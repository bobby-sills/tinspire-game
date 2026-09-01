-- Plays Arkanoid through the mock runtime so tools/screenshot.lua can capture
-- representative frames.
--
-- The simulated player reads the world back out of the paint calls -- see
-- tests/arkanoid/frame.lua -- rather than poking at the game's internals, so
-- nothing test-only leaks into the shipped script. It has no idea where the
-- bricks are: it puts the paddle under the lowest ball and presses enter often
-- enough to serve, to shoot and to let a caught ball go. That is enough to
-- clear a level, which is the point -- a course this can play is a course a
-- person can play.

local F = require("arkanoid.frame")

return function(hs, capture)

local function frame()
  local _, ops = hs:paint()
  return F.read(ops), ops
end

-- One frame of play; returns what was on screen before the tick.
local function tick(i)
  local f, ops = frame()
  hs.on.mouseDown(F.aimPoint(f), 150)
  if i % 5 == 0 then hs.on.enterKey() end
  hs.on.timer()
  return f, ops
end

-- 1. The title screen.
local _, ops = frame()
capture("title", ops)

-- 2. The serve: ball parked on the paddle, board on show, prompt underneath.
hs.on.enterKey()
for _ = 1, 4 do hs.on.timer() end
local _, serveOps = frame()
capture("serve", serveOps)

-- 3. Mid-level, with a bite out of the wall and the ball somewhere it reads as
--    moving. Also grab the first frame that happens to have a capsule falling.
hs.on.enterKey()
local total = #(frame()).bricks
local playOps, capsuleOps, capsuleKind
local cleared, clearedOps
local frames = 0

for i = 1, 40000 do
  local f, o = tick(i)
  frames = i

  if not playOps and #f.bricks <= total * 0.68 and f.balls[1] then
    local b = f.balls[1]
    if b.y > 70 and b.y < 150 then playOps = o end
  end

  if not capsuleOps and #f.capsules > 0 and f.capsules[1].y > 80 then
    capsuleOps, capsuleKind = o, f.capsules[1].kind
  end

  if F.hasText(f, "CLEAR") then
    cleared, clearedOps = true, o
    break
  end
end

assert(playOps, "autopilot never reached a photogenic mid-level frame")
capture("playing", playOps)
if capsuleOps then capture("capsule", capsuleOps) end
assert(cleared, "autopilot never cleared level 1 in " .. frames .. " frames")
capture("cleared", clearedOps)

-- 4. Paused, on the next level, so that panel gets a look too.
for _ = 1, 60 do hs.on.timer() end          -- let the banner move on
hs.on.enterKey()
for i = 1, 400 do tick(i) end
hs.on.escapeKey()
local _, pausedOps = frame()
capture("paused", pausedOps)
hs.on.enterKey()

-- 5. Game over: stop steering and let the ball go past the paddle three times.
local over = false
for i = 1, 6000 do
  hs.on.timer()
  if i % 20 == 0 then
    local f = frame()
    if F.hasText(f, "GAME OVER") then over = true break end
    hs.on.enterKey()                        -- re-serve after each life
  end
end
assert(over, "the ball never ran out of lives")
local _, overOps = frame()
capture("gameover", overOps)

print(string.format("  arkanoid autopilot: %d frames to clear level 1%s",
                    frames, capsuleKind and (", caught a " .. capsuleKind .. " capsule") or ""))
end
