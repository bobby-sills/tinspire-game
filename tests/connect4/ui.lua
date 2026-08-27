-- Connect Four frame assertions, run by tests/run_ui.lua after its generic
-- suite. Two headline claims, both of which a screenshot would have shown you:
-- no disc ever escapes the board at any window size, settled or mid-drop; and
-- the bot always says it is thinking while it is thinking, so a search sliced
-- across ticks never looks like a frozen screen.

local Frame = require("connect4.frame")

local COLS, ROWS = Frame.COLS, Frame.ROWS
local CELLS = COLS * ROWS

local SIZES = {
  { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
  { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
}

local function within(r, box)
  return r.x >= box.x and r.y >= box.y
    and r.x + r.w <= box.x + box.w
    and r.y + r.h <= box.y + box.h
end

-- Starts a round. The title screen defaults to one player against the bot;
-- pass "hotseat" for two.
local function begin(hs, mode)
  if mode == "hotseat" then hs.on.charIn("2") end
  hs.on.enterKey()
end

return function(t)
  local test, ok, eq, fail, boot = t.test, t.ok, t.eq, t.fail, t.boot

  -- The core invariant, checked on whatever frame it is handed.
  local function assertContained(f, label)
    if not f.board then return fail(label .. ": no board drawn") end

    local n = #f.arcs
    if f.falling then
      eq(n, CELLS + 1, label .. ": 42 cells plus the disc in flight")
    else
      eq(n, CELLS, label .. ": drew all 42 cells and nothing else")
    end

    eq(f.cellsPainted, CELLS, label .. ": every one of the 42 cells was painted")

    local out, oversize = 0, 0
    for _, a in ipairs(f.arcs) do
      if not within(a.rect, f.board) then out = out + 1 end
      if a.rect.w > f.size or a.rect.h > f.size then oversize = oversize + 1 end
    end
    eq(out, 0, label .. ": every disc and hole is inside the board")
    eq(oversize, 0, label .. ": no disc drawn larger than a cell")

    out = 0
    for _, r in ipairs(f.rings) do
      if not within(r, f.board) then out = out + 1 end
    end
    eq(out, 0, label .. ": the winning highlight stays inside the board too")
  end

  test("connect4: the board is 7x6 and fits the window at every size", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local f = Frame.read(select(2, hs:paint()))

      if not f.board then
        fail(label .. ": no board drawn")
      else
        eq(f.board.w % COLS, 0, label .. ": the board divides into seven columns")
        eq(f.board.h % ROWS, 0, label .. ": and six rows")
        eq(f.board.w / COLS, f.board.h / ROWS, label .. ": the cells are square")
        eq(f.cellsPainted, CELLS, label .. ": all 42 cells were painted, once each")
        ok(f.cell >= 6, label .. ": the cells are big enough to see (" .. f.cell .. "px)")
        ok(f.pad >= 1, label .. ": the discs are inset inside their cells")
        ok(f.board.x >= 0 and f.board.y >= 0, label .. ": the board starts on screen")
        ok(f.board.x + f.board.w <= s[1], label .. ": and ends inside it horizontally")
        ok(f.board.y + f.board.h <= s[2], label .. ": and vertically")
        ok(f.board.y >= 22, label .. ": below the status bar")
        ok(f.hud ~= nil, label .. ": drew the status bar")
        eq(Frame.discCount(f), 0, label .. ": an untouched board has no discs")
      end
      assertContained(f, label .. " title")
    end
  end)

  test("connect4: no disc escapes the board at any window size", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      begin(hs, "hotseat")

      -- Hot-seat, so this drives both colours and the board fills quickly.
      for move = 1, CELLS do
        local f = Frame.read(select(2, hs:paint()))
        assertContained(f, label .. " move " .. move)
        local open = Frame.openColumns(f)
        if #open == 0 or f.panel then break end
        -- Every tick of the drop, from the moment the key is pressed to the
        -- frame after it lands: that is exactly where an off-by-one escapes.
        hs.on.charIn(tostring(open[(move % #open) + 1]))
        for tick = 0, 7 do
          assertContained(Frame.read(select(2, hs:paint())),
            string.format("%s move %d tick %d", label, move, tick))
          hs.on.timer()
        end
      end
      assertContained(Frame.read(select(2, hs:paint())), label .. " final")
    end
  end)

  test("connect4: a disc really is caught in flight, not just after it lands", function()
    -- If the animation never showed up in a frame the test above would pass
    -- while proving nothing about mid-drop, so insist that it did.
    for _, s in ipairs({ { 318, 212 }, { 120, 90 }, { 900, 700 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      begin(hs, "hotseat")

      local caught, rows = 0, {}
      hs.on.charIn("4")
      for _ = 1, 8 do
        local f = Frame.read(select(2, hs:paint()))
        if f.falling then
          caught = caught + 1
          rows[#rows + 1] = f.falling.rect.y
          ok(within(f.falling.rect, f.board), label .. ": the falling disc is inside the board")
        end
        hs.on.timer()
      end
      ok(caught >= 2, label .. ": caught the disc in flight (" .. caught .. " frames)")

      -- And it fell downwards, monotonically.
      for i = 2, #rows do
        ok(rows[i] >= rows[i - 1], label .. ": the disc never moved back up")
      end
      ok(#rows < 2 or rows[#rows] > rows[1], label .. ": it actually travelled")
    end
  end)

  test("connect4: gravity, as painted -- a disc lands on the stack, not above it", function()
    local hs = boot()
    begin(hs, "hotseat")
    for i = 1, ROWS do
      local f = Frame.play(hs, 4)
      if not f then return fail("the board never settled") end
      eq(Frame.discCount(f), i, "disc " .. i .. " is on the board")
      -- Column 4 is filled from the bottom up and nothing floats.
      for r = 1, ROWS do
        local v = f.grid[(r - 1) * COLS + 4]
        if r > ROWS - i then
          ok(v ~= 0, string.format("row %d of column 4 is filled after %d drops", r, i))
        else
          eq(v, 0, string.format("row %d of column 4 is still empty after %d drops", r, i))
        end
      end
      -- And no other column was touched.
      for c = 1, COLS do
        if c ~= 4 then
          for r = 1, ROWS do
            eq(f.grid[(r - 1) * COLS + c], 0, "column " .. c .. " untouched")
          end
        end
      end
    end

    -- A seventh disc has nowhere to go, and the frame must not change.
    local before = Frame.signature(Frame.frame(hs))
    local f = Frame.play(hs, 4)
    eq(Frame.signature(f), before, "a full column refuses a seventh disc")
  end)

  test("connect4: the colours alternate on screen", function()
    local hs = boot()
    begin(hs, "hotseat")
    local want = 1
    for c = 1, COLS do
      local f = Frame.play(hs, c)
      if not f then return fail("the board never settled") end
      eq(f.grid[(ROWS - 1) * COLS + c], want, "column " .. c .. " got the right colour")
      want = 3 - want
    end
  end)

  test("connect4: the thinking indicator is up the whole time the bot searches", function()
    local hs = boot()
    begin(hs) -- one player against the bot; the player is red and opens

    -- Red plays, the disc falls, and then it is the bot's move.
    hs.on.charIn("4")
    local sawFalling, sawThinking, thinkingFrames = false, false, 0
    local landed = false

    for _ = 1, 400 do
      local f = Frame.read(select(2, hs:paint()))
      if f.falling then sawFalling = true end
      if f.thinking then
        sawThinking = true
        thinkingFrames = thinkingFrames + 1
        -- While it is thinking the bot must not have played yet.
        ok(Frame.discCount(f) <= 2, "the bot has not moved while still thinking")
        -- And the depth it reports is a real one, never a placeholder zero.
        ok((f.thinkDepth or 0) >= 1, "the indicator names a depth it is actually on")
      end
      if sawThinking and not f.thinking and not f.falling then
        landed = true
        eq(Frame.discCount(f), 2, "the bot played exactly one disc")
        break
      end
      hs.on.timer()
    end

    ok(sawFalling, "the player's disc was seen falling")
    ok(sawThinking, "the bot put its thinking indicator up")
    ok(thinkingFrames >= 3, "and kept it up for several frames (" .. thinkingFrames .. ")")
    ok(landed, "then took it down and played")
  end)

  test("connect4: the board does not move while the bot is thinking", function()
    -- The search explores by playing discs and taking them back, and it is
    -- suspended between ticks with several still played. Painting *that*
    -- board showed phantom discs flickering in and out while the bot thought,
    -- so the search runs on a copy. This is the regression test for it.
    local hs = boot()
    begin(hs)
    hs.on.charIn("4")

    local frozen, frames = nil, 0
    for _ = 1, 400 do
      local f = Frame.read(select(2, hs:paint()))
      if f.thinking then
        local sig = Frame.signature(f)
        if frozen == nil then
          frozen = sig
          eq(Frame.discCount(f), 1, "only the player's disc is on the board")
        else
          eq(sig, frozen, "the painted board is unchanged after " .. frames .. " thinking frames")
        end
        frames = frames + 1
      elseif frozen and not f.falling then
        break
      end
      hs.on.timer()
    end
    ok(frames >= 3, "watched the bot think for " .. frames .. " frames")
  end)

  test("connect4: the bot answers every move, and always legally", function()
    local hs = boot()
    begin(hs)
    local moves = 0

    for _ = 1, CELLS do
      local f = Frame.read(select(2, hs:paint()))
      if f.panel then break end -- the game ended
      local open = Frame.openColumns(f)
      if #open == 0 then break end

      local before = Frame.discCount(f)
      local after = Frame.play(hs, open[1])
      if not after then return fail("the board never settled after move " .. moves) end
      moves = moves + 1

      local gained = Frame.discCount(after) - before
      ok(gained == 2 or gained == 1,
        string.format("move %d added the player's disc and the bot's reply (%d)", moves, gained))

      -- Nothing floats anywhere on the painted board. Row 1 is the top row,
      -- so once a column has started, every row below it must be filled.
      for c = 1, COLS do
        local started = false
        for r = 1, ROWS do
          local v = after.grid[(r - 1) * COLS + c]
          if v ~= 0 then started = true
          elseif started then
            return fail("column " .. c .. " has a disc floating over a gap")
          end
        end
      end
    end
    ok(moves >= 4, "played a real game against the bot (" .. moves .. " moves)")
  end)

  test("connect4: hot-seat never shows a thinking indicator", function()
    -- There is no bot in a two-player game, so nothing should ever be
    -- searching, and the player should never be locked out waiting for one.
    local hs = boot()
    begin(hs, "hotseat")
    for move = 1, 20 do
      local f = Frame.read(select(2, hs:paint()))
      eq(f.thinking, nil, "no bot is thinking on move " .. move)
      local open = Frame.openColumns(f)
      if #open == 0 or f.panel then break end
      Frame.play(hs, open[1])
    end
  end)

  test("connect4: the winning four is highlighted when a game ends", function()
    -- Red takes columns 1..4 along the bottom row while yellow answers in 7.
    local hs = boot()
    begin(hs, "hotseat")
    for _, c in ipairs({ 1, 7, 2, 7, 3, 7 }) do Frame.play(hs, c) end

    local before = Frame.read(select(2, hs:paint()))
    eq(#before.rings, 0, "nothing is highlighted before anyone has won")

    Frame.play(hs, 4)

    -- The highlight flashes, so look across a few frames for the lit one.
    local best = 0
    for _ = 1, 20 do
      local f = Frame.read(select(2, hs:paint()))
      if #f.rings > best then best = #f.rings end
      hs.on.timer()
    end
    eq(best, 4, "the four winning discs were ringed")

    local f = Frame.read(select(2, hs:paint()))
    ok(f.panel, "and the result banner came up")
    -- The banner sits in the strip above the board, not over it, so the four
    -- it is telling you about stays visible.
    for _, r in ipairs(f.rings) do
      ok(r.y >= f.board.y, "the highlight is on the board, where the banner is not")
    end
  end)

  test("connect4: the overlay panel never covers the status bar", function()
    for _, s in ipairs({ { 318, 212 }, { 160, 120 }, { 120, 90 }, { 640, 480 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local panel
      for _, o in ipairs(select(2, hs:paint())) do
        if o.op == "fillRect" and o.color[1] == 26 and o.color[2] == 30 and o.color[3] == 39 then
          panel = o
        end
      end
      if panel then
        ok(panel.y >= 22, label .. ": the panel starts below the status bar")
        ok(panel.x >= 0 and panel.x + panel.w <= s[1], label .. ": it fits the window width")
        ok(panel.y + panel.h <= s[2], label .. ": and the window height")
      else
        fail(label .. ": the title screen drew no panel")
      end
    end
  end)

  test("connect4: every line of text fits inside the box drawn around it", function()
    -- Measured with the same getStringWidth/getStringHeight the game used, so
    -- this is a claim about the layout arithmetic rather than about DejaVu.
    --
    -- The result banner used to centre its line against a hard-coded 11 when
    -- the font reports 14, leaving the descenders of "play again" one pixel
    -- off the border: fine in the preview, and a clipped line on a handheld
    -- whose font this code cannot measure. Nothing caught it, so this does.
    local gc = t.stub.newGC()

    local function boxFor(op)
      gc:setFont("sansserif", op.style, op.size)
      return { x = op.x, y = op.y,
               w = gc:getStringWidth(op.text), h = gc:getStringHeight(op.text) }
    end

    -- Every frame worth checking: the title panel, the pause panel, and the
    -- banner a finished game puts up.
    local function checkFrame(hs, label)
      local ops = select(2, hs:paint())
      local panel
      for _, o in ipairs(ops) do
        if o.op == "fillRect" and o.color[1] == 26 and o.color[2] == 30 and o.color[3] == 39 then
          panel = o
        end
      end
      if not panel then return 0 end

      local checked = 0
      for _, o in ipairs(ops) do
        if o.op == "drawString" then
          local b = boxFor(o)
          -- The strings belonging to this box: anything below the status
          -- bar whose horizontal midpoint falls inside it. Keying on the
          -- vertical midpoint instead would let a line that spilled out of
          -- the bottom escape the check entirely.
          local midX = b.x + b.w / 2
          if b.y >= 22 and midX > panel.x and midX < panel.x + panel.w then
            if b.x < panel.x or b.x + b.w > panel.x + panel.w then
              fail(string.format("%s: '%s' is %dpx wide at x %d..%d, outside its box's %d..%d",
                label, o.text, b.w, b.x, b.x + b.w, panel.x, panel.x + panel.w))
            elseif b.y < panel.y or b.y + b.h > panel.y + panel.h then
              fail(string.format("%s: '%s' spans y %d..%d, outside its box's %d..%d",
                label, o.text, b.y, b.y + b.h, panel.y, panel.y + panel.h))
            else
              checked = checked + 1
            end
          end
        end
      end
      return checked
    end

    local total = 0
    for _, s in ipairs(SIZES) do
      local label = string.format("%dx%d", s[1], s[2])

      -- Title screen, on every difficulty, since the wording changes width.
      local hs = boot(s[1], s[2])
      total = total + checkFrame(hs, label .. " title")
      hs.on.arrowKey("down")
      for _ = 1, 4 do
        total = total + checkFrame(hs, label .. " menu")
        hs.on.arrowKey("right")
      end
      hs.on.arrowKey("up")

      -- Paused.
      begin(hs, "hotseat")
      Frame.play(hs, 4)
      hs.on.escapeKey()
      total = total + checkFrame(hs, label .. " paused")
      hs.on.enterKey()

      -- And the result banner. Red takes the bottom row while yellow answers
      -- in column 7.
      local won = boot(s[1], s[2])
      begin(won, "hotseat")
      for _, c in ipairs({ 1, 7, 2, 7, 3, 7, 4 }) do Frame.play(won, c) end
      local n = checkFrame(won, label .. " game over")
      ok(n >= 1, label .. ": the result banner drew a line to measure")
      total = total + n
    end

    ok(total > 200, "measured a lot of lines (" .. total .. ")")
  end)

  test("connect4: the title screen's panel does not resize as the menu moves", function()
    -- The panel is sized for the widest wording each row can ever take, so
    -- scrolling through the difficulties must not make it jump about.
    local hs = boot()
    local function panelRect()
      for _, o in ipairs(select(2, hs:paint())) do
        if o.op == "fillRect" and o.color[1] == 26 and o.color[2] == 30 and o.color[3] == 39 then
          return o
        end
      end
    end

    local first = panelRect()
    ok(first ~= nil, "there is a panel to measure")
    if not first then return end

    for _, key in ipairs({ "down", "left", "left", "left", "right", "up", "right" }) do
      hs.on.arrowKey(key)
      local r = panelRect()
      if not r then return fail("the panel vanished after " .. key) end
      eq(r.x, first.x, "panel x is unchanged after " .. key)
      eq(r.w, first.w, "panel width is unchanged after " .. key)
      eq(r.h, first.h, "panel height is unchanged after " .. key)
    end
  end)

  test("connect4: every difficulty plays a legal move", function()
    for level = 1, 4 do
      local hs = boot()
      -- Walk the menu to this difficulty, then start.
      hs.on.arrowKey("down")
      for _ = 2, level do hs.on.arrowKey("right") end
      hs.on.enterKey()

      local f = Frame.play(hs, 4, 1500)
      if not f then
        fail("level " .. level .. ": the board never settled")
      else
        eq(Frame.discCount(f), 2, "level " .. level .. ": the bot replied")
        eq(f.grid[(ROWS - 1) * COLS + 4], 1, "level " .. level .. ": the player's disc is where it was put")
        -- The bot's disc is somewhere on the board, resting on something --
        -- the floor, or the player's disc in column 4.
        local found = false
        for c = 1, COLS do
          for r = 1, ROWS do
            if f.grid[(r - 1) * COLS + c] == 2 then
              found = true
              local below = (r == ROWS) or (f.grid[r * COLS + c] ~= 0)
              ok(below, string.format("level %d: the bot's disc at %d,%d is supported", level, c, r))
            end
          end
        end
        ok(found, "level " .. level .. ": the bot played a disc")
      end
    end
  end)

  test("connect4: pausing stops the bot, resuming starts it again", function()
    local hs = boot()
    begin(hs)
    hs.on.charIn("4")
    for _ = 1, 6 do hs.on.timer() end -- into the bot's turn

    hs.on.escapeKey()
    local paused = Frame.read(select(2, hs:paint()))
    ok(paused.panel, "the pause panel is up")
    eq(paused.thinking, nil, "the bot is not searching behind it")

    local frozen = Frame.signature(paused)
    for _ = 1, 30 do hs.on.timer() end
    eq(Frame.signature(Frame.read(select(2, hs:paint()))), frozen,
      "nothing moved on the board while paused")

    hs.on.enterKey()
    local f = Frame.settle(hs)
    if not f then return fail("the game never settled after resuming") end
    eq(Frame.discCount(f), 2, "the bot took its move after the resume")
  end)

  test("connect4: M returns to the title screen from anywhere", function()
    local hs = boot()
    begin(hs)
    Frame.play(hs, 4)
    hs.on.charIn("m")
    local f = Frame.read(select(2, hs:paint()))
    ok(f.panel, "an overlay is up")
    eq(Frame.discCount(f), 0, "the board was cleared back to the title screen")
    -- And a new round still starts from there.
    hs.on.enterKey()
    local g = Frame.settle(hs)
    if not g then return fail("the game never settled after restarting") end
    ok(Frame.discCount(g) <= 1, "a fresh round began")
  end)
end
