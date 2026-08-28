-- Recovers the Wordle board and keyboard from a frame's draw calls, and drives
-- the game through them. Shared by tests/wordle/ui.lua and
-- tests/wordle/autoplay.lua.
--
-- Everything here reads the *painted frame*, never the game's own state, so no
-- test-only hooks have to reach the shipped script. The cost is that these
-- colours are a contract with src/wordle/main.lua: change one there and it has
-- to change here too.
--
-- Grid tiles and keyboard keys share the three mark colours, which is the
-- whole reason main.lua paints a backing rect behind the grid: anything inside
-- that rect is a tile, anything outside it is a key.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

local BOARD    = key({  40,  45,  58 })
local PAGE     = key({  18,  21,  27 })
local TILE_BG  = key({  30,  34,  44 })
local PANEL    = key({  26,  30,  39 })
local KEY_FILL = key({ 108, 114, 132 })

M.MARKS = {
  [key({  72,  76,  86 })] = "grey",
  [key({ 181, 159,  59 })] = "yellow",
  [key({  83, 141,  78 })] = "green",
}

-- The scale a letter's keyboard colour is only ever allowed to climb.
M.RANK = { unknown = 0, grey = 1, yellow = 2, green = 3 }

M.ROWS, M.LEN = 6, 5

local function inside(outer, r)
  return r.x >= outer.x and r.y >= outer.y
     and r.x + r.w <= outer.x + outer.w
     and r.y + r.h <= outer.y + outer.h
end

local function holds(r, x, y)
  return x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
end

