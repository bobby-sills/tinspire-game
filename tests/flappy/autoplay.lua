-- Plays Flappy Bird through the mock runtime so tools/screenshot.lua can
-- capture representative frames.
--
-- Like Snake's autoplay, the simulated player reads the world back out of the
-- paint calls rather than poking at the game's internals, so nothing test-only
-- leaks into the shipped script. Snake recovered a grid from cell-sized rects;
-- here there is no grid, so this recovers the bird and the pipe columns by
-- their colour and reconstructs each gap from the two columns sharing an x.

-- The three colours src/flappy_main.lua reserves for exactly one thing each.
local SKY_RGB  = { 18, 28, 48 }
local PIPE_RGB = { 86, 190, 92 }
local BIRD_RGB = { 252, 210, 74 }

local function sameColor(c, want)
  return c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
end

-- Recovers the world from a frame's drawing operations.
local function readWorld(ops)
  local st = { pipes = {} }
  local columns = {}

  for _, o in ipairs(ops) do
    if o.op == "fillRect" then
      if sameColor(o.color, SKY_RGB) then
        -- The sky is painted once, full-bleed; the lighter haze band above the
        -- horizon is a different colour and so cannot be mistaken for it.
        st.ox, st.oy, st.fw, st.fh = o.x, o.y, o.w, o.h
      elseif sameColor(o.color, BIRD_RGB) then
        st.bird = { x = o.x, y = o.y, w = o.w, h = o.h }
      elseif sameColor(o.color, PIPE_RGB) then
        columns[o.x] = columns[o.x] or {}
        table.insert(columns[o.x], o)
      end
    end
  end

  if not (st.ox and st.bird) then return nil end

  -- Each pipe reaches us as up to two columns sharing an x: one hanging from
  -- the ceiling and one standing on the ground. The gap is the space between
  -- them, which is the only thing the autopilot actually needs.
  for x, rects in pairs(columns) do
    table.sort(rects, function(a, b) return a.y < b.y end)
    local top, bottom = nil, nil
    for _, r in ipairs(rects) do
      if r.y <= st.oy then top = r else bottom = r end
    end

    local gapTop = top and (top.y + top.h) or st.oy
    local gapBottom = bottom and bottom.y or (st.oy + st.fh)
    if gapBottom > gapTop then
      st.pipes[#st.pipes + 1] = {
        x = x,
        w = rects[1].w,
        gapTop = gapTop,
        gapBottom = gapBottom,
        center = (gapTop + gapBottom) / 2,
      }
    end
  end

  table.sort(st.pipes, function(a, b) return a.x < b.x end)
  return st
end

-- The pipe the bird still has to get through.
local function nextPipe(st)
  for _, p in ipairs(st.pipes) do
    if p.x + p.w > st.bird.x then return p end
  end
  return nil
end

-- Flap whenever the bird is below where it wants to be. That is the whole
-- policy -- no lookahead, no damping -- which is the point: if this can fly the
-- course, a person can.
local function shouldFlap(st)
  local p = nextPipe(st)
  local target = p and p.center or (st.oy + st.fh / 2)
  local center = st.bird.y + st.bird.h / 2
  return center > target
end

-- ------------------------------------------------------------------- drive --

return function(hs, capture)
-- 1. Title screen.
local _, ops = hs:paint()
capture("title", ops)

-- 2. Mid-game, once the autopilot has a few pipes behind it and one filling
--    the frame ahead. Flying is driven purely by what the paint calls showed.
hs.on.enterKey()
local frames, cleared, lastX = 0, 0, nil
local playOps = nil
for _ = 1, 4000 do
  local _, frameOps = hs:paint()
  local st = readWorld(frameOps)
  if st then
    if shouldFlap(st) then hs.on.enterKey() end

    -- Count a pipe as cleared when the one the bird was chasing moves behind it.
    local p = nextPipe(st)
    if p and lastX and p.x > lastX then cleared = cleared + 1 end
    lastX = p and p.x or lastX

    -- Grab a frame where a pipe is close enough to read as a real moment of play.
    if cleared >= 3 and p and p.x - st.bird.x < 70 and p.x > st.bird.x then
      playOps = frameOps
    end
    frames = frames + 1
  end
  hs.on.timer()
  if playOps then break end
end
assert(playOps, "autopilot never reached a photogenic frame")
capture("playing", playOps)

-- 3. Game over: stop flapping and let the bird fall out of the sky.
for _ = 1, 400 do hs.on.timer() end
local _, overOps = hs:paint()
capture("gameover", overOps)

-- 4. Paused, to check that overlay too.
hs.on.enterKey() -- new round
for i = 1, 120 do
  local _, frameOps = hs:paint()
  local st = readWorld(frameOps)
  if st and shouldFlap(st) then hs.on.enterKey() end
  hs.on.timer()
end
hs.on.escapeKey()
local _, pausedOps = hs:paint()
capture("paused", pausedOps)

print("  flappy autopilot: " .. frames .. " frames, " .. cleared .. " pipes cleared")
end
