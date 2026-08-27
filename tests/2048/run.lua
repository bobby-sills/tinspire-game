-- Tests for the pure 2048 logic. Run with:  make GAME=2048 test
-- (or: GAME_SRC=src/2048 lua tests/2048/run.lua   from the repo root)

package.path = (os.getenv("GAME_SRC") or "src/2048") .. "/?.lua;" .. package.path
local Board = require("game")

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

-- Park-Miller MINSTD. Chosen over the usual power-of-two LCG because the
-- spawn tests below look at the *distribution* of rand(10) and rand(k), and a
-- power-of-two LCG's low bits are far too regular to say anything useful.
-- Every product here stays under 2^53, so it is exact in Lua 5.1 doubles.
local function seededRand(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (16807 * s) % 2147483647
    return (s % n) + 1
  end
end

-- Feeds a fixed script of values to Board's rand, so a test can say exactly
-- which cell spawns and whether it is a 2 or a 4.
local function queueRand(values)
  local i = 0
  return function(n)
    i = i + 1
    local v = values[i] or 1
    return ((v - 1) % n) + 1
  end
end

local function newBoard(opts)
  opts = opts or {}
  opts.rand = opts.rand or seededRand()
  return Board.new(opts)
end

local function rowsOf(b)
  local rows = {}
  for y = 1, b.size do
    rows[y] = {}
    for x = 1, b.size do rows[y][x] = b:get(x, y) end
  end
  return rows
end

local function setGrid(b, rows)
  for y = 1, b.size do
    for x = 1, b.size do b:set(x, y, rows[y][x] or 0) end
  end
end

-- A board holding exactly `rows`, mid-game, with a clean score and no undo.
-- A scripted `opts.rand` is installed *after* construction: Board.new deals two
-- opening tiles, which would otherwise eat the front of the script.
local function boardWith(rows, opts)
  opts = opts or {}
  local b = Board.new({ rand = seededRand(1), size = opts.size })
  if opts.rand then b.rand = opts.rand end
  setGrid(b, rows)
  b.state = "playing"
  b.score, b.moves, b.prev, b.won = 0, 0, nil, false
  return b
end

local function showRows(rows)
  local out = {}
  for _, r in ipairs(rows) do out[#out + 1] = table.concat(r, ",") end
  return "[" .. table.concat(out, " | ") .. "]"
end

local function rowsEq(got, want)
  for y = 1, #want do
    for x = 1, #want[y] do
      if got[y][x] ~= (want[y][x] or 0) then return false end
    end
  end
  return true
end

local function eqRows(got, want, msg)
  if rowsEq(got, want) then
    passed = passed + 1
  else
    fail(string.format("%s: got %s, want %s", msg, showRows(got), showRows(want)))
  end
end

-- Applies `dir` and returns the board as rows with the freshly spawned tile
-- cleared, so a merge assertion is not perturbed by the new tile. Spawning
-- only ever fills a cell the move left empty, so this removal is exact.
local function moveAndStrip(b, dir)
  local changed, gained = b:move(dir)
  local rows = rowsOf(b)
  if changed and b.spawned then rows[b.spawned.y][b.spawned.x] = 0 end
  return rows, changed, gained
end

-- One row, padded to a full 4x4 board of zeros.
local function oneRow(row)
  return { row, { 0, 0, 0, 0 }, { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }
end

local function oneCol(col)
  local rows = {}
  for y = 1, 4 do rows[y] = { col[y], 0, 0, 0 } end
  return rows
end

local function isPow2(v)
  if v < 2 then return false end
  while v > 1 do
    if v % 2 ~= 0 then return false end
    v = v / 2
  end
  return true
end

-- An independent restatement of "a move exists": an empty cell, or two equal
-- orthogonal neighbours. The game itself decides by actually collapsing all
-- four directions, so agreeing with this is real evidence rather than the
-- same code checked twice.
local function hasMoveByNeighbours(b)
  for y = 1, b.size do
    for x = 1, b.size do
      local v = b:get(x, y)
      if v == 0 then return true end
      if x < b.size and b:get(x + 1, y) == v then return true end
      if y < b.size and b:get(x, y + 1) == v then return true end
    end
  end
  return false
end

-- --------------------------------------------------------------- new game --

test("2048: a new board starts with exactly two tiles", function()
  for seed = 1, 40 do
    local b = newBoard({ rand = seededRand(seed) })
    eq(b:tileCount(), 2, "seed " .. seed .. ": two starting tiles")
    eq(b.score, 0, "score starts at zero")
    eq(b.moves, 0, "move count starts at zero")
    eq(b.state, "ready", "starts on the title screen")
    ok(not b:canUndo(), "nothing to undo yet")
    for i = 1, b.cells do
      local v = b.grid[i]
      ok(v == 0 or v == 2 or v == 4, "starting tile is a 2 or a 4, got " .. v)
    end
  end
end)

test("2048: no move is accepted before the round starts", function()
  local b = boardWith(oneRow({ 2, 2, 0, 0 }))
  b.state = "ready"
  local changed = b:move("left")
  ok(not changed, "a move on the title screen does nothing")
  eq(b.moves, 0, "the turn was not spent")
end)

-- ---------------------------------------------------------------- merging --

test("2048: tiles slide to the wall without merging", function()
  local b = boardWith(oneRow({ 2, 0, 0, 4 }))
  local rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 2, 4, 0, 0 }), "left slide")
  eq(b.score, 0, "sliding alone scores nothing")

  b = boardWith(oneRow({ 2, 0, 0, 4 }))
  rows = moveAndStrip(b, "right")
  eqRows(rows, oneRow({ 0, 0, 2, 4 }), "right slide")
end)

