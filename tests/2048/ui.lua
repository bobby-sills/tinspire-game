-- 2048-specific frame assertions, run by tests/run_ui.lua after its generic
-- suite. The headline claim is the one a screenshot would have shown you:
-- no tile ever escapes the grid, at any window size the software can produce,
-- settled or mid-slide.

local Frame = require("2048.frame")

local SIZES = {
  { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
  { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
}

local function within(r, box)
  return r.x >= box.x and r.y >= box.y
    and r.x + r.w <= box.x + box.w
    and r.y + r.h <= box.y + box.h
end

return function(t)
  local test, ok, eq, fail, boot, stub = t.test, t.ok, t.eq, t.fail, t.boot, t.stub

  -- The core invariant, checked on whatever frame it is handed.
  local function assertContained(f, label)
    if not f.board then return fail(label .. ": no board drawn") end
    eq(#f.cells, 16, label .. ": drew 16 cell backings")

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
    ok(#f.tiles <= 16, label .. ": at most 16 tiles on screen, got " .. #f.tiles)
  end

  test("2048: the board is square and fits inside the window", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local f = Frame.read(select(2, hs:paint()))
      if not f.board then
        fail(label .. ": no board drawn")
      else
        eq(f.board.w, f.board.h, label .. ": board is square")
        ok(f.board.x >= 0 and f.board.y >= 0, label .. ": board starts on screen")
        ok(f.board.w > 0, label .. ": board has a size")
        ok(f.hud ~= nil, label .. ": drew the score bar")
      end
    end
  end)

  test("2048: nothing escapes the grid at any window size", function()
    for _, s in ipairs(SIZES) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])

      assertContained(Frame.read(select(2, hs:paint())), label .. " title")

      hs.on.enterKey()
      for i = 1, 120 do
        local f = Frame.step(hs)
        if not f then break end -- the round ended
        if i % 10 == 0 then assertContained(f, label .. " move " .. i) end
      end
      assertContained(Frame.read(select(2, hs:paint())), label .. " final")
    end
  end)

  test("2048: tiles stay inside the grid mid-slide too", function()
    -- Every frame of the animation, not just the settled ones: a slide draws
    -- tiles between cells, which is exactly where an off-by-one escapes.
    for _, s in ipairs({ { 318, 212 }, { 120, 90 }, { 900, 700 }, { 200, 480 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      hs.on.enterKey()

      local sawMidSlide = false
      for move = 1, 60 do
        if not Frame.step(hs) then break end
        for _, dir in ipairs(Frame.ORDER) do
          hs.on.arrowKey(dir)
          -- Paint every tick of the animation, from t=0 to settled.
          for tick = 0, 6 do
            local f = Frame.read(select(2, hs:paint()))
            assertContained(f, label .. " slide " .. move .. "/" .. dir .. "@" .. tick)
            if f.settled == false then sawMidSlide = true end
            hs.on.timer()
          end
        end
      end
      ok(sawMidSlide, label .. ": actually caught tiles in flight")
    end
  end)

  test("2048: every tile's digits fit inside its own tile", function()
    -- Measured with the same getStringWidth the game used, so this is the
    -- claim that the shrink-to-fit in main.lua really shrinks far enough.
    local gc = stub.newGC()
    local checked, byDigits = 0, {}   -- byDigits: handheld only, see below

    for _, s in ipairs({ { 318, 212 }, { 240, 160 }, { 640, 480 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      hs.on.enterKey()

      for move = 1, 400 do
        local f = Frame.step(hs)
        if not f then break end

        local perFrame = {}
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
              return fail(string.format("%s: '%s' sits outside its tile vertically", label, lb.text))
            end
            checked = checked + 1

            local digits = #lb.text
            perFrame[digits] = math.max(perFrame[digits] or 0, lb.size)
            -- Only the handheld feeds byDigits: on a 640x480 window the cells
            -- are roomy enough that "128" and "2" both take the largest font,
            -- which is correct behaviour and would mask the shrink here.
            if s[1] == 318 then
              byDigits[digits] = math.max(byDigits[digits] or 0, lb.size)
            end
          end
        end

        -- Within one frame every tile is the same size, so a wider number
        -- must be set in a smaller font than a narrower one.
        for wide = 2, 5 do
          for narrow = 1, wide - 1 do
            if perFrame[wide] and perFrame[narrow] and perFrame[wide] > perFrame[narrow] then
              return fail(string.format("%s: %d digits set at %d, but %d digits only at %d",
                label, wide, perFrame[wide], narrow, perFrame[narrow]))
            end
          end
        end
      end
    end

    ok(checked > 500, "measured a lot of labels (" .. checked .. ")")
    -- Guard rather than compare straight away: if the autopilot never reached
    -- 128 the next assertion would crash on a nil instead of reporting which
    -- expectation actually broke.
    if ok((byDigits[3] or 0) > 0, "the autopilot reached a three-digit tile at 318x212") ~= false
      and byDigits[3] then
      ok(byDigits[3] < (byDigits[1] or 0),
        string.format("at 318x212 three digits (%d) are set smaller than one (%d)",
          byDigits[3], byDigits[1] or 0))
    end
  end)

  test("2048: undo puts the previous board back on screen", function()
    local hs = boot()
    hs.on.enterKey()
    for _ = 1, 6 do
      if not Frame.step(hs) then break end
    end

    local before = Frame.signature(Frame.frame(hs))
    local moved = false
    for _, dir in ipairs(Frame.ORDER) do
      hs.on.arrowKey(dir)
      Frame.settle(hs)
      if Frame.signature(Frame.frame(hs)) ~= before then moved = true; break end
    end
    ok(moved, "made a move to undo")

    hs.on.charIn("u")
    Frame.settle(hs)
    eq(Frame.signature(Frame.frame(hs)), before, "U restored the board")

    -- Backspace is the other undo key, and one level is all there is.
    hs.on.backspaceKey()
    Frame.settle(hs)
    eq(Frame.signature(Frame.frame(hs)), before, "a second undo is a no-op")
  end)

  test("2048: the overlay panel never covers the score bar", function()
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
        ok(panel.y >= 22, label .. ": panel starts below the score bar")
        ok(panel.x + panel.w <= s[1], label .. ": panel fits the window width")
        ok(panel.y + panel.h <= s[2], label .. ": panel fits the window height")
      else
        fail(label .. ": the title screen drew no panel")
      end
    end
  end)

  test("2048: a round can be played to game over and restarted", function()
    local hs = boot()
    hs.on.enterKey()
    local moves = 0
    for _ = 1, 3000 do
      if not Frame.step(hs) then break end
      moves = moves + 1
    end
    ok(moves > 40, "the autopilot got a real game in (" .. moves .. " moves)")

    local f = Frame.frame(hs)
    ok(f.panel, "ended on an overlay panel")
    ok(Frame.maxTile(f) >= 64, "built something worth looking at (max " .. Frame.maxTile(f) .. ")")

    hs.on.enterKey()
    Frame.settle(hs)
    local fresh = Frame.frame(hs)
    local tiles = 0
    for _, v in ipairs(fresh.grid) do if v ~= 0 then tiles = tiles + 1 end end
    eq(tiles, 2, "restart dealt a fresh two-tile board")
  end)
end
