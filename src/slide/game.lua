-- game.lua -- pure sliding-puzzle rules (the 15-puzzle, at 3x3, 4x4 and 5x5).
--
-- This module deliberately knows nothing about the TI-Nspire: no `platform`,
-- no `gc`, no `timer`. That keeps the rules runnable under a plain Lua 5.1
-- interpreter on a laptop. Drawing, input and timing live in src/slide/main.lua.
--
-- Read `Puzzle:shuffle` before anything else. Exactly half of all permutations
-- of a sliding puzzle cannot be reached from the solved state, and a player has
-- no way to tell an impossible board from a merely hard one -- they lose to the
-- generator after ten minutes of honest work. So the scramble is a random walk
-- of legal moves out of the solved position, which makes an unsolvable board
-- *unrepresentable* rather than merely detected, the same way Flappy fences its
-- pipe generator with the physics instead of filtering afterwards.
--
-- `Puzzle.isSolvable` then implements the inversion-parity rule anyway, purely
-- as an oracle for the tests. Two mechanisms that have to agree are worth far
-- more than one that is only asserted: a backwards oracle agreeing with a
-- backwards shuffler proves nothing, so the tests also pin the oracle against
-- boards whose solvability is known by construction.

local Puzzle = {}
Puzzle.__index = Puzzle

local floor, abs, max = math.floor, math.abs, math.max

-- ------------------------------------------------------------------ tuning --
-- Board size is the whole difficulty setting; the rules below are size-generic.
local DEFAULT_SIZE = 4
Puzzle.SIZES = { 3, 4, 5 }

-- Scramble length. A few hundred legal moves; more for a bigger board, which
-- has more cells to mix. 3x3: 192, 4x4: 248, 5x5: 320.
local WALK_BASE     = 120
local WALK_PER_CELL = 8
local REWALK_STEPS  = 40   -- extra moves when a walk landed too close to solved
local MAX_ROUNDS    = 64   -- give up re-walking after this many tries

-- A random walk can still land somewhere easy by chance, so a scramble has to
-- clear both floors below before the player ever sees it. The Manhattan floor
-- is the one that does the work -- misplaced-tile count saturates near the top
-- of its range and barely discriminates. Both are set at the 5th percentile of
-- what a walk of the length above actually produces, measured over 20000 walks
-- per size on this container, so rejection is rare and does not bias the
-- accepted boards much. For reference the medians were 14 / 36 / 66 Manhattan
-- and 7 / 14 / 23 misplaced at 3x3, 4x4 and 5x5.
local MIN_MISPLACED = { [3] = 5,  [4] = 12, [5] = 19 }
local MIN_MANHATTAN = { [3] = 10, [4] = 28, [5] = 52 }

-- Solver: no position at these sizes needs a longer optimal solution than this
-- (3x3 tops out at 31 moves, 4x4 at 80), so a bound past it means a bug, not a
-- hard board.
local MAX_BOUND = 90
-- ---------------------------------------------------------------------------

-- The gap's four neighbours, in a fixed order so the solver is deterministic.
local STEPS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }

-- An arrow names the direction THE TILE travels, so the gap travels the other
-- way: pressing Left slides the tile sitting to the *right* of the gap
-- leftwards into it. These are the gap's steps, which is why they read
-- inverted. `Puzzle.gapStep` flips them for players who prefer the opposite.
local GAP_STEP = {
  left  = {  1,  0 },
  right = { -1,  0 },
  up    = {  0,  1 },
  down  = {  0, -1 },
}

Puzzle.DIRS = { "left", "right", "up", "down" }

-- Returns dx, dy for the gap, or nil for anything that is not a direction.
-- `inverted` swaps the convention to "the arrow steers the gap".
function Puzzle.gapStep(dir, inverted)
  local s = GAP_STEP[dir]
  if not s then return nil end
  if inverted then return -s[1], -s[2] end
  return s[1], s[2]
end


