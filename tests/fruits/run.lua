-- Tests for the pure match-three logic. Run with:  make GAME=fruits test
-- (or: GAME_SRC=src/fruits lua tests/fruits/run.lua   from the repo root)
--
-- There are three headline claims in this file.
--
-- The first is that a fresh board is never already matching and never already
-- dead. The fill in `Fruit:dealCells` makes the first unrepresentable rather
-- than merely rejected, so nothing in the game ever scans a fresh board for
-- runs -- and `Fruit.scanRuns`, a naive from-the-definition scanner that
-- shares no code with any of it, is what has to agree. Same for the second
-- property and `Fruit.allLegalSwaps`, a brute force that tries every swap and
-- rescans the whole board. Neither oracle is trusted on its own: both are
-- first pinned against boards whose answer is known by construction, because
-- a backwards oracle agreeing with a backwards generator proves nothing.
--
-- The second is the trap that sits right next to the first. Fruit falling in
-- after a clear ARE allowed to match -- that is what a cascade is. So the
-- tests assert not only that the fresh deal never matches, but that the
-- mid-cascade refill sometimes does. Apply the no-match fill in both places
-- and every test above still passes while cascades quietly leave the game.
--
-- The third is that resolving a cascade one tick at a time reaches the
-- identical board and the identical score as resolving it in a single call.

package.path = (os.getenv("GAME_SRC") or "src/fruits") .. "/?.lua;" .. package.path
local Fruit = require("game")

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

local function note(msg) print("  note  " .. msg) end

-- ---------------------------------------------------------------- helpers --

local COLS, ROWS, KINDS = Fruit.COLS, Fruit.ROWS, Fruit.KINDS
local CELLS = Fruit.CELLS

