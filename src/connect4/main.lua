-- main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules and the bot live in src/connect4/game.lua. `platform.apilevel` is
-- emitted as the first line of the bundle by tools/bundle.py, so it is
-- intentionally absent here.
--
-- When bundled, `Board` is already a local from the inlined module; the
-- `Board or require` form below also lets this file load under a desktop Lua.
local Board = Board or require("game")

-- ------------------------------------------------------------------ tuning --
-- Connect Four is turn-based, so nothing here is a game loop: the timer runs
-- the drop animation and feeds the bot its slices, and asks for a repaint only
-- while one of those is actually happening.
local BASE_TICK       = 0.05 -- host timer period, the practical floor on hardware
local DROP_TICKS      = 5    -- ticks a disc takes to fall, whatever the distance
local MIN_THINK_TICKS = 3    -- shortest visible "thinking" pause, see below

-- Nodes of search per timer tick, and why that number: see the note above
-- Board.TICK_NODES in game.lua, which is where the measurements live. It is
-- kept there rather than here because the difficulty table is calibrated
-- against it, and the tests check that calibration.
local TICK_NODES      = Board.TICK_NODES

-- If the estimate behind it is wrong the bot does not break, it just lands on
-- a different depth: each difficulty caps its turn in *ticks*, and iterative
-- deepening means whatever depth finished inside them is the one that plays.
-- ---------------------------------------------------------------------------

local HUD_H    = 22 -- height of the status bar, pixels
local CURSOR_H = 16 -- strip above the board: the drop cursor, and the result banner
local CELL_MIN = 6
local PAD_X    = 8  -- breathing room around the result banner's text, pixels
local PAD_Y    = 3
local CELL_MAX = 40 -- past this the board looks silly on a large window

local COLS, ROWS = Board.COLS, Board.ROWS

-- These exact values are the contract with tests/connect4/frame.lua, which
-- reads the board back out of a painted frame rather than out of the game.
local PAGE     = {  18,  21,  27 }
local HUD_BG   = {  30,  34,  44 }
local HUD_RULE = {  58,  64,  80 }
local BOARD_BG = {  38,  78, 180 }
local BOARD_RIM = {  22,  46, 112 } -- the moulded edge around the classic board
local BOARD_HI = {  58, 102, 214 } -- the hovered column
local HOLE     = {  16,  19,  26 }
local PANEL_BG = {  26,  30,  39 }
local RING     = { 255, 255, 255 } -- flashes around the winning four
local INK      = { 224, 228, 238 }
local INK_DIM  = { 138, 146, 164 }

local DISC = {
  [1] = { 226,  66,  60 },
  [2] = { 247, 199,  58 },
}
local NAME = { [1] = "Red", [2] = "Yellow" }

local ui = { w = 318, h = 212, cell = 24, bx = 0, by = HUD_H + CURSOR_H, pad = 3 }

local game = Board.new({ mode = "bot" })
local ai   = nil

-- phase is what the *presentation* is doing, which is not the same question as
-- game.state: the board can be mid-game while the screen is busy dropping a
-- disc or the bot is busy thinking, and input has to be ignored during both.
local phase      = "idle" -- idle | dropping | thinking
local anim       = nil    -- { c, r, p, t } while a disc is falling
local thinkTicks = 0
local cursor     = 4
local blink      = 0
local entropy    = 0      -- ticks idled before the first input; seeds the RNG
local starter    = 1      -- who opens the next round; alternates

local menu = { row = 1, mode = 2, level = 2 } -- mode 1 = hot-seat, 2 = vs bot

local MODE_NAMES  = { "2 Players (hot-seat)", "1 Player vs Computer" }
local MODE_SHORT  = { "2 Players",            "vs Computer" }

-- ---------------------------------------------------------------- helpers --

