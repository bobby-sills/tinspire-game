-- Plays chess through the mock runtime so tools/screenshot.lua can capture
-- representative frames.
--
-- Three short sessions, because no one position shows everything worth
-- seeing: a hot-seat game played out to a real checkmate, a forced pawn
-- promotion to raise the chooser, and a game against the shipped bot where
-- the driver answers with its own search -- a second, independent copy of the
-- rules loaded from source by tests/chess/frame.lua.
--
-- The driver only ever clicks squares and reads painted frames. It keeps a
-- shadow game in step by parsing the sidebar's own "Last:" line, so nothing
-- test-only has to reach the shipped script.

local Frame = require("chess.frame")
local R = assert(Frame.Rules, "tests/chess/autoplay.lua needs src/chess/game.lua")

local DRIVER_LEVEL = 2 -- Medium: fast enough to run in a screenshot pass

-- --------------------------------------------------------------- plumbing --

local function newCtx(hs)
  return { hs = hs, shadow = R.new(), flip = false }
end

-- Re-reads which way round the board is drawn. Cheap, and it means a session
-- that turns the board over does not need the driver to be told.
local function sync(ctx, f)
  local flip = Frame.orientation(f, ctx.shadow)
  if flip ~= nil then ctx.flip = flip end
  return f
end

-- Applies whatever move the sidebar is reporting, if the shadow has not
-- already seen it. That is how the shipped bot's reply gets into the shadow.
local function absorb(ctx, f)
  if not f.lastText then return false end
  local mine = ctx.shadow:lastMove()
  if mine and mine.text == f.lastText then return false end
  local m = Frame.parseMove(ctx.shadow, f.lastText)
  if not m then return false end
  ctx.shadow:play(m)
  return true
end

-- Plays one move by clicking its two squares. Returns the frame after the
-- piece has been picked up (destinations showing) and the settled frame after
-- it has been put down.
local function play(ctx, m, capture, pickName)
  local hs = ctx.hs
  local f = sync(ctx, Frame.frame(hs))
  Frame.clickSquare(hs, f, R.moveFrom(m), ctx.flip)

  local picked, pickedOps = Frame.frame(hs)
  if capture and pickName then capture(pickName, pickedOps) end

  Frame.clickSquare(hs, f, R.moveTo(m), ctx.flip)
  ctx.shadow:play(m)

  local settled = Frame.settle(hs, 400)
  if settled then absorb(ctx, settled) end
  return picked, settled
end

-- Finds a move of the shadow game by its from/to squares, e.g. "e2e4".
local function bySquares(ctx, text)
  local from = R.squareFromName(text:sub(1, 2))
  local to = R.squareFromName(text:sub(3, 4))
  local moves = {}
  local n = ctx.shadow:legalMoves(moves)
  for i = 1, n do
    if R.moveFrom(moves[i]) == from and R.moveTo(moves[i]) == to then return moves[i] end
  end
  return nil
end

-- ------------------------------------------------------------------ frames --

return function(hs, capture)
  -- 1. The title screen, with the menu on it.
  capture("title", select(2, hs:paint()))

  -- 2. The menu wound on to Hard, which is also the level the game below is
  --    played at on the calculator's side.
  Frame.menuSet(hs, 2, "Hard")
  capture("menu", select(2, hs:paint()))

  -- 3. Hot-seat, played out to Scholar's mate: a real checkmate reached in
  --    seven plies, which is the cheapest way to get an honest final frame.
  Frame.menuSet(hs, 1, "2 Players (hot-seat)")
  hs.on.enterKey()

  local ctx = newCtx(hs)
  local mateLine = { "e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7" }
  local midOps
  for i, text in ipairs(mateLine) do
    local m = bySquares(ctx, text)
    if not m then break end
    local _, settled = play(ctx, m, capture, (i == 5) and "selected" or nil)
    if i == 4 and settled then midOps = select(2, Frame.frame(hs)) end
    if ctx.shadow:isOver() then break end
  end
  if midOps then capture("playing", midOps) end

  -- The overlay's prompt blinks, so take a frame where it is lit.
  local bestOps, lit = select(2, hs:paint()), false
  for _ = 1, 20 do
    local f, ops = Frame.frame(hs)
    if f.panel and not lit then bestOps, lit = ops, true end
    hs.on.timer()
  end
  capture("checkmate", bestOps)

  -- 4. A forced promotion, to raise the chooser. White walks the a-pawn down
  --    and takes the rook on a8 with it; Black shuffles a knight meanwhile.
  hs.on.charIn("m")             -- back to the menu
  Frame.menuSet(hs, 1, "2 Players (hot-seat)")
  hs.on.enterKey()

  ctx = newCtx(hs)
  for _, text in ipairs({ "a2a4", "g8f6", "a4a5", "f6g8", "a5a6", "g8f6",
                          "a6b7", "f6g8" }) do
    local m = bySquares(ctx, text)
    if not m then break end
    play(ctx, m)
  end
  -- b7xa8 promotes, so the second click raises the chooser instead of moving.
  local f = sync(ctx, Frame.frame(hs))
  Frame.clickSquare(hs, f, R.sqOf(2, 7), ctx.flip)
  Frame.clickSquare(hs, f, R.sqOf(1, 8), ctx.flip)
  hs.on.arrowKey("right")       -- wind on from queen, so the choice is visible
  capture("promotion", select(2, hs:paint()))
  hs.on.enterKey()

  -- 5. Against the shipped bot at Hard, with the driver answering for White.
  hs.on.charIn("m")
  Frame.menuSet(hs, 1, "1 Player vs Computer")
  Frame.menuSet(hs, 3, "White")       -- the driver takes White, so it opens
  hs.on.enterKey()

  ctx = newCtx(hs)
  local thinkOps, thinkRank = nil, -1
  local moves = 0

  for _ = 1, 8 do
    if ctx.shadow:isOver() then break end
    local ai = R.AI.fromLevel(ctx.shadow, DRIVER_LEVEL)
    local m = ai:solve()
    if not m then break end

    local frameBefore = sync(ctx, Frame.frame(hs))
    Frame.clickSquare(hs, frameBefore, R.moveFrom(m), ctx.flip)
    Frame.clickSquare(hs, frameBefore, R.moveTo(m), ctx.flip)
    ctx.shadow:play(m)
    moves = moves + 1

    -- Watch the bot think. Rank by the depth on the indicator: a frame
    -- reading "Thinking d1" says nothing about the search.
    local settled
    for _ = 1, 400 do
      local g, ops = Frame.frame(hs)
      if g.thinking then
        local rank = (g.thinkDepth or 0) * 100 + Frame.pieceCount(g)
        if rank > thinkRank then thinkRank, thinkOps = rank, ops end
      else
        settled = g
        break
      end
      hs.on.timer()
    end
    if not settled then break end
    absorb(ctx, settled)
  end

  if thinkOps then capture("thinking", thinkOps) end
  capture("versus", select(2, hs:paint()))

  print(string.format("  (autoplay: %d driven moves against the bot)", moves))
end
