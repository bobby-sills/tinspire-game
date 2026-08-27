-- Flappy-specific frame assertions, run by tests/run_ui.lua after its generic
-- suite. It passes in the shared helpers so these read like the tests there.
--
-- Ten checks that were duplicated from the generic runner (handlers exist,
-- junk input, resize, soak, ...) now come from tests/run_ui.lua itself. What
-- remains is what only Flappy can assert: that the world scrolls, that gravity
-- and flapping do their jobs, and that every gap is actually flyable.

return function(t)
  local test, ok, eq, fail, boot = t.test, t.ok, t.eq, t.fail, t.boot

  -- Colours src/flappy/main.lua reserves for exactly one thing each, so a
  -- frame can be read back without reaching into the script's internals.
  local SKY_RGB  = { 18, 28, 48 }
  local PIPE_RGB = { 86, 190, 92 }
  local BIRD_RGB = { 252, 210, 74 }

  local function isColor(c, want)
    return c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
  end

  local function frameGeometry(ops)
    local g = { pipes = {} }
    for _, o in ipairs(ops) do
      if o.op == "fillRect" then
        if isColor(o.color, SKY_RGB) then
          g.field = o
        elseif isColor(o.color, BIRD_RGB) then
          g.bird = o
        elseif isColor(o.color, PIPE_RGB) then
          g.pipes[#g.pipes + 1] = o
        end
      end
    end
    return g
  end

  -- ------------------------------------------------------------------ tests --

  local function assertInsideField(ops, label)
    local g = frameGeometry(ops)
    if not g.field then return fail(label .. ": no playfield drawn") end
    local top, bottom = g.field.y, g.field.y + g.field.h

    if g.bird then
      ok(g.bird.y >= top and g.bird.y + g.bird.h <= bottom,
        label .. ": bird inside the playfield vertically")
      ok(g.bird.x >= g.field.x and g.bird.x + g.bird.w <= g.field.x + g.field.w,
        label .. ": bird inside the playfield horizontally")
    end

    local escaped = 0
    for _, p in ipairs(g.pipes) do
      if p.y < top or p.y + p.h > bottom then escaped = escaped + 1 end
    end
    eq(escaped, 0, label .. ": pipe columns confined to the sky")
  end

  test("flappy: the world scrolls and the bird falls without input", function()
    local hs = boot()
    hs.on.enterKey() -- start flying
    local _, first = hs:paint()
    local a = frameGeometry(first)
    local y0 = a.bird.y
    local x0 = a.pipes[1] and a.pipes[1].x

    -- The keypress that starts the round also flaps, so the bird climbs for the
    -- first half-second. Run past that before asking whether gravity works.
    for _ = 1, 7 do hs.on.timer() end
    local _, apex = hs:paint()
    ok(frameGeometry(apex).bird.y < y0, "the starting press flapped, so the bird rose first")

    for _ = 1, 20 do hs.on.timer() end
    local _, later = hs:paint()
    local b = frameGeometry(later)

    ok(b.bird.y > y0, "gravity then pulled it back down (" .. y0 .. " -> " .. b.bird.y .. ")")
    if x0 then
      local nearest = nil
      for _, p in ipairs(b.pipes) do
        if not nearest or math.abs(p.x - x0) < math.abs(nearest - x0) then nearest = p.x end
      end
      ok(nearest and nearest < x0, "the course scrolled left")
    end
  end)

  test("flappy: flapping lifts the bird", function()
    local hs = boot()
    hs.on.enterKey()
    for _ = 1, 6 do hs.on.timer() end
    local _, before = hs:paint()
    local y0 = frameGeometry(before).bird.y

    -- Flap on every frame: the bird has to end up higher than it started.
    for _ = 1, 6 do
      hs.on.enterKey()
      hs.on.timer()
    end
    local _, after = hs:paint()
    local y1 = frameGeometry(after).bird.y
    ok(y1 < y0, "sustained flapping climbed (" .. y0 .. " -> " .. y1 .. ")")

    -- Every input that should flap, does.
    for _, press in ipairs({
      function(h) h.on.charIn(" ") end,
      function(h) h.on.charIn("w") end,
      function(h) h.on.charIn("8") end,
      function(h) h.on.arrowKey("up") end,
      function(h) h.on.mouseDown(100, 100) end,
    }) do
      local h = boot()
      h.on.enterKey()
      for _ = 1, 8 do h.on.timer() end
      local _, o1 = h:paint()
      local ya = frameGeometry(o1).bird.y
      for _ = 1, 5 do press(h); h.on.timer() end
      local _, o2 = h:paint()
      ok(frameGeometry(o2).bird.y < ya, "this input flaps")
    end
  end)

  test("flappy: pausing actually stops the world", function()
    local hs = boot()
    hs.on.enterKey()
    for _ = 1, 15 do hs.on.timer() end
    hs.on.escapeKey()
    local _, a = hs:paint()
    local ya = frameGeometry(a).bird.y
    for _ = 1, 40 do hs.on.timer() end
    local _, b = hs:paint()
    eq(frameGeometry(b).bird.y, ya, "the bird did not move while paused")
  end)

  test("flappy: dying is reachable, survivable and restartable", function()
    local hs = boot()
    hs.on.enterKey()
    for _ = 1, 400 do hs.on.timer() end -- never flap: fall out of the sky
    local _, ops = hs:paint()

    local sawGameOver = false
    for _, o in ipairs(ops) do
      if o.op == "drawString" and o.text == "GAME OVER" then sawGameOver = true end
    end
    ok(sawGameOver, "the game-over panel is on screen")

    hs.on.enterKey() -- play again
    for _ = 1, 20 do hs.on.timer(); hs:paint() end
    local _, ops2 = hs:paint()
    local again = false
    for _, o in ipairs(ops2) do
      if o.op == "drawString" and o.text == "GAME OVER" then again = true end
    end
    ok(not again, "restarting cleared the panel")
  end)

  test("flappy: nothing is drawn outside the playfield", function()
    for _, s in ipairs({ { 318, 212 }, { 640, 480 }, { 240, 160 }, { 160, 120 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local _, ops = hs:paint()
      assertInsideField(ops, label .. " title")

      hs.on.enterKey()
      for i = 1, 600 do
        hs.on.timer()
        if i % 4 == 0 then hs.on.enterKey() end
        if i % 150 == 0 then
          local _, playOps = hs:paint()
          assertInsideField(playOps, label .. " playing@" .. i)
        end
      end
    end
  end)

  test("flappy: every gap on screen is wide enough for the bird", function()
    -- Group the pipe columns by x and measure the opening between each pair.
    local hs = boot()
    hs.on.enterKey()
    local narrowest = math.huge
    for i = 1, 2500 do
      hs.on.timer()
      if i % 4 == 0 then hs.on.enterKey() end
      if i % 25 == 0 then
        local _, ops = hs:paint()
        local g = frameGeometry(ops)
        local byX = {}
        for _, p in ipairs(g.pipes) do
          byX[p.x] = byX[p.x] or {}
          table.insert(byX[p.x], p)
        end
        for _, cols in pairs(byX) do
          if #cols == 2 then
            table.sort(cols, function(a, b) return a.y < b.y end)
            local gap = cols[2].y - (cols[1].y + cols[1].h)
            if gap < narrowest then narrowest = gap end
          end
        end
      end
    end
    ok(narrowest > 12, "narrowest opening seen was " .. narrowest .. " px, clear of the 9px bird")
  end)

  test("flappy: a long flown round stays within the draw budget", function()
    -- The handheld redraws the whole screen every frame at 20 FPS. If the pipe
    -- list ever leaked, this is where the op count would give it away.
    local hs = boot()
    hs.on.enterKey()
    local worst = 0
    for i = 1, 4000 do
      hs.on.timer()
      if i % 4 == 0 then hs.on.enterKey() end
      if i % 20 == 0 then
        local calls = hs:paint()
        local total = calls.fillRect + calls.drawRect + calls.drawString + calls.drawLine
        if total > worst then worst = total end
      end
    end
    ok(worst < 120, "peak draw calls per frame stayed bounded (" .. worst .. ")")
  end)
end