test("2048: a pair merges into one tile worth double", function()
  local b = boardWith(oneRow({ 2, 2, 0, 0 }))
  local rows, changed, gained = moveAndStrip(b, "left")
  ok(changed, "the move changed the board")
  eqRows(rows, oneRow({ 4, 0, 0, 0 }), "2 2 -> 4")
  eq(gained, 4, "gained the merged tile's value")
  eq(b.score, 4, "score took the merged value")
end)

test("2048: each tile merges at most once per move", function()
  -- The bug this guards against collapses the row all the way to 16.
  local b = boardWith(oneRow({ 4, 4, 4, 4 }))
  local rows, _, gained = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 8, 8, 0, 0 }), "4 4 4 4 -> 8 8, never 16")
  eq(gained, 16, "two merges of 8 each")

  b = boardWith(oneRow({ 4, 4, 4, 4 }))
  rows = moveAndStrip(b, "right")
  eqRows(rows, oneRow({ 0, 0, 8, 8 }), "4 4 4 4 right -> 8 8")

  -- A merged tile must not then merge with the tile behind it.
  b = boardWith(oneRow({ 2, 2, 4, 0 }))
  rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 4, 4, 0, 0 }), "2 2 4 -> 4 4, not 8")

  b = boardWith(oneRow({ 4, 2, 2, 0 }))
  rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 4, 4, 0, 0 }), "4 2 2 -> 4 4, not 8")

  b = boardWith(oneRow({ 8, 8, 8, 8 }))
  rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 16, 16, 0, 0 }), "8 8 8 8 -> 16 16")
end)

test("2048: merge order follows the direction of travel", function()
  local b = boardWith(oneRow({ 4, 4, 4, 0 }))
  local rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 8, 4, 0, 0 }), "4 4 4 left -> 8 4")

  b = boardWith(oneRow({ 0, 4, 4, 4 }))
  rows = moveAndStrip(b, "right")
  eqRows(rows, oneRow({ 0, 0, 4, 8 }), "4 4 4 right -> 4 8")

  -- The same asymmetry, vertically.
  b = boardWith(oneCol({ 4, 4, 4, 0 }))
  rows = moveAndStrip(b, "up")
  eqRows(rows, oneCol({ 8, 4, 0, 0 }), "4 4 4 up -> 8 4")

  b = boardWith(oneCol({ 0, 4, 4, 4 }))
  rows = moveAndStrip(b, "down")
  eqRows(rows, oneCol({ 0, 0, 4, 8 }), "4 4 4 down -> 4 8")
end)

