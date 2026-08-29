-- main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules and the dictionary live in src/wordle/game.lua. `platform.apilevel` is
-- emitted as the first line of the bundle by tools/bundle.py, so it is
-- intentionally absent here.
--
-- When bundled, `Wordle` is already a local from the inlined module; the
-- `Wordle or require` form below also lets this file load under a desktop Lua.
local Wordle = Wordle or require("game")

-- ------------------------------------------------------------------ tuning --
-- Wordle is turn-based, so there is no game loop: a repaint is caused by a
-- keypress, not by the clock. The timer runs anyway, for three things that
-- happen without input -- the reveal, the message timeout, and the candidate
-- filter's slices -- and it asks for a repaint only when one of them moved.
local BASE_TICK    = 0.05  -- host timer period, the practical floor on hardware
local REVEAL_TICKS = 2     -- ticks between one tile colouring and the next
local MESSAGE_TICKS = 40   -- how long "Not in word list" stays up, in ticks
-- ---------------------------------------------------------------------------

local LEN, ROWS = Wordle.LEN, Wordle.ROWS
local UNKNOWN, GREY, YELLOW, GREEN =
  Wordle.UNKNOWN, Wordle.GREY, Wordle.YELLOW, Wordle.GREEN

-- Colours. These exact values are a contract with tests/wordle/frame.lua,
-- which recovers the board and the keyboard from the paint calls rather than
-- from the game's own state -- change one here and it has to change there too.
local PAGE_BG   = {  18,  21,  27 }
local PANEL_BG  = {  26,  30,  39 }
local BOARD_BG  = {  40,  45,  58 }  -- backing behind the grid, and the thing
                                     -- tests/wordle/frame.lua uses to tell a
                                     -- green tile from a green key
local TILE_BG   = {  30,  34,  44 }
local TILE_EDGE = {  58,  64,  80 }
local TILE_LIVE = { 106, 114, 138 }  -- outline of a square holding a letter
local MARK_FILL = {
  [GREY]   = {  72,  76,  86 },
  [YELLOW] = { 181, 159,  59 },
  [GREEN]  = {  83, 141,  78 },
}
local KEY_FILL  = { 108, 114, 132 }  -- a letter not yet tried
local KEY_TEXT  = { 248, 248, 248 }
local KEY_DIM   = { 150, 155, 168 }  -- text on an exhausted (grey) key
local INK       = { 235, 238, 245 }
local INK_SOFT  = { 158, 165, 182 }
local GOOD      = { 120, 190, 110 }
local BAD       = { 228,  98,  88 }
local ACCENT    = { 214, 178,  60 }

-- Largest first: fitFont walks down until the label measures small enough.
-- Sizes outside this set are rejected by the runtime, so there is no arithmetic
-- to do -- only a list to walk.
local FONT_STEPS = { 24, 16, 12, 11, 10, 9, 7 }

local KB_ROWS = { "qwertyuiop", "asdfghjkl", "zxcvbnm" }

local A = string.byte("a")

local ui = { w = 318, h = 212, keys = {} }
local game = Wordle.new()

local reveal   = nil  -- { row = n, t = ticks } while a row is colouring in
local shownKb  = nil  -- keyboard state as the player is allowed to see it
local message  = nil  -- { text, tone, t } transient line under the title
-- Entropy for the answer draw, folded in from every tick, key and click for
-- as long as the document is open. It is never reset: a second round is seeded
-- by everything the first one did.
local entropy  = 1

-- ---------------------------------------------------------------- helpers --

local function col(gc, c)
  gc:setColorRGB(c[1], c[2], c[3])
end

local function copyLetters()
  local out = {}
  for i = 1, 26 do out[i] = game.letters[i] end
  return out
end

