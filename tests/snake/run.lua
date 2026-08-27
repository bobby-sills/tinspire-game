-- Tests for the pure game logic. Run with:  make test
-- (or: lua tests/run.lua   from the repo root)

package.path = (os.getenv("GAME_SRC") or "src/snake") .. "/?.lua;" .. package.path
local Game = require("game")

-- ------------------------------------------------------------- framework --

local passed, failed = 0, 0
local current = "?"

local function fail(msg)
  failed = failed + 1
  print(string.format("  FAIL  [%s] %s", current, msg))
end

local function ok(cond, msg)
  if cond then passed = passed + 1 else fail(msg) end
end

local function eq(got, want, msg)
  if got == want then
    passed = passed + 1
  else
    fail(string.format("%s: got %s, want %s", msg, tostring(got), tostring(want)))
  end
end

local function test(name, fn)
  current = name
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- helpers --

-- Deterministic RNG so tests never flake on food placement.
local function seededRand(seed)
  local s = seed or 12345
  return function(n)
    s = (1103515245 * s + 12345) % 2147483648
    return (s % n) + 1
  end
end

local function newGame(cols, rows, opts)
  opts = opts or {}
  opts.rand = opts.rand or seededRand()
  return Game.new(cols or 30, rows or 20, opts)
end

-- Replaces the snake with an explicit head-first list of cells.
local function setSnake(g, cells)
  g.cells, g.occupied = {}, {}
  g.head, g.tail = 0, 1
  for i = #cells, 1, -1 do
    g:pushFront(cells[i][1], cells[i][2])
  end
end

-- Drops food directly in front of the head and steps into it.
local function feed(g)
  local h = g.cells[g.head]
  g.food = { x = h.x + g.dir.x, y = h.y + g.dir.y }
  g:step()
end

-- Structural invariants that must hold after every single move.
local function checkInvariants(g, label)
  local walked = 0
  for i = g.head, g.tail, -1 do
    local c = g.cells[i]
    if not c then return fail(label .. ": missing cell at " .. i) end
    if not g.occupied[g:cellKey(c.x, c.y)] then
      return fail(label .. ": cell not in occupied set")
    end
    if c.x < 1 or c.x > g.cols or c.y < 1 or c.y > g.rows then
      return fail(label .. ": cell out of bounds")
    end
    walked = walked + 1
  end

  local occupiedCount = 0
  for _ in pairs(g.occupied) do occupiedCount = occupiedCount + 1 end

  -- Equal counts also prove no cell is doubly occupied, since a self-overlap
  -- would collapse two deque entries onto one key.
  eq(occupiedCount, walked, label .. ": occupied set size")
  eq(g:length(), walked, label .. ": length matches deque")

  if g.food then
    ok(not g.occupied[g:cellKey(g.food.x, g.food.y)], label .. ": food not on snake")
    ok(g.food.x >= 1 and g.food.x <= g.cols and g.food.y >= 1 and g.food.y <= g.rows,
      label .. ": food in bounds")
  end
end

-- ------------------------------------------------------------------ tests --

