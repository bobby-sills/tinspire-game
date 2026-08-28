-- Tests for the pure chess logic and the bot. Run with:
--   make GAME=chess test
-- (or: GAME_SRC=src/chess lua tests/chess/run.lua   from the repo root)
--
-- Set CHESS_SLOW=1 to add the deep perft runs and the longer fuzzes. They are
-- off by default because 4.8M nodes of move generation in interpreted Lua is
-- a minute of wall clock, not a unit test.
--
-- The centre of gravity of this file is perft. Everything else here checks one
-- rule at a time and can only be as good as the case someone thought to write;
-- perft counts every leaf of the whole move tree against numbers that are
-- published and exact, so matching them proves castling, en passant,
-- promotion and check evasion all at once, in combinations nobody enumerated.
-- Two more properties near the bottom matter nearly as much: the pruned search
-- is checked against a slow, obviously-correct negamax written here rather
-- than reused from the game, and the sliced search against the same search run
-- in one shot.

package.path = (os.getenv("GAME_SRC") or "src/chess") .. "/?.lua;" .. package.path
local Chess = require("game")

local WHITE, BLACK = Chess.WHITE, Chess.BLACK
local PAWN, KNIGHT, BISHOP = Chess.PAWN, Chess.KNIGHT, Chess.BISHOP
local ROOK, QUEEN, KING = Chess.ROOK, Chess.QUEEN, Chess.KING
local MATE = Chess.AI.MATE
local SLOW = os.getenv("CHESS_SLOW") == "1"

local sq = Chess.squareFromName
local name = Chess.squareName

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
-- here -- a full move-tree walk and several hundred played-out games -- so it
-- is worth being able to see at a glance which part is costing the time.
local slowest = {}

