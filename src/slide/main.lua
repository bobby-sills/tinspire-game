-- main.lua -- TI-Nspire presentation layer: drawing, input, timing.
--
-- Rules live in src/slide/game.lua. `platform.apilevel` is emitted as the first
-- line of the bundle by tools/bundle.py, so it is intentionally absent here.
--
-- When bundled, `Puzzle` is already a local from the inlined module; the
-- `Puzzle or require` form below also lets this file load under a desktop Lua.
local Puzzle = Puzzle or require("game")

-- ------------------------------------------------------------------ tuning --
-- The puzzle is strictly turn-based, so there is no game loop: every repaint
-- is caused by a key. The timer runs the slide animation, ticks the clock and
-- feeds the hint search; it asks for repaints only when one of those has
-- actually changed something.
local BASE_TICK    = 0.05  -- host timer period, the practical floor on hardware
local SLIDE_TICKS  = 3     -- ticks a tile takes to travel one cell
local SECOND_TICKS = 20    -- ticks per displayed second, i.e. 1 / BASE_TICK
local ENTRY_TICKS  = 14    -- how long a half-typed tile number waits for a digit

-- Hint budget. tests/slide/run.lua's benchmark measures this search at about
-- 200000 nodes/second on the container it was developed in; a CX II running
-- the same interpreted Lua is assumed to be roughly 25x slower, so 300 nodes
-- is on the order of 10 ms -- comfortably inside a 50 ms tick. Being wrong
-- about that factor only changes how long the hint takes to arrive: the search
-- is sliced, so the screen keeps repainting and keys keep working either way.
local HINT_NODES_PER_TICK = 300
local HINT_MAX_NODES      = 80000
-- ---------------------------------------------------------------------------

local HUD_H = 22          -- height of the status bar, pixels

-- Colours. The two tile fills are a contract with tests/slide/frame.lua, which
-- reads the board back out of the paint calls rather than out of the game, so
-- changing one here means changing it there too.
local PAGE_BG   = {  18,  21,  27 }
local HUD_BG    = {  30,  34,  44 }
local HUD_RULE  = {  58,  64,  80 }
local BOARD_BG  = {  40,  45,  58 }
local CELL      = {  56,  63,  80 }   -- empty cell backing; the gap is one of these
local TILE      = { 232, 222, 200 }   -- a tile not yet in its final position
local TILE_HOME = { 150, 205, 155 }   -- ...and one that is
local TILE_INK  = {  42,  46,  42 }
local PANEL_BG  = {  26,  30,  39 }
local TEXT      = { 215, 220, 232 }
local DIM       = { 120, 128, 148 }
local GOLD      = { 246, 176,  14 }
local GREEN     = { 120, 200, 130 }
local RED       = { 228,  72,  62 }

-- Largest first: fitFont walks down until the widest label measures small
-- enough.
local FONT_STEPS = { 24, 16, 12, 11, 10, 9, 7 }

local ui = { w = 318, h = 212, bx = 0, by = HUD_H, side = 0, tile = 0, gap = 0 }

local entropy  = 1     -- folded into the seed by every tick, key and click
local inverted = false -- arrow convention; see ARROW_HELP below
local anim     = nil   -- { tiles, t } while a slide is on screen, else nil
local entry    = ""    -- half-typed tile number
local entryAge = 0
local hint     = nil   -- { solver, plan, at, msg, tone }
local puzzle

-- The convention has to be stated, because the two readings are exact
-- opposites and the wrong one feels broken rather than merely unfamiliar.
local ARROW_HELP = {
  [false] = "Arrows slide the tile that way",
  [true]  = "Arrows move the gap that way",
}

-- ---------------------------------------------------------------- helpers --

local function col(gc, c) gc:setColorRGB(c[1], c[2], c[3]) end

-- Note what is not here: math.randomseed. On the handheld it silently does
-- nothing, so seeding it would deal the same scramble every launch. The
-- entropy above is the source and Puzzle.newRandom is the generator.
local function newRand()
  local seed = entropy
  if os and os.time then seed = Puzzle.mix(seed, os.time() or 0) end
  if os and os.clock then seed = Puzzle.mix(seed, (os.clock() or 0) * 1000) end
  local okay, r = pcall(math.random, 1000000)
  if okay then seed = Puzzle.mix(seed, r) end
  return Puzzle.newRandom(seed)
end

local function formatTime(s)
  s = math.floor(s or 0)
  if s > 5999 then s = 5999 end   -- the field is two digits wide either side
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