test("2048: two independent pairs both merge", function()
  local b = boardWith(oneRow({ 2, 2, 4, 4 }))
  local rows, _, gained = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 4, 8, 0, 0 }), "2 2 4 4 -> 4 8")
  eq(gained, 12, "4 + 8")

  b = boardWith(oneRow({ 4, 4, 2, 2 }))
  rows = moveAndStrip(b, "left")
  eqRows(rows, oneRow({ 8, 4, 0, 0 }), "4 4 2 2 -> 8 4")
end)

test("2048: unequal neighbours never merge", function()
  local b = boardWith(oneRow({ 2, 4, 2, 4 }))
  local changed = b:move("left")
  ok(not changed, "2 4 2 4 has nowhere to go moving left")
  eq(b.score, 0, "no score from a move that did nothing")
end)

test("2048: every column and row moves independently", function()
  local b = boardWith({
    { 2, 2, 4, 4 },
    { 0, 0, 0, 0 },
    { 8, 0, 8, 0 },
    { 2, 4, 8, 16 },
  })
  local rows, _, gained = moveAndStrip(b, "left")
  eqRows(rows, {
    { 4, 8, 0, 0 },
    { 0, 0, 0, 0 },
    { 16, 0, 0, 0 },
    { 2, 4, 8, 16 },
  }, "each row collapsed on its own")
  eq(gained, 4 + 8 + 16, "score summed across rows")
end)

-- ------------------------------------------------------------- legal moves --

test("2048: a move that changes nothing is not a move", function()
  local b = boardWith({
    { 2, 4, 2, 4 },
    { 4, 2, 4, 2 },
    { 2, 4, 2, 4 },
    { 4, 2, 4, 2 },
  })
  local before = rowsOf(b)
  for _, dir in ipairs(Board.DIRS) do
    local changed, gained = b:move(dir)
    ok(not changed, dir .. " does not change a fully interlocked board")
    eq(gained, 0, dir .. " scored nothing")
  end
  eqRows(rowsOf(b), before, "board untouched")
  eq(b.moves, 0, "no turn was spent")
  eq(b.score, 0, "no score")
  ok(not b:canUndo(), "an illegal move leaves no undo point")
end)

test("2048: a tile spawns only after a move that changed something", function()
  local b = boardWith(oneRow({ 2, 0, 0, 0 }))
  eq(b:tileCount(), 1, "one tile to start")

  ok(not b:move("left"), "already flush left: nothing changes")
  eq(b:tileCount(), 1, "no spawn after an illegal move")

  ok(b:move("right"), "moving right does change the board")
  eq(b:tileCount(), 2, "exactly one tile spawned")
  ok(b.spawned ~= nil, "the spawn was recorded")
  eq(b:get(b.spawned.x, b.spawned.y), b.spawned.value, "spawn landed where it says")
end)

test("2048: wouldChange agrees with actually moving", function()
  local rand = seededRand(99)
  for trial = 1, 400 do
    local rows = {}
    for y = 1, 4 do
      rows[y] = {}
      for x = 1, 4 do
        local r = rand(6)
        rows[y][x] = (r == 1) and 0 or 2 ^ rand(5)
      end
    end
    for _, dir in ipairs(Board.DIRS) do
      local probe = boardWith(rows)
      local predicted = probe:wouldChange(dir)
      local actual = boardWith(rows):move(dir)
      if predicted ~= actual then
        return fail(string.format("trial %d %s: wouldChange said %s, move said %s on %s",
          trial, dir, tostring(predicted), tostring(actual), showRows(rows)))
      end
    end
  end
  passed = passed + 1
end)

-- -------------------------------------------------------------- game over --

test("2048: a full board is not automatically game over", function()
  local b = boardWith({
    { 2, 4, 2, 4 },
    { 4, 2, 4, 2 },
    { 2, 4, 2, 4 },
    { 4, 2, 4, 4 }, -- one equal pair, bottom right
  })
  eq(b:emptyCount(), 0, "the board is full")
  ok(b:canMove(), "a full board with an equal pair still has a move")
  ok(b:move("right"), "and that move works")
end)

