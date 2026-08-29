-- Plays the sliding puzzle through the mock runtime so tools/screenshot.lua
-- can capture representative frames.
--
-- The autopilot is the greedy hill-climb in tests/slide/frame.lua: it recovers
-- the board from the paint calls rather than reaching into the game's state,
-- which keeps test-only hooks out of the shipped script.
--
-- Each launch seeds the puzzle's own generator from the clock and from how
-- long the player idled, so no two runs deal the same board. Nothing here may
-- assume a particular scramble: the interesting frames are collected as play
-- goes by.

local Frame = require("slide.frame")

-- How many tiles are drawn off their own cell, i.e. caught in flight.
local function inFlight(f)
  local n = 0
  for _, t in ipairs(f.tiles) do
    if t.moving then n = n + 1 end
  end
  return n
end

-- Sends the gap to the far end of its own row, which drags a whole run of
-- tiles along, and keeps the busiest frame of the animation. Taking the first
-- moving frame is a trap: a tile crossing a cell boundary can sit exactly on a
-- cell at one tick and look settled.
local function captureRunSlide(hs)
  local best, bestOps = 0, nil
  for _ = 1, 12 do
    local f = Frame.frame(hs)
    if f.gap then
      local n = f.n
      local gx = (f.gap - 1) % n + 1
      local gy = math.floor((f.gap - 1) / n) + 1
      local tx = (gx <= n - gx) and n or 1     -- whichever end is further away
      if tx ~= gx then
        Frame.click(hs, f, tx, gy)
        for _ = 1, 3 do
          local g, ops = Frame.frame(hs)
          local moving = inFlight(g)
          if moving > best then best, bestOps = moving, ops end
          hs.on.timer()
        end
        Frame.settle(hs)
      end
    end
    if best >= 2 then break end
  end
  return bestOps, best
end

-- Presses H until the hint has played a move, or the puzzle is finished. The
-- first press has to run the sliced search; the ones after it replay a plan
-- already in hand and land on the next tick.
local function playHint(hs)
  local sig = Frame.signature(Frame.frame(hs))
  hs.on.charIn("h")
  for _ = 1, 4000 do
    hs.on.timer()
    local f, ops = Frame.frame(hs)
    if f.panel then return ops, true end
    if f.settled and Frame.signature(f) ~= sig then return ops, false end
  end
  return select(2, hs:paint()), false
end

-- S cycles 3 -> 4 -> 5, so this asks for a size without touching the script.
local function goToSize(hs, n)
  for _ = 1, 3 do
    if Frame.frame(hs).n == n then return end
    hs.on.charIn("s")
    Frame.settle(hs)
  end
end

return function(hs, capture)
  -- 1. Title screen: the 4x4 deal behind the panel that states the controls.
  capture("title", select(2, hs:paint()))

  -- 2. A 4x4 with some progress on it -- the frame with the most tiles home,
  --    so the highlight is worth looking at.
  hs.on.enterKey()
  local _, bestOps = Frame.play(hs, 60)
  capture("playing", bestOps or select(2, hs:paint()))

  -- 3. A multi-tile run in flight.
  local slideOps = captureRunSlide(hs)
  if slideOps then capture("sliding", slideOps) end

  -- 4. The hint mid-search. Asked of a freshly dealt 4x4, which needs a
  --    50-move solution and so will still be searching many ticks later --
  --    which is the honest picture of what this costs.
  hs.on.charIn("h")
  for _ = 1, 12 do hs.on.timer() end
  capture("hinting", select(2, hs:paint()))
  hs.on.arrowKey("left")   -- any move abandons a search for a board that was
  Frame.settle(hs)         -- about to stop existing

  -- 5. Paused.
  hs.on.escapeKey()
  capture("paused", select(2, hs:paint()))
  hs.on.escapeKey()

  -- 6. The 5x5, whose two-digit numbers are the ones that had to shrink.
  goToSize(hs, 5)
  Frame.play(hs, 40)
  capture("big", select(2, hs:paint()))

  -- 7. A 3x3 played out by the hint, which at that size does finish inside
  --    its budget, so the win panel is a real solve rather than a fixture.
  goToSize(hs, 3)
  local done = false
  for _ = 1, 120 do
    if done then break end
    _, done = playHint(hs)
  end
  capture("solved", select(2, hs:paint()))
end
