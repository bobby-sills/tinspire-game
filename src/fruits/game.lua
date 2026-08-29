-- game.lua -- pure match-three rules: an 8x8 grid, adjacent swaps, runs of
-- three or more, gravity, refill, and cascades that score down a chain.
--
-- Like the other games here, this module knows nothing about the TI-Nspire:
-- no `platform`, no `gc`, no `timer`. That is what lets the rules run under a
-- desktop Lua and be tested directly. Drawing, input and timing live in
-- src/fruits/main.lua.
--
-- Two things in this file are load-bearing, and both are worth reading before
-- anything else.
--
-- 1. `Fruit:dealCells` never deals a board that already matches. Dealing at
--    random and rerolling would work, but the board is *filled cell by cell*
--    excluding any colour that would complete a run with the two cells to the
--    left or the two above, which makes an already-matching board
--    unrepresentable rather than merely rejected -- the same reason
--    src/slide/game.lua walks legal moves instead of permuting tiles. At most
--    two kinds are ever excluded, so the fill can never paint itself into a
--    corner. The trap is the opposite one, and it is right next door:
--    `Fruit:collapse` refills mid-cascade with *no* exclusion at all, because
--    fruit falling in after a clear are allowed to match. That is what a
--    cascade is. Apply the no-match fill there and cascades quietly vanish
--    from the game.
--
--    `Fruit.scanRuns` and `Fruit.allLegalSwaps` then implement, from scratch and
--    sharing no code with any of the above, the two checks the constructive
--    fill was designed to make unnecessary. Nothing in the game ever calls
--    them; they exist so that two mechanisms have to agree in the tests.
--
-- 2. The cascade is a state machine, not a loop. There are no threads on this
--    device and no way to yield, and every step -- the swap, the clear, the
--    fall -- has to be seen. So `Fruit:advance()` performs exactly one phase
--    transition and `Fruit:tick()` decides only *when* to call it. Resolving a
--    cascade a tick at a time and resolving it in one `Fruit:resolve()` call
--    therefore reach the identical board and the identical score, which is the
--    test that matters. Keeping the machine here rather than in main.lua is
--    what lets the tests drive it straight through; cf. connect4's sliced
--    search.

local Fruit = {}
Fruit.__index = Fruit

local floor, max, min = math.floor, math.max, math.min

-- ------------------------------------------------------------------ tuning --

local COLS, ROWS = 8, 8
local CELLS = COLS * ROWS
local KINDS = 7          -- distinct fruits; must be >= 3 for the fill below
local RUN   = 3          -- fruit in a line that clear

Fruit.COLS, Fruit.ROWS, Fruit.CELLS = COLS, ROWS, CELLS
Fruit.KINDS, Fruit.RUN = KINDS, RUN

-- Scoring. A clear is scored as one event over its distinct cells, so a fruit
-- sitting in both arms of an L clears once and scores once -- see
-- `Fruit:findMatches`, which is what counts them.
local POINT_PER_GEM = 10
local LONG_BONUS    = 20   -- extra, per fruit past the third in a single clear

-- The multiplier down a cascade. Capped, because an eight-deep chain is rare
-- enough that letting it run away would make one lucky board the whole score.
Fruit.CHAIN_MULT = { 1, 2, 3, 5, 8, 12 }

-- How many host ticks each phase stays on screen. At the ~0.05s the handheld's
-- timer realistically manages these are roughly 0.15s a step, which reads as
-- deliberate rather than sluggish; a cascade three deep takes about a second.
-- These are pure presentation -- `advance()` is what changes the board, and it
-- is called the same number of times whatever these say.
Fruit.PHASE_HOLD = { swap = 3, unswap = 3, clear = 3, fall = 4 }

-- A fresh deal that has no legal swap is retried. That is not the same as
-- deal-and-reroll for *matches*, which the fill makes impossible: this is a
-- rare second property being resampled, not the main invariant being filtered.
-- Measured on this container over 200000 deals at 8x8 with 7 fruits, no deal
-- ever needed a retry, so the loop below is insurance rather than machinery.
local MAX_DEALS = 32

-- Safety stop for `resolve()`. A cascade cannot run forever -- each clear
-- removes at least three fruit and the refill is random -- but a bug in the
-- machine could, and a test that hangs is worse than one that fails.
local MAX_PHASES = 4096
-- ---------------------------------------------------------------------------


