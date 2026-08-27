-- Plays 2048 through the mock runtime so tools/screenshot.lua can capture
-- representative frames.
--
-- The autopilot is the corner strategy in tests/2048/frame.lua: it recovers
-- the board from the paint calls rather than reaching into the game's state,
-- which keeps test-only hooks out of the shipped script.
--
-- Each launch reseeds from the clock, so no two runs play the same game. That
-- means nothing here may assume a particular round lasts a particular length:
-- the interesting frames are collected as play goes by, and a fresh round is
-- started if the current one has already ended.

local Frame = require("2048.frame")

-- How many tiles are drawn off their own cell -- i.e. caught in flight.
local function inFlight(f)
  local n = 0
  for _, t in ipairs(f.tiles) do
    if t.rect.x ~= f.colX[t.x] or t.rect.y ~= f.rowY[t.y] then n = n + 1 end
  end
  return n
end

-- Plays up to `moves` moves, watching every frame. Returns the settled frame
-- with the largest tile on it, the busiest mid-animation frame, and whether
-- the round is still alive.
local function playAndWatch(hs, moves, stopAt, seen)
  seen = seen or { best = 0, busiest = 0 }

  for _ = 1, moves do
    local before = Frame.signature(Frame.frame(hs))
    local took = false

    for _, dir in ipairs(Frame.ORDER) do
      hs.on.arrowKey(dir)

      -- The ticks that fall inside the slide itself. Taking the first
      -- in-flight frame going is a trap: a tile crossing two cells sits
      -- exactly on the cell between them at the halfway tick and looks
      -- settled, so keep the frame with the most tiles actually in motion.
      for _ = 1, 2 do
        hs.on.timer()
        local f, ops = Frame.frame(hs)
        local n = inFlight(f)
        if n > seen.busiest then seen.busiest, seen.slideOps = n, ops end
      end

      Frame.settle(hs)
      local f, ops = Frame.frame(hs)
      if Frame.signature(f) ~= before then
        took = true
        local m = Frame.maxTile(f)
        if m > seen.best then seen.best, seen.bestOps = m, ops end
        break
      end
    end

    if not took then return seen, false end
    if stopAt and seen.best >= stopAt then return seen, true end
  end
  return seen, true
end

return function(hs, capture)
  -- 1. Title screen.
  capture("title", select(2, hs:paint()))

  -- 2 and 3. A board with some history on it, and a slide in progress.
  hs.on.enterKey()
  local seen, alive = playAndWatch(hs, 3000, 256)
  capture("playing", seen.bestOps or select(2, hs:paint()))
  if seen.slideOps then capture("sliding", seen.slideOps) end

  -- 4. Paused. Needs a live round, so deal a fresh one if that game is done.
  if not alive then
    hs.on.enterKey()
    _, alive = playAndWatch(hs, 60)
  end
  hs.on.escapeKey()
  capture("paused", select(2, hs:paint()))
  hs.on.escapeKey()

  -- 5. Game over: play the round out.
  playAndWatch(hs, 5000)
  capture("gameover", select(2, hs:paint()))
end
