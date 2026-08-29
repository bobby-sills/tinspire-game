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
M.keyOf = key

M.BOARD  = key({  34,  39,  52 })
M.CELL_A = key({  46,  52,  68 })
M.CELL_B = key({  39,  45,  60 })
M.PANEL  = key({  22,  26,  34 })
M.HUD    = key({  26,  30,  40 })
M.PAGE   = key({  14,  16,  22 })
M.CURSOR = key({ 250, 238, 120 })
-- The power ring throbs, and it DIMS as it grows -- so it arrives in three
-- colours, not one, and all three have to be recognised here. Keying off only
-- the brightest made a power fruit invisible to this reader on two steps of
-- every six, which is the sort of contract-with-main.lua slip that makes a
-- test flaky rather than failing.
M.POWER      = key({ 252, 252, 240 })
M.POWER_MID  = key({ 206, 210, 225 })
M.POWER_DIM  = key({ 150, 158, 180 })

local POWER_RING = { [M.POWER] = true, [M.POWER_MID] = true, [M.POWER_DIM] = true }
M.POWER_RING = POWER_RING
M.SELECT = key({ 120, 224, 255 })
M.HINT   = key({ 120, 250, 160 })

-- Fills that are furniture rather than fruit.
local CHROME = {
  [M.BOARD] = true, [M.CELL_A] = true, [M.CELL_B] = true,
  [M.PANEL] = true, [M.HUD] = true, [M.PAGE] = true,
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
              fruit = {}, panel = false, images = false,
              fills = 0, blits = 0 }

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

  -- Only what is drawn over the BOARD counts as fruit. The side panel fills
  -- rectangles too -- the level bar does -- and without this the reader would
  -- take those for art and every colour in the chrome would have to be
  -- enumerated here forever. Horizontally, because a fruit falling in from
  -- above the board is still in its own column and must keep counting.
  local left, right = f.colX[1], f.colX[f.cols] + f.cell
  local onBoard = {}
  for _, item in ipairs(f.fruit) do
    local o = item.op
    if item.id or (o.x < right and o.x + o.w > left) then
      onBoard[#onBoard + 1] = item
    end
  end
  f.fruit = onBoard

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
        f.blits = f.blits + 1
        if f.grid[i] and f.grid[i] ~= item.id then f.settled = false end
        f.grid[i] = item.id
      else
        f.fills = f.fills + 1
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

  -- A fruit shrinking as it bursts is too small for a native sprite, so it
  -- arrives as rects while everything settled around it is still one blit.
  -- Loose fills on a frame that is otherwise using images therefore mean a
  -- clear is on screen. (On the rect-only fallback there is nothing to
  -- contrast against, so this cannot tell -- which costs nothing, because
  -- M.settle waits on repaint requests rather than on this flag.)
  if f.images and f.fills > 0 then f.settled = false end

  -- The cursor is ONE ring whose colour says whether a fruit is picked up, so
  -- a selection is also a cursor position.
  for _, o in ipairs(outlines) do
    local gx, gy = cellOf(o.op.x + 1, o.op.y + 1)
    if gx then
      local at = { x = gx, y = gy }
      if POWER_RING[o.colour] then
        f.powers = f.powers or {}
        f.powers[(gy - 1) * f.cols + gx] = true
        f.ringW = o.op.w
      elseif o.colour == M.CURSOR then f.cursor = at
      elseif o.colour == M.SELECT then f.sel, f.cursor = at, at
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

-- What has to stop changing before the board counts as settled: where every
-- fruit is, and whether any of them is caught between cells or mid-burst.
--
-- Deliberately NOT the repaint requests, which is what this used to watch. The
-- game repaints while a power fruit throbs, which never stops, so a settled
-- board asks for frames forever and "it stopped asking" stopped meaning
-- anything. Watching the fruit instead is also the more honest question, since
-- that is what "settled" was always supposed to mean.
local function stability(f)
  return M.signature(f) .. "|" .. tostring(f.settled) .. "|" .. tostring(f.filled)
end

-- Runs the timer until the board stops changing, calling `fn(frame, ops,
-- calls)` for every frame along the way if one is given.
--
-- Two consecutive settled frames that look identical, rather than one. One is
-- not enough and the reason is worth writing down: at the very start of a swap
-- the two fruit are drawn at each other's cells, so all sixty-four hold
-- exactly one fruit and the board looks perfectly settled while a swap is in
-- fact under way. The next tick moves them off their cells and gives the game
-- away.
function M.watch(hs, fn, limit)
  local last, stable = nil, 0
  for _ = 1, limit or 800 do
    local f, ops, calls = M.frame(hs)
    if fn then fn(f, ops, calls) end
    local key = stability(f)
    if f.settled and key == last then
      stable = stable + 1
      if stable >= 2 then return f end
    else
      stable = 0
    end
    last = key
    hs.on.timer()
  end
  return M.frame(hs)
end

function M.settle(hs, limit)
  return M.watch(hs, nil, limit)
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

-- Every legal swap, brute force.
--
-- `ordinary`, if given, is the set of labels that are plain fruit -- learned
-- from fresh boards, which by construction hold nothing else. Any label
-- outside it is a special that is SPENT rather than matched, so a swap
-- touching one is a move whatever the run scanner thinks. Without this the
-- reader's idea of "no moves left" stops being the game's, and a board
-- carrying a rainbow reads as deadlocked while the game plays happily on.
function M.legalSwaps(f, ordinary)
  local out = {}
  local function special(i)
    return ordinary and f.grid[i] and not ordinary[f.grid[i]]
  end
  local function trial(x1, y1, x2, y2)
    local i, j = (y1 - 1) * f.cols + x1, (y2 - 1) * f.cols + x2
    if special(i) or special(j) then
      out[#out + 1] = { x1, y1, x2, y2 }
      return
    end
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
-- The labels that are ordinary fruit, unioned over several FRESH boards --
-- which hold no specials by construction, so anything seen later that is not
-- in here is one. Several boards rather than one because a single deal can
-- miss a kind entirely; the odds are tiny but not zero, and a missed kind
-- would be taken for a special ever after.
function M.ordinaryKinds(boot, boards)
  local set = {}
  for n = 1, boards or 4 do
    local hs = boot()
    for _ = 1, n * 3 do hs.on.timer() end   -- idling reseeds the deal
    hs.on.enterKey()
    local f = M.settle(hs)
    for i = 1, (f.cols or 8) * (f.rows or 8) do
      if f.grid[i] then set[f.grid[i]] = true end
    end
  end
  return set
end

function M.step(hs, pick, ordinary)
  local f = M.settle(hs)
  if not f.colX then return nil end
  local swaps = M.legalSwaps(f, ordinary)
  if #swaps == 0 then return nil, nil, nil, f end

  local s = swaps[pick and pick(#swaps) or 1]
  hs.on.mouseDown(M.centre(f, s[1], s[2]))
  hs.on.mouseDown(M.centre(f, s[3], s[4]))

  local busiest, busyOps = -1, nil
  local after = M.watch(hs, function(g, ops)
    -- "Busiest" means the most cells actually empty, which finds the frame
    -- with the most fruit in the air rather than one caught between ticks.
    local empty = (g.cols or 8) * (g.rows or 8) - (g.filled or 0)
    if empty > busiest then busiest, busyOps = empty, ops end
  end)

  return after, s, busyOps
end

return M
