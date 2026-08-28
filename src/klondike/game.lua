-- game.lua -- pure Klondike solitaire rules.
--
-- This module deliberately knows nothing about the TI-Nspire: no `platform`,
-- no `gc`, no `timer`. That keeps it runnable under a plain Lua 5.1
-- interpreter on a laptop, so the rules can be tested without a calculator.
-- All drawing, input and timing lives in src/klondike/main.lua.
--
-- Klondike's *rules* are easy: descending alternating colours down the
-- tableau, ascending same-suit from the ace up the foundations. What is not
-- easy is the bookkeeping around them, and everything below is shaped by the
-- three places an implementation actually goes wrong:
--
--   1. Card integrity. Every operation has to preserve exactly 52 distinct
--      cards across stock, waste, foundations and tableau. Dropping or
--      duplicating one is silent -- the game plays on, just unwinnably.
--   2. Undo has to restore *hidden* information. Turning a face-down card up
--      is a real state change; an undo that leaves it face-up has handed the
--      player free information. So moves are make/unmake against a small undo
--      record, not a snapshot, and the record carries the flip.
--   3. The draw-3 waste has an ordering that is easy to get backwards in a way
--      that still looks plausible on screen. See `recycle` for the derivation.

local Klondike = {}
Klondike.__index = Klondike

-- ------------------------------------------------------------------ tuning --
-- Standard Klondike scoring. Only the numbers; the rules are below.
local SCORE_WASTE_TO_TAB   = 5
local SCORE_WASTE_TO_FOUND = 10
local SCORE_TAB_TO_FOUND   = 10
local SCORE_FLIP           = 5    -- turning a tableau card face up
local SCORE_FOUND_TO_TAB   = -15  -- taking one back down
local SCORE_RECYCLE_1      = -100 -- per pass, draw-1: passes are nearly free
local SCORE_RECYCLE_3      = -20  -- per pass, draw-3: you only see a third
local DEFAULT_MAX_PASSES   = 3    -- when the "limited passes" option is on
-- ---------------------------------------------------------------------------

local COLUMNS   = 7
local SUITS     = 4
local RANKS     = 13
local DECK      = SUITS * RANKS

Klondike.COLUMNS, Klondike.SUITS, Klondike.RANKS, Klondike.DECK =
  COLUMNS, SUITS, RANKS, DECK

-- Suit order is fixed by the card encoding below and by the foundation slots,
-- which are indexed *by suit* -- that makes "a foundation holds one suit"
-- structural rather than something to check at runtime.
Klondike.CLUBS, Klondike.DIAMONDS, Klondike.HEARTS, Klondike.SPADES = 1, 2, 3, 4

local RANK_NAMES = { "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K" }
local SUIT_NAMES = { "clubs", "diamonds", "hearts", "spades" }
local SUIT_LETTERS = { "C", "D", "H", "S" }

Klondike.RANK_NAMES, Klondike.SUIT_NAMES = RANK_NAMES, SUIT_NAMES

-- ------------------------------------------------------------------- cards --
-- A card is one integer 1..52: (suit - 1) * 13 + rank, with rank 1 = ace and
-- rank 13 = king. Plain arithmetic, no packed bitfields -- this is Lua 5.1 on
-- a handheld with no `bit` library, so there are no bitwise operators to
-- unpack one with.

local function suitOf(card) return math.floor((card - 1) / RANKS) + 1 end
local function rankOf(card) return (card - 1) % RANKS + 1 end
-- Diamonds and hearts are the red suits, so suit 2 and 3 -- which is why the
-- suit order above is clubs, diamonds, hearts, spades and not alphabetical.
local function isRed(card) local s = suitOf(card) return s == 2 or s == 3 end

Klondike.suitOf, Klondike.rankOf, Klondike.isRed = suitOf, rankOf, isRed

function Klondike.cardName(card)
  return RANK_NAMES[rankOf(card)] .. SUIT_LETTERS[suitOf(card)]