-- --------------------------------------------------------------- generator --
--
-- math.randomseed does not take on the handheld: it returns without complaint
-- and changes nothing, so math.random replays one sequence from launch to
-- launch and the document would deal an identical scramble every time it is
-- opened. Wordle was caught by exactly this on real hardware, so the puzzle
-- owns its generator instead. MINSTD in plain arithmetic -- no bitwise
-- operators in Lua 5.1, and every product below stays under 2^53 so it is
-- exact in a double.

local RAND_M, RAND_A = 2147483647, 16807

function Puzzle.newRandom(seed)
  local s = floor(tonumber(seed) or 1) % RAND_M
  if s <= 0 then s = 1 end

  -- Two launches differ by only a few ticks of idling, and a raw LCG from a
  -- small seed returns a tiny first value: from s = 1 the first output is
  -- 16807, which scaled to four neighbours floors to the same choice for every
  -- seed in 1..10. Scramble, then warm up, so nearby seeds diverge at once.
  s = (s * 48271) % RAND_M
  if s <= 0 then s = 1 end
  for _ = 1, 6 do s = (RAND_A * s) % RAND_M end

  return function(n)
    s = (RAND_A * s) % RAND_M
    if not n or n < 1 then return s / RAND_M end
    -- From the top of the range rather than by a modulo: the low bits of an
    -- LCG are its weak ones, and the scramble draws from n = 2, 3 or 4, where
    -- a modulo would lean on exactly those bits a few hundred times a round.
    local v = floor(s / RAND_M * n) + 1
    if v > n then v = n end
    return v
  end
end

-- Folds a value into an accumulating seed. The host calls this for every tick,
-- key and click; 31 * 2147483646 is about 6.7e13, so this too stays exact.
function Puzzle.mix(acc, value)
  return ((acc or 1) * 31 + floor(tonumber(value) or 0)) % RAND_M
end

-- ------------------------------------------------------------------ set-up --

-- opts.size: 3, 4 or 5. opts.rand: function(n) -> integer in [1, n]; injectable
-- so tests are deterministic, and so the host can hand in a generator it owns
-- rather than math.random, which cannot be reseeded on the handheld.
-- opts.shuffle = false leaves the board solved, for tests that build their own.
function Puzzle.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Puzzle)
  self.rand = opts.rand or function(n) return math.random(n) end
  self.bests = opts.bests or {}   -- per size, kept across rounds for the session
  self:setSize(opts.size or DEFAULT_SIZE, opts.shuffle ~= false)
  return self
end

-- Changing size is a new puzzle, not a resize of the old one. Bests survive,
-- because they are per size and the session is what they belong to.
function Puzzle:setSize(n, doShuffle)
  self.size = n
  self.cells = n * n
  self:reset(doShuffle)
end

function Puzzle:setSolved()
  self.tiles = {}
  for i = 1, self.cells - 1 do self.tiles[i] = i end
  self.tiles[self.cells] = 0
  self.blank = self.cells
end

function Puzzle:reset(doShuffle)
  self:setSolved()
  self.moves = 0
  self.elapsed = 0
  self.undoStack = {}
  self.slide = nil        -- last move's tile motion, for the host's animation
  self.state = "ready"
  if doShuffle ~= false then self:shuffle() end
end

-- ------------------------------------------------------------------- cells --

function Puzzle:index(x, y) return (y - 1) * self.size + x end
function Puzzle:colOf(i) return (i - 1) % self.size + 1 end
function Puzzle:rowOf(i) return floor((i - 1) / self.size) + 1 end

function Puzzle:get(x, y)
  if x < 1 or x > self.size or y < 1 or y > self.size then return nil end
  return self.tiles[self:index(x, y)]
end

function Puzzle:blankXY()
  return self:colOf(self.blank), self:rowOf(self.blank)
end

-- Where tile v lives on the solved board -- which, with this numbering, is
-- cell v itself. Everything about "home" follows from that one line.
function Puzzle:homeOf(v) return v end

function Puzzle:isHome(i)
  local v = self.tiles[i]
  return v ~= 0 and v == i
end

function Puzzle:copyTiles(into)
  local t = into or {}
  for i = 1, self.cells do t[i] = self.tiles[i] end
  return t
end

-- ------------------------------------------------------------- measurements --