local function test(nameOfTest, fn)
  current = nameOfTest
  local t0 = os.clock()
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
  slowest[#slowest + 1] = { name = nameOfTest, secs = os.clock() - t0 }
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

local function pos(fen, opts)
  local g, err = Chess.fromFEN(fen, opts)
  assert(g, tostring(err) .. " -- " .. tostring(fen))
  return g
end

local function moveName(m)
  if not m then return "nil" end
  local flag = Chess.moveFlag(m)
  if flag == Chess.FLAG_KCASTLE then return "O-O" end
  if flag == Chess.FLAG_QCASTLE then return "O-O-O" end
  local p = Chess.movePromo(m)
  return name(Chess.moveFrom(m)) .. name(Chess.moveTo(m))
    .. ((p ~= 0) and Chess.LETTER[p]:lower() or "")
end

-- Every legal move as a set of "e2e4"-style names, which is what makes the
-- rule tests below readable as chess rather than as square numbers.
local function moveSet(g)
  local out, moves = {}, {}
  local n = g:legalMoves(moves)
  for i = 1, n do out[moveName(moves[i])] = true end
  return out, n
end

local function findMove(g, text)
  local moves = {}
  local n = g:legalMoves(moves)
  for i = 1, n do
    if moveName(moves[i]) == text then return moves[i] end
  end
  return nil
end

local function playText(g, ...)
  for _, text in ipairs({ ... }) do
    local m = findMove(g, text)
    if not m then return false, text end
    if not g:play(m) then return false, text end
  end
  return true
end

-- Depth-first walk of the whole legal move tree. The one number in this file
-- that is checked against the outside world rather than against itself.
local perftBuf = {}
local function perft(g, depth)
  if depth == 0 then return 1 end
  local moves = perftBuf[depth]
  if not moves then moves = {}; perftBuf[depth] = moves end
  local n = g:generate(moves, false)
  local total = 0
  for i = 1, n do
    local us = g.side
    g:make(moves[i])
    if not g:attacked(g.king[us], g.side) then
      total = total + perft(g, depth - 1)
    end
    g:unmake()
  end
  return total
end

-- ======================================================== board and FEN ====

test("squares round-trip through files and ranks", function()
  for f = 1, 8 do
    for r = 1, 8 do
      local s = Chess.sqOf(f, r)
      eq(Chess.fileOf(s), f, "fileOf " .. name(s))
      eq(Chess.rankOf(s), r, "rankOf " .. name(s))
      eq(sq(name(s)), s, "name round-trip " .. name(s))
    end
  end
  eq(name(Chess.sqOf(1, 1)), "a1", "a1")
  eq(name(Chess.sqOf(8, 8)), "h8", "h8")
  -- a1 is dark and h1 is light: the one orientation fact everything else
  -- about bishops depends on.
  ok(not Chess.isLight(sq("a1")), "a1 is a dark square")
  ok(Chess.isLight(sq("h1")), "h1 is a light square")
  ok(Chess.isLight(sq("a8")), "a8 is a light square")
end)

test("the mailbox padding catches every off-board step", function()
  -- The whole point of 10x12 over 8x8: from any real square, every knight
  -- hop and every king step lands inside the array, on either a real square
  -- or the sentinel. Nothing may index past the ends.
  local g = Chess.new()
  local offsets = { -21, -19, -12, -8, 8, 12, 19, 21, -11, -10, -9, -1, 1, 9, 10, 11 }
  local checked = 0
  for f = 1, 8 do
    for r = 1, 8 do
      for _, d in ipairs(offsets) do
        local t = Chess.sqOf(f, r) + d
        ok(t >= 0 and t <= 119, "step stays in the array")
        ok(g.board[t] ~= nil, "step lands on a defined cell")
        checked = checked + 1
      end
    end
  end
  eq(checked, 64 * 16, "checked every step from every square")
end)

test("move encoding survives every from, to, promotion and flag", function()
  for _, from in ipairs({ 0, 21, 55, 98, 119 }) do
    for _, to in ipairs({ 0, 28, 64, 91, 119 }) do
      for promo = 0, 5 do
        for flag = 0, 4 do
          local m = Chess.encode(from, to, promo, flag)
          local a, b, c, d = Chess.decode(m)
          ok(a == from and b == to and c == promo and d == flag,
            string.format("decode(encode(%d,%d,%d,%d))", from, to, promo, flag))
          eq(Chess.moveFrom(m), from, "moveFrom")
          eq(Chess.moveTo(m), to, "moveTo")
          eq(Chess.movePromo(m), promo, "movePromo")
          eq(Chess.moveFlag(m), flag, "moveFlag")
        end
      end
    end
  end
end)

test("FEN parses and prints back the same string", function()
  local fens = {
    Chess.START_FEN,
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 3",
  }
  for _, f in ipairs(fens) do
    eq(pos(f):toFEN(), f, "round-trip")
  end

  local g = pos("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 3")
  eq(g.side, WHITE, "side to move")
  eq(g.ep, sq("d6"), "en passant square")
  eq(g.half, 0, "halfmove clock")
  eq(g.full, 3, "fullmove number")

  local k = pos("r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")
  ok(k.castle[Chess.WK] and k.castle[Chess.WQ], "white keeps both rights")
  ok(k.castle[Chess.BK] and k.castle[Chess.BQ], "black keeps both rights")
end)

test("FEN rejects what it cannot represent", function()
  for _, bad in ipairs({
    "not a fen",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP w KQkq - 0 1",         -- too few ranks
    "rnbqkbnrx/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", -- bad piece
    "rnbqkbnr/ppppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", -- long rank
    "8/8/8/8/8/8/8/8 w - - 0 1",                                -- no kings
  }) do
    local g, err = Chess.fromFEN(bad)
    ok(g == nil and type(err) == "string", "rejected: " .. bad:sub(1, 30))
  end
end)

-- ================================================================ perft ====
--
-- Positions and counts from the Chess Programming Wiki's Perft Results page,
-- cross-checked against the perftsuite.epd shipped with several open-source
-- engines. They are exact: an engine either matches them or has a bug.

local PERFT = {
  { name = "initial",   fen = Chess.START_FEN,
    counts = { 20, 400, 8902, 197281, 4865609 } },
  { name = "kiwipete",  fen = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    counts = { 48, 2039, 97862, 4085603 } },
  { name = "position 3", fen = "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    counts = { 14, 191, 2812, 43238, 674624 } },
  { name = "position 4", fen = "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    counts = { 6, 264, 9467, 422333 } },
  { name = "position 5", fen = "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    counts = { 44, 1486, 62379, 2103487 } },
  { name = "position 6", fen = "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10",
    counts = { 46, 2079, 89890, 3894594 } },
}

-- Depths 1-3 always: about 200k nodes across all six, which is a second or so.
for _, P in ipairs(PERFT) do
  test("perft " .. P.name .. " to depth 3", function()
    local g = pos(P.fen)
    for depth = 1, math.min(3, #P.counts) do
      eq(perft(g, depth), P.counts[depth],
        string.format("%s perft(%d)", P.name, depth))
    end
    eq(g:toFEN(), P.fen, "the walk left the position exactly as it found it")
  end)
end

-- Position 3 is cheap enough to take further even in the fast pass, and it is
-- the one built to catch en passant and promotion bugs.
test("perft position 3 to depth 5", function()
  local g = pos(PERFT[3].fen)
  eq(perft(g, 4), 43238, "position 3 perft(4)")
  eq(perft(g, 5), 674624, "position 3 perft(5)")
end)

if SLOW then
  for _, P in ipairs(PERFT) do
    test("perft " .. P.name .. " to full depth (slow)", function()
      local g = pos(P.fen)
      for depth = 4, #P.counts do
        eq(perft(g, depth), P.counts[depth],
          string.format("%s perft(%d)", P.name, depth))
      end
    end)
  end
end

-- ===================================================== the rules, one by one ==

test("castling: both sides, when nothing is in the way", function()
  local g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  local set = moveSet(g)
  ok(set["O-O"], "white may castle kingside")
  ok(set["O-O-O"], "white may castle queenside")

  local b = pos("r3k2r/8/8/8/8/8/8/R3K2R b KQkq - 0 1")
  local bset = moveSet(b)
  ok(bset["O-O"], "black may castle kingside")
  ok(bset["O-O-O"], "black may castle queenside")

  -- And the rook actually moves with the king.
  ok(playText(g, "O-O"), "played O-O")
  eq(g.board[sq("g1")], Chess.code(WHITE, KING), "king on g1")
  eq(g.board[sq("f1")], Chess.code(WHITE, ROOK), "rook on f1")
  eq(g.board[sq("h1")], Chess.EMPTY, "h1 empty")
  eq(g.board[sq("e1")], Chess.EMPTY, "e1 empty")

  local q = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(q, "O-O-O"), "played O-O-O")
  eq(q.board[sq("c1")], Chess.code(WHITE, KING), "king on c1")
  eq(q.board[sq("d1")], Chess.code(WHITE, ROOK), "rook on d1")
  eq(q.board[sq("a1")], Chess.EMPTY, "a1 empty")
end)

test("castling: blocked by a piece in between", function()
  ok(not moveSet(pos("r3k2r/8/8/8/8/8/8/R3KB1R w KQkq - 0 1"))["O-O"],
    "bishop on f1 stops kingside")
  ok(not moveSet(pos("r3k2r/8/8/8/8/8/8/R2QK2R w KQkq - 0 1"))["O-O-O"],
    "queen on d1 stops queenside")
  ok(not moveSet(pos("r3k2r/8/8/8/8/8/8/RN2K2R w KQkq - 0 1"))["O-O-O"],
    "knight on b1 stops queenside")
end)

test("castling: not out of, through, or into check", function()
  -- Out of check: a rook on e8 attacks the king where it stands.
  local out = moveSet(pos("4r2k/8/8/8/8/8/8/R3K2R w KQ - 0 1"))
  ok(not out["O-O"], "may not castle out of check, kingside")
  ok(not out["O-O-O"], "may not castle out of check, queenside")

  -- Through check: f1 and d1 are the squares the king passes over.
  ok(not moveSet(pos("5rk1/8/8/8/8/8/8/R3K2R w KQ - 0 1"))["O-O"],
    "may not castle through an attacked f1")
  ok(not moveSet(pos("3rk3/8/8/8/8/8/8/R3K2R w KQ - 0 1"))["O-O-O"],
    "may not castle through an attacked d1")

  -- Into check: g1 and c1 are the squares the king lands on.
  ok(not moveSet(pos("6rk/8/8/8/8/8/8/R3K2R w KQ - 0 1"))["O-O"],
    "may not castle into an attacked g1")
  ok(not moveSet(pos("2r1k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"))["O-O-O"],
    "may not castle into an attacked c1")

  -- But b1 may be attacked and queenside castling is still legal: the king
  -- never touches it. This is the half of the rule that is usually wrong.
  local b1 = moveSet(pos("1r2k3/8/8/8/8/8/8/R3K2R w KQ - 0 1"))
  ok(b1["O-O-O"], "an attacked b1 does not stop queenside castling")
  ok(b1["O-O"], "and kingside is unaffected too")

  -- The rook may be attacked and it is still legal, on either side.
  ok(moveSet(pos("4k2r/8/8/8/8/8/8/R3K2R w KQ - 0 1"))["O-O"],
    "an attacked h1 rook does not stop kingside castling")
end)

test("castling rights are lost by moving, and only where they should be", function()
  local g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "e1e2"), "king steps off e1")
  ok(not g.castle[Chess.WK] and not g.castle[Chess.WQ], "king move kills both white rights")
  ok(g.castle[Chess.BK] and g.castle[Chess.BQ], "and leaves black's alone")

  g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "h1h2"), "kingside rook moves")
  ok(not g.castle[Chess.WK], "kingside right gone")
  ok(g.castle[Chess.WQ], "queenside right kept")

  g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "a1a2"), "queenside rook moves")
  ok(g.castle[Chess.WK], "kingside right kept")
  ok(not g.castle[Chess.WQ], "queenside right gone")

  -- A rook captured where it stands loses the right just as surely.
  g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "a1a8"), "rook takes rook on a8")
  ok(not g.castle[Chess.BQ], "black's queenside right dies with the rook")
  ok(g.castle[Chess.BK], "black's kingside right survives")

  -- And a rook that comes back to its home square does not get it back.
  g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "h1h2", "h8h7", "h2h1", "h7h8"), "rooks go out and come home")
  ok(not g.castle[Chess.WK] and not g.castle[Chess.BK], "rights do not come back")
