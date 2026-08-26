-- Drives build/snake.lua through the mock Nspire runtime and dumps frames as
-- draw-op logs for tools/render.py to rasterize. Lets you see what the game
-- actually looks like without a calculator or an emulator.
--
--   lua tools/screenshot.lua [outdir] [bundle]
--
-- The simulated player reads the board back out of the paint calls rather than
-- poking at the game's internals, so nothing test-only leaks into the shipped
-- script.

package.path = "tests/?.lua;" .. package.path
local stub = require("nspire_stub")

local OUTDIR = (...) or "build/frames"
local BUNDLE = select(2, ...) or "build/snake.lua"

local FIELD_BG  = { 12, 14, 19 }
local HEAD_RGB  = { 158, 248, 158 }

local function sameColor(c, want)
  return c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
end

-- Recovers the board from a frame's drawing operations.
local function readBoard(ops)
  local st = { body = {} }

  for _, o in ipairs(ops) do
    if o.op == "fillRect" and sameColor(o.color, FIELD_BG) then
      st.ox, st.oy, st.pw, st.ph = o.x, o.y, o.w, o.h
    elseif o.op == "fillRect" and sameColor(o.color, HEAD_RGB) then
      st.headPx = { x = o.x, y = o.y, w = o.w }
    elseif o.op == "fillArc" then
      st.foodPx = { x = o.x, y = o.y }
    end
  end
  if not (st.ox and st.headPx) then return nil end

  st.cell = st.headPx.w + 1
  st.cols = math.floor(st.pw / st.cell)
  st.rows = math.floor(st.ph / st.cell)

  local function toGrid(px, py)
    return math.floor((px - st.ox) / st.cell) + 1, math.floor((py - st.oy) / st.cell) + 1
  end

  st.head = {}
  st.head.x, st.head.y = toGrid(st.headPx.x, st.headPx.y)
  if st.foodPx then
    st.food = {}
    st.food.x, st.food.y = toGrid(st.foodPx.x - 1, st.foodPx.y - 1)
  end

  -- Every body segment is a cell-sized rect inside the field; the 2x2 eyes and
  -- the HUD bar are the wrong size to match.
  for _, o in ipairs(ops) do
    if o.op == "fillRect" and o.w == st.cell - 1 and o.h == st.cell - 1
      and o.x >= st.ox and o.y >= st.oy then
      local gx, gy = toGrid(o.x, o.y)
      st.body[(gy - 1) * st.cols + gx] = true
    end
  end
  return st
end

local DIRS = {
  up    = { x = 0, y = -1 }, down  = { x = 0, y = 1 },
  left  = { x = -1, y = 0 }, right = { x = 1, y = 0 },
}
local DIR_NAMES = { "up", "down", "left", "right" }

-- Chase the food, but only through cells that aren't wall or body.
local function chooseMove(st, lastDir)
  local best, bestDist
  for _, name in ipairs(DIR_NAMES) do
    local d = DIRS[name]
    local reverse = lastDir and d.x == -lastDir.x and d.y == -lastDir.y
    local nx, ny = st.head.x + d.x, st.head.y + d.y
    local inBounds = nx >= 1 and nx <= st.cols and ny >= 1 and ny <= st.rows
    if not reverse and inBounds and not st.body[(ny - 1) * st.cols + nx] then
      local dist = 0
      if st.food then
        dist = math.abs(st.food.x - nx) + math.abs(st.food.y - ny)
      end
      if not bestDist or dist < bestDist then best, bestDist = name, dist end
    end
  end
  return best
end

local function dump(ops, path)
  local f = assert(io.open(path, "w"))
  for _, o in ipairs(ops) do
    local c = o.color
    if o.op == "drawString" then
      f:write(string.format("drawString\t%d\t%d\t%d\t%d\t%d\t%s\t%s\t%s\n",
        o.x, o.y, c[1], c[2], c[3], o.size, o.style, o.text))
    elseif o.op == "drawLine" then
      f:write(string.format("drawLine\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        o.x, o.y, o.x2, o.y2, c[1], c[2], c[3]))
    elseif o.op == "fillArc" then
      f:write(string.format("fillArc\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        o.x, o.y, o.w, o.h, c[1], c[2], c[3]))
    else -- fillRect / drawRect
      f:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
        o.op, o.x, o.y, o.w, o.h, c[1], c[2], c[3], o.pen or "smooth"))
    end
  end
  f:close()
  print("wrote " .. path)
end

-- ------------------------------------------------------------------- drive --

os.execute("mkdir -p " .. OUTDIR)

local hs = stub.load(BUNDLE, 318, 212)
hs:resize(318, 212)

-- 1. Title screen.
local _, ops = hs:paint()
dump(ops, OUTDIR .. "/1-title.txt")

-- 2. Mid-game, after the simulated player has grown the snake.
hs.on.enterKey()
local lastDir, frames = nil, 0
for i = 1, 4000 do
  hs.on.timer()
  local _, frameOps = hs:paint()
  local st = readBoard(frameOps)
  if st then
    local move = chooseMove(st, lastDir)
    if move then
      hs.on.arrowKey(move)
      lastDir = DIRS[move]
    end
    frames = frames + 1
    -- Grab the frame once the snake is long enough to look like a real game.
    local len = 0
    for _ in pairs(st.body) do len = len + 1 end
    if len >= 22 then
      dump(frameOps, OUTDIR .. "/2-playing.txt")
      break
    end
  end
end

-- 3. Game over: drive the snake straight into a wall.
for _ = 1, 200 do
  hs.on.arrowKey("right")
  hs.on.timer()
end
local _, overOps = hs:paint()
dump(overOps, OUTDIR .. "/3-gameover.txt")

-- 4. Paused, to check that overlay too.
hs.on.enterKey()
for _ = 1, 30 do hs.on.timer() end
hs.on.escapeKey()
local _, pausedOps = hs:paint()
dump(pausedOps, OUTDIR .. "/4-paused.txt")

print("simulated " .. frames .. " frames")