-- --------------------------------------------------------------- generator --
--
-- math.randomseed does not take on the handheld: it returns without complaint
-- and changes nothing, so math.random replays one sequence from launch to
-- launch and the document would deal an identical board every time it is
-- opened. Wordle was caught by exactly this on real hardware. So the game owns
-- its generator, as slide and wordle do. MINSTD in plain arithmetic -- Lua 5.1
-- here has no bitwise operators, and every product below stays under 2^53 so
-- it is exact in a double.

local RAND_M, RAND_A = 2147483647, 16807

function Fruit.newRandom(seed)
  local s = floor(tonumber(seed) or 1) % RAND_M
  if s <= 0 then s = 1 end

  -- Two launches differ by only a few ticks of idling, and a raw LCG from a
  -- small seed returns a tiny first value: from s = 1 the first output is
  -- 16807, which scaled to seven fruits floors to the same one for every seed
  -- in 1..100. Scramble, then warm up, so nearby seeds diverge immediately.
  s = (s * 48271) % RAND_M
  if s <= 0 then s = 1 end
  for _ = 1, 6 do s = (RAND_A * s) % RAND_M end

  return function(n)
    s = (RAND_A * s) % RAND_M
    if not n or n < 1 then return s / RAND_M end
    -- From the top of the range rather than by a modulo: the low bits of an
    -- LCG are its weak ones, and a board deals 64 fruit and then refills a few
    -- hundred more, all from small n, where a modulo would lean on exactly
    -- those bits every single draw.
    local v = floor(s / RAND_M * n) + 1
    if v > n then v = n end
    return v
  end
end

-- Folds a value into an accumulating seed. The host calls this for every tick,
-- key and click; 31 * 2147483646 is about 6.7e13, so this too stays exact.
function Fruit.mix(acc, value)
  return ((acc or 1) * 31 + floor(tonumber(value) or 0)) % RAND_M
end


-- ------------------------------------------------------------------ set-up --

-- opts.rand:  function(n) -> integer in [1, n]. Injectable so tests are
--             deterministic, and so the host can hand in a generator it owns
--             rather than math.random, which cannot be reseeded on hardware.
-- opts.deal = false leaves the grid empty, for tests that build their own.
function Fruit.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Fruit)
  self.rand = opts.rand or function(n) return math.random(n) end
  self.best = opts.best or 0
  self.cells  = {}
  self.marked = {}
  self.motion = {}
  self:reset(opts.deal ~= false)
  return self
end

function Fruit:reset(doDeal)
  local cells, marked = self.cells, self.marked
  for i = 1, CELLS do cells[i], marked[i] = 0, false end
  self:clearMotion()

  self.score, self.moves, self.badSwaps, self.cleared = 0, 0, 0, 0
  self.chain, self.bestChain, self.matched, self.lastGain = 0, 0, 0, 0
  self.pending, self.hint = nil, nil
  self.state = "ready"      -- ready | playing | paused | over
  self.phase = "idle"       -- idle | swap | unswap | clear | fall
  self.hold  = 0

  if doDeal ~= false then self:deal() end
end


-- ------------------------------------------------------------------- cells --

function Fruit.index(x, y) return (y - 1) * COLS + x end

function Fruit.inside(x, y)
  return x ~= nil and y ~= nil
     and x >= 1 and x <= COLS and y >= 1 and y <= ROWS
     and x == floor(x) and y == floor(y)
end

function Fruit:get(x, y)
  if not Fruit.inside(x, y) then return nil end
  return self.cells[(y - 1) * COLS + x]
end

function Fruit:set(x, y, k)
  if Fruit.inside(x, y) then self.cells[(y - 1) * COLS + x] = k end
end

-- Two cells are swappable only if they share an edge. Diagonals are not a
-- move, and neither is a cell with itself.
function Fruit.adjacent(x1, y1, x2, y2)
  if not (Fruit.inside(x1, y1) and Fruit.inside(x2, y2)) then return false end
  local dx, dy = x1 - x2, y1 - y2
  if dx < 0 then dx = -dx end
  if dy < 0 then dy = -dy end
  return dx + dy == 1
end

-- Every cell holds a real fruit. The board is full at rest and full after every
-- phase; nothing in the game may leave a hole behind, and the tests assert
-- this after each individual step of thousands of cascades.
function Fruit:isFull()
  local cells = self.cells
  for i = 1, CELLS do
    local k = cells[i]
    if type(k) ~= "number" or k < 1 or k > KINDS or k ~= floor(k) then
      return false
    end
  end
  return true