end

-- --------------------------------------------------------------------- rng --
-- A Park-Miller minimal-standard generator rather than math.random, so that
-- "the same seed deals the same game" is a property of *this file* and not of
-- whichever Lua the code happens to be running under. The multiplier is small
-- enough that 16807 * 2147483646 stays well inside a double's 53-bit mantissa,
-- which matters because Lua 5.1 numbers are doubles and there is no integer
-- type to fall back on.
local RNG_M = 2147483647

local RNG_WARMUP = 8

local function makeRandom(seed)
  local s = math.floor(seed) % RNG_M
  if s <= 0 then s = s + RNG_M - 1 end
  -- Discard the first few outputs. A bare Park-Miller step is 16807 * s, so
  -- for the small, nearly-consecutive seeds this game actually gets -- a clock
  -- reading plus a handful of idle ticks -- the first output barely moves and
  -- the first few cards of consecutive deals come out the same. Spinning the
  -- state first is what makes "seed + 1" a different game rather than the same
  -- game with two cards swapped. tests/klondike/run.lua checks this by
  -- dealing hundreds of consecutive seeds and looking at the spread.
  for _ = 1, RNG_WARMUP do s = (16807 * s) % RNG_M end
  return function(n)
    s = (16807 * s) % RNG_M
    local i = math.floor((s - 1) / (RNG_M - 1) * n) + 1
    if i > n then i = n end        -- guards the closed upper end
    return i
  end
end

Klondike.makeRandom = makeRandom

-- ------------------------------------------------------------------- setup --

-- opts.seed      integer; the same seed always deals the same game.
-- opts.rand      function(n) -> 1..n, overriding the seeded generator.
-- opts.draw      1 or 3, cards turned per stock draw.
-- opts.maxPasses nil for unlimited, or the number of times through the stock.
-- opts.safeAuto  send obviously-safe cards up automatically (off by default).
function Klondike.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Klondike)
  self.drawCount = (opts.draw == 1) and 1 or 3
  self.maxPasses = opts.maxPasses          -- nil means unlimited
  self.safeAuto  = opts.safeAuto and true or false
  self:deal(opts.seed, opts.rand)
  return self
end

