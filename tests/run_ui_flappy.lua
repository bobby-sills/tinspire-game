-- Drives build/flappy.lua -- the exact script that goes into Flappy.tns --
-- against a mock TI-Nspire runtime. Catches API misuse and handler crashes
-- that logic tests can't see. Run with:  make test
--
-- Usage: lua tests/run_ui_flappy.lua [path-to-bundle]

package.path = "tests/?.lua;" .. package.path
local stub = require("nspire_stub")

local BUNDLE = ... or "build/flappy.lua"

local passed, failed = 0, 0
local current = "?"

local function fail(msg)
  failed = failed + 1
  print(string.format("  FAIL  [%s] %s", current, msg))
end

local function ok(cond, msg)
  if cond then passed = passed + 1 else fail(msg) end
end

local function eq(got, want, msg)
  if got == want then passed = passed + 1
  else fail(string.format("%s: got %s, want %s", msg, tostring(got), tostring(want))) end
end

local function test(name, fn)
  current = name
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
end

-- The handheld's usable script area; the sizes below bracket it.
local HANDHELD_W, HANDHELD_H = 318, 212

local function boot(w, h)
  local hs = stub.load(BUNDLE, w or HANDHELD_W, h or HANDHELD_H)
  hs:resize(w or HANDHELD_W, h or HANDHELD_H)
  return hs
end

-- The colours src/flappy_main.lua reserves for exactly one thing each, which
-- is what lets these tests read the world back out of the draw calls instead
-- of reaching into the script's internals.
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

test("script loads and declares an API level", function()
  local hs = boot()
  ok(hs.platform.apilevel ~= nil, "platform.apilevel is set")
  eq(type(hs.platform.apilevel), "string", "apilevel is a string")
  ok(hs.timerRunning, "started its timer")
  ok(hs.timerPeriod and hs.timerPeriod > 0 and hs.timerPeriod <= 0.2,
    "timer period is sane: " .. tostring(hs.timerPeriod))
  ok(hs.timerPeriod >= 0.05,
    "timer period is one the handheld can actually keep: " .. tostring(hs.timerPeriod))
end)

test("defines the handlers the OS will call", function()
  local hs = boot()
  for _, name in ipairs({ "paint", "resize", "timer", "arrowKey", "charIn",
                          "enterKey", "escapeKey", "mouseDown" }) do
    ok(type(hs.on[name]) == "function", "on." .. name .. " is defined")
  end
end)

test("paints the title screen without touching the API badly", function()
  local hs = boot()
  local calls, ops = hs:paint()
  ok(calls.fillRect > 6, "drew sky, ground, bird and pipes (" .. calls.fillRect .. " rects)")
  ok(calls.drawString >= 4, "drew HUD and panel text (" .. calls.drawString .. " strings)")
  local g = frameGeometry(ops)
  ok(g.field ~= nil, "painted a playfield")
  ok(g.bird ~= nil, "painted the bird")
end)

test("the world scrolls and the bird falls without input", function()
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

test("flapping lifts the bird", function()
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

test("survives a full play session with input", function()
  local hs = boot()
  for i = 1, 1200 do
    hs.on.timer()
    if i % 6 == 0 then hs.on.enterKey() end
    if i % 31 == 0 then hs.on.charIn(({ "w", " ", "8", "f" })[(i % 4) + 1]) end
    if i % 17 == 0 then hs.on.arrowKey("up") end
    hs:paint()
  end
  ok(hs.invalidated > 0, "requested repaints (" .. hs.invalidated .. ")")
end)

test("handles pause, resume and restart", function()
  local hs = boot()
  hs.on.enterKey()
  for _ = 1, 20 do hs.on.timer() end
  hs.on.escapeKey(); hs:paint()      -- pause
  hs.on.charIn("p"); hs:paint()      -- resume
  hs.on.arrowKey("down"); hs:paint() -- down is the pause reflex
  hs.on.charIn("p"); hs:paint()      -- resume
  hs.on.charIn("r"); hs:paint()      -- restart
  hs.on.deactivate(); hs:paint()     -- focus loss pauses
  hs.on.enterKey(); hs:paint()
  ok(true, "no handler raised")
end)

test("pausing actually stops the world", function()
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

test("dying is reachable, survivable and restartable", function()
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

test("ignores junk input", function()
  local hs = boot()
  for _, ch in ipairs({ "z", "Q", "!", "0", "", " ", "\n", "\t" }) do
    hs.on.charIn(ch)
  end
  hs.on.arrowKey("sideways") -- not a direction this game has
  hs.on.arrowKey("left")
  hs.on.arrowKey("right")
  hs:paint()
  ok(true, "unknown keys were harmless")
end)

test("clicking anywhere is safe", function()
  local hs = boot()
  for _, p in ipairs({ { 5, 5 }, { 300, 200 }, { 160, 30 }, { 0, 0 }, { 318, 212 },
                       { -5, -5 }, { 1000, 1000 } }) do
    hs.on.mouseDown(p[1], p[2])
    hs.on.timer()
    hs:paint()
  end
  ok(true, "clicks anywhere on screen were safe")
end)

test("renders at every window size the software can produce", function()
  local sizes = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
  }
  for _, s in ipairs(sizes) do
    local hs = boot(s[1], s[2])
    current = string.format("renders at %dx%d", s[1], s[2])
    hs:paint()
    hs.on.enterKey()
    for i = 1, 200 do
      hs.on.timer()
      if i % 5 == 0 then hs.on.enterKey() end
      hs:paint()
    end
    hs:paint()
    passed = passed + 1
  end
end)

-- The bird is pinned to a fixed x, so *it* must stay wholly inside the field.
-- The pipes are a different matter: they scroll in from the right and out past
-- the left, so a pipe hanging off the edge is the feature, not a bug. Only
-- their vertical extent is meaningful, and it has to stay in the sky.
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

test("nothing is drawn outside the playfield", function()
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

test("every gap on screen is wide enough for the bird", function()
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

test("resizing mid-game keeps rendering", function()
  local hs = boot(318, 212)
  hs.on.enterKey()
  for _ = 1, 60 do hs.on.timer() end
  hs:resize(640, 480); hs:paint()
  for _ = 1, 60 do hs.on.timer() end
  hs:resize(318, 212); hs:paint()
  hs:resize(318, 212); hs:paint() -- same size again: must not reset the round
  ok(true, "resize handled")
end)

test("long soak with no input still paints every frame", function()
  local hs = boot()
  hs.on.enterKey()
  for i = 1, 5000 do
    hs.on.timer()
    if i % 300 == 0 then hs.on.enterKey() end
    if i % 50 == 0 then hs:paint() end
  end
  ok(true, "5000 ticks survived")
end)

test("a long flown round stays within the draw budget", function()
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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