end

function Fruit:copyCells(into)
  local t, cells = into or {}, self.cells
  for i = 1, CELLS do t[i] = cells[i] end
  return t
end

function Fruit:loadCells(src)
  local cells = self.cells
  for i = 1, CELLS do cells[i] = src[i] end
end


-- ----------------------------------------------------------- the fresh deal --

-- Fills `cells` row by row, never placing a fruit that would complete a run with
-- the two cells to its left or the two above. Those are the only runs a
-- left-to-right, top-to-bottom fill can complete, and they exclude at most two
-- kinds between them -- so with KINDS >= 3 there is always something legal
-- to place and the fill can never get stuck and need a restart.
--
-- `pick(n)` must return an integer in [1, n]. It is a parameter rather than
-- self.rand so that `deal` can fall back to a deterministic chooser.
function Fruit:dealCells(pick, cells)
  cells = cells or self.cells
  local allowed = {}

  for y = 1, ROWS do
    for x = 1, COLS do
      local i = (y - 1) * COLS + x

      local banL, banU
      if x >= 3 and cells[i - 1] == cells[i - 2] then banL = cells[i - 1] end
      if y >= 3 and cells[i - COLS] == cells[i - 2 * COLS] then
        banU = cells[i - COLS]
      end

      local n = 0
      for k = 1, KINDS do
        if k ~= banL and k ~= banU then
          n = n + 1
          allowed[n] = k
        end
      end
      cells[i] = allowed[pick(n)]
    end
  end
  return cells
end

-- A board the player can actually start on: no run already on it (guaranteed
-- by the fill above, not checked here) and at least one swap that makes one,
-- or they are looking at a dead board with nothing on screen to say why.
function Fruit:deal()
  for _ = 1, MAX_DEALS do
    self:dealCells(self.rand)
    if self:hasMove() then return true end
  end

  -- Only a rand degenerate enough to make the same choice every time can get
  -- here. The deterministic fill is match-free by the same construction, and
  -- tests/fruits/run.lua pins it as having a legal swap, so even this path never
  -- opens onto a board the player cannot move.
  self:dealCells(function() return 1 end)
  return false
end


-- --------------------------------------------------- matching (production) --

-- True if the fruit at (x, y) sits in a run of RUN or more.
--
-- Only the cross through one cell, because every caller asks about a cell that
-- just moved, and a run that is new must pass through one of the two cells the
-- swap moved. That is what makes `findMove` -- 112 trial swaps -- cheap enough
-- to run on a handheld after every cascade.
function Fruit:matchesAt(x, y)
  local cells = self.cells
  if not Fruit.inside(x, y) then return false end
  local k = cells[(y - 1) * COLS + x]
  if not k or k == 0 then return false end

  local base = (y - 1) * COLS
  local n, cx = 1, x - 1
  while cx >= 1 and cells[base + cx] == k do n = n + 1; cx = cx - 1 end
  cx = x + 1
  while cx <= COLS and cells[base + cx] == k do n = n + 1; cx = cx + 1 end
  if n >= RUN then return true end

  n = 1
  local cy = y - 1
  while cy >= 1 and cells[(cy - 1) * COLS + x] == k do n = n + 1; cy = cy - 1 end
  cy = y + 1
  while cy <= ROWS and cells[(cy - 1) * COLS + x] == k do n = n + 1; cy = cy + 1 end
  return n >= RUN
end

-- Marks every cell in every run on the board into `self.marked` and returns
-- how many DISTINCT cells that is.
--
-- Distinct is the whole point. Two runs crossing in an L or a T share a fruit;
-- it can only clear once, and it must only score once, so the count comes from
-- the marks and not from adding the run lengths up. One sweep per axis, each
-- carrying a running run length, rather than a scan per cell.
function Fruit:findMatches()
  local cells, marked = self.cells, self.marked
  for i = 1, CELLS do marked[i] = false end
  local count = 0

  for y = 1, ROWS do
    local base = (y - 1) * COLS
    local start, kind = 1, cells[base + 1]
    -- One past the end, with a kind that matches nothing, so the last run on
    -- the row is closed by the same branch as every other run.
    for x = 2, COLS + 1 do
      local k = (x <= COLS) and cells[base + x] or nil
      if k ~= kind then
        if kind and kind ~= 0 and x - start >= RUN then
          for j = start, x - 1 do
            local i = base + j
            if not marked[i] then marked[i] = true; count = count + 1 end
          end
        end
        start, kind = x, k
      end
    end
  end

  for x = 1, COLS do
    local start, kind = 1, cells[x]
    for y = 2, ROWS + 1 do
      local k = (y <= ROWS) and cells[(y - 1) * COLS + x] or nil
      if k ~= kind then
        if kind and kind ~= 0 and y - start >= RUN then
          for j = start, y - 1 do
            local i = (j - 1) * COLS + x
            if not marked[i] then marked[i] = true; count = count + 1 end
          end
        end
        start, kind = y, k
      end
    end
  end

  self.matched = count
  return count
