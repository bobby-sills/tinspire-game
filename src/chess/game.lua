-- game.lua -- pure chess rules, plus the bot that plays them.
--
-- Like the other games here, this module knows nothing about the TI-Nspire:
-- no `platform`, no `gc`, no `timer`. All drawing and input lives in main.lua.
-- The bot lives here too, deliberately: keeping the search as pure logic is
-- what lets the tests drive it to completion synchronously while the handheld
-- runs the very same code in slices.
--
-- REPRESENTATION -- why it looks like this and not like a textbook engine:
--
-- * No bitboards. Lua 5.1 on the handheld has no bitwise operators and no
--   `bit` library, and 64 bits does not fit exactly in a double anyway.
-- * No 0x88 board either: the whole trick there is `sq & 0x88`, and without
--   an AND it is worse than useless. Instead this is a 10x12 padded mailbox
--   indexed 0..119, so "is that square off the board?" is a single array
--   lookup against a sentinel. The two border rows at each end are what keep
--   a knight's -21..+21 reach inside the array from every real square.
-- * Zobrist hashing needs XOR, so repetition detection builds a string key
--   instead and counts occurrences in a table. Slower, but it happens once
--   per played move, never inside the search.
-- * Make/unmake with an undo record, never a board copy per node: a copy
--   allocates a table per node, and that GC pressure would cost more than
--   the search itself both in perft and on the device.

local Chess = {}
Chess.__index = Chess

local floor, exp = math.floor, math.exp

-- ------------------------------------------------------------- vocabulary --

local OFF, EMPTY = -1, 0
local WHITE, BLACK = 1, 2
local PAWN, KNIGHT, BISHOP, ROOK, QUEEN, KING = 1, 2, 3, 4, 5, 6

Chess.WHITE, Chess.BLACK = WHITE, BLACK
Chess.PAWN, Chess.KNIGHT, Chess.BISHOP = PAWN, KNIGHT, BISHOP
Chess.ROOK, Chess.QUEEN, Chess.KING = ROOK, QUEEN, KING
Chess.EMPTY, Chess.OFF = EMPTY, OFF

-- Piece codes 1..6 are White's pawn..king, 7..12 are Black's. Two lookup
-- tables turn a code back into (colour, type) without arithmetic at the call
-- site, which matters because they are read in the innermost loops.
local COLOR, TYPE = {}, {}
for t = 1, 6 do
  COLOR[t], TYPE[t] = WHITE, t
  COLOR[t + 6], TYPE[t + 6] = BLACK, t
end
COLOR[EMPTY], TYPE[EMPTY] = 0, 0
COLOR[OFF], TYPE[OFF] = 0, 0
Chess.COLOR, Chess.TYPE = COLOR, TYPE

-- code = type for White, type + 6 for Black.
local function code(colour, t) return (colour == WHITE) and t or (t + 6) end
Chess.code = code

local LETTER = { "P", "N", "B", "R", "Q", "K" }
Chess.LETTER = LETTER

local FEN_CHAR = {
  P = 1, N = 2, B = 3, R = 4, Q = 5, K = 6,
  p = 7, n = 8, b = 9, r = 10, q = 11, k = 12,
}
local CHAR_OF = {}
for ch, pc in pairs(FEN_CHAR) do CHAR_OF[pc] = ch end
CHAR_OF[EMPTY] = "."

-- --------------------------------------------------------------- geometry --
--
-- 10 wide, 12 tall, indexed 0..119. Rank 8 is row 21..28 and rank 1 is
-- 91..98, so index order is screen order for a board drawn with White at the
-- bottom -- one less transform in the drawing code.

local function sqOf(file, rank) return 21 + (8 - rank) * 10 + (file - 1) end
local function fileOf(sq) return sq % 10 end
local function rankOf(sq) return 10 - floor(sq / 10) end

Chess.sqOf, Chess.fileOf, Chess.rankOf = sqOf, fileOf, rankOf