local function clearHint()
  hint = nil
end

local function beginAnim()
  if puzzle.slide and #puzzle.slide > 0 then
    anim = { tiles = puzzle.slide, t = 0 }
  end
end

-- Every move the player makes invalidates a hint plan and any search in
-- flight: the plan was for a board that no longer exists.
local function afterMove(moved)
  if moved > 0 then
    beginAnim()
    if hint and hint.at ~= puzzle.moves then clearHint() end
  end
  return moved
end

local function newPuzzle(size)
  puzzle = Puzzle.new({ size = size or (puzzle and puzzle.size) or 4,
                        rand = newRand(),
                        bests = puzzle and puzzle.bests or nil })
  anim, entry, entryAge = nil, "", 0
  clearHint()
end

local function begin()
  if puzzle.state == "ready" then puzzle:start() end
end

-- ------------------------------------------------------------------ layout --

local function layout()
  local w, h = ui.w, ui.h
  local n = puzzle.size

  -- The hint strip is the first thing to go when the window is short.
  local hintH = (h - HUD_H >= 120) and 15 or 0
  local side = math.min(w - 8, h - HUD_H - hintH - 6)
  if side < 40 then side = 40 end

  local gap = math.max(2, math.floor(side / 44))
  local tile = math.floor((side - gap * (n + 1)) / n)
  if tile < 4 then tile, gap = 4, 2 end
  side = tile * n + gap * (n + 1)

  ui.side, ui.tile, ui.gap = side, tile, gap
  ui.bx = math.max(0, math.floor((w - side) / 2))
  ui.by = math.max(HUD_H, HUD_H + math.floor((h - HUD_H - hintH - side) / 2))
  ui.hintY = ui.by + side + 3
  ui.hint = hintH > 0 and (ui.hintY + 13 <= h)
end

function on.resize(w, h)
  ui.w, ui.h = w, h
  layout()
  platform.window:invalidate()
end

-- ------------------------------------------------------------------- input --

local function undoMove()
  if puzzle:undo() then
    anim = nil
    clearHint()
    return true
  end
  return false
end

-- Deals a fresh puzzle, resuming play if a round was already under way: a new
-- board is what the player asked for, not a trip back to the title screen.
local function deal(size)
  local wasReady = (puzzle.state == "ready")
  newPuzzle(size)
  if not wasReady then puzzle:start() end
end

