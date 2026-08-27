-- flappy.lua -- pure Flappy Bird game logic.
--
-- Like src/game.lua (Snake), this module deliberately knows nothing about the
-- TI-Nspire: no `platform`, no `gc`, no `timer`. It runs under a plain Lua 5.1
-- on a laptop, so the rules can be tested without a calculator. Drawing and
-- input live in src/flappy_main.lua.
--
-- Snake is grid-stepped: it moves a whole cell at a time, so a position is
-- always an integer. Flappy is continuous -- the bird accelerates, and the
-- world scrolls past it. Everything here is therefore in *pixels and frames*,
-- with sub-pixel positions kept as floats. `Flappy:step()` advances exactly one
-- fixed timestep; nothing in this module ever rounds. The renderer floors
-- coordinates at the moment it draws, and only there, so the physics never
-- accumulates rounding error and a replay from the same seed is identical.

local Flappy = {}
Flappy.__index = Flappy

-- ====================================================================== --
--                          TUNING CONSTANTS                              --
--                                                                        --
--  Everything that decides how the game *feels* is in this block, and    --
--  nowhere else. Change a number here and the rest of the file --        --
--  including the guarantee that every pipe gap is reachable from the     --
--  one before it -- re-derives itself from the new value.                --
--                                                                        --
--  Units: pixels, and frames of the host timer. The Nspire's timer       --
--  bottoms out around 0.05 s, so a frame is 1/20 s and no faster.        --
-- ====================================================================== --

-- How far the world slides left each frame. Keep this a WHOLE NUMBER: at
-- 20 FPS the eye reads a fractional scroll as a stutter, because the pipes
-- land on a different pixel column on some frames and not others.
local SCROLL_SPEED = 2      -- px/frame  (= 40 px/s, ~8 s to cross the screen)

-- Bird physics. FLAP_IMPULSE is a velocity the flap *sets*, not adds, which
-- is what makes the control feel crisp rather than mushy when you tap fast.
local GRAVITY      = 0.6    -- px/frame^2
local FLAP_IMPULSE = -4.2   -- px/frame, negative is up
local MAX_FALL     = 7.0    -- px/frame terminal velocity

-- Pipes.
local PIPE_W       = 16     -- px wide
local PIPE_SPACING = 96     -- px between one pipe's left edge and the next.
                            -- Also sets the rhythm: at SCROLL_SPEED this is
                            -- 48 frames, ~2.4 s, and about 3 pipes on screen.
local GAP_START    = 50     -- px of opening, at score 0
local GAP_MIN      = 40     -- px -- never tighter than this
local GAP_SHRINK   = 2      -- px the gap loses ...
local PIPES_PER_SHRINK = 5  -- ... every this many pipes cleared

-- The bird sits at a fixed x; the world moves instead.
local BIRD_X       = 58     -- px from the left edge of the playfield
local BIRD_W       = 12
local BIRD_H       = 9

local GROUND_H     = 12     -- px of ground strip; its top is lethal
local EDGE_MARGIN  = 12     -- px of sky/ground a gap never encroaches on

-- Safety factors for the reachability guarantee (see reachSpan below).
-- RESERVE holds frames back so the bird arrives at the new gap able to hold
-- the line, rather than still hurtling toward it; SAFETY then keeps the
-- generator well inside even that.
local REACH_RESERVE = 4     -- frames
local REACH_SAFETY  = 0.75  -- fraction of the remaining travel to actually use

-- ====================================================================== --
--                       end of tuning constants                          --
-- ====================================================================== --

Flappy.SCROLL_SPEED = SCROLL_SPEED
Flappy.GRAVITY      = GRAVITY
Flappy.FLAP_IMPULSE = FLAP_IMPULSE
Flappy.MAX_FALL     = MAX_FALL
Flappy.PIPE_W       = PIPE_W
Flappy.PIPE_SPACING = PIPE_SPACING
Flappy.GAP_START    = GAP_START
Flappy.GAP_MIN      = GAP_MIN
Flappy.GAP_SHRINK   = GAP_SHRINK
Flappy.PIPES_PER_SHRINK = PIPES_PER_SHRINK
Flappy.BIRD_X       = BIRD_X
Flappy.BIRD_W       = BIRD_W
Flappy.BIRD_H       = BIRD_H
Flappy.GROUND_H     = GROUND_H
Flappy.EDGE_MARGIN  = EDGE_MARGIN

-- ----------------------------------------------------- reachability ----- --
--
-- The one property a generated pipe course has to have: whatever gap the
-- player just flew through, the next one must be flyable from it. Picking
-- gap heights uniformly at random does *not* give you that -- a low gap
-- followed by a high one is simply impossible past some distance, and the
-- player loses to the generator rather than to their own thumbs.
--
-- So the generator is fenced by the physics above. These two helpers ask what
-- the constants actually permit, by simulating the two extreme control
-- policies over the frames available between one pipe and the next.

