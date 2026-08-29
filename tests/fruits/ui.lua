-- Fruits' own frame assertions, run by tests/run_ui.lua against the built
-- bundle. Everything is read back out of the paint calls through
-- tests/fruits/frame.lua, so none of this needs a hook in src/.
--
-- Two things here are worth more than the rest.
--
-- The first is that tests/fruits/frame.lua works out the runs and the legal
-- swaps for itself, from the picture. src/fruits/game.lua's own oracles check
-- the rules against a second implementation; this checks the *screen* against a
-- third, which is the only one of them that would notice the board being drawn
-- correctly but somewhere else, or a fruit being painted as the wrong sprite.
--
-- The second is that the game draws fruit two ways -- one gc:drawImage each, or
-- the same pixels as fillRects -- and both are exercised, then held against
-- each other. A fallback nothing tests is a fallback that does not work.

local Frame = require("fruits.frame")

return function(t)
  local test, ok, eq = t.test, t.ok, t.eq

  -- The same set tests/run_ui.lua renders at.
  local SIZES = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
  }

  local function started(w, h)
    local hs = t.boot(w, h)
    hs.on.enterKey()
    return hs
  end

  -- Labels differ between the two draw paths -- an image id one way, a set of
  -- colours the other -- so compare boards by the PATTERN of which cells match
  -- which, renumbered in first-seen order. That is all match-three ever asks.
  local function pattern(f)
    local seen, next_, out = {}, 0, {}
    for i = 1, 64 do
      local k = f.grid[i]
      if k == false or k == nil then
        out[i] = "."
      else
        if not seen[k] then next_ = next_ + 1; seen[k] = next_ end
        out[i] = tostring(seen[k])
      end
    end
    return table.concat(out, ","), next_
  end

  -- ------------------------------------------------------------ geometry --

  test("the board is eight by eight, square, and on the screen", function()
    for _, s in ipairs(SIZES) do
      local hs = started(s[1], s[2])
      local f = Frame.settle(hs)
      if #f.cells ~= 64 then
        t.fail(string.format("%dx%d: %d cells, want 64", s[1], s[2], #f.cells))
        return
      end
      eq(f.cols, 8, string.format("%dx%d: eight columns", s[1], s[2]))
      eq(f.rows, 8, string.format("%dx%d: eight rows", s[1], s[2]))
      for _, c in ipairs(f.cells) do
        if c.w ~= c.h then
          t.fail(string.format("%dx%d: a cell is %dx%d, not square",
                               s[1], s[2], c.w, c.h))
          return
        end
        if c.x < 0 or c.y < 0 or c.x + c.w > s[1] or c.y + c.h > s[2] then
          t.fail(string.format("%dx%d: a cell escapes the window at %d,%d",
                               s[1], s[2], c.x, c.y))
          return
        end
      end
    end
    t.ok(true, "every size laid out a whole board inside the window")
  end)

  test("nothing at all is drawn outside the window", function()
    for _, s in ipairs(SIZES) do
      local hs = started(s[1], s[2])
      Frame.settle(hs)
      -- Mid-cascade too, where fruit fall in from above the board and are
      -- deliberately allowed to overflow upward behind the HUD.
      for _ = 1, 30 do
        local _, ops = hs:paint()
        for _, o in ipairs(ops) do
          if o.op == "fillRect" or o.op == "drawRect" then
            if o.x + o.w < -64 or o.x > s[1] + 64 or o.y > s[2] + 64 then
              t.fail(string.format("%dx%d: a %s is far off-screen at %d,%d",
                                   s[1], s[2], o.op, o.x, o.y))
              return
            end
          end
        end
        Frame.tick(hs)
      end
    end
    t.ok(true, "nothing strayed anywhere absurd")
  end)

  -- ------------------------------------------------- the board on screen --

  test("a fresh board shows no run, read from the pixels", function()
    -- The third opinion. game.lua's fill makes an already-matching board
    -- unrepresentable and Fruit.scanRuns checks that claim against the rules;
    -- this checks it against what is actually painted.
    for _, s in ipairs({ { 318, 212 }, { 640, 480 }, { 240, 160 } }) do
      for launch = 1, 6 do
        local hs = t.boot(s[1], s[2])
        for _ = 1, launch * 5 do hs.on.timer() end   -- idle, which reseeds
        hs.on.enterKey()
        local f = Frame.settle(hs)
        local _, n = Frame.runs(f)
        if n ~= 0 then
          t.fail(string.format("%dx%d launch %d: %d cells already matching "
                               .. "on a fresh board", s[1], s[2], launch, n))
          return
        end
        if f.filled ~= 64 then
          t.fail(string.format("%dx%d launch %d: only %d of 64 cells hold fruit",
                               s[1], s[2], launch, f.filled))
          return
        end
      end
    end
    t.ok(true, "no fresh board painted a run")
  end)

  test("a fresh board always shows a legal swap", function()
    for launch = 1, 8 do
      local hs = t.boot(318, 212)
      for _ = 1, launch * 3 do hs.on.timer() end
      hs.on.enterKey()
      local f = Frame.settle(hs)
      local swaps = Frame.legalSwaps(f)
      if #swaps == 0 then
        t.fail("launch " .. launch .. " painted a board with no legal swap")
        return
      end
    end
    t.ok(true, "every launch opened on a playable board")
  end)

  test("different launches deal different boards", function()
    local seen, distinct = {}, 0
    for _, idle in ipairs({ 0, 3, 11, 40, 137 }) do
      local hs = t.boot(318, 212)
      for _ = 1, idle do hs.on.timer() end
      hs.on.enterKey()
      local sig = Frame.signature(Frame.settle(hs))
      if not seen[sig] then seen[sig] = true; distinct = distinct + 1 end
    end
    ok(distinct >= 4, distinct .. " of five launches dealt a different board")
  end)

  -- --------------------------------------------------------- the two paths --

  test("the handheld draws one image per fruit, not a heap of rects", function()
    local hs = started(318, 212)
    Frame.settle(hs)
    local f, _, calls = Frame.frame(hs)
    ok(f.images, "the image path is in use")
    eq(calls.drawImage, 64, "one drawImage per cell")
    ok(calls.fillRect < 100,
       "and few rects left over (" .. calls.fillRect .. ")")
  end)

  test("exactly seven different fruits appear", function()
    local hs = started(318, 212)
    local seen, distinct = {}, 0
    for _ = 1, 40 do
      local f = Frame.settle(hs)
      for i = 1, 64 do
        local k = f.grid[i]
        if k and not seen[k] then seen[k] = true; distinct = distinct + 1 end
      end
      if not Frame.step(hs) then break end
    end
    print("  note  " .. distinct .. " distinct sprites seen over a round")
    eq(distinct, 7, "seven distinct sprites over a whole round")
  end)

  test("a frame stays inside its draw budget", function()
    -- The device constraint this is really about: the board is repainted on
    -- every tick of a cascade, and the handheld's timer only manages about
    -- 0.05s. So the frame that matters is not the settled one -- it is the
    -- middle of a clear, where the bursting fruit shrink and therefore drop
    -- off the one-call image path onto the rects.
    --
    -- Measured in this container at roughly 0.13us a draw call, so the ceiling
    -- below is about 0.2ms here; at the 50x factor the other games in this repo
    -- assume for the handheld's ARM, about 10ms of a 50ms tick. If that factor
    -- is wrong the cascade just runs slower -- the phase machine counts ticks,
    -- not wall clock -- rather than freezing.
    local BUDGET = 1400
    local hs = started(318, 212)
    local worst, worstWhen, sampled = 0, "?", 0

    for move = 1, 15 do
      local f = Frame.settle(hs)
      local swaps = Frame.legalSwaps(f)
      if #swaps == 0 then break end
      local sw = swaps[1 + (move % #swaps)]
      hs.on.mouseDown(Frame.centre(f, sw[1], sw[2]))
      hs.on.mouseDown(Frame.centre(f, sw[3], sw[4]))

      -- Every frame of the cascade this swap starts, not just where it lands.
      for _ = 1, 300 do
        local _, _, calls = Frame.frame(hs)
        local total = calls.fillRect + calls.drawRect + calls.drawImage
                    + calls.drawLine + calls.drawString + calls.fillArc
        sampled = sampled + 1
        if total > worst then worst, worstWhen = total, "move " .. move end
        if not Frame.tick(hs) then break end
      end
    end

    print(string.format("  note  busiest of %d cascade frames drew %d draw "
                        .. "calls (%s); budget %d", sampled, worst, worstWhen, BUDGET))
    ok(sampled > 100, "sampled a real cascade (" .. sampled .. " frames)")
    ok(worst <= BUDGET, string.format(
      "worst frame drew %d ops (%s), budget %d", worst, worstWhen, BUDGET))
  end)

  test("the rect fallback paints the identical board", function()
    -- Make image.new fail the way an OS that will not take the string form
    -- would, and the game must fall back to the rects for every fruit -- and
    -- paint the same board, since it is the same art and the same seed.
    local realNew = t.stub.image.new
    t.stub.image.new = function() error("image.new: not supported here", 2) end
    local okay, viaRects = pcall(function()
      local hs = started(318, 212)
      Frame.settle(hs)
      local f, _, calls = Frame.frame(hs)
      ok(not f.images, "no images were built")
      eq(calls.drawImage, 0, "and nothing tried to draw one")
      ok(calls.fillRect > 1000,
         "the fruit arrived as rects instead (" .. calls.fillRect .. ")")
      eq(f.filled, 64, "all sixty-four cells still hold a fruit")
      local _, runs = Frame.runs(f)
      eq(runs, 0, "and the fresh board still shows no run")
      return pattern(f)
    end)
    t.stub.image.new = realNew
    ok(okay, "the fallback ran: " .. tostring(viaRects))

    if okay then
      -- Same document, same entropy, so the same deal: the two paths must
      -- paint boards with the same pattern of matching cells.
      local hs = started(318, 212)
      local viaImages = pattern(Frame.settle(hs))
      eq(viaRects, viaImages, "both draw paths paint the same board")
    end
  end)

  test("small cells fall back to rects rather than overlapping sprites", function()
    -- 120x90 leaves cells far under the sprite's sixteen pixels, so the game
    -- has to scale, which only the rects can do.
    local hs = started(120, 90)
    local f, _, calls = Frame.frame(Frame.settle(hs) and hs)
    ok(f.cell < 16, "cells really are smaller than a native sprite (" .. tostring(f.cell) .. ")")
    eq(calls.drawImage, 0, "so no native sprite was drawn")
    eq(f.filled, 64, "and every cell still shows something")
  end)

  -- ---------------------------------------------------------------- play --

  test("clicking two neighbours swaps them and clears the run", function()
    local hs = started(318, 212)
    local f = Frame.settle(hs)
    local swaps = Frame.legalSwaps(f)
    ok(#swaps > 0, "the board offers a swap")
    if #swaps == 0 then return end

    local s = swaps[1]
    local before = Frame.signature(f)
    hs.on.mouseDown(Frame.centre(f, s[1], s[2]))
    hs.on.mouseDown(Frame.centre(f, s[3], s[4]))
    local after = Frame.settle(hs)

    ok(Frame.signature(after) ~= before, "the board changed")
    eq(after.filled, 64, "and came back full")
    local _, runs = Frame.runs(after)
    eq(runs, 0, "with nothing left matching once it settled")
  end)

  test("an illegal swap goes back rather than being silently refused", function()
    local hs = started(318, 212)
    local f = Frame.settle(hs)

    -- Find a pair the frame-side brute force says is NOT a legal swap.
    local legal = {}
    for _, s in ipairs(Frame.legalSwaps(f)) do
      legal[s[1] .. "," .. s[2] .. "," .. s[3] .. "," .. s[4]] = true
    end
    local px, py
    for y = 1, 8 do
      for x = 1, 7 do
        if not legal[x .. "," .. y .. "," .. (x + 1) .. "," .. y]
           and f.grid[(y - 1) * 8 + x] ~= f.grid[(y - 1) * 8 + x + 1] then
          px, py = x, y
          break
        end
      end
      if px then break end
    end
    ok(px ~= nil, "found a swap that makes nothing")
    if not px then return end

    local before = Frame.signature(f)
    hs.on.mouseDown(Frame.centre(f, px, py))
    hs.on.mouseDown(Frame.centre(f, px + 1, py))

    -- It must actually go somewhere first: a swap that is refused outright
    -- leaves the player wondering whether the click registered.
    local moved = false
    for _ = 1, 20 do
      if Frame.signature(Frame.frame(hs)) ~= before then moved = true end
      if not Frame.tick(hs) then break end
    end
    ok(moved, "the two fruit visibly traded places")
    eq(Frame.signature(Frame.settle(hs)), before, "and then went back")
  end)

  test("the cursor moves with the arrows and stays on the board", function()
    local hs = started(318, 212)
    local f = Frame.settle(hs)
    ok(f.cursor ~= nil, "a cursor is drawn")

    local keys = { "up", "down", "left", "right" }
    for i = 1, 200 do
      hs.on.arrowKey(keys[(i % 4) + 1])
      if i % 5 == 0 then hs.on.charIn(({ "2", "4", "6", "8" })[(i % 4) + 1]) end
      local g = Frame.frame(hs)
      if not g.cursor then
        t.fail("the cursor left the board after " .. i .. " keys")
        return
      end
      if g.cursor.x < 1 or g.cursor.x > 8 or g.cursor.y < 1 or g.cursor.y > 8 then
        t.fail(string.format("cursor at %d,%d", g.cursor.x, g.cursor.y))
        return
      end
    end
    t.ok(true, "the cursor never left the grid")
  end)

  test("enter picks a fruit up and an arrow then swaps it", function()
    local hs = started(318, 212)
    local f = Frame.settle(hs)

    -- Walk the cursor to the left end of a legal swap, pick up, push right.
    local s = Frame.legalSwaps(f)[1]
    ok(s ~= nil, "there is a swap to make")
    if not s then return end
    if s[3] ~= s[1] + 1 then return end   -- want a horizontal one for this

    for _ = 1, 8 do hs.on.arrowKey("left") end
    for _ = 1, 8 do hs.on.arrowKey("up") end
    for _ = 2, s[1] do hs.on.arrowKey("right") end
    for _ = 2, s[2] do hs.on.arrowKey("down") end

    local g = Frame.frame(hs)
    eq(g.cursor.x, s[1], "cursor is where we steered it")
    eq(g.cursor.y, s[2], "in both axes")

    hs.on.enterKey()
    g = Frame.frame(hs)
    ok(g.sel ~= nil, "enter drew the pick-up marker")

    local before = Frame.signature(g)
    hs.on.arrowKey("right")
    local after = Frame.settle(hs)
    ok(Frame.signature(after) ~= before, "one arrow was the whole swap")
    eq(after.filled, 64, "and the board came back full")
  end)

  test("the hint marks a swap that really is legal", function()
    local hs = started(318, 212)
    local f = Frame.settle(hs)
    hs.on.charIn("h")
    local g = Frame.frame(hs)
    ok(g.hint and #g.hint == 2, "two cells are lit")
    if not (g.hint and #g.hint == 2) then return end

    local a, b = g.hint[1], g.hint[2]
    local legal = false
    for _, s in ipairs(Frame.legalSwaps(f)) do
      if (s[1] == a.x and s[2] == a.y and s[3] == b.x and s[4] == b.y)
         or (s[1] == b.x and s[2] == b.y and s[3] == a.x and s[4] == a.y) then
        legal = true
      end
    end
    ok(legal, "and the frame's own brute force agrees the pair is a legal swap")
  end)

  test("the score on screen goes up when a run clears", function()
    local hs = started(318, 212)
    local function scoreText()
      local f = Frame.frame(hs)
      for i, s in ipairs(f.text) do
        if s == "SCORE" and f.text[i + 1] then return f.text[i + 1] end
      end
      return nil
    end
    eq(scoreText(), "0", "starts at nought")
    Frame.step(hs)
    local after = tonumber(scoreText() or "0")
    ok(after and after > 0, "and rises after a clear (" .. tostring(after) .. ")")
  end)

  test("a round played to the end says so", function()
    local hs = started(318, 212)
    for _ = 1, 4000 do
      if not Frame.step(hs) then break end
    end
    local f = Frame.frame(hs)
    local said = false
    for _, s in ipairs(f.text) do
      if s == "NO MOVES LEFT" then said = true end
    end
    ok(said, "the deadlock panel is up")
    eq(#Frame.legalSwaps(Frame.read(select(2, hs:paint()))), 0,
       "and the frame's own brute force agrees there is nothing left")
  end)

  test("pause and restart behave", function()
    local hs = started(318, 212)
    Frame.step(hs)
    hs.on.escapeKey()
    local f = Frame.frame(hs)
    local paused = false
    for _, s in ipairs(f.text) do if s == "PAUSED" then paused = true end end
    ok(paused, "esc paused it")

    hs.on.escapeKey()
    hs.on.charIn("r")
    local g = Frame.settle(hs)
    eq(g.filled, 64, "restart dealt a full board")
    local _, runs = Frame.runs(g)
    eq(runs, 0, "with no run on it")
  end)
end
