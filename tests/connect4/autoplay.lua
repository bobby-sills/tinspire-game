-- Plays Connect Four through the mock runtime so tools/screenshot.lua can
-- capture representative frames.
--
-- Bot against bot: the game is started in "1 Player vs Computer" mode, so the
-- shipped bot plays yellow, and the driver here answers for red with its own
-- search -- a second, independent copy of the rules loaded from source by
-- tests/connect4/frame.lua. The driver reads the position out of the painted
-- frame rather than out of the game, so nothing test-only has to reach the
-- shipped script.
--
-- Each launch reseeds from the clock, so nothing here may assume a particular
-- game lasts a particular length: the interesting frames are collected as play
-- goes by and the round is played out to whatever end it reaches.

local Frame = require("connect4.frame")

local DRIVER_LEVEL = 3 -- Hard, so the games on screen look like real games

-- Runs the timer until the board is at rest, keeping the most interesting
-- frames seen along the way.
local function watch(hs, seen, limit)
  for _ = 1, limit or 600 do
    local f, ops = Frame.frame(hs)

    -- A disc caught in flight. Prefer a busy board over an empty one -- the
    -- very first move of a game falls furthest and shows nothing else -- and
    -- among equally busy boards prefer the disc that has fallen furthest,
    -- since one still near the top barely reads as moving.
    if f.falling and f.board then
      local rank = Frame.discCount(f) * 1000 + (f.falling.rect.y - f.board.y)
      if rank > (seen.fallRank or -1) then
        seen.fallRank, seen.fallOps = rank, ops
      end
    end

    -- The bot mid-search, with its indicator up and a board worth looking at.
    -- Ranked by the depth on the indicator first: late in a game the search
    -- often proves a result at depth one and stops, and a frame reading
    -- "Thinking d1" over a nearly full board says nothing about the search.
    if f.thinking then
      local rank = (f.thinkDepth or 0) * 100 + Frame.discCount(f)
      if rank >= (seen.thinkRank or -1) then
        seen.thinkRank, seen.thinkOps = rank, ops
      end
    end

    if not f.falling and not f.thinking then return f, ops end
    hs.on.timer()
  end
  return nil
end

return function(hs, capture)
  local seen = {}

  -- 1. Title screen, with the menu on it.
  capture("title", select(2, hs:paint()))

  -- 2. The difficulty picker, one row down and wound on to Hard -- which is
  -- also the level the game below is played at, on both sides.
  hs.on.arrowKey("down")
  hs.on.arrowKey("right")
  capture("menu", select(2, hs:paint()))
  hs.on.arrowKey("up")

  -- 3. Play a whole game, red driven from here and yellow by the shipped bot.
  hs.on.enterKey()
  local last, lastOps = Frame.frame(hs)
  local moves = 0

  for _ = 1, 42 do
    local f = last
    if not f or f.panel then break end

    local col = Frame.bestMove(f, DRIVER_LEVEL)
    if not col then break end

    hs.on.charIn(tostring(col))
    local settled, ops = watch(hs, seen)
    if not settled then break end
    last, lastOps = settled, ops
    moves = moves + 1

    -- A board with a dozen or so discs on it is the one that looks like a
    -- game in progress; much later and the overlay is about to cover it.
    local n = Frame.discCount(settled)
    if n >= 10 and n <= 20 and (seen.playDiscs or 0) < n then
      seen.playDiscs, seen.playOps = n, ops
    end
  end

  -- 4. Mid-game, a disc in flight, and the bot thinking.
  capture("playing", seen.playOps or lastOps)
  if seen.fallOps then capture("dropping", seen.fallOps) end
  if seen.thinkOps then capture("thinking", seen.thinkOps) end

  -- 5. The finish, with the winning four ringed. The highlight flashes, so
  -- hunt for a frame where it is lit rather than taking whichever comes.
  local best, bestOps = -1, lastOps
  for _ = 1, 16 do
    local f, ops = Frame.frame(hs)
    if #f.rings > best then best, bestOps = #f.rings, ops end
    hs.on.timer()
  end
  capture("gameover", bestOps)

  print(string.format("  (autoplay: %d moves, %d rings on the final frame)", moves, best))
end