-- Builds the generator the next round draws its answer from.
--
-- Note what is NOT here: math.randomseed. On the handheld it returns happily
-- and changes nothing, so math.random replays one sequence from launch to
-- launch and the game deals the same word every time the document is opened.
-- That is the bug this function exists to avoid, so the entropy above is the
-- source and Wordle.newRandom is the generator.
--
-- os.time() and math.random are still folded in where they work, and cost
-- nothing where they do not -- on a handheld that has just been reset
-- os.time() is a constant, and a constant simply contributes nothing.
local function newRand()
  local seed = entropy
  if os and os.time then seed = Wordle.mix(seed, os.time() or 0) end
  if os and os.clock then seed = Wordle.mix(seed, (os.clock() or 0) * 1000) end
  local okay, r = pcall(math.random, 1000000)
  if okay then seed = Wordle.mix(seed, r) end
  return Wordle.newRandom(seed)
end

local function say(text, tone)
  message = { text = text, tone = tone or INK_SOFT, t = MESSAGE_TICKS }
end

local function newRound()
  local hard = game.hard
  game = Wordle.new({ hard = hard, rand = newRand() })
  game:start()
  reveal, message = nil, nil
  shownKb = copyLetters()
end

-- The largest font in FONT_STEPS whose rendering of `text` fits the box, or
-- nil if even the smallest does not. Every label on screen goes through this:
-- the Nspire's font metrics are not knowable ahead of time, so a box is sized
-- by asking the device, never by counting characters.
local function fitFont(gc, text, maxW, maxH, style)
  for _, size in ipairs(FONT_STEPS) do
    gc:setFont("sansserif", style or "b", size)
    if gc:getStringWidth(text) <= maxW and gc:getStringHeight(text) <= maxH then
      return size
    end
  end
  return nil
end

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local letterFont_cache = {}

-- One font size for every letter drawn in a box of this size, chosen so that
-- the *widest* letter in the alphabet fits -- not the letter in hand.
--
-- Sizing each letter independently is the obvious thing and looks broken: I
-- and O are narrow, so they win a larger size than W beside them, and a row of
-- keys ends up visibly ragged. Measured once per box size and cached, because
-- this is 26 measurements and on.paint runs it for 30 tiles and 26 keys.
local function letterFont(gc, w, h)
  local k = w .. "," .. h
  local hit = letterFont_cache[k]
  if hit ~= nil then return hit or nil end

  local chosen = false
  for _, size in ipairs(FONT_STEPS) do
    gc:setFont("sansserif", "b", size)
    local widest = 0
    for i = 1, 26 do
      local cw = gc:getStringWidth(ALPHABET:sub(i, i))
      if cw > widest then widest = cw end
    end
    if widest <= w and gc:getStringHeight("W") <= h then
      chosen = size
      break
    end
  end

  letterFont_cache[k] = chosen or false
  return chosen or nil
end

-- A single letter, centred, or nothing at all if the box is too small to hold
-- one -- a cramped window loses its labels rather than spilling them.
local function drawLetter(gc, ch, x, y, w, h)
  if w <= 0 or h <= 0 then return end
  local size = letterFont(gc, w, h)
  if not size then return end
  gc:setFont("sansserif", "b", size)
  local tw, th = gc:getStringWidth(ch), gc:getStringHeight(ch)
  gc:drawString(ch, x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2), "top")
end

-- Draws `text` centred in the box, at the largest size that fits, and does
-- nothing at all if it cannot be made to fit -- a cramped window loses its
-- labels rather than spilling them over their tiles.
--
-- Anchored "top" and centred by hand from getStringHeight: the preview
-- renderer in tools/render.py anchors at the top left, so "middle" would look
-- right on the device and wrong in `make screenshots`.
local function centred(gc, text, x, y, w, h, style)
  if w <= 0 or h <= 0 then return end
  local size = fitFont(gc, text, w, h, style)
  if not size then return end
  local tw, th = gc:getStringWidth(text), gc:getStringHeight(text)
  gc:drawString(text, x + math.floor((w - tw) / 2), y + math.floor((h - th) / 2), "top")
end

-- ----------------------------------------------------------------- layout --

-- Tile size for a cols x rows grid in the given box, with the largest gap that
-- still leaves a usable tile. Returns the tile edge and the gap.
local function fitGrid(availW, availH, cols, rows)
  for _, gap in ipairs({ 3, 2, 1 }) do
    local tw = math.floor((availW - (cols - 1) * gap) / cols)
    local th = math.floor((availH - (rows - 1) * gap) / rows)
    local t = math.min(tw, th)
    if t >= 12 then return t, gap end
  end
  local tw = math.floor((availW - (cols - 1)) / cols)
  local th = math.floor((availH - (rows - 1)) / rows)
  return math.max(3, math.min(tw, th)), 1