-- Every playable square, rank 8 first, so callers that want to walk the board
-- in a fixed order do not have to know about the padding.
local SQUARES = {}
for r = 8, 1, -1 do
  for f = 1, 8 do SQUARES[#SQUARES + 1] = sqOf(f, r) end
end
Chess.SQUARES = SQUARES

local ONBOARD = {}
for i = 0, 119 do ONBOARD[i] = false end
for _, sq in ipairs(SQUARES) do ONBOARD[sq] = true end

-- a1 is dark, h1 is light: (file + rank) odd means light.
local function isLight(sq) return (fileOf(sq) + rankOf(sq)) % 2 == 1 end
Chess.isLight = isLight

local function squareName(sq)
  return string.char(96 + fileOf(sq)) .. tostring(rankOf(sq))
end
Chess.squareName = squareName

local function squareFromName(s)
  if type(s) ~= "string" or #s < 2 then return nil end
  local f = string.byte(s, 1) - 96
  local r = tonumber(s:sub(2, 2))
  if not r or f < 1 or f > 8 or r < 1 or r > 8 then return nil end
  return sqOf(f, r)
end
Chess.squareFromName = squareFromName

-- Ray and hop offsets. Sliding pieces walk their direction until the mailbox
-- sentinel stops them, which is the whole reason for the padding.
local KNIGHT_D = { -21, -19, -12, -8, 8, 12, 19, 21 }
local BISHOP_D = { -11, -9, 9, 11 }
local ROOK_D   = { -10, -1, 1, 10 }
local KING_D   = { -11, -10, -9, -1, 1, 9, 10, 11 }

-- Sliding directions per piece type, so one loop covers bishop, rook, queen.
local SLIDE = { [BISHOP] = BISHOP_D, [ROOK] = ROOK_D, [QUEEN] = KING_D }

-- White advances toward lower indices, because rank 8 is at the top.
local PUSH = { [WHITE] = -10, [BLACK] = 10 }
local CAPD = { [WHITE] = { -11, -9 }, [BLACK] = { 11, 9 } }
local HOME_ROW = { [WHITE] = 8, [BLACK] = 3 } -- floor(sq/10) of the pawns' start rank
local PROMO_ROW = { [WHITE] = 2, [BLACK] = 9 }

-- --------------------------------------------------------- move encoding ---
--
-- A move is one integer, not a table: perft and the search generate millions
-- of them, and a table per move would spend more time in the collector than
-- in the search. Packed as from + to*128 + promo*16384 + flag*131072, which
-- peaks around 640k and so stays exact in a double with room to spare.

local FLAG_NORMAL, FLAG_DOUBLE, FLAG_EP = 0, 1, 2
local FLAG_KCASTLE, FLAG_QCASTLE = 3, 4
Chess.FLAG_NORMAL, Chess.FLAG_DOUBLE, Chess.FLAG_EP = FLAG_NORMAL, FLAG_DOUBLE, FLAG_EP
Chess.FLAG_KCASTLE, Chess.FLAG_QCASTLE = FLAG_KCASTLE, FLAG_QCASTLE

local function encode(from, to, promo, flag)
  return from + to * 128 + (promo or 0) * 16384 + (flag or 0) * 131072
end

local function decode(m)
  local from = m % 128
  local to = floor(m / 128) % 128
  local promo = floor(m / 16384) % 8
  local flag = floor(m / 131072)
  return from, to, promo, flag
end

Chess.encode, Chess.decode = encode, decode

function Chess.moveFrom(m) return m % 128 end
function Chess.moveTo(m) return floor(m / 128) % 128 end
function Chess.movePromo(m) return floor(m / 16384) % 8 end
function Chess.moveFlag(m) return floor(m / 131072) end

-- ---------------------------------------------------- castling bookkeeping --
--
-- Rights are four booleans: 1 = White kingside, 2 = White queenside,
-- 3 = Black kingside, 4 = Black queenside.
local WK, WQ, BK, BQ = 1, 2, 3, 4
Chess.WK, Chess.WQ, Chess.BK, Chess.BQ = WK, WQ, BK, BQ

-- Moving from or onto one of these squares kills the listed rights. Keyed by
-- square so make() clears them with two lookups and no special cases: the
-- king's own square covers "the king moved", each rook's square covers both
-- "that rook moved" and "that rook was captured where it stood".
local RIGHTS_LOST = {}
RIGHTS_LOST[sqOf(5, 1)] = { WK, WQ }  -- e1
RIGHTS_LOST[sqOf(8, 1)] = { WK }      -- h1
RIGHTS_LOST[sqOf(1, 1)] = { WQ }      -- a1
RIGHTS_LOST[sqOf(5, 8)] = { BK, BQ }  -- e8
RIGHTS_LOST[sqOf(8, 8)] = { BK }      -- h8
RIGHTS_LOST[sqOf(1, 8)] = { BQ }      -- a8

-- Per right: the king's start square, its destination, the rook's start and
-- destination, and the squares that must be empty / must not be attacked.
-- Written out rather than derived so the conditions are readable side by side.
local CASTLING = {
  [WK] = { colour = WHITE, king = 95, kingTo = 97, rook = 98, rookTo = 96,
           empty = { 96, 97 }, safe = { 95, 96, 97 }, flag = FLAG_KCASTLE },
  [WQ] = { colour = WHITE, king = 95, kingTo = 93, rook = 91, rookTo = 94,
           empty = { 92, 93, 94 }, safe = { 95, 94, 93 }, flag = FLAG_QCASTLE },
  [BK] = { colour = BLACK, king = 25, kingTo = 27, rook = 28, rookTo = 26,
           empty = { 26, 27 }, safe = { 25, 26, 27 }, flag = FLAG_KCASTLE },
  [BQ] = { colour = BLACK, king = 25, kingTo = 23, rook = 21, rookTo = 24,
           empty = { 22, 23, 24 }, safe = { 25, 24, 23 }, flag = FLAG_QCASTLE },
}
Chess.CASTLING = CASTLING

-- b1 and b8 may be attacked and queenside castling is still legal -- only the
-- three squares the king touches have to be safe. That asymmetry between
-- `empty` and `safe` above is the single most commonly mis-implemented rule
-- in chess, and tests/chess/run.lua pins it down explicitly.

-- ------------------------------------------------- material and the tables --
--
-- Piece-square tables after Michniewski's "Simplified Evaluation Function"
-- (Chess Programming Wiki), written a8-first so the row order matches this
-- file's square order. Material alone makes a bot that shuffles; these are
-- what make it develop knights, castle, and push passed pawns.

local VALUE = { 100, 320, 330, 500, 900, 0 } -- king's own value cancels out

local PST = {}
PST[PAWN] = {
   0,  0,  0,  0,  0,  0,  0,  0,
  50, 50, 50, 50, 50, 50, 50, 50,
  10, 10, 20, 30, 30, 20, 10, 10,
   5,  5, 10, 25, 25, 10,  5,  5,
   0,  0,  0, 20, 20,  0,  0,  0,
   5, -5,-10,  0,  0,-10, -5,  5,
   5, 10, 10,-20,-20, 10, 10,  5,
   0,  0,  0,  0,  0,  0,  0,  0,
}
PST[KNIGHT] = {
 -50,-40,-30,-30,-30,-30,-40,-50,
 -40,-20,  0,  0,  0,  0,-20,-40,
 -30,  0, 10, 15, 15, 10,  0,-30,
 -30,  5, 15, 20, 20, 15,  5,-30,
 -30,  0, 15, 20, 20, 15,  0,-30,
 -30,  5, 10, 15, 15, 10,  5,-30,
 -40,-20,  0,  5,  5,  0,-20,-40,
 -50,-40,-30,-30,-30,-30,-40,-50,
}
PST[BISHOP] = {
 -20,-10,-10,-10,-10,-10,-10,-20,
 -10,  0,  0,  0,  0,  0,  0,-10,
 -10,  0,  5, 10, 10,  5,  0,-10,
 -10,  5,  5, 10, 10,  5,  5,-10,
 -10,  0, 10, 10, 10, 10,  0,-10,
 -10, 10, 10, 10, 10, 10, 10,-10,
 -10,  5,  0,  0,  0,  0,  5,-10,
 -20,-10,-10,-10,-10,-10,-10,-20,
}
PST[ROOK] = {
   0,  0,  0,  0,  0,  0,  0,  0,
   5, 10, 10, 10, 10, 10, 10,  5,
  -5,  0,  0,  0,  0,  0,  0, -5,
  -5,  0,  0,  0,  0,  0,  0, -5,
  -5,  0,  0,  0,  0,  0,  0, -5,
  -5,  0,  0,  0,  0,  0,  0, -5,
  -5,  0,  0,  0,  0,  0,  0, -5,
   0,  0,  0,  5,  5,  0,  0,  0,
}
PST[QUEEN] = {
 -20,-10,-10, -5, -5,-10,-10,-20,
 -10,  0,  0,  0,  0,  0,  0,-10,
 -10,  0,  5,  5,  5,  5,  0,-10,
  -5,  0,  5,  5,  5,  5,  0, -5,
   0,  0,  5,  5,  5,  5,  0, -5,
 -10,  5,  5,  5,  5,  5,  0,-10,
 -10,  0,  5,  0,  0,  0,  0,-10,
 -20,-10,-10, -5, -5,-10,-10,-20,
}
local KING_MID = {
 -30,-40,-40,-50,-50,-40,-40,-30,
 -30,-40,-40,-50,-50,-40,-40,-30,
 -30,-40,-40,-50,-50,-40,-40,-30,
 -30,-40,-40,-50,-50,-40,-40,-30,
 -20,-30,-30,-40,-40,-30,-30,-20,
 -10,-20,-20,-20,-20,-20,-20,-10,
  20, 20,  0,  0,  0,  0, 20, 20,
  20, 30, 10,  0,  0, 10, 30, 20,
}
local KING_END = {
 -50,-40,-30,-20,-20,-30,-40,-50,
 -30,-20,-10,  0,  0,-10,-20,-30,
 -30,-10, 20, 30, 30, 20,-10,-30,
 -30,-10, 30, 40, 40, 30,-10,-30,
 -30,-10, 30, 40, 40, 30,-10,-30,
 -30,-10, 20, 30, 30, 20,-10,-30,
 -30,-30,  0,  0,  0,  0,-30,-30,
 -50,-30,-30,-30,-30,-30,-30,-50,
}
PST[KING] = KING_MID

-- Table index for a square, as White sees it, and mirrored for Black.
local function pstIndexWhite(sq) return (floor(sq / 10) - 2) * 8 + (sq % 10) end
local function pstIndexBlack(sq) return (9 - floor(sq / 10)) * 8 + (sq % 10) end

-- PSQ[pieceCode][square] is that piece's whole contribution to the running
-- score, from White's point of view and with the sign already folded in. So
-- placing or lifting a piece is one addition, and evaluation is a field read.
local PSQ = {}
for t = 1, 6 do
  local w, b = {}, {}
  for _, sq in ipairs(SQUARES) do
    w[sq] = VALUE[t] + PST[t][pstIndexWhite(sq)]
    b[sq] = -(VALUE[t] + PST[t][pstIndexBlack(sq)])
  end
  PSQ[t], PSQ[t + 6] = w, b
end

-- The kings' tables are the one thing that cannot be incremental, because
-- which table applies depends on how much material is still on. So the
-- running score carries the middlegame king table and this is the correction
-- added at evaluation time once the endgame threshold is crossed -- two
-- lookups, and everything else stays a single running total.
local KDELTA = {}
do
  local w, b = {}, {}
  for _, sq in ipairs(SQUARES) do
    w[sq] = KING_END[pstIndexWhite(sq)] - KING_MID[pstIndexWhite(sq)]
    b[sq] = -(KING_END[pstIndexBlack(sq)] - KING_MID[pstIndexBlack(sq)])
  end
  KDELTA[KING], KDELTA[KING + 6] = w, b
end

-- Non-pawn material on the board, both sides, used only to pick a king table.
-- Two rooks and a bishop a side, or less, counts as an endgame.
local NPM = {}
for t = 1, 6 do
  local v = (t == PAWN or t == KING) and 0 or VALUE[t]
  NPM[t], NPM[t + 6] = v, v
end
local ENDGAME_NPM = 2 * (2 * VALUE[ROOK] + VALUE[BISHOP])

Chess.PSQ, Chess.KDELTA, Chess.VALUE = PSQ, KDELTA, VALUE
Chess.ENDGAME_NPM, Chess.NPM = ENDGAME_NPM, NPM

-- =========================================================== the position ==

-- Piece placement is mirrored in three structures that must agree:
--   board[sq]        the mailbox, for "what is on this square"
--   plist[c][1..n]   the squares each side occupies, for "walk my pieces"
--   pindex[sq]       where a square sits in plist, so removal is O(1)
-- generate() walking 16 pieces instead of scanning 64 squares is worth about
-- three times the perft speed. tests/chess/run.lua rechecks all three against
-- a full board scan after every move of a long fuzz, which is what makes a
-- redundancy like this safe to keep.

local function addPiece(self, sq, pc)
  local c = COLOR[pc]
  local n = self.pcount[c] + 1
  self.board[sq] = pc
  self.pcount[c] = n
  self.plist[c][n] = sq
  self.pindex[sq] = n
  self.counts[pc] = self.counts[pc] + 1
  self.score = self.score + PSQ[pc][sq]
  self.npm = self.npm + NPM[pc]
  if TYPE[pc] == KING then self.king[c] = sq end
end

local function removePiece(self, sq)
  local pc = self.board[sq]
  local c = COLOR[pc]
  local i = self.pindex[sq]
  local n = self.pcount[c]
  local last = self.plist[c][n]
  self.plist[c][i] = last
  self.pindex[last] = i
  self.plist[c][n] = nil
  self.pcount[c] = n - 1
  self.board[sq] = EMPTY
  self.counts[pc] = self.counts[pc] - 1
  self.score = self.score - PSQ[pc][sq]
  self.npm = self.npm - NPM[pc]
end

local function movePiece(self, from, to)
  local pc = self.board[from]
  local c = COLOR[pc]
  local i = self.pindex[from]
  self.plist[c][i] = to
  self.pindex[to] = i
  self.board[to] = pc
  self.board[from] = EMPTY
  self.score = self.score + PSQ[pc][to] - PSQ[pc][from]
end

-- Empties the position without reallocating anything. Everything that follows
-- builds a position by dropping pieces onto this, so there is exactly one
-- place where the mirrored structures are initialised.
function Chess:clear()
  local b = self.board
  for i = 0, 119 do b[i] = OFF end
  for _, sq in ipairs(SQUARES) do b[sq] = EMPTY end

  self.pcount[WHITE], self.pcount[BLACK] = 0, 0
  for i = 1, 16 do self.plist[WHITE][i], self.plist[BLACK][i] = nil, nil end
  for pc = 1, 12 do self.counts[pc] = 0 end

  self.score, self.npm = 0, 0
  self.side = WHITE
  self.castle[WK], self.castle[WQ] = false, false
  self.castle[BK], self.castle[BQ] = false, false
  self.ep = 0
  self.half, self.full = 0, 1
  self.king[WHITE], self.king[BLACK] = 0, 0
  self.ply = 0
  return self
end

local START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
Chess.START_FEN = START_FEN

-- opts.rand: function(n) -> integer in [1, n]. Injectable so the bot's
--            temperature-weighted move choice is reproducible under test.
-- opts.mode: "hotseat" (two people on one calculator) or "bot".
--
-- There is no networked mode and there never can be: Nspire Lua has no socket
-- API, no link-cable access and no wireless. Two players means one calculator.
function Chess.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Chess)
  self.board = {}
  self.plist = { {}, {} }
  self.pindex = {}
  self.pcount = { 0, 0 }
  self.counts = {}
  self.castle = {}
  self.king = {}
  self.hist = {}       -- undo records, reused; indexed by ply
  self.moves = {}      -- game-level move log: { move, text, key }
  self.reps = {}       -- position key -> how many times it has occurred
  self._pseudo = {}    -- scratch for legalMoves; never nested
  self._scratch = {}
  self.rand = opts.rand or function(n) return math.random(n) end
  self.mode = opts.mode or "bot"
  self.botSide = opts.botSide or BLACK
  self:clear()
  self:setup(opts.fen or START_FEN)
  -- Playable straight away, because a rules module that needs to be told the
  -- game has started is a trap for every test that builds a position. main.lua
  -- passes state = "ready" for the title screen.
  self.state = opts.state or "playing"
  return self