end

function Fruit:hasMatch()
  return self:findMatches() > 0
end


-- ----------------------------------------------------- legal moves (production) --

-- Swaps two cells in place, tests only the crosses through them, and swaps
-- back. Leaves the board exactly as it found it.
function Fruit:swapMakesMatch(x1, y1, x2, y2)
  if not Fruit.adjacent(x1, y1, x2, y2) then return false end
  local cells = self.cells
  local i, j = (y1 - 1) * COLS + x1, (y2 - 1) * COLS + x2
  if cells[i] == cells[j] then return false end   -- a no-op swap changes nothing

  cells[i], cells[j] = cells[j], cells[i]
  local hit = self:matchesAt(x1, y1) or self:matchesAt(x2, y2)
  cells[i], cells[j] = cells[j], cells[i]
  return hit
end

-- The first legal swap in scan order, as x1, y1, x2, y2, or nil. Deterministic
-- on purpose: it is what the hint shows and what the tests compare against the
-- brute-force oracle, and "the same board always suggests the same move" is
-- easier to reason about than a random pick.
function Fruit:findMove()
  for y = 1, ROWS do
    for x = 1, COLS do
      if x < COLS and self:swapMakesMatch(x, y, x + 1, y) then
        return x, y, x + 1, y
      end
      if y < ROWS and self:swapMakesMatch(x, y, x, y + 1) then
        return x, y, x, y + 1
      end
    end
  end
  return nil
end

function Fruit:hasMove()
  return (self:findMove()) ~= nil
end


-- ================================================================ oracles ===
--
-- Independent reimplementations of the two questions the design above was
-- built to make unnecessary. NOTHING IN THE GAME CALLS EITHER OF THESE. They
-- exist so tests/fruits/run.lua can hold two mechanisms that share no code up
-- against each other -- a scanner agreeing with itself proves nothing.
--
-- Both are written the slow, obvious way on purpose: a cell at a time, from
-- the definition, with no running counters and no incremental reasoning.

-- Every cell that is part of a run, as a set of indices. The naive scanner:
-- for each cell, count its own colour outward in both directions along each
-- axis, and if the line is long enough, mark that one cell.
function Fruit.scanRuns(cells, cols, rows, run)
  cols, rows, run = cols or COLS, rows or ROWS, run or RUN
  local hit, n = {}, 0

  local function at(x, y)
    if x < 1 or x > cols or y < 1 or y > rows then return nil end
    return cells[(y - 1) * cols + x]
  end

  for y = 1, rows do
    for x = 1, cols do
      local k = at(x, y)
      if k and k ~= 0 then
        for axis = 1, 2 do
          local dx, dy = (axis == 1) and 1 or 0, (axis == 1) and 0 or 1
          local len = 1
          local cx, cy = x + dx, y + dy
          while at(cx, cy) == k do len = len + 1; cx, cy = cx + dx, cy + dy end
          cx, cy = x - dx, y - dy
          while at(cx, cy) == k do len = len + 1; cx, cy = cx - dx, cy - dy end
          if len >= run and not hit[(y - 1) * cols + x] then
            hit[(y - 1) * cols + x] = true
            n = n + 1
          end
        end
      end
    end
  end
  return hit, n
end

