-- Tests for the pure Connect Four logic and the bot. Run with:
--   make GAME=connect4 test
-- (or: GAME_SRC=src/connect4 lua tests/connect4/run.lua   from the repo root)
--
-- Connect Four has unusually strong testable properties and this file leans on
-- all of them. The two that matter most are near the bottom: the pruned search
-- is checked against a slow, obviously-correct minimax written here rather
-- than reused from the game, and the sliced search is checked against the same
-- search run in one shot.

package.path = (os.getenv("GAME_SRC") or "src/connect4") .. "/?.lua;" .. package.path
local Board = require("game")

local COLS, ROWS, CONNECT = Board.COLS, Board.ROWS, Board.CONNECT
local WIN_SCORE = Board.AI.WIN_SCORE

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

-- Times each test as it runs. This suite is much heavier than the others
-- here -- an unpruned minimax and several thousand played-out games -- so it
-- is worth being able to see at a glance which part is costing the time.
local slowest = {}

local function test(name, fn)
  current = name
  local t0 = os.clock()
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
  slowest[#slowest + 1] = { name = name, secs = os.clock() - t0 }
end

-- ---------------------------------------------------------------- helpers --

-- Park-Miller MINSTD: a small, exact-in-doubles generator, so a seed pins a
-- whole game down and a failure can be reproduced by printing the seed.
local function seededRand(seed)
  local s = (seed or 12345) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (16807 * s) % 2147483647
    return (s % n) + 1
  end
end

local function newBoard(opts)
  local b = Board.new(opts)
  b:start()
  return b
end

-- Builds a position by dropping the listed columns in order, alternating
-- colours the way a real game does.
local function playCols(cols, opts)
  local b = newBoard(opts)
  for _, c in ipairs(cols) do b:drop(c) end
  return b
end

-- The reference positional score: a full rescan of all 69 windows. game.lua
-- never does this -- it patches a running total in place() instead -- so this
-- is the independent definition the incremental one is checked against.
local function fullScore(b)
  local W, WS = Board.WINDOWS, Board.WSCORE
  local s = 0
  for i = 1, #W, CONNECT do
    local ones, twos = 0, 0
    for k = 0, CONNECT - 1 do
      local v = b.cells[W[i + k]]
      if v == 1 then ones = ones + 1 elseif v == 2 then twos = twos + 1 end
    end
    s = s + WS[ones * 5 + twos + 1]
  end
  for r = 1, ROWS do
    local v = b.cells[(r - 1) * COLS + 4]
    if v == 1 then s = s + Board.CENTRE_WEIGHT
    elseif v == 2 then s = s - Board.CENTRE_WEIGHT end
  end
  return s
end

-- Sets up an arbitrary position directly, bypassing turn order. `rows` is
-- given top row first, using '.', '1' and '2'. Only used where gravity would
-- make a position awkward to reach by dropping.
local function fromRows(rows, turn)
  local b = newBoard()
  for r = 1, ROWS do
    local line = rows[r]
    for c = 1, COLS do
      local ch = line:sub(c, c)
      local v = (ch == "1" and 1) or (ch == "2" and 2) or 0
      if v ~= 0 then
        b.cells[(r - 1) * COLS + c] = v
        -- The topmost filled row fixes the height, so take the largest.
        local h = ROWS - r + 1
        if h > b.heights[c] then b.heights[c] = h end
        b.nplaced = b.nplaced + 1
      end
    end
  end

  -- The window counts and running score are maintained by place(), which this
  -- shortcut went around, so rebuild both from what is on the board.
  local W = Board.WINDOWS
  for wid = 1, #W / CONNECT do
    local base, ones, twos = (wid - 1) * CONNECT, 0, 0
    for k = 1, CONNECT do
      local v = b.cells[W[base + k]]
      if v == 1 then ones = ones + 1 elseif v == 2 then twos = twos + 1 end
    end
    b.wcode[wid] = ones * 5 + twos
  end
  b.score = fullScore(b)
  b.turn = turn or 1

  -- A position that floats a disc over a gap would silently invalidate every
  -- test that used it, so refuse to build one.
  for c = 1, COLS do
    local n = 0
    for r = 1, ROWS do if b.cells[(r - 1) * COLS + c] ~= 0 then n = n + 1 end end
    assert(n == b.heights[c], "fromRows: column " .. c .. " has a floating disc")
  end
  return b
end

-- The thing game.lua deliberately does *not* do: look at every line on the
-- board. Used to prove that checking only lines through the last disc misses
-- nothing.
local function scanWholeBoard(b)
  local dirs = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }
  local found = {}
  for r = 1, ROWS do
    for c = 1, COLS do
      local p = b:at(c, r)
      if p and p ~= 0 then
        for _, d in ipairs(dirs) do
          local n = 0
          for k = 0, CONNECT - 1 do
            if b:at(c + k * d[1], r + k * d[2]) == p then n = n + 1 else break end
          end
          if n == CONNECT then found[#found + 1] = { c = c, r = r, dc = d[1], dr = d[2], p = p } end
        end
      end
    end
  end
  return found
end

local function boardString(b)
  local out = {}
  for r = 1, ROWS do
    local line = {}
    for c = 1, COLS do line[c] = tostring(b.cells[(r - 1) * COLS + c]) end
    out[r] = table.concat(line)
  end
  return table.concat(out, "/")
end

-- ============================================================ the rules ====

test("a fresh board is empty, red to move and not yet playing", function()
  local b = Board.new()
  eq(b.state, "ready", "starts on the title screen")
  eq(b.turn, 1, "red moves first")
  eq(b.nplaced, 0, "no discs")
  eq(b.score, 0, "an empty board is level")
  eq(#b:legalMoves(), COLS, "every column is open")
  for c = 1, COLS do
    eq(b.heights[c], 0, "column " .. c .. " is empty")
    for r = 1, ROWS do eq(b:at(c, r), 0, "cell " .. c .. "," .. r .. " is empty") end
  end
end)

test("cells outside the board read as nil, never as empty", function()
  local b = newBoard()
  for _, p in ipairs({ { 0, 1 }, { COLS + 1, 1 }, { 1, 0 }, { 1, ROWS + 1 },
                       { 0, 0 }, { COLS + 1, ROWS + 1 }, { -5, 3 }, { 3, 99 } }) do
    eq(b:at(p[1], p[2]), nil, string.format("(%d,%d) is off the board", p[1], p[2]))
  end
end)

test("gravity: a disc lands in the lowest empty row of its column", function()
  -- A fresh board per column: filling several columns of one alternating game
  -- completes a four along the bottom row and stops the game, which would say
  -- nothing about gravity. One column at a time alternates 1,2,1,2,1,2 and
  -- never makes a line.
  for c = 1, COLS do
    local b = newBoard()
    for i = 1, ROWS do
      local want = ROWS - i + 1
      eq(b:landing(c), want, string.format("col %d disc %d will land on row %d", c, i, want))
      local r = b:drop(c)
      eq(r, want, string.format("col %d disc %d reported row %d", c, i, want))
      eq(b.heights[c], i, "the column grew by one")
      ok(b:at(c, r) ~= 0, "the cell it reported is occupied")
      -- Nothing floats: every cell below is filled, every cell above is empty.
      for rr = r + 1, ROWS do ok(b:at(c, rr) ~= 0, "supported from below") end
      for rr = 1, r - 1 do eq(b:at(c, rr), 0, "nothing above it") end
      -- And no other column was touched.
      for other = 1, COLS do
        if other ~= c then eq(b.heights[other], 0, "column " .. other .. " untouched") end
      end
    end
  end
end)

test("a disc dropped onto a partly filled column stacks on top", function()
  local b = newBoard()
  b:drop(1); b:drop(1); b:drop(7) -- 1 twice, then elsewhere
  eq(b:landing(1), ROWS - 2, "the third disc lands two rows up")
  eq(b:drop(1), ROWS - 2, "and it does")
  eq(b:at(1, ROWS), 1, "bottom disc is still red")
  eq(b:at(1, ROWS - 1), 2, "then yellow")
  eq(b:at(1, ROWS - 2), 2, "then yellow again")
end)

test("a full column is rejected and leaves the board alone", function()
  local b = newBoard()
  for _ = 1, ROWS do b:drop(3) end
  eq(b.heights[3], ROWS, "column 3 is full")
  eq(b:open(3), false, "open() says so")
  eq(b:landing(3), nil, "landing() says so")

  local before, turn, n = boardString(b), b.turn, b.nplaced
  eq(b:drop(3), nil, "the drop was refused")
  eq(boardString(b), before, "the board did not change")
  eq(b.turn, turn, "the turn did not pass")
  eq(b.nplaced, n, "no disc was added")

  local legal = b:legalMoves()
  eq(#legal, COLS - 1, "column 3 is gone from the legal moves")
  for _, c in ipairs(legal) do ok(c ~= 3, "legalMoves never offers the full column") end
end)

test("out-of-range and non-integer columns are refused", function()
  local b = newBoard()
  for _, c in ipairs({ 0, -1, COLS + 1, 99, 3.5, -0.5 }) do
    eq(b:open(c), false, tostring(c) .. " is not a column")
    eq(b:drop(c), nil, "dropping into " .. tostring(c) .. " is refused")
  end
  for _, c in ipairs({ "3", {}, true }) do
    eq(b:open(c), false, tostring(c) .. " is not a column")
  end
  eq(b.nplaced, 0, "none of that put a disc on the board")
end)

test("drops are refused unless the game is running", function()
  local b = Board.new()
  eq(b.state, "ready", "not started")
  eq(b:drop(4), nil, "no drop before the game starts")
  b:start()
  ok(b:drop(4), "a drop lands once started")
  b:pause()
  eq(b:drop(4), nil, "no drop while paused")
  b:resume()
  ok(b:drop(4), "and again once resumed")
end)

test("the turn alternates, and only on a legal drop", function()
  local b = newBoard()
  local want = 1
  for i = 1, 20 do
    eq(b.turn, want, "move " .. i .. " is player " .. want)
    b:drop(((i - 1) % COLS) + 1)
    want = 3 - want
  end
  for _ = 1, ROWS do b:drop(1) end -- fill column 1
  local t = b.turn
  b:drop(1)
  eq(b.turn, t, "a refused drop does not pass the turn")
end)

-- ------------------------------------------------------- win detection -----

test("win detection: four in a row, every direction, every position", function()
  local dirs = {
    { 1, 0, "horizontal" }, { 0, 1, "vertical" },
    { 1, 1, "diagonal down-right" }, { 1, -1, "diagonal up-right" },
  }
  local checked = 0

  for _, d in ipairs(dirs) do
    local dc, dr = d[1], d[2]
    for r = 1, ROWS do
      for c = 1, COLS do
        -- Only start where the whole run fits on the board.
        local ec, er = c + 3 * dc, r + 3 * dr
        if ec >= 1 and ec <= COLS and er >= 1 and er <= ROWS then
          for p = 1, 2 do
            -- Place the run one disc at a time and check that the win is seen
            -- exactly on the fourth, and from whichever disc completed it.
            for last = 1, CONNECT do
              local b = newBoard()
              local lc, lr
              for k = 0, CONNECT - 1 do
                local cc, rr = c + k * dc, r + k * dr
                if k + 1 ~= last then
                  b.cells[(rr - 1) * COLS + cc] = p
                else
                  lc, lr = cc, rr
                end
              end
              -- Board:winsAt assumes the disc is already at (c,r) -- it is
              -- only ever called right after a place -- so the "not yet a
              -- win" half is asked of the whole-board scan, which makes no
              -- such assumption.
              eq(#scanWholeBoard(b), 0, d[3] .. " with a gap is not a win anywhere")
              -- The opponent filling the gap must not create one either.
              b.cells[(lr - 1) * COLS + lc] = 3 - p
              eq(b:winsAt(lc, lr, 3 - p), false, "the wrong colour in the gap wins nothing")
              eq(#scanWholeBoard(b), 0, "and the board is still clean")

              b.cells[(lr - 1) * COLS + lc] = p
              eq(b:winsAt(lc, lr, p), true,
                string.format("%s from (%d,%d) completed at (%d,%d) for player %d",
                  d[3], c, r, lc, lr, p))
              eq(b:winsAt(lc, lr, 3 - p), false, "the other colour did not win")

              local line = b:lineAt(lc, lr)
              ok(line ~= nil, "lineAt found the run")
              if line then
                ok(#line >= CONNECT, "the run is at least four long, got " .. #line)
                local onLine = false
                for _, cell in ipairs(line) do
                  ok(b:at(cell.c, cell.r) == p, "every cell in the run is the winner's")
                  if cell.c == lc and cell.r == lr then onLine = true end
                end
                ok(onLine, "the run contains the disc that completed it")
              end
              checked = checked + 1
            end
          end
        end
      end
    end
  end
  eq(checked, 69 * 2 * CONNECT, "covered every window, colour and completing disc")
end)

test("three in a row is never a win, in any direction or position", function()
  local dirs = { { 1, 0 }, { 0, 1 }, { 1, 1 }, { 1, -1 } }
  for _, d in ipairs(dirs) do
    for r = 1, ROWS do
      for c = 1, COLS do
        local ec, er = c + 2 * d[1], r + 2 * d[2]
        if ec >= 1 and ec <= COLS and er >= 1 and er <= ROWS then
          local b = newBoard()
          for k = 0, 2 do
            b.cells[(r + k * d[2] - 1) * COLS + (c + k * d[1])] = 1
          end
          for k = 0, 2 do
            eq(b:winsAt(c + k * d[1], r + k * d[2], 1), false, "three is not four")
          end
        end
      end
    end
  end
end)

test("checking only the last disc finds every win a whole-board scan finds", function()
  -- The claim game.lua rests on. Play thousands of random games; after every
  -- single drop, compare Board's answer with a scan of all 69 windows.
  local rand = seededRand(20250827)
  local games, decided, agreed = 0, 0, 0

  for g = 1, 1200 do
    local b = newBoard({ rand = rand })
    games = games + 1
    while not b:isOver() do
      local legal = b:legalMoves()
      local c = legal[rand(#legal)]
      local p = b.turn
      local r = b:drop(c)
      ok(r ~= nil, "the random move was legal")

      local scan = scanWholeBoard(b)
      local scanWinner = scan[1] and scan[1].p or nil

      if b.state == "won" then
        eq(b.winner, p, "the winner is whoever just moved")
        eq(scanWinner, p, "the full scan agrees there is a win, for the same player")
        decided = decided + 1
      else
        eq(#scan, 0, "the full scan agrees there is no win: " .. boardString(b))
      end
      agreed = agreed + 1

      -- No win may ever pre-date the disc that was just played: a scan of the
      -- board before this move must have been clean, which the loop above has
      -- already asserted for every earlier position in this game.
    end

    if b.state == "draw" then
      eq(b.nplaced, COLS * ROWS, "a draw means a full board")
      eq(#scanWholeBoard(b), 0, "and no line anywhere on it")
    end
  end

  eq(games, 1200, "played the games")
  ok(agreed > 20000, "compared a lot of positions (" .. agreed .. ")")
  ok(decided > 900, "most random games are won rather than drawn (" .. decided .. ")")
end)

test("a win is recorded once, and locks the board", function()
  local b = playCols({ 1, 2, 1, 2, 1, 2, 1 })
  eq(b.state, "won", "red won on the fourth")
  eq(b.winner, 1, "red is the winner")
  eq(b.wins[1], 1, "red's tally went up")
  eq(b.wins[2], 0, "yellow's did not")
  ok(b.line and #b.line == CONNECT, "there is a four-disc line to highlight")

  local before = boardString(b)
  eq(b:drop(5), nil, "no more drops once the game is won")
  eq(boardString(b), before, "the board is frozen")
  eq(b.wins[1], 1, "the tally did not move again")
end)

test("a run longer than four highlights the whole run", function()
  -- Red fills the bottom row's columns 1,2,4,5 then plays 3, joining two
  -- pairs into a five.
  local b = fromRows({
    ".......", ".......", ".......", ".......", ".......", "11.11..",
  }, 1)
  b.score = fullScore(b)
  local r = b:drop(3)
  eq(r, ROWS, "landed on the bottom row")
  eq(b.state, "won", "five in a row is a win")
  eq(#b.line, 5, "all five discs are highlighted")
end)

test("draw: a full board with no line ends the game as a draw", function()
  -- A known drawn filling. Columns are played in an order that leaves no
  -- four anywhere; asserted rather than assumed.
  -- Found by exhaustive search over move orders: the shortest centre-first
  -- filling of the board that never completes a four.
  local order = {
    4,4,4,4,4,4, 3,3,3,3,3,3, 5,5,5,5,5,5, 1, 2,2,2,2,2,2,
    6,6,6,6,6,6, 1,1,1,1,1, 7,7,7,7,7,7,
  }
  local b = newBoard()
  local drawn = false
  for i, c in ipairs(order) do
    b:drop(c)
    if b.state ~= "playing" then
      drawn = (b.state == "draw")
      eq(i, #order, "the game ended exactly when the board filled")
      break
    end
  end

  if b.state == "draw" then
    eq(b.nplaced, COLS * ROWS, "42 discs on the board")
    eq(#b:legalMoves(), 0, "no legal moves left")
    eq(b.draws, 1, "the draw was tallied")
    eq(#scanWholeBoard(b), 0, "no four anywhere")
    eq(b:drop(1), nil, "nothing can be dropped into a finished game")
    ok(drawn, "reported as a draw")
  else
    -- The filling above happens to contain a line; that is a bug in the test
    -- data, not in the game, so say which.
    fail("the drawing order produced a " .. b.state .. " for player " .. tostring(b.winner))
  end
end)

test("every game ends, and ends in a legal state", function()
  local rand = seededRand(99)
  local wins, draws = 0, 0
  for _ = 1, 800 do
    local b = newBoard({ rand = rand })
    local moves = 0
    while not b:isOver() do
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
      moves = moves + 1
      ok(moves <= COLS * ROWS, "no game runs past 42 moves")
    end
    if b.state == "won" then
      wins = wins + 1
      ok(b.line and #b.line >= CONNECT, "a win always leaves a line")
      ok(b.winner == 1 or b.winner == 2, "the winner is a real player")
    else
      draws = draws + 1
      eq(b.nplaced, COLS * ROWS, "a draw is a full board")
    end
    -- Heights and cells always agree.
    for c = 1, COLS do
      local n = 0
      for r = 1, ROWS do if b:at(c, r) ~= 0 then n = n + 1 end end
      eq(n, b.heights[c], "height of column " .. c .. " matches its discs")
    end
  end
  ok(wins > 0 and draws >= 0, string.format("%d wins, %d draws", wins, draws))
end)

test("the incremental score always equals a full rescan", function()
  -- place() patches a running total instead of rescanning 69 windows, which
  -- is what made the search three times faster. This is the check that the
  -- shortcut is exact -- after every drop of a long fuzz, and after undoing.
  local rand = seededRand(4242)
  local checks = 0
  for _ = 1, 400 do
    local b = newBoard({ rand = rand })
    while not b:isOver() do
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
      eq(b.score, fullScore(b), "score after " .. boardString(b))
      checks = checks + 1
    end
  end
  ok(checks > 8000, "checked a lot of positions (" .. checks .. ")")
end)

test("unplace is an exact inverse of place", function()
  local rand = seededRand(31337)
  for _ = 1, 300 do
    local b = newBoard({ rand = rand })
    for _ = 1, rand(30) do
      if b:isOver() then break end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end
    if not b:isOver() then
      local snapshot = { boardString(b), b.score, b.nplaced, b.turn }
      local codes = table.concat(b.wcode, ",")
      for _, c in ipairs(b:legalMoves()) do
        b:place(c)
        b:unplace(c)
      end
      eq(boardString(b), snapshot[1], "cells restored")
      eq(b.score, snapshot[2], "score restored")
      eq(b.nplaced, snapshot[3], "count restored")
      eq(b.turn, snapshot[4], "turn restored")
      eq(table.concat(b.wcode, ","), codes, "window counts restored")
    end
  end
end)

-- ============================================================== the bot ====

local function botFor(b, opts)
  opts = opts or {}
  opts.nodeBudget = opts.nodeBudget or 500000
  return Board.AI.new(b, opts)
end

test("the bot takes an immediate win when one is on offer", function()
  -- One case per direction, each with exactly one winning drop, and each
  -- checked at every depth: a bot that needs to look four plies ahead to see
  -- a win it can play right now is broken.
  local cases = {
    -- horizontal, completing from the right of the run
    { rows = { ".......", ".......", ".......", ".......", ".......",
               "111.222" }, turn = 1, want = 4 },
    -- horizontal, completing from the left
    { rows = { ".......", ".......", ".......", ".......", ".......",
               ".111222" }, turn = 1, want = 1 },
    -- vertical, yellow stacked three deep in column 2
    { rows = { ".......", ".......", ".......", ".2.....", ".2.....",
               "12.1.11" }, turn = 2, want = 2 },
    -- diagonal up-right, with the completing cell sitting on a full stack
    { rows = { ".......", ".......", ".......", "..11...", ".122...",
               "1222..1" }, turn = 1, want = 4 },
  }

  for i, case in ipairs(cases) do
    for depth = 1, 5 do
      local b = fromRows(case.rows, case.turn)
      eq(b.state, "playing", "case " .. i .. " is not already decided")
      eq(#scanWholeBoard(b), 0, "case " .. i .. " has no four on it yet")
      local ai = botFor(b, { maxDepth = depth })
      local mv = ai:solve()
      eq(mv, case.want, string.format("case %d at depth %d takes the win", i, depth))
      ok(ai.bestValue >= WIN_SCORE - 1000, "and knows it is winning")
      -- Playing it really does win.
      b:drop(mv)
      eq(b.state, "won", "case " .. i .. ": the move ended the game")
      eq(b.winner, case.turn, "for the player who made it")
    end
  end
end)

test("the bot blocks an immediate opponent win", function()
  -- Yellow to move against a single red threat, one case per direction. Each
  -- position is built so blocking is the *only* move that does not lose on
  -- the spot -- a second red threat would make the choice arbitrary and the
  -- test meaningless -- and so yellow has no win of its own to prefer.
  local cases = {
    { rows = { ".......", ".......", ".......", ".......", ".......",
               "111.2.2" }, want = 4 },
    { rows = { ".......", ".......", ".......", ".......", ".1.....",
               "2111.22" }, want = 5 },
    { rows = { ".......", ".......", ".......", ".1.....", ".1.....",
               ".1...22" }, want = 2 },
    { rows = { ".......", ".......", ".......", "..11...", ".122...",
               "1212..." }, want = 4 },
  }

  for i, case in ipairs(cases) do
    local check = fromRows(case.rows, 2)
    eq(#scanWholeBoard(check), 0, "case " .. i .. " has no four on it yet")
    -- Red's threat really is a threat and really is the only one, and yellow
    -- has no win of its own -- taking that would beat blocking, and did, the
    -- first time this test was written.
    local function winningDrops(p)
      local n, only = 0, nil
      local was = check.turn
      check.turn = p
      for _, c in ipairs(check:legalMoves()) do
        local r = check:place(c)
        if check:winsAt(c, r, p) then n, only = n + 1, c end
        check:unplace(c)
      end
      check.turn = was
      return n, only
    end

    local redThreats, redWin = winningDrops(1)
    eq(redThreats, 1, "case " .. i .. ": red has exactly one winning drop")
    eq(redWin, case.want, "case " .. i .. ": and it is the column yellow must take")
    eq(winningDrops(2), 0, "case " .. i .. ": yellow has no win to prefer")

    for depth = 2, 6 do
      local b = fromRows(case.rows, 2)
      local ai = botFor(b, { maxDepth = depth })
      eq(ai:solve(), case.want, string.format("case %d at depth %d blocks", i, depth))
    end
  end
end)

test("winning beats blocking when the bot can do both", function()
  -- Red can complete on the bottom row at either end; yellow is one disc from
  -- a vertical four in column 7. Taking the win is the only right answer.
  local b = fromRows({
    ".......",
    ".......",
    ".......",
    "......2",
    ".1....2",
    ".111.22",
  }, 1)
  eq(b.state, "playing", "the position is not already decided")
  for depth = 1, 5 do
    local ai = botFor(b, { maxDepth = depth })
    local mv = ai:solve()
    ok(mv == 1 or mv == 5,
      string.format("depth %d completes its own four (played %s)", depth, tostring(mv)))
    ok(ai.bestValue >= WIN_SCORE - 1000, "and scores it as a win")
  end
end)

test("the bot never returns an illegal column, at any depth or budget", function()
  local rand = seededRand(777)
  local checked = 0

  -- Forty games is about twenty thousand questions, which is plenty; this is
  -- the most expensive test in the file by a long way, because the depth-7
  -- corner of the grid below is a full search every time.
  for _ = 1, 40 do
    local b = newBoard({ rand = rand })
    -- Walk a random game, asking the bot for a move in every position, with a
    -- different depth and budget each time -- including budgets far too small
    -- to finish even depth one.
    while not b:isOver() do
      for _, depth in ipairs({ 1, 2, 4, 7 }) do
        for _, budget in ipairs({ 1, 3, 25, 400, 50000 }) do
          local ai = Board.AI.new(b, { maxDepth = depth, nodeBudget = budget, rand = rand })
          local mv = ai:solve()
          ok(mv ~= nil, "the bot always names a move")
          ok(b:open(mv), string.format("column %s is legal (depth %d, budget %d)",
            tostring(mv), depth, budget))
          checked = checked + 1
        end
      end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end
  end
  ok(checked > 8000, "asked the bot a lot of questions (" .. checked .. ")")
end)

test("a bot with no legal moves says so instead of guessing", function()
  local b = newBoard()
  for c = 1, COLS do
    for _ = 1, ROWS do
      local r = ROWS - b.heights[c]
      b.cells[(r - 1) * COLS + c] = 1
      b.heights[c] = b.heights[c] + 1
      b.nplaced = b.nplaced + 1
    end
  end
  eq(b.nplaced, COLS * ROWS, "the board really is full")
  eq(#b:legalMoves(), 0, "and has no legal moves")
  local ai = botFor(b, { maxDepth = 4 })
  eq(ai:solve(), nil, "no move to give")
  eq(ai:stop(), nil, "and stop() invents nothing either")
end)

test("blunders happen only at the level that asks for them, and stay legal", function()
  local rand = seededRand(2024)
  local b = playCols({ 4, 4, 3, 3, 5 }, { rand = rand })

  local blunders = 0
  for _ = 1, 400 do
    local ai = Board.AI.new(b, { maxDepth = 2, blunder = 0.35, nodeBudget = 5000, rand = rand })
    local mv = ai:solve()
    ok(b:open(mv), "even a blunder is a legal column")
    if ai.blundered then blunders = blunders + 1 end
  end
  ok(blunders > 90 and blunders < 220,
    string.format("roughly a third of moves blundered (%d of 400)", blunders))

  for _ = 1, 100 do
    local ai = Board.AI.new(b, { maxDepth = 4, blunder = 0, nodeBudget = 50000, rand = rand })
    ai:solve()
    eq(ai.blundered, false, "a blunder-free level never blunders")
  end
end)

-- ------------------------------------------- alpha-beta against minimax -----

-- A slow, obviously-correct negamax with no pruning, no ordering and no
-- iterative deepening. It duplicates nothing from game.lua except the scoring
-- primitives, and it exists purely to be the second opinion.
local function naive(b, depth, ply)
  local best = -math.huge
  for c = 1, COLS do
    if b:open(c) then
      local p = b.turn
      local r = b:place(c)
      local v
      if b:winsAt(c, r, p) then
        v = WIN_SCORE - ply
      elseif b:isFull() then
        v = 0
      elseif depth <= 1 then
        v = (p == 1) and b.score or -b.score
      else
        v = -naive(b, depth - 1, ply + 1)
      end
      b:unplace(c)
      if v > best then best = v end
    end
  end
  return best
end

-- The value of each root move under the unpruned search, at the given depth.
local function naiveRootValues(b, depth)
  local vals = {}
  for c = 1, COLS do
    if b:open(c) then
      local p = b.turn
      local r = b:place(c)
      if b:winsAt(c, r, p) then
        vals[c] = WIN_SCORE
      elseif b:isFull() then
        vals[c] = 0
      elseif depth <= 1 then
        vals[c] = (p == 1) and b.score or -b.score
      else
        vals[c] = -naive(b, depth - 1, 1)
      end
      b:unplace(c)
    end
  end
  return vals
end

test("alpha-beta picks a move of the same value as unpruned minimax", function()
  -- The single best check that the search is right: pruning is only allowed
  -- to be faster, never to change the answer. Alpha-beta may prefer a
  -- different column when several are equally good, so the assertion is on
  -- the *value* of the move it picked, scored by the slow search.
  local rand = seededRand(864213)
  local compared, agreedOnColumn = 0, 0

  for depth = 1, 5 do
    for trial = 1, 40 do
      -- A random reachable position, of a random age.
      local b = newBoard({ rand = rand })
      for _ = 1, rand(24) - 1 do
        if b:isOver() then break end
        local legal = b:legalMoves()
        b:drop(legal[rand(#legal)])
      end

      if not b:isOver() then
        local ai = botFor(b, { maxDepth = depth })
        local mv = ai:solve()
        local d = ai.completedDepth or depth
        local vals = naiveRootValues(b, d)

        local bestVal = -math.huge
        for _, v in pairs(vals) do if v > bestVal then bestVal = v end end

        ok(vals[mv] ~= nil, "the chosen column was legal")
        eq(vals[mv], bestVal, string.format(
          "depth %d trial %d: alpha-beta chose column %s worth %s, best is %s (%s)",
          d, trial, tostring(mv), tostring(vals[mv]), tostring(bestVal), boardString(b)))
        eq(ai.bestValue, bestVal, "and reported that value as its own")

        if vals[mv] == bestVal then agreedOnColumn = agreedOnColumn + 1 end
        compared = compared + 1
      end
    end
  end
  ok(compared > 150, "compared a lot of positions (" .. compared .. ")")
end)

test("pruning really does prune", function()
  -- If alpha-beta were somehow visiting as many nodes as the unpruned search,
  -- the test above would pass and the bot would still be unusable on a
  -- handheld. Count the nodes and insist on the saving.
  local rand = seededRand(5150)
  local b = newBoard({ rand = rand })
  for _ = 1, 6 do
    local legal = b:legalMoves()
    b:drop(legal[rand(#legal)])
  end

  local ai = botFor(b, { maxDepth = 6 })
  ai:solve()
  -- An unpruned depth-6 search of a 7-wide tree is 7^6 = 117649 nodes, and
  -- iterative deepening means the count below includes depths 1..5 as well.
  ok(ai.nodes < 117649 / 4,
    string.format("depth 6 took %d nodes, well under the unpruned 117649", ai.nodes))
end)

-- --------------------------------------------- incremental against one-shot --

test("the sliced search returns exactly what the one-shot search returns", function()
  -- The property the whole on.timer() design rests on: the node budget
  -- decides when think() answers, never what it answers.
  local rand = seededRand(60451)
  local compared = 0

  for _ = 1, 60 do
    local b = newBoard({ rand = rand })
    for _ = 1, rand(20) - 1 do
      if b:isOver() then break end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end

    if not b:isOver() then
      for _, depth in ipairs({ 2, 4, 6 }) do
        local oneShot = botFor(b, { maxDepth = depth })
        local want = oneShot:think(10 ^ 9)
        ok(want ~= nil, "the one-shot search finished in a single call")

        for _, slice in ipairs({ 1, 3, 17, 100 }) do
          local sliced = botFor(b, { maxDepth = depth })
          local got, ticks
          for i = 1, 2000000 do
            got = sliced:think(slice)
            if got then ticks = i break end
          end
          eq(got, want, string.format("slice %d agreed with one shot at depth %d", slice, depth))
          eq(sliced.nodes, oneShot.nodes, "and visited exactly the same nodes")
          eq(sliced.completedDepth, oneShot.completedDepth, "reaching the same depth")
          ok(ticks ~= nil, "the sliced search terminated")
          compared = compared + 1
        end
      end
    end
  end
  ok(compared > 400, "compared a lot of slicings (" .. compared .. ")")
end)

test("a search sliced thinly still answers within a sane number of ticks", function()
  -- The handheld's budget per tick is small. Nothing may need an unbounded
  -- number of ticks to produce a move.
  local rand = seededRand(1717)
  local worst = 0
  for _ = 1, 30 do
    local b = newBoard({ rand = rand })
    for _ = 1, rand(16) do
      if b:isOver() then break end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end
    if not b:isOver() then
      local L = Board.LEVELS[3]
      local ai = Board.AI.new(b, { maxDepth = L.maxDepth, nodeBudget = L.nodeBudget, rand = rand })
      local ticks = 0
      repeat
        ticks = ticks + 1
        local mv = ai:think(100)
      until ai.done or ticks > 5000
      ok(ai.done, "the search finished")
      if ticks > worst then worst = ticks end
    end
  end
  -- 60000 nodes at 100 a tick is 600 ticks, so this is really a check that
  -- the budget is honoured rather than overshot.
  ok(worst <= 601, "worst case was " .. worst .. " ticks of 100 nodes")
end)

test("stop() settles for the best move so far and it is always legal", function()
  local rand = seededRand(818)
  for _ = 1, 60 do
    local b = newBoard({ rand = rand })
    for _ = 1, rand(20) do
      if b:isOver() then break end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end
    if not b:isOver() then
      local snapshot = boardString(b)
      local ai = botFor(b, { maxDepth = 9 })
      for _ = 1, rand(5) - 1 do ai:think(37) end -- interrupt at an awkward moment
      local mv = ai:stop()
      ok(b:open(mv), "stop() gave a legal column")
      eq(ai:think(1000), mv, "and stands by it afterwards")
      -- Whatever it settled on, the game's board is untouched.
      eq(boardString(b), snapshot, "the search left the board exactly as it found it")
      eq(b.score, fullScore(b), "and its score with it")
    end
  end
end)

test("a search in progress never shows up on the game's board", function()
  -- The bot searches by playing discs and taking them back, and on a handheld
  -- it is suspended part-way through with several still played. If it did that
  -- on the board being played on, main.lua would paint the search: phantom
  -- discs flickering in and out while the bot thought. So it searches a copy,
  -- and the board it was handed must be untouched at every single step.
  local rand = seededRand(90210)
  local peeks = 0

  for _ = 1, 40 do
    local b = newBoard({ rand = rand })
    for _ = 1, rand(20) do
      if b:isOver() then break end
      local legal = b:legalMoves()
      b:drop(legal[rand(#legal)])
    end
    if not b:isOver() then
      local snapshot, score, n, turn = boardString(b), b.score, b.nplaced, b.turn
      local ai = botFor(b, { maxDepth = 7, nodeBudget = 30000 })
      -- Look at the board after every slice, not just at the end.
      repeat
        ai:think(23)
        eq(boardString(b), snapshot, "the board is untouched mid-search")
        eq(b.score, score, "and so is its score")
        eq(b.nplaced, n, "and its disc count")
        eq(b.turn, turn, "and whose move it is")
        peeks = peeks + 1
      until ai.done or peeks > 20000
    end
  end
  ok(peeks > 200, "peeked at the board mid-search a lot (" .. peeks .. ")")
end)

test("stopping early never gives a worse-than-random move", function()
  -- Iterative deepening's promise: there is always a usable move, however
  -- little work was allowed. Even one tick must beat picking at random.
  local rand = seededRand(24680)
  local wins = 0
  for game = 1, 60 do
    local b = newBoard({ rand = rand })
    local bot = (game % 2 == 1) and 1 or 2
    while not b:isOver() do
      if b.turn == bot then
        local ai = Board.AI.new(b, { maxDepth = 7, nodeBudget = 60000, rand = rand })
        ai:think(60) -- one tick's worth, then take whatever it has
        b:drop(ai:stop())
      else
        local legal = b:legalMoves()
        b:drop(legal[rand(#legal)])
      end
    end
    if b.winner == bot then wins = wins + 1 end
  end
  ok(wins >= 50, string.format("a one-tick bot still beat random %d times in 60", wins))
end)

-- ------------------------------------------------------------------ fuzz ----

test("fuzz: the bot essentially never loses to a random player", function()
  local rand = seededRand(31415)
  local results = { bot = 0, random = 0, draw = 0 }

  for game = 1, 60 do
    local b = newBoard({ rand = rand })
    local bot = (game % 2 == 1) and 1 or 2
    local moves = 0

    while not b:isOver() do
      local c
      if b.turn == bot then
        local ai = Board.AI.new(b, { maxDepth = 6, nodeBudget = 60000, rand = rand })
        c = ai:solve()
      else
        local legal = b:legalMoves()
        c = legal[rand(#legal)]
      end
      ok(b:open(c), "the move played was legal")
      ok(b:drop(c) ~= nil, "and it landed")
      moves = moves + 1
      ok(moves <= COLS * ROWS, "the game is bounded")
    end

    if b.state == "draw" then results.draw = results.draw + 1
    elseif b.winner == bot then results.bot = results.bot + 1
    else results.random = results.random + 1 end

    -- However it ended, it ended legally.
    if b.state == "won" then
      ok(b.line and #b.line >= CONNECT, "a win leaves a highlightable line")
      local scan = scanWholeBoard(b)
      ok(#scan > 0 and scan[1].p == b.winner, "a whole-board scan agrees")
    else
      eq(b.nplaced, COLS * ROWS, "a draw is a full board")
      eq(#scanWholeBoard(b), 0, "with no line on it")
    end
  end

  eq(results.random, 0, string.format("the bot lost %d of 60 games to random play", results.random))
  ok(results.bot >= 58, string.format("bot %d, random %d, drawn %d",
    results.bot, results.random, results.draw))
end)

test("fuzz: harder levels beat easier ones", function()
  -- Difficulty has to actually mean something. Hard against Easy, both sides
  -- of the board, over enough games that the blunders average out.
  local rand = seededRand(16180)
  local hardWins, easyWins, draws = 0, 0, 0

  for game = 1, 24 do
    local b = newBoard({ rand = rand })
    local hard = (game % 2 == 1) and 1 or 2
    while not b:isOver() do
      local level = (b.turn == hard) and 3 or 1
      local ai = Board.AI.fromLevel(b, level, { rand = rand })
      b:drop(ai:solve())
    end
    if b.state == "draw" then draws = draws + 1
    elseif b.winner == hard then hardWins = hardWins + 1
    else easyWins = easyWins + 1 end
  end

  ok(hardWins >= 20, string.format("Hard won %d, Easy won %d, %d drawn", hardWins, easyWins, draws))
end)

-- Plays exactly the way main.lua does: Board.TICK_NODES per timer tick, and
-- the level's thinkTicks as the cap on the turn. This -- not solve() -- is the
-- bot that actually ships, so it is the one the difficulty claims are made
-- about.
local function tickBot(b, level, rand)
  local L = Board.LEVELS[level]
  local ai = Board.AI.fromLevel(b, level, { rand = rand })
  local mv
  for _ = 1, L.thinkTicks do
    mv = ai:think(Board.TICK_NODES)
    if mv then break end
  end
  return mv or ai:stop(), ai
end

test("the shipped tick budget reaches the depth the levels claim", function()
  -- The difficulty table is calibrated against Board.TICK_NODES, so changing
  -- either means changing both. These are the depths the handheld should see,
  -- and the comment above Board.LEVELS quotes the numbers this prints.
  --
  -- Positions with a forced result are left out of the average: the search
  -- stops the moment it proves a win or a loss, so a mate in one reports
  -- depth 1 no matter how much budget it was given, which is correct and
  -- would drag the mean down for no reason.
  local WANT = { 2.0, 4.0, 5.0, 5.5 }
  print("")
  print("  level      ticks   mean nodes   mean depth   min   max")

  for level = 1, #Board.LEVELS do
    local L = Board.LEVELS[level]
    local rand = seededRand(4242)
    local depths, nodes, n, minD, maxD = 0, 0, 0, 99, 0

    for _ = 1, 40 do
      local b = newBoard({ rand = rand })
      for _ = 1, 4 + rand(16) do
        if b:isOver() then break end
        local legal = b:legalMoves()
        b:drop(legal[rand(#legal)])
      end

      if not b:isOver() then
        local mv, ai = tickBot(b, level, rand)
        ok(b:open(mv), L.name .. " played a legal column")

        if not ai.blundered then
          -- Depth 1 costs seven nodes, so there is always a completed search
          -- behind the move, never an unexamined fallback.
          ok((ai.completedDepth or 0) >= 1, L.name .. " completed at least one depth")
          if math.abs(ai.bestValue) < WIN_SCORE - 1000 then
            local d = ai.completedDepth or 0
            depths, nodes, n = depths + d, nodes + ai.nodes, n + 1
            if d < minD then minD = d end
            if d > maxD then maxD = d end
          end
        end
      end
    end

    local mean = depths / math.max(1, n)
    print(string.format("  %-9s %6d %12d %12.1f %5d %5d",
      L.name, L.thinkTicks, math.floor(nodes / math.max(1, n)), mean, minD, maxD))
    -- Easy blunders a third of the time and every level stops early on a
    -- forced result, so well under 40 of the positions feed the average.
    ok(n >= 12, L.name .. ": enough unforced positions to average over (" .. n .. ")")
    ok(mean >= WANT[level], string.format(
      "%s averaged depth %.1f in its %d ticks (wanted at least %.1f)",
      L.name, mean, L.thinkTicks, WANT[level]))
    if level > 1 then
      ok(L.thinkTicks * Board.TICK_NODES <= L.nodeBudget,
        L.name .. ": the tick cap is what binds on a handheld, not the node budget")
    end
  end

  -- And the levels really are ordered by how much thinking they get.
  for level = 2, #Board.LEVELS do
    ok(Board.LEVELS[level].thinkTicks > Board.LEVELS[level - 1].thinkTicks,
      Board.LEVELS[level].name .. " thinks for longer than " .. Board.LEVELS[level - 1].name)
    ok(Board.LEVELS[level].maxDepth > Board.LEVELS[level - 1].maxDepth,
      Board.LEVELS[level].name .. " searches deeper than " .. Board.LEVELS[level - 1].name)
  end
  print("")
end)

test("fuzz: the shipped bot gets harder as the difficulty goes up", function()
  -- Difficulty has to mean something to the player, not just to the search.
  -- Each level plays under the same tick budget main.lua gives it.
  local rand = seededRand(24681)
  local wins = { 0, 0, 0, 0 }
  local pairs_ = { { 3, 1 }, { 4, 2 } }

  for _, m in ipairs(pairs_) do
    local strong, weak = m[1], m[2]
    local strongWins, weakWins, draws = 0, 0, 0
    for game = 1, 16 do
      local b = newBoard({ rand = rand })
      local s = (game % 2 == 1) and 1 or 2
      while not b:isOver() do
        b:drop((tickBot(b, (b.turn == s) and strong or weak, rand)))
      end
      if b.state == "draw" then draws = draws + 1
      elseif b.winner == s then strongWins = strongWins + 1
      else weakWins = weakWins + 1 end
    end
    ok(strongWins > weakWins, string.format(
      "%s beat %s %d-%d (%d drawn)", Board.LEVELS[strong].name,
      Board.LEVELS[weak].name, strongWins, weakWins, draws))
    wins[strong] = wins[strong] + strongWins
  end
end)

test("fuzz: Easy loses often enough that a beginner can win", function()
  -- The other half of the difficulty claim. A player who only ever blocks the
  -- obvious threat and otherwise plays the centre should beat Easy sometimes;
  -- if Easy were unbeatable the level would be mislabelled.
  local rand = seededRand(27182)

  -- A deliberately weak but not random opponent: win if you can, block if you
  -- must, else play the most central open column.
  local function beginner(b)
    for _, c in ipairs(b:legalMoves()) do
      local p = b.turn
      local r = b:place(c)
      local won = b:winsAt(c, r, p)
      b:unplace(c)
      if won then return c end
    end
    for _, c in ipairs(b:legalMoves()) do
      b.turn = 3 - b.turn
      local p = b.turn
      local r = b:place(c)
      local threat = b:winsAt(c, r, p)
      b:unplace(c)
      b.turn = 3 - b.turn
      if threat then return c end
    end
    return b:legalMoves()[1]
  end

  local human, easy, draws = 0, 0, 0
  for game = 1, 30 do
    local b = newBoard({ rand = rand })
    local bot = (game % 2 == 1) and 2 or 1
    while not b:isOver() do
      local c
      if b.turn == bot then
        c = Board.AI.fromLevel(b, 1, { rand = rand }):solve()
      else
        c = beginner(b)
      end
      b:drop(c)
    end
    if b.state == "draw" then draws = draws + 1
    elseif b.winner == bot then easy = easy + 1
    else human = human + 1 end
  end

  ok(human >= 5, string.format("a beginner beat Easy %d times in 30 (Easy %d, drawn %d)",
    human, easy, draws))
end)

-- ------------------------------------------------------ measured throughput --

test("search cost per depth, measured (not asserted, printed)", function()
  -- The numbers the budgets in Board.LEVELS were chosen from. Printed rather
  -- than asserted: node counts are a property of the position, and a machine's
  -- speed is not something to fail a build over.
  local rand = seededRand(11235)
  print("")
  print("  depth   mean nodes    max nodes     us/node   (cumulative, iterative deepening)")

  for depth = 1, 8 do
    local total, maxn, n = 0, 0, 0
    local t0 = os.clock()
    for k = 1, 12 do
      local b = newBoard({ rand = rand })
      for _ = 1, 4 + (k % 12) do
        if b:isOver() then break end
        local legal = b:legalMoves()
        b:drop(legal[rand(#legal)])
      end
      if not b:isOver() then
        local ai = botFor(b, { maxDepth = depth, nodeBudget = 10 ^ 9 })
        ai:solve()
        total, n = total + ai.nodes, n + 1
        if ai.nodes > maxn then maxn = ai.nodes end
      end
    end
    local dt = os.clock() - t0
    print(string.format("  %5d   %10d   %10d   %9.2f", depth,
      math.floor(total / math.max(1, n)), maxn, dt * 1e6 / math.max(1, total)))
  end
  print("")
  ok(true, "measured")
end)

table.sort(slowest, function(a, b) return a.secs > b.secs end)
print("\n  slowest tests:")
for i = 1, math.min(6, #slowest) do
  print(string.format("  %5.1fs  %s", slowest[i].secs, slowest[i].name))
end

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
