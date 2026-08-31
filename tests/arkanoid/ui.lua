-- Arkanoid-specific frame assertions, run by tests/run_ui.lua after its
-- generic suite. It passes in the shared helpers so these read like the tests
-- there. Everything is driven through the on.* handlers and read back out of
-- the paint calls -- see tests/arkanoid/frame.lua -- so nothing here needs the
-- shipped script to expose anything for its benefit.

local F = require("arkanoid.frame")

return function(t)
  local test, ok, eq, fail, boot, stub = t.test, t.ok, t.eq, t.fail, t.boot, t.stub

  -- Boots with image.new refused, so the game has to fall back to rectangles.
  -- Both the load and the first resize have to see it broken, because a resize
  -- rebuilds the sprites.
  local function bootNoImages(w, h)
    local saved = stub.image.new
    stub.image.new = function() error("image.new unavailable on this OS") end
    local okBoot, hs = pcall(boot, w, h)
    stub.image.new = saved
    assert(okBoot, "booting without images raised: " .. tostring(hs))
    return hs
  end

  local function frame(hs)
    local _, ops = hs:paint()
    return F.read(ops)
  end

  local function play(hs, frames, each)
    local last
    for i = 1, frames do
      last = F.playFrame(hs, i)
      if each and each(last, i) then return last, i end
    end
    return last, frames
  end

  -- ------------------------------------------------------------ palette --

  test("arkanoid: every colour the game fills survives the panel distinctly", function()
    -- The handheld holds five bits a channel, so {230,74,68} and {228,72,64}
    -- are one colour there. Anything tests/arkanoid/frame.lua tells apart by
    -- ink has to still be distinct after that, or a brick reads as a ball.
    local seen = {}
    local clashes = 0
    for name, k in pairs(F.palette()) do
      if seen[k] then
        fail(string.format("%s and %s are the same colour on a calculator (%s)", name, seen[k], k))
        clashes = clashes + 1
      end
      seen[k] = name
    end
    eq(clashes, 0, "no two reserved colours collide at five bits a channel")
  end)

  -- ------------------------------------------------ the two brick encodings --

  test("arkanoid: sprites and rectangles paint the same wall", function()
    local blit = frame(boot())
    local rect = frame(bootNoImages())

    ok(blit.blitted, "the normal path blits the bricks")
    ok(not rect.blitted, "and without image.new it falls back to rectangles")
    ok(#blit.bricks > 30, "there is a wall to compare (" .. #blit.bricks .. " bricks)")
    eq(#rect.bricks, #blit.bricks, "both encodings paint the same number of bricks")

    local function fingerprint(f)
      local out = {}
      for _, b in ipairs(f.bricks) do
        out[#out + 1] = string.format("%d,%d,%d,%d,%s", b.x, b.y, b.w, b.h, tostring(b.name))
      end
      table.sort(out)
      return out
    end

    local a, b = fingerprint(blit), fingerprint(rect)
    local diff = 0
    for i = 1, math.max(#a, #b) do
      if a[i] ~= b[i] then
        diff = diff + 1
        if diff == 1 then fail("first difference: " .. tostring(a[i]) .. " vs " .. tostring(b[i])) end
      end
    end
    eq(diff, 0, "every brick is in the same place, the same size and the same ink")

    for _, br in ipairs(blit.bricks) do
      ok(br.ink ~= nil, "each blitted brick was recognised as a known ink")
    end
  end)

  test("arkanoid: the fallback is all of the bricks or none of them", function()
    -- Half a wall in each encoding would read as a bug rather than as a
    -- fallback, so no frame may ever mix them -- not just the first one.
    local hs = bootNoImages()
    hs.on.enterKey()
    local checked = 0
    for i = 1, 400 do
      local _, ops = hs:paint()
      local images = 0
      for _, o in ipairs(ops) do
        if o.op == "drawImage" then images = images + 1 end
      end
      if images > 0 then
        return fail("frame " .. i .. " blitted " .. images .. " bricks on the fallback path")
      end
      local f = F.read(ops)
      if #f.bricks == 0 then
        return fail("frame " .. i .. " painted no bricks at all")
      end
      checked = checked + 1
      hs.on.mouseDown(F.aimPoint(f), 150)
      hs.on.timer()
    end
    ok(true, checked .. " frames drew the whole wall as rectangles, none of them mixed")
  end)

  -- ------------------------------------------------------------- geometry --

  local function assertInside(f, label)
    if not f.field then return fail(label .. ": no playfield was drawn") end
    local L, R = f.field.x, f.field.x + f.field.w
    local T, B = f.field.y, f.field.y + f.field.h

    for _, b in ipairs(f.bricks) do
      if b.x < L or b.x + b.w > R or b.y < T or b.y + b.h > B then
        return fail(string.format("%s: brick at %d,%d (%dx%d) is outside the field",
                                  label, b.x, b.y, b.w, b.h))
      end
    end
    for _, b in ipairs(f.balls) do
      if b.x < L or b.x + b.w > R or b.y < T or b.y + b.h > B + 1 then
        return fail(string.format("%s: ball at %d,%d escaped the field", label, b.x, b.y))
      end
    end
    if f.paddle then
      local p = f.paddle
      if p.x < L or p.x + p.w > R or p.y < T or p.y + p.h > B then
        return fail(string.format("%s: paddle at %d,%d (%d wide) escaped the field",
                                  label, p.x, p.y, p.w))
      end
    end
    for _, c in ipairs(f.capsules) do
      if c.x < L - 2 or c.x > R then
        return fail(label .. ": a capsule is outside the field at " .. c.x)
      end
    end
    return true
  end

  test("arkanoid: nothing is ever drawn outside the playfield", function()
    for _, s in ipairs({ { 318, 212 }, { 640, 480 }, { 240, 160 }, { 160, 120 }, { 200, 480 } }) do
      local label = string.format("%dx%d", s[1], s[2])
      local hs = boot(s[1], s[2])
      if assertInside(frame(hs), label .. " title") then
        hs.on.enterKey()
        local bad = false
        play(hs, 700, function(f, i)
          if i % 40 == 0 and not assertInside(f, label .. " playing@" .. i) then
            bad = true
            return true
          end
        end)
        if not bad then ok(true, label .. ": everything stayed inside the walls") end
      end
    end
  end)

  test("arkanoid: the bricks sit on a regular grid, wall to wall", function()
    local f = frame(boot())
    local xs, ys = {}, {}
    for _, b in ipairs(f.bricks) do xs[b.x] = true; ys[b.y] = true end
    local cols, rows = 0, 0
    for _ in pairs(xs) do cols = cols + 1 end
    for _ in pairs(ys) do rows = rows + 1 end
    eq(cols, 13, "thirteen brick columns, as the rules declare")
    ok(rows >= 4 and rows <= 10, "and a sensible number of rows (" .. rows .. ")")

    local w, h = f.bricks[1].w, f.bricks[1].h
    for _, b in ipairs(f.bricks) do
      eq(b.w, w, "every brick is the same width")
      eq(b.h, h, "and the same height")
    end
  end)

  -- ---------------------------------------------------------------- play --

  test("arkanoid: the ball is served, moves, and bounces off the top", function()
    local hs = boot()
    local title = frame(hs)
    ok(F.hasText(title, "ARKANOID"), "the title screen names the game")

    hs.on.enterKey()                       -- leave the title
    local waiting = frame(hs)
    eq(#waiting.balls, 1, "a ball is waiting on the paddle")
    ok(F.hasText(waiting, "serve"), "and the game says so")
    local parked = waiting.balls[1].y

    for _ = 1, 30 do hs.on.timer() end
    eq(frame(hs).balls[1].y, parked, "it does not move until it is served")

    hs.on.enterKey()                       -- serve
    for _ = 1, 6 do hs.on.timer() end
    local away = frame(hs)
    ok(away.balls[1].y < parked, "serving sends it up the screen")

    -- Let it climb: it must come back down rather than leaving through the top.
    local highest = away.balls[1].y
    local returned = false
    for _ = 1, 200 do
      hs.on.timer()
      local f = frame(hs)
      local b = f.balls[1]
      if not b then break end
      if b.y < highest then highest = b.y end
      if b.y > highest + 8 then returned = true break end
    end
    ok(returned, "and it bounced back down off the ceiling")
    ok(highest >= 20, "without ever leaving through the top (highest " .. highest .. ")")
  end)

  test("arkanoid: arrows steer the paddle and a click aims it", function()
    local hs = boot()
    hs.on.enterKey()
    local start = frame(hs).paddle.x

    for _ = 1, 10 do hs.on.arrowKey("left"); hs.on.timer() end
    local left = frame(hs).paddle.x
    ok(left < start, "left moved it left (" .. start .. " -> " .. left .. ")")

    for _ = 1, 20 do hs.on.arrowKey("right"); hs.on.timer() end
    local right = frame(hs).paddle.x
    ok(right > left, "right moved it back (" .. left .. " -> " .. right .. ")")

    -- One tap, then nothing: it must coast to a stop rather than run on.
    hs.on.arrowKey("left")
    for _ = 1, 60 do hs.on.timer() end
    local settled = frame(hs).paddle.x
    for _ = 1, 60 do hs.on.timer() end
    eq(frame(hs).paddle.x, settled, "a single tap coasts to a stop")

    -- And a click drives it to that column. From a fresh boot each time, and
    -- inside the time it takes an unattended ball to come back down -- a lost
    -- life recentres the paddle, which would answer the question for us.
    local function clickAt(x, ticks)
      local h = boot()
      h.on.enterKey()
      h.on.mouseDown(x, 150)
      for _ = 1, ticks or 40 do h.on.timer() end
      return frame(h)
    end

    local aimed = clickAt(40).paddle
    ok(math.abs((aimed.x + aimed.w / 2) - 40) <= 8,
       "clicking at x=40 brought the paddle there (centre " .. (aimed.x + aimed.w / 2) .. ")")

    -- ... and never through a wall, however far off the edge you click.
    local walled = clickAt(0)
    ok(walled.paddle.x >= walled.field.x, "a click on the wall parks it against the wall")
    local far = clickAt(5000)
    ok(far.paddle.x + far.paddle.w <= far.field.x + far.field.w,
       "and one past the far wall parks it against that one")
  end)

  test("arkanoid: bricks come down and the score goes up", function()
    local hs = boot()
    hs.on.enterKey()
    local before = frame(hs)
    local startBricks = #before.bricks
    ok(startBricks > 30, "a full wall to start (" .. startBricks .. ")")
    eq(F.hud(before).score, 0, "and nothing on the board")

    local f = play(hs, 2500, function(fr)
      return #fr.bricks < startBricks - 4
    end)
    ok(#f.bricks < startBricks, "the autopilot knocked bricks out ("
       .. startBricks .. " -> " .. #f.bricks .. ")")
    local hud = F.hud(f)
    ok(hud and hud.score > 0, "and the score followed (" .. tostring(hud and hud.score) .. ")")
    eq(hud.level, 1, "still on level 1")
  end)

  test("arkanoid: gold bricks never come down", function()
    -- Level 5 is the first with gold in it. Rather than jumping there, this
    -- checks the invariant wherever gold appears: a gold brick seen in one
    -- frame is still there in the next, forever.
    local hs = boot()
    hs.on.enterKey()
    local golds, checked = nil, 0
    play(hs, 4000, function(f)
      local now = {}
      for _, b in ipairs(f.bricks) do
        if b.name == "gold" then now[b.x .. "," .. b.y] = true end
      end
      if golds then
        for cell in pairs(golds) do
          if not now[cell] then
            fail("a gold brick at " .. cell .. " disappeared")
            return true
          end
        end
      end
      local n = 0
      for _ in pairs(now) do n = n + 1 end
      if n > 0 then checked = checked + 1 end
      golds = now
      return false
    end)
    ok(true, "gold survived every frame it was on screen (" .. checked .. " frames with gold)")
  end)

  test("arkanoid: capsules fall and change the ship", function()
    local hs = boot()
    hs.on.enterKey()
    local seen, widths, caught = {}, {}, false
    local baseW
    play(hs, 9000, function(f)
      if f.paddle then
        baseW = baseW or f.paddle.w
        widths[f.paddle.w] = true
      end
      for _, c in ipairs(f.capsules) do seen[c.kind] = true end
      local kinds = 0
      for _ in pairs(seen) do kinds = kinds + 1 end
      return kinds >= 2 and widths[baseW] and (function()
        for w in pairs(widths) do if w ~= baseW then return true end end
      end)()
    end)
    local kinds = {}
    for k in pairs(seen) do kinds[#kinds + 1] = k end
    ok(#kinds > 0, "capsules dropped during play (" .. table.concat(kinds, ", ") .. ")")
    for w in pairs(widths) do if w ~= baseW then caught = true end end
    ok(caught, "and one of them was caught: the paddle changed width")
  end)

  test("arkanoid: a level can actually be finished", function()
    -- The one thing no logic test can show: that a wall the renderer draws is
    -- a wall a player driving the real handlers can take down.
    local hs = boot()
    hs.on.enterKey()
    local f, at = play(hs, 30000, function(fr)
      return F.hasText(fr, "CLEAR")
    end)
    ok(F.hasText(f, "CLEAR"), "the autopilot cleared level 1 in " .. at .. " frames")

    -- The banner clears itself and deals the next wall.
    for _ = 1, 80 do hs.on.timer() end
    local nxt = frame(hs)
    ok(not F.hasText(nxt, "CLEAR"), "the banner moved on by itself")
    local hud = F.hud(nxt)
    eq(hud.level, 2, "onto level 2")
    ok(#nxt.bricks > 20, "with a new wall (" .. #nxt.bricks .. " bricks)")
    ok(hud.score > 500, "and the level bonus was paid (" .. hud.score .. ")")
  end)

  test("arkanoid: losing every life ends the game, and it restarts", function()
    local hs = boot()
    hs.on.enterKey()
    hs.on.enterKey()                      -- serve, then never touch the paddle
    local over = false
    for i = 1, 4000 do
      hs.on.timer()
      if i % 20 == 0 then
        -- Look before pressing: on the game-over screen enter starts a new
        -- round, which would wipe the very thing being asked about.
        if F.hasText(frame(hs), "GAME OVER") then over = true break end
        hs.on.enterKey()                  -- re-serve after each life
      end
    end
    ok(over, "never moving the paddle ends the game")

    hs.on.enterKey()
    for _ = 1, 5 do hs.on.timer() end
    local f = frame(hs)
    ok(not F.hasText(f, "GAME OVER"), "and enter starts a fresh round")
    eq(F.hud(f).score, 0, "from zero")
    eq(F.hud(f).level, 1, "on level 1")
    ok(#f.bricks > 30, "with a full wall again")
    ok(F.hud(f).best > 0, "the last score is kept as the best")
  end)

  test("arkanoid: pausing freezes the board", function()
    local hs = boot()
    hs.on.enterKey(); hs.on.enterKey()
    for _ = 1, 30 do hs.on.timer() end
    hs.on.escapeKey()
    local a = frame(hs)
    ok(F.hasText(a, "PAUSED"), "the pause panel is up")
    local y = a.balls[1] and a.balls[1].y
    for _ = 1, 60 do hs.on.timer() end
    local b = frame(hs)
    eq(b.balls[1] and b.balls[1].y, y, "and the ball did not move")
    hs.on.enterKey()
    for _ = 1, 10 do hs.on.timer() end
    ok(not F.hasText(frame(hs), "PAUSED"), "resuming clears it")
  end)

  -- ---------------------------------------------------------- the panels --

  test("arkanoid: the overlay panels hold together in a bigger font", function()
    -- The mock measures with DejaVu; the calculator's font is taller. Fruits
    -- shipped a panel whose rows were constants tuned against the preview, and
    -- on hardware its rule ran through its own heading. So lay the panels out
    -- against a font up to half again as big and check nothing collides.
    for _, scale in ipairs({ 1, 1.25, 1.5 }) do
      stub.metricsScale = scale
      local label = "at " .. scale .. "x"
      local hs = boot()
      local f = frame(hs)

      if #f.panels == 0 then
        fail(label .. ": the title screen drew no panel")
      else
        local panel = f.panels[1]
        local rows = {}
        for _, s in ipairs(f.text) do
          if s.y >= panel.y then rows[#rows + 1] = s end
        end
        table.sort(rows, function(a, b) return a.y < b.y end)
        ok(#rows >= 4, label .. ": the panel's lines are all there (" .. #rows .. ")")

        for i = 1, #rows do
          local bottom = rows[i].y + stub.stringHeight(rows[i].size)
          if i < #rows then
            ok(bottom <= rows[i + 1].y,
               string.format("%s: row %d ends at %d, before row %d starts at %d",
                             label, i, bottom, i + 1, rows[i + 1].y))
          end
          ok(rows[i].x >= panel.x,
             string.format("%s: row %d starts inside the panel", label, i))
        end
        local last = rows[#rows]
        ok(last.y + stub.stringHeight(last.size) <= panel.y + panel.h + 1,
           label .. ": the last line stays inside the box")
        ok(panel.y >= 0 and panel.y + panel.h <= 212,
           label .. ": and the box stays on the screen")
      end
    end
    stub.metricsScale = 1
  end)

  -- ---------------------------------------------------------- draw budget --

  test("arkanoid: a full wall stays inside the frame budget", function()
    -- The handheld repaints everything twenty times a second. This is where a
    -- leaked ball, a leaked capsule or a wall drawn twice would show up.
    local function peak(hs, frames)
      local worst, worstColors = 0, 0
      hs.on.enterKey()
      for i = 1, frames do
        local calls = hs:paint()
        local total = calls.fillRect + calls.drawRect + calls.drawString
                    + calls.drawLine + calls.drawImage
        if total > worst then worst, worstColors = total, calls.setColorRGB end
        hs.on.mouseDown(159, 150)
        if i % 5 == 0 then hs.on.enterKey() end
        hs.on.timer()
      end
      return worst, worstColors
    end

    local blitPeak, blitColors = peak(boot(), 3000)
    ok(blitPeak < 190, "blitting the wall peaked at " .. blitPeak .. " draw calls, "
       .. blitColors .. " colour changes")

    local rectPeak = peak(bootNoImages(), 800)
    ok(rectPeak < 330, "and the rect fallback at " .. rectPeak .. ", still bounded")
    ok(blitPeak < rectPeak, "the sprites are the cheaper path ("
       .. blitPeak .. " against " .. rectPeak .. ")")
  end)
end
