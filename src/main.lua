-- main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules live in src/game.lua. `platform.apilevel` is emitted as the first line
-- of the bundle by tools/bundle.py, so it is intentionally absent here.
--
-- When bundled, `Game` is already a local from the inlined module; the
-- `Game or require` form below also lets this file load under a desktop Lua.
local Game = Game or require("game")

local HUD_H    = 22    -- height of the score bar, pixels
local CELL_MIN = 6     -- below this the snake is hard to see
local BASE_TICK = 0.05 -- host timer period; Game:ticksPerStep() sets the pace

local ui = { w = 318, h = 212, cell = 8, cols = 34, rows = 21, ox = 0, oy = HUD_H }
local game = Game.new(ui.cols, ui.rows)

local ticks   = 0 -- timer ticks since the last snake move
local blink   = 0 -- drives the blinking prompt on overlay screens
local entropy = 0 -- ticks the player idled before starting; seeds the RNG

-- ---------------------------------------------------------------- helpers --

-- os.time() alone is a poor seed here: a handheld that has just been reset can
-- report the same value every launch, which would deal the same apples every
-- game. Mixing in how long the player sat on the title screen fixes that.
local function reseed()
  local t = 0
  if os and os.time then t = os.time() or 0 end
  if os and os.clock then t = t + math.floor((os.clock() or 0) * 1000) end
  math.randomseed(t + entropy * 7919)
  math.random(); math.random() -- first draws after a reseed are weakly mixed
end

local function newRound()
  reseed()
  game:reset()
  ticks = 0
end

local function confirm()
  local s = game.state
  if s == "ready" then
    newRound()
    game:start()
  elseif s == "paused" then
    game:resume()
  elseif game:isOver() then
    newRound()
    game:start()
  end
end

local function togglePause()
  if game.state == "playing" then
    game:pause()
  elseif game.state == "paused" then
    game:resume()
  end
end

-- --------------------------------------------------------------- lifecycle --

-- Called before the first paint, and again if the window is resized (which on
-- a handheld means never, but the computer software can resize freely).
function on.resize(w, h)
  ui.w, ui.h = w, h

  local fieldW = w - 8
  local fieldH = h - HUD_H - 8
  local cell = math.floor(math.min(fieldW / 34, fieldH / 21))
  if cell < CELL_MIN then cell = CELL_MIN end

  local cols = math.max(10, math.floor(fieldW / cell))
  local rows = math.max(8, math.floor(fieldH / cell))

  ui.cell, ui.cols, ui.rows = cell, cols, rows
  ui.ox = math.floor((w - cols * cell) / 2)
  ui.oy = HUD_H + math.floor((h - HUD_H - rows * cell) / 2)

  -- Only rebuild when the grid actually changed; a cosmetic resize shouldn't
  -- throw away a game in progress.
  if game.cols ~= cols or game.rows ~= rows then
    game = Game.new(cols, rows, { highScore = game.highScore, wrap = game.wrap })
  end
  platform.window:invalidate()
end

timer.start(BASE_TICK)

function on.timer()
  blink = blink + 1
  local dirty = false

  if game.state == "playing" then
    ticks = ticks + 1
    if ticks >= game:ticksPerStep() then
      ticks = 0
      game:step()
      dirty = true
    end
  else
    entropy = entropy + 1
    if blink % 8 == 0 then dirty = true end
  end

  if dirty then platform.window:invalidate() end
end

function on.deactivate()
  game:pause()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

function on.arrowKey(key)
  if game.state == "ready" then
    newRound()
    game:start()
  end
  game:setDirection(key)
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

local CHAR_DIRS = {
  w = "up",   ["8"] = "up",
  s = "down", ["2"] = "down",
  a = "left", ["4"] = "left",
  d = "right",["6"] = "right",
}

function on.charIn(ch)
  ch = string.lower(ch or "")
  local dir = CHAR_DIRS[ch]

  if dir then
    on.arrowKey(dir)
    return
  elseif ch == " " then
    confirm()
  elseif ch == "p" then
    togglePause()
  elseif ch == "r" then
    newRound()
    game:start()
  elseif ch == "m" and game.state ~= "playing" then
    -- Wall mode is a property of the round, so only offer it between rounds.
    game.wrap = not game.wrap
    if game:isOver() then newRound() end
  end

  platform.window:invalidate()
end

-- Steering by click, for the touchpad and for mouse play in the computer
-- software: move toward whichever axis the click is furthest along from the head.
function on.mouseDown(x, y)
  if game.state ~= "playing" then
    confirm()
  else
    local h = game.cells[game.head]
    local hx = ui.ox + (h.x - 0.5) * ui.cell
    local hy = ui.oy + (h.y - 0.5) * ui.cell
    local dx, dy = x - hx, y - hy
    if math.abs(dx) > math.abs(dy) then
      game:setDirection(dx < 0 and "left" or "right")
    else
      game:setDirection(dy < 0 and "up" or "down")
    end
  end
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function drawHud(gc)
  gc:setColorRGB(30, 34, 44)
  gc:fillRect(0, 0, ui.w, HUD_H)
  gc:setColorRGB(58, 64, 80)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  gc:setFont("sansserif", "b", 10)
  local labelW = gc:getStringWidth("SNAKE")

  gc:setFont("sansserif", "r", 10)
  local stats = "Score " .. game.score
    .. "   Len " .. game:length()
    .. "   Lv " .. game.level
    .. "   Best " .. game.highScore
  local statsW = gc:getStringWidth(stats)
  local statsX = ui.w - statsW - 6

  -- Big scores, or a narrower font than we assumed, can push the stats into
  -- the title. The stats matter more, so the title yields.
  if statsX > labelW + 12 then
    gc:setFont("sansserif", "b", 10)
    gc:setColorRGB(120, 230, 130)
    gc:drawString("SNAKE", 6, 4, "top")
    gc:setFont("sansserif", "r", 10)
  end

  gc:setColorRGB(215, 220, 232)
  gc:drawString(stats, math.max(4, statsX), 4, "top")