test("2048: game over means no direction changes the board", function()
  local b = boardWith({
    {  2,  4,  2,  4 },
    {  4,  2,  4,  2 },
    {  2,  4,  2,  4 },
    {  4,  2,  4,  2 },
  })
  ok(not b:canMove(), "interlocked board has no move")
  for _, dir in ipairs(Board.DIRS) do
    ok(not b:wouldChange(dir), dir .. " changes nothing")
  end
end)

-- A full board whose only legal move is `left`, and whose single merge frees
-- exactly one cell -- which the spawn then fills with a 4, interlocking the
-- whole board. Used by the game-over and undo-rescue tests below.
local DOOMED = {
  { 2, 4, 4, 2 },
  { 4, 2, 4, 2 },
  { 2, 4, 2, 4 },
  { 4, 2, 4, 2 },
}
-- rand script: the one empty cell, then a draw of 1, which spawns a 4.
local function doomedRand() return queueRand({ 1, 1 }) end

test("2048: the round ends the moment the last move is used up", function()
  local b = boardWith(DOOMED, { rand = doomedRand() })
  eq(b:emptyCount(), 0, "the board starts full")
  ok(b:canMove(), "but it still has a move")

  ok(b:move("left"), "the merge is legal")
  eqRows(rowsOf(b), {
    { 2, 8, 2, 4 },
    { 4, 2, 4, 2 },
    { 2, 4, 2, 4 },
    { 4, 2, 4, 2 },
  }, "merged, then the spawn filled the only gap")
  eq(b.state, "over", "and it left no move behind")
  ok(not b:canMove(), "confirmed: nothing moves")
end)

test("2048: canMove agrees with the neighbour rule on random boards", function()
  local rand = seededRand(4242)
  for trial = 1, 3000 do
    local rows = {}
    for y = 1, 4 do
      rows[y] = {}
      for x = 1, 4 do
        -- Weighted towards full boards, where the two rules can disagree.
        local r = rand(12)
        rows[y][x] = (r == 1) and 0 or 2 ^ rand(4)
      end
    end
    local b = boardWith(rows)
    if b:canMove() ~= hasMoveByNeighbours(b) then
      return fail(string.format("trial %d: canMove=%s neighbours=%s on %s",
        trial, tostring(b:canMove()), tostring(hasMoveByNeighbours(b)), showRows(rows)))
    end
  end
  passed = passed + 1
end)

-- ---------------------------------------------------------------- spawning --

test("2048: spawn picks the k-th empty cell in row-major order", function()
  local b = boardWith({
    { 2, 0, 0, 0 },
    { 0, 0, 0, 0 },
    { 0, 0, 0, 0 },
    { 0, 0, 0, 0 },
  }, { rand = queueRand({ 3, 2 }) }) -- 3rd empty cell, then "not a 4"
  b:spawn()
  -- Empties are (2,1) (3,1) (4,1) ... so the 3rd is (4,1).
  eq(b:get(4, 1), 2, "landed on the third empty cell")
  eq(b.spawned.x, 4, "recorded x")
  eq(b.spawned.y, 1, "recorded y")
end)

test("2048: spawn value is 4 exactly when the second draw comes up 1", function()
  local b = boardWith(oneRow({ 2, 0, 0, 0 }), { rand = queueRand({ 1, 1 }) })
  b:spawn()
  eq(b.spawned.value, 4, "draw of 1 gives a 4")

  b = boardWith(oneRow({ 2, 0, 0, 0 }), { rand = queueRand({ 1, 2 }) })
  b:spawn()
  eq(b.spawned.value, 2, "any other draw gives a 2")
end)

test("2048: spawns are about 90% twos and land on every empty cell", function()
  local rand = seededRand(2024)
  local fours, total = 0, 0
  local cellHits = {}
  for i = 1, 16 do cellHits[i] = 0 end

  for _ = 1, 20000 do
    local b = boardWith({ { 0, 0, 0, 0 }, { 0, 0, 0, 0 },
                          { 0, 0, 0, 0 }, { 0, 0, 0, 0 } }, { rand = rand })
    b:spawn()
    total = total + 1
    if b.spawned.value == 4 then fours = fours + 1 end
    local idx = (b.spawned.y - 1) * 4 + b.spawned.x
    cellHits[idx] = cellHits[idx] + 1
  end

  local rate = fours / total
  ok(rate > 0.085 and rate < 0.115,
    string.format("4s land about a tenth of the time (got %.3f)", rate))

  local expected = total / 16
  local worst = 0
  for i = 1, 16 do
    local off = math.abs(cellHits[i] - expected) / expected
    if off > worst then worst = off end
  end
  ok(worst < 0.15,
    string.format("every cell is about equally likely (worst off by %.1f%%)", worst * 100))
end)

