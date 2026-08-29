-- Tests for the pure sliding-puzzle logic. Run with:  make GAME=slide test
-- (or: GAME_SRC=src/slide lua tests/slide/run.lua   from the repo root)
--
-- The headline claim in this file is that the puzzle is never impossible.
-- Exactly half of all permutations of a sliding puzzle are unreachable from
-- the solved state, and the player cannot tell an unsolvable board from a hard
-- one. Two independent mechanisms have to agree about that here: the scramble,
-- which only ever makes legal moves and so cannot represent an unsolvable
-- board, and the inversion-parity oracle in Puzzle.isSolvable, which is only
-- ever used by these tests. Neither is trusted on its own -- the oracle is
-- first pinned against boards whose solvability is known by construction,
-- because a backwards oracle agreeing with a backwards shuffler proves nothing.

package.path = (os.getenv("GAME_SRC") or "src/slide") .. "/?.lua;" .. package.path
local Puzzle = require("game")

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

-- Park-Miller MINSTD, so a failing seed can be replayed exactly.
local function seededRand(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (16807 * s) % 2147483647
    return (s % n) + 1
  end
end

local SIZES = { 3, 4, 5 }

local function newPuzzle(size, seed, shuffle)
  return Puzzle.new({ size = size, rand = seededRand(seed), shuffle = shuffle })
end

-- A puzzle in play, so recorded moves are accepted.
local function playing(size, seed, shuffle)
  local p = newPuzzle(size, seed, shuffle)
  p:start()
  return p
end

local function sig(p)
  return table.concat(p.tiles, ",") .. "|" .. p.blank
end

local function solvedTiles(size)
  local t = {}
  for i = 1, size * size - 1 do t[i] = i end
  t[size * size] = 0
  return t
end

-- Every cell in line with the gap, which is every move a click could ask for.
local function legalTargets(p)
  local bx, by = p:blankXY()
  local out = {}
  for i = 1, p.size do
    if i ~= bx then out[#out + 1] = { i, by } end
    if i ~= by then out[#out + 1] = { bx, i } end
  end
  return out
end

local function randomLegalMove(p, rand)
  local targets = legalTargets(p)
  local t = targets[rand(#targets)]
  return p:slideTo(t[1], t[2]), t
end

-- ------------------------------------------------------------ the oracle --
--
-- Pinned first, against boards whose solvability follows from how they were
-- built, so the agreement tests below are worth something.

test("the parity oracle calls the solved board solvable", function()
  for _, n in ipairs(SIZES) do
    local t = solvedTiles(n)
    eq(Puzzle.inversions(t, n), 0, n .. "x" .. n .. ": solved has no inversions")
    ok(Puzzle.isSolvable(t, n), n .. "x" .. n .. ": solved is solvable")
  end

  -- The worked example from the rule itself, spelled out rather than trusted:
  -- solved 4x4 has 0 inversions with the gap on the bottom row, so the row
  -- counted from the bottom is 1, and 0 + 1 = 1 is odd, therefore solvable.
  local t = solvedTiles(4)
  eq(Puzzle.inversions(t, 4), 0, "solved 4x4 inversions")
  eq(t[16], 0, "solved 4x4 keeps the gap in the last cell")
  ok((0 + 1) % 2 == 1, "0 inversions + bottom row 1 is odd")
  ok(Puzzle.isSolvable(t, 4), "...so the oracle must call it solvable")
end)

test("the parity oracle counts inversions the way the rule means", function()
  -- 3x3 read row by row as 1 2 3 4 5 6 8 7 (gap skipped): one pair out of
  -- order, so one inversion.
  local t = { 1, 2, 3, 4, 5, 6, 8, 7, 0 }
  eq(Puzzle.inversions(t, 3), 1, "one swapped pair is one inversion")

  -- Fully reversed 1..8 has every pair out of order: 8*7/2 = 28.
  local rev = { 8, 7, 6, 5, 4, 3, 2, 1, 0 }
  eq(Puzzle.inversions(rev, 3), 28, "a reversed row-major reading is all pairs")

  -- The gap is skipped, so moving it about cannot change the count.
  eq(Puzzle.inversions({ 0, 1, 2, 3, 4, 5, 6, 8, 7 }, 3), 1, "the gap is not counted")
end)

test("a single swap of two tiles flips solvability at every size", function()
  -- One transposition changes the permutation's parity, and on an odd-width
  -- board that alone decides it; on 4x4 the gap has not moved, so the row term
  -- is unchanged and the parity flip carries through there too.
  for _, n in ipairs(SIZES) do
    local t = solvedTiles(n)
    t[1], t[2] = t[2], t[1]
    ok(not Puzzle.isSolvable(t, n), n .. "x" .. n .. ": one swap is unsolvable")
    t[3], t[4] = t[4], t[3]
    ok(Puzzle.isSolvable(t, n), n .. "x" .. n .. ": a second swap is solvable again")
  end

  -- Sam Loyd's 14-15 puzzle: the famous impossible one.
  local loyd = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 15, 14, 0 }
  ok(not Puzzle.isSolvable(loyd, 4), "the 14-15 puzzle is unsolvable")
end)

test("the oracle tracks the gap's row on an even-width board", function()
  -- Same tile order, gap moved up one row: on 4x4 that must flip the verdict,
  -- because the row-from-the-bottom term changes parity while the inversion
  -- count (which skips the gap) does not.
  local a = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 0, 12, 13, 14, 15 }
  local b = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0 }
  eq(Puzzle.inversions(a, 4), Puzzle.inversions(b, 4), "same tiles, same inversions")
  ok(Puzzle.isSolvable(b, 4), "gap on the bottom row: solvable")
  ok(not Puzzle.isSolvable(a, 4), "same tiles with the gap a row up: not solvable")
end)

-- ---------------------------------------------------- the scramble is safe --

test("every scramble the game deals is solvable", function()
  -- The most important test in the file. The shuffler and the oracle share no
  -- code: one walks legal moves, the other counts inversions.
  local checked = 0
  for _, n in ipairs(SIZES) do
    local bad = 0
    for seed = 1, 400 do
      local p = newPuzzle(n, seed * 7919 + n)
      if not p:solvable() then bad = bad + 1 end
      checked = checked + 1
    end
    eq(bad, 0, n .. "x" .. n .. ": unsolvable deals out of 400")
  end
  ok(checked == 1200, "checked " .. checked .. " deals")
end)

test("every scramble is a valid permutation", function()
  for _, n in ipairs(SIZES) do
    local bad = 0
    for seed = 1, 300 do
      local p = newPuzzle(n, seed * 104729 + n)
      if not p:isPermutation() then bad = bad + 1 end
    end
    eq(bad, 0, n .. "x" .. n .. ": malformed deals out of 300")
  end
end)

test("a scramble is never solved, and never trivially close to it", function()
  for _, n in ipairs(SIZES) do
    local solved, easy, worstMis, worstMan = 0, 0, math.huge, math.huge
    for seed = 1, 400 do
      local p = newPuzzle(n, seed * 15485863 + n)
      if p:isSolved() then solved = solved + 1 end
      if not p:isScrambled() then easy = easy + 1 end
      worstMis = math.min(worstMis, p:misplaced())
      worstMan = math.min(worstMan, p:manhattan())
    end
    eq(solved, 0, n .. "x" .. n .. ": deals that were already solved")
    eq(easy, 0, n .. "x" .. n .. ": deals that were too close to solved")
    ok(worstMis >= 5, string.format("%dx%d: fewest misplaced tiles dealt was %d",
      n, n, worstMis))
    ok(worstMan > 0, string.format("%dx%d: smallest Manhattan sum dealt was %d",
      n, n, worstMan))
  end
end)

test("the scramble never immediately undoes its previous move", function()
  -- Driven through the same step the shuffler uses. Without this the walk
  -- spends half its time retracing and drifts back toward the solved board.
  for _, n in ipairs(SIZES) do
    local p = newPuzzle(n, 4242 + n, false)
    local prev, back = nil, 0
    for _ = 1, 3000 do
      -- What the step is allowed to choose from, before it chooses.
      local allowed = p:gapNeighbours(prev)
      for _, idx in ipairs(allowed) do
        if idx == prev then back = back + 1 end
      end
      ok(#allowed >= 1, "always at least one way to go")
      passed = passed - 1  -- counted once below instead of 3000 times

      local was = p.blank
      prev = p:scrambleStep(prev)
      eq(prev, was, "scrambleStep reports where the gap came from")
      passed = passed - 1
      ok(p.blank ~= was, "the gap actually moved")
      passed = passed - 1
    end
    eq(back, 0, n .. "x" .. n .. ": steps that could have retraced")
    ok(true, n .. "x" .. n .. ": 3000 steps all moved the gap somewhere new")
  end
end)

-- ---------------------------------------------------- moves keep it legal --

test("a legal move never changes solvability", function()
  -- The invariant that catches a move implementation quietly corrupting the
  -- board: thousands of real slides, with the oracle re-run after every one.
  for _, n in ipairs(SIZES) do
    local rand = seededRand(20240607 + n)
    local p = playing(n, 555 + n)
    local unsolvable, malformed, moved = 0, 0, 0
    for _ = 1, 4000 do
      local count = randomLegalMove(p, rand)
      if count > 0 then moved = moved + 1 end
      if not p:solvable() then unsolvable = unsolvable + 1 end
      if not p:isPermutation() then malformed = malformed + 1 end
    end
    eq(unsolvable, 0, n .. "x" .. n .. ": moves that left an unsolvable board")
    eq(malformed, 0, n .. "x" .. n .. ": moves that left an invalid board")
    eq(moved, 4000, n .. "x" .. n .. ": every chosen target was a legal move")
  end
end)

test("arrow moves keep it legal too, in either convention", function()
  local rand = seededRand(97531)
  for _, n in ipairs(SIZES) do
    local p = playing(n, 8080 + n)
    for _ = 1, 3000 do
      p:step(Puzzle.DIRS[rand(4)], rand(2) == 1)
      if not p:solvable() or not p:isPermutation() then
        return fail(n .. "x" .. n .. ": a keyed move corrupted the board")
      end
    end
    ok(true, n .. "x" .. n .. ": 3000 keyed moves all legal")
  end
end)

-- ------------------------------------------------------ what may move, and --
-- ------------------------------------------------------ exactly what moves --

test("only tiles in line with the gap can move", function()
  for _, n in ipairs(SIZES) do
    local p = playing(n, 31337 + n)
    local bx, by = p:blankXY()
    local rejected, accepted = 0, 0
    for y = 1, n do
      for x = 1, n do
        local inLine = (x == bx or y == by) and not (x == bx and y == by)
        eq(p:canSlideTo(x, y), inLine,
          string.format("%dx%d: (%d,%d) with the gap at (%d,%d)", n, n, x, y, bx, by))
        if not inLine then
          local before = sig(p)
          eq(p:slideTo(x, y), 0, "an out-of-line target moves nothing")
          eq(sig(p), before, "...and leaves the board untouched")
          rejected = rejected + 1
        else
          accepted = accepted + 1
        end
      end
    end
    ok(rejected > 0 and accepted == 2 * (n - 1),
      string.format("%dx%d: %d legal targets, %d rejected", n, n, accepted, rejected))
  end

  -- The gap itself is not a move, and neither is anything off the board.
  local p = playing(4, 11, false)
  local bx, by = p:blankXY()
  ok(not p:canSlideTo(bx, by), "the gap is not a move")
  ok(not p:canSlideTo(0, by), "off the left edge is not a move")
  ok(not p:canSlideTo(5, by), "off the right edge is not a move")
  ok(not p:canSlideTo(bx, 0) and not p:canSlideTo(bx, 5), "off top and bottom")
  ok(not p:canSlideTo(nil, nil), "nil is not a move")
end)

test("a run slide moves exactly the tiles between the gap and the target", function()
  -- Solved 4x4, so the gap is at (4,4) and row 4 reads 13 14 15 _.
  local p = playing(4, 1, false)
  eq(select(1, p:blankXY()), 4, "gap starts in column 4")
  eq(select(2, p:blankXY()), 4, "gap starts in row 4")

  eq(p:slideTo(1, 4), 3, "clicking tile 13 takes the whole run with it")
  eq(p:get(1, 4), 0, "the gap ends where the clicked tile was")
  eq(p:get(2, 4), 13, "13 moved one cell right")
  eq(p:get(3, 4), 14, "14 moved one cell right")
  eq(p:get(4, 4), 15, "15 moved one cell right")
  eq(p.moves, 3, "three tiles travelled, so three moves")

  -- The other eleven tiles are exactly where they were.
  local intact = true
  for i = 1, 12 do
    if p.tiles[i] ~= i then intact = false end
  end
  ok(intact, "rows 1 to 3 were not touched")

  -- The animation record describes precisely those three tiles.
  eq(#p.slide, 3, "the slide record has one entry per travelling tile")
  local seen = {}
  for _, m in ipairs(p.slide) do
    seen[m.value] = true
    eq(math.abs(m.toX - m.fromX) + math.abs(m.toY - m.fromY), 1,
      "tile " .. m.value .. " travelled exactly one cell")
  end
  ok(seen[13] and seen[14] and seen[15], "the record names 13, 14 and 15")

  -- Vertical runs behave the same way.
  local q = playing(4, 1, false)
  eq(q:slideTo(4, 1), 3, "a full-column click takes three tiles")
  eq(q:get(4, 1), 0, "the gap climbed to the top of the column")
  eq(q:get(4, 2), 4, "4 moved one cell down")
  eq(q:get(4, 3), 8, "8 moved one cell down")
  eq(q:get(4, 4), 12, "12 moved one cell down")

  -- A single-step click is just the one-tile case of the same operation.
  local r = playing(3, 1, false)
  eq(r:slideTo(2, 3), 1, "clicking the tile beside the gap moves one tile")
  eq(r.moves, 1, "and counts as one move")
end)

test("run slides of every length move the right number of tiles", function()
  for _, n in ipairs(SIZES) do
    local p = playing(n, 606 + n)
    local rand = seededRand(n * 99991)
    for _ = 1, 500 do
      local bx, by = p:blankXY()
      local before = {}
      for i = 1, p.cells do before[i] = p.tiles[i] end

      local t = legalTargets(p)[rand(2 * (n - 1))]
      local want = math.max(math.abs(t[1] - bx), math.abs(t[2] - by))
      local got = p:slideTo(t[1], t[2])
      eq(got, want, n .. "x" .. n .. ": tiles moved matches the run length")
      passed = passed - 1

      -- Exactly `want` cells changed contents, plus the two ends of the run.
      local changed = 0
      for i = 1, p.cells do
        if before[i] ~= p.tiles[i] then changed = changed + 1 end
      end
      eq(changed, want + 1, "cells whose contents changed")
      passed = passed - 1
    end
    ok(true, n .. "x" .. n .. ": 500 run slides moved exactly their run")
  end
end)

-- ------------------------------------------------------------------- undo --

test("a move followed by its inverse restores the board exactly", function()
  for _, n in ipairs(SIZES) do
    local rand = seededRand(2718 + n)
    local p = playing(n, 1618 + n)
    for _ = 1, 1500 do
      local before, movesBefore = sig(p), p.moves
      local count = randomLegalMove(p, rand)

      -- The inverse of a run slide is the same run slide back the other way:
      -- send the gap to where it started.
      local rec = p.undoStack[#p.undoStack]
      p.undoStack[#p.undoStack] = nil
      p:slideTo(rec.x, rec.y, false)
      p.moves = p.moves - count

      if sig(p) ~= before then
        return fail(n .. "x" .. n .. ": the inverse slide did not restore the board")
      end
      if p.moves ~= movesBefore then
        return fail(n .. "x" .. n .. ": the move counter did not come back")
      end
    end
    ok(true, n .. "x" .. n .. ": 1500 move/inverse pairs were exact")
  end
end)

test("undo is unlimited and exact all the way back to the deal", function()
  for _, n in ipairs(SIZES) do
    local rand = seededRand(31415 + n)
    local p = playing(n, 27182 + n)

    local history = { sig(p) }
    for _ = 1, 200 do
      randomLegalMove(p, rand)
      history[#history + 1] = sig(p)
    end
    eq(#p.undoStack, 200, n .. "x" .. n .. ": one undo record per move")

    local mismatched = 0
    for i = #history - 1, 1, -1 do
      ok(p:canUndo(), "still something to undo at step " .. i)
      passed = passed - 1
      p:undo()
      if sig(p) ~= history[i] then mismatched = mismatched + 1 end
    end
    eq(mismatched, 0, n .. "x" .. n .. ": undos that landed on the wrong board")
    eq(p.moves, 0, n .. "x" .. n .. ": the move counter unwound to zero")
    ok(not p:canUndo(), n .. "x" .. n .. ": nothing left to undo")
    eq(p:undo(), false, n .. "x" .. n .. ": undoing nothing is a no-op")
  end
end)

test("undo takes a solved puzzle back into play", function()
  local p = playing(3, 7, false)
  p:slideTo(2, 3)
  eq(p.state, "playing", "one move off solved is still in play")
  p:slideTo(3, 3)
  eq(p.state, "solved", "putting it back solves it")
  ok(p:undo(), "undo works from the solved state")
  eq(p.state, "playing", "and puts the round back in play")
  ok(not p:isSolved(), "the board is no longer solved")
end)

-- -------------------------------------------------------- win detection --

test("win detection fires on exactly the solved arrangement", function()
  for _, n in ipairs(SIZES) do
    local p = newPuzzle(n, 1, false)
    ok(p:isSolved(), n .. "x" .. n .. ": the solved board is solved")

    -- Every single transposition of two tiles, including the near-miss with
    -- the last two swapped, which is the one that looks solved at a glance.
    local wrong = 0
    for a = 1, p.cells do
      for b = a + 1, p.cells do
        p:setSolved()
        p.tiles[a], p.tiles[b] = p.tiles[b], p.tiles[a]
        if p.tiles[a] == 0 then p.blank = a elseif p.tiles[b] == 0 then p.blank = b end
        if p:isSolved() then wrong = wrong + 1 end
      end
    end
    eq(wrong, 0, n .. "x" .. n .. ": swapped boards reported as solved")

    -- Spelled out, because it is the case a lazy check gets wrong.
    p:setSolved()
    local last, prev = p.cells - 1, p.cells - 2
    p.tiles[last], p.tiles[prev] = p.tiles[prev], p.tiles[last]
    ok(not p:isSolved(), n .. "x" .. n .. ": last two tiles swapped is not solved")
    ok(not Puzzle.isSolvable(p.tiles, n),
      n .. "x" .. n .. ": ...and the oracle agrees it is unreachable")
  end
end)

test("win detection is exact over a fuzz of arrangements", function()
  -- isSolved() must be true for precisely one arrangement, so compare it
  -- against the arrangement itself over thousands of shuffled boards.
  local rand = seededRand(864213)
  for _, n in ipairs(SIZES) do
    local p = newPuzzle(n, 1, false)
    local want = table.concat(solvedTiles(n), ",")
    local disagreed, solvedSeen = 0, 0
    for _ = 1, 8000 do
      -- A uniform shuffle of all cells: half of these are unsolvable boards,
      -- which is fine -- this is about detection, not reachability.
      for i = p.cells, 2, -1 do
        local j = rand(i)
        p.tiles[i], p.tiles[j] = p.tiles[j], p.tiles[i]
      end
      for i = 1, p.cells do
        if p.tiles[i] == 0 then p.blank = i end
      end
      local isSolved = (table.concat(p.tiles, ",") == want)
      if isSolved then solvedSeen = solvedSeen + 1 end
      if p:isSolved() ~= isSolved then disagreed = disagreed + 1 end
    end
    eq(disagreed, 0, n .. "x" .. n .. ": arrangements where isSolved disagreed")
  end
end)

test("solving a puzzle records the best moves and the best time", function()
  local p = playing(3, 99, false)
  p:slideTo(2, 3)          -- one tile away from solved
  p:advance(30)
  p:slideTo(3, 3)
  eq(p.state, "solved", "the puzzle is solved")
  local best = p:best()
  eq(best.moves, 2, "best moves recorded")
  eq(best.seconds, 30, "best time recorded")

  -- Each record moves only when it is beaten, and the two are independent: a
  -- quicker but wasteful solve must not wipe the fewest-moves record.
  local q = Puzzle.new({ size = 3, rand = seededRand(5), shuffle = false, bests = p.bests })
  q:start()
  q:slideTo(2, 3); q:slideTo(1, 3); q:slideTo(2, 3)
  q:advance(5)
  q:slideTo(3, 3)
  eq(q.state, "solved", "the second puzzle is solved too")
  eq(q.moves, 4, "in four moves and five seconds")
  eq(q:best().seconds, 5, "the faster time replaced the record")
  eq(q:best().moves, 2, "the fewer-moves record survived the wasteful solve")

  -- Bests are per size: a 4x4 record cannot be confused with a 3x3 one.
  eq(p.bests[4], nil, "no 4x4 record has been set")
end)

test("the clock only runs while the round is in play", function()
  local p = newPuzzle(4, 1)
  p:advance(10)
  eq(p.elapsed, 0, "a puzzle waiting on the title screen does not age")
  p:start()
  p:advance(10)
  eq(p.elapsed, 10, "playing counts")
  p:pause()
  p:advance(10)
  eq(p.elapsed, 10, "paused does not")
  p:resume()
  p:advance(5)
  eq(p.elapsed, 15, "resumed counts again")
end)

-- --------------------------------------------------------- input mapping --

test("an arrow moves the tile the arrow points at, not the gap", function()
  -- The convention, asserted rather than assumed: the two readings are exact
  -- opposites, so getting this backwards would feel broken rather than merely
  -- unfamiliar. Solved 4x4, so the gap sits at (4,4).
  local p = playing(4, 1, false)
  eq(p:step("right"), 1, "right is a legal move here")
  eq(p:get(3, 4), 0, "the gap moved left, because the tile moved right")
  eq(p:get(4, 4), 15, "tile 15 slid rightwards into the gap")

  local q = playing(4, 1, false)
  eq(q:step("down"), 1, "down is a legal move here")
  eq(q:get(4, 3), 0, "the gap moved up, because the tile moved down")
  eq(q:get(4, 4), 12, "tile 12 slid downwards into the gap")

  -- With the gap in the bottom-right corner there is no tile to the right of
  -- it and none below it, so Left and Up have nothing to pull in. This is the
  -- half of the convention that is easy to get backwards: pressing Left here
  -- moving tile 15 would mean the arrow was steering the gap, not the tile.
  local r = playing(4, 1, false)
  eq(r:step("left"), 0, "nothing to the right of the gap for Left to bring in")
  eq(r:step("up"), 0, "nor anything below it for Up")
  eq(r.moves, 0, "a rejected arrow is not a move")
end)

test("the inverse convention is the exact mirror of it", function()
  for _, dir in ipairs(Puzzle.DIRS) do
    local a, b = { Puzzle.gapStep(dir, false) }, { Puzzle.gapStep(dir, true) }
    eq(a[1], -b[1], dir .. ": inverted dx is negated")
    eq(a[2], -b[2], dir .. ": inverted dy is negated")
  end
  eq(Puzzle.gapStep("sideways"), nil, "junk is not a direction")

  -- Inverted, Left is the arrow that works on the solved board, because it
  -- now steers the gap rather than the tile.
  local p = playing(4, 1, false)
  eq(p:step("left", true), 1, "inverted, Left moves the gap leftwards...")
  eq(p:get(3, 4), 0, "...which is the move Right made under the normal reading")
  eq(playing(4, 1, false):step("right", true), 0,
    "and on a fresh board inverted Right is the one with nowhere to go")

  -- Two opposite arrows in the same convention put everything back.
  local q = playing(4, 1, false)
  local before = sig(q)
  q:step("right")
  q:step("left")
  eq(sig(q), before, "right then left is a round trip")
end)

-- ----------------------------------------------------------------- sizes --

test("the rules are generic over board size", function()
  for _, n in ipairs(SIZES) do
    local p = newPuzzle(n, 5150 + n)
    eq(p.size, n, "size")
    eq(p.cells, n * n, "cells")
    eq(#p.tiles, n * n, "one entry per cell")
    eq(p.tiles[p.blank], 0, "the cached gap index points at the gap")
  end

  -- Changing size is a new puzzle, but the session's records survive it.
  local p = newPuzzle(3, 4321)
  p.bests[3] = { moves = 40, seconds = 60 }
  p:setSize(5)
  eq(p.size, 5, "resized to 5x5")
  eq(p.cells, 25, "25 cells")
  ok(p:solvable(), "and the new board is solvable")
  eq(p.bests[3].moves, 40, "the 3x3 record survived the size change")
end)

-- ---------------------------------------------------------------- solver --

test("the solver finds a path that actually solves the board", function()
  for _, n in ipairs({ 3, 4 }) do
    for trial = 1, 12 do
      local p = playing(n, trial * 7919 + n, false)
      p:randomWalk(6 + trial)               -- shallow enough to solve outright
      p.moves, p.undoStack = 0, {}

      local solver = p:newSolver(2000000)
      eq(solver:think(1e9), "solved", n .. "x" .. n .. " trial " .. trial .. ": solved")
      passed = passed - 1

      for _, cell in ipairs(solver.path) do
        if p:slideTo(p:colOf(cell), p:rowOf(cell)) ~= 1 then
          return fail(n .. "x" .. n .. ": the solver proposed an illegal move")
        end
      end
      if not p:isSolved() then
        return fail(n .. "x" .. n .. ": the solver's path did not solve the board")
      end
    end
    ok(true, n .. "x" .. n .. ": 12 searches each produced a working solution")
  end
end)

test("the solver's path is optimal on positions of known depth", function()
  -- A walk that never retraces its own last step still revisits positions, so
  -- its length is only an upper bound. What must hold is that the solver never
  -- returns something *longer*, and that it agrees with the walk whenever the
  -- walk was already shortest.
  local shortest, longer = 0, 0
  for trial = 1, 40 do
    local p = playing(3, trial * 65537, false)
    local steps = 2 + (trial % 12)
    p:randomWalk(steps)
    local solver = p:newSolver(2000000)
    if solver:think(1e9) == "solved" then
      if #solver.path > steps then longer = longer + 1 end
      if #solver.path == steps then shortest = shortest + 1 end
    end
  end
  eq(longer, 0, "searches that returned a path longer than the walk that made it")
  ok(shortest > 20, "and matched the walk exactly " .. shortest .. " times out of 40")
end)

test("slicing the search changes when it answers, never what", function()
  -- The property that makes the timer-driven hint trustworthy: a search fed a
  -- few nodes per tick must return exactly what the same search returns when
  -- run straight through.
  for _, n in ipairs({ 3, 4 }) do
    local differed = 0
    for trial = 1, 15 do
      local p = playing(n, trial * 2654435761 % 2147483647, false)
      p:randomWalk(8 + trial)

      local straight = p:newSolver(2000000)
      straight:think(1e9)

      local sliced = p:newSolver(2000000)
      local guard = 0
      while sliced:think(17) == "thinking" and guard < 200000 do guard = guard + 1 end

      eq(sliced.status, straight.status, "same verdict")
      passed = passed - 1
      if table.concat(sliced.path or {}, ",") ~= table.concat(straight.path or {}, ",") then
        differed = differed + 1
      end
      eq(sliced.nodes, straight.nodes, "same amount of work")
      passed = passed - 1
    end
    eq(differed, 0, n .. "x" .. n .. ": sliced searches that answered differently")
  end
end)

test("the solver reports a budget it cannot meet instead of guessing", function()
  -- A freshly dealt 4x4 needs a solution about 50 moves long, which is far
  -- past any budget a handheld can spend between frames. Saying so is the
  -- right answer; returning a move it cannot justify would not be.
  local p = newPuzzle(4, 20240101)
  local solver = p:newSolver(4000)
  local guard = 0
  while solver:think(250) == "thinking" and guard < 100 do guard = guard + 1 end
  eq(solver.status, "budget", "gave up rather than guessing")
  eq(solver.path, nil, "and offers no path")
  ok(solver.nodes <= 4000 + 250, "stopped inside its budget (" .. solver.nodes .. " nodes)")

  -- 5x5 is refused outright: optimal search at that size is hopeless and
  -- pretending otherwise would just burn ticks.
  local big = newPuzzle(5, 7)
  eq(big:newSolver(1000).status, "unsupported", "5x5 is not attempted")

  -- An already-solved board needs no search at all.
  local done = newPuzzle(3, 1, false)
  local s = done:newSolver(10)
  eq(s.status, "solved", "a solved board is solved before the first node")
  eq(#s.path, 0, "with an empty path")
end)

test("the heuristic never overestimates the distance to the goal", function()
  -- Manhattan plus linear conflict has to be admissible or the paths above are
  -- not optimal. Walk back from solved and check the estimate against a length
  -- that is known to be achievable.
  local overs = 0
  for _, n in ipairs({ 3, 4 }) do
    for trial = 1, 60 do
      local p = playing(n, trial * 40503 + n, false)
      local steps = 1 + (trial % 20)
      p:randomWalk(steps)
      if Puzzle.heuristic(p.tiles, n) > steps then overs = overs + 1 end
    end
  end
  eq(overs, 0, "positions where the heuristic exceeded a known solution length")

  -- It is zero exactly on the goal, and positive everywhere else.
  for _, n in ipairs({ 3, 4, 5 }) do
    local p = newPuzzle(n, 1, false)
    eq(Puzzle.heuristic(p.tiles, n), 0, n .. "x" .. n .. ": solved estimates zero")
    p:start()
    p:slideTo(n - 1, n)
    ok(Puzzle.heuristic(p.tiles, n) > 0, n .. "x" .. n .. ": one move off is not zero")
  end

  -- Linear conflict has to add something, or it is not being computed: two
  -- tiles of row 1 in row 1 but the wrong way round cost two extra moves that
  -- Manhattan alone cannot see.
  local t = { 2, 1, 3, 4, 5, 6, 7, 8, 0 }
  eq(Puzzle.heuristic(t, 3), 4, "swapped row-mates cost Manhattan 2 plus a conflict")
end)

test("benchmark: the hint search on this machine", function()
  -- main.lua sizes its per-tick budget from this number, so it is measured
  -- rather than remembered. The handheld is assumed to be about 25x slower.
  local nodes, t0 = 0, os.clock()
  local worst = 0
  for trial = 1, 60 do
    local p = newPuzzle(3, trial * 104729)   -- a full 3x3 scramble
    local solver = p:newSolver(2000000)
    if solver:think(1e9) == "solved" then
      nodes = nodes + solver.nodes
      if solver.nodes > worst then worst = solver.nodes end
    end
  end
  local secs = os.clock() - t0
  print(string.format("  note  full 3x3 scrambles: %d nodes in %.2fs (%.0f nodes/sec), worst %d",
    nodes, secs, nodes / math.max(secs, 0.001), worst))
  ok(nodes > 0, "the benchmark ran")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