-- Park-Miller MINSTD, so a failing seed can be replayed exactly. Deliberately
-- not Fruit.newRandom: the tests should not be driven by the same generator
-- they are checking.
local function seededRand(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (16807 * s) % 2147483647
    return (s % n) + 1
  end
end

local function newBoard(seed, deal)
  return Fruit.new({ rand = Fruit.newRandom(seed), deal = deal })
end

-- An empty board to load a fixture into.
local function blank()
  return Fruit.new({ rand = seededRand(1), deal = false })
end

local function fromRows(rows)
  local b = blank()
  local cells = {}
  for y = 1, ROWS do
    for x = 1, COLS do cells[(y - 1) * COLS + x] = rows[y][x] end
  end
  b:loadCells(cells)
  return b
end

-- A board with NO two orthogonal neighbours alike, and so no run anywhere,
-- built out of the low four kinds only. Planting a fixture on top of it with a
-- kind of 5 or more therefore cannot accidentally extend into a neighbour --
-- which is exactly the mistake that made the first draft of the shape tests
-- below pass for the wrong reason, and then fail for the right one.
--
-- (x + 2y) mod 4 steps by 1 across and by 2 down, so neither neighbour ever
-- matches. `cleanBoard` asserts the no-run property rather than assuming it.
local PLANT = 5   -- the first kind the base pattern never uses

local function cleanBoard()
  local b = blank()
  local cells = {}
  for y = 1, ROWS do
    for x = 1, COLS do
      cells[(y - 1) * COLS + x] = ((x + 2 * y) % 4) + 1
    end
  end
  b:loadCells(cells)
  return b
end

-- A board of uniformly random fruit -- which, unlike a dealt board, is very
-- likely to contain runs. That is the point: the oracles have to agree with
-- the production code on boards the production code would never deal.
local function randomBoard(rnd)
  local b = blank()
  local cells = {}
  for i = 1, CELLS do cells[i] = rnd(KINDS) end
  b:loadCells(cells)
  return b
end

local function markedSet(b)
  local set = {}
  for i = 1, CELLS do
    if b.marked[i] then set[i] = true end
  end
  return set
end

local function sameSet(a, c)
  for i = 1, CELLS do
    if (a[i] and true or false) ~= (c[i] and true or false) then return false, i end
  end
  return true
end

local function countSet(s)
  local n = 0
  for _ in pairs(s) do n = n + 1 end
  return n
end

-- Everything a round is, flattened. Used by the tick-versus-resolve test,
-- where anything left out is a difference the test cannot see.
local function signature(b)
  local parts = { table.concat(b.cells, ",") }
  for _, k in ipairs({ "score", "moves", "badSwaps", "cleared",
                       "chain", "bestChain", "matched", "best", "lastGain" }) do
    parts[#parts + 1] = k .. "=" .. tostring(b[k])
  end
  parts[#parts + 1] = "state=" .. b.state
  parts[#parts + 1] = "phase=" .. b.phase
  return table.concat(parts, "|")
end

-- ============================================ pinning the oracles first ====
--
-- Everything below leans on these two. If they are wrong in the same
-- direction as the code they check, the whole file proves nothing, so they
-- are first held against boards whose answer follows from how they were built.

test("the fixture base really has no run and no kind to collide with", function()
  ok(KINDS >= PLANT + 2, "there are spare kinds above the base pattern's four")
  local b = cleanBoard()
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0, "no run on the base")
  ok(b:isFull(), "and it is a full, legal board")
  for i = 1, CELLS do
    if b.cells[i] >= PLANT then
      fail("the base pattern used kind " .. b.cells[i] .. ", which fixtures plant")
      return
    end
  end
  passed = passed + 1
end)

test("scanRuns finds a planted horizontal run and nothing else", function()
  local b = cleanBoard()
  b:set(3, 5, PLANT); b:set(4, 5, PLANT); b:set(5, 5, PLANT)
  local hit, n = Fruit.scanRuns(b.cells, COLS, ROWS)
  eq(n, 3, "exactly three cells are in a run")
  for _, x in ipairs({ 3, 4, 5 }) do
    ok(hit[(5 - 1) * COLS + x], "cell (" .. x .. ",5) is marked")
  end
end)

test("scanRuns finds a planted vertical run", function()
  local b = cleanBoard()
  b:set(2, 2, PLANT); b:set(2, 3, PLANT); b:set(2, 4, PLANT)
  local hit, n = Fruit.scanRuns(b.cells, COLS, ROWS)
  eq(n, 3, "three cells marked")
  for _, y in ipairs({ 2, 3, 4 }) do
    ok(hit[(y - 1) * COLS + 2], "cell (2," .. y .. ") is marked")
  end
end)

test("scanRuns counts a shared cell once", function()
  local b = cleanBoard()
  -- An L: three across row 4 and three down column 4, meeting at (4,4).
  b:set(4, 4, PLANT); b:set(5, 4, PLANT); b:set(6, 4, PLANT)
  b:set(4, 5, PLANT); b:set(4, 6, PLANT)
  local _, n = Fruit.scanRuns(b.cells, COLS, ROWS)
  eq(n, 5, "five distinct cells, not six")
end)

test("scanRuns needs three, not two", function()
  local b = cleanBoard()
  b:set(1, 1, PLANT); b:set(2, 1, PLANT)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0, "a pair is not a run")
end)

test("allLegalSwaps finds a swap that is legal by construction", function()
  local b = cleanBoard()
  -- Two of a kind either side of a gap, and the same kind sitting one cell
  -- below the gap: pushing it up completes the row. That swap is legal by
  -- construction, so the oracle must contain it.
  b:set(2, 4, PLANT); b:set(3, 4, PLANT); b:set(5, 4, PLANT); b:set(4, 5, PLANT)
  b:set(4, 4, PLANT + 1)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0,
     "nothing matches yet -- the swap is what makes the run")

  local swaps = Fruit.allLegalSwaps(b.cells, COLS, ROWS)
  local found = false
  for _, s in ipairs(swaps) do
    if s[1] == 4 and s[2] == 4 and s[3] == 4 and s[4] == 5 then found = true end
  end
  ok(found, "the constructed swap (4,4)<->(4,5) is in the oracle's list")
  ok(#swaps >= 1, "at least one legal swap")
end)

test("allLegalSwaps leaves the board exactly as it found it", function()
  local rnd = seededRand(5150)
  for _ = 1, 200 do
    local b = randomBoard(rnd)
    local before = table.concat(b.cells, ",")
    Fruit.allLegalSwaps(b.cells, COLS, ROWS)
    if table.concat(b.cells, ",") ~= before then
      fail("the oracle mutated the board it was given")
      return
    end
  end
  passed = passed + 1
end)

-- The deadlock fixture below is the one board in this file that could not be
-- written down by hand. It was found by hill-climbing offline and is proved
-- here before anything asserts on it.
local DEAD_ROWS = {
  { 2, 6, 6, 1, 7, 3, 3, 4 },
  { 5, 1, 4, 7, 5, 5, 7, 7 },
  { 3, 6, 2, 6, 3, 6, 2, 2 },
  { 7, 5, 3, 7, 4, 5, 3, 5 },
  { 3, 1, 5, 1, 5, 1, 2, 7 },
  { 7, 1, 6, 4, 3, 6, 7, 2 },
  { 5, 2, 4, 5, 7, 4, 6, 3 },
  { 4, 2, 1, 5, 5, 7, 1, 1 },
}

test("the deadlock fixture really is dead", function()
  local b = fromRows(DEAD_ROWS)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0,
     "oracle: no run already on it")
  eq(#Fruit.allLegalSwaps(b.cells, COLS, ROWS), 0,
     "oracle: no swap anywhere makes one")
  ok(b:isFull(), "and it is a full, legal board")
end)

-- ================================ production has to agree with the oracles ==

test("findMatches agrees with scanRuns over random boards", function()
  local rnd = seededRand(20240229)
  local withRuns = 0
  for i = 1, 3000 do
    local b = randomBoard(rnd)
    local n = b:findMatches()
    local hit, on = Fruit.scanRuns(b.cells, COLS, ROWS)
    if n ~= on then
      fail(string.format("board %d: production counted %d, oracle %d", i, n, on))
      return
    end
    local same, at = sameSet(markedSet(b), hit)
    if not same then
      fail(string.format("board %d: the two disagree about cell %d", i, at))
      return
    end
    if n > 0 then withRuns = withRuns + 1 end
  end
  passed = passed + 1
  note(string.format("%d of 3000 uniform-random boards had a run", withRuns))
  ok(withRuns > 1000, "most uniform-random boards do have runs, so this was a real test")
end)

test("matchesAt agrees with the oracle, cell by cell", function()
  local rnd = seededRand(616)
  for i = 1, 300 do
    local b = randomBoard(rnd)
    local hit = Fruit.scanRuns(b.cells, COLS, ROWS)
    for y = 1, ROWS do
      for x = 1, COLS do
        local want = hit[(y - 1) * COLS + x] and true or false
        if b:matchesAt(x, y) ~= want then
          fail(string.format("board %d cell (%d,%d): local scan says %s", i, x, y,
                             tostring(not want)))
          return
        end
      end
    end
  end
  passed = passed + 1
end)

test("hasMove agrees with brute force over random boards", function()
  local rnd = seededRand(8675309)
  local dead = 0
  for i = 1, 1500 do
    local b = randomBoard(rnd)
    local swaps = Fruit.allLegalSwaps(b.cells, COLS, ROWS)
    local has = b:hasMove()
    if has ~= (#swaps > 0) then
      fail(string.format("board %d: production says %s, oracle found %d swaps",
                         i, tostring(has), #swaps))
      return
    end
    if has then
      -- And the move it names must be one the oracle agrees is legal.
      local x1, y1, x2, y2 = b:findMove()
      local found = false
      for _, s in ipairs(swaps) do
        if s[1] == x1 and s[2] == y1 and s[3] == x2 and s[4] == y2 then found = true end
      end
      if not found then
        fail(string.format("board %d: findMove suggested (%d,%d)<->(%d,%d), "
                           .. "which the oracle says is not legal", i, x1, y1, x2, y2))
        return
      end
    else
      dead = dead + 1
    end
  end
  passed = passed + 1
  note(string.format("%d of 1500 uniform-random boards had no legal swap", dead))
end)

test("swapMakesMatch leaves the board untouched", function()
  local rnd = seededRand(1234)
  for _ = 1, 200 do
    local b = randomBoard(rnd)
    local before = table.concat(b.cells, ",")
    for y = 1, ROWS do
      for x = 1, COLS do
        if x < COLS then b:swapMakesMatch(x, y, x + 1, y) end
        if y < ROWS then b:swapMakesMatch(x, y, x, y + 1) end
      end
    end
    if table.concat(b.cells, ",") ~= before then
      fail("a trial swap was not undone")
      return
    end
  end
  passed = passed + 1
end)

-- =========================================================== the fresh deal ==

test("a fresh board never contains a run", function()
  for seed = 1, 400 do
    local b = newBoard(seed)
    local _, n = Fruit.scanRuns(b.cells, COLS, ROWS)
    if n ~= 0 then
      fail(string.format("seed %d dealt a board with %d cells already matching",
                         seed, n))
      return
    end
    if b:findMatches() ~= 0 then
      fail("seed " .. seed .. ": production matcher disagrees on a fresh board")
      return
    end
  end
  passed = passed + 1
end)

test("a fresh board always has a legal swap", function()
  for seed = 1, 400 do
    local b = newBoard(seed)
    if #Fruit.allLegalSwaps(b.cells, COLS, ROWS) == 0 then
      fail("seed " .. seed .. " dealt a board with no legal swap")
      return
    end
    if not b:hasMove() then
      fail("seed " .. seed .. ": production disagrees about there being a move")
      return
    end
  end
  passed = passed + 1
end)

test("a fresh board is full and legal", function()
  for seed = 1, 200 do
    local b = newBoard(seed)
    if not b:isFull() then
      fail("seed " .. seed .. " dealt a board with a hole or a bad value")
      return
    end
  end
  passed = passed + 1
end)

test("the fill excludes at most two kinds, so it can never stall", function()
  -- Directly: after filling, every cell could legally hold at least
  -- KINDS - 2 different fruits. That is what makes the fill total rather than
  -- a filter that might have to start over.
  ok(KINDS >= 3, "KINDS is at least 3, or the fill has nothing to fall back on")
  local b = newBoard(31)
  for y = 3, ROWS do
    for x = 3, COLS do
      local i = (y - 1) * COLS + x
      local banL = (b.cells[i - 1] == b.cells[i - 2]) and b.cells[i - 1] or nil
      local banU = (b.cells[i - COLS] == b.cells[i - 2 * COLS])
                   and b.cells[i - COLS] or nil
      local excluded = (banL and 1 or 0) + ((banU and banU ~= banL) and 1 or 0)
      if excluded > 2 then
        fail("more than two kinds excluded at " .. x .. "," .. y)
        return
      end
    end
  end
  passed = passed + 1
end)

test("the deterministic fallback fill is also match-free and playable", function()
  -- The path taken when an injected rand is degenerate enough that no deal
  -- ever has a move. It must still not open onto a dead or exploding board.
  local b = blank()
  b:dealCells(function() return 1 end)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0, "no run on it")
  ok(#Fruit.allLegalSwaps(b.cells, COLS, ROWS) > 0, "and there is a move")
  ok(b:isFull(), "and it is full")
end)

test("a degenerate rand still produces a playable board", function()
  local b = Fruit.new({ rand = function() return 1 end })
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0, "no run")
  ok(b:hasMove(), "has a move")
  ok(b:isFull(), "is full")
end)

-- ======================================================= the cascade refill ==

test("the mid-cascade refill is allowed to match, unlike the deal", function()
  -- The trap. If collapse ever grew a no-match fill, this would go to zero and
  -- cascades would silently leave the game while every other test still passed.
  local rnd = seededRand(4711)
  local matched = 0
  for _ = 1, 400 do
    local b = randomBoard(rnd)
    -- Punch holes, then let it refill.
    for _ = 1, 12 do
      b.cells[rnd(CELLS)] = 0
    end
    b:collapse(function(n) return rnd(n) end)
    if select(2, Fruit.scanRuns(b.cells, COLS, ROWS)) > 0 then
      matched = matched + 1
    end
  end
  note(string.format("%d of 400 refills landed on a match", matched))
  ok(matched > 20, "refills do sometimes match -- cascades are still possible")
end)

test("cascades of depth two or more actually happen in play", function()
  local depths = {}
  local deepest = 0
  for seed = 1, 60 do
    local b = newBoard(seed)
    b:start()
    for _ = 1, 40 do
      local x1, y1, x2, y2 = b:findMove()
      if not x1 then break end
      b:swap(x1, y1, x2, y2)
      local seen = 0
      while b:busy() do
        b:advance()
        if b.chain > seen then seen = b.chain end
      end
      depths[seen] = (depths[seen] or 0) + 1
      if seen > deepest then deepest = seen end
    end
  end
  local multi = 0
  for d, c in pairs(depths) do if d >= 2 then multi = multi + c end end
  note(string.format("deepest chain seen: x%d; %d moves cascaded two or deeper",
                     deepest, multi))
  ok(multi > 50, "chains of two or more are common")
  ok(deepest >= 3, "at least one chain three deep")
end)

-- ============================================================ overlapping ===

test("an L clears and scores its shared fruit exactly once", function()
  local b = cleanBoard()
  -- Prove the fixture is the shape claimed before asserting anything about it:
  -- three across and three down, meeting at (4,4), five cells in all.
  b:set(4, 4, PLANT); b:set(5, 4, PLANT); b:set(6, 4, PLANT)
  b:set(4, 5, PLANT); b:set(4, 6, PLANT)
  local hit, on = Fruit.scanRuns(b.cells, COLS, ROWS)
  eq(on, 5, "oracle: the L covers five distinct cells")
  ok(hit[(4 - 1) * COLS + 4], "oracle: the corner is one of them")

  eq(b:findMatches(), 5, "production counts the corner once, not twice")

  b.state, b.chain = "playing", 1
  local gained = b:scoreClear()
  -- 5 cells: 5 * 10, plus 2 past the third at 20 each, times the x1 chain.
  eq(gained, 5 * 10 + 2 * 20, "scored over five cells, not six")
  eq(b.cleared, 5, "five fruit cleared")
end)

test("a plus shape scores its centre once", function()
  local b = cleanBoard()
  b:set(4, 3, PLANT)
  b:set(3, 4, PLANT); b:set(4, 4, PLANT); b:set(5, 4, PLANT)
  b:set(4, 5, PLANT)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 5, "oracle: five cells")
  eq(b:findMatches(), 5, "production: five cells, centre counted once")
end)

test("two separate runs in one step are both cleared", function()
  local b = cleanBoard()
  b:set(1, 1, PLANT); b:set(2, 1, PLANT); b:set(3, 1, PLANT)
  b:set(6, 8, PLANT + 1); b:set(7, 8, PLANT + 1); b:set(8, 8, PLANT + 1)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 6, "oracle: six cells")
  eq(b:findMatches(), 6, "production: six cells across two runs")
end)

test("a run of five is one run, not three overlapping threes", function()
  local b = cleanBoard()
  for x = 2, 6 do b:set(x, 7, PLANT) end
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 5, "oracle: five cells")
  eq(b:findMatches(), 5, "production: five cells")
end)