-- Frames the bird has between clearing one pipe's trailing edge and meeting
-- the next pipe's leading edge.
local TRAVEL_FRAMES = math.floor((PIPE_SPACING - PIPE_W) / SCROLL_SPEED)

-- Furthest the bird can climb in `frames`, flapping on every one of them.
-- The flap *sets* velocity, so where the bird was heading beforehand does not
-- matter: after the first flap it is climbing at FLAP_IMPULSE + GRAVITY.
local function maxClimb(frames)
  local y, v = 0, 0
  for _ = 1, frames do
    v = FLAP_IMPULSE + GRAVITY
    y = y + v
  end
  return -y
end

-- Furthest the bird can fall in `frames`, never flapping. The worst case for
-- *descending* is entering the window climbing as hard as possible, so that
-- is where this starts: it has to spend frames killing that upward velocity.
local function maxDrop(frames)
  local y, v = 0, FLAP_IMPULSE + GRAVITY
  for _ = 1, frames do
    v = v + GRAVITY
    if v > MAX_FALL then v = MAX_FALL end
    y = y + v
  end
  return y
end

local USABLE_FRAMES = math.max(1, TRAVEL_FRAMES - REACH_RESERVE)
local REACH_CLIMB = maxClimb(USABLE_FRAMES) * REACH_SAFETY
local REACH_DROP  = maxDrop(USABLE_FRAMES) * REACH_SAFETY

Flappy.TRAVEL_FRAMES = TRAVEL_FRAMES
Flappy.REACH_CLIMB   = REACH_CLIMB
Flappy.REACH_DROP    = REACH_DROP

-- ------------------------------------------------------------ lifecycle -- --

-- w, h: playfield size in pixels (the HUD is already excluded by the caller).
-- opts.rand:      function(n) -> integer in [1, n]. Injectable for tests.
-- opts.highScore: carried across rounds.
function Flappy.new(w, h, opts)
  opts = opts or {}
  local self = setmetatable({}, Flappy)
  self.w = w
  self.h = h
  self.rand = opts.rand or function(n) return math.random(n) end
  self.highScore = opts.highScore or 0
  self:reset()
  return self
end

function Flappy:groundY()
  return self.h - GROUND_H
end

-- Gap opening for the *next* pipe to be spawned. Difficulty is expressed as a
-- tightening gap rather than a faster scroll, because SCROLL_SPEED has to stay
-- a whole number of pixels per frame and there is no room above 2 to step it.
function Flappy:gapSize()
  local shrunk = GAP_START - GAP_SHRINK * math.floor(self.score / PIPES_PER_SHRINK)
  local gap = math.max(GAP_MIN, shrunk)

  -- The handheld is always tall enough, but the computer software's window can
  -- be dragged far shorter, leaving less sky than the gap and its margins want.
  -- Give up the margins first and then the gap itself, down to something the
  -- bird still fits through, rather than emitting a pipe with no opening.
  local room = self:groundY()
  gap = math.min(gap, math.max(BIRD_H + 4, room - 2 * EDGE_MARGIN))
  return math.min(gap, math.max(1, room - 2))
end

-- The band of gap *centres* that keeps a whole gap inside the sky, clear of
-- the ceiling and of the ground strip.
function Flappy:centerLimits(gap)
  local lo = EDGE_MARGIN + gap / 2
  local hi = self:groundY() - EDGE_MARGIN - gap / 2
  if lo > hi then                       -- a very short window: centre it
    local mid = self:groundY() / 2
    return mid, mid
  end
  return lo, hi
end

-- The band a gap centre may occupy given where the previous gap was: inside
-- the playfield, and within what the bird can physically climb or fall to in
-- the travel window. Always non-empty, because `prev` is itself clamped into
-- the playfield band before the reach limits are applied around it.
function Flappy:reachBand(prev, gap)
  local lo, hi = self:centerLimits(gap)
  if prev < lo then prev = lo elseif prev > hi then prev = hi end
  local blo = math.max(lo, prev - REACH_CLIMB)
  local bhi = math.min(hi, prev + REACH_DROP)
  return blo, bhi, prev
end

function Flappy:reset()
  self.pipes = {}
  self.score = 0
  self.frame = 0
  self.flaps = 0
  self.lastFlapFrame = -100
  self.state = "ready" -- ready | playing | paused | over

  local mid = self:groundY() / 2
  self.bird = { y = mid - BIRD_H / 2, v = 0 }
  self.lastCenter = mid

  self:spawnPipe()
end

function Flappy:start()
  if self.state == "ready" then self.state = "playing" end
end

function Flappy:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Flappy:resume()
  if self.state == "paused" then self.state = "playing" end
end

function Flappy:isOver()
  return self.state == "over"
end

function Flappy:recordScore()
  if self.score > self.highScore then self.highScore = self.score end
end

