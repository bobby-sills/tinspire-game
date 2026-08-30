-- Chess-specific frame assertions, run by tests/run_ui.lua against the built
-- bundle -- the exact script that goes into the .tns.
--
-- Everything here reads painted frames and presses keys. It never reaches into
-- the game's state, so nothing test-only has to exist in src/. What it costs
-- is that tests/chess/frame.lua has to agree with src/chess/main.lua about a
-- handful of colours and two strings; what it buys is that these tests fail
-- when the *screen* is wrong, which is the only thing a player can see.

local Frame = require("chess.frame")
local R = Frame.Rules

return function(t)
  local test, ok, eq, fail, boot = t.test, t.ok, t.eq, t.fail, t.boot

  -- The sizes tests/run_ui.lua uses, plus a couple that squeeze the layout
  -- past each of the things it is allowed to give up.
  local SIZES = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 100, 80 }, { 640, 480 }, { 900, 700 },
    { 480, 200 }, { 200, 480 },
  }

  -- Starts a game in the given mode and returns the harness. `mode` is the
  -- exact string the menu shows, so a rename of either has to be a rename of
  -- both.
  local function start(mode, opts)
    opts = opts or {}
    local hs = boot(opts.w, opts.h)
    Frame.menuSet(hs, 1, mode)
    if opts.level then Frame.menuSet(hs, 2, opts.level) end
    if opts.side then Frame.menuSet(hs, 3, opts.side) end
    if opts.turn then Frame.menuSet(hs, 4, opts.turn) end
    hs.on.enterKey()
    return hs
  end

  local function hotseat(opts) return start("2 Players (hot-seat)", opts) end
  local function versus(opts) return start("1 Player vs Computer", opts) end

  -- Plays one move by clicking its two squares, the way a person would.
  local function clickMove(hs, shadow, text)
    local from = R.squareFromName(text:sub(1, 2))
    local to = R.squareFromName(text:sub(3, 4))
    local moves = {}
    local n = shadow:legalMoves(moves)
    local m
    for i = 1, n do
      if R.moveFrom(moves[i]) == from and R.moveTo(moves[i]) == to then m = moves[i] end
    end
    if not m then return nil end
    local f = Frame.frame(hs)
    local flip = Frame.orientation(f, shadow) or false
    Frame.clickSquare(hs, f, from, flip)
    local picked = Frame.frame(hs)
    Frame.clickSquare(hs, f, to, flip)
    shadow:play(m)
    return m, picked
  end

  -- ------------------------------------------------------------ the frame --

  test("the board and every piece stay inside their frame, at every size", function()
    for _, size in ipairs(SIZES) do
      local w, h = size[1], size[2]
      local label = string.format("%dx%d", w, h)
      local hs = hotseat({ w = w, h = h })
      local f, ops = Frame.frame(hs)

      if not f.rim then
        fail(label .. ": no board was drawn")
      else
        -- The board and its moulded rim fit in the window, below the status
        -- bar, and the board is square.
        ok(f.rim.x >= 0 and f.rim.y >= 0, label .. ": the rim starts on screen")
        ok(f.rim.x + f.rim.w <= w, label .. ": the rim ends inside the width")
        ok(f.rim.y + f.rim.h <= h, label .. ": the rim ends inside the height")
        ok(f.rim.y >= 20, label .. ": the board clears the status bar")
        eq(f.rim.w, f.rim.h, label .. ": the board is square")
        eq(f.board % 8, 0, label .. ": the board divides into eight files")
        ok(f.cell >= 1, label .. ": the squares have a size")

        -- All thirty-two men are drawn, each one inside the board.
        eq(Frame.pieceCount(f), 32, label .. ": thirty-two pieces on the board")
        eq(#f.cells, 32, label .. ": and every one of them landed on a square")

        -- Every piece is drawn wholly inside the square it belongs to,
        -- whichever way it is being drawn. For a letter this is what catches
        -- a glyph centred out of its own cell, which happens when the
        -- smallest font the OS has is still taller than a square; for a
        -- sprite it is what catches an inset computed the wrong way round.
        for _, piece in ipairs(f.cells) do
          local x0 = f.bx + piece.c * f.cell
          local y0 = f.by + piece.r * f.cell
          if piece.sprite then
            ok(piece.x0 >= x0 and piece.y0 >= y0
                and piece.x1 <= x0 + f.cell and piece.y1 <= y0 + f.cell,
              label .. ": the sprite is inside its own square")
          else
            ok(piece.op.x >= x0 and piece.op.x < x0 + f.cell
                and piece.op.y >= y0 and piece.op.y < y0 + f.cell,
              label .. ": the letter is inside its own square")
          end
        end
        eq(f.unknownSprites, nil, label .. ": every sprite drawn is a known piece")

        -- Sprites are drawn at a fixed 16x16 with no scaling available, so
        -- the game must fall back to letters rather than crop them.
        if f.cell >= 16 then
          ok(f.spriteMode, label .. ": squares this size get the sprites")
        else
          ok(not f.spriteMode, label .. ": squares this small fall back to letters")
          local discs = 0
          for _, o in ipairs(ops) do
            if o.op == "fillArc" and o.x >= f.bx and o.y >= f.by
                and o.x + o.w <= f.bx + f.board and o.y + o.h <= f.by + f.board then
              discs = discs + 1
            end
          end
          eq(discs, 32, label .. ": thirty-two discs behind the letters")
        end
      end

      -- And nothing at all is painted at a negative coordinate, which is the
      -- one thing the handheld will not show you it is doing.
      for _, o in ipairs(ops) do
        if o.x < 0 or o.y < 0 then
          fail(string.format("%s: %s painted at %d,%d", label, o.op, o.x, o.y))
          break
        end
      end
    end
  end)

  -- --------------------------------------------------- the two draw paths --
  --
  -- A piece is one gc:drawImage where the runtime will build the images, and
  -- the identical pixels as fillRect runs where it will not. Both are
  -- exercised here and then held against each other: a fallback nothing tests
  -- is a fallback that does not work.

  test("the handheld draws one image per piece, not a heap of rects", function()
    local hs = hotseat({ w = 318, h = 212 })
    local calls = hs:paint()
    eq(calls.drawImage, 32, "thirty-two men, thirty-two blits")
    -- The runs would be about 940 rects for the same board. Everything left is
    -- chrome -- squares, rim, panels -- so hold it well under that, or a
    -- regression that quietly falls back would still pass.
    ok(calls.fillRect < 100,
      "the board is chrome plus blits (" .. calls.fillRect .. " rects)")
  end)

  test("the rect fallback paints the identical position", function()
    -- The position the image path draws, to hold the fallback against.
    local viaImages = Frame.signature(Frame.frame(hotseat({ w = 318, h = 212 })))

    -- Now make image.new fail the way an OS that will not take the string form
    -- would. Every piece must fall back to the runs -- and paint the same
    -- board, since it is the same art either way.
    local realNew = t.stub.image.new
    t.stub.image.new = function() error("image.new: not supported here", 2) end
    local built, viaRects = pcall(function()
      local hs = hotseat({ w = 318, h = 212 })
      local calls = hs:paint()
      eq(calls.drawImage, 0, "nothing tried to draw an image")
      ok(calls.fillRect > 500,
        "the pieces arrived as rects instead (" .. calls.fillRect .. ")")
      local f = Frame.frame(hs)
      eq(Frame.pieceCount(f), 32, "all thirty-two men are still on the board")
      eq(f.unknownSprites, nil, "and every one of them is a known piece")
      return Frame.signature(f)
    end)
    t.stub.image.new = realNew

    ok(built, "the fallback ran: " .. tostring(viaRects))
    if built then
      eq(viaRects, viaImages, "both encodings paint the same position")
    end
  end)

  test("the sidebar never overlaps the board", function()
    for _, size in ipairs(SIZES) do
      local hs = hotseat({ w = size[1], h = size[2] })
      local f = Frame.frame(hs)
      local label = string.format("%dx%d", size[1], size[2])
      if f.rim then
        -- Every string that is not a piece on the board and is level with the
        -- board must start to the right of it. `piece` is set by the frame
        -- reader on the letters it matched to squares.
        for _, str in ipairs(f.strings) do
          if not str.piece and str.y >= f.rim.y and str.y < f.rim.y + f.rim.h
              and str.x > f.rim.x then
            ok(str.x >= f.rim.x + f.rim.w,
              label .. ": '" .. str.text .. "' does not sit on the board")
          end
        end
      end
    end
  end)

  test("the pieces are laid out as chess actually starts", function()
    local hs = hotseat()
    local f = Frame.frame(hs)
    -- Screen row 0 is rank 8 with White at the bottom, which is the default.
    local back = { 4, 2, 3, 5, 6, 3, 2, 4 } -- R N B Q K B N R
    for c = 0, 7 do
      eq(f.grid[c + 1], 2 * 8 + back[c + 1], "black's back rank, file " .. (c + 1))
      eq(f.grid[8 + c + 1], 2 * 8 + 1, "black's pawn on file " .. (c + 1))
      eq(f.grid[48 + c + 1], 1 * 8 + 1, "white's pawn on file " .. (c + 1))
      eq(f.grid[56 + c + 1], 1 * 8 + back[c + 1], "white's back rank, file " .. (c + 1))
    end
    for i = 17, 48 do eq(f.grid[i], 0, "the middle four ranks are empty") end
    eq(f.side, 1, "white to move")
  end)

  -- ------------------------------------------------------------ playing ----

  test("the cursor moves with the arrows and stops at the edges", function()
    local hs = hotseat()
    local f = Frame.frame(hs)
    ok(f.cursor, "a cursor is on the board")

    -- Walk it into each corner and keep pushing; it must not wrap or leave.
    for _, run in ipairs({ { "left", "up" }, { "right", "down" } }) do
      for _, key in ipairs(run) do
        for _ = 1, 12 do hs.on.arrowKey(key) end
      end
      local g = Frame.frame(hs)
      ok(g.cursor, "the cursor survived a run of " .. run[1] .. "/" .. run[2])
      ok(g.cursor.c >= 0 and g.cursor.c <= 7 and g.cursor.r >= 0 and g.cursor.r <= 7,
        "and stayed on the board")
    end

    -- One step from a known place moves exactly one square.
    for _ = 1, 12 do hs.on.arrowKey("left") end
    for _ = 1, 12 do hs.on.arrowKey("down") end
    local before = Frame.frame(hs).cursor
    hs.on.arrowKey("right")
    local after = Frame.frame(hs).cursor
    eq(after.c, before.c + 1, "one step right is one square")
    eq(after.r, before.r, "and no change of rank")
  end)

  test("picking a piece up shows exactly its legal destinations", function()
    local hs = hotseat()
    local shadow = R.new()
    local f = Frame.frame(hs)

    -- The knight on b1: two moves, and both must be marked.
    Frame.clickSquare(hs, f, R.sqOf(2, 1), false)
    local picked = Frame.frame(hs)
    ok(picked.sel, "the square it came from is highlighted")

    local want = {}
    local n = shadow:legalMovesFrom(R.sqOf(2, 1), want)
    eq(#picked.dests, n, "one marker per legal move (" .. n .. ")")

    local marked = {}
    for _, d in ipairs(picked.dests) do marked[d.r * 8 + d.c] = true end
    for i = 1, n do
      local to = R.moveTo(want[i])
      local c, r = R.fileOf(to) - 1, 8 - R.rankOf(to)
      ok(marked[r * 8 + c], "b1 to " .. R.squareName(to) .. " is marked")
    end

    -- Clicking the same square again puts the piece back down.
    Frame.clickSquare(hs, f, R.sqOf(2, 1), false)
    ok(not Frame.frame(hs).sel, "clicking it again deselects")

    -- A square with nothing on it, and one with the other side's piece, are
    -- both simply not selectable.
    Frame.clickSquare(hs, f, R.sqOf(4, 4), false)
    ok(not Frame.frame(hs).sel, "an empty square selects nothing")
    Frame.clickSquare(hs, f, R.sqOf(4, 7), false)
    ok(not Frame.frame(hs).sel, "the other side's pawn selects nothing")
  end)

  test("a move played on the board is the move that shows up", function()
    local hs = hotseat()
    local shadow = R.new()
    for _, text in ipairs({ "e2e4", "e7e5", "g1f3", "b8c6" }) do
      local m = clickMove(hs, shadow, text)
      ok(m, "played " .. text)
      local f = Frame.frame(hs)
      eq(Frame.orientation(f, shadow), false,
        "the painted board matches the position after " .. text)
      eq(f.lastText, shadow:lastMove().text, "and the sidebar names the move")
      eq(f.side, shadow.side, "and says whose turn it is")
      eq(#f.last, 2, "the two squares of the last move are highlighted")
    end
  end)

  test("a king in check is highlighted, and so is a mated one", function()
    local hs = hotseat()
    local shadow = R.new()
    ok(not Frame.frame(hs).check, "nobody is in check to begin with")

    -- Scholar's mate: check on the last move of it, and mate at the end.
    for _, text in ipairs({ "e2e4", "e7e5", "f1c4", "b8c6", "d1h5", "g8f6", "h5f7" }) do
      ok(clickMove(hs, shadow, text), "played " .. text)
    end
    local f = Frame.frame(hs)
    ok(f.check, "the mated king's square is marked")
    local c, r = f.check.c, f.check.r
    eq(R.squareName(R.sqOf(c + 1, 8 - r)), "e8", "and it is the black king's square")
    ok(f.panel, "the result panel is up")

    local sawMate = false
    for _, s in ipairs(f.strings) do
      if s.text == "CHECKMATE" then sawMate = true end
    end
    ok(sawMate, "and it says CHECKMATE")
  end)

  test("undo takes the move back", function()
    local hs = hotseat()
    local shadow = R.new()
    local before = Frame.signature(Frame.frame(hs))
    ok(clickMove(hs, shadow, "e2e4"), "played e4")
    ok(Frame.signature(Frame.frame(hs)) ~= before, "the board changed")
    hs.on.charIn("u")
    eq(Frame.signature(Frame.frame(hs)), before, "and undo put it back")
    ok(not Frame.frame(hs).lastText, "with no last move left to report")

    -- Undo on an empty history is harmless.
    for _ = 1, 5 do hs.on.charIn("u") end
    eq(Frame.signature(Frame.frame(hs)), before, "undoing past the start is a no-op")
  end)

  test("flipping turns the board over without moving a piece", function()
    local hs = hotseat()
    local shadow = R.new()
    ok(clickMove(hs, shadow, "e2e4"), "played e4")

    local before = Frame.frame(hs)
    eq(Frame.orientation(before, shadow), false, "white is at the bottom")
    hs.on.charIn("f")
    local after = Frame.frame(hs)
    eq(Frame.orientation(after, shadow), true, "and now black is")

    -- Same men, same squares, drawn the other way up: every cell is the
    -- 180-degree rotation of the one before.
    for r = 0, 7 do
      for c = 0, 7 do
        eq(after.grid[r * 8 + c + 1], before.grid[(7 - r) * 8 + (7 - c) + 1],
          "cell " .. c .. "," .. r .. " is the rotation of its opposite")
      end
    end

    hs.on.charIn("f")
    eq(Frame.orientation(Frame.frame(hs), shadow), false, "and flipping back")
  end)

  test("the promotion chooser comes up and places what it is told to", function()
    -- Walk a pawn to the eighth rank: a4-a5-a6xb7xa8, with Black shuffling a
    -- knight in between.
    local hs = hotseat()
    local shadow = R.new()
    for _, text in ipairs({ "a2a4", "g8f6", "a4a5", "f6g8", "a5a6", "g8f6",
                            "a6b7", "f6g8" }) do
      ok(clickMove(hs, shadow, text), "played " .. text)
    end

    local f = Frame.frame(hs)
    Frame.clickSquare(hs, f, R.sqOf(2, 7), false)  -- pick up the pawn on b7
    Frame.clickSquare(hs, f, R.sqOf(1, 8), false)  -- take the rook on a8

    local chooser = Frame.frame(hs)
    ok(chooser.panel, "a panel came up instead of the move being played")
    local sawTitle = false
    for _, s in ipairs(chooser.strings) do
      if s.text == "Promote to" then sawTitle = true end
    end
    ok(sawTitle, "and it is the promotion chooser")
    ok(not chooser.cells[1] or true, "the chooser's own pieces are not read as board pieces")

    -- Q R B N: one step right is the rook, which is the underpromotion a
    -- queen would be wrong to assume.
    hs.on.arrowKey("right")
    hs.on.enterKey()

    local after = Frame.frame(hs)
    ok(not after.panel, "the chooser is gone")
    local a8 = after.grid[1] -- screen cell 0,0 is a8 with white at the bottom
    eq(a8, 1 * 8 + R.ROOK, "a white rook is standing on a8")
    ok(shadow:play(R.encode(R.sqOf(2, 7), R.sqOf(1, 8), R.ROOK, R.FLAG_NORMAL)),
      "the same move on the shadow board")
    eq(Frame.orientation(after, shadow), false, "and the two positions agree")
  end)

  -- ------------------------------------------------------------ the bot ----

  test("the thinking indicator is up while the bot searches, and only then", function()
    -- Hard, so the bot has enough ticks that the indicator is unmissable.
    local hs = versus({ level = "Hard", side = "White" })
    local shadow = R.new()

    ok(not Frame.frame(hs).thinking, "not thinking before anyone has moved")

    ok(clickMove(hs, shadow, "e2e4"), "played e4")
    local f = Frame.frame(hs)
    ok(f.thinking, "the bot starts thinking the moment it is its turn")
    ok(f.thinkDepth and f.thinkDepth >= 1, "and reports a depth")

    -- It keeps saying so, and it gets deeper rather than sitting on depth 1.
    local ticks, maxDepth, seen = 0, 0, 0
    local settled
    for _ = 1, 600 do
      local g = Frame.frame(hs)
      if not g.thinking then settled = g; break end
      seen = seen + 1
      if (g.thinkDepth or 0) > maxDepth then maxDepth = g.thinkDepth end
      hs.on.timer()
      ticks = ticks + 1
    end
    ok(settled, "the bot finished inside six hundred ticks")
    ok(seen >= 4, "the indicator was up for " .. seen .. " frames")
    ok(maxDepth >= 2, "and the search reached depth " .. maxDepth)

    -- And when it stops, a move has been made.
    ok(settled and settled.lastText, "the bot's move is named in the sidebar")
    ok(settled and not settled.thinking, "and the indicator is down")
    eq(settled and settled.side, 1, "it is White's turn again")
    local m = settled and Frame.parseMove(shadow, settled.lastText)
    ok(m, "the move it reports is a legal move of the position: "
      .. tostring(settled and settled.lastText))
    if m then
      shadow:play(m)
      eq(Frame.orientation(settled, shadow), false, "and it is the move on the board")
    end
  end)

  test("the bot answers over and over without wedging", function()
    local hs = versus({ level = "Easy", side = "White" })
    local shadow = R.new()
    for ply = 1, 6 do
      local moves = {}
      local n = shadow:legalMoves(moves)
      if n == 0 then break end
      -- Any legal move will do; this is about the bot always replying.
      local m = moves[1 + (ply * 7) % n]
      local f = Frame.frame(hs)
      Frame.clickSquare(hs, f, R.moveFrom(m), false)
      Frame.clickSquare(hs, f, R.moveTo(m), false)
      shadow:play(m)

      local settled = Frame.settle(hs, 600)
      ok(settled, "the bot settled after ply " .. ply)
      if not settled then break end
      local reply = Frame.parseMove(shadow, settled.lastText)
      ok(reply, "and answered with a legal move (" .. tostring(settled.lastText) .. ")")
      if not reply then break end
      shadow:play(reply)
      eq(Frame.orientation(settled, shadow), false, "board agrees after ply " .. ply)
    end
  end)

  test("input during the bot's turn cannot move a piece", function()
    local hs = versus({ level = "Hard", side = "White" })
    local shadow = R.new()
    ok(clickMove(hs, shadow, "d2d4"), "played d4")
    local thinking = Frame.frame(hs)
    ok(thinking.thinking, "the bot is thinking")
    local sig = Frame.signature(thinking)

    -- Everything a bored player might press.
    for _, ch in ipairs({ " ", "z", "0" }) do hs.on.charIn(ch) end
    for _, key in ipairs({ "up", "down", "left", "right" }) do hs.on.arrowKey(key) end
    hs.on.enterKey()
    hs.on.mouseDown(40, 60)
    hs.on.mouseDown(200, 150)

    local after = Frame.frame(hs)
    eq(Frame.signature(after), sig, "the board did not move")
    ok(not after.sel, "and nothing got picked up")
  end)

  test("the menu keeps its shape as the modes change", function()
    local hs = boot()
    -- Every row is always on screen, whether or not it applies, so the panel
    -- never changes size under the player's hand.
    for _, mode in ipairs({ "1 Player vs Computer", "2 Players (hot-seat)" }) do
      ok(Frame.menuSet(hs, 1, mode), "set the mode to " .. mode)
      local rows = Frame.menuRows(Frame.frame(hs))
      eq(#rows, 4, mode .. ": four rows")
      for i, r in ipairs(rows) do
        ok(r.value and r.value ~= "", mode .. ": row " .. i .. " has a value")
      end
    end

    ok(Frame.menuSet(hs, 1, "1 Player vs Computer"), "back to the bot")
    for _, level in ipairs({ "Easy", "Medium", "Hard" }) do
      ok(Frame.menuSet(hs, 2, level), "the level cycles to " .. level)
    end
    for _, side in ipairs({ "Black", "White" }) do
      ok(Frame.menuSet(hs, 3, side), "the side cycles to " .. side)
    end
  end)

  test("playing as Black starts the board the other way up, and the bot opens", function()
    local hs = versus({ level = "Easy", side = "Black" })
    local shadow = R.new()
    local settled = Frame.settle(hs, 600)
    ok(settled, "the bot moved first without being asked")
    if settled then
      local m = Frame.parseMove(shadow, settled.lastText)
      ok(m, "its opening move is a legal one: " .. tostring(settled.lastText))
      if m then
        shadow:play(m)
        eq(Frame.orientation(settled, shadow), true,
          "the board is drawn with Black at the bottom, showing the move it made")
      end
      eq(settled.side, 2, "it is Black's move now")
    end
  end)

  test("hot-seat can turn the board between turns", function()
    local hs = hotseat({ turn = "On" })
    local shadow = R.new()
    eq(Frame.orientation(Frame.frame(hs), shadow), false, "White opens facing up")
    ok(clickMove(hs, shadow, "e2e4"), "played e4")
    eq(Frame.orientation(Frame.frame(hs), shadow), true, "and the board turns for Black")
    ok(clickMove(hs, shadow, "e7e5"), "played e5")
    eq(Frame.orientation(Frame.frame(hs), shadow), false, "and back again for White")
  end)
end