-- =============================================================== gravity ====

test("gravity keeps the relative order of each column", function()
  local rnd = seededRand(31415)
  for iter = 1, 500 do
    local b = randomBoard(rnd)

    -- Punch holes first, THEN record what is left: the survivors are what
    -- gravity has to preserve the order of, not the original full column.
    local holes = {}
    for x = 1, COLS do holes[x] = 0 end
    for _ = 1, 20 do
      local i = rnd(CELLS)
      if b.cells[i] ~= 0 then
        b.cells[i] = 0
        local x = (i - 1) % COLS + 1
        holes[x] = holes[x] + 1
      end
    end
    local before = {}
    for x = 1, COLS do
      before[x] = {}
      for y = 1, ROWS do before[x][y] = b.cells[(y - 1) * COLS + x] end
    end

    local motion = b:collapse(function(n) return rnd(n) end)

    -- Which cells the refill created, straight from the motion record.
    local fresh = {}
    local newCount = 0
    for _, e in ipairs(motion) do
      if e.new then
        fresh[(e.toY - 1) * COLS + e.x] = true
        newCount = newCount + 1
      end
    end

    if not b:isFull() then
      fail("iteration " .. iter .. ": board is not full after collapse")
      return
    end

    local totalHoles = 0
    for x = 1, COLS do totalHoles = totalHoles + holes[x] end
    if newCount ~= totalHoles then
      fail(string.format("iteration %d: %d holes but %d new fruit",
                         iter, totalHoles, newCount))
      return
    end

    for x = 1, COLS do
      -- What survived, bottom-up, must be the old column's survivors bottom-up.
      local want = {}
      for y = ROWS, 1, -1 do
        if before[x][y] ~= 0 then want[#want + 1] = before[x][y] end
      end
      local got = {}
      for y = ROWS, 1, -1 do
        local i = (y - 1) * COLS + x
        if not fresh[i] then got[#got + 1] = b.cells[i] end
      end
      -- The survivors are however many did not get punched out.
      if #got ~= #want then
        fail(string.format("iteration %d column %d: %d survivors, expected %d",
                           iter, x, #got, #want))
        return
      end
      for k = 1, #want do
        if got[k] ~= want[k] then
          fail(string.format("iteration %d column %d: survivor %d is %d, was %d "
                             .. "-- gravity reordered the column",
                             iter, x, k, got[k], want[k]))
          return
        end
      end
      -- And every newcomer is above every survivor, never wedged among them.
      local seenSurvivor = false
      for y = ROWS, 1, -1 do
        local i = (y - 1) * COLS + x
        if fresh[i] then
          if not seenSurvivor and holes[x] > 0 then
            -- fine: newcomers stack at the top
          end
        else
          seenSurvivor = true
        end
      end
      for y = 1, ROWS - 1 do
        local above = fresh[(y - 1) * COLS + x]
        local below = fresh[y * COLS + x]
        if below and not above then
          fail(string.format("iteration %d column %d: a new fruit landed "
                             .. "underneath an old one", iter, x))
          return
        end
      end
    end
  end
  passed = passed + 1
end)

test("collapse on a full board changes nothing and moves nothing", function()
  local rnd = seededRand(2718)
  for _ = 1, 100 do
    local b = randomBoard(rnd)
    local before = table.concat(b.cells, ",")
    local motion = b:collapse(function() return 1 end)
    if table.concat(b.cells, ",") ~= before then
      fail("collapse disturbed a board with no holes")
      return
    end
    if #motion ~= 0 then
      fail("collapse reported motion on a board with no holes")
      return
    end
  end
  passed = passed + 1
end)

test("an emptied column refills completely from the top", function()
  local b = randomBoard(seededRand(11))
  for y = 1, ROWS do b.cells[(y - 1) * COLS + 3] = 0 end
  local motion = b:collapse(function() return 2 end)
  ok(b:isFull(), "the column came back full")
  local n = 0
  for _, e in ipairs(motion) do
    if e.x == 3 then
      n = n + 1
      ok(e.new, "every arrival in an emptied column is a new fruit")
      ok(e.fromY <= 0, "and it starts above the board, not inside it")
    end
  end
  eq(n, ROWS, "one arrival per row")
end)

-- ======================================================= the phase machine ===

test("the board is full and legal after every single phase", function()
  for seed = 1, 40 do
    local b = newBoard(seed)
    b:start()
    for _ = 1, 25 do
      local x1, y1, x2, y2 = b:findMove()
      if not x1 then break end
      b:swap(x1, y1, x2, y2)
      local guard = 0
      while b:busy() and guard < 500 do
        b:advance()
        guard = guard + 1
        if not b:isFull() then
          fail(string.format("seed %d: board has a hole after leaving a phase "
                             .. "(now %s)", seed, b.phase))
          return
        end
      end
    end
  end
  passed = passed + 1
end)

test("an illegal swap is played and visibly played back", function()
  local b = fromRows(DEAD_ROWS)   -- proved above: no swap here is legal
  b.state = "playing"
  local before = table.concat(b.cells, ",")

  ok(b:swap(1, 1, 2, 1), "the swap is accepted rather than silently refused")
  eq(b.phase, "swap", "and it is on screen")
  ok(table.concat(b.cells, ",") ~= before, "the fruit really did trade places")

  b:advance()
  eq(b.phase, "unswap", "no match, so it goes back -- visibly")
  eq(table.concat(b.cells, ","), before, "the board is restored")

  b:advance()
  eq(b.phase, "idle", "and then it is over")
  eq(table.concat(b.cells, ","), before, "still restored")
  eq(b.score, 0, "an illegal swap scores nothing")
  eq(b.moves, 0, "and does not count as a move")
  eq(b.badSwaps, 1, "but it is counted as a bad one")
end)

test("a legal swap counts exactly one move however long the cascade", function()
  for seed = 1, 60 do
    local b = newBoard(seed)
    b:start()
    local x1, y1, x2, y2 = b:findMove()
    ok(x1 ~= nil, "seed " .. seed .. " has an opening move")
    b:swap(x1, y1, x2, y2)
    b:resolve()
    if b.moves ~= 1 then
      fail(string.format("seed %d: one swap counted %d moves", seed, b.moves))
      return
    end
    if b.score <= 0 then
      fail("seed " .. seed .. ": a legal swap scored nothing")
      return
    end
  end
  passed = passed + 1
end)

test("swaps are refused while the machine is busy, and when not playing", function()
  local b = newBoard(64)
  ok(not b:swap(1, 1, 2, 1), "no swap before the round starts")
  b:start()
  local x1, y1, x2, y2 = b:findMove()
  ok(b:swap(x1, y1, x2, y2), "a swap on an idle board is accepted")
  ok(not b:swap(1, 1, 2, 1), "a second swap mid-cascade is refused")
  b:resolve()
  b:pause()
  ok(not b:swap(1, 1, 2, 1), "and none while paused")
end)

test("only edge neighbours can be swapped", function()
  local b = newBoard(65)
  b:start()
  ok(not b:swap(1, 1, 3, 1), "not two apart")
  ok(not b:swap(1, 1, 2, 2), "not diagonally")
  ok(not b:swap(1, 1, 1, 1), "not with itself")
  ok(not b:swap(1, 1, 0, 1), "not off the board")
  ok(not b:swap(1, 1, 1, 0), "not off the top")
  eq(b.phase, "idle", "none of them started anything")
end)

test("every phase is held for at least one tick, so all of them are seen", function()
  for _, phase in ipairs({ "swap", "unswap", "clear", "fall" }) do
    local hold = Fruit.PHASE_HOLD[phase]
    ok(hold and hold >= 1, phase .. " has a hold of at least one tick")
  end
end)

-- ================================== a tick at a time == all in one call =====

test("resolving a cascade tick by tick reaches the identical board", function()
  local function play(seed, byTicks)
    local b = newBoard(seed)
    b:start()
    for _ = 1, 30 do
      local x1, y1, x2, y2 = b:findMove()
      if not x1 then break end
      b:swap(x1, y1, x2, y2)
      if byTicks then
        local guard = 0
        while b:busy() and guard < 20000 do
          b:tick()
          guard = guard + 1
        end
        if b:busy() then error("tick loop never settled") end
      else
        b:resolve()
      end
    end
    return b
  end

  for seed = 1, 40 do
    local a, c = play(seed, false), play(seed, true)
    if signature(a) ~= signature(c) then
      fail("seed " .. seed .. ": one call and one tick at a time disagree")
      return
    end
    if a.score == 0 then
      fail("seed " .. seed .. " scored nothing, so this proved little")
      return
    end
  end
  passed = passed + 1
end)

test("pausing mid-cascade changes when it finishes, never how", function()
  for seed = 1, 25 do
    local plain = newBoard(seed)
    plain:start()
    local x1, y1, x2, y2 = plain:findMove()
    plain:swap(x1, y1, x2, y2)
    plain:resolve()

    local paused = newBoard(seed)
    paused:start()
    paused:swap(paused:findMove())
    local ticks = 0
    while paused:busy() and ticks < 20000 do
      -- Pause for a few ticks every so often; a paused tick must do nothing.
      if ticks % 7 == 0 then
        paused:pause()
        local frozen = signature(paused)
        for _ = 1, 3 do paused:tick() end
        if signature(paused) ~= frozen then
          fail("seed " .. seed .. ": the board moved while paused")
          return
        end
        paused:resume()
      end
      paused:tick()
      ticks = ticks + 1
    end

    if signature(plain) ~= signature(paused) then
      fail("seed " .. seed .. ": pausing changed the outcome")
      return
    end
  end
  passed = passed + 1
end)

test("tick does nothing at all when the machine is idle", function()
  local b = newBoard(70)
  b:start()
  local before = signature(b)
  for _ = 1, 50 do
    ok(b:tick() == false, "an idle tick reports no change")
  end
  eq(signature(b), before, "and changes nothing")
end)

-- ================================================================ scoring ===

test("the chain multiplier grows and then caps", function()
  local t = Fruit.CHAIN_MULT
  eq(Fruit.chainMult(1), t[1], "a first clear is x" .. t[1])
  for i = 2, #t do
    ok(Fruit.chainMult(i) > Fruit.chainMult(i - 1), "x" .. i .. " beats x" .. (i - 1))
  end
  eq(Fruit.chainMult(#t + 9), t[#t], "and it caps rather than running away")
  eq(Fruit.chainMult(0), t[1], "chain 0 is treated as the first clear")
  eq(Fruit.chainMult(nil), t[1], "and so is no chain at all")
end)

test("the same clear is worth more the deeper down the chain it is", function()
  local base
  for chain = 1, #Fruit.CHAIN_MULT do
    local b = newBoard(88)
    b.matched, b.chain, b.state = 3, chain, "playing"
    local gained = b:scoreClear()
    if chain == 1 then
      base = gained
      eq(gained, 30, "a plain three is worth 30")
    else
      eq(gained, base * Fruit.chainMult(chain),
         "a three at chain " .. chain .. " is the multiple")
    end
  end
end)

test("score, best and cleared all move the right way", function()
  local b = newBoard(91)
  b:start()
  eq(b.best, 0, "no best yet")
  b:swap(b:findMove())
  b:resolve()
  ok(b.score > 0, "scored something")
  eq(b.best, b.score, "best tracks the score up")
  ok(b.cleared >= 3, "cleared at least a run's worth")
end)

test("a hint costs score once, not once per repaint", function()
  local b = newBoard(93)
  b:start()
  b.score = 500
  local h = b:showHint()
  ok(h ~= nil, "there is a hint to give")
  eq(b.score, 500 - Fruit.HINT_COST, "it cost once")
  b:showHint(); b:showHint()
  eq(b.score, 500 - Fruit.HINT_COST, "asking again while it is up is free")
  ok(b:swapMakesMatch(h.x1, h.y1, h.x2, h.y2), "and the hint is a legal swap")
end)

test("a hint never drives the score below zero", function()
  local b = newBoard(94)
  b:start()
  b.score = 5
  b:showHint()
  eq(b.score, 0, "clamped at zero")
end)

-- =============================================================== deadlock ===

test("the round ends when no swap is left", function()
  local b = fromRows(DEAD_ROWS)
  b.state = "playing"
  ok(not b:hasMove(), "production agrees the fixture is dead")

  -- Drive the machine through the one transition that checks: leaving `fall`.
  b.phase, b.hold, b.chain = "fall", 1, 0
  b:advance()
  eq(b.phase, "idle", "the machine settles")
  eq(b.state, "over", "and calls the round")
end)

test("a live board is not called dead", function()
  for seed = 1, 100 do
    local b = newBoard(seed)
    b.state = "playing"
    b.phase, b.hold, b.chain = "fall", 1, 0
    b:advance()
    if b.state ~= "playing" then
      fail("seed " .. seed .. ": a playable board was declared over")
      return
    end
  end
  passed = passed + 1
end)

test("play continues until the board really is dead", function()
  local ended, longest = 0, 0
  for seed = 1, 30 do
    local b = newBoard(seed)
    b:start()
    local moves = 0
    while b.state == "playing" and moves < 4000 do
      local x1, y1, x2, y2 = b:findMove()
      if not x1 then
        fail("seed " .. seed .. ": no move, but the round is still running")
        return
      end
      b:swap(x1, y1, x2, y2)
      b:resolve()
      moves = moves + 1
    end
    if b.state == "over" then
      ended = ended + 1
      -- And when it ends, the oracle must agree there was nothing left.
      if #Fruit.allLegalSwaps(b.cells, COLS, ROWS) > 0 then
        fail("seed " .. seed .. ": ended on a board that still had a swap")
        return
      end
    end
    if moves > longest then longest = moves end
  end
  passed = passed + 1
  note(string.format("%d of 30 auto-played rounds reached deadlock; "
                     .. "longest ran %d moves", ended, longest))
end)

-- =============================================================== specials ===

local RAINBOW = Fruit.RAINBOW

-- A board in play with a fixture on it, built on the clean base so nothing
-- planted can collide with a neighbour.
local function playing()
  local b = cleanBoard()
  b.state = "playing"
  return b
end

local function countSpecials(b)
  local powers, rainbows = 0, 0
  for i = 1, CELLS do
    if b.special[i] then powers = powers + 1 end
    if b.cells[i] == RAINBOW then rainbows = rainbows + 1 end
  end
  return powers, rainbows
end

test("four in a line merges into a power fruit", function()
  -- A pair, a gap, and a single, so the row holds no run yet; the swap brings
  -- the fourth up into the gap and joins all four. Laying three in a row and
  -- adding a fourth would not work -- the three already match.
  local b = playing()
  b:set(2, 4, PLANT); b:set(3, 4, PLANT); b:set(5, 4, PLANT)
  b:set(4, 5, PLANT); b:set(4, 4, PLANT + 1)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0,
     "the fixture matches nothing until the swap")

  ok(b:swap(4, 4, 4, 5), "the swap is accepted")
  b:advance()
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 4,
     "oracle: exactly four cells in the run")
  eq(#b.spawns, 1, "one special is planned")
  eq(b.spawns[1].what, Fruit.SPAWN_POWER, "and it is a power fruit")
  eq(b.spawns[1].at, (4 - 1) * COLS + 4,
     "placed on the cell the player moved into")

  b:advance()   -- leave "clear": the merge happens here
  local powers, rainbows = countSpecials(b)
  eq(powers, 1, "one power fruit is on the board")
  eq(rainbows, 0, "and no rainbow")
  ok(b:isFull(), "the board is full")
end)

test("five in a line merges into a rainbow, not a power fruit", function()
  -- Two pairs either side of a gap: no run yet, and one fruit into the gap
  -- makes five.
  local b = playing()
  b:set(2, 4, PLANT); b:set(3, 4, PLANT)
  b:set(5, 4, PLANT); b:set(6, 4, PLANT)
  b:set(4, 5, PLANT); b:set(4, 4, PLANT + 1)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0, "nothing matches yet")

  b:swap(4, 4, 4, 5)
  b:advance()
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 5, "oracle: five in the run")
  eq(#b.spawns, 1, "one special")
  eq(b.spawns[1].what, Fruit.SPAWN_RAINBOW, "five in a LINE is a rainbow")

  b:advance()
  local powers, rainbows = countSpecials(b)
  eq(rainbows, 1, "a rainbow is on the board")
  eq(powers, 0, "and it is not also a power fruit")
end)

test("five cells in an L is a power fruit, not a rainbow", function()
  -- The distinction that is easy to get wrong: it is five in a straight LINE
  -- that makes a rainbow, not five cells cleared.
  local b = playing()
  b:set(4, 4, PLANT); b:set(5, 4, PLANT); b:set(6, 4, PLANT)
  b:set(4, 5, PLANT); b:set(4, 6, PLANT)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 5,
     "oracle: the L covers five cells")

  eq(b:findMatches(), 5, "production agrees")
  local spawns = b:planSpawns(nil, nil)
  eq(#spawns, 1, "one special from the whole L")
  eq(spawns[1].what, Fruit.SPAWN_POWER, "an L makes a power fruit")
  eq(spawns[1].at, (4 - 1) * COLS + 4, "placed on the corner, where the eye is")
end)

test("a plain three makes nothing", function()
  local b = playing()
  b:set(3, 5, PLANT); b:set(4, 5, PLANT); b:set(5, 5, PLANT)
  b:findMatches()
  eq(#b:planSpawns(nil, nil), 0, "three in a row is just three in a row")
end)

test("two separate fours make two specials", function()
  local b = playing()
  for x = 1, 4 do b:set(x, 1, PLANT) end
  for x = 5, 8 do b:set(x, 8, PLANT + 1) end
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 8, "oracle: eight cells")
  b:findMatches()
  local spawns = b:planSpawns(nil, nil)
  eq(#spawns, 2, "one special per run")
  for _, sp in ipairs(spawns) do
    eq(sp.what, Fruit.SPAWN_POWER, "both are power fruit")
  end
end)

test("a power fruit takes the eight cells around it", function()
  local b = playing()
  -- A power fruit at (4,4), then a plain three through it so it clears.
  b:set(3, 4, PLANT); b:set(4, 4, PLANT); b:set(5, 4, PLANT)
  b.special[(4 - 1) * COLS + 4] = true

  eq(b:findMatches(), 3, "the run itself is three cells")
  b._fired = nil
  local added = b:detonate()
  eq(added, 6, "the blast adds the six cells of the 3x3 not already marked")
  eq(b.matched, 9, "nine cells go in all")

  for dy = -1, 1 do
    for dx = -1, 1 do
      local i = (4 + dy - 1) * COLS + (4 + dx)
      ok(b.marked[i], string.format("cell (%d,%d) is caught in the blast",
                                    4 + dx, 4 + dy))
    end
  end
end)

test("a blast at the edge does not run off the board", function()
  local b = playing()
  b:set(1, 1, PLANT); b:set(2, 1, PLANT); b:set(3, 1, PLANT)
  b.special[1] = true
  b:findMatches()
  b._fired = nil
  b:detonate()
  local n = 0
  for i = 1, CELLS do if b.marked[i] then n = n + 1 end end
  -- The 3x3 clipped to a corner is 4 cells -- (1,1), (2,1), (1,2), (2,2) --
  -- and the run adds only (3,1), the other two already being in it.
  eq(n, 5, "corner blast plus the run, and nothing off the edge")
  ok(b:isFull(), "and nothing was corrupted")
end)

test("blasts chain through other power fruit", function()
  local b = playing()
  b:set(3, 4, PLANT); b:set(4, 4, PLANT); b:set(5, 4, PLANT)
  b.special[(4 - 1) * COLS + 4] = true    -- in the run
  b.special[(5 - 1) * COLS + 5] = true    -- in the first blast, one row down
  b:findMatches()
  b._fired = nil
  b:detonate()
  -- The second one is at (5,5); its own 3x3 reaches row 6, which the first
  -- blast never touches. That is the proof the chain actually happened.
  ok(b.marked[(6 - 1) * COLS + 5], "the second blast reached a row the first could not")
end)

test("a chain of blasts always terminates", function()
  -- Every cell a power fruit, which is the worst case for the fixpoint.
  local b = playing()
  for i = 1, CELLS do b.special[i] = true end
  b:set(3, 4, PLANT); b:set(4, 4, PLANT); b:set(5, 4, PLANT)
  b:findMatches()
  b._fired = nil
  b:detonate()
  eq(b.matched, CELLS, "it swallows the whole board, and stops")
end)

test("a rainbow is never part of a run", function()
  local b = playing()
  b:set(3, 3, RAINBOW); b:set(4, 3, RAINBOW); b:set(5, 3, RAINBOW)
  eq(select(2, Fruit.scanRuns(b.cells, COLS, ROWS)), 0,
     "oracle: three rainbows in a row are not a run")
  eq(b:findMatches(), 0, "and production agrees")
  ok(not b:matchesAt(4, 3), "nor does the local scan think so")
end)

test("spending a rainbow clears every fruit of the colour it took", function()
  local b = playing()
  b:set(4, 4, RAINBOW)
  local target = b:get(4, 5)
  local before = 0
  for i = 1, CELLS do if b.cells[i] == target then before = before + 1 end end
  ok(before >= 8, "there is a decent number of the target colour (" .. before .. ")")

  ok(b:swap(4, 4, 4, 5), "swapping a rainbow is accepted")
  b:advance()                      -- leaves "swap"
  eq(b.phase, "clear", "it goes straight to clearing, not to unswap")
  eq(b.matched, before + 1, "every one of that colour, plus the rainbow itself")

  b:resolve()
  ok(b:isFull(), "the board came back full")
  eq(b.moves, 1, "and it counted as a move")
  ok(b.score > 0, "and scored")
end)

test("two rainbows swapped together clear the whole board", function()
  local b = playing()
  b:set(4, 4, RAINBOW); b:set(5, 4, RAINBOW)
  b:swap(4, 4, 5, 4)
  b:advance()
  eq(b.matched, CELLS, "all sixty-four cells")
  b:resolve()
  ok(b:isFull(), "and the board refills completely")
end)

test("a swap touching a rainbow is always legal, to both mechanisms", function()
  local b = fromRows(DEAD_ROWS)     -- proved dead above
  eq(#Fruit.allLegalSwaps(b.cells, COLS, ROWS), 0, "dead to start with")
  ok(not b:hasMove(), "production agrees")

  b:set(4, 4, RAINBOW)
  ok(b:hasMove(), "one rainbow revives the board")
  local swaps = Fruit.allLegalSwaps(b.cells, COLS, ROWS)
  eq(#swaps, 4, "oracle: its four neighbours, and nothing else")

  local x1, y1, x2, y2 = b:findMove()
  local found = false
  for _, s in ipairs(swaps) do
    if s[1] == x1 and s[2] == y1 and s[3] == x2 and s[4] == y2 then found = true end
  end
  ok(found, "and the move production names is one of them")
end)

test("gravity carries a power fruit with its own cell", function()
  local b = playing()
  local at = (3 - 1) * COLS + 4
  b.special[at] = true
  local kind = b.cells[at]
  -- Punch the cell below it out; the power fruit must fall into the hole.
  b.cells[(4 - 1) * COLS + 4] = 0
  b.special[(4 - 1) * COLS + 4] = false
  b:collapse(function() return 1 end)

  local landed = (4 - 1) * COLS + 4
  eq(b.cells[landed], kind, "the fruit fell one row")
  ok(b.special[landed], "and it is still a power fruit")
  ok(not b.special[at], "with nothing left behind where it was")
end)

test("gravity keeps specials attached over a long fuzz", function()
  local rnd = seededRand(31337)
  for iter = 1, 300 do
    local b = randomBoard(rnd)
    -- Sprinkle specials, remember them by the fruit they sit on.
    local tagged = {}
    for _ = 1, 8 do
      local i = rnd(CELLS)
      b.special[i] = true
      tagged[i] = b.cells[i]
    end
    local before = 0
    for i = 1, CELLS do if b.special[i] then before = before + 1 end end

    for _ = 1, 10 do
      local i = rnd(CELLS)
      if not b.special[i] then b.cells[i] = 0 end   -- never punch out a special
    end
    b:collapse(function(n) return rnd(n) end)

    local after = 0
    for i = 1, CELLS do
      if b.special[i] then
        after = after + 1
        if b.cells[i] == RAINBOW then
          fail("iteration " .. iter .. ": a rainbow came out flagged as a power")
          return
        end
      end
    end
    if after ~= before then
      fail(string.format("iteration %d: %d specials went in, %d came out",
                         iter, before, after))
      return
    end
    if not b:isFull() then
      fail("iteration " .. iter .. ": board not full after collapse")
      return
    end
  end
  passed = passed + 1
end)

test("the refill never hands out a special", function()
  local rnd = seededRand(4242)
  for _ = 1, 200 do
    local b = randomBoard(rnd)
    for i = 1, CELLS do b.cells[i] = 0 end
    local motion = b:collapse(function(n) return rnd(n) end)
    for i = 1, CELLS do
      if b.special[i] then fail("the refill made a power fruit"); return end
      if b.cells[i] == RAINBOW then fail("the refill made a rainbow"); return end
    end
    eq(#motion, CELLS, "a whole board of newcomers")
  end
  passed = passed + 1
end)

test("a fresh deal never contains a special", function()
  for seed = 1, 200 do
    local b = newBoard(seed)
    local powers, rainbows = countSpecials(b)
    if powers ~= 0 or rainbows ~= 0 then
      fail(string.format("seed %d dealt %d powers and %d rainbows",
                         seed, powers, rainbows))
      return
    end
  end
  passed = passed + 1
end)

test("isFull rejects a rainbow that is also a power fruit", function()
  local b = playing()
  ok(b:isFull(), "the fixture is fine to start with")
  b:set(4, 4, RAINBOW)
  ok(b:isFull(), "a plain rainbow is fine")
  b.special[(4 - 1) * COLS + 4] = true
  ok(not b:isFull(), "but a rainbow flagged as a power is not a legal board")
end)

test("specials survive a whole round of real play", function()
  local madePower, madeRainbow, spent, biggest = 0, 0, 0, 0
  for seed = 1, 25 do
    local b = newBoard(seed)
    b:start()
    for _ = 1, 200 do
      local x1, y1, x2, y2 = b:findMove()
      if not x1 then break end
      if b:isRainbow(x1, y1) or b:isRainbow(x2, y2) then spent = spent + 1 end
      b:swap(x1, y1, x2, y2)
      while b:busy() do
        if b.phase == "clear" and b.matched > biggest then biggest = b.matched end
        for _, sp in ipairs(b.spawns or {}) do
          if sp.what == Fruit.SPAWN_POWER then madePower = madePower + 1
          else madeRainbow = madeRainbow + 1 end
        end
        b:advance()
        if not b:isFull() then
          fail("seed " .. seed .. ": board has a hole after a phase")
          return
        end
      end
    end
  end
  note(string.format("over 25 rounds: %d power fruit, %d rainbows, %d spent; "
                     .. "biggest single clear %d cells",
                     madePower, madeRainbow, spent, biggest))
  ok(madePower > 50, "power fruit are made regularly")
  ok(madeRainbow > 0, "and rainbows do appear")
  ok(spent > 0, "and get spent")
  ok(biggest > 9, "and clears get big (" .. biggest .. " cells)")
end)

-- ================================================================= levels ===

test("each level asks for more than the last", function()
  local prev = 0
  for level = 1, 12 do
    local target = Fruit.levelTarget(level)
    ok(target > prev, "level " .. level .. " wants more than level " .. (level - 1))
    prev = target
  end
  eq(Fruit.levelTarget(0), Fruit.levelTarget(1), "a bad level is treated as the first")
  eq(Fruit.levelTarget(nil), Fruit.levelTarget(1), "and so is none at all")
end)

test("clearing fruit fills the bar and then levels up", function()
  local b = newBoard(500)
  b:start()
  eq(b.level, 1, "starts on level 1")
  eq(b:levelProgress(), 0, "with an empty bar")

  b.matched, b.chain = 10, 1
  b:scoreClear()
  eq(b.level, 1, "ten fruit is not a level")
  ok(b:levelProgress() > 0, "but the bar moved")
  ok(b:levelProgress() < 1, "and is not full")

  local scoreBefore = b.score
  b.matched, b.chain = Fruit.levelTarget(1), 1
  b:scoreClear()
  eq(b.level, 2, "passing the target is a level")
  ok(b.leveledUp, "and it says so, for the host to flash")
  ok(b.score > scoreBefore, "the level bonus was paid")
end)

test("one huge clear can carry several levels at once", function()
  local b = newBoard(501)
  b:start()
  local total = Fruit.levelTarget(1) + Fruit.levelTarget(2) + Fruit.levelTarget(3)
  b.matched, b.chain = total, 1
  b:scoreClear()
  eq(b.level, 4, "three levels' worth of fruit is three levels")
  eq(b.levelCleared, 0, "with nothing left over, since it was exact")
end)

test("level progress stays inside its bar", function()
  local b = newBoard(502)
  b:start()
  for _ = 1, 200 do
    b.matched, b.chain = 7, 1
    b:scoreClear()
    local p = b:levelProgress()
    if p < 0 or p > 1 then
      fail("progress left 0..1: " .. tostring(p))
      return
    end
  end
  ok(b.level > 5, "and a lot of clearing got a long way (level " .. b.level .. ")")
end)

test("a reset puts the level back", function()
  local b = newBoard(503)
  b:start()
  b.matched, b.chain = Fruit.levelTarget(1) * 3, 1
  b:scoreClear()
  ok(b.level > 1, "levelled up")
  b:reset()
  eq(b.level, 1, "and a new round starts at level 1")
  eq(b.levelCleared, 0, "with an empty bar")
end)

test("a free hint costs nothing, a asked-for one costs", function()
  local b = newBoard(504)
  b:start()
  b.score = 500
  ok(b:showHint(true) ~= nil, "the nudge finds a move")
  eq(b.score, 500, "and is free")
  b.hint = nil
  ok(b:showHint() ~= nil, "the deliberate one finds a move too")
  eq(b.score, 500 - Fruit.HINT_COST, "and is charged for")
end)

-- ============================================================ states, RNG ===

test("the round's state machine only moves the way it should", function()
  local b = newBoard(101)
  eq(b.state, "ready", "starts ready")
  b:resume(); eq(b.state, "ready", "resume does nothing before it starts")
  b:pause();  eq(b.state, "ready", "nor does pause")
  b:start();  eq(b.state, "playing", "enter starts it")
  b:start();  eq(b.state, "playing", "and starting twice is harmless")
  b:pause();  eq(b.state, "paused", "esc pauses")
  b:resume(); eq(b.state, "playing", "and resumes")
end)

test("a reset deals a new board and clears the round", function()
  local b = newBoard(102)
  b:start()
  b:swap(b:findMove())
  b:resolve()
  local score = b.score
  ok(score > 0, "there was something to clear")
  b:reset()
  eq(b.score, 0, "score cleared")
  eq(b.moves, 0, "moves cleared")
  eq(b.state, "ready", "back to the title")
  eq(b.phase, "idle", "and the machine is idle")
  eq(b.best, score, "but the session best survives")
end)

test("newRandom stays in range and never returns the same board twice", function()
  local seen = {}
  for seed = 1, 200 do
    local r = Fruit.newRandom(seed)
    for _ = 1, 50 do
      local v = r(KINDS)
      if type(v) ~= "number" or v < 1 or v > KINDS or v ~= math.floor(v) then
        fail("seed " .. seed .. " produced " .. tostring(v))
        return
      end
    end
    local key = table.concat(newBoard(seed).cells, ",")
    if seen[key] then
      fail(string.format("seeds %d and %d deal the identical board",
                         seen[key], seed))
      return
    end
    seen[key] = seed
  end
  passed = passed + 1
end)

test("seeds a few ticks apart deal visibly different boards", function()
  -- The failure this is really about: two launches differ by only the handful
  -- of timer ticks the player idled on the title screen, and a raw LCG from a
  -- small seed returns nearly the same first values. Wordle shipped that bug.
  local first = newBoard(1).cells
  for seed = 2, 12 do
    local cells = newBoard(seed).cells
    local same = 0
    for i = 1, CELLS do
      if cells[i] == first[i] then same = same + 1 end
    end
    -- Chance alone puts about 1/7 of 64 cells -- roughly 9 -- in agreement.
    if same > 24 then
      fail(string.format("seeds 1 and %d share %d of %d cells", seed, same, CELLS))
      return
    end
  end
  passed = passed + 1
end)

test("mix folds values in and stays inside exact-integer range", function()
  local acc = 1
  for i = 1, 5000 do
    acc = Fruit.mix(acc, i * 7919)
    if acc ~= math.floor(acc) or acc < 0 or acc >= 2147483647 then
      fail("mix left the range at step " .. i .. ": " .. tostring(acc))
      return
    end
  end
  ok(Fruit.mix(nil, nil) >= 0, "mix survives nils")
  passed = passed + 1
end)

test("the game never calls its own oracles", function()
  -- The oracles are only worth something if they are genuinely a second
  -- opinion. Read the source and check.
  local path = (os.getenv("GAME_SRC") or "src/fruits") .. "/game.lua"
  local f = assert(io.open(path))
  local src = f:read("*a")
  f:close()

  -- The oracles live in one marked block. Cut it out -- definitions and the
  -- calls they make to each other included -- and the rest of the file is the
  -- game proper, which must not mention either of them.
  local from = src:find("=== oracles ===", 1, true)
  local to = src:find("-- ====================", from or 1, true)
  ok(from and to and to > from, "found the oracle block in game.lua")
  local rest = src:sub(1, from or 1) .. src:sub((to or 1) + 20)

  for _, name in ipairs({ "scanRuns", "allLegalSwaps" }) do
    local uses = 0
    for _ in rest:gmatch("[:%.]" .. name .. "%s*%(") do uses = uses + 1 end
    eq(uses, 0, name .. " is never called by the game itself")
    ok(src:find("function Fruit%." .. name), name .. " does exist to be called")
  end
end)

-- ------------------------------------------------------------------ done ---

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
