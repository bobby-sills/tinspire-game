-- Recovers a Fruits board from a frame's draw calls, and plays it.
--
-- Shared by tests/fruits/ui.lua and tests/fruits/autoplay.lua. Everything here
-- reads the *painted frame*, never the game's own state, so no test-only hook
-- has to reach the shipped script. The cost is that the colours below are a
-- contract with src/fruits/main.lua: change a chrome colour there and it has to
-- change here too.
--
-- The game draws fruit two ways and this has to read both. Normally each fruit
-- is one gc:drawImage, and the image's identity is the fruit's identity --
-- nothing else needed. When a cell is too small for a native 16-pixel sprite,
-- or when a runtime will not build the images, the same pixels arrive as
-- fillRects instead, and a fruit is then identified by the SET OF COLOURS
-- filled inside its cell. Either way the tests only ever ask whether two cells
-- hold the same thing, so an opaque label is enough and neither path needs to
-- know what a Pear is.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

M.BOARD  = key({  34,  39,  52 })
M.CELL_A = key({  46,  52,  68 })
M.CELL_B = key({  39,  45,  60 })
M.PANEL  = key({  22,  26,  34 })
M.HUD    = key({  26,  30,  40 })
M.PAGE   = key({  14,  16,  22 })
M.FLASH  = key({ 255, 252, 232 })
M.CURSOR = key({ 250, 238, 120 })
M.SELECT = key({ 120, 224, 255 })
M.HINT   = key({ 120, 250, 160 })

-- Fills that are furniture rather than fruit.
local CHROME = {
  [M.BOARD] = true, [M.CELL_A] = true, [M.CELL_B] = true,
  [M.PANEL] = true, [M.HUD] = true, [M.PAGE] = true, [M.FLASH] = true,
}