-- -------------------------------------------------------------------- undo --

test("2048: undo restores the board, score and move count exactly", function()
  local b = boardWith(oneRow({ 2, 2, 4, 0 }))
  local before, beforeScore = rowsOf(b), b.score

  ok(b:move("left"), "made a move")
  ok(b.score > beforeScore, "score went up")
  ok(b:canUndo(), "there is something to undo")

  ok(b:undo(), "undo succeeded")
  eqRows(rowsOf(b), before, "grid restored, spawn and all")
  eq(b.score, beforeScore, "score restored")
  eq(b.moves, 0, "move count restored")
  eq(b.state, "playing", "still playing")
  eq(b:tileCount(), 3, "the spawned tile is gone again")
end)

test("2048: undo is one level deep", function()
  local b = boardWith(oneRow({ 2, 0, 0, 0 }))
  b:move("right")
  b:move("left")
  ok(b:undo(), "first undo works")
  ok(not b:canUndo(), "there is no second undo")
  ok(not b:undo(), "and asking for one is refused")
end)

test("2048: undo rescues you from game over", function()
  local b = boardWith(DOOMED, { rand = doomedRand() })
  ok(b:move("left"), "the last legal move")
  eq(b.state, "over", "which ended the round")

  ok(b:undo(), "undo the fatal move")
  eq(b.state, "playing", "back in play")
  ok(b:canMove(), "and there is a move again")
  eqRows(rowsOf(b), DOOMED, "the board is the one from before the move")
end)

test("2048: an illegal move does not overwrite the undo point", function()
  -- The spawn is scripted onto the 4th empty cell, (1,2), so that after the
  -- merge both tiles sit against the left wall and `left` genuinely does
  -- nothing -- otherwise the new tile would make it legal again.
  local start = {
    { 2, 0, 0, 0 },
    { 2, 0, 0, 0 },
    { 0, 0, 0, 0 },
    { 0, 0, 0, 0 },
  }
  local b = boardWith(start, { rand = queueRand({ 4, 2 }) })

  ok(b:move("up"), "a real move")
  eqRows(rowsOf(b), {
    { 4, 0, 0, 0 },
    { 2, 0, 0, 0 },
    { 0, 0, 0, 0 },
    { 0, 0, 0, 0 },
  }, "merged, and the spawn landed below it")

  ok(not b:move("left"), "then a move that changes nothing")
  ok(b:canUndo(), "the undo point survived")
  ok(b:undo(), "undo works")
  eqRows(rowsOf(b), start, "and it undid the real move, not the no-op")
  eq(b.score, 0, "the merge's score came back too")
end)

-- --------------------------------------------------------------- win state --

test("2048: reaching 2048 wins, and play can continue", function()
  local b = boardWith(oneRow({ 1024, 1024, 0, 0 }))
  ok(b:move("left"), "merged to 2048")
  eq(b:maxTile(), 2048, "the tile is there")
  eq(b.state, "won", "which is a win")

  b:keepPlaying()
  eq(b.state, "playing", "and the player can carry on")
  ok(b:move("right"), "moves still work past the win")
  eq(b.state, "playing", "the win panel does not come back")
end)

test("2048: undoing the winning move takes the win back", function()
  local b = boardWith(oneRow({ 1024, 1024, 0, 0 }))
  b:move("left")
  b:undo()
  eq(b.state, "playing", "state restored")
  ok(not b.won, "the win flag was rolled back too")
end)

-- ------------------------------------------------------------------- fuzz --