-- Every legal swap on the board, brute force: make the swap, scan the WHOLE
-- board with the oracle above, restore. Shares nothing with `findMove`, which
-- reasons about which crosses can possibly have changed.
function Fruit.allLegalSwaps(cells, cols, rows, run)
  cols, rows = cols or COLS, rows or ROWS
  local out = {}

  local function trial(x1, y1, x2, y2)
    local i, j = (y1 - 1) * cols + x1, (y2 - 1) * cols + x2
    cells[i], cells[j] = cells[j], cells[i]
    local _, n = Fruit.scanRuns(cells, cols, rows, run)
    cells[i], cells[j] = cells[j], cells[i]
    if n > 0 then out[#out + 1] = { x1, y1, x2, y2 } end
  end

  for y = 1, rows do
    for x = 1, cols do
      if x < cols then trial(x, y, x + 1, y) end
      if y < rows then trial(x, y, x, y + 1) end
    end
  end
  return out
end

-- ==========================================================================


-- ---------------------------------------------------------------- gravity --

function Fruit:clearMotion()
  local m = self.motion
  for i = #m, 1, -1 do m[i] = nil end
  return m
end

-- Compacts each column downward and refills the holes from off the top.
--
-- Walking each column from the bottom up and writing to the lowest free row
-- preserves the relative order of what was already there: a fruit never passes
-- another fruit in its own column, which is what "falling" has to mean.
--
-- `pick(n)` fills the holes and is deliberately unconstrained -- fruit arriving
-- after a clear ARE allowed to land on a match. Excluding matches here, the
-- way the fresh deal does, would silently delete cascades from the game.
--
-- Fills self.motion with { x, fromY, toY, kind, new } so the host can animate
-- it. New fruit get a fromY at or above 0, which is off the top of the board.
function Fruit:collapse(pick)
  local cells = self.cells
  local motion = self:clearMotion()

  for x = 1, COLS do
    local write = ROWS
    for y = ROWS, 1, -1 do
      local i = (y - 1) * COLS + x
      local k = cells[i]
      if k ~= 0 then
        if write ~= y then
          cells[(write - 1) * COLS + x] = k
          cells[i] = 0
          motion[#motion + 1] =
            { x = x, fromY = y, toY = write, kind = k, new = false }
        end
        write = write - 1
      end
    end

    -- Rows 1..write are the holes left over. The fruit that lands lowest starts
    -- highest above the board, so a column's newcomers never cross each other
    -- on the way down.
    for y = 1, write do
      local k = pick(KINDS)
      cells[(y - 1) * COLS + x] = k
      motion[#motion + 1] =
        { x = x, fromY = y - write, toY = y, kind = k, new = true }
    end
  end
  return motion
end


-- --------------------------------------------------------------- scoring --

function Fruit.chainMult(chain)
  local t = Fruit.CHAIN_MULT
  if not chain or chain < 1 then return t[1] end
  return t[min(chain, #t)]
end

-- One clear, scored over its distinct cells so an overlap counts once.
function Fruit:scoreClear()
  local n = self.matched
  if n <= 0 then return 0 end

  local mult = Fruit.chainMult(self.chain)
  local gained = (n * POINT_PER_GEM + max(0, n - RUN) * LONG_BONUS) * mult

  self.score = self.score + gained
  self.lastGain = gained
  self.cleared = self.cleared + n
  if self.chain > self.bestChain then self.bestChain = self.chain end
  if self.score > self.best then self.best = self.score end
  return gained
end


-- ======================================================= the phase machine ==
--
-- One transition per `advance()`. The work of a phase happens as it is LEFT,
-- so while a phase is on screen the board holds exactly what that phase is
-- meant to show: during `clear`, the matched fruit are still there and
-- self.marked says which are bursting; during `fall`, the board already holds
-- the settled result and self.motion says where everything came from. That is
-- the same split 2048's slide animation uses.

local function enter(self, phase)
  self.phase = phase
  if phase == "idle" then
    self.hold = 0
  else
    -- At least one tick, always: a phase nobody can see is a phase that may as
    -- well not exist, and the illegal-swap bounce is the one that needs it most.
    self.hold = max(1, Fruit.PHASE_HOLD[phase] or 1)
  end
end

local function swapCells(self, x1, y1, x2, y2)
  local cells = self.cells
  local i, j = (y1 - 1) * COLS + x1, (y2 - 1) * COLS + x2
  cells[i], cells[j] = cells[j], cells[i]
end

local function setSwapMotion(self, x1, y1, x2, y2)
  local motion = self:clearMotion()
  local cells = self.cells
  -- The cells already hold the post-swap board, so each fruit is drawn coming
  -- FROM the other cell.
  motion[1] = { x = x1, y = y1, fromX = x2, fromY = y2, toX = x1, toY = y1,
                kind = cells[(y1 - 1) * COLS + x1], swap = true }
  motion[2] = { x = x2, y = y2, fromX = x1, fromY = y1, toX = x2, toY = y2,
                kind = cells[(y2 - 1) * COLS + x2], swap = true }
end

-- Asks for a swap. Returns true if it was accepted as an attempt -- which is
-- not the same as it being legal: an illegal swap is accepted, played, and
-- visibly played back, because silently refusing leaves the player unsure the
-- key even registered.
function Fruit:swap(x1, y1, x2, y2)
  if self.state ~= "playing" then return false end
  if self.phase ~= "idle" then return false end
  if not Fruit.adjacent(x1, y1, x2, y2) then return false end

  self.hint = nil
  swapCells(self, x1, y1, x2, y2)
  setSwapMotion(self, x1, y1, x2, y2)
  self.pending = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  self.chain, self.lastGain = 0, 0
  enter(self, "swap")
  return true
end

-- Exactly one phase transition. Returns false only when there was nothing to
-- do, i.e. the machine is idle.
function Fruit:advance()
  local p = self.phase

  if p == "swap" then
    if self:findMatches() > 0 then
      self.moves = self.moves + 1
      self.chain = 1
      self:clearMotion()
      enter(self, "clear")
    else
      local q = self.pending
      swapCells(self, q.x1, q.y1, q.x2, q.y2)
      setSwapMotion(self, q.x1, q.y1, q.x2, q.y2)
      self.badSwaps = self.badSwaps + 1
      enter(self, "unswap")
    end

  elseif p == "unswap" then
    self.pending = nil
    self:clearMotion()
    enter(self, "idle")

  elseif p == "clear" then
    self:scoreClear()
    local cells, marked = self.cells, self.marked
    for i = 1, CELLS do
      if marked[i] then cells[i] = 0 end
    end
    self:collapse(self.rand)
    enter(self, "fall")

  elseif p == "fall" then
    self:clearMotion()
    if self:findMatches() > 0 then
      self.chain = self.chain + 1
      enter(self, "clear")
    else
      self.pending = nil
      self.chain = 0
      enter(self, "idle")
      -- The round ends where it can no longer be played. Checked here, at the
      -- one moment the board is settled and full, rather than anywhere a
      -- caller might think to ask.
      if self.state == "playing" and not self:hasMove() then
        self.state = "over"
        if self.score > self.best then self.best = self.score end
      end
    end

  else
    return false
  end

  return true
end

-- Runs the machine to a standstill in one call. Used by the tests, and by
-- nothing on the handheld -- doing this inside one on.timer() is exactly the
-- freeze this file exists to avoid.
function Fruit:resolve()
  local n = 0
  while self.phase ~= "idle" and n < MAX_PHASES do
    self:advance()
    n = n + 1
  end
  return n
end

-- One host timer tick.
--
-- This is the ONLY thing that knows about time, and it deliberately contains
-- no game logic at all: it decides when `advance()` is called and nothing
-- else. That is what makes "resolve a cascade a tick at a time" and "resolve
-- it in one call" provably the same board and the same score, and it is why
-- the equivalence test in tests/fruits/run.lua is worth writing -- it fails the
-- moment someone moves a rule up into here.
--
-- Returns true if the board changed, i.e. if the host should repaint the
-- world rather than just the animation.
function Fruit:tick()
  if self.state ~= "playing" then return false end
  if self.phase == "idle" then return false end

  self.hold = self.hold - 1
  if self.hold > 0 then return false end
  return self:advance()
end

-- True while something is moving on screen and the host must keep repainting.
function Fruit:busy()
  return self.phase ~= "idle"
end

-- How far through the current phase we are, 0..1, for the host's tweening.
function Fruit:phaseProgress()
  local total = Fruit.PHASE_HOLD[self.phase]
  if not total or total <= 0 then return 1 end
  local done = total - self.hold
  if done < 0 then done = 0 end
  if done > total then done = total end
  return done / total
end


-- ------------------------------------------------------------------ states --

function Fruit:start()
  if self.state == "ready" then self.state = "playing" end
end

function Fruit:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Fruit:resume()
  if self.state == "paused" then self.state = "playing" end
end

function Fruit:isOver()
  return self.state == "over"
end

-- Lights up a legal swap. Costs a little score, so it is a real decision
-- rather than a button to lean on -- and never below zero.
Fruit.HINT_COST = 20

function Fruit:showHint()
  if self.state ~= "playing" or self.phase ~= "idle" then return nil end
  local x1, y1, x2, y2 = self:findMove()
  if not x1 then return nil end
  if not self.hint then
    self.score = max(0, self.score - Fruit.HINT_COST)
  end
  self.hint = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
  return self.hint
end

return Fruit
