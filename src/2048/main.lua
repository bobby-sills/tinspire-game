-- main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules live in src/2048/game.lua. `platform.apilevel` is emitted as the first
-- line of the bundle by tools/bundle.py, so it is intentionally absent here.
--
-- When bundled, `Board` is already a local from the inlined module; the
-- `Board or require` form below also lets this file load under a desktop Lua.
local Board = Board or require("game")

-- ------------------------------------------------------------------ tuning --
-- 2048 is turn-based, so there is no game loop: every repaint is caused by a
-- key. The timer exists only to run the slide, and it asks for repaints only
-- while a slide is actually in flight.
local BASE_TICK   = 0.05  -- host timer period, the practical floor on hardware
local SLIDE_TICKS = 3     -- ticks a tile takes to travel to its new cell
local POP_TICKS   = 2     -- ticks new and merged tiles take to swell to size
-- ---------------------------------------------------------------------------

local HUD_H = 22          -- height of the score bar, pixels
local N = Board.SIZE

-- Tile colours, and the text colour that stays legible on each. 2 and 4 are
-- pale enough to need dark digits; everything above them takes light ones.
-- These exact values are also how tests/2048/autoplay.lua reads the board back
-- out of a frame, so changing one means changing it there too.
local TILE = {
  [2]     = { 238, 228, 218,  58,  54,  48 },
  [4]     = { 237, 224, 200,  58,  54,  48 },
  [8]     = { 242, 177, 121, 249, 246, 242 },
  [16]    = { 245, 149,  99, 249, 246, 242 },
  [32]    = { 246, 124,  95, 249, 246, 242 },
  [64]    = { 235,  90,  58, 249, 246, 242 },
  [128]   = { 237, 207, 114, 249, 246, 242 },
  [256]   = { 237, 200,  90, 249, 246, 242 },
  [512]   = { 240, 192,  64, 249, 246, 242 },
  [1024]  = { 242, 184,  38, 249, 246, 242 },
  [2048]  = { 246, 176,  14, 249, 246, 242 },
  [4096]  = { 108,  92, 196, 249, 246, 242 },
  [8192]  = {  84,  72, 168, 249, 246, 242 },
  [16384] = {  62,  52, 140, 249, 246, 242 },
}
local TILE_SUPER = { 44, 38, 104, 249, 246, 242 }

local PAGE_BG  = {  18,  21,  27 }
local HUD_BG   = {  30,  34,  44 }
local HUD_RULE = {  58,  64,  80 }
local BOARD_BG = {  40,  45,  58 }
local EMPTY    = {  56,  63,  80 }
local PANEL_BG = {  26,  30,  39 }
local GOLD     = { 246, 176,  14 }

-- Largest first: fitFont walks down until the label measures small enough.
local FONT_STEPS = { 24, 16, 12, 11, 10, 9, 7 }

local ui = { w = 318, h = 212, bx = 0, by = HUD_H, side = 0, tile = 0, gap = 0 }
local board = Board.new()

local anim    = nil -- { tiles, pop, t } while a slide is playing, else nil
local entropy = 0   -- ticks the player idled before starting; seeds the RNG

-- ---------------------------------------------------------------- helpers --

local function col(gc, c)
  gc:setColorRGB(c[1], c[2], c[3])
end

-- os.time() alone is a poor seed here: a handheld that has just been reset can
-- report the same value every launch, which would deal the same opening tiles
-- every game. Mixing in how long the player sat on the title screen fixes that.
local function reseed()
  local t = 0
  if os and os.time then t = os.time() or 0 end
  if os and os.clock then t = t + math.floor((os.clock() or 0) * 1000) end
  math.randomseed(t + entropy * 7919)
  math.random(); math.random() -- first draws after a reseed are weakly mixed
end

local function newRound()
  reseed()
  board:reset()
  anim = nil
end

-- Records the cells that should swell after the slide: everything that just
-- merged, plus the tile that spawned in response to the move.
local function beginAnim()
  local pop = {}
  if board.merges then
    for _, m in ipairs(board.merges) do pop[(m.y - 1) * N + m.x] = true end
  end
  if board.spawned then
    pop[(board.spawned.y - 1) * N + board.spawned.x] = true
  end
  anim = { tiles = board.slide or {}, pop = pop, t = 0 }