end

-- ------------------------------------------------------------------- FEN ---
--
-- Tests set positions up in one line with this, which is most of what makes
-- the rule tests below readable; perft positions arrive as FEN too.

-- Returns the position on success, or nil plus a message. Deliberately
-- forgiving about the last two fields, which many published FENs omit.
function Chess:setup(fen)
  local placement, side, rights, ep, half, full = fen:match(
    "^%s*(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(%S*)%s*(%S*)%s*$")
  if not placement then return nil, "malformed FEN" end

  self:clear()
  local sq = sqOf(1, 8)
  local file = 1
  for i = 1, #placement do
    local ch = placement:sub(i, i)
    if ch == "/" then
      if file ~= 9 then return nil, "short rank in FEN" end
      sq = sq + 10 - 8
      file = 1
    elseif ch:match("%d") then
      local skip = tonumber(ch)
      file, sq = file + skip, sq + skip
      if file > 9 then return nil, "over-long rank in FEN" end
    else
      local pc = FEN_CHAR[ch]
      if not pc then return nil, "bad piece '" .. ch .. "' in FEN" end
      if file > 8 then return nil, "over-long rank in FEN" end
      addPiece(self, sq, pc)
      file, sq = file + 1, sq + 1
    end
  end
  if file ~= 9 then return nil, "short rank in FEN" end

  self.side = (side == "b") and BLACK or WHITE
  self.castle[WK] = rights:find("K", 1, true) ~= nil
  self.castle[WQ] = rights:find("Q", 1, true) ~= nil
  self.castle[BK] = rights:find("k", 1, true) ~= nil
  self.castle[BQ] = rights:find("q", 1, true) ~= nil
  self.ep = (ep ~= "-" and squareFromName(ep)) or 0
  self.half = tonumber(half) or 0
  self.full = tonumber(full) or 1

  if self.king[WHITE] == 0 or self.king[BLACK] == 0 then
    return nil, "FEN has a side with no king"
  end

  self.moves = {}
  self.reps = {}
  self.ply = 0
  self.state = "playing"
  self.result = nil
  self:noteRepetition()
  self:updateResult()
  return self
end

function Chess.fromFEN(fen, opts)
  local g = Chess.new(opts)
  local okSetup, err = g:setup(fen)
  if not okSetup then return nil, err end
  return g
end