local function sortedKeys(set)
  local out = {}
  for v in pairs(set) do out[#out + 1] = v end
  table.sort(out)
  return out
end

-- Returns:
--   cell, colX, rowY   the grid's geometry, read off the cell backings
--   grid               64 labels, indexed (y-1)*8 + x; false where empty
--   settled            false while anything is mid-flight or mid-burst
--   cursor, sel, hint  cells carrying each outline, or nil
--   images             true if this frame used the drawImage path
--   text               every string drawn, in order
function M.read(ops)
  local f = { cells = {}, grid = {}, text = {}, strings = {},
              fruit = {}, panel = false, images = false, flash = 0 }

  local outlines = {}

  for _, o in ipairs(ops) do
    local k = key(o.color)
    if o.op == "fillRect" then
      if k == M.CELL_A or k == M.CELL_B then
        f.cells[#f.cells + 1] = o
      elseif k == M.BOARD then
        f.board = f.board or o
      elseif k == M.PANEL then
        f.panel = true
      elseif k == M.FLASH then
        f.flash = f.flash + 1
      elseif not CHROME[k] then
        f.fruit[#f.fruit + 1] = { op = o, colour = k }
      end
    elseif o.op == "drawImage" then
      f.images = true
      f.fruit[#f.fruit + 1] = { op = o, id = o.img.id }
    elseif o.op == "drawRect" then
      outlines[#outlines + 1] = { op = o, colour = k }
    elseif o.op == "drawString" then
      f.strings[#f.strings + 1] = o
      f.text[#f.text + 1] = o.text
    end
  end

  if #f.cells == 0 then return f end

  local xs, ys = {}, {}
  for _, c in ipairs(f.cells) do xs[c.x] = true; ys[c.y] = true end
  f.colX, f.rowY = sortedKeys(xs), sortedKeys(ys)
  f.cell = f.cells[1].w
  f.cols, f.rows = #f.colX, #f.rowY

  -- Which cell a pixel is in, by the grid's own geometry rather than by
  -- assuming where the board starts.
  local function cellOf(px, py)
    local gx = math.floor((px - f.colX[1]) / f.cell) + 1
    local gy = math.floor((py - f.rowY[1]) / f.cell) + 1
    if gx < 1 or gx > f.cols or gy < 1 or gy > f.rows then return nil end
    return gx, gy
  end
  f.cellOf = cellOf

  f.settled = true
  local sig = {}       -- per cell, the set of fill colours found in it

  for _, item in ipairs(f.fruit) do
    local o = item.op
    local gx, gy = cellOf(o.x + o.w / 2, o.y + o.h / 2)
    if not gx then
      f.settled = false      -- something is off the grid entirely: mid-fall
    else
      local i = (gy - 1) * f.cols + gx
      item.x, item.y, item.cell = gx, gy, i
      -- Wholly inside its own cell, or it is in flight between two.
      if o.x < f.colX[gx] or o.y < f.rowY[gy]
         or o.x + o.w > f.colX[gx] + f.cell
         or o.y + o.h > f.rowY[gy] + f.cell then
        f.settled = false
      end
      if item.id then
        if f.grid[i] and f.grid[i] ~= item.id then f.settled = false end
        f.grid[i] = item.id
      else
        sig[i] = sig[i] or {}
        sig[i][item.colour] = true
      end
    end
  end

  -- The rect path: a cell's fruit is the set of colours drawn in it.
  if not f.images then
    for i, set in pairs(sig) do
      f.grid[i] = table.concat(sortedKeys(set), " ")
    end
  end

  local full = 0
  for i = 1, f.cols * f.rows do
    if f.grid[i] then full = full + 1 else f.grid[i] = false end
  end
  f.filled = full
  if full ~= f.cols * f.rows then f.settled = false end
  if f.flash > 0 then f.settled = false end   -- something is bursting

  for _, o in ipairs(outlines) do
    local gx, gy = cellOf(o.op.x + 1, o.op.y + 1)
    if gx then
      local at = { x = gx, y = gy }
      if o.colour == M.CURSOR then f.cursor = at
      elseif o.colour == M.SELECT then f.sel = at
      elseif o.colour == M.HINT then
        f.hint = f.hint or {}
        f.hint[#f.hint + 1] = at
      end
    end
  end

  return f
end

function M.frame(hs)
  local calls, ops = hs:paint()
  local f = M.read(ops)
  f.calls, f.ops = calls, ops
  return f, ops, calls
end

-- Runs the timer until nothing is moving.
--
-- "Moving" is read from the repaint requests, not from the picture: the game
-- calls platform.window:invalidate() on a tick exactly when it has something
-- to animate, so a tick that asks for no repaint is a tick where the machine
-- was idle. Judging it from the frame instead does not work, and the way it
-- fails is worth writing down -- at the very start of a swap the two fruit are
-- drawn at each other's cells, so all sixty-four cells hold exactly one fruit
-- and the board looks perfectly settled while a swap is in fact under way.
function M.settle(hs, limit)
  for _ = 1, limit or 800 do
    local before = hs.invalidated
    hs.on.timer()
    if hs.invalidated == before then break end
  end
  return M.frame(hs)
end

-- Ticks once and says whether the game asked to be repainted, i.e. whether
-- anything is still in flight.
function M.tick(hs)
  local before = hs.invalidated
  hs.on.timer()
  return hs.invalidated ~= before
end

function M.signature(f)
  local out = {}
  for i = 1, (f.cols or 8) * (f.rows or 8) do
    out[i] = tostring(f.grid[i])
  end
  return table.concat(out, ",")
end

-- The centre of a cell, in screen pixels -- what to click.
function M.centre(f, gx, gy)
  return f.colX[gx] + math.floor(f.cell / 2), f.rowY[gy] + math.floor(f.cell / 2)
end

-- ------------------------------------------------------- an independent eye --
--
-- Match-three, worked out again from the frame the game painted. This shares
-- no code with src/fruits/game.lua -- it does not even know what a fruit is,
-- only which labels are equal -- so when it agrees with the game about what is
-- on the board, that is two mechanisms agreeing rather than one asserting.

local function at(f, x, y)
  if x < 1 or x > f.cols or y < 1 or y > f.rows then return nil end
  return f.grid[(y - 1) * f.cols + x]
end

-- Every cell in a run of three or more, as a set of indices.
function M.runs(f)
  local hit, n = {}, 0
  for y = 1, f.rows do
    for x = 1, f.cols do
      local k = at(f, x, y)
      if k then
        for axis = 1, 2 do
          local dx, dy = (axis == 1) and 1 or 0, (axis == 1) and 0 or 1
          local len = 1
          local cx, cy = x + dx, y + dy
          while at(f, cx, cy) == k do len = len + 1; cx, cy = cx + dx, cy + dy end
          cx, cy = x - dx, y - dy
          while at(f, cx, cy) == k do len = len + 1; cx, cy = cx - dx, cy - dy end
          if len >= 3 and not hit[(y - 1) * f.cols + x] then
            hit[(y - 1) * f.cols + x] = true
            n = n + 1
          end
        end
      end
    end
  end
  return hit, n
end

-- Every swap that would make a run, brute force.
function M.legalSwaps(f)
  local out = {}
  local function trial(x1, y1, x2, y2)
    local i, j = (y1 - 1) * f.cols + x1, (y2 - 1) * f.cols + x2
    f.grid[i], f.grid[j] = f.grid[j], f.grid[i]
    local _, n = M.runs(f)
    f.grid[i], f.grid[j] = f.grid[j], f.grid[i]
    if n > 0 then out[#out + 1] = { x1, y1, x2, y2 } end
  end
  for y = 1, f.rows do
    for x = 1, f.cols do
      if x < f.cols then trial(x, y, x + 1, y) end
      if y < f.rows then trial(x, y, x, y + 1) end
    end
  end
  return out
end

-- Plays one move by clicking: a cell, then its neighbour. Returns the settled
-- frame after the cascade, the swap taken, and the ops of the busiest
-- mid-cascade frame seen on the way -- which is what the screenshots want.
function M.step(hs, pick)
  local f = M.settle(hs)
  if not f.colX then return nil end
  local swaps = M.legalSwaps(f)
  if #swaps == 0 then return nil, nil, nil, f end

  local s = swaps[pick and pick(#swaps) or 1]
  hs.on.mouseDown(M.centre(f, s[1], s[2]))
  hs.on.mouseDown(M.centre(f, s[3], s[4]))

  local busiest, busyOps = -1, nil
  for _ = 1, 800 do
    local g, ops = M.frame(hs)
    -- "Busiest" means the most cells actually empty, which finds the frame
    -- with the most fruit in the air rather than one caught between ticks.
    local empty = (g.cols or 8) * (g.rows or 8) - (g.filled or 0)
    if empty > busiest then busiest, busyOps = empty, ops end
    if not M.tick(hs) then break end
  end

  return M.settle(hs), s, busyOps
end

return M
