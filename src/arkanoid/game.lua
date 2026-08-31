-- arkanoid.lua -- pure Arkanoid rules: bricks, ball, paddle, capsules, lasers.
--
-- Like every other game/*.lua here this module knows nothing about the
-- TI-Nspire: no `platform`, no `gc`, no `timer`. It runs under a desktop Lua
-- 5.1 so the rules can be fuzzed without a calculator. Drawing, input and
-- timing live in src/arkanoid/main.lua.
--
-- Flappy is the closest relative -- continuous motion advanced by one fixed
-- timestep per host tick, everything in pixels-per-frame -- but Arkanoid adds
-- the problem Flappy never had: a fast small object hunting small obstacles.
-- At the handheld's ~20 FPS ceiling the ball moves several pixels a frame, the
-- paddle is five pixels thick, and a naive "add the velocity, then look for an
-- overlap" integrator lets the ball pass clean through both. `Ball:step` below
-- is therefore substepped and axis-separated, with a hard guarantee that a
-- step never *ends* with the ball inside anything -- see moveAxis.

local Arkanoid = {}
Arkanoid.__index = Arkanoid

local floor, ceil, abs, sqrt = math.floor, math.ceil, math.abs, math.sqrt
local min, max = math.min, math.max

-- ====================================================================== --
--                          TUNING CONSTANTS                              --
--                                                                        --
--  Everything that decides how the game *feels* is in this block and     --
--  nowhere else, because none of it can be judged from this container --  --
--  the mock cannot tell you whether a paddle answers a thumb. Units are  --
--  pixels and frames of the host timer, and a frame is 1/20 s at best.   --
-- ====================================================================== --

local COLS       = 13     -- brick columns. 13 x 23px fills the 306px interior.
local MAX_ROWS   = 10     -- most rows a level may declare
local WALL       = 6      -- side and top wall thickness
local BRICK_H    = 9
local TOP_GAP    = 8      -- sky between the top wall and the first brick row

local BALL_SIZE  = 4
local PADDLE_H   = 5
local PADDLE_W   = 38     -- ... and 60 with the Enlarge capsule
local PADDLE_W_WIDE = 60
local PADDLE_BOTTOM = 16  -- gap from the paddle's top to the bottom edge

-- Paddle drive. The Nspire has no key-down polling and no key-up event, so a
-- *held* arrow reaches a script only as the OS's auto-repeat: one press, a
-- pause of about half a second, then a stream. Steering a paddle by nudging it
-- one step per event is unplayable at that rate. So an arrow does not move the
-- paddle -- it opens a DRIVE window during which the paddle accelerates, and
-- each repeat re-opens it. A single tap is a satisfying nudge that coasts to a
-- stop under friction; a held key is smooth continuous travel. Neither path
-- needs to know which one the player is doing.
local PADDLE_ACCEL  = 1.7   -- px/frame^2 while driven
local PADDLE_MAX    = 7.0   -- px/frame
local PADDLE_DRIVE  = 5     -- frames one key event keeps driving for
local PADDLE_FRICTION = 0.70 -- per frame once the drive window closes
local PADDLE_SNAP   = 2     -- px: close enough to a clicked target

-- Ball speed. Substepping means no speed here can tunnel, so SPEED_MAX is a
-- playability limit and not a safety one.
-- Pace, and the one thing here that a container cannot judge. At 20 FPS the
-- ball is a 4px square moving whole pixels between frames, so speed is bounded
-- above by legibility rather than by the physics: past about 6 px/frame it
-- stops reading as a moving object and starts reading as a flicker. 3.6 is a
-- round trip of the playfield in a bit over three seconds, which is a rally.
local SPEED_BASE      = 3.8   -- px/frame at level 1
local SPEED_PER_LEVEL = 0.14
-- The wind-up matters more than the base speed does. Breakout's failure mode
-- is not the opening, it is the last four bricks, where the wall no longer
-- gets in the way and every trip is the full height of the playfield for one
-- hit. Winding the ball up over the level turns that tail from a grind into a
-- sprint, and it is self-limiting: it can only get there by clearing the wall.
local SPEED_PER_HIT   = 0.022
local SPEED_HIT_CAP   = 1.30
local SPEED_MAX_ROW   = 0.55  -- extra, once a third or less of the wall is left
local SPEED_TOP_BONUS = 0.35  -- once the ball has reached the ceiling, as in 1986
local SPEED_MAX       = 5.6
local SLOW_FACTOR     = 0.70  -- the Slow capsule

-- The largest distance the ball is allowed to travel between two collision
-- checks. Everything it can hit is at least PADDLE_H = 5 px thick in the
-- direction it is thin, so anything below that cannot be passed through.
local SUBSTEP = 1.5

-- A ball whose path is too flat rallies along a brick row forever and the
-- player can only watch. Every bounce is therefore re-angled to keep at least
-- this fraction of the speed pointing up or down, which bounds how long the
-- ball can go without meeting the paddle or the ceiling.
local MIN_VY_FRAC = 0.34
local MAX_BOUNCE  = 1.0472    -- radians (60 degrees) off vertical at the paddle rim

local BULLET_SPEED = 6.0
local BULLET_W, BULLET_H = 2, 6
local LASER_COOLDOWN = 6      -- frames between shots

local CAPSULE_W, CAPSULE_H = 18, 10  -- big enough to carry a readable letter
local CAPSULE_FALL   = 1.6    -- px/frame
local CAPSULE_CHANCE = 14     -- percent of broken bricks that drop one
local MAX_CAPSULES   = 3      -- on screen at once
local MAX_BALLS      = 3

local START_LIVES = 3
local MAX_LIVES   = 6
-- Catch holds the ball until the player shoots it off, which is the whole
-- point of the capsule -- but a held ball is a stopped game, so it also lets
-- go on its own after two seconds rather than waiting forever for a player who
-- has not realised the ball is theirs to release.
local CATCH_HOLD  = 40        -- frames the Catch capsule will hold a ball
local CAPSULE_SCORE = 100
local LEVEL_BONUS   = 500     -- x level, for clearing

-- ====================================================================== --
--                       end of tuning constants                          --
-- ====================================================================== --

Arkanoid.COLS        = COLS
Arkanoid.MAX_ROWS    = MAX_ROWS
Arkanoid.WALL        = WALL
Arkanoid.BRICK_H     = BRICK_H
Arkanoid.TOP_GAP     = TOP_GAP
Arkanoid.BALL_SIZE   = BALL_SIZE
Arkanoid.PADDLE_H    = PADDLE_H
Arkanoid.PADDLE_W    = PADDLE_W
Arkanoid.PADDLE_W_WIDE = PADDLE_W_WIDE
Arkanoid.SPEED_MAX   = SPEED_MAX
Arkanoid.MIN_VY_FRAC = MIN_VY_FRAC
Arkanoid.SUBSTEP     = SUBSTEP
Arkanoid.MAX_BALLS   = MAX_BALLS
Arkanoid.MAX_CAPSULES = MAX_CAPSULES
Arkanoid.START_LIVES = START_LIVES
Arkanoid.CAPSULE_W   = CAPSULE_W
Arkanoid.CAPSULE_H   = CAPSULE_H
Arkanoid.BULLET_W    = BULLET_W
Arkanoid.BULLET_H    = BULLET_H

-- Brick colours, in the order the score table below runs. main.lua turns these
-- indices into ink; nothing in here knows what colour 3 looks like.
local COLOR_SCORE = { 50, 60, 70, 80, 90, 100, 110, 120 }
Arkanoid.COLOR_SCORE = COLOR_SCORE
Arkanoid.COLORS = #COLOR_SCORE

-- Level source characters. Lower case is a plain one-hit brick in the colour
-- of that name; `s` is silver (several hits), `G` is gold (indestructible).
local CHAR_COLOR = { w = 1, o = 2, c = 3, g = 4, r = 5, b = 6, m = 7, y = 8 }

-- The capsule kinds, and how often each is picked relative to the others.
-- Weighted rather than uniform because Extra Life has to stay rare enough to
-- matter and Split has to stay common enough to be the reason you take risks.
local CAPSULES = {
  { kind = "wide",  weight = 20 },
  { kind = "catch", weight = 16 },
  { kind = "laser", weight = 18 },
  { kind = "slow",  weight = 14 },
  { kind = "split", weight = 22 },
  { kind = "life",  weight = 6  },
}
Arkanoid.CAPSULES = CAPSULES

local CAPSULE_TOTAL = 0
for _, c in ipairs(CAPSULES) do CAPSULE_TOTAL = CAPSULE_TOTAL + c.weight end

-- ------------------------------------------------------------------ RNG -- --
--
-- math.randomseed does nothing on the handheld: it returns without complaint
-- and math.random then replays one sequence from launch to launch, so a seeded
-- game deals the identical level and the identical capsules every time the
-- document is opened. `os` is not there to fall back on either. So the game
-- owns its generator, exactly as Slide, Wordle and Fruits do.
--
-- MINSTD, in plain arithmetic: there are no bitwise operators in this Lua and
-- 16807 * 2147483646 is about 3.6e13, comfortably inside a double's exact
-- integer range, so every intermediate below is exact.

local RAND_A, RAND_M = 16807, 2147483647

function Arkanoid.newRandom(seed)
  local s = floor(tonumber(seed) or 1) % RAND_M
  if s <= 0 then s = 1 end

  -- Two launches of the same document differ by only a handful of idle ticks,
  -- and a raw LCG from a small seed returns a small first value -- scaled to a
  -- level number or a capsule kind, seeds 1..10 would all choose the same
  -- thing. Scramble, then warm up, so neighbouring seeds diverge immediately.
  s = (s * 48271) % RAND_M
  if s <= 0 then s = 1 end
  for _ = 1, 6 do s = (RAND_A * s) % RAND_M end

  return function(n)
    s = (RAND_A * s) % RAND_M
    if not n or n < 1 then return s / RAND_M end
    -- Taken from the top of the range rather than by a modulo: an LCG's low
    -- bits are its weakest, and a capsule roll draws from n = 100 several
    -- times a second.
    local v = floor(s / RAND_M * n) + 1
    if v > n then v = n end
    return v
  end
end

-- Folds a value into an accumulating seed. The host calls this for every tick,
-- key and click it sees, so that the seed play starts from is not a constant.
function Arkanoid.mix(acc, value)
  return ((acc or 1) * 31 + floor(tonumber(value) or 0)) % RAND_M
end

-- --------------------------------------------------------------- levels -- --
--
-- Eight hand-drawn levels, then generated ones for as long as anybody keeps
-- playing. Both have to satisfy one property: EVERY DESTRUCTIBLE BRICK MUST BE
-- REACHABLE. Gold bricks never break, so a ring of them seals whatever is
-- inside it and the level can never be finished -- and nothing on screen says
-- so, which is the same trap an unsolvable sliding puzzle sets. The player
-- would grind a perfect run into a board that was never winnable.
--
-- As in src/slide/game.lua the answer is not to filter bad levels out but to
-- make them unrepresentable. Sealing a region requires a closed barrier of
-- gold, and a barrier is a chain of cells each touching the next -- including
-- diagonally, since two diagonal blockers already sever a 4-connected path. So
-- gold is only ever placed on the sublattice
--
--     row even  AND  column = 1 (mod 3)
--
-- whose members are two rows or three columns apart and therefore can never
-- touch. Every 8-connected component of gold is a single cell, a single cell
-- cannot enclose anything, and so no subset of that sublattice can seal a
-- brick in. There is nothing to check and nothing to reject.
--
-- Row 1 is never on the sublattice (it is odd) and every generated pattern
-- fills it, so a generated level always has at least one breakable brick.
--
-- `Arkanoid.isClearable` below then implements the test the generator was
-- built not to need, and nothing in the game ever calls it: it floods the grid
-- from underneath and asks whether every destructible brick was reached. Two
-- mechanisms sharing no code, which have to agree.

local LEVELS = {
  -- 1. Warm-up: solid bands, nothing to think about.
  {
    "rrrrrrrrrrrrr",
    "ooooooooooooo",
    "yyyyyyyyyyyyy",
    "ggggggggggggg",
  },
  -- 2. Comb: the gaps make the ball's angle matter for the first time.
  {
    "bbbbbbbbbbbbb",
    "m.m.m.m.m.m.m",
    "y.y.y.y.y.y.y",
    "g.g.g.g.g.g.g",
    "ccccccccccccc",
  },
  -- 3. Pyramid, with a silver course through the middle.
  {
    "wwwwwwwwwwwww",
    ".ooooooooooo.",
    "..sssssssss..",
    "...ggggggg...",
    "....rrrrr....",
    ".....yyy.....",
    "......b......",
  },
  -- 4. Fortress: no gold at all, but you have to break in.
  {
    "ccccccccccccc",
    "m...........m",
    "m.rrrrrrrrr.m",
    "m.r.......r.m",
    "m.r.sssss.r.m",
    "m.r.......r.m",
    "m.rrrrrrrrr.m",
    "mmmmmmmmmmmmm",
  },
  -- 5. Rivets: the first gold, spaced on the sublattice.
  {
    "yyyyyyyyyyyyy",
    "ooooooooooooo",
    "G..G..G..G..G",
    "rrrrrrrrrrrrr",
    "G..G..G..G..G",
    "bbbbbbbbbbbbb",
  },
  -- 6. Chequer, on a silver roof.
  {
    "sssssssssssss",
    "w.w.w.w.w.w.w",
    ".c.c.c.c.c.c.",
    "m.m.m.m.m.m.m",
    ".b.b.b.b.b.b.",
  },
  -- 7. Arch.
  {
    "mmmmmmmmmmmmm",
    "ooooooooooooo",
    "ss.........ss",
    "y.G.......G.y",
    "yy.........yy",
    "rrr.......rrr",
    "rrrrr...rrrrr",
    "ccccccccccccc",
  },
  -- 8. Sandwich: two silver slabs either side of a gold seam.
  {
    "wwwwwwwwwwwww",
    "sssssssssssss",
    "G.G.G.G.G.G.G",
    "rrrrrrrrrrrrr",
    "yyyyyyyyyyyyy",
  },
}

Arkanoid.LEVELS = LEVELS
Arkanoid.AUTHORED = #LEVELS

-- How many hits a silver brick takes. Grows with the level, as in the original.
function Arkanoid.silverHP(level)
  return 2 + floor((level - 1) / 8)
end

local function newBrick(kind, color, hp)
  return { kind = kind, color = color, hp = hp }
end

-- Turns one level's rows of characters into a grid of bricks.
local function gridFromRows(rows, level)
  local grid = { rows = min(#rows, MAX_ROWS), cols = COLS }
  local silver = Arkanoid.silverHP(level)
  for r = 1, grid.rows do
    grid[r] = {}
    local line = rows[r]
    for c = 1, COLS do
      local ch = string.sub(line, c, c)
      if ch == "G" then
        grid[r][c] = newBrick("gold", 0, -1)
      elseif ch == "s" then
        grid[r][c] = newBrick("silver", 0, silver)
      elseif CHAR_COLOR[ch] then
        grid[r][c] = newBrick("normal", CHAR_COLOR[ch], 1)
      else
        grid[r][c] = false
      end
    end
  end
  return grid
end

-- The five generated shapes. Each is a predicate on (row, column) and each
-- fills row 1 completely, which is what guarantees a generated level always
-- holds a breakable brick however the gold falls.
local FAMILIES = {
  function(r, c, rows) return true end,                                   -- bands
  function(r, c, rows) return r == 1 or c % 2 == 1 end,                   -- comb
  function(r, c, rows) return r == 1 or (c > r - 1 and c <= COLS - r + 1) end, -- pyramid
  function(r, c, rows)                                                    -- arch
    local mid = ceil(COLS / 2)
    return r == 1 or c <= mid - r or c >= mid + r
  end,
  function(r, c, rows)                                                    -- stagger
    local inset = floor((r - 1) / 2)
    return r == 1 or (c > inset and c <= COLS - inset)
  end,
}
Arkanoid.FAMILIES = #FAMILIES

-- A gold cell may only ever sit here. See the note above: no two members of
-- this set are 8-adjacent, so no subset of it can enclose anything.
function Arkanoid.goldAllowed(r, c)
  return r % 2 == 0 and c % 3 == 1
end

function Arkanoid.generateLevel(level, rand)
  local rows = 5 + ((level - 1) % 4)
  local shape = FAMILIES[rand(#FAMILIES)]
  local silver = Arkanoid.silverHP(level)
  local silverPct = min(30, 4 + level)
  local goldPct   = min(70, 15 + level * 3)

  local grid = { rows = rows, cols = COLS }
  for r = 1, rows do
    grid[r] = {}
    local color = ((r - 1 + level) % #COLOR_SCORE) + 1
    for c = 1, COLS do
      if not shape(r, c, rows) then
        grid[r][c] = false
      elseif Arkanoid.goldAllowed(r, c) and rand(100) <= goldPct then
        grid[r][c] = newBrick("gold", 0, -1)
      elseif r > 1 and rand(100) <= silverPct then
        grid[r][c] = newBrick("silver", 0, silver)
      else
        grid[r][c] = newBrick("normal", color, 1)
      end
    end
  end
  return grid
end

function Arkanoid.buildLevel(level, rand)
  if level <= #LEVELS then return gridFromRows(LEVELS[level], level) end
  return Arkanoid.generateLevel(level, rand)
end

-- ---------------------------------------------------------------- oracle -- --
--
-- Never called by the game. The generator above is built so this cannot fail;
-- tests/arkanoid/run.lua runs it over every authored level and thousands of
-- generated ones, so that two mechanisms sharing no code have to agree.
--
-- The brick field spans the whole interior, wall to wall, so the only way in
-- is from below: the flood starts under the bottom row and spreads through any
-- cell that is not gold, because a destructible brick opens its own cell as
-- soon as it is hit. A level is clearable when it holds at least one
-- destructible brick and every one of them was reached.
function Arkanoid.isClearable(grid)
  local rows, cols = grid.rows, grid.cols or COLS
  local seen, queue, head = {}, {}, 1

  local function push(r, c)
    if r < 1 or r > rows or c < 1 or c > cols then return end
    local key = r * 100 + c
    if seen[key] then return end
    local b = grid[r][c]
    if b and b.kind == "gold" then return end
    seen[key] = true
    queue[#queue + 1] = { r, c }
  end

  for c = 1, cols do push(rows, c) end   -- the row the ball arrives at first

  while head <= #queue do
    local cell = queue[head]; head = head + 1
    local r, c = cell[1], cell[2]
    push(r - 1, c); push(r + 1, c); push(r, c - 1); push(r, c + 1)
  end

  local destructible, reached = 0, 0
  for r = 1, rows do
    for c = 1, cols do
      local b = grid[r][c]
      if b and b.kind ~= "gold" then
        destructible = destructible + 1
        if seen[r * 100 + c] then reached = reached + 1 end
      end
    end
  end
  return destructible > 0 and destructible == reached, destructible, reached
end

-- ------------------------------------------------------------- lifecycle -- --

-- w, h: the playfield in pixels, HUD already excluded by the caller.
-- opts.rand: function(n) -> integer in [1, n]. Injectable, so tests are
--            deterministic and so the host can hand in a generator it owns
--            rather than math.random, which cannot be reseeded on hardware.
function Arkanoid.new(w, h, opts)
  opts = opts or {}
  local self = setmetatable({}, Arkanoid)
  self.rand = opts.rand or function(n) return math.random(n) end
  self.highScore = opts.highScore or 0
  self:setSize(w or 318, h or 192)
  self:reset(opts.level or 1)
  return self
end

-- Works out the geometry for a playfield of this size. The handheld is always
-- 318x192 and everything below lands on its natural value there; the computer
-- software can be dragged to any size at all, so every dimension degrades
-- rather than being assumed to fit.
function Arkanoid:setSize(w, h)
  self.w, self.h = w, h

  self.wall = min(WALL, max(1, floor(w / 12)))
  local interior = max(COLS, w - 2 * self.wall)

  self.brickW = max(2, floor(interior / COLS))
  self.fieldX = self.wall + floor((interior - self.brickW * COLS) / 2)
  self.fieldW = self.brickW * COLS

  self.padBottom = min(PADDLE_BOTTOM, max(3, floor(h * 0.09)))
  self.padH = min(PADDLE_H, max(2, floor(h / 30)))
  self.padY = h - self.padBottom - self.padH

  self.fieldY = self.wall + min(TOP_GAP, max(1, floor(h / 24)))

  -- The bricks get whatever is left once the ball has somewhere to play. Below
  -- about a third of the window the field is squeezed instead of the rally.
  local playRoom = max(18, floor(h * 0.30))
  local room = self.padY - self.fieldY - playRoom
  self.brickH = max(2, min(BRICK_H, floor(room / MAX_ROWS)))

  self.ballSize = max(2, min(BALL_SIZE, floor(min(w, h) / 40)))
  self.baseW = max(10, min(PADDLE_W, floor(interior / 6)))
  self.wideW = max(self.baseW + 4, min(PADDLE_W_WIDE, floor(interior / 4)))
end

function Arkanoid:left()  return self.wall end
function Arkanoid:right() return self.w - self.wall end
function Arkanoid:top()   return self.wall end

function Arkanoid:paddleWidth()
  return self.power == "wide" and self.wideW or self.baseW
end

-- Resets everything and deals level `level`. A round is one document session:
-- the high score outlives it, nothing else does.
function Arkanoid:reset(level)
  self.level = level or 1
  self.score = 0
  self.lives = START_LIVES
  self.frame = 0
  self.state = "ready"          -- ready|serve|playing|paused|cleared|over
  self.paddle = { x = 0, vx = 0, dir = 0, drive = 0, target = nil, w = self.baseW }
  self:clearPowers()
  self:loadLevel(self.level)
end

function Arkanoid:clearPowers()
  self.power = nil              -- nil | "wide" | "laser" | "catch"
  self.slow = false
  self.cooldown = 0
  self.paddle.w = self:paddleWidth()
end

function Arkanoid:loadLevel(level)
  self.level = level
  self.bricks = Arkanoid.buildLevel(level, self.rand)
  self.rows = self.bricks.rows
  self.remaining = 0
  for r = 1, self.rows do
    for c = 1, COLS do
      local b = self.bricks[r][c]
      if b and b.kind ~= "gold" then self.remaining = self.remaining + 1 end
    end
  end
  self.startRemaining = self.remaining
  self.capsules = {}
  self.bullets = {}
  self.hits = 0
  self.topHit = false
  self:serve()
end

-- Parks a fresh ball on the paddle and waits. Also where a lost life returns
-- to, which is why it re-centres the paddle: coming back with the paddle
-- wherever it died reads as the game moving on its own.
function Arkanoid:serve()
  local p = self.paddle
  p.w = self:paddleWidth()
  p.x = floor((self.w - p.w) / 2)
  p.vx, p.dir, p.drive, p.target = 0, 0, 0, nil

  self.balls = { {
    x = p.x + p.w / 2 - self.ballSize / 2,
    y = self.padY - self.ballSize,
    vx = 0, vy = 0,
    stuck = true,
    stuckOff = p.w / 2 - self.ballSize / 2,
    hold = 0,
  } }
  self.topHit = false
  if self.state ~= "ready" and self.state ~= "over" then self.state = "serve" end
end

function Arkanoid:isOver() return self.state == "over" end

function Arkanoid:recordScore()
  if self.score > self.highScore then self.highScore = self.score end
end

-- ---------------------------------------------------------------- speed -- --

-- What the ball should be travelling at right now. Recomputed every frame
-- rather than stored on the ball, so a capsule or a level change takes effect
-- without having to find and rewrite every ball in flight.
function Arkanoid:speed()
  local sp = SPEED_BASE
    + (self.level - 1) * SPEED_PER_LEVEL
    + min(self.hits * SPEED_PER_HIT, SPEED_HIT_CAP)
  if self.topHit then sp = sp + SPEED_TOP_BONUS end
  if self.startRemaining > 0 and self.remaining * 3 <= self.startRemaining then
    sp = sp + SPEED_MAX_ROW
  end
  if self.slow then sp = sp * SLOW_FACTOR end
  return min(sp, SPEED_MAX)
end

local function setSpeed(b, sp)
  local m = sqrt(b.vx * b.vx + b.vy * b.vy)
  if m > 1e-9 then
    b.vx, b.vy = b.vx / m * sp, b.vy / m * sp
  end
end

-- Keeps the trajectory steep enough to make progress. A ball skimming along a
-- brick row at two degrees is not a rally, it is a hang: the player has no
-- input that changes it and nothing on screen explains why. Applied after
-- every bounce, and it preserves the speed exactly -- only the angle moves.
local function steepen(b)
  local sp = sqrt(b.vx * b.vx + b.vy * b.vy)
  if sp < 1e-9 then return end
  local wantY = MIN_VY_FRAC * sp
  if abs(b.vy) < wantY then
    b.vy = (b.vy < 0) and -wantY or wantY
    local rest = sp * sp - b.vy * b.vy
    b.vx = (b.vx < 0 and -1 or 1) * sqrt(max(0, rest))
  end
end
Arkanoid.steepen = steepen

-- ------------------------------------------------------------ geometry -- --

function Arkanoid:brickX(c) return self.fieldX + (c - 1) * self.brickW end
function Arkanoid:brickY(r) return self.fieldY + (r - 1) * self.brickH end

function Arkanoid:brickAt(r, c)
  local row = self.bricks[r]
  return row and row[c] or nil
end

function Arkanoid:paddleRect()
  return self.paddle.x, self.padY, self.paddle.w, self.padH
end

function Arkanoid:ballRect(b)
  return b.x, b.y, self.ballSize, self.ballSize
end

local function overlap(ax, ay, aw, ah, bx, by, bw, bh)
  return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end
Arkanoid.overlap = overlap

-- The inclusive cell range a rectangle touches, already clamped to the grid.
function Arkanoid:cellRange(x, y, w, h)
  local c0 = floor((x - self.fieldX) / self.brickW) + 1
  local c1 = floor((x + w - self.fieldX) / self.brickW) + 1
  local r0 = floor((y - self.fieldY) / self.brickH) + 1
  local r1 = floor((y + h - self.fieldY) / self.brickH) + 1
  if c0 < 1 then c0 = 1 end
  if c1 > COLS then c1 = COLS end
  if r0 < 1 then r0 = 1 end
  if r1 > self.rows then r1 = self.rows end
  return r0, r1, c0, c1
end

-- Any brick this rectangle is inside, or nil. Returns the one furthest along
-- `dir` on `axis`, which is the surface a mover travelling that way met first.
function Arkanoid:brickUnder(x, y, w, h, axis, dir)
  local r0, r1, c0, c1 = self:cellRange(x, y, w, h)
  local bestR, bestC, bestKey
  for r = r0, r1 do
    for c = c0, c1 do
      local br = self.bricks[r] and self.bricks[r][c]
      if br and overlap(x, y, w, h,
                        self:brickX(c), self:brickY(r), self.brickW, self.brickH) then
        local key
        if axis == "x" then key = (dir > 0) and -c or c
        else key = (dir > 0) and -r or r end
        if not bestKey or key > bestKey then bestKey, bestR, bestC = key, r, c end
      end
    end
  end
  if bestR then return bestR, bestC end
  return nil
end

-- --------------------------------------------------------------- bricks -- --

-- One hit on (r, c). Returns true if the brick broke.
function Arkanoid:hitBrick(r, c)
  local b = self.bricks[r][c]
  if not b then return false end
  self.hits = self.hits + 1
  if b.kind == "gold" then return false end

  b.hp = b.hp - 1
  if b.hp > 0 then
    self.score = self.score + 10          -- a dent still pays something
    return false
  end

  if b.kind == "silver" then
    self.score = self.score + 50 * self.level
  else
    self.score = self.score + (COLOR_SCORE[b.color] or 50)
  end
  self.bricks[r][c] = false
  self.remaining = self.remaining - 1
  self:maybeDrop(r, c)
  return true
end

function Arkanoid:maybeDrop(r, c)
  if #self.capsules >= MAX_CAPSULES then return end
  if self.rand(100) > CAPSULE_CHANCE then return end

  local roll, acc = self.rand(CAPSULE_TOTAL), 0
  for _, spec in ipairs(CAPSULES) do
    acc = acc + spec.weight
    if roll <= acc then
      self.capsules[#self.capsules + 1] = {
        kind = spec.kind,
        x = self:brickX(c) + self.brickW / 2 - CAPSULE_W / 2,
        y = self:brickY(r),
      }
      return
    end
  end
end

function Arkanoid:destructibleLeft()
  return self.remaining
end

-- ----------------------------------------------------------- ball motion -- --

-- Moves one ball along a single axis by `d`, then makes sure it did not end up
-- inside anything.
--
-- This is where the game is either correct or not. The rule it enforces is
-- absolute: **a ball never ends a move overlapping a wall, a brick or the
-- paddle.** Resolution normally just backs the ball out to the surface it hit,
-- but a ball wedged between two things -- the paddle sweeping it into a wall,
-- say -- can have nowhere legal within reach. Rather than let one frame of
-- that leak into the next and compound, the move is simply abandoned and the
-- ball is put back where it started, which the invariant says was legal.
function Arkanoid:moveAxis(b, d, axis)
  if d == 0 then return end
  local size = self.ballSize
  local prevX, prevY = b.x, b.y
  local dir = (d > 0) and 1 or -1

  if axis == "x" then b.x = b.x + d else b.y = b.y + d end

  local bounced = false
  local function flip()
    if bounced then return end
    bounced = true
    if axis == "x" then b.vx = -b.vx else b.vy = -b.vy end
  end

  -- Walls. The floor is not a wall: that is where a ball is lost.
  if axis == "x" then
    if b.x < self:left() then b.x = self:left(); flip()
    elseif b.x + size > self:right() then b.x = self:right() - size; flip() end
  else
    if b.y < self:top() then
      b.y = self:top()
      self.topHit = true          -- the 1986 speed-up trigger
      flip()
    elseif b.y > self.h then
      b.dead = true
      return
    end
  end

  -- The paddle, from above. A ball coming down onto it leaves at an angle set
  -- by where it landed, which is the whole control surface of the game: the
  -- paddle is not a mirror, it is a steering wheel.
  local px, py, pw, ph = self:paddleRect()
  if overlap(b.x, b.y, size, size, px, py, pw, ph) then
    if axis == "y" and dir > 0 then
      b.y = py - size
      self:bounceOffPaddle(b)
      bounced = true
    elseif axis == "y" then
      b.y = py + ph
      flip()
    else
      -- Caught the rim on the way past. Push out the near side rather than
      -- through the paddle, so a fast paddle shoves the ball instead of
      -- swallowing it.
      if (b.x + size / 2) < (px + pw / 2) then b.x = px - size else b.x = px + pw end
      flip()
    end
  end

  -- Bricks. At most a couple of passes: each one backs the ball out along the
  -- axis it came in on, so it is monotonically retreating and must stop.
  for _ = 1, 4 do
    local r, c = self:brickUnder(b.x, b.y, size, size, axis, dir)
    if not r then break end
    if axis == "x" then
      b.x = (dir > 0) and (self:brickX(c) - size) or (self:brickX(c) + self.brickW)
    else
      b.y = (dir > 0) and (self:brickY(r) - size) or (self:brickY(r) + self.brickH)
    end
    flip()
    self:hitBrick(r, c)
  end

  -- Last resort, and the reason the invariant holds unconditionally.
  if self:ballStuck(b) then
    b.x, b.y = prevX, prevY
    flip()
  end

  if bounced then steepen(b) end
end

-- True if the ball is overlapping anything solid where it now stands.
function Arkanoid:ballStuck(b)
  local size = self.ballSize
  if b.x < self:left() or b.x + size > self:right() or b.y < self:top() then
    return true
  end
  local px, py, pw, ph = self:paddleRect()
  if overlap(b.x, b.y, size, size, px, py, pw, ph) then return true end
  return self:brickUnder(b.x, b.y, size, size, "y", 1) ~= nil
end

function Arkanoid:bounceOffPaddle(b)
  local px, _, pw = self:paddleRect()
  local sp = self:speed()

  -- Where on the paddle, as -1 (left rim) to +1 (right rim).
  local off = ((b.x + self.ballSize / 2) - (px + pw / 2)) / (pw / 2)
  if off < -1 then off = -1 elseif off > 1 then off = 1 end

  local ang = off * MAX_BOUNCE
  b.vx = sp * math.sin(ang)
  b.vy = -sp * math.cos(ang)

  if self.power == "catch" and b.hold == 0 then
    b.stuck = true
    b.stuckOff = (b.x - px)
    b.hold = CATCH_HOLD
    b.vx, b.vy = 0, 0
  end
end

-- One frame of motion for one ball, cut into pieces small enough that nothing
-- can be jumped over. SUBSTEP is below the thinnest thing in the game, so the
-- ball is checked against the world at least once inside every obstacle it
-- passes through -- which is what makes tunnelling impossible rather than
-- unlikely. The axes are moved separately because the surface a corner-on hit
-- should bounce off is otherwise ambiguous, and a wrong guess there is a ball
-- that reflects the wrong way once in a hundred hits and looks like a bug.
function Arkanoid:stepBall(b)
  setSpeed(b, self:speed())
  local far = max(abs(b.vx), abs(b.vy))
  local parts = max(1, ceil(far / SUBSTEP))
  for _ = 1, parts do
    self:moveAxis(b, b.vx / parts, "x")
    if b.dead then return end
    self:moveAxis(b, b.vy / parts, "y")
    if b.dead then return end
  end
end

-- --------------------------------------------------------------- paddle -- --

function Arkanoid:stepPaddle()
  local p = self.paddle
  p.w = self:paddleWidth()

  local ax = 0
  if p.target then
    local cx = p.x + p.w / 2
    local d = p.target - cx
    if abs(d) <= PADDLE_SNAP then
      p.target, p.vx = nil, 0
    else
      ax = (d > 0 and 1 or -1) * PADDLE_ACCEL
      -- Ease off near the target instead of sailing past it and hunting.
      if abs(d) < abs(p.vx) * 3 then ax = -ax end
    end
  elseif p.drive > 0 then
    p.drive = p.drive - 1
    ax = p.dir * PADDLE_ACCEL
  end

  if ax ~= 0 then
    p.vx = p.vx + ax
  else
    p.vx = p.vx * PADDLE_FRICTION
    if abs(p.vx) < 0.05 then p.vx = 0 end
  end
  if p.vx > PADDLE_MAX then p.vx = PADDLE_MAX
  elseif p.vx < -PADDLE_MAX then p.vx = -PADDLE_MAX end

  p.x = p.x + p.vx
  if p.x < self:left() then p.x, p.vx, p.target = self:left(), 0, nil
  elseif p.x + p.w > self:right() then
    p.x, p.vx, p.target = self:right() - p.w, 0, nil
  end

  -- A paddle that has just swept sideways can be standing on a ball. Move the
  -- ball, not the paddle: the player asked for the paddle to be there.
  local size = self.ballSize
  for _, b in ipairs(self.balls) do
    if not b.stuck and overlap(b.x, b.y, size, size, p.x, self.padY, p.w, self.padH) then
      if b.y + size / 2 <= self.padY + self.padH / 2 then
        b.y = self.padY - size
        if b.vy > 0 then self:bounceOffPaddle(b) end
      else
        b.x = (p.vx > 0) and (p.x + p.w) or (p.x - size)
        if b.x < self:left() then b.x = self:left() end
        if b.x + size > self:right() then b.x = self:right() - size end
      end
    end
  end

  -- Balls held on the paddle ride along with it.
  for _, b in ipairs(self.balls) do
    if b.stuck then
      b.x = p.x + b.stuckOff
      if b.x < self:left() then b.x = self:left() end
      if b.x + size > self:right() then b.x = self:right() - size end
      b.y = self.padY - size
      if b.hold > 0 then
        b.hold = b.hold - 1
        if b.hold == 0 then self:launch() end
      end
    end
  end
end

-- ------------------------------------------------------ bullets, capsules -- --

function Arkanoid:stepBullets()
  local kept = {}
  for _, s in ipairs(self.bullets) do
    local parts = max(1, ceil(BULLET_SPEED / SUBSTEP))
    local alive = true
    for _ = 1, parts do
      s.y = s.y - BULLET_SPEED / parts
      if s.y < self:top() then alive = false break end
      local r, c = self:brickUnder(s.x, s.y, BULLET_W, BULLET_H, "y", -1)
      if r then
        self:hitBrick(r, c)
        alive = false
        break
      end
    end
    if alive then kept[#kept + 1] = s end
  end
  self.bullets = kept
  if self.cooldown > 0 then self.cooldown = self.cooldown - 1 end
end

function Arkanoid:stepCapsules()
  local kept = {}
  local px, py, pw, ph = self:paddleRect()
  for _, cap in ipairs(self.capsules) do
    cap.y = cap.y + CAPSULE_FALL
    if overlap(cap.x, cap.y, CAPSULE_W, CAPSULE_H, px, py, pw, ph) then
      self:applyCapsule(cap.kind)
    elseif cap.y < self.h then
      kept[#kept + 1] = cap
    end
  end
  self.capsules = kept
end

function Arkanoid:applyCapsule(kind)
  self.score = self.score + CAPSULE_SCORE

  if kind == "life" then
    if self.lives < MAX_LIVES then self.lives = self.lives + 1 end
    return
  end

  if kind == "slow" then
    self.slow = true
    return
  end

  if kind == "split" then
    self:splitBalls()
    return
  end

  -- Wide, Laser and Catch are the same slot: taking one drops the last, which
  -- is what makes choosing which capsule to run for a decision.
  local was = self.power
  self.power = kind
  self.paddle.w = self:paddleWidth()

  -- Grow or shrink about the centre, so the paddle does not appear to jump
  -- sideways when a capsule lands, and never out through a wall.
  if was ~= kind then
    local p = self.paddle
    local oldW = (was == "wide") and self.wideW or self.baseW
    p.x = p.x - (p.w - oldW) / 2
    if p.x < self:left() then p.x = self:left() end
    if p.x + p.w > self:right() then p.x = self:right() - p.w end
  end

  if kind ~= "catch" then
    for _, b in ipairs(self.balls) do
      if b.stuck and self.state == "playing" then b.hold = 1 end
    end
  end
end

-- Splits every ball in two, up to the cap. The copies leave at a visible angle
-- from the original rather than alongside it, or a split reads as nothing
-- happening until the balls drift apart several seconds later.
function Arkanoid:splitBalls()
  local sp = self:speed()
  local extra = {}
  for _, b in ipairs(self.balls) do
    if #self.balls + #extra >= MAX_BALLS then break end
    local ang = math.atan2(b.vx, -b.vy)
    if b.stuck then ang = 0 end
    for _, turn in ipairs({ 0.45, -0.45 }) do
      if #self.balls + #extra < MAX_BALLS then
        local a = ang + turn
        local nb = {
          x = b.x, y = b.y,
          vx = sp * math.sin(a), vy = -sp * math.cos(a),
          stuck = false, stuckOff = 0, hold = 0,
        }
        steepen(nb)
        extra[#extra + 1] = nb
      end
    end
  end
  for _, b in ipairs(extra) do self.balls[#self.balls + 1] = b end
  -- A split releases whatever was being held, or the new balls fly off while
  -- the original sits on the paddle looking broken.
  self:launch()
end

-- ---------------------------------------------------------------- input -- --

-- dir is -1 or +1. Opens the drive window described at the top of the file.
function Arkanoid:steer(dir)
  if self.state ~= "playing" and self.state ~= "serve" then return false end
  local p = self.paddle
  p.dir = (dir < 0) and -1 or 1
  p.drive = PADDLE_DRIVE
  p.target = nil
  return true
end

-- Absolute aim, from a click or a touchpad tap: x is where the paddle's
-- CENTRE should end up. The paddle still accelerates there rather than
-- teleporting, so a click cannot rescue a ball the paddle could not have got to.
function Arkanoid:aim(x)
  if self.state ~= "playing" and self.state ~= "serve" then return false end
  local p = self.paddle
  p.target = x
  p.dir, p.drive = 0, 0
  return true
end

-- Releases every held ball. The serve leaves at a slight angle rather than
-- straight up, so the opening of a life is never identical to the last one.
function Arkanoid:launch()
  local sp = self:speed()
  local launched = false
  for _, b in ipairs(self.balls) do
    if b.stuck then
      local px, _, pw = self:paddleRect()
      local off = ((b.x + self.ballSize / 2) - (px + pw / 2)) / (pw / 2)
      if off < -1 then off = -1 elseif off > 1 then off = 1 end
      local ang = off * MAX_BOUNCE * 0.6
      if abs(ang) < 0.12 then
        ang = (self.rand(2) == 1 and -1 or 1) * (0.15 + self.rand(20) / 100)
      end
      b.vx, b.vy = sp * math.sin(ang), -sp * math.cos(ang)
      b.stuck, b.hold = false, 0
      steepen(b)
      launched = true
    end
  end
  if launched and self.state == "serve" then self.state = "playing" end
  return launched
end

-- The fire button: serves, releases a caught ball, or shoots.
function Arkanoid:fire()
  if self.state == "serve" then return self:launch() end
  if self.state ~= "playing" then return false end
  if self:launch() then return true end

  if self.power == "laser" and self.cooldown == 0 then
    local p = self.paddle
    self.cooldown = LASER_COOLDOWN
    for _, x in ipairs({ p.x + 2, p.x + p.w - 2 - BULLET_W }) do
      self.bullets[#self.bullets + 1] = { x = x, y = self.padY - BULLET_H }
    end
    return true
  end
  return false
end

function Arkanoid:pause()
  if self.state == "playing" or self.state == "serve" then
    self.paused = self.state
    self.state = "paused"
  end
end

function Arkanoid:resume()
  if self.state == "paused" then
    self.state = self.paused or "serve"
    self.paused = nil
  end
end

-- --------------------------------------------------------------- rounds -- --

function Arkanoid:loseLife()
  self.lives = self.lives - 1
  self.capsules = {}
  self.bullets = {}
  self.hits = 0
  self:clearPowers()
  if self.lives <= 0 then
    self.lives = 0
    self.state = "over"
    self:recordScore()
    self.balls = {}
  else
    self:serve()
    self.state = "serve"
  end
end

function Arkanoid:clearLevel()
  self.score = self.score + LEVEL_BONUS * self.level
  self.state = "cleared"
  self.balls = {}
  self.capsules = {}
  self.bullets = {}
  self:recordScore()
end

function Arkanoid:nextLevel()
  if self.state ~= "cleared" then return false end
  self:clearPowers()
  self:loadLevel(self.level + 1)
  self.state = "serve"
  return true
end

function Arkanoid:start()
  if self.state == "ready" then
    self.state = "serve"
    return true
  end
  return false
end

-- ----------------------------------------------------------------- step -- --

-- One fixed timestep. The host calls this once per timer tick and every
-- constant above is already per-frame, so a handheld whose timer is coarser
-- than 0.05 s runs the whole game proportionally slower -- a fair fight, and
-- never a skipped collision.
function Arkanoid:step()
  if self.state == "serve" then
    self.frame = self.frame + 1
    self:stepPaddle()
    return
  end
  if self.state ~= "playing" then return end
  self.frame = self.frame + 1

  self:stepPaddle()
  self:stepBullets()
  self:stepCapsules()

  local alive = {}
  for _, b in ipairs(self.balls) do
    if not b.stuck then self:stepBall(b) end
    if not b.dead then alive[#alive + 1] = b end
  end
  self.balls = alive

  -- Clearing the level beats losing the last ball in the same frame: the
  -- bricks were already gone when the ball went past the paddle.
  if self.remaining <= 0 then
    self:clearLevel()
  elseif #self.balls == 0 then
    self:loseLife()
  end
end

return Arkanoid
