-- arkanoid/main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules live in src/arkanoid/game.lua. `platform.apilevel` is emitted as the
-- first line of the bundle by tools/bundle.py, so it is intentionally absent.
--
-- When bundled, `Arkanoid` is already a local from the inlined module; the
-- `Arkanoid or require` form below also lets this file load under desktop Lua.
local Arkanoid = Arkanoid or require("game")

local HUD_H     = 20    -- height of the score bar, pixels
local BASE_TICK = 0.05  -- host timer period -- one physics step per tick
local CLEAR_HOLD = 44   -- ticks the "level cleared" banner sits before moving on

local ui = { w = 318, h = 212, ox = 0, oy = HUD_H, fw = 318, fh = 212 - HUD_H }

local blink   = 0     -- drives the blinking prompt on overlay screens
local entropy = 1     -- folded from every tick, key and click; seeds the RNG
local clearTicks = 0

-- The board behind the title screen is dealt from a fixed seed, and a real one
-- is dealt only when play starts. Fruits shipped the opposite way round and
-- dealt the identical board at every launch, because at load time the only
-- entropy that has ever been collected is whatever the seed started at.
local game = Arkanoid.new(ui.fw, ui.fh, { rand = Arkanoid.newRandom(1) })

-- ---------------------------------------------------------------- palette --
--
-- Several of these are a contract with tests/arkanoid/frame.lua, which reads
-- the board back out of the paint calls rather than out of the game, so that
-- no test-only hook has to reach the shipped script. Anything it identifies by
-- colour has to keep that colour to itself -- and to stay distinct once the
-- handheld's five-bits-a-channel panel has had it, which is coarser than it
-- looks: {230,74,68} and {228,72,64} are the same colour on a calculator.

local PAGE      = {  10,  12,  18 }   -- behind everything
local FIELD     = {  16,  19,  30 }   -- the playfield, painted once, full bleed
local WALL_C    = {  96, 104, 128 }
local WALL_HI   = { 148, 158, 184 }
local HUD_BG    = {  26,  30,  42 }
local PANEL     = {  20,  24,  44 }   -- behind the overlay boxes
local HUD_LINE  = {  58,  64,  84 }
local INK       = { 214, 220, 234 }
local INK_DIM   = {  96, 104, 124 }

local BALL_C    = { 248, 248, 240 }
local BALL_HI   = { 255, 255, 255 }
local PADDLE_C  = {  70, 150, 250 }
local PADDLE_HI = { 190, 225, 255 }
local PADDLE_CAP= { 236,  96,  72 }
local LASER_C   = { 255, 236, 120 }

-- The eight brick inks, in the order src/arkanoid/game.lua scores them.
local BRICK = {
  { 236, 240, 246 },  -- 1 white     50
  { 242, 150,  52 },  -- 2 orange    60
  {  88, 206, 236 },  -- 3 cyan      70
  {  96, 206, 110 },  -- 4 green     80
  { 230,  74,  68 },  -- 5 red       90
  {  84, 124, 236 },  -- 6 blue     100
  { 216,  96, 208 },  -- 7 magenta  110
  { 244, 214,  68 },  -- 8 yellow   120
}
local SILVER      = { 176, 182, 196 }
local SILVER_HURT = { 118, 124, 140 }
local GOLD        = { 226, 182,  58 }

-- Ink indices 1..8 are the colours above; 9 silver, 10 silver already hit,
-- 11 gold. The sprite table below is keyed the same way.
local INK_COUNT = 11
local function inkColor(i)
  if i <= 8 then return BRICK[i] end
  if i == 9 then return SILVER end
  if i == 10 then return SILVER_HURT end
  return GOLD
end

local CAPSULE = {
  wide  = { letter = "E", color = { 232,  84,  76 } },
  catch = { letter = "C", color = {  84, 204, 124 } },
  laser = { letter = "L", color = { 240, 154,  60 } },
  slow  = { letter = "S", color = {  92, 148, 244 } },
  split = { letter = "D", color = { 108, 220, 232 } },
  life  = { letter = "P", color = { 218, 122, 220 } },
}

