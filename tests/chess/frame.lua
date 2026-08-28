-- Recovers a chess position from a frame's draw calls, and gives the tests a
-- way to play through the built bundle. Shared by tests/chess/ui.lua and
-- tests/chess/autoplay.lua.
--
-- Everything here reads the *painted frame*, never the game's own state, so no
-- test-only hooks have to reach the shipped script. The cost is that these
-- colours and the "Thinking d" and "Last:" strings are a contract with
-- src/chess/main.lua: change one there and it has to change here too.

local M = {}

local function key(c) return c[1] .. "," .. c[2] .. "," .. c[3] end

local RIM      = key({  74,  52,  38 })
local PANEL    = key({  26,  30,  39 })
local HUD      = key({  30,  34,  44 })
local W_INK    = key({  30,  30,  38 })
local B_INK    = key({ 236, 236, 244 })
local W_FILL   = key({ 248, 246, 240 })
local B_FILL   = key({  44,  44,  54 })
local CURSOR   = key({ 250, 250, 250 })
local DEST     = key({  70, 158,  84 })
local CHECK_SQ = key({ 208,  76,  66 })
local ACCENT   = key({ 226, 190, 100 })
local SEL      = { [key({ 246, 226, 120 })] = true, [key({ 200, 172,  70 })] = true }
local LAST     = { [key({ 214, 208, 128 })] = true, [key({ 146, 138,  74 })] = true }

M.LETTERS = { P = 1, N = 2, B = 3, R = 4, Q = 5, K = 6 }
M.SIDE_INK = { [W_INK] = 1, [B_INK] = 2 }

-- The board draws pieces one of two ways: 16x16 sprites where a square is big
-- enough for them, and letters on discs where it is not. This reader handles
-- both, because tests/run_ui.lua drives window sizes either side of the line.
M.SIDE_FILL = { [W_FILL] = 1, [B_FILL] = 2 }

-- A sprite is identified by how many horizontal runs it is drawn in and how
-- many pixels those runs cover -- a pair that is unique across the six pieces.
-- This is a contract with the art in assets/chess and with the table
-- tools/sprites.py generates from it; tests/chess/run.lua does not depend on
-- it, so a change to the sprites breaks only this line and not the rules.
M.SPRITE_SHAPES = {
  ["7,28"]  = 1, -- pawn
  ["10,44"] = 2, -- knight
  ["11,34"] = 3, -- bishop
  ["10,36"] = 4, -- rook
  ["13,42"] = 5, -- queen
  ["12,44"] = 6, -- king
}

