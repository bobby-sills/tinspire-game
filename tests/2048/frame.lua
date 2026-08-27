-- Recovers a 2048 board from a frame's draw calls, and drives a simple
-- autopilot over it. Shared by tests/2048/ui.lua and tests/2048/autoplay.lua.
--
-- Everything here reads the *painted frame*, never the game's own state, so
-- no test-only hooks have to reach the shipped script. The cost is that these
-- colours are a contract with src/2048/main.lua: change a tile colour there
-- and it has to change here too.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

local BOARD = key({ 40, 45, 58 })
local EMPTY = key({ 56, 63, 80 })
local PANEL = key({ 26, 30, 39 })
local HUD   = key({ 30, 34, 44 })

-- Tile fills, mirroring main.lua's TILE table. Only fillRect ops are matched,
-- which is why 2048's gold can appear here and still be safe: main.lua uses
-- that colour for text and panel outlines, never for a filled tile.
M.VALUES = {
  ["238,228,218"] = 2,    ["237,224,200"] = 4,    ["242,177,121"] = 8,
  ["245,149,99"]  = 16,   ["246,124,95"]  = 32,   ["235,90,58"]   = 64,
  ["237,207,114"] = 128,  ["237,200,90"]  = 256,  ["240,192,64"]  = 512,
  ["242,184,38"]  = 1024, ["246,176,14"]  = 2048, ["108,92,196"]  = 4096,
  ["84,72,168"]   = 8192, ["62,52,140"]   = 16384, ["44,38,104"]  = 32768,
}

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

-- Returns { board, hud, cells, tiles, grid, panel, settled, size }.
--   cells   the 16 empty-cell backings, which fix the grid geometry
--   tiles   { rect = op, value = n, cell = idx, label = drawString op }
--   grid    16 entries, 0 for empty, indexed (y-1)*4 + x
--   settled false while a slide or a pop is on screen, i.e. some tile is not
--           sitting exactly on its cell
function M.read(ops)
  local f = { cells = {}, tiles = {}, grid = {}, strings = {}, panel = false }
  for i = 1, 16 do f.grid[i] = 0 end

  for _, o in ipairs(ops) do
    if o.op == "fillRect" then
      local k = key(o.color)
      if k == BOARD then f.board = f.board or o
      elseif k == EMPTY then f.cells[#f.cells + 1] = o
      elseif k == PANEL then f.panel = true
      elseif k == HUD then f.hud = f.hud or o
      elseif M.VALUES[k] then
        f.tiles[#f.tiles + 1] = { rect = o, value = M.VALUES[k] }
      end
    elseif o.op == "drawString" then
      f.strings[#f.strings + 1] = o
    end
  end

  if #f.cells == 0 then return f end

  local xs, ys = {}, {}
  for _, c in ipairs(f.cells) do xs[c.x] = true; ys[c.y] = true end
  f.colX, f.rowY = sortedUnique(xs), sortedUnique(ys)
  f.size = f.cells[1].w

  f.settled = true
  local half = f.size / 2
  for _, t in ipairs(f.tiles) do
    local gx = nearestIndex(f.colX, t.rect.x + t.rect.w / 2 - half)
    local gy = nearestIndex(f.rowY, t.rect.y + t.rect.h / 2 - half)
    t.cell = (gy - 1) * #f.colX + gx
    t.x, t.y = gx, gy
    if t.rect.x ~= f.colX[gx] or t.rect.y ~= f.rowY[gy] or t.rect.w ~= f.size then
      f.settled = false -- mid-slide, or mid-pop: not on its cell
    else
      f.grid[t.cell] = t.value
    end
  end

  -- Pair each tile with the digits drawn on top of it. Only meaningful on a
  -- frame with no overlay panel, whose text would land on the board too.
  if not f.panel then
    for _, s in ipairs(f.strings) do
      for _, t in ipairs(f.tiles) do
        if contains(t.rect, s.x, s.y) then t.label = s; break end
      end
    end
  end

  return f
end

function M.signature(f)
  return table.concat(f.grid, ",")
end

function M.maxTile(f)
  local m = 0
  for _, v in ipairs(f.grid) do if v > m then m = v end end
  return m
end

-- Runs the timer far enough that any slide has finished and the frame settles.
function M.settle(hs)
  for _ = 1, 8 do hs.on.timer() end
end

function M.frame(hs)
  local _, ops = hs:paint()
  return M.read(ops), ops
end

-- Corner strategy: keep pressing toward the top-left, and only reach for the
-- other two directions when neither of those does anything. That is enough to
-- build a real-looking board with a few hundred-plus tiles on it.
M.ORDER = { "left", "up", "down", "right" }

-- Plays one move: tries the preferences in order until the board actually
-- changes. Returns the settled frame, its ops and the direction taken, or nil
-- once no direction moves anything.
function M.step(hs)
  local before = M.signature(M.frame(hs))
  for _, dir in ipairs(M.ORDER) do
    hs.on.arrowKey(dir)
    M.settle(hs)
    local f, ops = M.frame(hs)
    if M.signature(f) ~= before then return f, ops, dir end
  end
  return nil
end

return M
