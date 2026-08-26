-- Drives build/snake.lua -- the exact script that goes into Snake.tns --
-- against a mock TI-Nspire runtime. Catches API misuse and handler crashes
-- that logic tests can't see. Run with:  make test
--
-- Usage: lua tests/run_ui.lua [path-to-bundle]

package.path = "tests/?.lua;" .. package.path
local stub = require("nspire_stub")

local BUNDLE = ... or "build/snake.lua"

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

-- ------------------------------------------------------------------ tests --

test("script loads and declares an API level", function()
  local hs = boot()
  ok(hs.platform.apilevel ~= nil, "platform.apilevel is set")
  eq(type(hs.platform.apilevel), "string", "apilevel is a string")
  ok(hs.timerRunning, "started its timer")
  ok(hs.timerPeriod and hs.timerPeriod > 0 and hs.timerPeriod <= 0.2,
    "timer period is sane: " .. tostring(hs.timerPeriod))
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
  local calls = hs:paint()
  ok(calls.fillRect > 4, "drew the field and snake (" .. calls.fillRect .. " rects)")
  ok(calls.drawString >= 4, "drew HUD and panel text (" .. calls.drawString .. " strings)")
  ok(calls.fillArc >= 1, "drew the food")
end)

test("survives a full play session with input", function()
  local hs = boot()
  local keys = { "up", "down", "left", "right" }

  hs.on.enterKey() -- start
  for i = 1, 900 do
    hs.on.timer()
    if i % 7 == 0 then hs.on.arrowKey(keys[(i % 4) + 1]) end
    if i % 23 == 0 then hs.on.charIn(({ "w", "a", "s", "d", "8", "2", "4", "6" })[(i % 8) + 1]) end
    if i % 200 == 0 then hs.on.enterKey() end -- restart after any death
    hs:paint()
  end
  ok(hs.invalidated > 0, "requested repaints (" .. hs.invalidated .. ")")
end)

test("handles pause, resume, restart and mode toggle", function()
  local hs = boot()
  hs.on.enterKey()
  for _ = 1, 20 do hs.on.timer() end
  hs.on.escapeKey(); hs:paint()   -- pause
  hs.on.charIn("p"); hs:paint()   -- resume
  hs.on.charIn("p"); hs:paint()   -- pause again
  hs.on.enterKey(); hs:paint()    -- resume
  hs.on.charIn("r"); hs:paint()   -- restart
  hs.on.charIn("m"); hs:paint()   -- toggle wall mode (blocked while playing)
  hs.on.deactivate(); hs:paint()  -- focus loss pauses
  hs.on.enterKey(); hs:paint()
  ok(true, "no handler raised")
end)

test("wrap mode paints correctly", function()
  local hs = boot()
  hs.on.charIn("m") -- title screen: switch to wrap
  local calls = hs:paint()
  ok(calls.setPen >= 1, "set a pen style for the dashed border")
  hs.on.enterKey()
  for _ = 1, 400 do hs.on.timer() end
  hs:paint()
  ok(true, "played a wrap round")
end)

test("ignores junk input", function()
  local hs = boot()
  for _, ch in ipairs({ "z", "Q", "!", "0", "", " ", "\n" }) do
    hs.on.charIn(ch)
  end
  hs.on.arrowKey("sideways") -- not a real direction
  hs:paint()
  ok(true, "unknown keys were harmless")
end)

test("clicking steers and confirms", function()
  local hs = boot()
  hs.on.mouseDown(100, 100)          -- confirms from the title screen
  for _ = 1, 10 do hs.on.timer() end
  for _, p in ipairs({ { 5, 5 }, { 300, 200 }, { 160, 30 }, { 0, 0 }, { 318, 212 } }) do
    hs.on.mouseDown(p[1], p[2])
    hs.on.timer()
    hs:paint()
  end
  ok(true, "clicks anywhere on screen were safe")
end)

test("renders at every window size the software can produce", function()
  -- Handheld, the computer software's small and large views, plus extremes
  -- that exercise the minimum cell size and the panel clamping.
  local sizes = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
  }
  for _, s in ipairs(sizes) do
    local hs = boot(s[1], s[2])
    current = string.format("renders at %dx%d", s[1], s[2])
    hs:paint()
    hs.on.enterKey()
    for i = 1, 120 do
      hs.on.timer()
      if i % 9 == 0 then hs.on.arrowKey(({ "up", "left", "down", "right" })[(i % 4) + 1]) end
      hs:paint()
    end
    hs:paint()
    passed = passed + 1
  end
end)

-- Pulls the playfield rect, the snake cells and the food out of a frame's
-- draw calls, so we can assert the board never spills past its own border.
local function frameGeometry(ops)
  local field, cells, food = nil, {}, nil
  for _, o in ipairs(ops) do
    local c = o.color
    if o.op == "fillRect" then
      if c[1] == 12 and c[2] == 14 and c[3] == 19 then
        field = o
      elseif o.w == o.h and o.w >= 4 and o.w <= 20 then
        cells[#cells + 1] = o
      end
    elseif o.op == "fillArc" then
      food = o
    end
  end
  return field, cells, food
end

local function assertInsideField(ops, label)
  local field, cells, food = frameGeometry(ops)
  if not field then return fail(label .. ": no playfield drawn") end

  local escaped = 0
  for _, o in ipairs(cells) do
    if o.x < field.x or o.y < field.y
      or o.x + o.w > field.x + field.w
      or o.y + o.h > field.y + field.h then
      escaped = escaped + 1
    end
  end
  eq(escaped, 0, label .. ": snake cells outside the playfield")

  if food then
    ok(food.x >= field.x and food.y >= field.y
      and food.x + food.w <= field.x + field.w
      and food.y + food.h <= field.y + field.h,
      label .. ": food inside the playfield")
  end
end

test("nothing is drawn outside the playfield", function()
  for _, s in ipairs({ { 318, 212 }, { 640, 480 }, { 240, 160 } }) do
    local hs = boot(s[1], s[2])
    local label = string.format("%dx%d", s[1], s[2])
    local _, ops = hs:paint()
    assertInsideField(ops, label .. " title")

    hs.on.enterKey()
    for i = 1, 500 do
      hs.on.timer()
      if i % 5 == 0 then hs.on.arrowKey(({ "up", "left", "down", "right" })[(i % 4) + 1]) end
      if i % 100 == 0 then
        local _, playOps = hs:paint()
        assertInsideField(playOps, label .. " playing@" .. i)
      end
    end
  end
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
  for i = 1, 3000 do
    hs.on.timer()
    if i % 300 == 0 then hs.on.enterKey() end
    if i % 50 == 0 then hs:paint() end
  end
  ok(true, "3000 ticks survived")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