end

local function moveBoard(dir)
  if board.state == "ready" then
    newRound()
    board:start()
  elseif board.state == "won" then
    board:keepPlaying() -- sliding past the win panel means "keep going"
  end
  if board:move(dir) then beginAnim() end
end

local function confirm()
  local s = board.state
  if s == "ready" or s == "over" then
    newRound()
    board:start()
  elseif s == "paused" then
    board:resume()
  elseif s == "won" then
    board:keepPlaying()
  end
end

local function togglePause()
  if board.state == "playing" then
    board:pause()
  elseif board.state == "paused" then
    board:resume()
  end
end

local function undoMove()
  if board:undo() then anim = nil end
end

-- --------------------------------------------------------------- lifecycle --

-- Called before the first paint, and again if the window is resized (which on
-- a handheld means never, but the computer software can resize freely). The
-- board is always 4x4, so a resize is purely cosmetic and never disturbs a
-- game in progress.
function on.resize(w, h)
  ui.w, ui.h = w, h

  -- The hint strip is the first thing to go when the window is short.
  local hintH = (h - HUD_H >= 120) and 15 or 0
  local side = math.min(w - 8, h - HUD_H - hintH - 6)
  if side < 40 then side = 40 end

  local gap = math.max(2, math.floor(side / 44))
  local tile = math.floor((side - gap * (N + 1)) / N)
  if tile < 4 then tile, gap = 4, 2 end
  side = tile * N + gap * (N + 1)

  ui.side, ui.tile, ui.gap = side, tile, gap
  ui.bx = math.max(0, math.floor((w - side) / 2))
  ui.by = math.max(HUD_H, HUD_H + math.floor((h - HUD_H - hintH - side) / 2))
  ui.hintY = ui.by + side + 3
  ui.hint = hintH > 0 and (ui.hintY + 13 <= h)

  platform.window:invalidate()
end

timer.start(BASE_TICK)

-- The only repaint that does not come from a key press. It happens solely
-- while a slide is on screen; the rest of the time this costs one branch.
function on.timer()
  if anim then
    anim.t = anim.t + 1
    if anim.t >= SLIDE_TICKS + POP_TICKS then anim = nil end
    platform.window:invalidate()
  elseif board.state == "ready" then
    entropy = entropy + 1 -- idling on the title screen; nothing has changed
  end
end

function on.deactivate()
  board:pause()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

local DIR_KEYS = { up = true, down = true, left = true, right = true }

function on.arrowKey(key)
  if DIR_KEYS[key] then moveBoard(key) end
  platform.window:invalidate()
end

function on.enterKey()
  confirm()
  platform.window:invalidate()
end

function on.escapeKey()
  togglePause()
  platform.window:invalidate()
end

function on.backspaceKey()
  undoMove()
  platform.window:invalidate()
end

local CHAR_DIRS = {
  w = "up",    ["8"] = "up",
  s = "down",  ["2"] = "down",
  a = "left",  ["4"] = "left",
  d = "right", ["6"] = "right",
}

function on.charIn(ch)
  ch = string.lower(ch or "")
  local dir = CHAR_DIRS[ch]

  if dir then
    moveBoard(dir)
  elseif ch == " " then
    confirm()
  elseif ch == "p" then
    togglePause()
  elseif ch == "u" then
    undoMove()
  elseif ch == "r" then
    newRound()
    board:start()
  end

  platform.window:invalidate()
end

-- Sliding by click, for the touchpad and for mouse play in the computer
-- software: slide toward whichever side of the board's centre was clicked.
function on.mouseDown(x, y)
  if board.state ~= "playing" then
    confirm()
  else
    local dx = x - (ui.bx + ui.side / 2)
    local dy = y - (ui.by + ui.side / 2)
    if math.abs(dx) > math.abs(dy) then
      moveBoard(dx < 0 and "left" or "right")
    else
      moveBoard(dy < 0 and "up" or "down")
    end
  end
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function cellX(gx) return ui.bx + ui.gap + (gx - 1) * (ui.tile + ui.gap) end
local function cellY(gy) return ui.by + ui.gap + (gy - 1) * (ui.tile + ui.gap) end