local function rgb(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

local function shade(c, f)
  local function ch(v)
    v = math.floor(v * f)
    if v < 0 then v = 0 elseif v > 255 then v = 255 end
    return v
  end
  return { ch(c[1]), ch(c[2]), ch(c[3]) }
end

-- ------------------------------------------------------------ brick sprites --
--
-- A wall is up to 13 x 8 bricks and the screen is repainted twenty times a
-- second, so how a brick is drawn is the one drawing decision in this game
-- that matters. Measured, on this container, painting level 1 (52 bricks) at
-- the handheld's own 318x212, whole frame including chrome and text:
--
--   as rectangles   137 draw calls, 29 colour changes  (2 rects a brick)
--   as TI.Images     85 draw calls, 24 colour changes  (1 blit a brick)
--
-- and on the fullest wall the game paints, 104 bricks, that is 241 against
-- 137. A brick is one call instead of two, and it needs no colour change at
-- all, which is the half that actually costs. Same trade chess made for its
-- pieces and klondike refused for its cards; here it lands clearly in favour,
-- because a brick repaints on a TIMER and not on a keypress.
--
-- What is different from both is that a brick is not art. It is a bevelled
-- rectangle in one of eleven inks, so there is nothing to import and no
-- tools/*art.py to write: the sprites are built here, at load, straight from
-- the palette above. That also keeps them out of the bundle -- chess pays 25 KB
-- of escaped source for its twelve pieces, and these cost about forty lines.
-- And because they are generated from the current geometry, a window the
-- computer software has resized just rebuilds them at the new brick size
-- instead of dropping to the fallback.
--
-- The fallback is still here and still complete. One calculator on one OS is
-- what has been checked, so `image.new` is called inside a pcall and the rects
-- take over if anything at all goes wrong -- all of the bricks or none of
-- them, because half a wall in each encoding reads as a bug.

local sprites = nil     -- [1..11] TI.Image, or nil if the rect path is in use
local spriteW, spriteH = 0, 0

local function u16(v)
  v = math.floor(v) % 65536
  return string.char(v % 256, math.floor(v / 256))
end

local function u32(v)
  v = math.floor(v) % 4294967296
  return u16(v % 65536) .. u16(math.floor(v / 65536))
end

-- One pixel: A RRRRR GGGGG BBBBB, little endian, alpha in the TOP bit. Note
-- 555 and not 565 -- see the TI.Image note in CLAUDE.md; the OS rejects a bad
-- header outright and paints nothing at all for a bad layout.
local function pixel(c)
  return u16(32768
    + math.floor(c[1] / 8) * 1024
    + math.floor(c[2] / 8) * 32
    + math.floor(c[3] / 8))
end

-- 20 bytes: w, h, alignment, flags, padding, stride, bits-per-pixel, planes.
local function imageHeader(w, h)
  return u32(w) .. u32(h) .. string.char(0, 0) .. u16(0) .. u32(w * 2) .. u16(16) .. u16(1)
end

-- A bevelled brick: lit along the top and left, shadowed along the bottom and
-- right. Rows repeat, so this is a handful of string.rep calls rather than a
-- loop over every pixel -- which is what makes rebuilding all eleven on a
-- resize cost nothing worth measuring.
local function brickImageData(w, h, body)
  local hi, lo = pixel(shade(body, 1.35)), pixel(shade(body, 0.55))
  local mid = pixel(body)
  local rowTop = string.rep(hi, w)
  local rowMid = hi .. string.rep(mid, math.max(0, w - 2)) .. (w > 1 and lo or "")
  local rowBot = hi .. string.rep(lo, math.max(0, w - 1))

  local rows = { imageHeader(w, h), rowTop }
  for _ = 2, h - 1 do rows[#rows + 1] = rowMid end
  if h > 1 then rows[#rows + 1] = rowBot end
  return table.concat(rows)
end

local function buildSprites()
  sprites, spriteW, spriteH = nil, 0, 0
  local w, h = math.floor(game.brickW), math.floor(game.brickH)
  if not image or not image.new then return end
  if w < 3 or h < 3 then return end     -- below this a bevel is not a picture

  local built = {}
  for i = 1, INK_COUNT do
    local made, img = pcall(image.new, brickImageData(w, h, inkColor(i)))
    if not made or not img then return end   -- all of them, or none
    built[i] = img
  end
  sprites, spriteW, spriteH = built, w, h
end

-- --------------------------------------------------------------- helpers --

local function newRound()
  -- Seeded from entropy folded out of every tick and keypress since the
  -- document opened, because math.randomseed does nothing on the handheld and
  -- math.random alone would deal the same capsules on every launch.
  game.rand = Arkanoid.newRandom(entropy)
  game:reset(1)
  game.state = "serve"
  clearTicks = 0
end

local function confirm()
  local s = game.state
  if s == "ready" or s == "over" then
    newRound()
  elseif s == "paused" then
    game:resume()
  elseif s == "cleared" then
    game:nextLevel()
    clearTicks = 0
  else
    game:fire()
  end
end

local function togglePause()
  if game.state == "paused" then game:resume() else game:pause() end
end

-- --------------------------------------------------------------- lifecycle --

-- Called before the first paint, and again if the window is resized (which on
-- a handheld means never, but the computer software can resize freely).
function on.resize(w, h)
  ui.w, ui.h = w, h
  ui.ox, ui.oy = 0, HUD_H
  ui.fw = math.max(60, w)
  ui.fh = math.max(60, h - HUD_H)

  -- Only rebuild when the playfield actually changed; a cosmetic resize
  -- shouldn't throw away a round in progress.
  if game.w ~= ui.fw or game.h ~= ui.fh then
    local keep = { rand = game.rand, highScore = game.highScore, level = game.level }
    game = Arkanoid.new(ui.fw, ui.fh, keep)
  end
  buildSprites()
  platform.window:invalidate()
end

timer.start(BASE_TICK)

function on.timer()
  blink = blink + 1
  entropy = Arkanoid.mix(entropy, blink)

  local s = game.state
  if s == "playing" or s == "serve" then
    game:step()
    platform.window:invalidate()
  elseif s == "cleared" then
    clearTicks = clearTicks + 1
    if clearTicks >= CLEAR_HOLD then
      game:nextLevel()
      clearTicks = 0
    end
    platform.window:invalidate()
  elseif blink % 8 == 0 then
    platform.window:invalidate()
  end
end

-- Losing focus mid-rally would otherwise mean coming back to a dead ball.
function on.deactivate()
  game:pause()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

-- Every arrow press opens the paddle's drive window rather than nudging it a
-- fixed distance -- see the note on PADDLE_DRIVE in game.lua. A tap coasts, a
-- held key rides the OS's auto-repeat into smooth travel, and neither this
-- file nor game.lua has to know which the player is doing.
function on.arrowKey(key)
  entropy = Arkanoid.mix(entropy, blink)
  if key == "left" then
    game:steer(-1)
  elseif key == "right" then
    game:steer(1)
  elseif key == "up" then
    confirm()
  elseif key == "down" then
    togglePause()
  end
  platform.window:invalidate()
end

function on.enterKey()
  entropy = Arkanoid.mix(entropy, blink + 7)
  confirm()
  platform.window:invalidate()
end

function on.escapeKey()
  togglePause()
  platform.window:invalidate()
end

function on.charIn(ch)
  ch = string.lower(ch or "")
  entropy = Arkanoid.mix(entropy, string.byte(ch) or 0)

  if ch == "4" or ch == "a" or ch == "," then
    game:steer(-1)
  elseif ch == "6" or ch == "d" or ch == "." then
    game:steer(1)
  elseif ch == " " or ch == "w" or ch == "8" or ch == "f" then
    confirm()
  elseif ch == "p" then
    togglePause()
  elseif ch == "r" then
    newRound()
  end

  platform.window:invalidate()
end

-- A click is absolute aim: the paddle sets off toward that column rather than
-- appearing there, so the touchpad cannot rescue a ball the paddle could never
-- have reached. Clicking is also how you serve, so one input plays the game.
function on.mouseDown(x, y)
  entropy = Arkanoid.mix(entropy, (x or 0) * 31 + (y or 0))
  local s = game.state
  if s == "playing" or s == "serve" then
    game:aim((x or 0) - ui.ox)
    if s == "serve" then game:fire() end
  else
    confirm()
  end
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function drawField(gc)
  local ox, oy, fw, fh = ui.ox, ui.oy, ui.fw, ui.fh
  rgb(gc, FIELD)
  gc:fillRect(ox, oy, fw, fh)

  -- Walls: three bars with a lit inner edge, which is all the depth a
  -- 318-pixel screen has room for.
  local t = game.wall
  rgb(gc, WALL_C)
  gc:fillRect(ox, oy, t, fh)
  gc:fillRect(ox + fw - t, oy, t, fh)
  gc:fillRect(ox, oy, fw, t)
  rgb(gc, WALL_HI)
  gc:fillRect(ox + t - 1, oy, 1, fh)
  gc:fillRect(ox + fw - t, oy, 1, fh)
  gc:fillRect(ox, oy + t - 1, fw, 1)
end

local function inkOf(b, fullSilver)
  if b.kind == "gold" then return 11 end
  if b.kind == "silver" then return (b.hp >= fullSilver) and 9 or 10 end
  return b.color
end

local function drawBricks(gc)
  local ox, oy = ui.ox, ui.oy
  local bw, bh = game.brickW, game.brickH
  local fullSilver = Arkanoid.silverHP(game.level)
  local blit = sprites and spriteW == math.floor(bw) and spriteH == math.floor(bh)

  if blit then
    for r = 1, game.rows do
      local row = game.bricks[r]
      local y = oy + math.floor(game:brickY(r))
      for c = 1, Arkanoid.COLS do
        local b = row[c]
        if b then
          gc:drawImage(sprites[inkOf(b, fullSilver)], ox + math.floor(game:brickX(c)), y)
        end
      end
    end
    return
  end

  -- Fallback. Bodies first, walking the grid in row order and changing the
  -- ink only when it actually changes -- a level's rows are usually one
  -- colour, so this is a colour change a row rather than one a brick, and the
  -- colour change is the expensive part. The bevel then goes on in a single
  -- pass afterwards, in one shared highlight, for the same reason.
  local last = nil
  for r = 1, game.rows do
    local row = game.bricks[r]
    local y = oy + math.floor(game:brickY(r))
    for c = 1, Arkanoid.COLS do
      local b = row[c]
      if b then
        local ink = inkOf(b, fullSilver)
        if ink ~= last then rgb(gc, inkColor(ink)); last = ink end
        gc:fillRect(ox + math.floor(game:brickX(c)), y, math.floor(bw), math.floor(bh))
      end
    end
  end

  if bh >= 3 then
    gc:setColorRGB(255, 255, 255)
    for r = 1, game.rows do
      local row = game.bricks[r]
      local y = oy + math.floor(game:brickY(r))
      for c = 1, Arkanoid.COLS do
        if row[c] then
          gc:fillRect(ox + math.floor(game:brickX(c)), y, math.floor(bw) - 1, 1)
        end
      end
    end
  end
end

local function drawPaddle(gc)
  local px, py, pw, ph = game:paddleRect()
  local x, y = ui.ox + math.floor(px), ui.oy + math.floor(py)
  pw, ph = math.floor(pw), math.floor(ph)

  rgb(gc, PADDLE_C)
  gc:fillRect(x, y, pw, ph)

  -- The red rims are the Vaus's silhouette, and they are also what tells the
  -- player where "full angle" is: hit the ball on the red and it leaves at
  -- sixty degrees.
  local cap = math.max(2, math.floor(pw / 8))
  rgb(gc, PADDLE_CAP)
  gc:fillRect(x, y, cap, ph)
  gc:fillRect(x + pw - cap, y, cap, ph)

  rgb(gc, PADDLE_HI)
  gc:fillRect(x + cap, y, math.max(0, pw - cap * 2), 1)

  -- The laser barrels, so the capsule you are carrying is visible on the ship
  -- rather than only in the HUD.
  if game.power == "laser" and ph >= 3 then
    rgb(gc, LASER_C)
    gc:fillRect(x + cap, y - 2, 2, 2)
    gc:fillRect(x + pw - cap - 2, y - 2, 2, 2)
  end
end

local function drawBalls(gc)
  local s = math.floor(game.ballSize)
  for _, b in ipairs(game.balls) do
    local x, y = ui.ox + math.floor(b.x), ui.oy + math.floor(b.y)
    rgb(gc, BALL_C)
    gc:fillRect(x, y, s, s)
    if s >= 3 then
      rgb(gc, BALL_HI)
      gc:fillRect(x, y, 1, 1)
    end
  end
end

local function drawBullets(gc)
  if #game.bullets == 0 then return end
  rgb(gc, LASER_C)
  for _, s in ipairs(game.bullets) do
    gc:fillRect(ui.ox + math.floor(s.x), ui.oy + math.floor(s.y),
                Arkanoid.BULLET_W, Arkanoid.BULLET_H)
  end
end

local function drawCapsules(gc)
  local w, h = Arkanoid.CAPSULE_W, Arkanoid.CAPSULE_H
  for _, cap in ipairs(game.capsules) do
    local spec = CAPSULE[cap.kind]
    local x, y = ui.ox + math.floor(cap.x), ui.oy + math.floor(cap.y)
    rgb(gc, spec.color)
    gc:fillRect(x, y, w, h)
    rgb(gc, shade(spec.color, 0.45))
    gc:drawRect(x, y, w - 1, h - 1)

    gc:setFont("sansserif", "b", 7)
    local tw = gc:getStringWidth(spec.letter)
    local th = gc:getStringHeight(spec.letter)
    gc:setColorRGB(16, 16, 20)
    -- Centred from the measured glyph, never from a row height written down as
    -- a number: the handheld's font is not the one this was laid out against.
    gc:drawString(spec.letter,
      x + math.floor((w - tw) / 2),
      y + math.max(0, math.floor((h - th) / 2)), "top")
  end
end

-- --------------------------------------------------------------------- HUD --

local function drawLives(gc, x, y)
  -- The spare Vaus, drawn as what they are. Bounded, or a stack of extra lives
  -- would walk across the score.
  local n = math.min(game.lives - 1, 5)
  for i = 1, n do
    rgb(gc, PADDLE_C)
    gc:fillRect(x + (i - 1) * 12, y, 8, 4)
    rgb(gc, PADDLE_CAP)
    gc:fillRect(x + (i - 1) * 12, y, 2, 4)
    gc:fillRect(x + (i - 1) * 12 + 6, y, 2, 4)
  end
  return n * 12
end

local function drawHud(gc)
  rgb(gc, HUD_BG)
  gc:fillRect(0, 0, ui.w, HUD_H)
  rgb(gc, HUD_LINE)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  gc:setFont("sansserif", "b", 10)
  local titleW = gc:getStringWidth("ARKANOID")

  gc:setFont("sansserif", "r", 10)
  local stats = string.format("%d   L%d   Best %d", game.score, game.level, game.highScore)
  local statsW = gc:getStringWidth(stats)
  local textY = math.max(1, math.floor((HUD_H - gc:getStringHeight(stats)) / 2))

  -- Lives sit on the right, the score to their left with a gap the score
  -- cannot eat into, and the title yields first if the numbers or the font
  -- turn out bigger than assumed.
  local livesW = math.min(math.max(game.lives - 1, 0), 5) * 12
  local statsX = ui.w - 6 - livesW - 8 - statsW
  if statsX > titleW + 12 then
    gc:setFont("sansserif", "b", 10)
    rgb(gc, BRICK[8])
    gc:drawString("ARKANOID", 6, textY, "top")
    gc:setFont("sansserif", "r", 10)
  end

  rgb(gc, INK)
  gc:drawString(stats, math.max(4, statsX), textY, "top")
  drawLives(gc, ui.w - 6 - livesW, math.floor((HUD_H - 4) / 2))
end

-- ----------------------------------------------------------------- overlays --

-- lines: array of { text, dim } -- dim entries blink.
local function drawPanel(gc, title, lines, accent)
  gc:setFont("sansserif", "b", 16)
  local titleW, titleH = gc:getStringWidth(title), gc:getStringHeight(title)

  gc:setFont("sansserif", "r", 10)
  -- Row height comes from the font in hand and never from a constant: Fruits
  -- shipped a panel whose rows were tuned against the preview's DejaVu and
  -- whose rule ran straight through its own heading on the calculator.
  local lineH = gc:getStringHeight("Ag") + 3
  local maxW = titleW
  for _, l in ipairs(lines) do
    local lw = gc:getStringWidth(l[1])
    if lw > maxW then maxW = lw end
  end

  local pad = 10
  local bw = math.min(maxW + pad * 2, ui.w - 4)
  local bh = math.min(titleH + 6 + #lines * lineH + pad * 2, ui.h - 4)
  local bx = math.max(2, math.floor((ui.w - bw) / 2))
  local by = math.max(2, math.floor((ui.h - bh) / 2))

  rgb(gc, PANEL)
  gc:fillRect(bx, by, bw, bh)
  rgb(gc, accent)
  gc:drawRect(bx, by, bw, bh)
  gc:drawRect(bx + 2, by + 2, math.max(0, bw - 4), math.max(0, bh - 4))

  gc:setFont("sansserif", "b", 16)
  gc:drawString(title, bx + math.floor((bw - titleW) / 2), by + pad, "top")

  gc:setFont("sansserif", "r", 10)
  local y = by + pad + titleH + 6
  local lit = (blink % 16) < 10
  for _, l in ipairs(lines) do
    if l[2] then
      rgb(gc, lit and INK or INK_DIM)
    else
      rgb(gc, INK_DIM)
    end
    gc:drawString(l[1], bx + math.floor((bw - gc:getStringWidth(l[1])) / 2), y, "top")
    y = y + lineH
  end
end

local POWER_TEXT = {
  wide  = "Enlarge",
  catch = "Catch -- press enter to fire",
  laser = "Laser -- press enter to fire",
}

local function drawOverlay(gc)
  local s = game.state
  if s == "ready" then
    drawPanel(gc, "ARKANOID", {
      { "left / right steer, or click a column" },
      { "enter serves, fires the laser and" },
      { "lets a caught ball go" },
      { "esc or P pause      R restart" },
      { "Press enter to play", true },
    }, { 244, 214, 68 })
  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { "Score " .. game.score .. "     Level " .. game.level },
      { "Press enter to resume", true },
    }, { 240, 190, 70 })
  elseif s == "cleared" then
    drawPanel(gc, "LEVEL " .. game.level .. " CLEAR", {
      { "Bonus " .. (500 * game.level) },
      { "Score " .. game.score },
      { "Next level...", true },
    }, { 96, 206, 110 })
  elseif s == "over" then
    drawPanel(gc, "GAME OVER", {
      { "Score " .. game.score .. "     Best " .. game.highScore },
      { game.score >= game.highScore and game.score > 0
          and "New best!" or ("Reached level " .. game.level) },
      { "Press enter to play again", true },
    }, { 228, 72, 62 })
  elseif s == "serve" then
    -- Not a panel: the ball is sitting on the paddle and the player needs the
    -- board, not a box over it. One line, low, out of the way of the wall.
    gc:setFont("sansserif", "r", 10)
    local msg = "Press enter to serve"
    rgb(gc, (blink % 16) < 10 and INK or INK_DIM)
    gc:drawString(msg,
      math.floor((ui.w - gc:getStringWidth(msg)) / 2),
      ui.oy + math.floor(game.padY) - gc:getStringHeight(msg) - 6, "top")
  elseif game.power and POWER_TEXT[game.power] then
    -- What the ship is carrying, in that capsule's own colour, on the strip
    -- below the paddle -- the one part of the screen nothing else uses. Placed
    -- from the measured glyph height so a taller font rides up rather than off.
    gc:setFont("sansserif", "r", 7)
    local msg = POWER_TEXT[game.power]
    local h = gc:getStringHeight(msg)
    rgb(gc, CAPSULE[game.power].color)
    gc:drawString(msg, ui.ox + game.wall + 3,
      math.min(ui.h - h - 2, ui.oy + math.floor(game.padY + game.padH) + 3), "top")
  end
end

function on.paint(gc)
  rgb(gc, PAGE)
  gc:fillRect(0, 0, ui.w, ui.h)

  drawField(gc)
  drawBricks(gc)
  drawCapsules(gc)
  drawBullets(gc)
  drawPaddle(gc)
  drawBalls(gc)
  drawHud(gc)
  drawOverlay(gc)
end

buildSprites()
