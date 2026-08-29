-- Slide-specific frame assertions, run by tests/run_ui.lua after its generic
-- suite. The two headline claims are the ones a screenshot would have shown
-- you: no tile ever escapes the grid, at any window size the software can
-- produce, settled or mid-slide; and every tile's number fits inside its own
-- tile at all three board sizes.

local Frame = require("slide.frame")

local SIZES = {
  { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
  { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
}

local BOARDS = { 3, 4, 5 }

local function within(r, box)
  return r.x >= box.x and r.y >= box.y
    and r.x + r.w <= box.x + box.w
    and r.y + r.h <= box.y + box.h
end

-- The game starts at 4x4 and S cycles 3 -> 4 -> 5, so this is how a test asks
-- for a particular board size without reaching into the script.
local function boardOfSize(boot, n, w, h)
  local hs = boot(w, h)
  for _ = 1, 3 do
    local f = Frame.read(select(2, hs:paint()))
    if f.n == n then return hs, f end
    hs.on.charIn("s")
  end
  return hs, Frame.read(select(2, hs:paint()))
end

return function(t)
  local test, ok, eq, fail, boot, stub = t.test, t.ok, t.eq, t.fail, t.boot, t.stub

  local function assertContained(f, label)
    if not f.board then return fail(label .. ": no board drawn") end

    local out = 0
    for _, c in ipairs(f.cells) do
      if not within(c, f.board) then out = out + 1 end
    end
    eq(out, 0, label .. ": cell backings inside the board")

    out = 0
    local oversize = 0
    for _, tl in ipairs(f.tiles) do
      if not within(tl.rect, f.board) then out = out + 1 end
      if f.size and tl.rect.w > f.size then oversize = oversize + 1 end
    end
    eq(out, 0, label .. ": tiles inside the board")
    eq(oversize, 0, label .. ": no tile drawn larger than a cell")
    ok(#f.tiles <= f.n * f.n - 1,
      label .. ": never more tiles than cells-minus-the-gap, got " .. #f.tiles)
  end

  test("slide: the board is square and fits inside the window", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local f = Frame.read(select(2, hs:paint()))
      if not f.board then
        fail(label .. ": no board drawn")
      else
        eq(f.board.w, f.board.h, label .. ": board is square")
        ok(f.board.x >= 0 and f.board.y >= 0, label .. ": board starts on screen")
        ok(f.board.x + f.board.w <= s[1], label .. ": board fits the window width")
        ok(f.board.y + f.board.h <= s[2], label .. ": board fits the window height")
        ok(f.hud ~= nil, label .. ": drew the status bar")
      end
    end
  end)

  test("slide: every board size draws its full grid", function()
    for _, n in ipairs(BOARDS) do
      local hs, f = boardOfSize(boot, n)
      local label = n .. "x" .. n
      eq(f.n, n, label .. ": S reached this size")
      eq(#f.cells, n * n, label .. ": drew one backing per cell")
      eq(#f.tiles, n * n - 1, label .. ": drew every tile but the gap")

      -- The deal is on the title screen, and it is never already solved --
      -- that is the shuffler's promise, checked here through the paint calls.
      hs.on.enterKey()
      local g = Frame.read(select(2, hs:paint()))
      ok(g.gap ~= nil, label .. ": exactly one cell is empty")
      ok(Frame.homeCount(g) < n * n - 1, label .. ": the deal is not already solved")
      ok(Frame.manhattan(g) > 0, label .. ": the deal is scrambled (Manhattan "
        .. Frame.manhattan(g) .. ")")
    end
  end)

  test("slide: nothing escapes the grid at any window size", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      assertContained(Frame.read(select(2, hs:paint())), label .. " title")

      hs.on.enterKey()
      local f = Frame.frame(hs)
      local avoid
      for i = 1, 40 do
        local nf, _, came = Frame.step(hs, f, avoid)
        if not nf then break end
        f, avoid = nf, came
        if i % 8 == 0 then assertContained(f, label .. " move " .. i) end
      end
      assertContained(Frame.read(select(2, hs:paint())), label .. " final")
    end
  end)

  test("slide: tiles stay inside the grid mid-slide too", function()
    -- Every frame of the animation, not just the settled ones: a slide draws
    -- tiles between cells, which is exactly where an off-by-one escapes. A run
    -- slide moves several tiles at once, so this also covers the multi-tile
    -- case the arrow keys never produce.
    for _, s in ipairs({ { 318, 212 }, { 120, 90 }, { 900, 700 }, { 200, 480 } }) do
      for _, n in ipairs(BOARDS) do
        local hs = boardOfSize(boot, n, s[1], s[2])
        local label = string.format("%dx%d %dx%d", s[1], s[2], n, n)
        hs.on.enterKey()

        local sawMidSlide, sawRun = false, false
        for move = 1, 25 do
          local f = Frame.frame(hs)
          if not f.gap then break end

          -- Click the far end of the gap's row, which drags a whole run.
          local gx = (f.gap - 1) % n + 1
          local gy = math.floor((f.gap - 1) / n) + 1
          local tx = (gx == 1) and n or 1
          Frame.click(hs, f, tx, gy)
          if math.abs(tx - gx) > 1 then sawRun = true end

          for tick = 0, 5 do
            local g = Frame.read(select(2, hs:paint()))
            assertContained(g, label .. " slide " .. move .. "@" .. tick)
            if g.settled == false then sawMidSlide = true end
            hs.on.timer()
          end
        end
        ok(sawMidSlide, label .. ": actually caught tiles in flight")
        ok(sawRun, label .. ": and at least one of them was a multi-tile run")
      end
    end
  end)

  test("slide: every tile's number fits inside its own tile", function()
    -- Measured with the same getStringWidth the game used, so this is the
    -- claim that the shrink-to-fit in main.lua really shrinks far enough. The
    -- interesting case is 5x5, whose two-digit numbers have to come down a
    -- size or two from what 3x3 can afford.
    local gc = stub.newGC()
    local checked, byBoard = 0, {}

    for _, s in ipairs({ { 318, 212 }, { 240, 160 }, { 640, 480 } }) do
      for _, n in ipairs(BOARDS) do
        local hs = boardOfSize(boot, n, s[1], s[2])
        local label = string.format("%dx%d at %dx%d", n, n, s[1], s[2])
        hs.on.enterKey()

        local f = Frame.frame(hs)
        local avoid
        for _ = 1, 30 do
          for _, tl in ipairs(f.tiles) do
            local lb = tl.label
            if lb then
              gc:setFont("sansserif", lb.style, lb.size)
              local w = gc:getStringWidth(lb.text)
              local r = tl.rect
              if lb.x < r.x or lb.x + w > r.x + r.w then
                return fail(string.format("%s: '%s' (size %d, %dpx) overflows its %dpx tile",
                  label, lb.text, lb.size, w, r.w))
              end
              if lb.y < r.y or lb.y + lb.size > r.y + r.h then
                return fail(string.format("%s: '%s' sits outside its tile vertically",
                  label, lb.text))
              end
              checked = checked + 1
              if s[1] == 318 then byBoard[n] = lb.size end
            end
          end

          -- One font for the whole board: fitting each number to its own tile
          -- would set "1" larger than "24" and the grid would look ragged.
          local sizes = {}
          for _, tl in ipairs(f.tiles) do
            if tl.label then sizes[tl.label.size] = true end
          end
          local distinct = 0
          for _ in pairs(sizes) do distinct = distinct + 1 end
          if distinct > 1 then
            return fail(label .. ": tiles drawn at " .. distinct .. " different font sizes")
          end

          local nf, _, came = Frame.step(hs, f, avoid)
          if not nf then break end
          f, avoid = nf, came
        end
      end
    end

    ok(checked > 500, "measured a lot of labels (" .. checked .. ")")
    ok(byBoard[3] and byBoard[5], "saw labels on both the smallest and largest board")
    if byBoard[3] and byBoard[5] then
      ok(byBoard[5] < byBoard[3], string.format(
        "at 318x212 a 5x5's two-digit numbers (%d) are set smaller than a 3x3's (%d)",
        byBoard[5], byBoard[3]))
    end
  end)

  test("slide: the highlight marks exactly the tiles that are home", function()
    for _, n in ipairs(BOARDS) do
      local hs = boardOfSize(boot, n)
      hs.on.enterKey()
      local f = Frame.frame(hs)
      local avoid, wrong, everHome = nil, 0, false

      for _ = 1, 60 do
        for _, tl in ipairs(f.tiles) do
          if tl.value then
            local atHome = (tl.value == tl.cell)
            if atHome then everHome = true end
            if tl.home ~= atHome then wrong = wrong + 1 end
          end
        end
        local nf, _, came = Frame.step(hs, f, avoid)
        if not nf then break end
        f, avoid = nf, came
      end

      eq(wrong, 0, n .. "x" .. n .. ": tiles whose highlight disagreed with their cell")
      ok(everHome, n .. "x" .. n .. ": some tile did reach its home cell")
    end
  end)

  test("slide: 2/4/6/8 do exactly what the arrows do", function()
    -- The number pad is laid out 7 8 9 / 4 5 6 / 1 2 3, so these four digits
    -- sit where the arrows point. All on one board: a second harness would
    -- deal a different scramble, which is the point of the game owning its
    -- generator.
    local hs = boot()
    hs.on.enterKey()
    local start = Frame.signature(Frame.frame(hs))

    for _, pair in ipairs({ { "up", "8" }, { "down", "2" },
                            { "left", "4" }, { "right", "6" } }) do
      hs.on.arrowKey(pair[1])
      Frame.settle(hs)
      local byArrow = Frame.signature(Frame.frame(hs))

      hs.on.charIn("u")
      Frame.settle(hs)
      eq(Frame.signature(Frame.frame(hs)), start, "undo returned to the deal")

      hs.on.charIn(pair[2])
      Frame.settle(hs)
      eq(Frame.signature(Frame.frame(hs)), byArrow,
        pair[2] .. " does what " .. pair[1] .. " does")

      hs.on.charIn("u")
      Frame.settle(hs)
    end

    -- The digits that are not directions must be inert, not wired to something
    -- surprising, and neither must the letters the generic suite presses.
    for _, ch in ipairs({ "0", "1", "3", "5", "7", "9", "z", "q", "!" }) do
      hs.on.charIn(ch)
      Frame.settle(hs)
    end
    eq(Frame.signature(Frame.frame(hs)), start, "junk keys moved nothing")
  end)

  test("slide: undo puts the previous board back on screen", function()
    local hs = boot()
    hs.on.enterKey()
    local f = Frame.frame(hs)

    local history = { Frame.signature(f) }
    local avoid
    for _ = 1, 8 do
      local nf, _, came = Frame.step(hs, f, avoid)
      if not nf then break end
      f, avoid = nf, came
      history[#history + 1] = Frame.signature(f)
    end
    ok(#history > 4, "made some moves to undo")

    -- Unlimited undo, all the way back to the deal, alternating the two keys.
    local mismatched = 0
    for i = #history - 1, 1, -1 do
      if i % 2 == 0 then hs.on.charIn("u") else hs.on.backspaceKey() end
      Frame.settle(hs)
      if Frame.signature(Frame.frame(hs)) ~= history[i] then mismatched = mismatched + 1 end
    end
    eq(mismatched, 0, "undos that landed on the wrong board")

    hs.on.charIn("u")
    Frame.settle(hs)
    eq(Frame.signature(Frame.frame(hs)), history[1], "undoing past the deal is a no-op")
  end)

  test("slide: the overlay panel never covers the status bar", function()
    for _, s in ipairs({ { 318, 212 }, { 160, 120 }, { 640, 480 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local _, ops = hs:paint()
      local panel
      for _, o in ipairs(ops) do
        if o.op == "fillRect" and o.color[1] == 26 and o.color[2] == 30 and o.color[3] == 39 then
          panel = o
        end
      end
      if panel then
        ok(panel.y >= 22, label .. ": panel starts below the status bar")
        ok(panel.x + panel.w <= s[1], label .. ": panel fits the window width")
        ok(panel.y + panel.h <= s[2], label .. ": panel fits the window height")
      else
        fail(label .. ": the title screen drew no panel")
      end
    end
  end)

  test("slide: the hint solves a 3x3 and the win panel comes up", function()
    -- Drives the sliced search through the timer exactly as the handheld
    -- would, and proves the whole chain: search, plan, replay, win detection.
    local hs = boardOfSize(boot, 3)
    hs.on.enterKey()
    local before = Frame.signature(Frame.frame(hs))

    local moves, ticks = 0, 0
    for _ = 1, 200 do
      local sig = Frame.signature(Frame.frame(hs))
      hs.on.charIn("h")
      -- The first hint has to search; the ones after it replay a plan already
      -- in hand and land on the very next tick.
      local waited = 0
      while waited < 4000 do
        hs.on.timer()
        ticks, waited = ticks + 1, waited + 1
        local f = Frame.frame(hs)
        if f.settled and Frame.signature(f) ~= sig then break end
        if f.panel then break end
      end
      moves = moves + 1
      if Frame.read(select(2, hs:paint())).panel then break end
    end

    local f = Frame.read(select(2, hs:paint()))
    ok(f.panel, "the hint played the puzzle out to a panel (" .. moves .. " hints, "
      .. ticks .. " ticks)")
    ok(Frame.signature(Frame.frame(hs)) ~= before, "the board moved")

    -- The panel is the win panel, not a pause: it says SOLVED.
    local said = false
    for _, s in ipairs(f.strings) do
      if s.text == "SOLVED!" then said = true end
    end
    ok(said, "and the panel says SOLVED")

    -- Enter deals a fresh puzzle, which is scrambled again.
    hs.on.enterKey()
    Frame.settle(hs)
    local g = Frame.frame(hs)
    ok(not g.panel, "enter cleared the panel")
    ok(Frame.homeCount(g) < 8, "and dealt a scrambled 3x3")
  end)

  test("slide: cycling the size deals a new puzzle at that size", function()
    local hs = boot()
    hs.on.enterKey()
    local seen = {}
    for _ = 1, 6 do
      local f = Frame.frame(hs)
      seen[f.n] = true
      eq(#f.cells, f.n * f.n, "grid matches the size on screen")
      ok(f.gap ~= nil, f.n .. "x" .. f.n .. ": exactly one gap")
      ok(Frame.manhattan(f) > 0, f.n .. "x" .. f.n .. ": redealt scrambled")
      hs.on.charIn("s")
      Frame.settle(hs)
    end
    ok(seen[3] and seen[4] and seen[5], "S visited all three board sizes")
  end)

  test("slide: inverting the arrows mirrors what they do", function()
    local hs = boot()
    hs.on.enterKey()
    local before = Frame.signature(Frame.frame(hs))

    -- All on one board: two boots deal two different puzzles, which is the
    -- whole point of the game owning its generator, so a second harness would
    -- be comparing different scrambles.
    for _, p in ipairs({ { "left", "right" }, { "up", "down" } }) do
      hs.on.arrowKey(p[1])
      Frame.settle(hs)
      local normal = Frame.signature(Frame.frame(hs))

      hs.on.charIn("u")         -- back to where we started
      Frame.settle(hs)
      eq(Frame.signature(Frame.frame(hs)), before, "undo returned to the deal")

      hs.on.charIn("i")         -- invert
      hs.on.arrowKey(p[2])
      Frame.settle(hs)
      eq(Frame.signature(Frame.frame(hs)), normal,
        p[1] .. " normally is " .. p[2] .. " inverted")

      hs.on.charIn("i")         -- back to the normal convention
      hs.on.charIn("u")
      Frame.settle(hs)
    end

    hs.on.charIn("i")
    hs.on.charIn("i")
    Frame.settle(hs)
    eq(Frame.signature(Frame.frame(hs)), before, "toggling twice moved nothing")
  end)
end