local function cycleSize()
  local sizes = Puzzle.SIZES
  local at = 1
  for i, s in ipairs(sizes) do
    if s == puzzle.size then at = i end
  end
  deal(sizes[at % #sizes + 1])
  layout()
end

-- Commits whatever tile number has been typed so far.
local function commitEntry()
  local v = tonumber(entry)
  entry, entryAge = "", 0
  if v then
    begin()
    afterMove(puzzle:slideTile(v))
  end
end

-- Number keys are the fast way to play on a calculator -- the pad is right
-- there -- but 4x4 and 5x5 have two-digit tiles, so a digit may be the whole
-- number or the start of one. It is committed the moment no longer tile number
-- begins with what has been typed (on 4x4 there is nothing above 15, so "2" is
-- unambiguous and moves at once), and otherwise after ENTRY_TICKS or on enter.
local function typeDigit(d)
  local maxV = puzzle.cells - 1
  local cand = entry .. d
  if (tonumber(cand) or 0) > maxV then cand = d end
  if (tonumber(cand) or 0) < 1 then
    entry, entryAge = "", 0
    return
  end

  local extendable = false
  for v = 1, maxV do
    local s = tostring(v)
    if #s > #cand and string.sub(s, 1, #cand) == cand then
      extendable = true
      break
    end
  end

  entry, entryAge = cand, 0
  if not extendable then commitEntry() end
end

local function startHint()
  if puzzle.state ~= "playing" then return end

  -- A plan already in hand is free: play its next move rather than searching
  -- the same position again.
  if hint and hint.plan and hint.at == puzzle.moves and hint.plan[hint.i] then
    local cell = hint.plan[hint.i]
    hint.i = hint.i + 1
    -- Deliberately not afterMove(): that drops a plan whose move count has
    -- moved on, which is exactly what playing the hint just did.
    if puzzle:slideTo(puzzle:colOf(cell), puzzle:rowOf(cell)) > 0 then beginAnim() end
    hint.at = puzzle.moves
    local left = #hint.plan - hint.i + 1
    hint.msg = (left > 0) and ("Hint played  " .. left .. " moves left")
                          or  "Hint played  that was the last move"
    hint.tone = GREEN
    return
  end

  local solver = puzzle:newSolver(HINT_MAX_NODES)
  if solver.status == "unsupported" then
    hint = { msg = "Hint searches 3x3 and 4x4 only", tone = DIM }
  else
    hint = { solver = solver, msg = "Thinking...", tone = GOLD, at = puzzle.moves }
  end
end

local function confirm()
  local s = puzzle.state
  if s == "ready" then
    puzzle:start()
  elseif s == "paused" then
    puzzle:resume()
  elseif s == "solved" then
    newPuzzle()
    puzzle:start()
  end
end

local function togglePause()
  if puzzle.state == "playing" then
    puzzle:pause()
  elseif puzzle.state == "paused" then
    puzzle:resume()
  end
end

function on.arrowKey(key)
  entropy = Puzzle.mix(entropy, 7)
  if entry ~= "" then commitEntry() end
  begin()
  afterMove(puzzle:step(key, inverted))
  platform.window:invalidate()
end

function on.enterKey()
  entropy = Puzzle.mix(entropy, 11)
  if entry ~= "" then
    commitEntry()
  else
    confirm()
  end
  platform.window:invalidate()
end

function on.escapeKey()
  entropy = Puzzle.mix(entropy, 13)
  if entry ~= "" then
    entry, entryAge = "", 0
  else
    togglePause()
  end
  platform.window:invalidate()
end

function on.backspaceKey()
  entropy = Puzzle.mix(entropy, 17)
  if entry ~= "" then
    entry = string.sub(entry, 1, #entry - 1)
  else
    undoMove()
  end
  platform.window:invalidate()
end

function on.charIn(ch)
  ch = string.lower(ch or "")
  entropy = Puzzle.mix(entropy, #ch > 0 and string.byte(ch) or 0)

  if ch >= "0" and ch <= "9" and #ch == 1 then
    typeDigit(ch)
  elseif ch == "u" then
    undoMove()
  elseif ch == "r" then
    deal()
  elseif ch == "s" then
    cycleSize()
  elseif ch == "i" then
    inverted = not inverted
  elseif ch == "h" then
    startHint()
  elseif ch == "p" then
    togglePause()
  elseif ch == " " then
    confirm()
  end

  platform.window:invalidate()
end

-- Clicking a tile slides it, and a tile in line with the gap but not next to
-- it takes the whole run between them along -- which is what this puzzle has
-- always done and what people reach for without being told.
function on.mouseDown(x, y)
  entropy = Puzzle.mix(Puzzle.mix(entropy, x), y)
  if entry ~= "" then entry, entryAge = "", 0 end

  if puzzle.state ~= "playing" and puzzle.state ~= "ready" then
    confirm()
  else
    local gx = math.floor((x - ui.bx - ui.gap) / (ui.tile + ui.gap)) + 1
    local gy = math.floor((y - ui.by - ui.gap) / (ui.tile + ui.gap)) + 1
    if gx >= 1 and gx <= puzzle.size and gy >= 1 and gy <= puzzle.size then
      begin()
      afterMove(puzzle:slideTo(gx, gy))
    elseif puzzle.state == "ready" then
      confirm()
    end
  end
  platform.window:invalidate()
end

-- --------------------------------------------------------------- lifecycle --

newPuzzle(4)
layout()
timer.start(BASE_TICK)

local ticks = 0

function on.timer()
  ticks = ticks + 1
  entropy = Puzzle.mix(entropy, 1)
  local dirty = false

  if anim then
    anim.t = anim.t + 1
    if anim.t >= SLIDE_TICKS then anim = nil end
    dirty = true
  end

  if puzzle.state == "playing" then
    puzzle:advance(BASE_TICK)
    if ticks % SECOND_TICKS == 0 then dirty = true end
  end

  if entry ~= "" then
    entryAge = entryAge + 1
    if entryAge >= ENTRY_TICKS then commitEntry() end
    dirty = true
  end

  -- One slice of the hint search per tick, never the whole thing: running it
  -- to completion here would freeze the screen and queue up keypresses, which
  -- a player reads as a crash.
  if hint and hint.solver then
    local status = hint.solver:think(HINT_NODES_PER_TICK)
    if status == "thinking" then
      hint.msg = "Thinking...  " .. hint.solver.nodes .. " nodes"
    elseif status == "solved" then
      hint.plan, hint.i, hint.solver = hint.solver.path, 1, nil
      hint.msg, hint.tone = "Solution found: " .. #hint.plan .. " moves", GREEN
      startHint()   -- play the first move straight away
    else
      hint.solver = nil
      hint.msg, hint.tone = "No solution found in budget", RED
    end
    dirty = true
  end

  if dirty then platform.window:invalidate() end
end

function on.deactivate()
  puzzle:pause()
  platform.window:invalidate()
end

-- ----------------------------------------------------------------- drawing --

local function cellX(gx) return ui.bx + ui.gap + (gx - 1) * (ui.tile + ui.gap) end
local function cellY(gy) return ui.by + ui.gap + (gy - 1) * (ui.tile + ui.gap) end

-- One font for every tile on the board, chosen from the *widest* label rather
-- than from each label in turn. Fitting "1" and "24" independently would set
-- them at different sizes and the grid would come out visibly ragged, which is
-- the same trap Wordle's keyboard hits with I and W.
local fontCache = {}

-- Returns the font size to set, or nil when even the smallest one would spill
-- out of the tile -- which happens on a 5x5 squeezed into the computer
-- software's smallest window. Dropping the digits there is the graceful
-- degradation: the Nspire would otherwise draw them over the neighbours with
-- no complaint, and a 10px cell says more by its colour than by "24" smeared
-- across two tiles.
local function boardFont(gc, maxV, box)
  local key = box .. "/" .. maxV
  local cached = fontCache[key]
  if cached ~= nil then
    if cached then gc:setFont("sansserif", "b", cached) end
    return cached or nil
  end

  -- The padding is deliberate rather than the tightest thing that fits: at a
  -- 30px cell a 5x5's "24" measures 26px, which technically fits and looks
  -- like a mistake. Leaving room on both axes is what actually drops the
  -- two-digit boards a size.
  local chosen = false
  for _, s in ipairs(FONT_STEPS) do
    if s + 4 <= box - 4 then
      gc:setFont("sansserif", "b", s)
      local widest = 0
      for v = 1, maxV do
        local w = gc:getStringWidth(tostring(v))
        if w > widest then widest = w end
      end
      if widest <= box - 6 then
        chosen = s
        break
      end
    end
  end

  fontCache[key] = chosen
  if chosen then gc:setFont("sansserif", "b", chosen) end
  return chosen or nil
end

-- home marks the tile as already in its final position, which is one
-- comparison per tile and reads as progress at a glance.
local function drawTile(gc, px, py, size, value, home)
  col(gc, home and TILE_HOME or TILE)
  gc:fillRect(px, py, size, size)
  if size < 10 then return end   -- no room for digits
  if not boardFont(gc, puzzle.cells - 1, size) then return end

  local text = tostring(value)
  col(gc, TILE_INK)
  gc:drawString(text,
    px + math.floor((size - gc:getStringWidth(text)) / 2),
    py + math.floor((size - gc:getStringHeight(text)) / 2), "top")
end

local function drawBoard(gc)
  local n = puzzle.size

  col(gc, BOARD_BG)
  gc:fillRect(ui.bx, ui.by, ui.side, ui.side)

  col(gc, CELL)
  for y = 1, n do
    for x = 1, n do
      gc:fillRect(cellX(x), cellY(y), ui.tile, ui.tile)
    end
  end

  -- Mid-slide the grid already holds the result, so a moving tile is drawn on
  -- the way to the cell it now occupies. Everything not in the slide is drawn
  -- where it sits.
  local flight
  if anim then
    flight = {}
    for _, m in ipairs(anim.tiles) do
      flight[(m.toY - 1) * n + m.toX] = m
    end
  end

  for y = 1, n do
    for x = 1, n do
      local i = (y - 1) * n + x
      local v = puzzle.tiles[i]
      if v ~= 0 then
        local m = flight and flight[i]
        if m then
          local p = anim.t / SLIDE_TICKS
          local fx, fy = cellX(m.fromX), cellY(m.fromY)
          local tx, ty = cellX(m.toX), cellY(m.toY)
          drawTile(gc, math.floor(fx + (tx - fx) * p),
                       math.floor(fy + (ty - fy) * p), ui.tile, v, v == i)
        else
          drawTile(gc, cellX(x), cellY(y), ui.tile, v, v == i)
        end
      end
    end
  end
end

local function drawHud(gc)
  col(gc, HUD_BG)
  gc:fillRect(0, 0, ui.w, HUD_H)
  col(gc, HUD_RULE)
  gc:drawLine(0, HUD_H - 1, ui.w, HUD_H - 1)

  local title = puzzle.size .. "x" .. puzzle.size
  gc:setFont("sansserif", "b", 12)
  local titleW = gc:getStringWidth(title)

  local best = puzzle:best()
  local bestText = "--"
  if best then
    bestText = (best.moves or 0) .. " / " .. formatTime(best.seconds)
  end

  gc:setFont("sansserif", "r", 10)

  -- Drop fields rather than assume the whole line fits: a long solve in a
  -- narrow window is exactly when the Nspire would clip it without a word.
  local stats, statsX
  for _, candidate in ipairs({
    "Moves " .. puzzle.moves .. "   " .. formatTime(puzzle.elapsed) .. "   Best " .. bestText,
    "Moves " .. puzzle.moves .. "   " .. formatTime(puzzle.elapsed),
    puzzle.moves .. "   " .. formatTime(puzzle.elapsed),
  }) do
    stats = candidate
    statsX = ui.w - gc:getStringWidth(candidate) - 8
    if statsX > titleW + 12 then break end
  end

  if statsX > titleW + 12 then
    gc:setFont("sansserif", "b", 12)
    col(gc, GOLD)
    gc:drawString(title, 6, 3, "top")
    gc:setFont("sansserif", "r", 10)
  end

  col(gc, TEXT)
  gc:drawString(stats, math.max(4, statsX), 5, "top")
end

-- The strip under the board says one thing at a time, in priority order: what
-- the player is halfway through typing, then whatever the hint search has to
-- report, then the controls. Each degrades to a shorter form rather than
-- assuming the full line fits at whatever width the font turns out to be.
local function drawStrip(gc)
  if not ui.hint then return end
  gc:setFont("sansserif", "r", 9)

  local lines, tone
  if entry ~= "" then
    lines, tone = { "Tile " .. entry .. "_   enter to move", "Tile " .. entry .. "_" }, GOLD
  elseif hint and hint.msg then
    lines, tone = { hint.msg }, hint.tone or DIM
  else
    lines, tone = {
      ARROW_HELP[inverted] .. "    digits move a tile    U undo    H hint",
      ARROW_HELP[inverted] .. "    U undo    H hint",
      ARROW_HELP[inverted],
    }, DIM
  end

  col(gc, tone)
  for _, text in ipairs(lines) do
    local w = gc:getStringWidth(text)
    if w <= ui.w - 8 then
      gc:drawString(text, math.floor((ui.w - w) / 2), ui.hintY, "top")
      return
    end
  end
end

-- lines: array of { text, highlight }. Mirrors 2048's overlay panels.
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
  -- Clamp to the window: the handheld is always big enough, but the computer
  -- software can be resized smaller than the panel's natural size and the
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
    col(gc, l[2] and TEXT or DIM)
    gc:drawString(l[1], bx + math.floor((bw - gc:getStringWidth(l[1])) / 2), y, "top")
    y = y + lineH
  end
end

local function drawOverlay(gc)
  local s = puzzle.state
  if s == "ready" then
    drawPanel(gc, "SLIDE", {
      { "Put 1-" .. (puzzle.cells - 1) .. " back in order" },
      { ARROW_HELP[inverted] },
      { "Digits move a tile; a click slides one" },
      { "S size    I invert arrows    H hint" },
      { "Press enter to start", true },
    }, GOLD)
  elseif s == "paused" then
    drawPanel(gc, "PAUSED", {
      { "Moves " .. puzzle.moves .. "     " .. formatTime(puzzle.elapsed) },
      { "Press enter to resume", true },
    }, { 240, 190, 70 })
  elseif s == "solved" then
    local best = puzzle:best() or {}
    drawPanel(gc, "SOLVED!", {
      { puzzle.moves .. " moves in " .. formatTime(puzzle.elapsed) },
      { "Best at " .. puzzle.size .. "x" .. puzzle.size .. ": "
        .. (best.moves or puzzle.moves) .. " moves, " .. formatTime(best.seconds) },
      { "S changes size    U takes a move back" },
      { "Press enter for a new puzzle", true },
    }, GREEN)
  end
end

function on.paint(gc)
  col(gc, PAGE_BG)
  gc:fillRect(0, 0, ui.w, ui.h)
  drawBoard(gc)
  drawHud(gc)
  drawStrip(gc)
  drawOverlay(gc)
end