-- Font metrics are unknown until runtime, so the digits are *measured* down
-- from the largest size that could fit rather than guessed from digit count.
-- This is what shrinks 128 and 2048 without ever assuming a character width.
local function fitFont(gc, text, maxW, maxH)
  for _, s in ipairs(FONT_STEPS) do
    if s + 4 <= maxH then
      gc:setFont("sansserif", "b", s)
      if gc:getStringWidth(text) <= maxW then return s end
    end
  end
  gc:setFont("sansserif", "b", 7)
  return 7
end

-- scale < 1 shrinks the tile about its cell's centre. It is never above 1, so
-- a swelling tile can't spill out of the board however small the cells get.
local function drawTile(gc, px, py, size, value, scale)
  local s = size
  if scale and scale < 1 then
    s = math.max(2, math.floor(size * scale))
    px = px + math.floor((size - s) / 2)
    py = py + math.floor((size - s) / 2)
  end

  local c = TILE[value] or TILE_SUPER
  gc:setColorRGB(c[1], c[2], c[3])
  gc:fillRect(px, py, s, s)

  if s < 10 then return end -- no room for digits; the colour carries the value

  local text = tostring(value)
  fitFont(gc, text, s - 4, s - 2)
  gc:setColorRGB(c[4], c[5], c[6])
  gc:drawString(text,
    px + math.floor((s - gc:getStringWidth(text)) / 2),
    py + math.floor((s - gc:getStringHeight(text)) / 2), "top")
end

local function drawBoard(gc)
  col(gc, BOARD_BG)
  gc:fillRect(ui.bx, ui.by, ui.side, ui.side)

  col(gc, EMPTY)
  for y = 1, N do
    for x = 1, N do
      gc:fillRect(cellX(x), cellY(y), ui.tile, ui.tile)
    end
  end

  -- Mid-slide: the grid already holds the result, so the tiles on screen are
  -- the ones the move consumed, drawn at their pre-merge values in flight.
  if anim and anim.t < SLIDE_TICKS then
    local p = anim.t / SLIDE_TICKS
    for _, m in ipairs(anim.tiles) do
      local fx, fy = cellX(m.fromX), cellY(m.fromY)
      local tx, ty = cellX(m.toX), cellY(m.toY)
      drawTile(gc, math.floor(fx + (tx - fx) * p),
                   math.floor(fy + (ty - fy) * p), ui.tile, m.value)
    end
    return
  end

  local popScale, popCells
  if anim then
    local p = (anim.t - SLIDE_TICKS) / POP_TICKS
    if p > 1 then p = 1 end
    popScale, popCells = 0.55 + 0.45 * p, anim.pop
  end

  for y = 1, N do
    for x = 1, N do
      local v = board:get(x, y)
      if v ~= 0 then
        local scale = popCells and popCells[(y - 1) * N + x] and popScale or nil
        drawTile(gc, cellX(x), cellY(y), ui.tile, v, scale)
      end
    end
  end
end

local function drawHud(gc)
  col(gc, HUD_BG)
  gc:fillRect(0, 0, ui.w, HUD_H)
  col(gc, HUD_RULE)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  gc:setFont("sansserif", "b", 12)
  local titleW = gc:getStringWidth("2048")

  gc:setFont("sansserif", "r", 10)

  -- Drop fields rather than assume the whole line fits: a long game plus a
  -- narrow window is exactly when the Nspire would clip it without a word.
  local stats, statsX
  for _, candidate in ipairs({
    "Score " .. board.score .. "   Best " .. board.best .. "   Moves " .. board.moves,
    "Score " .. board.score .. "   Best " .. board.best,
    "Score " .. board.score,
  }) do
    stats = candidate
    statsX = ui.w - gc:getStringWidth(candidate) - 10
    if statsX > titleW + 12 then break end
  end

  -- Even the shortest form can collide with the title on a very narrow
  -- window. The score matters more, so the title yields.
  if statsX > titleW + 12 then
    gc:setFont("sansserif", "b", 12)
    col(gc, GOLD)
    gc:drawString("2048", 6, 3, "top")
    gc:setFont("sansserif", "r", 10)
  end

  gc:setColorRGB(215, 220, 232)
  gc:drawString(stats, math.max(4, statsX), 5, "top")