end)

test("castling rights survive an undo", function()
  local g = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  ok(playText(g, "e1e2"), "king moves")
  ok(not g.castle[Chess.WK], "right lost")
  ok(g:takeback(), "took it back")
  ok(g.castle[Chess.WK] and g.castle[Chess.WQ], "rights restored by the undo")
  ok(moveSet(g)["O-O"], "and castling is on the move list again")
end)

test("en passant: available only on the move right after the double push", function()
  local g = pos("4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1")
  ok(playText(g, "d7d5"), "black double-pushes past the white pawn")
  eq(g.ep, sq("d6"), "the en passant square is behind the pawn")
  ok(moveSet(g)["e5d6"], "exd6 is available immediately")

  -- Let a move go by and it is gone for good.
  local h = pos("4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1")
  ok(playText(h, "d7d5", "e1d1", "e8d8"), "a move each way passes")
  eq(h.ep, 0, "the en passant square has cleared")
  ok(not moveSet(h)["e5d6"], "exd6 is no longer legal")

  -- A single push offers nothing, even onto the same square.
  local s = pos("4k3/8/3p4/4P3/8/8/8/4K3 b - - 0 1")
  ok(playText(s, "d6d5"), "black pushes one square")
  eq(s.ep, 0, "a single push sets no en passant square")
  ok(not moveSet(s)["e5d6"], "and offers no capture")
end)

test("en passant removes the pawn that is not on the destination square", function()
  local g = pos("4k3/3p4/8/4P3/8/8/8/4K3 b - - 0 1")
  ok(playText(g, "d7d5", "e5d6"), "double push, then the capture")
  eq(g.board[sq("d6")], Chess.code(WHITE, PAWN), "the capturing pawn is on d6")
  eq(g.board[sq("d5")], Chess.EMPTY, "the captured pawn is gone from d5")
  eq(g.board[sq("e5")], Chess.EMPTY, "and e5 is empty behind it")
  eq(g.counts[Chess.code(BLACK, PAWN)], 0, "black is a pawn down")

  ok(g:takeback(), "undo the capture")
  eq(g.board[sq("d5")], Chess.code(BLACK, PAWN), "the pawn comes back to d5")
  eq(g.board[sq("e5")], Chess.code(WHITE, PAWN), "and the capturer to e5")
  eq(g.counts[Chess.code(BLACK, PAWN)], 1, "counts restored")
end)

test("en passant is illegal when it would expose the king", function()
  -- The classic: taking en passant lifts two pawns off the fifth rank at
  -- once, and the rook behind them hits the king. No pin test would find
  -- this; only actually playing the move and looking at the king does.
  local g = pos("8/8/8/K2pP2r/8/8/8/7k w - d6 0 1")
  local set = moveSet(g)
  ok(not set["e5d6"], "en passant that uncovers the rook is rejected")
  ok(set["e5e6"], "but pushing the same pawn is fine")

  -- The same position with the rook gone: now it is legal.
  local h = pos("8/8/8/K2pP3/8/8/8/7k w - d6 0 1")
  ok(moveSet(h)["e5d6"], "with nothing behind, en passant is legal")
end)

test("promotion offers all four pieces, and each one arrives", function()
  local g = pos("8/4P3/8/8/8/8/8/K6k w - - 0 1")
  local set, n = moveSet(g)
  for _, ch in ipairs({ "q", "r", "b", "n" }) do
    ok(set["e7e8" .. ch], "e8=" .. ch:upper() .. " is offered")
  end

  for _, case in ipairs({ { "q", QUEEN }, { "r", ROOK }, { "b", BISHOP }, { "n", KNIGHT } }) do
    local h = pos("8/4P3/8/8/8/8/8/K6k w - - 0 1")
    ok(playText(h, "e7e8" .. case[1]), "played e8=" .. case[1])
    eq(h.board[sq("e8")], Chess.code(WHITE, case[2]), "the right piece arrived")
    eq(h.counts[Chess.code(WHITE, PAWN)], 0, "the pawn is spent")
    ok(h:takeback(), "undo")
    eq(h.board[sq("e7")], Chess.code(WHITE, PAWN), "the pawn is back on e7")
    eq(h.board[sq("e8")], Chess.EMPTY, "and e8 is empty again")
  end

  -- Capturing into promotion, on both diagonals, is four more moves each.
  local c = pos("3r1r2/4P3/8/8/8/8/8/K6k w - - 0 1")
  local cset, cn = moveSet(c)
  ok(cset["e7d8q"] and cset["e7f8n"], "captures promote too")
  -- Three destinations for the pawn -- push, and a rook on each diagonal --
  -- times four pieces, plus the king's three squares.
  eq(cn, 15, "one pawn one square from the eighth rank has twelve moves")

  -- Black promotes downward.
  local b = pos("K6k/8/8/8/8/8/4p3/8 b - - 0 1")
  ok(moveSet(b)["e2e1q"], "black promotes on the first rank")
  ok(playText(b, "e2e1n"), "underpromotion to a knight")
  eq(b.board[sq("e1")], Chess.code(BLACK, KNIGHT), "black knight on e1")
end)

