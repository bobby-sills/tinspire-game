-- Plays Fruits through the mock runtime so tools/screenshot.lua can capture
-- representative frames.
--
-- The autopilot lives in tests/fruits/frame.lua: it recovers the board from the
-- paint calls, works out the legal swaps itself, and plays them by clicking --
-- which keeps test-only hooks out of the shipped script and exercises the
-- touchpad path at the same time.
--
-- Each launch seeds itself from the player's own timing, so no two runs deal
-- the same board. Nothing here may assume a round lasts a particular length:
-- interesting frames are collected as play goes by.

local Frame = require("fruits.frame")

-- A cheap, reproducible pick among the legal swaps, so the autoplayer does not
-- always take the top-left one and the boards it builds look played rather
-- than combed.
local function chooser(seed)
  local s = seed
  return function(n)
    s = (16807 * s) % 2147483647
    return (s % n) + 1
  end
end

return function(hs, capture)
  local pick = chooser(20240229)

  -- 1. Title screen.
  capture("title", select(2, hs:paint()))

  hs.on.enterKey()

  -- 2. A fresh board, before anything has been touched.
  local f = Frame.settle(hs)
  capture("board", f.ops)

  -- 3 and 4. A board with some history on it, and the busiest cascade frame
  -- seen along the way.
  local bestBusy, bestBusyOps = -1, nil
  local alive = true
  for _ = 1, 25 do
    local after, swap, busyOps = Frame.step(hs, pick)
    if not swap then alive = false break end
    if busyOps then
      -- Keep the frame with the most fruit visibly in the air.
      local g = Frame.read(busyOps)
      local empty = 64 - (g.filled or 64)
      if empty > bestBusy then bestBusy, bestBusyOps = empty, busyOps end
    end
    f = after
  end
  capture("playing", select(2, hs:paint()))
  if bestBusyOps then capture("cascade", bestBusyOps) end

  -- 5. A fruit picked up with the hint lit: the two markers the player steers
  -- by. Captured here, mid-round, and not after the play-out below -- a round
  -- that has already deadlocked answers `enter` by dealing a new board, and
  -- the frame that comes back is a fresh deal with nothing selected on it.
  if alive then
    hs.on.charIn("h")
    local hf = Frame.frame(hs)
    if hf.hint and hf.hint[1] then
      hs.on.mouseDown(Frame.centre(hf, hf.hint[1].x, hf.hint[1].y))
    end
    capture("selected", select(2, hs:paint()))

    -- 6. Paused.
    hs.on.escapeKey()
    capture("paused", select(2, hs:paint()))
    hs.on.escapeKey()
  end

  -- 7. Deadlock. Play the round out; a round takes a few hundred moves, so
  -- this is bounded generously rather than exactly.
  for _ = 1, 3000 do
    local _, swap = Frame.step(hs, pick)
    if not swap then break end
  end
  capture("gameover", select(2, hs:paint()))
end
