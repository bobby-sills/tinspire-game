-- Plays Snake through the mock runtime so tools/screenshot.lua can capture
-- representative frames.
--
-- The simulated player recovers the board from the paint calls rather than
-- reaching into the game's state, which keeps test-only hooks out of the
-- shipped script. A new game writes its own version of this file.

local FIELD_BG = { 12, 14, 19 }
local HEAD_RGB = { 158, 248, 158 }

local DIRS = {
  up    = { x = 0, y = -1 }, down  = { x = 0, y = 1 },
  left  = { x = -1, y = 0 }, right = { x = 1, y = 0 },
}
local DIR_NAMES = { "up", "down", "left", "right" }

local function sameColor(c, want)
  return c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
end

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

  for _, o in ipairs(ops) do
    if o.op == "fillRect" and o.w == st.cell - 1 and o.h == st.cell - 1
      and o.x >= st.ox and o.y >= st.oy then
      local gx, gy = toGrid(o.x, o.y)
      st.body[(gy - 1) * st.cols + gx] = true
    end
  end
  return st
end

-- Chase the food, but only through cells that are neither wall nor body.
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

return function(hs, capture)
  -- 1. Title screen.
  local _, ops = hs:paint()
  capture("title", ops)

  -- 2. Mid-game, once the snake is long enough to look like a real game.
  hs.on.enterKey()
  local lastDir
  for _ = 1, 4000 do
    hs.on.timer()
    local _, frameOps = hs:paint()
    local st = readBoard(frameOps)
    if st then
      local move = chooseMove(st, lastDir)
      if move then
        hs.on.arrowKey(move)
        lastDir = DIRS[move]
      end
      local len = 0
      for _ in pairs(st.body) do len = len + 1 end
      if len >= 22 then
        capture("playing", frameOps)
        break
      end
    end
  end

  -- 3. Game over: drive straight into a wall.
  for _ = 1, 200 do
    hs.on.arrowKey("right")
    hs.on.timer()
  end
  local _, overOps = hs:paint()
  capture("gameover", overOps)

  -- 4. Paused.
  hs.on.enterKey()
  for _ = 1, 30 do hs.on.timer() end
  hs.on.escapeKey()
  local _, pausedOps = hs:paint()
  capture("paused", pausedOps)
end