test("a move that leaves your own king in check is not a move", function()
  -- Absolute pin: the bishop cannot leave the file.
  local g = pos("4k3/8/8/8/8/4B3/8/4K2r w - - 0 1")
  local set = moveSet(g)
  ok(not set["e3d4"], "the pinned bishop may not step off the file")
  ok(not set["e3c5"], "nor anywhere else off it")

  -- A pin along a rank, with the pinned piece able to move along it.
  local r = pos("4k3/8/8/8/8/8/8/K2R3r w - - 0 1")
  local rset = moveSet(r)
  ok(rset["d1e1"], "a rook pinned along the rank may still slide along it")
  ok(rset["d1h1"], "including all the way to the pinner")
  ok(not rset["d1d8"], "but not off the rank")

  -- In check, only the moves that answer it exist.
  local c = pos("4k3/8/8/8/8/8/4r3/4K3 w - - 0 1")
  local cset, cn = moveSet(c)
  eq(cn, 3, "three answers to the check")
  for mv in pairs(cset) do
    ok(mv:sub(1, 2) == "e1", "every legal move is the king's: " .. mv)
  end
  ok(cset["e1e2"], "the king may take the checking rook")
  ok(not cset["e1d2"] and not cset["e1f2"], "and may not stay on the rook's rank")

  -- The king may not walk into a square the enemy covers, including the
  -- squares the enemy king covers.
  local adjacent = moveSet(pos("8/8/8/8/8/8/5k2/7K w - - 0 1"))
  ok(not adjacent["h1g1"] and not adjacent["h1g2"], "kings may not touch")
  ok(adjacent["h1h2"], "but h2 is two files from f2, so that one is legal")
end)

