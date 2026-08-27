-- flappy_main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules live in src/flappy.lua. `platform.apilevel` is emitted as the first
-- line of the bundle by tools/bundle.py, so it is intentionally absent here.
--
-- When bundled, `Flappy` is already a local from the inlined module; the
-- `Flappy or require` form below also lets this file load under a desktop Lua.
local Flappy = Flappy or require("flappy")

local HUD_H     = 22    -- height of the score bar, pixels
local BASE_TICK = 0.05  -- host timer period -- one physics step per tick

-- The Nspire's timer will not reliably go below ~0.05 s, so 20 FPS is the
-- ceiling and one step per tick is the whole timing model. There is no
-- accumulator and no delta time: src/flappy.lua's constants are already
-- per-frame, which keeps the physics identical on every machine that runs it.

local ui = { w = 318, h = 212, ox = 0, oy = HUD_H, fw = 318, fh = 190 }
local game = Flappy.new(ui.fw, ui.fh)

local blink   = 0 -- drives the blinking prompt on overlay screens
local entropy = 0 -- ticks the player idled before starting; seeds the RNG

-- ---------------------------------------------------------------- palette --

local SKY       = { 18, 28, 48 }
local SKY_HI    = { 30, 44, 70 }
local STAR      = { 52, 66, 96 }
local GROUND    = { 62, 50, 38 }
local GRASS     = { 92, 146, 74 }
local PIPE      = { 86, 190, 92 }   -- the two columns, and nothing else
local PIPE_LIP  = { 128, 216, 130 }
local PIPE_EDGE = { 38, 106, 50 }
local BIRD      = { 252, 210, 74 }  -- the body, and nothing else
local BIRD_WING = { 226, 166, 46 }
local BIRD_BEAK = { 240, 122, 48 }
local BIRD_EYE  = { 26, 24, 20 }

-- ---------------------------------------------------------------- helpers --

-- os.time() alone is a poor seed here: a handheld that has just been reset can
-- report the same value every launch, which would deal the same course every
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

-- The one verb the game has. From anywhere that isn't play, it starts play --
-- pressing the flap key on the title screen should launch the bird, not make
-- the player hunt for a separate start key.
local function flapOrStart()
  if game.state == "playing" then
    game:flap()
  else
    confirm()
    game:flap()
  end
end

-- --------------------------------------------------------------- lifecycle --

-- Called before the first paint, and again if the window is resized (which on
-- a handheld means never, but the computer software can resize freely).
function on.resize(w, h)
  ui.w, ui.h = w, h
  ui.ox, ui.oy = 0, HUD_H
  ui.fw = math.max(80, w)
  ui.fh = math.max(48, h - HUD_H)

  -- Only rebuild when the playfield actually changed; a cosmetic resize
  -- shouldn't throw away a round in progress.
  if game.w ~= ui.fw or game.h ~= ui.fh then
    game = Flappy.new(ui.fw, ui.fh, { highScore = game.highScore })
  end
  platform.window:invalidate()
end

timer.start(BASE_TICK)

function on.timer()
  blink = blink + 1

  if game.state == "playing" then
    game:step()
    platform.window:invalidate()
  else
    entropy = entropy + 1
    if blink % 8 == 0 then platform.window:invalidate() end
  end
end

function on.deactivate()
  game:pause()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

function on.arrowKey(key)
  if key == "up" then
    flapOrStart()
  elseif key == "down" then
    -- Nothing to steer downward into; treat it as a pause reflex instead of a
    -- dead key, since "down" is where a panicking thumb goes.
    togglePause()
  end
  platform.window:invalidate()
end

function on.enterKey()
  flapOrStart()
  platform.window:invalidate()
end

function on.escapeKey()
  togglePause()
  platform.window:invalidate()
end

function on.charIn(ch)
  ch = string.lower(ch or "")

  if ch == " " or ch == "w" or ch == "8" or ch == "f" then
    flapOrStart()
  elseif ch == "p" then
    togglePause()
  elseif ch == "r" then
    newRound()
    game:start()
  end

  platform.window:invalidate()
end