local function sortedKeys(set)
  local out = {}
  for v in pairs(set) do out[#out + 1] = v end
  table.sort(out)
  return out
end

-- Nearest index in `list` to v, so a letter drawn a pixel off centre still
-- lands in the right column.
local function nearest(list, v)
  local best, bestD = 1, math.huge
  for i, c in ipairs(list) do
    local d = math.abs(c - v)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

-- Returns a table describing the frame:
--   board    the grid's backing rect
--   grid     [row][col] = { mark, letter, live, rect }
--   keys     ["a"] = { mark = "grey"|..., rect }, plus ["ENT"] and ["DEL"]
--   text     every drawString that is not on a tile or a key, in paint order
--   rects    every fillRect, for the containment checks in ui.lua
function M.read(ops)
  local f = { grid = {}, keys = {}, text = {}, rects = {}, strings = {} }
  local fills, strings = {}, {}

  for _, o in ipairs(ops) do
    if o.op == "fillRect" then
      f.rects[#f.rects + 1] = o
      local k = key(o.color)
      if k == BOARD and not f.board then
        f.board = o
      elseif k ~= PAGE then
        fills[#fills + 1] = o
      end
    elseif o.op == "drawRect" then
      f.rects[#f.rects + 1] = o
      fills[#fills + 1] = o
    elseif o.op == "drawString" then
      strings[#strings + 1] = o
      f.strings[#f.strings + 1] = o
    end
  end

  if not f.board then return f end

  -- Tiles: the square fills inside the backing rect. drawRect outlines ride
  -- along on the same geometry and say whether a square is "live" -- holding a
  -- letter that has not been scored yet.
  local tiles, outlines = {}, {}
  for _, o in ipairs(fills) do
    if inside(f.board, o) and not (o.x == f.board.x and o.w == f.board.w) then
      if o.op == "fillRect" then tiles[#tiles + 1] = o else outlines[#outlines + 1] = o end
    end
  end

  local xs, ys = {}, {}
  for _, t in ipairs(tiles) do xs[t.x] = true; ys[t.y] = true end
  f.colX, f.rowY = sortedKeys(xs), sortedKeys(ys)

  for r = 1, M.ROWS do
    f.grid[r] = {}
    for c = 1, M.LEN do f.grid[r][c] = { mark = nil, letter = nil, live = false } end
  end

  for _, t in ipairs(tiles) do
    local c, r = nearest(f.colX, t.x), nearest(f.rowY, t.y)
    local cell = f.grid[r] and f.grid[r][c]
    if cell then
      cell.rect = t
      local k = key(t.color)
      if M.MARKS[k] then cell.mark = M.MARKS[k] end
    end
  end

  for _, o in ipairs(outlines) do
    local c, r = nearest(f.colX, o.x), nearest(f.rowY, o.y)
    local cell = f.grid[r] and f.grid[r][c]
    -- The brighter outline is the one main.lua uses for a square with a letter
    -- in it; the dim one is an untouched square.
    if cell and o.color[1] > 80 then cell.live = true end
  end

  -- Keys: coloured fills outside the backing rect that have a label on them.
  local keyRects = {}
  for _, o in ipairs(fills) do
    if o.op == "fillRect" and not inside(f.board, o) then
      local k = key(o.color)
      if M.MARKS[k] or k == KEY_FILL or k == PANEL then keyRects[#keyRects + 1] = o end
    end
  end

  for _, s in ipairs(strings) do
    local host, hostArea = nil, math.huge
    for _, t in ipairs(tiles) do
      if holds(t, s.x, s.y) and t.w * t.h < hostArea then host, hostArea = t, t.w * t.h end
    end
    if host then
      local c, r = nearest(f.colX, host.x), nearest(f.rowY, host.y)
      if f.grid[r] and f.grid[r][c] then f.grid[r][c].letter = s.text:lower() end
    else
      for _, kr in ipairs(keyRects) do
        if holds(kr, s.x, s.y) and kr.w * kr.h < hostArea then host, hostArea = kr, kr.w * kr.h end
      end
      if host then
        local k = key(host.color)
        f.keys[s.text:lower()] = { mark = M.MARKS[k] or "unknown", rect = host }
      else
        f.text[#f.text + 1] = s.text
      end
    end
  end

  return f
end

function M.frame(hs)
  local _, ops = hs:paint()
  return M.read(ops), ops
end

-- Everything on screen, as a string. Two frames with the same signature are
-- the same frame as far as these tests are concerned.
function M.signature(f)
  local parts = {}
  for r = 1, M.ROWS do
    for c = 1, M.LEN do
      local cell = f.grid[r] and f.grid[r][c] or {}
      parts[#parts + 1] = (cell.letter or ".") .. (cell.mark or "-")
    end
  end
  for _, letter in ipairs({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                            "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" }) do
    parts[#parts + 1] = (f.keys[letter] and f.keys[letter].mark or "?")
  end
  parts[#parts + 1] = table.concat(f.text, " ")
  return table.concat(parts, "")
end

-- Runs the timer until the frame stops changing, so the reveal is over and the
-- candidate filter has finished its slices. Returns the settled frame.
--
-- STILL is 6 rather than 1 on purpose: the reveal turns one tile every few
-- ticks, so the frames *between* two tiles are identical and a single quiet
-- tick is not evidence of anything. Stopping at the first repeat reads a
-- half-revealed row as a finished one.
local STILL = 6

function M.settle(hs, limit)
  local last, quiet = M.signature(M.frame(hs)), 0
  for _ = 1, limit or 400 do
    hs.on.timer()
    local sig = M.signature(M.frame(hs))
    if sig == last then
      quiet = quiet + 1
      if quiet >= STILL then return M.frame(hs) end
    else
      quiet = 0
    end
    last = sig
  end
  return M.frame(hs)
end

function M.typeWord(hs, word)
  for i = 1, #word do hs.on.charIn(word:sub(i, i)) end
end

-- Types a word and plays it, then waits out the reveal.
function M.play(hs, word)
  M.typeWord(hs, word)
  hs.on.enterKey()
  return M.settle(hs)
end

-- The rows that have been scored, as { word = "slate", marks = "BYGBB" }.
function M.guesses(f)
  local out = {}
  local code = { grey = "B", yellow = "Y", green = "G" }
  for r = 1, M.ROWS do
    local word, marks, full = {}, {}, true
    for c = 1, M.LEN do
      local cell = f.grid[r][c]
      if cell.letter and cell.mark then
        word[c], marks[c] = cell.letter, code[cell.mark]
      else
        full = false
      end
    end
    if full then out[#out + 1] = { word = table.concat(word), marks = table.concat(marks) } end
  end
  return out
end

return M