end

-- Places the keyboard's three rows inside a box, returning the rects. ENTER
-- and DEL sit on the bottom row at double width, which is where they are on
-- every phone keyboard and therefore where a thumb looks for them.
local function layoutKeys(x, y, w, h)
  local keys = {}
  local gap = w >= 120 and 1 or 0
  local rowGap = h >= 45 and 2 or 1
  local keyH = math.max(3, math.floor((h - rowGap * 2) / 3))
  local unit = math.max(2, math.floor((w - gap * 9) / 10))
  local wide = math.floor(unit * 3 / 2)

  local rowY = y
  for r, letters in ipairs(KB_ROWS) do
    local row = {}
    for i = 1, #letters do
      row[#row + 1] = { key = letters:sub(i, i), w = unit }
    end
    if r == 3 then
      table.insert(row, 1, { key = "enter", label = "ENT", w = wide })
      row[#row + 1] = { key = "del", label = "DEL", w = wide }
    end

    local total = -gap
    for _, k in ipairs(row) do total = total + k.w + gap end
    local rowX = x + math.floor((w - total) / 2)
    for _, k in ipairs(row) do
      k.x, k.y, k.h = rowX, rowY, keyH
      keys[#keys + 1] = k
      rowX = rowX + k.w + gap
    end
    rowY = rowY + keyH + rowGap
  end

  return keys, rowY - rowGap - y
end

-- The whole screen, recomputed on resize.
--
-- The budget on the handheld's 318x212: a 5x6 grid, a three-row keyboard and a
-- status line do not all fit stacked without shrinking the tiles to about 18px.
-- Side by side they do, because the screen is landscape and Wordle's layout is
-- portrait -- the grid takes 152px of width and 183 of height at 28px tiles,
-- and the 146px left over is enough for ten 13px keys with a gap between them.
-- So: grid on the left, keyboard and status on the right. A window that is not
-- landscape (the computer software can make one) falls back to stacking.
local function relayout()
  local w, h = ui.w, ui.h
  local m = math.max(2, math.min(6, math.floor(math.min(w, h) / 24)))
  ui.m = m
  ui.side = w >= h * 1.15 and w >= 210

  if ui.side then
    local availH = math.max(1, h - 2 * m)
    local availW = math.max(1, w - 3 * m)
    local gridW = math.floor(availW * 0.52)
    local t, gap = fitGrid(gridW, availH, LEN, ROWS)
    ui.tile, ui.gap = t, gap
    ui.gw = LEN * t + (LEN - 1) * gap
    ui.gh = ROWS * t + (ROWS - 1) * gap
    ui.gx = m
    ui.gy = math.max(m, math.floor((h - ui.gh) / 2))

    ui.px = ui.gx + ui.gw + m                       -- right-hand panel
    ui.pw = math.max(1, w - ui.px - m)
    ui.py = m
    ui.ph = math.max(1, h - 2 * m)
  else
    local availW = math.max(1, w - 2 * m)
    -- The keyboard takes a fixed slice of the height; the grid gets the rest.
    local kbH = math.max(12, math.min(math.floor(h * 0.30), 62))
    local availH = math.max(1, h - kbH - 3 * m)
    local t, gap = fitGrid(availW, availH, LEN, ROWS)
    ui.tile, ui.gap = t, gap
    ui.gw = LEN * t + (LEN - 1) * gap
    ui.gh = ROWS * t + (ROWS - 1) * gap
    ui.gx = math.floor((w - ui.gw) / 2)
    ui.gy = m

    ui.px = m
    ui.pw = availW
    ui.py = ui.gy + ui.gh + m
    ui.ph = math.max(1, h - ui.py - m)
  end

  -- The keyboard is anchored to the bottom of the panel, so the space that
  -- opens up above it belongs to the status text and the end-of-game result.
  local kbH = math.max(12, math.min(math.floor(ui.ph * (ui.side and 0.34 or 0.95)), 64))
  local kbY = ui.py + ui.ph - kbH
  ui.keys = layoutKeys(ui.px, kbY, ui.pw, kbH)
  ui.kbY = kbY
  ui.textH = math.max(0, kbY - ui.py - 2)
end

-- ---------------------------------------------------------------- drawing --

-- The marks the player is allowed to see for `n`. During the reveal the row is
-- uncovered a tile at a time, so a row mid-reveal reports nil for the tiles
-- that have not turned yet.
local function visibleMarks(n)
  local row = game.rows[n]
  if not row then return nil end
  if reveal and reveal.row == n then
    local shown = math.floor(reveal.t / REVEAL_TICKS)
    if shown < LEN then return row.marks, shown end
  end
  return row.marks, LEN
end

local function drawGrid(gc)
  local t, gap = ui.tile, ui.gap
  local pad = gap
  col(gc, BOARD_BG)
  gc:fillRect(ui.gx - pad, ui.gy - pad, ui.gw + pad * 2, ui.gh + pad * 2)
  for r = 1, ROWS do
    local y = ui.gy + (r - 1) * (t + gap)
    local row = game.rows[r]
    local marks, shown = visibleMarks(r)
    -- The row being typed into is the one after the last submitted row, and
    -- only while the game is still running.
    local typing = (not row) and game.state == "playing" and r == #game.rows + 1

    for c = 1, LEN do
      local x = ui.gx + (c - 1) * (t + gap)
      local letter, fill, edge

      if row then
        letter = row.word:sub(c, c)
        if c <= shown then
          fill = MARK_FILL[marks[c]]
        else
          edge = TILE_LIVE
        end
      elseif typing and c <= #game.typed then
        letter = game.typed:sub(c, c)
        edge = TILE_LIVE
      else
        edge = TILE_EDGE
      end

      if fill then
        col(gc, fill)
        gc:fillRect(x, y, t, t)
      else
        col(gc, TILE_BG)
        gc:fillRect(x, y, t, t)
        col(gc, edge or TILE_EDGE)
        gc:drawRect(x, y, t, t)
      end

      if letter then
        col(gc, KEY_TEXT)
        drawLetter(gc, letter:upper(), x, y, t, t)
      end
    end
  end
end

local function drawKeyboard(gc)
  local marks = shownKb or {}
  for _, k in ipairs(ui.keys) do
    local fill, ink = KEY_FILL, KEY_TEXT
    if #k.key == 1 then
      local m = marks[string.byte(k.key) - A + 1] or UNKNOWN
      if m ~= UNKNOWN then
        fill = MARK_FILL[m]
        if m == GREY then ink = KEY_DIM end
      end
    else
      fill = PANEL_BG
      ink = INK_SOFT
    end
    col(gc, fill)
    gc:fillRect(k.x, k.y, k.w, k.h)
    if #k.key > 1 then
      col(gc, TILE_EDGE)
      gc:drawRect(k.x, k.y, k.w, k.h)
    end
    col(gc, ink)
    if k.label then
      centred(gc, k.label, k.x, k.y, k.w, k.h, "b")
    else
      drawLetter(gc, k.key:upper(), k.x, k.y, k.w, k.h)
    end
  end
end

-- A line of text in the panel, top down. Returns the y to carry on from, and
-- drops the line entirely rather than overflowing if there is no room left.
local function panelLine(gc, text, y, tone, size, style)
  local limit = ui.py + ui.textH
  gc:setFont("sansserif", style or "r", size)
  local th = gc:getStringHeight(text)
  if y + th > limit then return y end
  local tw = gc:getStringWidth(text)
  -- Nothing here is allowed to spill sideways either: if the measured width
  -- overruns the panel, step down through the sizes until it does not.
  if tw > ui.pw then
    local fitted = fitFont(gc, text, ui.pw, th, style or "r")
    if not fitted then return y + th end
    tw, th = gc:getStringWidth(text), gc:getStringHeight(text)
  end
  col(gc, tone or INK_SOFT)
  gc:drawString(text, ui.px + math.floor((ui.pw - tw) / 2), y, "top")
  return y + th + 1
end

-- The end-of-game share grid: the rows played, as coloured squares. Same
-- information the phone version puts on a clipboard, which this sandbox has no
-- access to -- so it is drawn instead of copied.
local function shareMetrics()
  local n = #game.rows
  local cell = math.max(2, math.min(6, math.floor(ui.pw / 18)))
  local gap = cell >= 4 and 1 or 0
  return n, cell, gap, LEN * cell + (LEN - 1) * gap, n * cell + (n - 1) * gap
end

local function drawShareGrid(gc, y)
  local n, cell, gap, gw, gh = shareMetrics()
  if n == 0 then return y end
  if y + gh > ui.py + ui.textH then return y end
  local x0 = ui.px + math.floor((ui.pw - gw) / 2)
  for r = 1, n do
    for c = 1, LEN do
      col(gc, MARK_FILL[game.rows[r].marks[c]])
      gc:fillRect(x0 + (c - 1) * (cell + gap), y + (r - 1) * (cell + gap), cell, cell)
    end
  end
  return y + gh + 3
end

-- How well the player did, in Wordle's own words.
local VERDICT = { "Genius", "Magnificent", "Impressive", "Splendid", "Great", "Phew" }

-- What the panel has to say, as a list rather than a sequence of draw calls.
-- Building it first means it can be measured first, which is what lets the
-- block be centred in the space above the keyboard: drawn straight down from
-- the title, a two-line status leaves a hole the height of the panel below it.
local function panelItems()
  local items = {}
  local function line(text, tone, size, style)
    items[#items + 1] = { text = text, tone = tone, size = size, style = style }
  end

  if game.hard then line("hard mode", ACCENT, 9, "i") end

  if game.state == "ready" then
    line("Type a five-letter word", INK_SOFT, 9)
    line("enter guesses it", INK_SOFT, 9)
    line("left arrow deletes", INK_SOFT, 9)
    line("H toggles hard mode", INK_SOFT, 9)
    line("Press enter to play", INK, 10, "b")
  elseif game.state == "won" then
    line(VERDICT[#game.rows] or "Phew", GOOD, 12, "b")
    items[#items + 1] = { share = true }
    line("enter plays again", INK_SOFT, 9)
  elseif game.state == "lost" then
    line(game.answer:upper(), BAD, 12, "b")
    items[#items + 1] = { share = true }
    line("enter plays again", INK_SOFT, 9)
  else
    if message then
      line(message.text, message.tone, 10, "b")
    else
      local left = ROWS - #game.rows
      line(left == 1 and "last guess" or (left .. " guesses left"), INK_SOFT, 9)
    end
    -- The candidate count, or a placeholder while the filter is mid-pass. It
    -- is never a stale number: the pass swaps its result in atomically.
    local n = game:remaining()
    line(n and (n == 1 and "1 word fits" or (n .. " words fit")) or "counting...",
      INK_SOFT, 9)
  end

  return items
end

local function drawPanel(gc)
  local bottom = ui.py + ui.textH
  local y = panelLine(gc, "WORDLE", ui.py, ACCENT, 16, "b") + 2

  local items = panelItems()
  local total = 0
  for _, it in ipairs(items) do
    if it.share then
      total = total + select(5, shareMetrics()) + 3
    else
      gc:setFont("sansserif", it.style or "r", it.size)
      total = total + gc:getStringHeight(it.text) + 1
    end
  end

  y = y + math.max(0, math.floor((bottom - y - total) / 2))
  for _, it in ipairs(items) do
    if it.share then
      y = drawShareGrid(gc, y)
    else
      y = panelLine(gc, it.text, y, it.tone, it.size, it.style)
    end
  end
  return y
end

function on.paint(gc)
  col(gc, PAGE_BG)
  gc:fillRect(0, 0, ui.w, ui.h)
  drawGrid(gc)
  drawPanel(gc)
  drawKeyboard(gc)
end

-- ------------------------------------------------------------------ input --

local function submit()
  local okay, reason, msg = game:submit()
  if okay then
    reveal = { row = #game.rows, t = 0 }
    game:beginFilter()
    message = nil
  elseif reason ~= "over" then
    say(msg or "?", reason == "short" and INK_SOFT or BAD)
  end
  return okay
end

local function confirm()
  if game.state == "ready" then
    newRound()
  elseif game:isOver() then
    newRound()
  elseif reveal then
    -- Enter during the reveal finishes it rather than being swallowed; a
    -- player typing quickly should never lose a keypress to an animation.
    reveal.t = LEN * REVEAL_TICKS
  else
    submit()
  end
  platform.window:invalidate()
end

local function del()
  if game:backspace() then platform.window:invalidate() end
end

function on.charIn(ch)
  entropy = Wordle.mix(entropy, #ch > 0 and string.byte(ch) or 0)

  -- Space confirms, the way it does in the other games here. It reaches the
  -- script through on.charIn like any other character; there is no separate
  -- handler for it.
  if ch == " " then
    if game.state ~= "playing" then confirm() end
    return
  end

  if game.state == "ready" then
    -- Hard mode is only settable between games, which is also its real rule:
    -- it cannot be turned on halfway through to change what is legal.
    if Wordle.letterOf(ch) == "h" then
      game.hard = not game.hard
      platform.window:invalidate()
    end
    return
  end

  if game:typeLetter(ch) then platform.window:invalidate() end
end

function on.enterKey()
  entropy = Wordle.mix(entropy, 13)
  confirm()
end

-- on.backspaceKey is not in every Nspire OS build, and a handler the runtime
-- never calls is harmless, so it is defined *and* the left arrow deletes as
-- well. One of the two is guaranteed to reach the player.
function on.backspaceKey()
  del()
end

function on.arrowKey(dir)
  if dir == "left" then del() end
end

function on.escapeKey()
  -- Escape clears what has been typed, which is the fastest way out of a word
  -- that is going nowhere. With nothing typed there is nothing to clear.
  if game.state == "playing" and #game.typed > 0 then
    while game:backspace() do end
    platform.window:invalidate()
  end
end

function on.mouseDown(x, y)
  entropy = Wordle.mix(Wordle.mix(entropy, x), y)
  for _, k in ipairs(ui.keys) do
    if x >= k.x and x < k.x + k.w and y >= k.y and y < k.y + k.h then
      if k.key == "enter" then
        confirm()
      elseif k.key == "del" then
        del()
      elseif game.state == "playing" then
        if game:typeLetter(k.key) then platform.window:invalidate() end
      end
      return
    end
  end
  -- A click anywhere else confirms, so the title and result screens can be
  -- dismissed without reaching for the keyboard.
  if game.state ~= "playing" then confirm() end
end

-- ------------------------------------------------------------------ timer --

function on.timer()
  local dirty = false

  -- Every tick moves the entropy on, so how long the player spends on the
  -- title screen -- or on the round before this one -- is what decides the
  -- next word. This is the only source that is guaranteed to vary on a
  -- handheld with no clock and no working reseed.
  entropy = Wordle.mix(entropy, 1)

  if reveal then
    reveal.t = reveal.t + 1
    dirty = true
    if reveal.t >= LEN * REVEAL_TICKS then
      reveal = nil
      -- The keyboard catches up only once the row has finished turning;
      -- updating it at submit time would colour a letter green before the
      -- tile that earned it had flipped.
      shownKb = copyLetters()
    end
  end

  if message then
    message.t = message.t - 1
    if message.t <= 0 then
      message = nil
      dirty = true
    end
  end

  -- One slice of the candidate filter. Deliberately after the reveal, so the
  -- two never compete for the same tick's budget on a slow handheld.
  if game:isFiltering() then
    if game:filterStep(Wordle.TICK_CANDIDATES) then dirty = true end
  end

  if dirty then platform.window:invalidate() end
end

function on.resize(w, h)
  ui.w, ui.h = w, h
  relayout()
end

-- --------------------------------------------------------------- start up --

ui.w, ui.h = platform.window:width(), platform.window:height()
relayout()
shownKb = copyLetters()
timer.start(BASE_TICK)