-- Fisher-Yates over 1..52, then the standard Klondike deal. `rand` is
-- injectable so a failing deal can be reproduced from its seed alone.
function Klondike:deal(seed, rand)
  self.seed = seed or 1
  self.rand = rand or makeRandom(self.seed)

  local deck = {}
  for c = 1, DECK do deck[c] = c end
  for i = DECK, 2, -1 do
    local j = self.rand(i)
    deck[i], deck[j] = deck[j], deck[i]
  end
  self.tab, self.down = {}, {}
  for c = 1, COLUMNS do self.tab[c] = {}; self.down[c] = 0 end

  -- Deal across: one card to each remaining column, left to right, seven
  -- times. Column c ends up with c cards, of which the last is face up.
  local next_ = 1
  for i = 1, COLUMNS do
    for c = i, COLUMNS do
      self.tab[c][#self.tab[c] + 1] = deck[next_]
      next_ = next_ + 1
    end
  end
  for c = 1, COLUMNS do self.down[c] = c - 1 end

  -- The rest becomes the stock. stock[#stock] is the *top* -- the next card
  -- off -- so the remaining deck is loaded back to front.
  self.stock, self.waste = {}, {}
  for i = DECK, next_, -1 do
    self.stock[#self.stock + 1] = deck[i]
  end

  self.found = {}
  for f = 1, SUITS do self.found[f] = {} end

  self.passes  = 1     -- passes *through* the stock; the deal is the first
  self.score   = 0
  self.moves   = 0
  self.history = {}
end

-- ------------------------------------------------------------------ access --

function Klondike:stockCount() return #self.stock end
function Klondike:wasteCount() return #self.waste end
function Klondike:wasteTop()   return self.waste[#self.waste] end
function Klondike:foundTop(f)  return self.found[f][#self.found[f]] end

function Klondike:foundationTotal()
  local n = 0
  for f = 1, SUITS do n = n + #self.found[f] end
  return n
end

function Klondike:isWon() return self:foundationTotal() == DECK end

-- The face-up cards of a column are the ones after the face-down block, so
-- `down[c]` is both the count of hidden cards and the index of the last of
-- them. A non-empty column always has at least one face-up card.
function Klondike:faceUpStart(c) return self.down[c] + 1 end

function Klondike:canRecycle()
  if #self.stock > 0 or #self.waste == 0 then return false end
  if not self.maxPasses then return true end
  return self.passes < self.maxPasses
end

-- ------------------------------------------------------------------- rules --

-- A card may go on a tableau column if the column is empty and the card is a
-- king, or if it is one rank below the exposed card and the opposite colour.
function Klondike:canPlaceOnTableau(card, c)
  local col = self.tab[c]
  local top = col[#col]
  if not top then return rankOf(card) == RANKS end
  return rankOf(card) == rankOf(top) - 1 and isRed(card) ~= isRed(top)
end

-- A card may go on its foundation only as the next rank up, ace first.
function Klondike:canPlaceOnFoundation(card)
  return rankOf(card) == #self.found[suitOf(card)] + 1
end

-- Whether tab[c][i..] is a run that may be picked up as a unit. The rules
-- below *maintain* this for every face-up run, so in a consistent game this
-- only ever fails for an index inside the face-down block -- but the move
-- generator and `play` both ask, so a bug that broke the property would show
-- up as an illegal move being refused rather than as a corrupted column.
function Klondike:isMovableRun(c, i)
  local col = self.tab[c]
  if i <= self.down[c] or i > #col then return false end
  for k = i, #col - 1 do
    local a, b = col[k], col[k + 1]
    if rankOf(b) ~= rankOf(a) - 1 or isRed(a) == isRed(b) then return false end
  end
  return true
end

-- ------------------------------------------------------------------- moves --
--
-- A move is a small table. `k` is the kind; the rest names the piles:
--
--   { k = "draw" }                 turn drawCount cards from stock to waste
--   { k = "recycle" }              waste back under the stock, one pass spent
--   { k = "wf", f = suit }         waste -> foundation
--   { k = "wt", t = column }       waste -> tableau
--   { k = "tf", c = column, f = suit }              tableau top -> foundation
--   { k = "tt", c = column, i = index, t = column } tableau run -> tableau
--   { k = "ft", f = suit, t = column }              foundation -> tableau
--
-- `moveKey` gives each one a canonical string so the generator and the
-- validator can be compared as sets, in both directions.

function Klondike.moveKey(m)
  local k = m.k
  if k == "draw" or k == "recycle" then return k end
  if k == "wf" then return "wf:" .. m.f end
  if k == "wt" then return "wt:" .. m.t end
  if k == "tf" then return "tf:" .. m.c .. ":" .. m.f end
  if k == "tt" then return "tt:" .. m.c .. ":" .. m.i .. ":" .. m.t end
  if k == "ft" then return "ft:" .. m.f .. ":" .. m.t end
  return "?"
end

-- Is this exact move legal right now? `play` uses it, and the tests check it
-- against `legalMoves` in both directions -- a generator and a validator that
-- only agree one way still let a whole class of bug through.
function Klondike:isLegal(m)
  if type(m) ~= "table" then return false end
  local k = m.k

  if k == "draw" then
    return #self.stock > 0

  elseif k == "recycle" then
    return self:canRecycle()

  elseif k == "wf" then
    local card = self:wasteTop()
    return card ~= nil and m.f == suitOf(card) and self:canPlaceOnFoundation(card)

  elseif k == "wt" then
    local card = self:wasteTop()
    if not card or not self.tab[m.t] then return false end
    return self:canPlaceOnTableau(card, m.t)

  elseif k == "tf" then
    local col = self.tab[m.c]
    if not col then return false end
    local card = col[#col]
    return card ~= nil and m.f == suitOf(card) and self:canPlaceOnFoundation(card)

  elseif k == "tt" then
    if not self.tab[m.c] or not self.tab[m.t] or m.c == m.t then return false end
    if not self:isMovableRun(m.c, m.i) then return false end
    return self:canPlaceOnTableau(self.tab[m.c][m.i], m.t)

  elseif k == "ft" then
    if not self.found[m.f] or not self.tab[m.t] then return false end
    local card = self:foundTop(m.f)
    return card ~= nil and self:canPlaceOnTableau(card, m.t)
  end

  return false
end

-- Every legal move, in a stable order. The UI filters this rather than
-- deciding for itself what may go where, so a highlighted destination and an
-- accepted move cannot disagree.
function Klondike:legalMoves()
  local out = {}
  local function add(m) out[#out + 1] = m end

  if #self.stock > 0 then add({ k = "draw" }) end
  if self:canRecycle() then add({ k = "recycle" }) end

  local w = self:wasteTop()
  if w then
    if self:canPlaceOnFoundation(w) then add({ k = "wf", f = suitOf(w) }) end
    for t = 1, COLUMNS do
      if self:canPlaceOnTableau(w, t) then add({ k = "wt", t = t }) end
    end
  end

  for c = 1, COLUMNS do
    local col = self.tab[c]
    local top = col[#col]
    if top and self:canPlaceOnFoundation(top) then
      add({ k = "tf", c = c, f = suitOf(top) })
    end
    for i = self:faceUpStart(c), #col do
      if self:isMovableRun(c, i) then
        for t = 1, COLUMNS do
          if t ~= c and self:canPlaceOnTableau(col[i], t) then
            add({ k = "tt", c = c, i = i, t = t })
          end
        end
      end
    end
  end

  for f = 1, SUITS do
    local card = self:foundTop(f)
    if card then
      for t = 1, COLUMNS do
        if self:canPlaceOnTableau(card, t) then add({ k = "ft", f = f, t = t }) end
      end
    end
  end

  return out
end

-- Only the legal moves that start from a given pile, for the UI's two-stage
-- selection: pick something up, then see everywhere it can go.
--   movesFrom("waste")            movesFrom("found", f)
--   movesFrom("tab", c, i)        -- i is the index the run starts at
--   movesFrom("stock")
function Klondike:movesFrom(kind, a, b)
  local out = {}
  for _, m in ipairs(self:legalMoves()) do
    local keep = false
    if kind == "stock" then
      keep = (m.k == "draw" or m.k == "recycle")
    elseif kind == "waste" then
      keep = (m.k == "wf" or m.k == "wt")
    elseif kind == "found" then
      keep = (m.k == "ft" and m.f == a)
    elseif kind == "tab" then
      keep = ((m.k == "tf" and m.c == a and b == #self.tab[a]) or
              (m.k == "tt" and m.c == a and m.i == b))
    end
    if keep then out[#out + 1] = m end
  end
  return out
end

function Klondike:isStuck()
  return #self:legalMoves() == 0
end

-- ---------------------------------------------------------- make and unmake --

-- After cards leave a column, the card they were sitting on becomes visible.
-- Returns whether a flip happened, because undo has to put it back down --
-- the classic solitaire undo bug is leaving it face-up and quietly handing
-- the player information the position never contained.
function Klondike:flipExposed(c)
  local col = self.tab[c]
  if #col > 0 and self.down[c] == #col then
    self.down[c] = #col - 1
    return true
  end
  return false
end

-- Slides the top n cards across keeping their order, for tableau runs: a
-- K-Q-J picked up and put down is still a K-Q-J.
local function moveCards(from, to, n)
  local at = #from - n
  for i = 1, n do
    to[#to + 1] = from[at + i]
    from[at + i] = nil
  end
end

-- Turning cards between the stock and the waste is *not* that. Cards are
-- turned over one at a time, so the group arrives reversed: with the stock
-- top-first A, B, C, the player turns A face-up first, then covers it with B,
-- then with C, and it is C -- the third card down -- that ends up playable.
-- Getting this backwards leaves the stock's own top card on the waste, which
-- quietly turns draw-3 into draw-1 with extra steps.
local function pour(from, to, n)
  for _ = 1, n do to[#to + 1] = table.remove(from) end
end

-- The waste is turned back over to become the new stock.
--
-- Getting this backwards is the classic draw-3 bug, and it is invisible on
-- screen: the pile still counts down and still recycles, it just deals a
-- different partition of the deck on every pass, which quietly makes the game
-- much easier than Klondike.
--
-- Physically: the waste is a face-up pile, so its topmost card is the one
-- dealt last. You pick the pile up and turn the whole block over, which puts
-- the *oldest* card -- the bottom one -- on top, face down. So the new stock,
-- top first, is the waste in the order it was dealt.
--
-- With stock[#stock] as the top, that is exactly "pop the waste, push the
-- stock" until the waste is empty, and it makes recycle the inverse of
-- drawing. The check that falls out of that, and which the tests assert: draw
-- the whole stock away with no other play, recycle, and the stock is the
-- identical array it started as -- so a second pass deals the same cards in
-- the same groups of three, which is the whole reason draw-3 is hard.
local function recycleWaste(self)
  local n = #self.waste
  pour(self.waste, self.stock, n)
  return n
end

local function scoreBy(self, delta)
  local before = self.score
  self.score = self.score + delta
  if self.score < 0 then self.score = 0 end   -- standard scoring has a floor
  return self.score - before                  -- the delta actually applied
end

-- Applies `m` if it is legal, pushing an undo record. Returns true on success.
function Klondike:play(m)
  if not self:isLegal(m) then return false end

  local rec = { k = m.k }
  local delta = 0

  if m.k == "draw" then
    local n = math.min(self.drawCount, #self.stock)
    pour(self.stock, self.waste, n)
    rec.n = n

  elseif m.k == "recycle" then
    rec.n = recycleWaste(self)
    self.passes = self.passes + 1
    delta = (self.drawCount == 1) and SCORE_RECYCLE_1 or SCORE_RECYCLE_3

  elseif m.k == "wf" then
    self.found[m.f][#self.found[m.f] + 1] = table.remove(self.waste)
    rec.f = m.f
    delta = SCORE_WASTE_TO_FOUND

  elseif m.k == "wt" then
    local col = self.tab[m.t]
    col[#col + 1] = table.remove(self.waste)
    rec.t = m.t
    delta = SCORE_WASTE_TO_TAB

  elseif m.k == "tf" then
    local col = self.tab[m.c]
    self.found[m.f][#self.found[m.f] + 1] = table.remove(col)
    rec.c, rec.f = m.c, m.f
    delta = SCORE_TAB_TO_FOUND
    rec.flipped = self:flipExposed(m.c)
    if rec.flipped then delta = delta + SCORE_FLIP end

  elseif m.k == "tt" then
    local n = #self.tab[m.c] - m.i + 1
    moveCards(self.tab[m.c], self.tab[m.t], n)
    rec.c, rec.t, rec.n = m.c, m.t, n
    rec.flipped = self:flipExposed(m.c)
    if rec.flipped then delta = SCORE_FLIP end

  elseif m.k == "ft" then
    local col = self.tab[m.t]
    col[#col + 1] = table.remove(self.found[m.f])
    rec.f, rec.t = m.f, m.t
    delta = SCORE_FOUND_TO_TAB
  end

  -- The delta stored is the one actually applied, after the score floor, so
  -- undo restores the score exactly rather than approximately.
  rec.d = scoreBy(self, delta)
  self.moves = self.moves + 1
  self.history[#self.history + 1] = rec
  return true
end

function Klondike:canUndo() return #self.history > 0 end

-- Unlimited undo, back to the deal. Each record is a handful of integers, so
-- the whole history of a long game is smaller than one board snapshot would
-- be -- which is the other reason to do it this way round.
function Klondike:undo()
  local rec = table.remove(self.history)
  if not rec then return false end

  if rec.k == "draw" then
    -- Undoing a draw is pouring the same cards back, which is exactly what a
    -- recycle does to the whole waste -- and that symmetry is the reason a
    -- full pass followed by a recycle restores the stock verbatim.
    pour(self.waste, self.stock, rec.n)

  elseif rec.k == "recycle" then
    pour(self.stock, self.waste, rec.n)
    self.passes = self.passes - 1

  elseif rec.k == "wf" then
    self.waste[#self.waste + 1] = table.remove(self.found[rec.f])

  elseif rec.k == "wt" then
    self.waste[#self.waste + 1] = table.remove(self.tab[rec.t])

  elseif rec.k == "tf" then
    if rec.flipped then self.down[rec.c] = self.down[rec.c] + 1 end
    local col = self.tab[rec.c]
    col[#col + 1] = table.remove(self.found[rec.f])

  elseif rec.k == "tt" then
    if rec.flipped then self.down[rec.c] = self.down[rec.c] + 1 end
    moveCards(self.tab[rec.t], self.tab[rec.c], rec.n)

  elseif rec.k == "ft" then
    self.found[rec.f][#self.found[rec.f] + 1] = table.remove(self.tab[rec.t])
  end

  self.score = self.score - rec.d
  self.moves = self.moves - 1
  return true
end

-- ------------------------------------------------------------- safe autoplay --

-- Is sending `card` to its foundation guaranteed never to cost the game?
--
-- The only thing a card in the tableau can still be *used* for is as a base
-- for the card one rank below it in the opposite colour -- there are exactly
-- two such cards. If both are already on their foundations, nothing can ever
-- be placed on this card again, so removing it can only help: it uncovers
-- what is underneath and blocks nothing.
--
-- Foundations fill from the ace up, so "both opposite-colour cards of rank
-- r-1 are already up" is just "both opposite-colour foundations have reached
-- at least r-1".
--
-- Aces and twos are unconditional. Nothing stacks on an ace (there is no rank
-- zero), and the only card that could stack on a two is an opposite-colour
-- ace, which is never wanted in the tableau either -- it can always go
-- straight up, and nothing stacks on it in turn.
--
-- This is deliberately conservative. An over-eager autoplay loses games that
-- were winnable, which is why the option is off by default.
function Klondike:isSafeToAutoPlay(card)
  if not self:canPlaceOnFoundation(card) then return false end
  local r = rankOf(card)
  if r <= 2 then return true end
  local a, b
  if isRed(card) then a, b = Klondike.CLUBS, Klondike.SPADES
  else a, b = Klondike.DIAMONDS, Klondike.HEARTS end
  return #self.found[a] >= r - 1 and #self.found[b] >= r - 1
end

-- One safe move to a foundation, or nil. Callers loop until it returns nil,
-- because sending one card up can make the next one safe.
function Klondike:safeAutoMove()
  local w = self:wasteTop()
  if w and self:isSafeToAutoPlay(w) then return { k = "wf", f = suitOf(w) } end
  for c = 1, COLUMNS do
    local col = self.tab[c]
    local top = col[#col]
    if top and self:isSafeToAutoPlay(top) then
      return { k = "tf", c = c, f = suitOf(top) }
    end
  end
  return nil
end

-- Plays safe cards up until there are none, and answers how many went. Only
-- called when the option is on; each one is a normal move, so all of them
-- undo one at a time like anything else.
function Klondike:runSafeAuto()
  local n = 0
  while true do
    local m = self:safeAutoMove()
    if not m then break end
    if not self:play(m) then break end
    n = n + 1
  end
  return n
end

return Klondike