test("initial state", function()
  local g = newGame(30, 20)
  eq(g:length(), Game.START_LEN, "starting length")
  eq(g.state, "ready", "starting state")
  eq(g.score, 0, "starting score")
  eq(g.level, 1, "starting level")
  ok(g.food ~= nil, "food exists at reset")
  checkInvariants(g, "initial")

  local segs = g:segments()
  eq(#segs, Game.START_LEN, "segments count")
  -- Snake starts laid out horizontally, head rightmost.
  eq(segs[1].y, segs[2].y, "starts horizontal")
  eq(segs[1].x - segs[2].x, 1, "head is ahead of the next segment")
end)

test("step moves the head and keeps length", function()
  local g = newGame(30, 20)
  g:start()
  local before = g:segments()[1]
  local len = g:length()
  g.food = nil -- keep the move from being an accidental meal
  g:step()
  local after = g:segments()[1]
  eq(after.x, before.x + 1, "head advanced right")
  eq(after.y, before.y, "head stayed on its row")
  eq(g:length(), len, "length unchanged without food")
  checkInvariants(g, "after step")
end)

test("does not step unless playing", function()
  local g = newGame(30, 20)
  local before = g:segments()[1]
  g:step() -- still "ready"
  eq(g:segments()[1].x, before.x, "ready state does not move")
  g:start(); g:pause()
  g:step()
  eq(g:segments()[1].x, before.x, "paused state does not move")
end)

test("solid walls end the game", function()
  local g = newGame(10, 10)
  g:start()
  g.food = nil
  for _ = 1, 20 do g:step() end
  eq(g.state, "over", "ran into the right wall")
end)

test("wrap mode carries the snake across the edge", function()
  local g = newGame(10, 10, { wrap = true })
  g:start()
  g.food = nil
  setSnake(g, { { 10, 5 }, { 9, 5 }, { 8, 5 } })
  g.dir = Game.DIRS.right
  g:step()
  eq(g.state, "playing", "survived the edge")
  eq(g:segments()[1].x, 1, "wrapped to column 1")
  eq(g:segments()[1].y, 5, "stayed on its row")
  checkInvariants(g, "after wrap")
end)

test("reversal is rejected, perpendicular turns accepted", function()
  local g = newGame(30, 20)
  g:start()
  eq(g:setDirection("left"), false, "cannot reverse into itself")
  eq(g:setDirection("right"), false, "no-op turn rejected")
  eq(g:setDirection("up"), true, "perpendicular turn accepted")
end)

test("queued turns apply on consecutive steps", function()
  local g = newGame(30, 20)
  g:start()
  g.food = nil
  -- Both presses land inside one tick; the second must not be read as a
  -- reversal of the first, and both must survive to be applied in order.
  ok(g:setDirection("up"), "first turn queued")
  ok(g:setDirection("left"), "second turn queued against the first")
  local start = g:segments()[1]
  g:step()
  eq(g:segments()[1].y, start.y - 1, "first step went up")
  g:step()
  eq(g:segments()[1].x, start.x - 1, "second step went left")
  checkInvariants(g, "after queued turns")
end)

test("queue is bounded", function()
  local g = newGame(30, 20)
  g:start()
  ok(g:setDirection("up"), "1st")
  ok(g:setDirection("left"), "2nd")
  ok(g:setDirection("down"), "3rd")
  eq(g:setDirection("right"), false, "4th turn refused, queue full")
end)

test("eating grows the snake and scores", function()
  local g = newGame(30, 20)
  g:start()
  local len = g:length()
  feed(g)
  eq(g.score, 10, "scored at level 1")
  eq(g.foodEaten, 1, "food counted")
  -- Growth is paid out over the following moves, so the snake reaches its
  -- new length a few steps after the bite.
  g.food = nil
  for _ = 1, Game.GROW_PER_FOOD do g:step() end
  eq(g:length(), len + Game.GROW_PER_FOOD, "grew by GROW_PER_FOOD")
  checkInvariants(g, "after eating")
end)

test("level and speed ramp with food eaten", function()
  local g = newGame(60, 40)
  g:start()
  for _ = 1, Game.FOODS_PER_LEVEL do feed(g) end
  eq(g.foodEaten, Game.FOODS_PER_LEVEL, "ate a level's worth")
  eq(g.level, 2, "levelled up")
  eq(g.score, 10 * Game.FOODS_PER_LEVEL, "all scored at level 1 rates")
  feed(g)
  eq(g.score, 10 * Game.FOODS_PER_LEVEL + 20, "next food scores at level 2")
  ok(g:ticksPerStep() >= 1, "step pace stays positive")

  local g2 = newGame(60, 40)
  ok(g2:ticksPerStep() >= g:ticksPerStep(), "higher level is not slower")
end)

test("following its own tail is legal", function()
  local g = newGame(10, 10)
  g:start()
  g.food = nil
  -- A closed 2x2 loop: the head is about to enter the cell the tail vacates.
  setSnake(g, { { 1, 1 }, { 2, 1 }, { 2, 2 }, { 1, 2 } })
  g.dir = Game.DIRS.left
  g:setDirection("down")
  g:step()
  eq(g.state, "playing", "survived entering the vacated tail cell")
  eq(g:segments()[1].x, 1, "head x")
  eq(g:segments()[1].y, 2, "head y")
  checkInvariants(g, "after tail follow")
end)

test("entering the tail cell is fatal when the tail is not vacating", function()
  local g = newGame(10, 10)
  g:start()
  g.food = nil
  setSnake(g, { { 1, 1 }, { 2, 1 }, { 2, 2 }, { 1, 2 } })
  g.dir = Game.DIRS.left
  g.growth = 1 -- pending growth pins the tail in place this move
  g:setDirection("down")
  g:step()
  eq(g.state, "over", "died on the stationary tail")
end)

test("running into its own body ends the game", function()
  local g = newGame(10, 10)
  g:start()
  g.food = nil
  -- Head at (2,2) with body wrapping around; turning up hits its own neck.
  setSnake(g, { { 2, 3 }, { 3, 3 }, { 3, 2 }, { 2, 2 }, { 1, 2 }, { 1, 3 }, { 1, 4 } })
  g.dir = Game.DIRS.left
  g:setDirection("up")
  g:step()
  eq(g.state, "over", "collided with its own body")
end)

test("death preserves the snake for the final frame", function()
  local g = newGame(10, 10)
  g:start()
  g.food = nil
  local len = g:length()
  local head = g:segments()[1]
  setSnake(g, { { 10, 5 }, { 9, 5 }, { 8, 5 }, { 7, 5 } })
  g.dir = Game.DIRS.right
  g:step()
  eq(g.state, "over", "hit the wall")
  eq(g:length(), 4, "snake left intact for rendering")
  checkInvariants(g, "after death")
  ok(head ~= nil and len > 0, "sanity")
end)

test("high score survives a reset", function()
  local g = newGame(30, 20)
  g:start()
  feed(g); feed(g)
  local scored = g.score
  ok(scored > 0, "scored something")
  g.state = "playing"
  setSnake(g, { { 30, 5 }, { 29, 5 } })
  g.dir = Game.DIRS.right
  g:step() -- wall death records the score
  eq(g.highScore, scored, "high score recorded on death")
  g:reset()
  eq(g.score, 0, "score cleared")
  eq(g.highScore, scored, "high score kept")
end)

test("food spawns in the last free cell on a full board", function()
  local g = newGame(3, 3)
  -- Occupy every cell but (1,1).
  setSnake(g, {
    { 2, 1 }, { 3, 1 }, { 3, 2 }, { 2, 2 },
    { 1, 2 }, { 1, 3 }, { 2, 3 }, { 3, 3 },
  })
  ok(g:spawnFood(), "found a spot")
  eq(g.food.x, 1, "food x is the only free cell")
  eq(g.food.y, 1, "food y is the only free cell")
end)

test("filling the board wins", function()
  local g = newGame(3, 3)
  g:start()
  setSnake(g, {
    { 2, 1 }, { 3, 1 }, { 3, 2 }, { 2, 2 },
    { 1, 2 }, { 1, 3 }, { 2, 3 }, { 3, 3 },
  })
  g.dir = Game.DIRS.left
  g.growth = 4 -- tail pinned, so this bite completes the board
  g.food = { x = 1, y = 1 }
  g:step()
  eq(g:length(), 9, "snake covers all 9 cells")
  eq(g.state, "won", "won the game")
  eq(g.food, nil, "no food left to place")
end)

test("random play holds invariants over many moves", function()
  local dirs = { "up", "down", "left", "right" }
  local rand = seededRand(99)
  local g = newGame(24, 16, { rand = rand })
  g:start()

  local deaths, moves = 0, 0
  for i = 1, 4000 do
    if g.state ~= "playing" then
      deaths = deaths + 1
      g:reset()
      g:start()
    end
    if i % 3 == 0 then g:setDirection(dirs[rand(4)]) end
    g:step()
    moves = moves + 1
    if i % 200 == 0 then checkInvariants(g, "fuzz@" .. i) end
  end
  eq(moves, 4000, "completed all moves")
  ok(deaths > 0, "random play died at least once (deaths: " .. deaths .. ")")
end)

-- Fixed order rather than pairs(), so the simulated player is reproducible.
local DIR_NAMES = { "up", "down", "left", "right" }

-- Directions that are legal to queue and survive the next move.
local function safeMoves(g)
  local h = g.cells[g.head]
  local tailCell = g.cells[g.tail]
  local vacating = (g.growth == 0) and g:length() > 1
  local last = g.queue[#g.queue] or g.dir
  local out = {}

  for _, name in ipairs(DIR_NAMES) do
    local d = Game.DIRS[name]
    local reversal = g:length() > 1 and d.x == -last.x and d.y == -last.y
    if not reversal then
      local nx, ny = h.x + d.x, h.y + d.y
      local inBounds = true
      if g.wrap then
        if nx < 1 then nx = g.cols elseif nx > g.cols then nx = 1 end
        if ny < 1 then ny = g.rows elseif ny > g.rows then ny = 1 end
      elseif nx < 1 or nx > g.cols or ny < 1 or ny > g.rows then
        inBounds = false
      end
      if inBounds then
        local blocked = g.occupied[g:cellKey(nx, ny)]
        if blocked and vacating and nx == tailCell.x and ny == tailCell.y then
          blocked = false
        end
        if not blocked then out[#out + 1] = { name = name, x = nx, y = ny } end
      end
    end
  end
  return out
end

test("greedy play grows a long snake safely", function()
  local rand = seededRand(7)
  local g = newGame(16, 12, { rand = rand })
  g:start()

  local maxLen, steps = 0, 0
  for i = 1, 4000 do
    if g.state ~= "playing" then break end

    -- Of the moves that don't kill us, take the one closest to the food.
    local moves = safeMoves(g)
    if #moves > 0 then
      local f = g.food
      local best, bestDist = moves[1], nil
      if f then
        for _, m in ipairs(moves) do
          local dist = math.abs(f.x - m.x) + math.abs(f.y - m.y)
          if not bestDist or dist < bestDist then best, bestDist = m, dist end
        end
      end
      g:setDirection(best.name)
    end

    g:step()
    steps = steps + 1
    if g:length() > maxLen then maxLen = g:length() end
    if i % 100 == 0 then checkInvariants(g, "greedy@" .. i) end
  end

  -- A player that avoids obvious death should fill a good share of the
  -- 16x12 board, which is what drives spawnFood onto its dense-board path.
  ok(maxLen > 40, "snake grew long (max: " .. maxLen .. " over " .. steps .. " steps)")
  checkInvariants(g, "greedy final")
end)

-- ----------------------------------------------------------------- report --

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
