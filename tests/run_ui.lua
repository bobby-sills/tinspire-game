-- Drives a built bundle -- the exact script that goes into the .tns --
-- against a mock TI-Nspire runtime. Catches API misuse and handler crashes
-- that logic tests can't see. Run with:  make test
--
-- Every test here is game-agnostic: it only assumes the script defines the
-- usual on.* handlers and paints something. A game adds its own frame
-- assertions in tests/<game>/ui.lua, which this file runs at the end.
--
-- Usage: lua tests/run_ui.lua [path-to-bundle] [game-name]

package.path = "tests/?.lua;" .. package.path
local stub = require("nspire_stub")

local BUNDLE, GAME = ...
BUNDLE = BUNDLE or "build/snake/snake.lua"
GAME = GAME or BUNDLE:match("build/([^/]+)/")

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
  ok(calls.fillRect > 4, "drew a scene (" .. calls.fillRect .. " rects)")
  ok(calls.drawString >= 2, "drew some text (" .. calls.drawString .. " strings)")
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
  hs.on.charIn("m"); hs:paint()   -- game-specific key, or junk: both must be safe
  hs.on.deactivate(); hs:paint()  -- focus loss pauses
  hs.on.enterKey(); hs:paint()
  ok(true, "no handler raised")
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

-- Per-game frame assertions, e.g. "no cell escapes the playfield". Optional:
-- a game with no tests/<game>/ui.lua just runs the generic suite above.
if GAME then
  local found, extra = pcall(require, GAME .. ".ui")
  if found and type(extra) == "function" then
    extra({ test = test, ok = ok, eq = eq, fail = fail, boot = boot, stub = stub })
  elseif found then
    fail("tests/" .. GAME .. "/ui.lua did not return a function")
  end
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