test("checkmate and stalemate are told apart", function()
  -- Fool's mate: mate, and White has nothing.
  local mate = pos("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
  eq(select(2, moveSet(mate)), 0, "no legal moves")
  ok(mate:inCheck(), "and the king is attacked")
  ok(mate:isOver(), "game over")
  eq(mate.result.kind, "checkmate", "checkmate")
  eq(mate.result.winner, BLACK, "black wins")

  -- The classic stalemate: no legal move, no check.
  local stale = pos("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
  eq(select(2, moveSet(stale)), 0, "no legal moves")
  ok(not stale:inCheck(), "but the king is not attacked")
  eq(stale.result.kind, "stalemate", "stalemate")
  eq(stale.result.winner, nil, "nobody wins")

  -- A stalemate where the side to move has pieces, just none that can move.
  local pinned = pos("k7/P7/K7/8/8/8/8/8 b - - 0 1")
  eq(pinned.result.kind, "stalemate", "stalemate with a pawn on the board")

  -- Reached by playing it, not just by parsing it.
  local g = Chess.new()
  ok(playText(g, "f2f3", "e7e5", "g2g4", "d8h4"), "fool's mate played out")
  eq(g.result.kind, "checkmate", "recognised after the move that gave it")
  eq(g.result.winner, BLACK, "black delivered it")
end)

test("the fifty-move rule", function()
  -- The counter resets on a capture and on a pawn move, and on nothing else.
  local g = pos("4k3/8/8/8/8/8/4P3/4K3 w - - 10 30")
  eq(g.half, 10, "parsed the clock")
  ok(playText(g, "e1d1"), "a king move")
  eq(g.half, 11, "the clock ticks on")
  ok(playText(g, "e8d8", "e2e4"), "a pawn move")
  eq(g.half, 0, "a pawn move resets it")

  local c = pos("4k3/8/8/8/8/8/4K3/R6r w - - 40 60")
  ok(playText(c, "a1h1"), "a capture")
  eq(c.half, 0, "a capture resets it")

  -- At 100 half-moves it is a draw. Set up one short and step over the line.
  local d = pos("4k3/8/8/8/8/8/8/R3K3 w - - 99 80")
  ok(not d:isOver(), "99 is not yet a draw")
  ok(playText(d, "a1a2"), "one more quiet move")
  eq(d.half, 100, "the clock reads 100")
  ok(d:isOver(), "the game is over")
  eq(d.result.kind, "fifty", "drawn by the fifty-move rule")

  -- Taking it back un-draws it.
  ok(d:takeback(), "undo")
  ok(not d:isOver(), "and the game is live again")
end)

test("threefold repetition", function()
  local g = Chess.new()
  eq(g:repetitionCount(), 1, "the starting position counts once")
  ok(playText(g, "g1f3", "g8f6", "f3g1", "f6g8"), "knights out and back")
  eq(g:repetitionCount(), 2, "second occurrence")
  ok(not g:isOver(), "twice is not a draw")
  ok(playText(g, "g1f3", "g8f6", "f3g1", "f6g8"), "and round again")
  eq(g:repetitionCount(), 3, "third occurrence")
  ok(g:isOver(), "game over")
  eq(g.result.kind, "repetition", "drawn by repetition")

  ok(g:takeback(), "undo the move that made it")
  eq(g:repetitionCount(), 2, "the tally comes back down")
  ok(not g:isOver(), "and it is a game again")

  -- Castling rights are part of a position's identity: the same men on the
  -- same squares are a different position if one side has since lost the
  -- right to castle.
  local r = pos("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
  local before = r:positionKey()
  ok(playText(r, "e1e2", "e8e7", "e2e1", "e7e8"), "kings out and back")
  ok(r:positionKey() ~= before, "the same men, but no longer the same position")
  eq(r:repetitionCount(), 1, "so it is not a repetition")
end)

test("en passant only counts toward repetition when someone can take it", function()
  -- Two positions with the same men and the same rights differ only if the
  -- en passant capture is actually available to the side to move.
  local a = pos("4k3/8/8/3pP3/8/8/8/4K3 w - d6 0 1")
  local b = pos("4k3/8/8/3pP3/8/8/8/4K3 w - - 0 1")
  ok(a:epUsable(), "the capture is there to be made")
  ok(a:positionKey() ~= b:positionKey(), "so the two positions differ")

  local c = pos("4k3/8/8/3p4/8/8/8/4K3 w - d6 0 1")
  local d = pos("4k3/8/8/3p4/8/8/8/4K3 w - - 0 1")
  ok(not c:epUsable(), "no pawn is placed to take")
  eq(c:positionKey(), d:positionKey(), "so an idle en passant square is ignored")
end)

test("insufficient material", function()
  local draws = {
    { "4k3/8/8/8/8/8/8/4K3 w - - 0 1", "king against king" },
    { "4k3/8/8/8/8/8/8/3BK3 w - - 0 1", "king and bishop against king" },
    { "4k3/8/8/8/8/8/8/3NK3 w - - 0 1", "king and knight against king" },
    { "3bk3/8/8/8/8/8/8/4K3 w - - 0 1", "black's bishop, same thing" },
    -- c1 and f8 are both dark, so neither bishop can ever mate.
    { "5b2/4k3/8/8/8/8/8/2B1K3 w - - 0 1", "bishops on the same colour" },
  }
  for _, d in ipairs(draws) do
    local g = pos(d[1])
    ok(g:insufficientMaterial(), d[2] .. " is a draw")
    eq(g.result and g.result.kind, "material", d[2] .. " is reported as one")
  end

  local live = {
    { "4k3/8/8/8/8/8/4P3/4K3 w - - 0 1", "a pawn can still promote" },
    { "4k3/8/8/8/8/8/8/3RK3 w - - 0 1", "a rook can mate" },
    { "4k3/8/8/8/8/8/8/3QK3 w - - 0 1", "a queen can mate" },
    { "4k3/8/8/8/8/8/8/2BBK3 w - - 0 1", "two bishops can mate" },
    -- d1 is light and f8 is dark, so between them they cover every square.
    { "4kb2/8/8/8/8/8/8/3BK3 w - - 0 1", "bishops on opposite colours" },
  }
  for _, l in ipairs(live) do
    local g = pos(l[1])
    ok(not g:insufficientMaterial(), l[2] .. " is not a draw")
    eq(g.result, nil, l[2] .. " leaves the game running")
  end

  -- Two knights against a bare king cannot be *forced*, but it can be reached
  -- with cooperation, so under FIDE it is not a dead position and play goes on.
  ok(not pos("4k3/8/8/8/8/8/8/2NNK3 w - - 0 1"):insufficientMaterial(),
    "two knights against a king is not insufficient material")
end)

-- ============================== the position's internal bookkeeping ========
--
-- The board is mirrored in three structures that have to agree -- the mailbox,
-- the per-side piece lists with their index, and the running score. Perft
-- would catch a piece-list bug (it walks the lists to generate) but not a
-- score bug, and neither would say which of the three was wrong. These do.

-- Rebuilds everything derived from a full board scan and compares.
local function checkDerived(g, label)
  local counts, score, npm = {}, 0, 0
  for pc = 1, 12 do counts[pc] = 0 end
  local occupied = { {}, {} }
  local kings = {}

  for _, s in ipairs(Chess.SQUARES) do
    local pc = g.board[s]
    if pc ~= Chess.EMPTY then
      local c = Chess.COLOR[pc]
      occupied[c][s] = true
      counts[pc] = counts[pc] + 1
      score = score + Chess.PSQ[pc][s]
      npm = npm + Chess.NPM[pc]
      if Chess.TYPE[pc] == KING then kings[c] = s end
    end
  end

  for c = 1, 2 do
    local n = 0
    for _ in pairs(occupied[c]) do n = n + 1 end
    if g.pcount[c] ~= n then
      return fail(label .. ": pcount[" .. c .. "] is " .. g.pcount[c] .. ", board says " .. n)
    end
    local seen = {}
    for i = 1, n do
      local s = g.plist[c][i]
      if not occupied[c][s] then
        return fail(label .. ": plist has " .. name(s) .. " but the board does not")
      end
      if seen[s] then return fail(label .. ": " .. name(s) .. " is in plist twice") end
      if g.pindex[s] ~= i then
        return fail(label .. ": pindex[" .. name(s) .. "] is " .. tostring(g.pindex[s])
          .. ", plist says " .. i)
      end
      seen[s] = true
    end
    if g.king[c] ~= kings[c] then
      return fail(label .. ": king[" .. c .. "] is wrong")
    end
  end

  for pc = 1, 12 do
    if g.counts[pc] ~= counts[pc] then
      return fail(label .. ": counts[" .. pc .. "] is " .. g.counts[pc]
        .. ", board says " .. counts[pc])
    end
  end
  if g.score ~= score then
    return fail(label .. ": running score is " .. g.score .. ", a full rescan says " .. score)
  end
  if g.npm ~= npm then
    return fail(label .. ": npm is " .. g.npm .. ", a full rescan says " .. npm)
  end

  -- And the padding must still be padding. A stray write outside the board is
  -- exactly the bug the mailbox exists to make impossible.
  for i = 0, 119 do
    if g.board[i] == nil then return fail(label .. ": hole in the board array at " .. i) end
  end
  passed = passed + 1
end

test("make and unmake are exact inverses", function()
  local rand = seededRand(90210)
  local moves = {}
  for round = 1, 40 do
    local g = Chess.new()
    for _ = 1, 60 do
      if g:isOver() then break end
      local n = g:legalMoves(moves)
      if n == 0 then break end

      -- Every legal move from here, made and unmade, must leave the position
      -- byte for byte as it was -- not just the pieces, the clocks and rights
      -- and the derived tallies too.
      local before = g:toFEN()
      local score, npm = g.score, g.npm
      for i = 1, n do
        g:make(moves[i])
        g:unmake()
        if g:toFEN() ~= before then
          return fail("round " .. round .. ": " .. moveName(moves[i])
            .. " left " .. g:toFEN() .. ", want " .. before)
        end
        if g.score ~= score or g.npm ~= npm then
          return fail("round " .. round .. ": " .. moveName(moves[i]) .. " leaked score")
        end
      end
      g:play(moves[rand(n)])
    end
  end
  passed = passed + 1
end)

test("the piece lists and the running score track the board", function()
  local rand = seededRand(31337)
  local moves = {}
  for round = 1, 25 do
    local g = Chess.new()
    checkDerived(g, "round " .. round .. " start")
    for ply = 1, 80 do
      if g:isOver() then break end
      local n = g:legalMoves(moves)
      if n == 0 then break end
      g:play(moves[rand(n)])
      checkDerived(g, "round " .. round .. " ply " .. ply)
    end
    -- And unwinding the whole game must land back on the start position.
    while g:takeback() do end
    eq(g:toFEN(), Chess.START_FEN, "round " .. round .. " unwound to the start")
    checkDerived(g, "round " .. round .. " unwound")
  end
end)

test("a fuzzed game never reaches an illegal state", function()
  local rand = seededRand(5150)
  local moves = {}
  for round = 1, 40 do
    local g = Chess.new()
    for _ = 1, 200 do
      if g:isOver() then break end
      local n = g:legalMoves(moves)
      if n == 0 then return fail("no legal moves but the game is not over") end
      g:play(moves[rand(n)])

      -- Both kings are always on the board, and the side that just moved is
      -- never the one in check.
      if g.counts[Chess.code(WHITE, KING)] ~= 1
          or g.counts[Chess.code(BLACK, KING)] ~= 1 then
        return fail("a king went missing")
      end
      if g:attacked(g.king[3 - g.side], g.side) then
        return fail("the side that just moved left its king in check: " .. g:toFEN())
      end
      if g.counts[Chess.code(WHITE, PAWN)] > 8 or g.counts[Chess.code(BLACK, PAWN)] > 8 then
        return fail("more pawns than a side can have")
      end
    end
    -- Whatever it ended as, the reported result has to be the true one.
    if g:isOver() and g.result.kind == "checkmate" then
      ok(g:inCheck(), "a checkmate is a check")
      eq(select(2, moveSet(g)), 0, "and has no escape")
    end
  end
  passed = passed + 1
end)

-- ========================================================== the bot ========

-- Static evaluation, written out here rather than reused from the game, so
-- the reference search below is not checking the bot against itself.
local function evalOf(p)
  local s = p.score
  if p.npm <= Chess.ENDGAME_NPM then
    s = s + Chess.KDELTA[6][p.king[WHITE]] + Chess.KDELTA[12][p.king[BLACK]]
  end
  if p.side == WHITE then return s end
  return -s
end

-- Plain recursive negamax: no pruning, no ordering, no incremental anything.
-- Obviously correct and far too slow to ship, which is exactly what makes it
-- worth comparing against -- a pruning bug produces a subtly bad bot, not an
-- obviously broken one, and nothing else in this file would notice.
--
-- It mirrors game.lua's two horizon rules and no others: a node with no depth
-- left stands pat and looks only at captures, unless it is in check, when it
-- has to look at every evasion.
local function reference(p, depth, qply, qmax, ply)
  local inCheck = p:inCheck(p.side)
  local qs = depth <= 0
  if ply > 0 and p.half >= 100 then return 0 end
  if qs and qply >= qmax then return evalOf(p) end

  local moves = {}
  local best, n = -math.huge, 0
  if qs and not inCheck then
    best = evalOf(p)
    n = p:generate(moves, true)
  else
    n = p:generate(moves, false)
  end

  local legal = 0
  for i = 1, n do
    local us = p.side
    p:make(moves[i])
    if not p:attacked(p.king[us], p.side) then
      legal = legal + 1
      local v = -reference(p, depth - 1, qs and (qply + 1) or 0, qmax, ply + 1)
      if v > best then best = v end
    end
    p:unmake()
  end

  if legal == 0 and (not qs or inCheck) then
    return inCheck and (-MATE + ply) or 0
  end
  return best
end

-- A brute-force mate prover, used to establish that the positions below
-- really are the mates they are labelled as, rather than taking it on trust.
-- Everything it needs -- legal moves, check, mate -- is what perft verified.
--
-- Returns a negamax score from the side to move's point of view, scoring only
-- mate and stalemate and treating every other leaf as level. So MATE - n means
-- "the side to move mates in n plies" and -(MATE - n) means it is mated in n.
local function mateScore(g, maxPlies)
  local function search(depth, ply)
    local moves = {}
    local n = g:legalMoves(moves)
    if n == 0 then return g:inCheck() and -(MATE - ply) or 0 end
    if depth == 0 then return 0 end
    local best = -math.huge
    for i = 1, n do
      g:make(moves[i])
      local v = -search(depth - 1, ply + 1)
      g:unmake()
      if v > best then best = v end
    end
    return best
  end
  return search(maxPlies, 0)
end

-- Plays one move the way main.lua does: TICK_NODES a tick, capped in ticks,
-- settling for whatever depth finished. The fuzzes below use this rather than
-- solve() so that what they are testing is the bot the handheld actually
-- gets -- which is also several times cheaper to run.
local function levelMove(g, level, rand)
  local L = Chess.LEVELS[level]
  local ai = Chess.AI.fromLevel(g, level, { rand = rand })
  local ticks, mv = 0, nil
  while not mv and not ai.done do
    ticks = ticks + 1
    mv = ai:think(Chess.TICK_NODES)
    if not mv and ticks >= L.thinkTicks then mv = ai:stop() end
  end
  return mv
end

-- A spread of real midgame positions, reached by random legal play. Shared by
-- the search tests below so they all look at the same board states.
local function samplePositions(count, seed)
  local rand = seededRand(seed or 4242)
  local out, moves = {}, {}
  local k = 0
  while #out < count and k < count * 6 do
    k = k + 1
    local g = Chess.new({ rand = rand })
    for _ = 1, 4 + (k * 5) % 34 do
      if g:isOver() then break end
      local n = g:legalMoves(moves)
      if n == 0 then break end
      g:play(moves[rand(n)])
    end
    if not g:isOver() then out[#out + 1] = g end
  end
  return out
end

test("alpha-beta returns exactly what plain negamax returns", function()
  -- The one test that would catch a pruning bug. Alpha-beta is only allowed
  -- to skip work it can prove cannot change the answer, so at the same depth
  -- the two must agree on the value to the point, over and over.
  for _, qmax in ipairs({ 0, 2 }) do
    -- Depth 3 with quiescence on is minutes of unpruned negamax, so the fast
    -- pass stops at 2 there and CHESS_SLOW=1 takes it further.
    local maxDepth = (qmax == 0 or SLOW) and 3 or 2
    for _, g in ipairs(samplePositions(6, 777 + qmax)) do
      for depth = 1, maxDepth do
        local ai = Chess.AI.new(g, { maxDepth = depth, nodeBudget = 10 ^ 9, qmax = qmax })
        ai:solve()
        local p = Chess.new()
        g:copyInto(p)
        local want = reference(p, ai.completedDepth, 0, qmax, 0)
        eq(ai.bestValue, want,
          string.format("qmax %d depth %d on %s", qmax, ai.completedDepth, g:toFEN()))
      end
    end
  end
end)

test("the sliced search returns exactly what the one-shot search returns", function()
  -- Slicing is allowed to change *when* the bot answers, never *what* it
  -- answers. This is what lets main.lua feed the search a tick at a time
  -- without the handheld playing a different game from the tests.
  for _, g in ipairs(samplePositions(8, 2024)) do
    local one = Chess.AI.new(g, { maxDepth = 3, nodeBudget = 10 ^ 9 })
    local want = one:solve()

    for _, slice in ipairs({ 1, 3, 17, 200 }) do
      local sliced = Chess.AI.new(g, { maxDepth = 3, nodeBudget = 10 ^ 9 })
      local got, spins = nil, 0
      repeat
        got = sliced:think(slice)
        spins = spins + 1
      until sliced.done or spins > 200000
      eq(moveName(got), moveName(want),
        string.format("slice %d on %s", slice, g:toFEN()))
      eq(sliced.nodes, one.nodes, "and visited the same nodes doing it")
    end
  end
end)

test("the bot never returns an illegal move, at any depth or budget", function()
  -- Including budgets far too small to finish a single iteration, which is
  -- the case the handheld actually hits: whatever comes back then is the
  -- fallback, and the fallback has to be a real move too.
  local rand = seededRand(8675309)
  local legalMoves = {}
  for _, g in ipairs(samplePositions(14, 1234)) do
    local n = g:legalMoves(legalMoves)
    local set = {}
    for i = 1, n do set[legalMoves[i]] = true end

    for _, depth in ipairs({ 1, 2, 3 }) do
      for _, budget in ipairs({ 1, 2, 7, 60, 500, 10 ^ 9 }) do
        local ai = Chess.AI.new(g, { maxDepth = depth, nodeBudget = budget, rand = rand })
        local m = ai:solve()
        ok(m and set[m], string.format("depth %d budget %d gave %s", depth, budget, moveName(m)))
      end
      -- And the same for a search cut off part-way by stop(), which is how
      -- main.lua ends a turn that has run out of ticks.
      for _, ticks in ipairs({ 0, 1, 4 }) do
        local ai = Chess.AI.fromLevel(g, 3, { rand = rand })
        for _ = 1, ticks do ai:think(Chess.TICK_NODES) end
        local m = ai:stop()
        ok(m and set[m], "stop() after " .. ticks .. " ticks gave " .. moveName(m))
      end
    end
    -- Every temperature, too: the softmax may only ever pick from the moves
    -- the root actually scored.
    for _, temp in ipairs({ 0, 55, 180, 900 }) do
      for _ = 1, 6 do
        local ai = Chess.AI.new(g, { maxDepth = 2, nodeBudget = 10 ^ 9,
                                     temperature = temp, rand = rand })
        local m = ai:solve()
        ok(m and set[m], "temperature " .. temp .. " gave " .. moveName(m))
      end
    end
  end
end)

test("the bot finds mate in one", function()
  local mates = {
    { "6k1/5ppp/8/8/8/8/8/1R4K1 w - - 0 1" },
    { "3k4/8/3K4/8/8/8/8/6R1 w - - 0 1" },
    { "k7/8/1K6/8/8/8/8/7R w - - 0 1" },
    { "8/8/8/8/8/1k6/7q/K7 b - - 0 1" },
    -- Scholar's mate, from the position one move before it.
    { "r1bqkbnr/pppp1ppp/2n5/4p3/2B1P3/5Q2/PPPP1PPP/RNB1K1NR w KQkq - 0 1" },
  }
  for _, m in ipairs(mates) do
    local g = pos(m[1])
    ok(not g:attacked(g.king[3 - g.side], g.side), "the position is legal: " .. m[1])
    eq(mateScore(g, 1), MATE - 1, "and really is mate in one: " .. m[1])
    for _, depth in ipairs({ 1, 2, 3 }) do
      local ai = Chess.AI.new(g, { maxDepth = depth, nodeBudget = 10 ^ 9 })
      local mv = ai:solve()
      -- What is asked is that the move mates, not that it is a particular
      -- move: several of these positions have two mates in one, and a bot
      -- that finds the other one has not done anything wrong.
      local h = pos(m[1])
      ok(h:play(mv), "played " .. moveName(mv))
      eq(mateScore(h, 0), -MATE,
        string.format("depth %d played %s, which is mate, in %s", depth, moveName(mv), m[1]))
      ok(ai.bestValue >= MATE - 100, "and knew it was mate")
    end
  end
end)

test("the bot finds mate in two, given the depth for it", function()
  -- Both of these are proved to be mates in two by the brute-force prover
  -- above before the bot is asked, so a failure here is the bot's and not the
  -- position's.
  local mates = {
    { "7k/8/8/8/8/8/R7/1R5K w - - 0 1", "a two-rook ladder" },
    { "2k5/8/1K6/8/8/8/8/7R w - - 0 1", "king and rook against a bare king" },
  }
  for _, m in ipairs(mates) do
    local g = pos(m[1])
    eq(mateScore(g, 3), MATE - 3, m[2] .. " really is mate in two")

    -- Three ply is the depth that can see it, and at that depth the bot must
    -- both find a mating move and know the score.
    local ai = Chess.AI.new(g, { maxDepth = 3, nodeBudget = 10 ^ 9 })
    local mv = ai:solve()
    ok(ai.bestValue >= MATE - 100, m[2] .. ": the bot reports a mate score")

    -- And the move it chose keeps the mate: after it, the other side is the
    -- one being mated, in the two plies that are left.
    local h = pos(m[1])
    ok(h:play(mv), m[2] .. ": played " .. moveName(mv))
    eq(mateScore(h, 2), -(MATE - 2), m[2] .. ": the reply is mated in two plies")
  end
end)

test("quiescence is what stops the bot hanging its queen for a pawn", function()
  -- The queen on b1 can take the pawn on b6, which the pawn on c7 defends.
  -- A one-ply search stops the moment the pawn is taken, counts it, and calls
  -- that winning material. Extending the captures shows the recapture.
  local fen = "4k3/2p5/1p6/8/8/8/8/1Q2K3 w - - 0 1"
  ok(findMove(pos(fen), "b1b6") ~= nil, "the grab is on the move list")

  local blind = Chess.AI.new(pos(fen), { maxDepth = 1, nodeBudget = 10 ^ 9, qmax = 0 })
  eq(moveName(blind:solve()), "b1b6",
    "without quiescence the bot takes the defended pawn")

  local seeing = Chess.AI.new(pos(fen), { maxDepth = 1, nodeBudget = 10 ^ 9, qmax = 4 })
  local mv = seeing:solve()
  ok(moveName(mv) ~= "b1b6", "with quiescence it does not: it plays " .. moveName(mv))
  ok(seeing.nodes > blind.nodes, "and it looked at more to find that out")

  -- And what the grab was really worth, settled by playing it out. White went
  -- into it a queen for two pawns ahead and comes out of it a bare king
  -- against a king and a pawn: reply.bestValue is Black's, so a positive
  -- number there is White having thrown the game away.
  local after = pos(fen)
  ok(after:play(findMove(after, "b1b6")), "played the grab")
  local reply = Chess.AI.new(after, { maxDepth = 1, nodeBudget = 10 ^ 9, qmax = 4 })
  reply:solve()
  ok(reply.bestValue > 0,
    "black stands better once the recapture is on the board ("
      .. reply.bestValue .. ")")
  -- The two are the same position seen from opposite sides, so their sum is
  -- exactly how far wrong the blind search was: about a queen.
  ok(blind.bestValue + reply.bestValue > 800,
    string.format("the blind search was %d centipawns too optimistic",
      blind.bestValue + reply.bestValue))
end)

test("temperature makes the bot vary, and zero makes it not", function()
  local g = samplePositions(1, 99)[1]

  -- Temperature 0 is the argmax: the same position gives the same move, every
  -- time, whatever the random source is doing.
  local first
  for i = 1, 8 do
    local ai = Chess.AI.new(g, { maxDepth = 2, nodeBudget = 10 ^ 9,
                                 temperature = 0, rand = seededRand(i * 7919) })
    local m = ai:solve()
    first = first or m
    eq(moveName(m), moveName(first), "temperature 0 is deterministic")
  end

  -- And a high temperature does not: over enough draws it must produce more
  -- than one move, or it is not sampling at all.
  local seen = {}
  for i = 1, 40 do
    local ai = Chess.AI.new(g, { maxDepth = 2, nodeBudget = 10 ^ 9,
                                 temperature = 400, rand = seededRand(i * 104729) })
    seen[moveName(ai:solve())] = true
  end
  local distinct = 0
  for _ in pairs(seen) do distinct = distinct + 1 end
  ok(distinct > 1, "a high temperature picks more than one move (" .. distinct .. ")")

  -- The same seed twice is the same move, though -- a bot whose blunders
  -- cannot be reproduced cannot be debugged.
  local a = Chess.AI.new(g, { maxDepth = 2, nodeBudget = 10 ^ 9,
                              temperature = 400, rand = seededRand(555) })
  local b = Chess.AI.new(g, { maxDepth = 2, nodeBudget = 10 ^ 9,
                              temperature = 400, rand = seededRand(555) })
  eq(moveName(a:solve()), moveName(b:solve()), "same seed, same choice")
end)

test("a search in progress never shows up on the game's board", function()
  -- The bot searches a scratch copy. If it shared the board, on.paint would
  -- draw its half-explored guesses between ticks and the player would watch
  -- pieces appear and vanish.
  local g = samplePositions(1, 4321)[1]
  local before = g:toFEN()
  local ai = Chess.AI.fromLevel(g, 3)
  for _ = 1, 40 do
    ai:think(37)
    eq(g:toFEN(), before, "the game's board is untouched mid-search")
    if ai.done then break end
  end
  ai:cancel()
  eq(g:toFEN(), before, "and after a cancel")
  -- The scratch board is left legal too, not stranded mid-move.
  eq(ai.pos:toFEN(), before, "the scratch copy unwound to the root position")
end)

test("fuzz: the bot essentially never loses to a random player", function()
  -- The honest bar for a two-to-three ply bot. It is not asked to play well,
  -- only to punish someone who is not playing at all.
  local rand = seededRand(1618)
  local losses, wins, draws = 0, 0, 0
  local moves = {}

  for gameNo = 1, 12 do
    local botSide = (gameNo % 2 == 1) and WHITE or BLACK
    local g = Chess.new({ rand = rand })
    for _ = 1, 160 do
      if g:isOver() then break end
      local m
      if g.side == botSide then
        m = levelMove(g, 3, rand)
      else
        local n = g:legalMoves(moves)
        m = moves[rand(n)]
      end
      if not m or not g:play(m) then
        return fail("game " .. gameNo .. ": could not play " .. moveName(m))
      end
    end

    local r = g.result
    if r and r.kind == "checkmate" then
      if r.winner == botSide then wins = wins + 1 else losses = losses + 1 end
    else
      draws = draws + 1
    end
  end

  ok(losses == 0, string.format("lost %d of 12 (won %d, drew or ran on %d)",
    losses, wins, draws))
  ok(wins >= 8, string.format("won %d of 12", wins))
end)

test("fuzz: a harder level beats an easier one", function()
  -- Difficulty comes from move selection here, not depth, so this is the test
  -- that the temperature actually costs the easy bot something.
  local rand = seededRand(271828)
  local hardWins, easyWins, drawn = 0, 0, 0

  for gameNo = 1, 10 do
    local hardSide = (gameNo % 2 == 1) and WHITE or BLACK
    local g = Chess.new({ rand = rand })
    for _ = 1, 140 do
      if g:isOver() then break end
      local m = levelMove(g, (g.side == hardSide) and 3 or 1, rand)
      if not m or not g:play(m) then return fail("could not play") end
    end
    local r = g.result
    if r and r.kind == "checkmate" then
      if r.winner == hardSide then hardWins = hardWins + 1 else easyWins = easyWins + 1 end
    else
      drawn = drawn + 1
    end
  end

  ok(hardWins > easyWins,
    string.format("Hard won %d, Easy won %d, %d otherwise", hardWins, easyWins, drawn))
end)

-- ===================================================== the measurements ====

test("measured: what a ply costs, and what each level gets", function()
  -- The numbers the budgets in game.lua were chosen from. Printed rather than
  -- asserted: node counts are a property of the position, and a machine's
  -- speed is not something to fail a build over.
  local positions = samplePositions(14, 4242)
  print("")
  print("  depth   mean nodes    max nodes     us/node   (cumulative, with quiescence)")
  for depth = 1, 4 do
    local total, maxn, t0 = 0, 0, os.clock()
    for _, g in ipairs(positions) do
      local ai = Chess.AI.new(g, { maxDepth = depth, nodeBudget = 10 ^ 9 })
      ai:solve()
      total = total + ai.nodes
      if ai.nodes > maxn then maxn = ai.nodes end
    end
    local dt = os.clock() - t0
    print(string.format("  %5d   %10d   %10d   %9.2f", depth,
      math.floor(total / #positions), maxn, dt * 1e6 / math.max(1, total)))
  end

  print("")
  print("  level    ticks   mean nodes   mean depth   (driven exactly as main.lua drives it)")
  local levelPositions = samplePositions(20, 4242)
  for i, L in ipairs(Chess.LEVELS) do
    local total, depth = 0, 0
    for _, g in ipairs(levelPositions) do
      local ai = Chess.AI.fromLevel(g, i)
      local ticks, mv = 0, nil
      while not mv and not ai.done do
        ticks = ticks + 1
        mv = ai:think(Chess.TICK_NODES)
        if not mv and ticks >= L.thinkTicks then mv = ai:stop() end
      end
      total = total + ai.nodes
      depth = depth + (ai.completedDepth or 0)
    end
    print(string.format("  %-7s %6d   %10d   %10.1f", L.name, L.thinkTicks,
      math.floor(total / #levelPositions), depth / #levelPositions))
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