function on.mouseDown(x, y)
  flapOrStart()
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function rgb(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

-- Stars are placed by a fixed hash of their index rather than math.random, so
-- they stay put frame to frame without the game having to store them, and
-- reseeding for a new round doesn't make the sky twitch.
local function drawSky(gc)
  local ox, oy, fw, fh = ui.ox, ui.oy, ui.fw, ui.fh
  rgb(gc, SKY)
  gc:fillRect(ox, oy, fw, fh)

  -- Sky lightens toward the horizon. Five steps read as depth from a metre
  -- away, which is the only distance that matters; a true gradient would be
  -- one fillRect per scanline and the handheld would feel every one of them.
  local BANDS = 5
  local top = math.floor(fh * 0.55)
  for i = 1, BANDS do
    local y0 = oy + top + math.floor((fh - top) * (i - 1) / BANDS)
    local y1 = oy + top + math.floor((fh - top) * i / BANDS)
    local t = i / BANDS
    gc:setColorRGB(
      math.floor(SKY[1] + (SKY_HI[1] - SKY[1]) * t),
      math.floor(SKY[2] + (SKY_HI[2] - SKY[2]) * t),
      math.floor(SKY[3] + (SKY_HI[3] - SKY[3]) * t))
    gc:fillRect(ox, y0, fw, math.max(0, y1 - y0))
  end

  rgb(gc, STAR)
  for i = 1, 26 do
    local sx = (i * 7919) % fw
    local sy = (i * 104729) % math.max(1, math.floor(fh * 0.55))
    gc:fillRect(ox + sx, oy + sy, 1, 1)
  end
end

local function drawGround(gc)
  local ox, oy, fw = ui.ox, ui.oy, ui.fw
  local gy = oy + math.floor(game:groundY())
  rgb(gc, GROUND)
  gc:fillRect(ox, gy, fw, ui.h - gy)
  rgb(gc, GRASS)
  gc:fillRect(ox, gy, fw, 2)
end

local function drawPipes(gc)
  local ox, oy = ui.ox, ui.oy

  for _, p in ipairs(game.pipes) do
    local top, bottom = game:pipeRects(p)

    -- Coordinates are floored here, at the draw boundary, and nowhere else:
    -- the physics in src/flappy.lua stays in floats so nothing drifts.
    for _, r in ipairs({ top, bottom }) do
      local x = ox + math.floor(r.x)
      local y = oy + math.floor(r.y)
      local h = math.floor(r.h)
      if h > 0 then
        rgb(gc, PIPE)
        gc:fillRect(x, y, r.w, h)
        rgb(gc, PIPE_EDGE)
        gc:drawRect(x, y, r.w - 1, h - 1)
      end
    end

    -- Lips at the mouth of the gap. Drawn wider than the column and in their
    -- own colour, which is also what keeps the two PIPE-coloured rects above
    -- the only thing tools/screenshot_flappy.lua has to recognise as a pipe.
    local x = ox + math.floor(p.x)
    local gt = oy + math.floor(p.gapTop)
    local gb = oy + math.floor(p.gapTop + p.gap)
    rgb(gc, PIPE_LIP)
    if math.floor(top.h) > 0 then gc:fillRect(x - 2, gt - 5, Flappy.PIPE_W + 4, 5) end
    if math.floor(bottom.h) > 0 then gc:fillRect(x - 2, gb, Flappy.PIPE_W + 4, 5) end
  end
end

local function drawBird(gc)
  local bx, by, bw, bh = game:birdRect()
  local x = ui.ox + math.floor(bx)
  local y = ui.oy + math.floor(by)

  -- On the title screen the bird hovers, so the screen isn't a still frame.
  if game.state == "ready" then
    y = y + math.floor(math.sin(blink / 5) * 2)
  end

  rgb(gc, BIRD)
  gc:fillRect(x, y, bw, bh)

  -- The wing rides high just after a flap and settles as the bird falls, which
  -- reads as effort without needing a sprite or a rotation the API can't do.
  local since = game.frame - game.lastFlapFrame
  local wy = (since < 3) and (y + 1) or (y + 4)
  rgb(gc, BIRD_WING)
  gc:fillRect(x + 2, wy, 5, 3)

  rgb(gc, BIRD_BEAK)
  gc:fillRect(x + bw, y + 3, 3, 3)

  rgb(gc, BIRD_EYE)
  gc:fillRect(x + bw - 4, y + 2, 2, 2)
end

local function drawHud(gc)
  rgb(gc, { 30, 34, 44 })
  gc:fillRect(0, 0, ui.w, HUD_H)
  gc:setColorRGB(58, 64, 80)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  gc:setFont("sansserif", "b", 10)
  local labelW = gc:getStringWidth("FLAPPY")

  gc:setFont("sansserif", "r", 10)
  local stats = "Score " .. game.score
    .. "   Gap " .. math.floor(game:gapSize())
    .. "   Best " .. game.highScore
  local statsW = gc:getStringWidth(stats)
  local statsX = ui.w - statsW - 6

  -- Big scores, or a narrower font than we assumed, can push the stats into
  -- the title. The stats matter more, so the title yields.
  if statsX > labelW + 12 then
    gc:setFont("sansserif", "b", 10)
    gc:setColorRGB(252, 210, 74)
    gc:drawString("FLAPPY", 6, 4, "top")
    gc:setFont("sansserif", "r", 10)
  end

  gc:setColorRGB(215, 220, 232)
  gc:drawString(stats, math.max(4, statsX), 4, "top")
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
    drawPanel(gc, "FLAPPY", {
      { "enter, space, up or click to flap" },
      { "esc or P pause     R restart" },
      { "Thread the pipes. One tap per gap." },
      { "Press enter to fly", true },
    }, { 252, 210, 74 })
  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { "Score " .. game.score },
      { "Press enter to resume", true },
    }, { 240, 190, 70 })
  elseif s == "over" then
    drawPanel(gc, "GAME OVER", {
      { "Score " .. game.score .. "     Best " .. game.highScore },
      { game.score >= game.highScore and game.score > 0
          and "New best!" or ("Pipes cleared " .. game.score) },
      { "Press enter to play again", true },
    }, { 228, 72, 62 })
  end
end

function on.paint(gc)
  drawSky(gc)
  drawPipes(gc)
  drawGround(gc)
  drawBird(gc)
  drawHud(gc)
  drawOverlay(gc)
end