local function die(self)
  self.state = "over"
  self:recordScore()
end

-- --------------------------------------------------------------- pipes -- --

-- Appends one pipe, PIPE_SPACING to the right of the last one (or just off the
-- right edge if this is the first). Spacing is measured pipe-to-pipe rather
-- than from the screen edge, so it stays exact for the whole run instead of
-- drifting by whatever the spawn test overshot by.
function Flappy:spawnPipe()
  local gap = self:gapSize()
  local last = self.pipes[#self.pipes]
  local x = last and (last.x + PIPE_SPACING) or self.w

  local lo, hi, prev = self:reachBand(self.lastCenter, gap)
  self.lastCenter = prev

  -- rand() deals in whole numbers, and integral gap edges keep the pipe rects
  -- pixel-crisp without the renderer having to round them.
  local loI, hiI = math.ceil(lo), math.floor(hi)
  if hiI < loI then hiI = loI end
  local center = loI + self.rand(hiI - loI + 1) - 1

  self.lastCenter = center
  self.pipes[#self.pipes + 1] = {
    x = x,
    gap = gap,
    gapTop = center - gap / 2,
    scored = false,
  }
  return self.pipes[#self.pipes]
end

-- Top and bottom column of a pipe, as x/y/w/h rects in playfield coordinates.
function Flappy:pipeRects(p)
  local top = { x = p.x, y = 0, w = PIPE_W, h = p.gapTop }
  local by = p.gapTop + p.gap
  local bottom = { x = p.x, y = by, w = PIPE_W, h = self:groundY() - by }
  return top, bottom
end

function Flappy:birdRect()
  return BIRD_X, self.bird.y, BIRD_W, BIRD_H
end

function Flappy:birdCenterY()
  return self.bird.y + BIRD_H / 2
end

-- The pipe the bird has yet to clear -- what an autopilot aims at, and what
-- the HUD would point to. nil once the course is momentarily empty.
function Flappy:nextPipe()
  for _, p in ipairs(self.pipes) do
    if p.x + PIPE_W > BIRD_X then return p end
  end
  return nil
end

-- --------------------------------------------------------------- input -- --

-- Sets the bird's velocity outright rather than adding to it, so a flap out of
-- a long dive lifts exactly as much as a flap from a hover. Applied
-- immediately rather than queued for the next step: at 20 FPS, holding a press
-- back for a frame is 50 ms of lag the player can feel.
function Flappy:flap()
  if self.state ~= "playing" then return false end
  self.bird.v = FLAP_IMPULSE
  self.flaps = self.flaps + 1
  self.lastFlapFrame = self.frame
  return true
end

-- ---------------------------------------------------------------- step -- --

local function overlaps(ax, aw, bx, bw)
  return ax < bx + bw and bx < ax + aw
end

-- One fixed timestep. No wall clock, no delta time: the host calls this once
-- per timer tick and the constants above are already expressed per frame. A
-- handheld whose timer is coarser than 0.05 s runs the whole game
-- proportionally slower, which is a fair fight -- it never skips physics.
function Flappy:step()
  if self.state ~= "playing" then return end
  self.frame = self.frame + 1

  -- Bird.
  local b = self.bird
  b.v = b.v + GRAVITY
  if b.v > MAX_FALL then b.v = MAX_FALL end
  b.y = b.y + b.v

  -- The ceiling stops the bird instead of killing it: an invisible lethal line
  -- above the visible sky is the kind of death players read as a bug. Holding
  -- the ceiling is no exploit -- the top of every pipe is up there waiting.
  if b.y < 0 then
    b.y = 0
    b.v = 0
  end

  -- World.
  for _, p in ipairs(self.pipes) do
    p.x = p.x - SCROLL_SPEED
  end

  -- Retire pipes that have left the screen. They leave in the order they
  -- arrived, so this only ever has to look at the front of the list.
  while self.pipes[1] and self.pipes[1].x + PIPE_W < 0 do
    table.remove(self.pipes, 1)
  end

  local last = self.pipes[#self.pipes]
  if not last or last.x <= self.w - PIPE_SPACING then
    self:spawnPipe()
  end

  -- Scoring, before collision: a pipe you were level with as you died still
  -- does not count, because the collision below ends the frame either way.
  for _, p in ipairs(self.pipes) do
    if not p.scored and p.x + PIPE_W <= BIRD_X then
      p.scored = true
      self.score = self.score + 1
    end
  end

  -- Collision.
  if b.y + BIRD_H >= self:groundY() then
    b.y = self:groundY() - BIRD_H
    b.v = 0
    return die(self)
  end

  for _, p in ipairs(self.pipes) do
    if overlaps(BIRD_X, BIRD_W, p.x, PIPE_W) then
      if b.y < p.gapTop or b.y + BIRD_H > p.gapTop + p.gap then
        return die(self)
      end
    end
  end
end

return Flappy