function Puzzle:misplaced()
  local n = 0
  for i = 1, self.cells do
    local v = self.tiles[i]
    if v ~= 0 and v ~= i then n = n + 1 end
  end
  return n
end

local function manhattanOf(tiles, size)
  local total = 0
  for i = 1, size * size do
    local v = tiles[i]
    if v ~= 0 then
      total = total + abs(((i - 1) % size) - ((v - 1) % size))
                    + abs(floor((i - 1) / size) - floor((v - 1) / size))
    end
  end
  return total
end

function Puzzle:manhattan() return manhattanOf(self.tiles, self.size) end

function Puzzle:isSolved()
  if self.tiles[self.cells] ~= 0 then return false end
  for i = 1, self.cells - 1 do
    if self.tiles[i] ~= i then return false end
  end
  return true
end

-- Every tile present exactly once and exactly one gap. Not used by the game --
-- the moves below cannot break it -- but it is what the tests assert after
-- thousands of random slides, so it lives with the rules it describes.
function Puzzle:isPermutation()
  local seen = {}
  local blanks = 0
  for i = 1, self.cells do
    local v = self.tiles[i]
    if type(v) ~= "number" or v < 0 or v > self.cells - 1 or v ~= floor(v) then
      return false
    end
    if v == 0 then
      blanks = blanks + 1
      if i ~= self.blank then return false end   -- cached gap must agree
    else
      if seen[v] then return false end
      seen[v] = true
    end
  end
  return blanks == 1
end

-- --------------------------------------------------------- solvability oracle --
--
-- The independent check, used only by the tests. Read the tiles row by row,
-- skipping the gap, and count inversions -- pairs that appear in the wrong
-- relative order.

function Puzzle.inversions(tiles, size)
  local seq, n = {}, 0
  for i = 1, size * size do
    local v = tiles[i]
    if v ~= 0 then
      n = n + 1
      seq[n] = v
    end
  end
  local inv = 0
  for a = 1, n - 1 do
    for b = a + 1, n do
      if seq[a] > seq[b] then inv = inv + 1 end
    end
  end
  return inv
end

-- Odd width  (3x3, 5x5): solvable iff the inversion count is even.
-- Even width (4x4):      solvable iff inversions + the gap's row counted from
--                        the BOTTOM, 1-indexed, is odd.
--
-- Sanity check that this is the right way round rather than its exact mirror:
-- the solved 4x4 has 0 inversions with the gap on the bottom row, so
-- 0 + 1 = 1, odd, therefore solvable -- which it must be, being solved.
function Puzzle.isSolvable(tiles, size)
  local inv = Puzzle.inversions(tiles, size)
  if size % 2 == 1 then
    return inv % 2 == 0
  end
  local blank
  for i = 1, size * size do
    if tiles[i] == 0 then blank = i break end
  end
  if not blank then return false end
  local rowFromTop = floor((blank - 1) / size) + 1
  local rowFromBottom = size - rowFromTop + 1
  return (inv + rowFromBottom) % 2 == 1
end

function Puzzle:solvable()
  return Puzzle.isSolvable(self.tiles, self.size)
end

-- ------------------------------------------------------------------- moves --