function Chess:toFEN()
  local rows = {}
  for r = 8, 1, -1 do
    local row, run = {}, 0
    for f = 1, 8 do
      local pc = self.board[sqOf(f, r)]
      if pc == EMPTY then
        run = run + 1
      else
        if run > 0 then row[#row + 1] = tostring(run); run = 0 end
        row[#row + 1] = CHAR_OF[pc]
      end
    end
    if run > 0 then row[#row + 1] = tostring(run) end
    rows[#rows + 1] = table.concat(row)
  end
  local rights = (self.castle[WK] and "K" or "") .. (self.castle[WQ] and "Q" or "")
    .. (self.castle[BK] and "k" or "") .. (self.castle[BQ] and "q" or "")
  if rights == "" then rights = "-" end
  return table.concat(rows, "/") .. " "
    .. ((self.side == WHITE) and "w" or "b") .. " " .. rights .. " "
    .. ((self.ep ~= 0) and squareName(self.ep) or "-") .. " "
    .. tostring(self.half) .. " " .. tostring(self.full)
end

-- ------------------------------------------------------------ board reads --

function Chess:at(sq)
  if not ONBOARD[sq] then return nil end
  return self.board[sq]
end

function Chess:kingSq(side) return self.king[side or self.side] end

-- True when `side`'s piece could capture onto `sq` if an enemy stood there.
-- Written as "who attacks this square" rather than "what does this piece
-- attack" because that is the question castling, check and the legality
-- filter all ask, and answering it directly skips generating a move list.
function Chess:attacked(sq, by)
  local b = self.board

  -- Pawns. A White pawn on s hits s-11 and s-9, so read the relation backwards
  -- from the square being asked about.
  if by == WHITE then
    local p = code(WHITE, PAWN)
    if b[sq + 11] == p or b[sq + 9] == p then return true end
  else
    local p = code(BLACK, PAWN)
    if b[sq - 11] == p or b[sq - 9] == p then return true end
  end

  local n = code(by, KNIGHT)
  for i = 1, 8 do
    if b[sq + KNIGHT_D[i]] == n then return true end
  end

  local k = code(by, KING)
  for i = 1, 8 do
    if b[sq + KING_D[i]] == k then return true end
  end

  local q = code(by, QUEEN)
  local r = code(by, ROOK)
  for i = 1, 4 do
    local d = ROOK_D[i]
    local t = sq + d
    local pc = b[t]
    while pc == EMPTY do t = t + d; pc = b[t] end
    if pc == r or pc == q then return true end
  end

  local bi = code(by, BISHOP)
  for i = 1, 4 do
    local d = BISHOP_D[i]
    local t = sq + d
    local pc = b[t]
    while pc == EMPTY do t = t + d; pc = b[t] end
    if pc == bi or pc == q then return true end
  end

  return false
end

function Chess:inCheck(side)
  side = side or self.side
  return self:attacked(self.king[side], 3 - side)
end

-- --------------------------------------------------- move generation ------
--
-- Pseudo-legal: these moves obey how the pieces move, but may leave their own
-- king in check. Legality is a filter applied on top -- see legalMoves --
-- because that is the rule as it actually is: a move is illegal if it leaves
-- your king attacked, and pins, discovered checks and en-passant's peculiar
-- two-square removal all fall out of that one test instead of needing cases
-- of their own.
--
-- Writes into `out` and returns the count, so the caller keeps one array
-- forever and the generator never allocates.

local PROMO_PIECES = { QUEEN, ROOK, BISHOP, KNIGHT }
Chess.PROMO_PIECES = PROMO_PIECES

function Chess:generate(out, capturesOnly)
  local b = self.board
  local us = self.side
  local them = 3 - us
  local list, count = self.plist[us], self.pcount[us]
  local n = 0

  local push = PUSH[us]
  local capd = CAPD[us]
  local homeRow, promoRow = HOME_ROW[us], PROMO_ROW[us]
  local ep = self.ep

  for i = 1, count do
    local from = list[i]
    local pc = b[from]
    local t = TYPE[pc]

    if t == PAWN then
      local one = from + push
      local promoting = floor(one / 10) == promoRow

      if b[one] == EMPTY then
        if promoting then
          for k = 1, 4 do
            n = n + 1; out[n] = encode(from, one, PROMO_PIECES[k], FLAG_NORMAL)
          end
        elseif not capturesOnly then
          n = n + 1; out[n] = encode(from, one, 0, FLAG_NORMAL)
          if floor(from / 10) == homeRow and b[one + push] == EMPTY then
            n = n + 1; out[n] = encode(from, one + push, 0, FLAG_DOUBLE)
          end
        end
      end

      for d = 1, 2 do
        local to = from + capd[d]
        local target = b[to]
        if target ~= OFF then
          if target ~= EMPTY and COLOR[target] == them then
            if promoting then
              for k = 1, 4 do
                n = n + 1; out[n] = encode(from, to, PROMO_PIECES[k], FLAG_NORMAL)
              end
            else
              n = n + 1; out[n] = encode(from, to, 0, FLAG_NORMAL)
            end
          elseif target == EMPTY and to == ep and ep ~= 0 then
            n = n + 1; out[n] = encode(from, to, 0, FLAG_EP)
          end
        end
      end

    elseif t == KNIGHT or t == KING then
      local dirs = (t == KNIGHT) and KNIGHT_D or KING_D
      for d = 1, 8 do
        local to = from + dirs[d]
        local target = b[to]
        if target == EMPTY then
          if not capturesOnly then n = n + 1; out[n] = encode(from, to, 0, FLAG_NORMAL) end
        elseif target ~= OFF and COLOR[target] == them then
          n = n + 1; out[n] = encode(from, to, 0, FLAG_NORMAL)
        end
      end

    else
      local dirs = SLIDE[t]
      for d = 1, #dirs do
        local step = dirs[d]
        local to = from + step
        local target = b[to]
        while target == EMPTY do
          if not capturesOnly then n = n + 1; out[n] = encode(from, to, 0, FLAG_NORMAL) end
          to = to + step
          target = b[to]
        end
        if target ~= OFF and COLOR[target] == them then
          n = n + 1; out[n] = encode(from, to, 0, FLAG_NORMAL)
        end
      end
    end
  end

  -- Castling. Never a capture, so the quiescence search skips it entirely.
  if not capturesOnly then
    local first = (us == WHITE) and WK or BK
    for right = first, first + 1 do
      local C = CASTLING[right]
      if self.castle[right] and b[C.king] == code(us, KING)
          and b[C.rook] == code(us, ROOK) then
        local blocked = false
        local e = C.empty
        for j = 1, #e do
          if b[e[j]] ~= EMPTY then blocked = true; break end
        end
        if not blocked then
          -- The king may not start in, pass through, or land on an attacked
          -- square. The last of those the legality filter would catch anyway;
          -- the first two it would not, so all three are checked here.
          local s = C.safe
          for j = 1, #s do
            if self:attacked(s[j], them) then blocked = true; break end
          end
        end
        if not blocked then
          n = n + 1; out[n] = encode(C.king, C.kingTo, 0, C.flag)
        end
      end
    end
  end

  return n
end

-- Pseudo-legal moves filtered down to the legal ones, by playing each and
-- asking whether the mover's king is attacked. Every rule that looks like a
-- special case -- absolute pins, moving out of check, the en passant that
-- would uncover a rook on the fifth rank -- is this one test.
function Chess:legalMoves(out)
  out = out or {}
  local pseudo = self._pseudo
  local n = self:generate(pseudo, false)
  local k = 0
  for i = 1, n do
    local m = pseudo[i]
    local us = self.side
    self:make(m)
    if not self:attacked(self.king[us], self.side) then
      k = k + 1
      out[k] = m
    end
    self:unmake()
  end
  for i = k + 1, #out do out[i] = nil end
  return k, out
end

-- The legal moves that start on `sq`. What the board highlights when a player
-- picks a piece up -- essential on a screen this small.
function Chess:legalMovesFrom(sq, out)
  out = out or {}
  local all = {}
  local n = self:legalMoves(all)
  local k = 0
  for i = 1, n do
    if all[i] % 128 == sq then k = k + 1; out[k] = all[i] end
  end
  for i = k + 1, #out do out[i] = nil end
  return k, out
end

function Chess:isLegal(m)
  local all = {}
  local n = self:legalMoves(all)
  for i = 1, n do if all[i] == m then return true end end
  return false
end

-- ------------------------------------------------------- make and unmake ---

function Chess:make(m)
  local from, to, promo, flag = decode(m)
  local b = self.board
  local us = self.side
  local pc = b[from]

  local ply = self.ply + 1
  local u = self.hist[ply]
  if not u then u = {}; self.hist[ply] = u end

  u.move = m
  u.ep = self.ep
  u.half = self.half
  u.captured = EMPTY
  u.capSq = 0
  u.c1, u.c2 = self.castle[WK], self.castle[WQ]
  u.c3, u.c4 = self.castle[BK], self.castle[BQ]

  self.half = self.half + 1

  if flag == FLAG_EP then
    -- The pawn taken en passant is not on the destination square. This is the
    -- only capture in chess where those differ, and the only reason the undo
    -- record carries a square alongside the piece.
    local capSq = to - PUSH[us]
    u.captured, u.capSq = b[capSq], capSq
    removePiece(self, capSq)
    self.half = 0
  elseif b[to] ~= EMPTY then
    u.captured, u.capSq = b[to], to
    removePiece(self, to)
    self.half = 0
  end

  movePiece(self, from, to)
  if TYPE[pc] == PAWN then self.half = 0 end

  if promo ~= 0 then
    removePiece(self, to)
    addPiece(self, to, code(us, promo))
  end

  if flag == FLAG_KCASTLE then
    movePiece(self, to + 1, to - 1)
  elseif flag == FLAG_QCASTLE then
    movePiece(self, to - 2, to + 1)
  end

  if TYPE[pc] == KING then self.king[us] = to end

  -- A double push is the only move that creates an en passant target, and it
  -- lasts exactly one ply -- every other move clears it.
  self.ep = (flag == FLAG_DOUBLE) and ((from + to) / 2) or 0

  local lost = RIGHTS_LOST[from]
  if lost then for j = 1, #lost do self.castle[lost[j]] = false end end
  lost = RIGHTS_LOST[to]
  if lost then for j = 1, #lost do self.castle[lost[j]] = false end end

  self.side = 3 - us
  if us == BLACK then self.full = self.full + 1 end
  self.ply = ply
end

function Chess:unmake()
  local ply = self.ply
  local u = self.hist[ply]
  local from, to, promo, flag = decode(u.move)
  local us = 3 - self.side

  self.ply = ply - 1
  self.side = us
  if us == BLACK then self.full = self.full - 1 end
  self.ep = u.ep
  self.half = u.half
  self.castle[WK], self.castle[WQ] = u.c1, u.c2
  self.castle[BK], self.castle[BQ] = u.c3, u.c4

  if flag == FLAG_KCASTLE then
    movePiece(self, to - 1, to + 1)
  elseif flag == FLAG_QCASTLE then
    movePiece(self, to + 1, to - 2)
  end

  if promo ~= 0 then
    removePiece(self, to)
    addPiece(self, to, code(us, PAWN))
  end

  movePiece(self, to, from)
  if TYPE[self.board[from]] == KING then self.king[us] = from end

  if u.captured ~= EMPTY then addPiece(self, u.capSq, u.captured) end
end

-- Copies just the position -- not the game log, not the repetition table --
-- into `dst`. The bot searches a scratch copy rather than the board being
-- played on, because a suspended search is suspended mid-mutation: on a
-- shared board on.paint would draw the search's half-explored guesses, and
-- the player would watch phantom pieces appear and vanish. One copy per move
-- is nothing; a copy per node would have cost more than the search.
function Chess:copyInto(dst)
  local src, out = self.board, dst.board
  for i = 0, 119 do out[i] = src[i] end
  for c = 1, 2 do
    local s, d, n = self.plist[c], dst.plist[c], self.pcount[c]
    for i = 1, n do d[i] = s[i] end
    for i = n + 1, #d do d[i] = nil end
    dst.pcount[c] = n
  end
  for _, sq in ipairs(SQUARES) do dst.pindex[sq] = self.pindex[sq] end
  for pc = 1, 12 do dst.counts[pc] = self.counts[pc] end
  dst.score, dst.npm = self.score, self.npm
  dst.side, dst.ep = self.side, self.ep
  dst.half, dst.full = self.half, self.full
  dst.castle[WK], dst.castle[WQ] = self.castle[WK], self.castle[WQ]
  dst.castle[BK], dst.castle[BQ] = self.castle[BK], self.castle[BQ]
  dst.king[WHITE], dst.king[BLACK] = self.king[WHITE], self.king[BLACK]
  dst.ply = 0
  dst.state = "playing"
  return dst
end

-- ------------------------------------------------- repetition and results --
--
-- Zobrist hashing wants XOR, which Lua 5.1 on the handheld does not have. So
-- a position's identity is a string: the 64 squares, the side to move, the
-- four castling rights and the en passant file. Building one costs far more
-- than a hash would, but it happens once per played move and never inside the
-- search, so it does not show up anywhere it matters.

-- FIDE counts two positions as the same only if the same moves are available
-- in both, so an en passant square that nobody can actually capture onto must
-- not distinguish them.
function Chess:epUsable()
  local ep = self.ep
  if ep == 0 then return false end
  local p = code(self.side, PAWN)
  local c = CAPD[self.side]
  return self.board[ep - c[1]] == p or self.board[ep - c[2]] == p
end

function Chess:positionKey()
  local t = self._scratch
  local b = self.board
  for i = 1, 64 do t[i] = CHAR_OF[b[SQUARES[i]]] end
  t[65] = (self.side == WHITE) and "w" or "b"
  t[66] = (self.castle[WK] and "K" or "-") .. (self.castle[WQ] and "Q" or "-")
       .. (self.castle[BK] and "k" or "-") .. (self.castle[BQ] and "q" or "-")
  t[67] = self:epUsable() and tostring(fileOf(self.ep)) or "-"
  return table.concat(t, "", 1, 67)
end

function Chess:noteRepetition()
  local k = self:positionKey()
  self.keys = self.keys or {}
  self.keys[#self.keys + 1] = k
  self.reps[k] = (self.reps[k] or 0) + 1
  return k
end

function Chess:repetitionCount()
  local keys = self.keys
  if not keys or #keys == 0 then return 0 end
  return self.reps[keys[#keys]] or 0
end

-- K vs K, K+minor vs K, and same-coloured bishops. Deliberately not the wider
-- "cannot be forced" set: two knights against a bare king cannot be forced,
-- but it can be reached with cooperation, so under FIDE it is not a dead
-- position and play continues.
function Chess:insufficientMaterial()
  local c = self.counts
  if c[1] + c[7] > 0 then return false end                 -- any pawn
  if c[4] + c[10] + c[5] + c[11] > 0 then return false end -- any rook or queen

  local wMinor, bMinor = c[2] + c[3], c[8] + c[9]
  if wMinor + bMinor <= 1 then return true end             -- K v K, K+minor v K
  if wMinor == 1 and bMinor == 1 and c[3] == 1 and c[9] == 1 then
    local wsq, bsq
    for i = 1, self.pcount[WHITE] do
      local sq = self.plist[WHITE][i]
      if TYPE[self.board[sq]] == BISHOP then wsq = sq end
    end
    for i = 1, self.pcount[BLACK] do
      local sq = self.plist[BLACK][i]
      if TYPE[self.board[sq]] == BISHOP then bsq = sq end
    end
    return isLight(wsq) == isLight(bsq)
  end
  return false
end

-- Sets self.result and self.state. Checkmate and stalemate are settled by the
-- one question "does the side to move have a legal move", with check deciding
-- which of the two it is; the drawing rules are checked after, since a mate
-- delivered on the hundredth half-move is still a mate.
function Chess:updateResult()
  local n = self:legalMoves(self._scratchMoves or {})
  if n == 0 then
    if self:inCheck() then
      self.result = { kind = "checkmate", winner = 3 - self.side }
    else
      self.result = { kind = "stalemate" }
    end
    self.state = "over"
    return self.result
  end

  if self:insufficientMaterial() then
    self.result = { kind = "material" }
  elseif self.half >= 100 then
    self.result = { kind = "fifty" }
  elseif self:repetitionCount() >= 3 then
    self.result = { kind = "repetition" }
  else
    self.result = nil
    if self.state ~= "ready" then self.state = "playing" end
    return nil
  end
  self.state = "over"
  return self.result
end

function Chess:isOver() return self.state == "over" end

-- ------------------------------------------------------- the played game --

-- Long algebraic: unambiguous without needing disambiguation rules, and short
-- enough for the sidebar. Must be called before the move is made, since it
-- reads what is standing on the two squares.
function Chess:moveText(m)
  local from, to, promo, flag = decode(m)
  if flag == FLAG_KCASTLE then return "O-O" end
  if flag == FLAG_QCASTLE then return "O-O-O" end
  local pc = self.board[from]
  local t = TYPE[pc]
  local takes = (self.board[to] ~= EMPTY) or (flag == FLAG_EP)
  local s = ((t == PAWN) and "" or LETTER[t])
    .. squareName(from) .. (takes and "x" or "-") .. squareName(to)
  if promo ~= 0 then s = s .. "=" .. LETTER[promo] end
  return s
end

-- Plays a legal move and advances the game state. Returns false for anything
-- illegal, so main.lua can hand user input straight in.
function Chess:play(m)
  if self.state ~= "playing" then return false end
  if not self:isLegal(m) then return false end
  local text = self:moveText(m)
  local from, to = m % 128, floor(m / 128) % 128
  self:make(m)
  self.moves[#self.moves + 1] = { move = m, text = text, from = from, to = to }
  self:noteRepetition()
  self:updateResult()
  return true
end

-- Takes the last move back. Make/unmake already carries everything the
-- position needs; the only extra work is the repetition tally, which lives a
-- level above it.
function Chess:takeback()
  local n = #self.moves
  if n == 0 then return false end
  local k = self.keys[#self.keys]
  local c = (self.reps[k] or 1) - 1
  self.reps[k] = (c > 0) and c or nil
  self.keys[#self.keys] = nil
  self.moves[n] = nil
  self:unmake()
  self.state = "playing"
  self.result = nil
  self:updateResult()
  return true
end

function Chess:lastMove()
  return self.moves[#self.moves]
end

-- How many of each type `side` has taken, for the sidebar's material tally.
-- A promotion makes this approximate -- a promoted queen reads as a pawn
-- captured -- which is why it clamps at zero rather than pretending to be a
-- ledger.
local INITIAL = { 8, 2, 2, 2, 1, 1 }
function Chess:capturedBy(side, out)
  out = out or {}
  local them = 3 - side
  for t = 1, 5 do
    local left = self.counts[code(them, t)]
    local gone = INITIAL[t] - left
    out[t] = (gone > 0) and gone or 0
  end
  return out
end

-- Material balance in pawns, from `side`'s point of view. Rounded toward
-- zero, not down: floor() would report a side a knight behind as four pawns
-- down rather than three, which is the sort of small lie that makes a player
-- distrust the whole sidebar.
function Chess:materialEdge(side)
  local s = 0
  for t = 1, 5 do
    s = s + VALUE[t] * (self.counts[code(WHITE, t)] - self.counts[code(BLACK, t)])
  end
  s = (s >= 0) and floor(s / 100) or -floor(-s / 100)
  return (side == WHITE) and s or -s
end

-- Starts a fresh game. `opts.fen` sets a position; everything else defaults
-- back to the standard array.
function Chess:reset(opts)
  opts = opts or {}
  self.mode = opts.mode or self.mode
  self.botSide = opts.botSide or self.botSide
  self:setup(opts.fen or START_FEN)
  self.state = opts.state or "playing"
  return self
end

function Chess:isBotTurn()
  return self.mode == "bot" and self.side == self.botSide
end

-- ============================================================== the bot =====

local AI = {}
AI.__index = AI
Chess.AI = AI

-- Far enough above any positional score that a mate always outranks one, and
-- small enough that MATE - ply stays comfortably exact in a double.
local MATE = 100000
local INF = 1e9
AI.MATE = MATE

-- Quiescence plies. Without a quiescence search a two-ply bot hangs pieces
-- constantly: it stops the search in the middle of an exchange and scores the
-- half of it that went its way. Four extra plies of captures is enough to see
-- a normal exchange out, and bounding it is what keeps a pathological
-- position from eating the whole node budget.
local QMAX = 4

-- Nodes of search the host should spend per timer tick.
--
-- The whole point of the incremental search is that this number is bounded: a
-- search that ran to completion inside one on.timer() would freeze the screen
-- and queue up keypresses, which reads to the player as a crash.
--
-- Measured on the build container (tests/chess/run.lua prints this table):
--
--   depth    1     2      3      4
--   nodes   94   547   2660  19665   (mean, cumulative, with quiescence)
--
-- at ~12us a node, so ~83k nodes/sec here. A chess node is far more work
-- than a Connect Four one -- thirty-odd moves generated through sliding rays,
-- a make, an unmake and a legality test each -- which is where the difference
-- from that game's 3us comes from. The handheld's 396MHz ARM runs interpreted
-- Lua far slower than this x86 -- call it 50x, the one number here that is an
-- estimate rather than a measurement, and good to perhaps a factor of two --
-- so ~1660 nodes/sec, ~83 nodes in a 0.05s tick. Half of that is the budget:
Chess.TICK_NODES = 45

function AI.new(game, opts)
  opts = opts or {}
  local self = setmetatable({}, AI)
  -- root is the game being played and is only ever read; pos is the scratch
  -- copy the search mutates. See Chess:copyInto for why they are not one.
  self.root = game
  self.pos = Chess.new()
  self.maxDepth = opts.maxDepth or 3
  self.nodeBudget = opts.nodeBudget or 60000
  self.temperature = opts.temperature or 0
  self.qmax = opts.qmax or QMAX
  self.rand = opts.rand or game.rand
  self.stack = {}
  self.rootMoves = {}
  self.rootScore = {}  -- move -> value, for the iteration in progress
  self.bestScore = {}  -- move -> value, from the last completed iteration
  self.sp = 0
  self:cancel()
  return self
end

-- Difficulty comes from move SELECTION, not from depth.
--
-- Depth is already pinned near the floor by what interpreted Lua on a 396MHz
-- ARM can do, so there is no room to make an easy bot by searching less --
-- and "a random move with probability p" is instantly recognisable as a
-- computer throwing a game away. Instead every level searches about as deeply
-- as it can and then picks from the root scores with a temperature-weighted
-- softmax: at temperature 0 that is the best move, and as it rises, moves
-- within a pawn or two of best start to come up. A weak bot chosen this way
-- plays *plausible* moves that are merely not the best ones.
--
-- temperature is in centipawns: the score gap at which a move becomes about
-- e times less likely than the best one.
--
-- maxDepth and nodeBudget are ceilings, not promises. What the bot really
-- gets is thinkTicks * TICK_NODES nodes, and iterative deepening turns that
-- into "the deepest complete search that fit". See the measurements printed
-- by tests/chess/run.lua.
-- Measured at 45 nodes a tick over 20 random midgame positions, driven
-- exactly as main.lua drives it (tests/chess/run.lua prints this one too):
--
--   Easy    40 ticks (2.0s)    1380 nodes   depth 1.3
--   Medium  80 ticks (4.0s)    3215 nodes   depth 2.2
--   Hard   120 ticks (6.0s)    5400 nodes   depth 2.9
--
-- One to three ply plus quiescence, which is what this hardware supports and
-- what the bot is honestly built for: it plays legal, sensible chess and
-- punishes a hanging piece. It does not play well, and is not meant to.
--
-- Easy lands near a single ply on purpose. Its weakness is meant to come from
-- the temperature, not from waiting: at depth one the quiescence search still
-- sees a hanging piece and a losing exchange, so what it plays is a plausible
-- move that is merely not the best one -- and it answers in two seconds
-- rather than six, which is most of what makes it the beginner's level.
--
-- Several seconds a move is a long pause in an arcade game and an ordinary
-- one in chess, which is the other reason the tick counts are what they are.
-- If the 50x estimate above is wrong the bot does not break: each level caps
-- its turn in *ticks*, and iterative deepening means whatever depth finished
-- inside them is the one that plays.
--
-- nodeBudget is what binds instead on a desktop, where the same ticks would
-- be six seconds of a search that finished in a twentieth of one.
Chess.LEVELS = {
  { name = "Easy",   maxDepth = 2, temperature = 180, nodeBudget = 12000,  thinkTicks = 40 },
  { name = "Medium", maxDepth = 3, temperature = 55,  nodeBudget = 40000,  thinkTicks = 80 },
  { name = "Hard",   maxDepth = 4, temperature = 0,   nodeBudget = 150000, thinkTicks = 120 },
}

function AI.fromLevel(game, level, opts)
  local L = Chess.LEVELS[level] or Chess.LEVELS[#Chess.LEVELS]
  local o = { maxDepth = L.maxDepth, temperature = L.temperature,
              nodeBudget = L.nodeBudget }
  if opts then for k, v in pairs(opts) do o[k] = v end end
  return AI.new(game, o)
end

function AI:frame(n)
  local f = self.stack[n]
  if not f then
    f = { moves = {}, scores = {} }
    self.stack[n] = f
  end
  return f
end

-- Puts back every move the search still has played on its scratch board.
--
-- Abandoning an iteration part-way -- which running out of budget does, and
-- which is the normal case on a handheld -- leaves one made move per live
-- frame. begin() copies the position in fresh and would overwrite them
-- anyway, so this is belt and braces: it keeps ai.pos a legal position at
-- every moment between calls, which is cheap to hold and unpleasant to debug
-- the absence of. Deepest frame first, because that move was made last.
function AI:unwind()
  local sp = self.sp or 0
  while sp >= 1 do
    local f = self.stack[sp]
    if f and f.child then
      self.pos:unmake()
      f.child = nil
    end
    sp = sp - 1
  end
  self.sp = 0
end

function AI:cancel()
  self:unwind()
  self.active = false
  self.done = false
  self.result = nil
  self.nodes = 0
  self.searchDepth = 0
  self.completedDepth = nil
  self.best = nil
  self.bestValue = 0
  self.nRoot = 0
  for k in pairs(self.rootScore) do self.rootScore[k] = nil end
  for k in pairs(self.bestScore) do self.bestScore[k] = nil end
end

-- Static evaluation from the side to move's point of view; positive is good.
--
-- Almost nothing happens here: make/unmake keeps the material-plus-tables
-- total up to date as the search walks, and it is antisymmetric, so one side
-- reads the negation of the other. Only the kings' table depends on the
-- phase, so only that is applied here.
function AI:evaluate()
  local pos = self.pos
  local s = pos.score
  if pos.npm <= ENDGAME_NPM then
    s = s + KDELTA[6][pos.king[WHITE]] + KDELTA[12][pos.king[BLACK]]
  end
  if pos.side == WHITE then return s end
  return -s
end

-- ------------------------------------------- move ordering within a node ---
--
-- MVV-LVA: try taking the most valuable victim with the least valuable
-- attacker first. Alpha-beta's saving depends almost entirely on searching a
-- good move first, and in a position with any tactics at all the good move is
-- usually a capture.

function AI:order(f)
  local moves, scores, n = f.moves, f.scores, f.n

  -- At the root, last iteration's scores are a far better order than any
  -- static guess -- which is most of what makes iterative deepening pay for
  -- itself rather than just costing an extra pass.
  if f.root and self.completedDepth then
    local bs = self.bestScore
    for i = 1, n do scores[i] = bs[moves[i]] or -INF end
    return
  end

  local b = self.pos.board
  for i = 1, n do
    local m = moves[i]
    local to = floor(m / 128) % 128
    local promo = floor(m / 16384) % 8
    local flag = floor(m / 131072)
    local s = 0
    if flag == FLAG_EP then
      s = 100000 + VALUE[PAWN] * 16 - VALUE[PAWN]
    else
      local victim = b[to]
      if victim ~= EMPTY then
        s = 100000 + VALUE[TYPE[victim]] * 16 - VALUE[TYPE[b[m % 128]]]
      end
    end
    if promo ~= 0 then s = s + 90000 + VALUE[promo] end
    scores[i] = s
  end
end

-- Selection sort, one pick at a time rather than sorting the list up front:
-- with a beta cutoff most nodes only ever look at the first move or two, and
-- sorting the other thirty would be work thrown away.
function AI:pick(f, i)
  local moves, scores, n = f.moves, f.scores, f.n
  local bi, bv = i, scores[i]
  for j = i + 1, n do
    if scores[j] > bv then bi, bv = j, scores[j] end
  end
  if bi ~= i then
    moves[i], moves[bi] = moves[bi], moves[i]
    scores[i], scores[bi] = scores[bi], scores[i]
  end
  return moves[i]
end

-- --------------------------------------------------- the incremental search --
--
-- There are no threads on this machine, and a search that runs to completion
-- inside one on.timer() callback freezes the screen and queues up keypresses,
-- which reads to the player as a crash. So the search is an explicit state
-- machine over its own stack of frames: main.lua calls think(budget) once per
-- tick and the search advances by that many nodes and no more.
--
-- Frames mirror what a recursive alpha-beta would keep in locals:
--   depth      plies left below this node; <= 0 means quiescence
--   qply       how many quiescence plies deep, so it can be capped
--   alpha,beta the window, already negated for this side
--   best,bestMove  the best seen so far at this node
--   moves,scores,n,i  the move list, its ordering keys, and how far in we are
--   child      the move currently played on the board, awaiting its value
--   pending    a child's returned value, waiting to be folded in

function AI:startDepth(d)
  self.searchDepth = d
  self.sp = 1
  for k in pairs(self.rootScore) do self.rootScore[k] = nil end
  local f = self:frame(1)
  f.depth = d
  f.qply = 0
  f.alpha = -INF
  f.beta = INF
  f.ply = 0
  f.root = true
  f.stage = 0
  f.child = nil
  f.pending = nil
end

-- Begins a search for whoever is to move. Safe to call on a finished game:
-- it just reports "no move".
function AI:begin()
  self:cancel()
  self.root:copyInto(self.pos)
  self.nRoot = self.pos:legalMoves(self.rootMoves)

  if self.nRoot == 0 then
    self.done = true
    return
  end

  -- The fallback that guarantees think() can always name a legal move,
  -- however little work it has been allowed to do.
  self.best = self.rootMoves[1]

  -- Alpha-beta only proves an exact value for the best root move; the rest
  -- come back as "no better than this", which is not something a softmax can
  -- weigh. Widening the root window to full would fix that and cost about six
  -- times the nodes -- measured, and far too much here.
  --
  -- So the root window is loosened by a margin instead of removed. Every move
  -- within `margin` of the best gets an exact score, which is exactly the set
  -- the softmax cares about; anything worse comes back as an upper bound at
  -- best - margin, and at four temperatures wide that is a weight of e^-4,
  -- under two per cent of the best move's. Measured at about 3x the nodes of a
  -- plain search rather than 6x, and only the two sampling levels pay it --
  -- Hard runs at temperature 0 and so prunes normally.
  self.rootMargin = (self.temperature > 0) and (4 * self.temperature) or 0

  self.active = true
  self:startDepth(1)
end

function AI:ret(value)
  self.sp = self.sp - 1
  if self.sp == 0 then
    self:finishDepth(value)
  else
    self.stack[self.sp].pending = value
  end
end

function AI:settle()
  self:unwind()
  self.active = false
  self.done = true
  self.result = self:choose()
end

function AI:finishDepth(value)
  local root = self.stack[1]
  if root.bestMove ~= 0 then
    self.best = root.bestMove
    self.bestValue = value
    self.completedDepth = self.searchDepth
    for k in pairs(self.bestScore) do self.bestScore[k] = nil end
    for m, v in pairs(self.rootScore) do self.bestScore[m] = v end
  end

  -- Stop when there is nothing more to learn: the depth cap, or a mate
  -- already proved in either direction.
  if self.searchDepth >= self.maxDepth
      or self.bestValue >= MATE - 1000
      or self.bestValue <= -MATE + 1000 then
    self:settle()
  else
    self:startDepth(self.searchDepth + 1)
  end
end

function AI:step()
  local f = self.stack[self.sp]
  local pos = self.pos

  if f.stage == 0 then
    self.nodes = self.nodes + 1
    f.stage = 1
    f.inCheck = pos:inCheck(pos.side)
    f.best, f.bestMove, f.legal, f.i = -INF, 0, 0, 0
    f.child, f.pending = nil, nil

    -- A draw is a draw at any depth. Repetition is deliberately *not* checked
    -- inside the search: it would need the game's key history threaded
    -- through every node, and at three or four ply the bot cannot engineer a
    -- repetition far enough ahead for it to matter. The fifty-move counter is
    -- already part of the position, so that one costs a comparison.
    if f.ply > 0 and pos.half >= 100 then return self:ret(0) end

    local qs = f.depth <= 0
    f.qs = qs

    -- A hard floor on the quiescence search. Standing pat below is what
    -- normally stops it, but a node in check never stands pat -- it has to
    -- look at its evasions -- so a position holding a perpetual check would
    -- recurse until the node budget ran out, with the frame stack growing the
    -- whole way. This is the only thing that bounds that.
    if qs and f.qply >= self.qmax then return self:ret(self:evaluate()) end

    if qs and not f.inCheck then
      -- Stand pat: the side to move is never obliged to capture, so a
      -- position already good enough to beat beta needs no further search.
      local stand = self:evaluate()
      f.best = stand
      if stand >= f.beta then return self:ret(stand) end
      if stand > f.alpha then f.alpha = stand end
      f.n = pos:generate(f.moves, true)
    else
      -- In check there is no standing pat -- every evasion has to be looked
      -- at, or a quiescence node would happily report a score for a position
      -- where it is about to be mated.
      f.n = pos:generate(f.moves, false)
    end
    self:order(f)
    return
  end

  if f.pending ~= nil then
    -- Negamax: the child's value is from the other side's point of view, so
    -- it comes back negated.
    local v = -f.pending
    local m = f.child
    f.pending, f.child = nil, nil
    pos:unmake()
    if f.root then self.rootScore[m] = v end
    if v > f.best then f.best, f.bestMove = v, m end
    if v > f.alpha then f.alpha = v end
    if f.alpha >= f.beta then return self:ret(f.best) end
  end

  local i = f.i
  while i < f.n do
    i = i + 1
    f.i = i
    local m = self:pick(f, i)
    local us = pos.side
    pos:make(m)
    if pos:attacked(pos.king[us], pos.side) then
      -- Pseudo-legal only: it left its own king attacked, so it is no move at
      -- all. Not counted as a node, and not counted as a legal move, which is
      -- what makes "ran out of moves" below mean mate or stalemate.
      pos:unmake()
    else
      f.legal = f.legal + 1
      f.child = m
      local g = self:frame(self.sp + 1)
      g.depth = f.depth - 1
      g.qply = f.qs and (f.qply + 1) or 0
      g.alpha = -f.beta
      -- The root margin, when there is one, is the only place a node hands a
      -- child a window wider than its own alpha justifies. See begin().
      g.beta = (f.root and -f.alpha + self.rootMargin) or -f.alpha
      g.ply = f.ply + 1
      g.root = false
      g.stage = 0
      g.child = nil
      g.pending = nil
      self.sp = self.sp + 1
      return
    end
  end

  if f.legal == 0 and (not f.qs or f.inCheck) then
    -- Every move was tried and none was legal. Mate if the king is attacked,
    -- stalemate if it is not -- the one place the two are told apart.
    -- Mate is scored by distance from the root so that a mate found sooner
    -- beats the same mate found later, and the bot finishes games off.
    return self:ret(f.inCheck and (-MATE + f.ply) or 0)
  end
  return self:ret(f.best)
end

-- Turns the last completed iteration's root scores into an actual move.
-- Iterating self.rootMoves rather than the score table matters: pairs() order
-- is unspecified in Lua, and a bot whose choice depended on it could not be
-- reproduced from a seed.
function AI:choose()
  if not self.best then return nil end
  local T = self.temperature
  if T <= 0 or not self.completedDepth then return self.best end

  local top = -INF
  for i = 1, self.nRoot do
    local v = self.bestScore[self.rootMoves[i]]
    if v and v > top then top = v end
  end
  if top == -INF then return self.best end

  local moves, cumulative, total, k = {}, {}, 0, 0
  for i = 1, self.nRoot do
    local m = self.rootMoves[i]
    local v = self.bestScore[m]
    if v then
      k = k + 1
      total = total + exp((v - top) / T)
      moves[k], cumulative[k] = m, total
    end
  end
  if k == 0 then return self.best end

  local r = (self.rand(10000) - 1) / 10000 * total
  for i = 1, k do
    if r < cumulative[i] then return moves[i] end
  end
  return moves[k]
end

-- Does up to maxNodes nodes of work. Returns the chosen move once the search
-- has settled, or nil to mean "still thinking, call me again".
--
-- Slicing changes nothing about the answer: the budget only ever decides
-- *when* this returns, never *what*. That is worth keeping true -- it is what
-- tests/chess/run.lua leans on to check the sliced search against the
-- one-shot one.
function AI:think(maxNodes)
  if self.done then return self.result end
  if not self.active then self:begin() end
  if self.done then return self.result end

  local stop = self.nodes + (maxNodes or 500)
  if stop > self.nodeBudget then stop = self.nodeBudget end

  while self.active and self.nodes < stop do
    self:step()
  end

  -- Out of budget part-way through an iteration. Iterative deepening means
  -- the last completed depth has already left a usable move behind, which is
  -- the whole reason the search deepens rather than going straight for
  -- maxDepth: there is always an answer to give.
  if self.active and self.nodes >= self.nodeBudget then
    self:settle()
  end

  return self.result
end

-- Gives up on the iteration in progress and settles for the best move the
-- last completed depth found. main.lua calls this once the bot has used up
-- the ticks its difficulty allows, which is what bounds the bot's turn in
-- *time* on a machine whose speed this code has no way to know.
function AI:stop()
  if self.done then return self.result end
  if not self.active then self:begin() end
  if not self.done then self:settle() end
  return self.result
end

-- Runs the search out in one go. Used by the tests and by nothing on the
-- handheld, where blocking the event loop is exactly what must not happen.
function AI:solve()
  local mv
  repeat
    mv = self:think(self.nodeBudget)
  until self.done
  return mv
end

return Chess