local function col(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

local function level() return Board.LEVELS[menu.level] end

local function vsBot() return game.mode == "bot" end

local function botPlayer() return game.botPlayer end

-- os.time() alone is a poor seed here: a handheld that has just been reset can
-- report the same value every launch, which would make the bot's blunders --
-- and so every Easy game -- identical every time. Mixing in how long the
-- player sat on the title screen fixes that.
local function reseed()
  local t = 0
  if os and os.time then t = os.time() or 0 end
  if os and os.clock then t = t + math.floor((os.clock() or 0) * 1000) end
  math.randomseed(t + entropy * 7919)
  math.random(); math.random() -- first draws after a reseed are weakly mixed
end

-- True when the machine is waiting on a person rather than on itself.
local function humansTurn()
  return game.state == "playing" and phase == "idle"
    and not (vsBot() and game.turn == botPlayer())
end

local function nearestOpen(c)
  if game:open(c) then return c end
  for d = 1, COLS do
    if game:open(c - d) then return c - d end
    if game:open(c + d) then return c + d end
  end
  return c
end

-- Hands the bot the position and lets on.timer() feed it from there.
local function startThinking()
  if not ai then ai = Board.AI.fromLevel(game, menu.level) end
  ai:cancel()
  thinkTicks = 0
  phase = "thinking"
end

-- Called once a disc has finished falling: hand over to the bot, or to the
-- player, or to nobody if that disc ended the game.
local function afterMove()
  if game:isOver() then
    phase = "idle"
    return
  end
  cursor = nearestOpen(cursor)
  if vsBot() and game.turn == botPlayer() then
    startThinking()
  else
    phase = "idle"
  end
end

local function doDrop(c)
  if phase == "dropping" or game.state ~= "playing" then return false end
  local p = game.turn
  -- The tally the status bar shows while the disc is in the air. A winning
  -- drop bumps it the moment it is committed, and a score that ticks over
  -- before the disc lands gives the result away just as surely as the banner.
  local tally = { game.wins[1], game.wins[2] }
  local r = game:drop(c)
  if not r then return false end
  cursor = c
  anim = { c = c, r = r, p = p, t = 0, wins = tally }
  phase = "dropping"
  return true
end

local function newRound()
  reseed()
  game.mode = (menu.mode == 1) and "hotseat" or "bot"
  game:reset(starter)
  starter = 3 - starter -- alternate the opening move between rounds
  game:start()
  ai = Board.AI.fromLevel(game, menu.level)
  anim, phase, thinkTicks = nil, "idle", 0
  cursor = 4
  if vsBot() and game.turn == botPlayer() then startThinking() end
end

local function toMenu()
  if ai then ai:cancel() end
  -- Clear the board on the way out. Leaving the abandoned game showing behind
  -- the title panel invites the player to think it is still theirs to finish.
  -- The match tally is not part of a round, so it survives.
  game:reset(starter)
  anim, phase = nil, "idle"
  cursor = 4
end

local function togglePause()
  -- Pausing mid-search is fair game and throws the search away; the bot
  -- starts over on resume. Mid-drop it is ignored, because the disc is five
  -- ticks from landing and freezing it in the air looks like a fault.
  if game.state == "playing" and phase ~= "dropping" then
    if phase == "thinking" then
      if ai then ai:cancel() end
      phase = "idle"
    end
    game:pause()
  elseif game.state == "paused" then
    game:resume()
    -- The bot's search was thrown away on the way in, so start it again.
    if vsBot() and game.turn == botPlayer() then startThinking() end
  end
end

local function confirm()
  local s = game.state
  if s == "ready" then
    newRound()
  elseif s == "paused" then
    game:resume()
    if vsBot() and game.turn == botPlayer() then startThinking() end
  elseif game:isOver() then
    newRound()
  elseif humansTurn() then
    doDrop(cursor)
  end
end

-- --------------------------------------------------------------- lifecycle --

-- Called before the first paint, and again if the window is resized -- which
-- on a handheld means never, but the computer software can resize freely.
-- The board is always 7x6, so a resize only ever changes the scale: unlike
-- Snake, there is no reason for it to disturb a game in progress.
function on.resize(w, h)
  ui.w, ui.h = w, h

  -- The extra slack is the moulded rim drawn just outside the board.
  local availW = w - 12
  local availH = h - HUD_H - CURSOR_H - 8
  local cell = math.floor(math.min(availW / COLS, availH / ROWS))
  if cell > CELL_MAX then cell = CELL_MAX end
  if cell < CELL_MIN then cell = CELL_MIN end

  local bw, bh = cell * COLS, cell * ROWS
  ui.cell = cell
  ui.pad = math.max(1, math.floor(cell / 8))
  ui.bx = math.max(0, math.floor((w - bw) / 2))
  ui.by = math.max(HUD_H + CURSOR_H,
                   HUD_H + CURSOR_H + math.floor((h - HUD_H - CURSOR_H - bh) / 2))

  platform.window:invalidate()
end

timer.start(BASE_TICK)

function on.timer()
  blink = blink + 1
  local dirty = false

  if game.state == "ready" or game.state == "paused" then
    entropy = entropy + 1
    if blink % 8 == 0 then dirty = true end

  elseif phase == "dropping" then
    anim.t = anim.t + 1
    dirty = true
    if anim.t >= DROP_TICKS then
      anim = nil
      afterMove()
    end

  elseif phase == "thinking" then
    thinkTicks = thinkTicks + 1
    local mv = ai:think(TICK_NODES)

    -- The turn is capped in ticks, not in nodes, because how many nodes fit in
    -- a tick depends on a machine this code cannot measure. Whatever depth
    -- finished by now is the one that plays.
    if not mv and thinkTicks >= level().thinkTicks then
      mv = ai:stop()
    end

    -- An instant answer -- a forced win, or an Easy-level blunder -- would
    -- otherwise flash past with the board apparently moving on its own, so
    -- hold the indicator up for a few ticks either way.
    if mv and thinkTicks >= MIN_THINK_TICKS then
      phase = "idle"
      if not doDrop(mv) then afterMove() end
    end
    dirty = true

  elseif game:isOver() then
    if blink % 4 == 0 then dirty = true end -- flash the winning four
  end

  if dirty then platform.window:invalidate() end
end

function on.deactivate()
  -- Losing focus mid-search would leave the bot holding a half-finished
  -- search across an unknown gap in time; pausing throws it away cleanly.
  if phase == "thinking" then
    if ai then ai:cancel() end
    phase = "idle"
  end
  game:pause()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

local function menuKey(key)
  if key == "up" then
    menu.row = (menu.row == 1) and 2 or 1
  elseif key == "down" then
    menu.row = (menu.row == 2) and 1 or 2
  elseif key == "left" or key == "right" then
    local d = (key == "right") and 1 or -1
    if menu.row == 1 then
      menu.mode = (menu.mode == 1) and 2 or 1
    else
      menu.level = ((menu.level - 1 + d) % #Board.LEVELS) + 1
      ai = nil -- rebuilt at the next round, at the new depth
    end
  end
end

function on.arrowKey(key)
  if game.state == "ready" then
    menuKey(key)
  elseif game.state == "paused" or game:isOver() then
    -- Arrows do nothing behind an overlay; enter is the way out.
  elseif key == "left" or key == "right" then
    if humansTurn() then
      local d = (key == "right") and 1 or -1
      local c = cursor
      for _ = 1, COLS do
        c = ((c - 1 + d) % COLS) + 1
        if game:open(c) then break end
      end
      cursor = c
    end
  elseif key == "down" then
    if humansTurn() then doDrop(cursor) end
  end
  platform.window:invalidate()
end

function on.enterKey()
  confirm()
  platform.window:invalidate()
end

function on.escapeKey()
  if game.state == "ready" then
    -- already home
  elseif game:isOver() then
    toMenu()
  else
    togglePause()
  end
  platform.window:invalidate()
end

function on.charIn(ch)
  ch = string.lower(ch or "")
  local n = tonumber(ch)

  if game.state == "ready" then
    -- 1 and 2 pick the mode straight off the title screen.
    if n == 1 or n == 2 then
      menu.mode = (n == 1) and 2 or 1
    elseif ch == " " then
      confirm()
    end

  elseif n and n >= 1 and n <= COLS then
    -- Typing the column number is the fastest way to play on a calculator,
    -- and beats walking the cursor across with the arrow keys.
    if humansTurn() then doDrop(n) end

  elseif ch == " " then
    confirm()
  elseif ch == "a" then
    on.arrowKey("left"); return
  elseif ch == "d" then
    on.arrowKey("right"); return
  elseif ch == "s" then
    on.arrowKey("down"); return
  elseif ch == "p" then
    togglePause()
  elseif ch == "r" then
    if game.state ~= "ready" then newRound() end
  elseif ch == "m" then
    toMenu()
  end

  platform.window:invalidate()
end

function on.mouseDown(x, y)
  if game.state ~= "playing" then
    confirm()
  elseif humansTurn() then
    local c = math.floor((x - ui.bx) / ui.cell) + 1
    if c >= 1 and c <= COLS then
      cursor = c
      doDrop(c)
    end
  end
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function cellX(c) return ui.bx + (c - 1) * ui.cell end
local function cellY(r) return ui.by + (r - 1) * ui.cell end

-- A game is over the instant the winning disc is committed, but the disc is
-- still in the air for another few ticks. Announcing the result over a disc
-- the player can see falling gives the game away before the board does, so
-- everything that reports the result waits for it to land.
local function resultVisible()
  return game:isOver() and not anim
end

local function statusText()
  if game.state == "ready" then
    return MODE_NAMES[menu.mode]
  elseif game.state == "paused" then
    return "Paused"
  elseif anim then
    return NAME[anim.p] .. " to play"
  elseif game.state == "draw" then
    return "Draw"
  elseif game.state == "won" then
    return NAME[game.winner] .. " wins"
  elseif phase == "thinking" then
    -- The depth is honest information, not decoration: it is how a player can
    -- tell a slow machine from a hard level. It is the depth being searched
    -- now, not the last one finished, so it never reads as zero.
    local d = math.max((ai and ai.searchDepth) or 1, 1)
    return "Thinking d" .. d .. string.rep(".", 1 + (blink % 3))
  end
  return NAME[game.turn] .. " to play"
end

local function drawHud(gc)
  col(gc, HUD_BG)
  gc:fillRect(0, 0, ui.w, HUD_H)
  col(gc, HUD_RULE)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  gc:setFont("sansserif", "b", 10)
  local titleW = gc:getStringWidth("CONNECT 4")

  gc:setFont("sansserif", "r", 10)
  local tally = (anim and anim.wins) or game.wins
  local stats = statusText() .. "   " .. tally[1] .. "-" .. tally[2]
  -- Drawn games only earn a place in the tally once one has happened.
  if game.draws > 0 then stats = stats .. "-" .. game.draws end
  local statsW = gc:getStringWidth(stats)
  local statsX = ui.w - statsW - 6

  -- A long status, or a wider font than assumed, can push the status into the
  -- title. The status matters more, so the title is what yields.
  if statsX > titleW + 12 then
    gc:setFont("sansserif", "b", 10)
    col(gc, DISC[1])
    gc:drawString("CONNECT 4", 6, 4, "top")
    gc:setFont("sansserif", "r", 10)
  end

  col(gc, INK)
  local sx = math.max(4, statsX)
  gc:drawString(stats, sx, 4, "top")

  -- A swatch of whose move it is. The status line already says so, but the
  -- colour is the thing a player actually glances at, and it reads at a
  -- distance where 10pt text does not.
  local who = nil
  if anim then who = anim.p
  elseif game.state == "won" then who = game.winner
  elseif game.state == "playing" or game.state == "paused" then who = game.turn end
  if who and sx >= 12 then
    col(gc, DISC[who])
    gc:fillRect(sx - 9, 7, 6, 8)
  end
end

-- The chevron above the board showing where the next disc goes. Drawn out of
-- rectangles rather than an arc so that every fillArc in a frame is a board
-- cell, which is what lets tests/connect4/ui.lua assert that no disc ever
-- escapes the board.
local function drawCursor(gc)
  if game.state ~= "playing" or phase == "dropping" then return end
  if phase ~= "thinking" and not humansTurn() then return end
  if not game:open(cursor) then return end

  local d = ui.cell - 2 * ui.pad
  local h = math.min(CURSOR_H - 3, math.max(3, math.floor(d / 2)))
  local cx = cellX(cursor) + ui.cell / 2
  local top = ui.by - h - 2

  if phase == "thinking" then
    -- A pulsing marker centred over the board, not over a column: the bot has
    -- not chosen one yet, and putting the marker anywhere in particular would
    -- be a guess the player would read as an answer.
    local mid = ui.bx + (ui.cell * COLS) / 2
    col(gc, ((blink % 6) < 3) and DISC[botPlayer()] or HUD_RULE)
    gc:fillRect(math.floor(mid - d / 4), top, math.max(1, math.floor(d / 2)), 2)
    return
  end

  col(gc, DISC[game.turn])
  for i = 0, h - 1 do
    local wRow = math.floor(d * (h - i) / h)
    if wRow > 0 then
      gc:fillRect(math.floor(cx - wRow / 2), top + i, wRow, 1)
    end
  end
end

local function drawBoard(gc)
  local cell, pad = ui.cell, ui.pad
  local bw, bh = cell * COLS, cell * ROWS
  local d = cell - 2 * pad

  -- A darker rim, the way the moulding round a real board reads. Clamped to
  -- the window so a small computer-software window cannot push it off-screen.
  local rim = math.max(1, math.min(3, math.floor(cell / 8)))
  local rx = math.max(0, ui.bx - rim)
  local ry = math.max(0, ui.by - rim)
  col(gc, BOARD_RIM)
  gc:fillRect(rx, ry, math.min(bw + 2 * rim, ui.w - rx), math.min(bh + 2 * rim, ui.h - ry))

  col(gc, BOARD_BG)
  gc:fillRect(ui.bx, ui.by, bw, bh)

  -- The hovered column, lit from behind so the holes still read as holes.
  if humansTurn() and game:open(cursor) then
    col(gc, BOARD_HI)
    gc:fillRect(cellX(cursor), ui.by, cell, bh)
  end

  local lineSet = nil
  if game.line and resultVisible() and (blink % 8) < 5 then
    lineSet = {}
    for _, c in ipairs(game.line) do lineSet[(c.r - 1) * COLS + c.c] = true end
  end

  for r = 1, ROWS do
    for c = 1, COLS do
      local x, y = cellX(c), cellY(r)
      local v = game:at(c, r)

      -- While a disc is falling its destination is still shown empty; the
      -- disc itself is drawn below, in flight. Exactly 42 arcs either way.
      if anim and anim.c == c and anim.r == r then v = 0 end

      -- The highlight is a white disc drawn just under the winning one, so it
      -- shows as a ring. It needs pad > 1 to have anything to show; on a
      -- window small enough that the discs are only a few pixels across it
      -- ends up exactly behind them and the flash is simply lost, which is
      -- the right way for it to fail -- the banner and the status bar still
      -- say who won.
      if v ~= 0 and lineSet and lineSet[(r - 1) * COLS + c] then
        col(gc, RING)
        gc:fillArc(x + 1, y + 1, cell - 2, cell - 2, 0, 360)
      end

      col(gc, (v == 0) and HOLE or DISC[v])
      gc:fillArc(x + pad, y + pad, d, d, 0, 360)
    end
  end

  if anim then
    -- Accelerating rather than linear, because a disc that falls at a
    -- constant speed reads as a slide. It starts at the top row of the board,
    -- never above it, so it is inside the board on every frame.
    local t = anim.t / DROP_TICKS
    if t > 1 then t = 1 end
    local y = cellY(1) + pad + (t * t) * (anim.r - 1) * cell
    col(gc, DISC[anim.p])
    gc:fillArc(cellX(anim.c) + pad, math.floor(y + 0.5), d, d, 0, 360)
  end
end

-- lines: array of { text, dim = bool, sel = bool, alt = { shorter... },
--   drop = n }. `alt` gives shorter wordings to fall back on when the window
--   is too narrow for the first. `drop` marks a line that may be given up
--   when the window is too short to hold them all, lowest rank first, so the
--   line naming the key that starts the game outlives the ones explaining
--   the menu.
-- opts.widest: line tables a row might later hold, so the panel is sized once
--   for the widest wording it can ever show and does not jitter as the
--   selection moves through the menu.
local TITLE_GAP = 8

local function drawPanel(gc, title, lines, accent, opts)
  opts = opts or {}

  gc:setFont("sansserif", "b", 16)
  local titleH = gc:getStringHeight(title)
  local titleW = gc:getStringWidth(title)
  gc:setFont("sansserif", "r", 10)
  local lineH = gc:getStringHeight("Ay")

  -- Heights come from the font rather than from a guess at how tall a line
  -- is: the handheld's font is not the one these tests measure with, and a
  -- panel sized against the wrong number clips its own last line.
  local shown = {}
  for _, l in ipairs(lines) do shown[#shown + 1] = l end

  local maxH = ui.h - HUD_H - 4
  local pad = 12
  local function panelH() return titleH + TITLE_GAP + #shown * lineH + pad * 2 end

  -- Give up padding first, then the lines marked optional. A squeezed panel
  -- beats a clipped one, and the rows you can actually select matter more
  -- than the lines explaining how to select them.
  while panelH() > maxH and pad > 2 do pad = pad - 1 end
  while panelH() > maxH do
    local pick, rank
    for i = #shown, 1, -1 do
      local d = shown[i].drop
      if d and (rank == nil or d < rank) then pick, rank = i, d end
    end
    if not pick then break end
    table.remove(shown, pick)
  end
  -- Give the padding back once the lines are gone; it was only borrowed.
  while pad < 12
      and titleH + TITLE_GAP + #shown * lineH + (pad + 1) * 2 <= maxH do
    pad = pad + 1
  end

  -- Then take the longest wording of each line that still fits across. The
  -- handheld takes the full forms; only a computer-software window dragged
  -- narrow ever reaches for the short ones.
  local availW = ui.w - 4 - pad * 2
  local function widestFitting(l)
    local text = l[1]
    for _, shorter in ipairs(l.alt or {}) do
      if gc:getStringWidth(text) <= availW then break end
      text = shorter
    end
    return text
  end

  local texts, maxW = {}, titleW
  for i, l in ipairs(shown) do
    texts[i] = widestFitting(l)
    local w = gc:getStringWidth(texts[i])
    if w > maxW then maxW = w end
  end
  for _, l in ipairs(opts.widest or {}) do
    local w = gc:getStringWidth(widestFitting(l))
    if w > maxW then maxW = w end
  end

  local bw = math.min(maxW + pad * 2, ui.w - 4)
  local bh = math.min(panelH(), maxH)
  local bx = math.max(2, math.floor((ui.w - bw) / 2))
  local by = math.max(HUD_H + 2, math.floor((ui.h - bh) / 2) + math.floor(HUD_H / 2))

  col(gc, PANEL_BG)
  gc:fillRect(bx, by, bw, bh)
  col(gc, accent)
  gc:drawRect(bx, by, bw, bh)

  gc:setFont("sansserif", "b", 16)
  gc:drawString(title, bx + math.floor((bw - titleW) / 2), by + pad, "top")

  gc:setFont("sansserif", "r", 10)
  local y = by + pad + titleH + TITLE_GAP
  local lit = (blink % 16) < 10
  for i, l in ipairs(shown) do
    if l.sel then
      col(gc, accent)
    elseif l.dim and not lit then
      col(gc, INK_DIM)
    elseif l.dim then
      col(gc, INK)
    else
      col(gc, INK_DIM)
    end
    gc:drawString(texts[i], bx + math.floor((bw - gc:getStringWidth(texts[i])) / 2), y, "top")
    y = y + lineH
  end
end

-- A slim bar in the strip above the board, which is where a finished game
-- says what to press. A modal panel in the middle of the screen would sit
-- right on top of the winning four, and that is the one thing worth looking
-- at when a game ends.
local function drawBanner(gc, text, accent)
  gc:setFont("sansserif", "r", 10)

  -- Shorten rather than overflow: the handheld fits the long form, but the
  -- computer software can be dragged narrower than any of them.
  for _, candidate in ipairs({ text, "enter: again    M: menu", "enter / M" }) do
    text = candidate
    if gc:getStringWidth(text) <= ui.w - 20 then break end
  end

  -- Size the bar around the line rather than around a guess at how tall a
  -- line is. The first version centred against a hard-coded 11 when the font
  -- reports 14, leaving the descenders of "play again" a single pixel off the
  -- border: fine in the preview, and a clipped line on a handheld whose font
  -- this code has no way to measure.
  local tw, th = gc:getStringWidth(text), gc:getStringHeight(text)
  local bh = math.min(th + PAD_Y * 2, ui.by - HUD_H - 2)
  if bh < th + 2 then return end -- no room; the status bar still says who won

  local bw = math.min(tw + PAD_X * 2, ui.w - 4)
  local bx = math.max(2, math.floor((ui.w - bw) / 2))
  local by = math.max(HUD_H + 1, ui.by - bh - 1)

  col(gc, PANEL_BG)
  gc:fillRect(bx, by, bw, bh)
  col(gc, accent)
  gc:drawRect(bx, by, bw, bh)
  col(gc, INK)
  gc:drawString(text, bx + math.floor((bw - tw) / 2),
                      by + math.floor((bh - th) / 2), "top")
end

local function drawOverlay(gc)
  local s = game.state

  if s == "ready" then
    -- The angle brackets go on the selected row only, so it is obvious which
    -- one Left/Right will change.
    local function row(label, text, selected)
      if selected then return label .. ": < " .. text .. " >" end
      return label .. ":  " .. text
    end

    -- Full wording, then a shorter mode name, then no label at all: at the
    -- narrowest the arrows are what matter, and the status bar is already
    -- spelling the mode out in full.
    local function modeRow(i, selected)
      return { row("Mode", MODE_NAMES[i], selected),
               alt = { row("Mode", MODE_SHORT[i], selected),
                       selected and ("< " .. MODE_SHORT[i] .. " >") or MODE_SHORT[i] } }
    end

    local modeLine = modeRow(menu.mode, menu.row == 1)
    modeLine.sel = (menu.row == 1)

    local function levelRow(name, selected)
      return { row("Level", name, selected),
               alt = { selected and ("< " .. name .. " >") or name } }
    end

    local levelLine = levelRow(level().name, menu.row == 2)
    levelLine.sel = (menu.row == 2)
    levelLine.dim = (menu.mode == 1)

    -- Every wording either row can take, so the panel is sized once for the
    -- widest and stays put while the player scrolls through them.
    local widest = {}
    for i = 1, #MODE_NAMES do widest[#widest + 1] = modeRow(i, true) end
    for _, L in ipairs(Board.LEVELS) do
      widest[#widest + 1] = levelRow(L.name, true)
    end

    drawPanel(gc, "CONNECT 4", {
      modeLine,
      levelLine,
      { "Up/Down pick a row, Left/Right change it",
        alt = { "Up/Down, then Left/Right" }, drop = 1 },
      { "In play: arrows or 1-7, enter to drop",
        alt = { "arrows or 1-7 to drop" }, drop = 1 },
      { "Press enter to play", alt = { "enter to play" }, dim = true, drop = 2 },
    }, DISC[1], { widest = widest })

  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { NAME[game.turn] .. " to play" },
      { "enter: resume     M: menu", alt = { "enter / M" }, dim = true },
    }, { 240, 190, 70 })

  elseif s == "won" and resultVisible() then
    -- The status bar already names the winner and carries the tally, and the
    -- four discs are flashing on the board, so all that is left to say is
    -- which key does what.
    drawBanner(gc, "enter: play again    M: menu", DISC[game.winner])

  elseif s == "draw" and resultVisible() then
    drawBanner(gc, "A draw -- enter: again    M: menu", { 240, 190, 70 })

  end
end

function on.paint(gc)
  col(gc, PAGE)
  gc:fillRect(0, 0, ui.w, ui.h)
  drawBoard(gc)
  drawCursor(gc)
  drawHud(gc)
  drawOverlay(gc)
end