-- The cells the gap could swap with, in STEPS order. `avoid` drops one of
-- them, which is how the scramble refuses to immediately undo itself.
function Puzzle:gapNeighbours(avoid, out)
  local list = out or {}
  for i = #list, 1, -1 do list[i] = nil end
  local bx, by = self:blankXY()
  for s = 1, 4 do
    local x, y = bx + STEPS[s][1], by + STEPS[s][2]
    if x >= 1 and x <= self.size and y >= 1 and y <= self.size then
      local idx = self:index(x, y)
      if idx ~= avoid then list[#list + 1] = idx end
    end
  end
  return list
end

-- True if the cell is in line with the gap and is not the gap: exactly the
-- tiles a click or a number key is allowed to move.
function Puzzle:canSlideTo(x, y)
  if x == nil or y == nil then return false end
  if x < 1 or x > self.size or y < 1 or y > self.size then return false end
  local bx, by = self:blankXY()
  if x == bx and y == by then return false end
  return x == bx or y == by
end

-- Slides the whole run of tiles between the gap and (x, y) one cell toward the
-- gap, leaving the gap where the clicked tile was. That run behaviour is what
-- players expect from this puzzle, and a single-step move is just the case
-- where the run is one tile long.
--
-- Returns the number of tiles moved, 0 for an illegal target. Each tile that
-- travels counts as one move, which is the unit published solution lengths use.
function Puzzle:slideTo(x, y, record)
  -- record == false is the internal form, used by the scramble and by undo,
  -- and is deliberately not gated on the state machine. A move the player made
  -- only counts while the round is actually running.
  if record ~= false and self.state ~= "playing" then return 0 end
  if not self:canSlideTo(x, y) then return 0 end

  local bx, by = self:blankXY()
  local dx = (x > bx and 1) or (x < bx and -1) or 0
  local dy = (y > by and 1) or (y < by and -1) or 0
  local count = max(abs(x - bx), abs(y - by))

  -- Walk the gap along the line; every tile it passes steps back one cell.
  local slide = {}
  local cx, cy = bx, by
  for _ = 1, count do
    local nx, ny = cx + dx, cy + dy
    local v = self.tiles[self:index(nx, ny)]
    self.tiles[self:index(cx, cy)] = v
    slide[#slide + 1] = { fromX = nx, fromY = ny, toX = cx, toY = cy, value = v }
    cx, cy = nx, ny
  end
  self.tiles[self:index(cx, cy)] = 0
  self.blank = self:index(cx, cy)
  self.slide = slide

  if record ~= false then
    -- The inverse of a run slide is the same run slide back the other way, so
    -- one gap position is the entire undo record. Unlimited undo for free, and
    -- no snapshot per move: cf. Klondike's make/unmake.
    self.undoStack[#self.undoStack + 1] = { x = bx, y = by, count = count }
    self.moves = self.moves + count
    if self.state == "playing" and self:isSolved() then
      self.state = "solved"
      self:recordBest()
    end
  end
  return count
end

-- An arrow key. Returns the number of tiles moved (0 or 1: an arrow can only
-- ever move the one tile beside the gap).
function Puzzle:step(dir, inverted)
  local dx, dy = Puzzle.gapStep(dir, inverted)
  if not dx then return 0 end
  local bx, by = self:blankXY()
  return self:slideTo(bx + dx, by + dy)
end

function Puzzle:canUndo() return #self.undoStack > 0 end

-- Unlimited, because an undo record is one gap position and the inverse move
-- is the same operation run backwards.
function Puzzle:undo()
  local rec = self.undoStack[#self.undoStack]
  if not rec then return false end
  if self.state == "solved" then self.state = "playing" end
  self.undoStack[#self.undoStack] = nil
  self:slideTo(rec.x, rec.y, false)
  self.moves = self.moves - rec.count
  return true
end

-- ---------------------------------------------------------------- scramble --

-- One step of the scramble: a uniform choice among the gap's neighbours, never
-- the cell it just came from. Without that exclusion the walk spends half its
-- time retracing and drifts back toward solved. Public because that property
-- is worth testing directly rather than inferring from a distribution.
function Puzzle:scrambleStep(prev)
  local list = self:gapNeighbours(prev)
  local pick = list[self.rand(#list)]
  local from = self.blank
  self:slideTo(self:colOf(pick), self:rowOf(pick), false)
  return from
end

function Puzzle:randomWalk(steps, prev)
  for _ = 1, steps do
    prev = self:scrambleStep(prev)
  end
  return prev
end

-- Far enough from solved to be worth playing.
function Puzzle:isScrambled()
  if self:isSolved() then return false end
  local n = self.size
  return self:misplaced() >= (MIN_MISPLACED[n] or self.cells - 2)
     and self:manhattan() >= (MIN_MANHATTAN[n] or 0)
end

function Puzzle:shuffle()
  self:setSolved()
  local prev = self:randomWalk(WALK_BASE + WALK_PER_CELL * self.cells)
  local round = 0
  -- Keep walking from where the walk got to rather than starting over: it
  -- stays a legal walk (so still solvable) and it is already well mixed.
  while not self:isScrambled() and round < MAX_ROUNDS do
    prev = self:randomWalk(REWALK_STEPS, prev)
    round = round + 1
  end
  -- Belt and braces for a degenerate injected rand, which is the only way the
  -- loop above can run out while still sitting on the solved board. The result
  -- may then be easy, but it is never already-won.
  if self:isSolved() then self:scrambleStep() end

  self.moves = 0
  self.elapsed = 0
  self.undoStack = {}
  self.slide = nil
  self.state = "ready"
end

-- ------------------------------------------------------------------ states --

function Puzzle:start()
  if self.state == "ready" then self.state = "playing" end
end

function Puzzle:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Puzzle:resume()
  if self.state == "paused" then self.state = "playing" end
end

-- Seconds, fed by the host. Kept here rather than in main.lua so that "best
-- time" lives beside "best moves" and both are testable without a calculator.
function Puzzle:advance(dt)
  if self.state == "playing" then self.elapsed = self.elapsed + (dt or 0) end
end

function Puzzle:best()
  return self.bests[self.size]
end

function Puzzle:recordBest()
  local b = self.bests[self.size]
  if not b then
    b = {}
    self.bests[self.size] = b
  end
  -- Fewest moves and best time are tracked separately: a careful solve and a
  -- fast one are different achievements and neither should overwrite the other.
  if not b.moves or self.moves < b.moves then b.moves = self.moves end
  if not b.seconds or self.elapsed < b.seconds then b.seconds = self.elapsed end
  return b
end


-- ------------------------------------------------------------------ solver --
--
-- IDA* with Manhattan distance plus linear conflict, sliced across calls.
--
-- Running this to completion inside one on.timer() would freeze the screen and
-- queue up keypresses, which a player reads as a crash. So it is an explicit
-- state machine with a work budget the host advances one slice per tick,
-- exactly like Connect Four's ai:think(). Slicing changes only *when* it
-- answers, never *what*: the search is deterministic, so `think(20)` in a loop
-- and `think(1e9)` once return the same path, which is a test in
-- tests/slide/run.lua.
--
-- The search is optimal, and optimal is expensive: a freshly scrambled 4x4
-- needs a solution around 50 moves long, which is far past any budget a
-- handheld can spend between frames. That is why the answer is allowed to be
-- "no solution found in budget" -- a hint that guesses would be worse than no
-- hint at all. 5x5 is not attempted: see Puzzle.MAX_SOLVER_SIZE.

Puzzle.MAX_SOLVER_SIZE = 4

-- Scratch, reused across nodes. Allocating two tables per node is the single
-- most expensive thing this search would otherwise do.
local goalPos, conflicts = {}, {}

-- Linear conflict for one line: the goal offsets of the tiles that belong in
-- this line, in the order they currently appear. Two of them are in conflict
-- when they are in the wrong relative order, and each conflict costs the
-- solution at least two extra moves because one tile has to step out of the
-- line and back. Tiles are removed greedily, most-conflicted first, which is
-- the usual formulation and the one that stays admissible -- counting 2 per
-- conflicting *pair* would overestimate and cost the search its optimality.
local function lineConflict(count)
  if count < 2 then return 0 end
  for i = 1, count do conflicts[i] = 0 end
  for i = 1, count - 1 do
    for j = i + 1, count do
      if goalPos[i] > goalPos[j] then
        conflicts[i] = conflicts[i] + 1
        conflicts[j] = conflicts[j] + 1
      end
    end
  end

  local extra = 0
  while true do
    local worst, most = 0, 0
    for i = 1, count do
      if conflicts[i] > most then worst, most = i, conflicts[i] end
    end
    if most == 0 then return extra end
    extra = extra + 2
    local gone = goalPos[worst]
    goalPos[worst] = false
    conflicts[worst] = 0
    for j = 1, count do
      if goalPos[j] and ((j < worst and goalPos[j] > gone)
                      or (j > worst and goalPos[j] < gone)) then
        conflicts[j] = conflicts[j] - 1
      end
    end
  end
end

local function heuristic(tiles, size)
  local h = manhattanOf(tiles, size)

  for r = 1, size do
    local count = 0
    for c = 1, size do
      local v = tiles[(r - 1) * size + c]
      if v ~= 0 and floor((v - 1) / size) + 1 == r then
        count = count + 1
        goalPos[count] = (v - 1) % size + 1
      end
    end
    h = h + lineConflict(count)
  end

  for c = 1, size do
    local count = 0
    for r = 1, size do
      local v = tiles[(r - 1) * size + c]
      if v ~= 0 and (v - 1) % size + 1 == c then
        count = count + 1
        goalPos[count] = floor((v - 1) / size) + 1
      end
    end
    h = h + lineConflict(count)
  end

  return h
end

Puzzle.heuristic = heuristic

local Solver = {}
Solver.__index = Solver
Puzzle.Solver = Solver

-- maxNodes is the *total* budget across every think() call, not per call.
function Puzzle:newSolver(maxNodes)
  local s = setmetatable({}, Solver)
  s.size, s.cells = self.size, self.cells
  -- A copy, never the live board. A suspended search is suspended mid-mutation
  -- and on.paint would draw its half-explored guesses -- Connect Four hit
  -- exactly this.
  s.tiles = self:copyTiles()
  s.blank = self.blank
  s.maxNodes = maxNodes or 250000
  s.nodes = 0
  s.nextBound = math.huge
  s.stack = { { blank = s.blank, from = 0, dir = 0 } }
  s.depth = 1

  if self.size > Puzzle.MAX_SOLVER_SIZE then
    s.status = "unsupported"
  else
    s.bound = heuristic(s.tiles, s.size)
    if s.bound == 0 then
      s.status, s.path = "solved", {}
    else
      s.status = "thinking"
    end
  end
  return s
end

function Solver:finish()
  local path = {}
  for i = 2, self.depth do path[i - 1] = self.stack[i].blank end
  self.path, self.status = path, "solved"
end

-- One node of the depth-first search, or one pop, or one deepening.
function Solver:advance()
  local size = self.size
  local d = self.depth
  local fr = self.stack[d]

  while fr.dir < 4 do
    fr.dir = fr.dir + 1
    local st = STEPS[fr.dir]
    local x = (fr.blank - 1) % size + 1 + st[1]
    local y = floor((fr.blank - 1) / size) + 1 + st[2]
    if x >= 1 and x <= size and y >= 1 and y <= size then
      local target = (y - 1) * size + x
      if target ~= fr.from then           -- never step straight back
        self.nodes = self.nodes + 1
        local v = self.tiles[target]
        self.tiles[fr.blank] = v
        self.tiles[target] = 0

        local h = heuristic(self.tiles, size)
        if d + h > self.bound then         -- g of this child is exactly d
          if d + h < self.nextBound then self.nextBound = d + h end
          self.tiles[target] = v           -- unmake
          self.tiles[fr.blank] = 0
        else
          d = d + 1
          self.depth = d
          local nf = self.stack[d]
          if nf then
            nf.blank, nf.from, nf.dir = target, fr.blank, 0
          else
            self.stack[d] = { blank = target, from = fr.blank, dir = 0 }
          end
          if h == 0 then self:finish() end
          return
        end

        if self.nodes >= self.maxNodes then
          self.status = "budget"
          return
        end
      end
    end
  end

  if d > 1 then
    -- Unmake the move that created this frame and drop back to its parent.
    self.tiles[fr.blank] = self.tiles[fr.from]
    self.tiles[fr.from] = 0
    self.depth = d - 1
    return
  end

  -- The root ran out of moves, so nothing at this bound reaches the goal.
  if self.nextBound == math.huge or self.nextBound > MAX_BOUND then
    self.status = "budget"
    return
  end
  self.bound, self.nextBound = self.nextBound, math.huge
  fr.dir = 0
end

-- Does at most `budget` nodes of work and reports where it got to:
--   "thinking"    call again next tick
--   "solved"      self.path holds the gap's cells, in order
--   "budget"      no solution found in budget; say so, do not guess
--   "unsupported" too big to search optimally
function Solver:think(budget)
  budget = budget or 2000
  local start = self.nodes
  while self.status == "thinking" and self.nodes - start < budget do
    self:advance()
  end
  return self.status
end

return Puzzle