end

-- Degrades by dropping to a shorter hint, then to none, rather than assuming
-- the full line fits at whatever width the font turns out to be.
local function drawHint(gc)
  if not ui.hint then return end
  gc:setFont("sansserif", "r", 9)
  gc:setColorRGB(120, 128, 148)
  for _, text in ipairs({
    "Arrows move    U undo    esc pause    R restart",
    "Arrows move    U undo    esc pause",
    "Arrows move    U undo",
  }) do
    local w = gc:getStringWidth(text)
    if w <= ui.w - 8 then
      gc:drawString(text, math.floor((ui.w - w) / 2), ui.hintY, "top")
      return
    end
  end
end

-- lines: array of { text, highlight }. Mirrors Snake's overlay panels, minus
-- the blinking prompt -- nothing here repaints on a timer.
local function drawPanel(gc, title, lines, accent)
  gc:setFont("sansserif", "b", 16)
  local titleW = gc:getStringWidth(title)

  gc:setFont("sansserif", "r", 10)
  local maxW = titleW
  for _, l in ipairs(lines) do
    local lw = gc:getStringWidth(l[1])
    if lw > maxW then maxW = lw end
  end

  local pad, lineH = 12, 14
  -- Clamp to the window: the handheld is always wide enough, but the computer
  -- software can be resized smaller than the panel's natural size, and the
  -- Nspire clips silently rather than complaining.
  local bw = math.min(maxW + pad * 2, ui.w - 4)
  local bh = math.min(24 + #lines * lineH + pad * 2, ui.h - HUD_H - 4)
  local bx = math.max(2, math.floor((ui.w - bw) / 2))
  local by = math.max(HUD_H + 2, math.floor((ui.h - bh) / 2) + math.floor(HUD_H / 2))

  col(gc, PANEL_BG)
  gc:fillRect(bx, by, bw, bh)
  col(gc, accent)
  gc:drawRect(bx, by, bw, bh)

  gc:setFont("sansserif", "b", 16)
  col(gc, accent)
  gc:drawString(title, bx + math.floor((bw - titleW) / 2), by + pad - 2, "top")

  gc:setFont("sansserif", "r", 10)
  local y = by + pad + 22
  for _, l in ipairs(lines) do
    if l[2] then
      gc:setColorRGB(235, 238, 245)
    else
      gc:setColorRGB(186, 192, 206)
    end
    gc:drawString(l[1], bx + math.floor((bw - gc:getStringWidth(l[1])) / 2), y, "top")
    y = y + lineH
  end
end

local function drawOverlay(gc)
  local s = board.state
  if s == "ready" then
    drawPanel(gc, "2048", {
      { "Arrows, 2/4/6/8 or WASD to slide" },
      { "Equal tiles merge; reach 2048" },
      { "U or backspace undoes one move" },
      { "Press enter to play", true },
    }, GOLD)
  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { "Score " .. board.score .. "     Best " .. board.best },
      { "Press enter to resume", true },
    }, { 240, 190, 70 })
  elseif s == "won" then
    drawPanel(gc, "2048!", {
      { "Score " .. board.score .. " in " .. board.moves .. " moves" },
      { "Press enter to keep going", true },
    }, GOLD)
  elseif s == "over" then
    drawPanel(gc, "GAME OVER", {
      { "Score " .. board.score .. "     Best " .. board.best },
      { "Largest tile " .. board:maxTile() .. "     " .. board.moves .. " moves" },
      { board:canUndo() and "U undoes your last move" or "No move left in any direction" },
      { "Press enter to play again", true },
    }, { 228, 72, 62 })
  end
end

function on.paint(gc)
  col(gc, PAGE_BG)
  gc:fillRect(0, 0, ui.w, ui.h)
  drawBoard(gc)
  drawHud(gc)
  drawHint(gc)
  drawOverlay(gc)
end
