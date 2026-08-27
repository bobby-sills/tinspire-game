-- Recovers a Connect Four position from a frame's draw calls, and gives the
-- tests a way to play through the built bundle. Shared by tests/connect4/ui.lua
-- and tests/connect4/autoplay.lua.
--
-- Everything here reads the *painted frame*, never the game's own state, so no
-- test-only hooks have to reach the shipped script. The cost is that these
-- colours are a contract with src/connect4/main.lua: change one there and it
-- has to change here too.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

local BOARD = key({ 38, 78, 180 })
local RING  = key({ 255, 255, 255 })
local PANEL = key({ 26, 30, 39 })
local HUD   = key({ 30, 34, 44 })

M.PLAYER = {
  ["226,66,60"]  = 1, -- red
  ["247,199,58"] = 2, -- yellow
}

M.COLS, M.ROWS = 7, 6

-- Returns a table describing one painted frame:
--   board     the board's fillRect, or nil if none was drawn
--   arcs         every fillArc: the 42 board cells, holes and discs alike,
--                plus at most one disc in flight. Each is
--                { rect = op, player = 0|1|2, c, r }.
--   grid         42 entries, 0 empty, 1 red, 2 yellow, indexed (r-1)*7 + c
--   cellsPainted how many distinct cells the frame actually drew; 42 unless
--                something is wrong
--   cell, size, pad  the cell pitch, the disc diameter and the inset
--   rings        the white highlight arcs behind a winning four
--   falling      the disc in flight, if there is one
--   thinking     true while the bot's indicator is on screen
--   thinkDepth   the depth that indicator is reporting
--   panel        true when an overlay panel or the result banner is up
function M.read(ops)
  local f = { arcs = {}, rings = {}, grid = {}, panel = false }
  for i = 1, M.COLS * M.ROWS do f.grid[i] = 0 end

  for _, o in ipairs(ops) do
    local k = key(o.color)
    if o.op == "fillRect" then
      if k == BOARD then f.board = f.board or o
      elseif k == PANEL then f.panel = true
      elseif k == HUD then f.hud = f.hud or o end
    elseif o.op == "fillArc" then
      if k == RING then
        f.rings[#f.rings + 1] = o
      else
        f.arcs[#f.arcs + 1] = { rect = o, player = M.PLAYER[k] or 0 }
      end
    elseif o.op == "drawString" then
      -- "Thinking d5..." -- the depth the bot is on, which is the honest
      -- measure of how much of its budget it has spent.
      local depth = o.text:match("^Thinking d(%d+)")
      if depth then
        f.thinking = true
        f.thinkDepth = tonumber(depth)
      end
    end
  end

  if #f.arcs == 0 or not f.board then return f end

  -- The grid geometry comes from the board rectangle, not from where the arcs
  -- happen to sit. Deriving it from the arcs looked simpler and was wrong: a
  -- disc caught in flight contributes a row of its own, which shifted every
  -- other arc's row by one.
  local cell = f.board.w / M.COLS
  local d = f.arcs[1].rect.w
  local pad = (cell - d) / 2
  f.cell, f.size, f.pad = cell, d, pad

  f.colX, f.rowY = {}, {}
  for c = 1, M.COLS do f.colX[c] = f.board.x + (c - 1) * cell + pad end
  for r = 1, M.ROWS do f.rowY[r] = f.board.y + (r - 1) * cell + pad end

  -- The cells are painted first, in order, and a disc in flight last. So an
  -- arc that is off its cell is falling -- and so is one that is exactly on a
  -- cell already accounted for, which is how a disc caught at the very top of
  -- its column, or one landing in the top row, still reads as falling rather
  -- than as a disc that teleported there.
  local seen = {}
  f.cellsPainted = 0

  for _, a in ipairs(f.arcs) do
    local gx = math.floor((a.rect.x - f.board.x) / cell) + 1
    local gy = math.floor((a.rect.y - f.board.y) / cell) + 1
    if gx < 1 then gx = 1 elseif gx > M.COLS then gx = M.COLS end
    if gy < 1 then gy = 1 elseif gy > M.ROWS then gy = M.ROWS end
    local cellIdx = (gy - 1) * M.COLS + gx
    a.c, a.r = gx, gy

    if a.rect.x == f.colX[gx] and a.rect.y == f.rowY[gy] and not seen[cellIdx] then
      seen[cellIdx] = true
      f.cellsPainted = f.cellsPainted + 1
      if a.player ~= 0 then f.grid[cellIdx] = a.player end
    else
      f.falling = a
    end
  end

  return f
end

function M.frame(hs)
  local _, ops = hs:paint()
  return M.read(ops), ops
end

function M.signature(f)
  return table.concat(f.grid, ",")
end

function M.discCount(f)
  local n = 0
  for _, v in ipairs(f.grid) do if v ~= 0 then n = n + 1 end end
  return n
end

-- Which columns still have room, read off the painted grid.
function M.openColumns(f)
  local out = {}
  for c = 1, M.COLS do
    if f.grid[c] == 0 then out[#out + 1] = c end -- row 1 is the top row
  end
  return out
end

-- Runs the timer until nothing is moving: no disc in flight, and the bot no
-- longer thinking. Returns the settled frame, or nil if it never settled --
-- which is a bug, and the caller should say so rather than carry on.
function M.settle(hs, limit)
  for _ = 1, limit or 600 do
    local f = M.frame(hs)
    if not f.falling and not f.thinking then return f end
    hs.on.timer()
  end
  return nil
end

-- Plays one disc into column c and waits for the board to come to rest --
-- including the bot's reply, if there is a bot. Returns the settled frame.
function M.play(hs, c, limit)
  hs.on.charIn(tostring(c))
  return M.settle(hs, limit)
end

-- ------------------------------------------------- driving the game back ----
--
-- A second, independent copy of the rules, loaded straight from source. The
-- tests drive the bundle only through its key handlers and its painted
-- frames; this copy is what decides which key to press next, so a bot-vs-bot
-- session needs no test-only hook inside the shipped script.
do
  local path = (os.getenv("GAME_SRC") or "src/connect4") .. "/game.lua"
  local loaded, rules = pcall(dofile, path)
  M.Rules = loaded and rules or nil
end

-- Rebuilds a Board from a painted grid. Whose turn it is follows from the
-- disc counts, since red always opens.
function M.toBoard(f)
  local R = assert(M.Rules, "tests/connect4/frame.lua could not load the rules")
  local b = R.new()
  b:start()

  local counts = { 0, 0 }
  for r = 1, M.ROWS do
    for c = 1, M.COLS do
      local v = f.grid[(r - 1) * M.COLS + c]
      if v ~= 0 then
        b.cells[(r - 1) * M.COLS + c] = v
        local h = M.ROWS - r + 1
        if h > b.heights[c] then b.heights[c] = h end
        b.nplaced = b.nplaced + 1
        counts[v] = counts[v] + 1
      end
    end
  end

  -- Window counts and the running score are normally maintained by place(),
  -- which building the board this way went around.
  local W = R.WINDOWS
  for wid = 1, #W / 4 do
    local base, ones, twos = (wid - 1) * 4, 0, 0
    for k = 1, 4 do
      local v = b.cells[W[base + k]]
      if v == 1 then ones = ones + 1 elseif v == 2 then twos = twos + 1 end
    end
    b.wcode[wid] = ones * 5 + twos
    b.score = b.score + R.WSCORE[ones * 5 + twos + 1]
  end
  for r = 1, M.ROWS do
    local v = b.cells[(r - 1) * M.COLS + 4]
    if v == 1 then b.score = b.score + R.CENTRE_WEIGHT
    elseif v == 2 then b.score = b.score - R.CENTRE_WEIGHT end
  end

  b.turn = (counts[1] == counts[2]) and 1 or 2
  return b
end

-- The move a bot of the given difficulty would make in the painted position.
-- A position built this way is always in the "playing" state -- it never went
-- through drop(), so a won board does not know it is won. Callers stop on the
-- overlay panel appearing in the frame instead; the check here is only for a
-- board with nowhere left to play.
function M.bestMove(f, level)
  local b = M.toBoard(f)
  if #b:legalMoves() == 0 then return nil end
  return M.Rules.AI.fromLevel(b, level or 3):solve()
end

return M