test("2048: invariants hold across thousands of random moves", function()
  local rand = seededRand(31337)
  local rounds, totalMoves = 0, 0

  for game = 1, 60 do
    local b = newBoard({ rand = rand })
    b:start()
    rounds = rounds + 1
    local lastScore = 0

    for _ = 1, 400 do
      if b.state == "won" then b:keepPlaying() end
      if b.state ~= "playing" then break end

      local before = rowsOf(b)
      local tilesBefore = b:tileCount()
      local occupiedBefore = {}
      for y = 1, 4 do
        for x = 1, 4 do
          if before[y][x] ~= 0 then occupiedBefore[(y - 1) * 4 + x] = before[y][x] end
        end
      end

      local dir = Board.DIRS[rand(4)]
      local predicted = b:wouldChange(dir)
      local changed, gained = b:move(dir)
      local after = rowsOf(b)

      eq(changed, predicted, "wouldChange predicted the outcome")

      if not changed then
        if not rowsEq(after, before) then
          return fail("board changed on an illegal move: " .. showRows(after))
        end
        eq(gained, 0, "an illegal move scores nothing")
        eq(b.score, lastScore, "score untouched")
      else
        totalMoves = totalMoves + 1
        if rowsEq(after, before) then
          return fail("board unchanged on a move reported as legal")
        end

        -- Score never decreases, and rises by exactly what the merges were
        -- worth.
        if b.score < lastScore then return fail("score went backwards") end
        eq(b.score - lastScore, gained, "score rose by the reported gain")
        local mergeSum = 0
        for _, m in ipairs(b.merges) do mergeSum = mergeSum + m.value end
        eq(gained, mergeSum, "the gain is the sum of the merged tiles")
        lastScore = b.score

        -- Every tile that existed before the move went somewhere, exactly
        -- once, and the count moves by merges consumed minus the one spawn.
        eq(#b.slide, tilesBefore, "every pre-move tile is accounted for")
        for _, m in ipairs(b.slide) do
          local key = (m.fromY - 1) * 4 + m.fromX
          if occupiedBefore[key] ~= m.value then
            return fail("slide claims a tile that was not there")
          end
          if m.toX < 1 or m.toX > 4 or m.toY < 1 or m.toY > 4 then
            return fail("slide leaves the board")
          end
        end
        ok(b.spawned ~= nil, "a legal move always leaves room to spawn")
        eq(b:tileCount(), tilesBefore - #b.merges + 1, "tile count adds up")
      end

      -- Structural invariants that must hold after every single move.
      local tiles = 0
      for y = 1, 4 do
        for x = 1, 4 do
          local v = after[y][x]
          if v ~= 0 then
            tiles = tiles + 1
            if not isPow2(v) then
              return fail("tile " .. tostring(v) .. " is not a power of two")
            end
            if v < 2 then return fail("tile below 2: " .. tostring(v)) end
          end
        end
      end
      if tiles > 16 then return fail("more than 16 tiles: " .. tiles) end
      if tiles < 1 then return fail("board emptied itself") end

      if b.state == "over" and b:canMove() then
        return fail("declared over while a move remains")
      end
      if b.state == "playing" and not b:canMove() then
        return fail("still playing with no move left")
      end
    end
  end

  ok(totalMoves > 2000, "played a real workout (" .. totalMoves .. " legal moves)")
  ok(rounds == 60, "finished every round")
end)

test("2048: undo is exact under fuzzing", function()
  local rand = seededRand(777)
  local undone = 0

  for _ = 1, 40 do
    local b = newBoard({ rand = rand })
    b:start()
    for _ = 1, 120 do
      if b.state == "won" then b:keepPlaying() end
      if b.state ~= "playing" then break end

      local snapshot = rowsOf(b)
      local score, moves = b.score, b.moves
      local dir = Board.DIRS[rand(4)]

      if b:move(dir) then
        if rand(3) == 1 then
          ok(b:undo(), "undo available right after a move")
          if not rowsEq(rowsOf(b), snapshot) then
            return fail("undo did not restore the grid")
          end
          eq(b.score, score, "undo restored the score")
          eq(b.moves, moves, "undo restored the move count")
          undone = undone + 1
          b:move(dir) -- replay it so the round keeps advancing
        end
      end
    end
  end

  ok(undone > 200, "exercised undo a lot (" .. undone .. " times)")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