-- Returns a table describing one painted frame:
--   rim         the board's moulded-edge fillRect, or nil if no board was drawn
--   bx,by,cell,board  the board geometry, derived from that rect
--   cells       every piece as { c, r, side, type }, in screen cells 0..7
--   grid        64 entries indexed r*8 + c + 1: 0 empty, else side*8 + type
--   cursor      { c, r } of the cursor outline, if one is up
--   sel         { c, r } of the selected square, if one is
--   lastFrom/lastTo  the two last-move squares, unordered, as { c, r }
--   check       { c, r } of a king in check, if any
--   dests       screen cells carrying a legal-destination marker
--   thinking    true while the bot's indicator is on screen
--   thinkDepth  the depth that indicator is reporting
--   panel       true when an overlay panel is up
--   side        1 or 2, read off the "White/Black to move" line
--   lastText    the text of the "Last:" line, or nil
--   strings     every drawString, for tests that want to look for their own
function M.read(ops)
  local f = { cells = {}, grid = {}, dests = {}, last = {}, strings = {}, carets = {} }
  for i = 1, 64 do f.grid[i] = 0 end

  local letters, rects = {}, {}
  for _, o in ipairs(ops) do
    local k = key(o.color)
    if o.op == "fillRect" then
      if k == RIM then
        -- The rim is drawn once, before the squares. Anything else this
        -- colour would be a bug worth noticing, so take the first only.
        f.rim = f.rim or o
      elseif k == PANEL then
        f.panel = true
        -- An overlay draws pieces of its own -- the promotion chooser shows
        -- all four -- so the board reader has to know what it covers.
        f.panelRect = f.panelRect or o
      elseif k == HUD then f.hud = f.hud or o
      elseif k == ACCENT and o.w == 5 and o.h == 5 then
        -- The menu's caret. Sized rather than coloured apart, because the
        -- promotion chooser highlights its pick in the same accent.
        f.carets[#f.carets + 1] = o
      else rects[#rects + 1] = { op = o, k = k } end
    elseif o.op == "drawRect" then
      rects[#rects + 1] = { op = o, k = k }
    elseif o.op == "fillArc" then
      if k == DEST then rects[#rects + 1] = { op = o, k = k } end
    elseif o.op == "drawString" then
      f.strings[#f.strings + 1] = o
      local t = o.text
      if #t == 1 and M.LETTERS[t] and M.SIDE_INK[k] then
        letters[#letters + 1] = { op = o, side = M.SIDE_INK[k], type = M.LETTERS[t] }
      end
      local d = t:match("^Thinking d(%d+)")
      if d then f.thinking, f.thinkDepth = true, tonumber(d) end
      local side = t:match("^(%a+) to move")
      if side == "White" then f.side = 1 elseif side == "Black" then f.side = 2 end
      local last = t:match("^Last: (.+)$")
      if last then f.lastText = last end
    end
  end

  if not f.rim then return f end

  -- Geometry comes from the rim rectangle, never from where the pieces happen
  -- to sit: a board with a bare rank would otherwise read as a smaller board.
  local RIM_W = 2
  f.bx, f.by = f.rim.x + RIM_W, f.rim.y + RIM_W
  f.board = f.rim.w - RIM_W * 2
  f.cell = f.board / 8

  local function cellAt(x, y)
    local c = math.floor((x - f.bx) / f.cell)
    local r = math.floor((y - f.by) / f.cell)
    if c < 0 or c > 7 or r < 0 or r > 7 then return nil end
    return c, r
  end

  local function inPanel(o)
    local p = f.panelRect
    return p and o.x >= p.x and o.x < p.x + p.w and o.y >= p.y and o.y < p.y + p.h
  end

  local function place(c, r, side, ptype, extra)
    local cell = { c = c, r = r, side = side, type = ptype }
    if extra then for k, v in pairs(extra) do cell[k] = v end end
    f.cells[#f.cells + 1] = cell
    f.grid[r * 8 + c + 1] = side * 8 + ptype
    return cell
  end

  -- Sprites: gather every fill-coloured run into the square it lands in, then
  -- name the piece from the shape those runs add up to.
  local sprites = {}
  for _, R in ipairs(rects) do
    local side = M.SIDE_FILL[R.k]
    if side and R.op.op == "fillRect" and not inPanel(R.op) then
      local c, r = cellAt(R.op.x, R.op.y)
      if c then
        local idx = r * 8 + c
        local acc = sprites[idx]
        if not acc then
          acc = { c = c, r = r, side = side, runs = 0, px = 0,
                  x0 = R.op.x, y0 = R.op.y, x1 = R.op.x + R.op.w, y1 = R.op.y + 1 }
          sprites[idx] = acc
        end
        acc.runs = acc.runs + 1
        acc.px = acc.px + R.op.w
        if R.op.x < acc.x0 then acc.x0 = R.op.x end
        if R.op.y < acc.y0 then acc.y0 = R.op.y end
        if R.op.x + R.op.w > acc.x1 then acc.x1 = R.op.x + R.op.w end
        if R.op.y + 1 > acc.y1 then acc.y1 = R.op.y + 1 end
      end
    end
  end
  for _, acc in pairs(sprites) do
    local ptype = M.SPRITE_SHAPES[acc.runs .. "," .. acc.px]
    if ptype then
      place(acc.c, acc.r, acc.side, ptype,
        { x0 = acc.x0, y0 = acc.y0, x1 = acc.x1, y1 = acc.y1, sprite = true })
    else
      f.unknownSprites = (f.unknownSprites or 0) + 1
    end
  end
  f.spriteMode = next(sprites) ~= nil

  -- Letters: the fallback the game uses on squares too small for the art.
  for _, L in ipairs(letters) do
    local c, r = cellAt(L.op.x, L.op.y)
    if c and not inPanel(L.op) then
      L.op.piece = true
      place(c, r, L.side, L.type, { op = L.op })
    end
  end

  for _, R in ipairs(rects) do
    local o = R.op
    local c, r = cellAt(o.x, o.y)
    if c then
      if R.k == CURSOR and o.op == "drawRect" and not f.cursor then
        f.cursor = { c = c, r = r }
      elseif R.k == DEST then
        f.dests[#f.dests + 1] = { c = c, r = r }
      elseif R.k == CHECK_SQ and o.op == "fillRect" then
        f.check = { c = c, r = r }
      elseif SEL[R.k] and o.op == "fillRect" then
        f.sel = { c = c, r = r }
      elseif LAST[R.k] and o.op == "fillRect" then
        f.last[#f.last + 1] = { c = c, r = r }
      end
    end
  end

  return f
end

function M.frame(hs)
  local _, ops = hs:paint()
  return M.read(ops), ops
end

-- ---------------------------------------------------------------- the menu --
--
-- Read off the title panel rather than counted in keypresses: the rows wrap
-- round, so "press up until you reach the top" has no answer, and the values
-- cycle, so setting one means looking at what it currently says.
M.MENU_ROWS = { "Players:", "Level:", "Play as:", "Turn board:" }

-- Returns one entry per row: { label, value, marked }. Empty when no menu is
-- on screen.
function M.menuRows(f)
  local rows = {}
  for i, label in ipairs(M.MENU_ROWS) do
    for _, s in ipairs(f.strings) do
      if s.text:sub(1, #label) == label then
        local marked = false
        for _, c in ipairs(f.carets) do
          -- main.lua draws the caret four pixels below its row's baseline.
          if c.y == s.y + 4 then marked = true end
        end
        rows[i] = { label = label, value = s.text:sub(#label + 2), marked = marked }
        break
      end
    end
  end
  return rows
end

function M.markedRow(f)
  local rows = M.menuRows(f)
  for i, r in pairs(rows) do if r.marked then return i end end
  return nil
end

-- Moves the highlight onto `row`, then winds that row on until it reads
-- `want`. Returns true if it got there.
function M.menuSet(hs, row, want)
  for _ = 1, #M.MENU_ROWS do
    local marked = M.markedRow(M.frame(hs))
    if not marked or marked == row then break end
    hs.on.arrowKey("down")
  end
  for _ = 1, 8 do
    local rows = M.menuRows(M.frame(hs))
    if not rows[row] then return false end
    if rows[row].value == want then return true end
    hs.on.arrowKey("right")
  end
  return false
end

function M.pieceCount(f)
  local n = 0
  for _, v in ipairs(f.grid) do if v ~= 0 then n = n + 1 end end
  return n
end

function M.signature(f) return table.concat(f.grid, ",") end

-- Runs the timer until the bot is no longer thinking. Returns the settled
-- frame, or nil if it never settled -- which is a bug, and the caller should
-- say so rather than carry on.
function M.settle(hs, limit)
  for _ = 1, limit or 600 do
    local f, ops = M.frame(hs)
    if not f.thinking then return f, ops end
    hs.on.timer()
  end
  return nil
end

-- ------------------------------------------------- driving the game back ----
--
-- A second, independent copy of the rules, loaded straight from source. The
-- tests drive the bundle only through its key handlers, its mouse handler and
-- its painted frames; this copy is what decides which move to play next, so a
-- bot-against-bot session needs no test-only hook inside the shipped script.
do
  local path = (os.getenv("GAME_SRC") or "src/chess") .. "/game.lua"
  local loaded, rules = pcall(dofile, path)
  M.Rules = loaded and rules or nil
end

-- Which way round the board is drawn, decided by trying both against a
-- position we already know. Reading it rather than assuming it is what lets
-- the same driver work after the board has been flipped.
function M.orientation(f, shadow)
  local R = assert(M.Rules, "tests/chess/frame.lua could not load the rules")
  for _, flip in ipairs({ false, true }) do
    local okAll = true
    for r = 0, 7 do
      for c = 0, 7 do
        local sq = flip and R.sqOf(8 - c, r + 1) or R.sqOf(c + 1, 8 - r)
        local pc = shadow.board[sq]
        local want = (pc == 0) and 0 or (R.COLOR[pc] * 8 + R.TYPE[pc])
        if f.grid[r * 8 + c + 1] ~= want then okAll = false; break end
      end
      if not okAll then break end
    end
    if okAll then return flip end
  end
  return nil
end

-- Pixel centre of a square, given the orientation.
function M.squareXY(f, sq, flip)
  local R = M.Rules
  local file, rank = R.fileOf(sq), R.rankOf(sq)
  local c, r
  if flip then c, r = 8 - file, rank - 1 else c, r = file - 1, 8 - rank end
  return f.bx + (c + 0.5) * f.cell, f.by + (r + 0.5) * f.cell
end

function M.clickSquare(hs, f, sq, flip)
  local x, y = M.squareXY(f, sq, flip)
  hs.on.mouseDown(math.floor(x), math.floor(y))
end

-- Turns the sidebar's "Last:" text back into a move of `shadow`. The text is
-- long algebraic -- "Ng1-f3", "e7xd8=Q", "O-O" -- which is unambiguous, so
-- this only has to find the one legal move that matches.
function M.parseMove(shadow, text)
  local R = M.Rules
  local moves = {}
  local n = shadow:legalMoves(moves)

  if text == "O-O" or text == "O-O-O" then
    local want = (text == "O-O") and R.FLAG_KCASTLE or R.FLAG_QCASTLE
    for i = 1, n do
      if R.moveFlag(moves[i]) == want then return moves[i] end
    end
    return nil
  end

  local _, from, to, promo = text:match("^([KQRBN]?)([a-h][1-8])[-x]([a-h][1-8])=?([QRBN]?)$")
  if not from then return nil end
  local fromSq, toSq = R.squareFromName(from), R.squareFromName(to)
  local promoType = 0
  if promo ~= "" then
    for t, ch in ipairs(R.LETTER) do if ch == promo then promoType = t end end
  end
  for i = 1, n do
    local m = moves[i]
    if R.moveFrom(m) == fromSq and R.moveTo(m) == toSq
        and R.movePromo(m) == promoType then
      return m
    end
  end
  return nil
end

return M
