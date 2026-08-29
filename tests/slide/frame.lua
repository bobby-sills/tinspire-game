-- Recovers a slide-puzzle board from a frame's draw calls, and drives a simple
-- autopilot over it. Shared by tests/slide/ui.lua and tests/slide/autoplay.lua.
--
-- Everything here reads the *painted frame*, never the game's own state, so no
-- test-only hooks have to reach the shipped script. The cost is that these
-- colours are a contract with src/slide/main.lua: change a tile fill there and
-- it has to change here too.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

local BOARD = key({  40,  45,  58 })
local CELL  = key({  56,  63,  80 })
local PANEL = key({  26,  30,  39 })
local HUD   = key({  30,  34,  44 })

M.TILE      = key({ 232, 222, 200 })   -- not yet in its final position
M.TILE_HOME = key({ 150, 205, 155 })   -- ...and one that is

local function sortedUnique(set)
  local out = {}
  for v in pairs(set) do out[#out + 1] = v end
  table.sort(out)
  return out
end

local function nearestIndex(list, v)
  local best, bestD = 1, math.huge
  for i, c in ipairs(list) do
    local d = math.abs(c - v)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

local function contains(r, x, y)
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

-- Returns a frame table:
--   board    the board backing rect
--   hud      the status bar rect
--   cells    the n*n cell backings, which fix the grid geometry
--   n        board edge, recovered from how many cell backings were drawn
--   tiles    { rect, home, cell, x, y, label, value }
--   grid     n*n entries, 0 for the gap, indexed (y-1)*n + x
--   gap      index of the one cell with no tile on it
--   settled  false while a tile is drawn off its own cell, i.e. mid-slide
--   panel    true when an overlay panel is covering the board
--   strings  every drawString op, in order
function M.read(ops)
  local f = { cells = {}, tiles = {}, grid = {}, strings = {}, panel = false }

  for _, o in ipairs(ops) do
    if o.op == "fillRect" then
      local k = key(o.color)
      if k == BOARD then f.board = f.board or o
      elseif k == CELL then f.cells[#f.cells + 1] = o
      elseif k == PANEL then f.panel = true
      elseif k == HUD then f.hud = f.hud or o
      elseif k == M.TILE or k == M.TILE_HOME then
        f.tiles[#f.tiles + 1] = { rect = o, home = (k == M.TILE_HOME) }
      end
    elseif o.op == "drawString" then
      f.strings[#f.strings + 1] = o
    end
  end

  if #f.cells == 0 then return f end

  local xs, ys = {}, {}
  for _, c in ipairs(f.cells) do xs[c.x] = true; ys[c.y] = true end
  f.colX, f.rowY = sortedUnique(xs), sortedUnique(ys)
  f.n = #f.colX
  f.size = f.cells[1].w
  for i = 1, f.n * f.n do f.grid[i] = 0 end

  f.settled = true
  local occupied = {}
  local half = f.size / 2
  for _, t in ipairs(f.tiles) do
    local gx = nearestIndex(f.colX, t.rect.x + t.rect.w / 2 - half)
    local gy = nearestIndex(f.rowY, t.rect.y + t.rect.h / 2 - half)
    t.x, t.y = gx, gy
    t.cell = (gy - 1) * f.n + gx
    if t.rect.x ~= f.colX[gx] or t.rect.y ~= f.rowY[gy] then
      t.moving = true
      f.settled = false
    end
    occupied[t.cell] = true
  end

  -- The gap is the one cell with no tile drawn on it. Read from geometry
  -- rather than from the numbers, because a window small enough that the game
  -- drops the digits still has a perfectly legible grid of rectangles. Only
  -- claim it on a settled frame: mid-slide the tiles are between cells and
  -- several cells look empty.
  if f.settled then
    local empty, count = nil, 0
    for i = 1, f.n * f.n do
      if not occupied[i] then empty, count = i, count + 1 end
    end
    if count == 1 then f.gap = empty end
  end

  -- Pair each tile with the digits drawn on top of it. Only meaningful on a
  -- frame with no overlay panel, whose text would land on the board too.
  if not f.panel then
    for _, s in ipairs(f.strings) do
      for _, t in ipairs(f.tiles) do
        if contains(t.rect, s.x, s.y) then
          t.label = s
          t.value = tonumber(s.text)
          break
        end
      end
    end
    for _, t in ipairs(f.tiles) do
      if t.value and not t.moving then f.grid[t.cell] = t.value end
    end

  end

  return f
end

function M.signature(f)
  return table.concat(f.grid, ",")
end

function M.frame(hs)
  local _, ops = hs:paint()
  return M.read(ops), ops
end

-- Runs the timer far enough that any slide has finished and the frame settles.
function M.settle(hs)
  for _ = 1, 5 do hs.on.timer() end
end

function M.cellCentre(f, gx, gy)
  return f.colX[gx] + math.floor(f.size / 2), f.rowY[gy] + math.floor(f.size / 2)
end

function M.click(hs, f, gx, gy)
  local x, y = M.cellCentre(f, gx, gy)
  hs.on.mouseDown(x, y)
end

-- --------------------------------------------------------------- autopilot --
--
-- A greedy hill-climb over the board as *painted*: of the tiles beside the
-- gap, move whichever gets closest to its home cell, never straight back where
-- it came from. It does not solve the puzzle -- nothing this simple does --
-- but it makes visible progress, which is what a screenshot wants.

local function homeDistance(n, value, cell)
  local cx, cy = (cell - 1) % n, math.floor((cell - 1) / n)
  local hx, hy = (value - 1) % n, math.floor((value - 1) / n)
  return math.abs(cx - hx) + math.abs(cy - hy)
end

function M.manhattan(f)
  local total = 0
  for i = 1, f.n * f.n do
    local v = f.grid[i]
    if v ~= 0 then total = total + homeDistance(f.n, v, i) end
  end
  return total
end

function M.homeCount(f)
  local n = 0
  for _, t in ipairs(f.tiles) do
    if t.home then n = n + 1 end
  end
  return n
end

-- The cells whose tile could step into the gap, i.e. the gap's neighbours.
local function neighbours(f)
  local n = f.n
  local gx, gy = (f.gap - 1) % n + 1, math.floor((f.gap - 1) / n) + 1
  local out = {}
  for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
    local x, y = gx + d[1], gy + d[2]
    if x >= 1 and x <= n and y >= 1 and y <= n then
      out[#out + 1] = { x = x, y = y, cell = (y - 1) * n + x }
    end
  end
  return out
end

-- Plays one move by clicking. `avoid` is the cell the gap came from, so the
-- autopilot does not spend the whole run rocking one tile back and forth.
-- Returns the settled frame, its ops and the cell that was clicked.
function M.step(hs, f, avoid, rand)
  rand = rand or math.random
  if not f.gap then return nil end

  local best, bestScore
  for _, c in ipairs(neighbours(f)) do
    if c.cell ~= avoid then
      local v = f.grid[c.cell]
      -- Moving this tile into the gap: how much closer to home does it get?
      -- Zero means the frame carried no numbers (too small to draw them), so
      -- every neighbour scores the same and the noise below picks one.
      local score = (v == 0) and 0
        or (homeDistance(f.n, v, c.cell) - homeDistance(f.n, v, f.gap))
      score = score * 4 + rand(3)   -- a little noise, so it does not cycle
      if not bestScore or score > bestScore then best, bestScore = c, score end
    end
  end
  if not best then return nil end

  M.click(hs, f, best.x, best.y)
  M.settle(hs)
  local nf, ops = M.frame(hs)
  return nf, ops, f.gap
end

-- Plays `moves` moves, returning the last frame and the best one seen by some
-- measure -- used by autoplay to pick a frame worth capturing.
function M.play(hs, moves, rand)
  local f = M.frame(hs)
  local avoid, bestHome, bestOps = nil, -1, nil
  for _ = 1, moves do
    local nf, ops, came = M.step(hs, f, avoid, rand)
    if not nf then break end
    f, avoid = nf, came
    local home = M.homeCount(f)
    if home > bestHome then bestHome, bestOps = home, ops end
  end
  return f, bestOps, bestHome
end

return M