end

local function drawField(gc)
  local ox, oy, cell = ui.ox, ui.oy, ui.cell
  local pw, ph = game.cols * cell, game.rows * cell

  gc:setColorRGB(12, 14, 19)
  gc:fillRect(ox, oy, pw, ph)

  -- A dashed border is the visual tell that edges wrap instead of kill.
  gc:setPen("thin", game.wrap and "dashed" or "smooth")
  gc:setColorRGB(70, 78, 96)
  gc:drawRect(ox - 1, oy - 1, pw + 1, ph + 1)
  gc:setPen("thin", "smooth")

  if game.food then
    local fx = ox + (game.food.x - 1) * cell
    local fy = oy + (game.food.y - 1) * cell
    gc:setColorRGB(228, 72, 62)
    gc:fillArc(fx + 1, fy + 1, cell - 2, cell - 2, 0, 360)
  end

  -- Body shades from bright at the head to dark at the tail. The ramp is
  -- quantised into bands so a long snake needs ~8 setColorRGB calls, not 800.
  local n = math.max(1, game:length() - 1)
  local i, band = 0, -1
  for idx = game.head, game.tail, -1 do
    local c = game.cells[idx]
    local x = ox + (c.x - 1) * cell
    local y = oy + (c.y - 1) * cell

    if idx == game.head then
      gc:setColorRGB(158, 248, 158)
      band = -1
    else
      local b = math.floor((i / n) * 7)
      if b ~= band then
        band = b
        local t = b / 7
        gc:setColorRGB(
          math.floor(46 + 18 * (1 - t)),
          math.floor(206 - 96 * t),
          math.floor(112 - 46 * t))
      end
    end

    gc:fillRect(x, y, cell - 1, cell - 1)
    i = i + 1
  end

  -- Eyes, once the cells are big enough to fit them.
  if cell >= 7 then
    local h = game.cells[game.head]
    local hx = ox + (h.x - 1) * cell
    local hy = oy + (h.y - 1) * cell
    local d = game.dir
    local px = (d.x ~= 0) and (d.x > 0 and cell - 3 or 1) or 1
    local py = (d.y ~= 0) and (d.y > 0 and cell - 3 or 1) or 1
    gc:setColorRGB(16, 26, 18)
    if d.x ~= 0 then
      gc:fillRect(hx + px, hy + 1, 2, 2)
      gc:fillRect(hx + px, hy + cell - 4, 2, 2)
    else
      gc:fillRect(hx + 1, hy + py, 2, 2)
      gc:fillRect(hx + cell - 4, hy + py, 2, 2)
    end
  end
end

-- lines: array of { text, dim } -- dim entries blink on the overlay screens.
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

  gc:setColorRGB(26, 30, 39)
  gc:fillRect(bx, by, bw, bh)
  gc:setColorRGB(accent[1], accent[2], accent[3])
  gc:drawRect(bx, by, bw, bh)

  gc:setFont("sansserif", "b", 16)
  gc:drawString(title, bx + math.floor((bw - titleW) / 2), by + pad - 2, "top")

  gc:setFont("sansserif", "r", 10)
  local y = by + pad + 22
  local lit = (blink % 16) < 10
  for _, l in ipairs(lines) do
    if l[2] and not lit then
      gc:setColorRGB(90, 96, 110)
    elseif l[2] then
      gc:setColorRGB(235, 238, 245)
    else
      gc:setColorRGB(186, 192, 206)
    end
    gc:drawString(l[1], bx + math.floor((bw - gc:getStringWidth(l[1])) / 2), y, "top")
    y = y + lineH
  end
end

local function drawOverlay(gc)
  local s = game.state
  if s == "ready" then
    drawPanel(gc, "SNAKE", {
      { "Arrows, 2/4/6/8 or WASD to steer" },
      { "esc or P pause     R restart" },
      { game.wrap and "Edges: wrap around   (M)" or "Edges: solid walls   (M)" },
      { "Press enter to play", true },
    }, { 120, 230, 130 })
  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { "Score " .. game.score .. "     Length " .. game:length() },
      { "Press enter to resume", true },
    }, { 240, 190, 70 })
  elseif s == "over" then
    drawPanel(gc, "GAME OVER", {
      { "Score " .. game.score .. "     Length " .. game:length() },
      { "Best " .. game.highScore },
      { "Press enter to play again", true },
    }, { 228, 72, 62 })
  elseif s == "won" then
    drawPanel(gc, "PERFECT!", {
      { "You filled the board." },
      { "Score " .. game.score },
      { "Press enter to play again", true },
    }, { 120, 230, 130 })
  end
end

function on.paint(gc)
  gc:setColorRGB(18, 21, 27)
  gc:fillRect(0, 0, ui.w, ui.h)
  drawField(gc)
  drawHud(gc)
  drawOverlay(gc)
end
