-- Tests for the pure game logic. Run with:  make GAME=klondike test
--
-- Klondike's rules are short enough to state in a sentence, so almost nothing
-- here tests them directly. What is tested is what the rules must *maintain*
-- while they are applied: that the deck stays a deck, that hidden cards stay
-- hidden, and that undo puts back exactly what a move took away. Those are
-- properties, not cases, so they are asserted continuously over a fuzz of
-- random legal play rather than in a handful of scripted games.

package.path = (os.getenv("GAME_SRC") or "src/klondike") .. "/?.lua;"
  .. "tests/?.lua;" .. package.path
local K = require("game")
local Solver = require("klondike.solver")

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

local COLUMNS, SUITS, RANKS, DECK = K.COLUMNS, K.SUITS, K.RANKS, K.DECK

-- Everything that makes two games the same game, including the parts a player
-- cannot see. This is what undo is checked against: not "the board looks
-- right" but "the state is identical", down to the face-down counts, the
-- stock/waste split, the pass count and the score.
local function fullKey(g)
  local p = { "D" .. g.drawCount, "P" .. g.passes,
              "S" .. g.score, "M" .. g.moves, "H" .. #g.history }
  for c = 1, COLUMNS do
    p[#p + 1] = "t" .. c .. "/" .. g.down[c] .. ":" .. table.concat(g.tab[c], ",")
  end
  for f = 1, SUITS do
    p[#p + 1] = "f" .. f .. ":" .. table.concat(g.found[f], ",")
  end
  p[#p + 1] = "stock:" .. table.concat(g.stock, ",")
  p[#p + 1] = "waste:" .. table.concat(g.waste, ",")
  return table.concat(p, "|")
end

-- A snapshot of just the per-column shape, for the face-down monotonicity
-- check, which is about how a column changes rather than what it holds.
local function shape(g)
  local s = {}
  for c = 1, COLUMNS do s[c] = { down = g.down[c], n = #g.tab[c] } end
  return s
end

-- ==================================================================
--  The invariants. Everything below calls these; they are the point.
-- ==================================================================

-- 1. The deck is the invariant: exactly one of each of the 52 rank/suit
--    pairs, somewhere, at every single step. A shuffle or a multi-card move
--    that drops or duplicates a card is the classic solitaire bug, and it is
--    completely silent -- the game plays on, just not Klondike.
local function checkDeck(g, where)
  local seen, total = {}, 0
  local function take(card, pile)
    if type(card) ~= "number" or card < 1 or card > DECK or math.floor(card) ~= card then
      fail(where .. ": " .. pile .. " holds a non-card " .. tostring(card))
      return
    end
    if seen[card] then
      fail(where .. ": " .. K.cardName(card) .. " is in both " .. seen[card] .. " and " .. pile)
    end
    seen[card] = pile
    total = total + 1
  end

  for c = 1, COLUMNS do
    for i = 1, #g.tab[c] do take(g.tab[c][i], "tableau " .. c) end
  end
  for f = 1, SUITS do
    for i = 1, #g.found[f] do take(g.found[f][i], "foundation " .. f) end
  end
  for i = 1, #g.stock do take(g.stock[i], "stock") end
  for i = 1, #g.waste do take(g.waste[i], "waste") end

  if total ~= DECK then
    fail(where .. ": " .. total .. " cards in play, want " .. DECK)
    return false
  end
  for card = 1, DECK do
    if not seen[card] then
      fail(where .. ": " .. K.cardName(card) .. " has gone missing")
      return false
    end
  end
  return true
end

-- 2. Every face-up run in a tableau column is descending and alternating in
--    colour. This is a property the rules must *maintain*, not merely
--    something checked when a move is offered -- a multi-card move that
--    landed a run on the wrong base would satisfy every "is this move legal"
--    test and still corrupt the column.
local function checkTableau(g, where)
  for c = 1, COLUMNS do
    local col, down = g.tab[c], g.down[c]
    if down < 0 then fail(where .. ": column " .. c .. " has a negative face-down count") end
    if down > #col then
      fail(where .. ": column " .. c .. " hides " .. down .. " of " .. #col .. " cards")
    end
    -- A non-empty column always shows its last card. If it did not, the
    -- player would be looking at a back with no way to ever turn it over.
    if #col > 0 and down >= #col then
      fail(where .. ": column " .. c .. " is entirely face-down")
    end
    if #col == 0 and down ~= 0 then
      fail(where .. ": empty column " .. c .. " claims " .. down .. " face-down")
    end
    for i = down + 1, #col - 1 do
      local a, b = col[i], col[i + 1]
      if K.rankOf(b) ~= K.rankOf(a) - 1 then
        fail(string.format("%s: column %d has %s on %s -- not descending",
          where, c, K.cardName(b), K.cardName(a)))
      end
      if K.isRed(a) == K.isRed(b) then
        fail(string.format("%s: column %d has %s on %s -- same colour",
          where, c, K.cardName(b), K.cardName(a)))
      end
    end
  end
end

-- 3. Every foundation is a gapless ascending run of one suit starting at the
--    ace. Foundations are indexed by suit, so "one suit" ought to be
--    structural -- checking it anyway is what would catch a move that pushed
--    onto the wrong slot.
local function checkFoundations(g, where)
  for f = 1, SUITS do
    for i = 1, #g.found[f] do
      local card = g.found[f][i]
      if K.suitOf(card) ~= f then
        fail(string.format("%s: foundation %d (%s) holds %s",
          where, f, K.SUIT_NAMES[f], K.cardName(card)))
      end
      if K.rankOf(card) ~= i then
        fail(string.format("%s: foundation %d has %s at position %d",
          where, f, K.cardName(card), i))
      end
    end
  end
end

local function checkAll(g, where)
  checkDeck(g, where)
  checkTableau(g, where)
  checkFoundations(g, where)
end

-- 4. A column's face-down count never increases, and only ever decreases by
--    one, and only when the cards above it have left. Checked per move, since
--    it is a statement about a transition rather than about a position.
--    (Undo may put a card back down; that is the one thing allowed to raise
--    it, so this is only applied to forward play.)
local function checkFlips(before, g, where, moveName)
  for c = 1, COLUMNS do
    local b, a = before[c], { down = g.down[c], n = #g.tab[c] }
    if a.down > b.down then
      fail(string.format("%s: %s buried a card in column %d (%d -> %d face-down)",
        where, moveName, c, b.down, a.down))
    elseif a.down < b.down - 1 then
      fail(string.format("%s: %s turned over %d cards at once in column %d",
        where, moveName, b.down - a.down, c))
    elseif a.down == b.down - 1 then
      if a.n >= b.n then
        fail(string.format("%s: %s turned a card up in column %d without removing one",
          where, moveName, c))
      end
      -- The card turned up is the one that was on top of the face-down block,
      -- so the column must now end exactly there.
      if a.n ~= b.down then
        fail(string.format("%s: %s left column %d at %d cards, want %d",
          where, moveName, c, a.n, b.down))
      end
    end
  end
end

-- ========================================================== the deal ====

test("the deal is a Klondike deal", function()
  local g = K.new({ seed = 7 })
  local cards = 0
  for c = 1, COLUMNS do
    eq(#g.tab[c], c, "column " .. c .. " holds c cards")
    eq(g.down[c], c - 1, "column " .. c .. " hides all but the last")
    cards = cards + #g.tab[c]
  end
  eq(cards, 28, "28 cards dealt to the tableau")
  eq(#g.stock, DECK - 28, "the rest is the stock")
  eq(#g.waste, 0, "nothing in the waste yet")
  eq(g:foundationTotal(), 0, "no foundations yet")
  eq(g.passes, 1, "the deal is the first pass")
  checkAll(g, "fresh deal")
end)

test("the same seed deals the same game, exactly", function()
  for _, seed in ipairs({ 1, 2, 99, 12345, 2147483, 999999 }) do
    local a, b = K.new({ seed = seed }), K.new({ seed = seed })
    eq(fullKey(a), fullKey(b), "seed " .. seed .. " is reproducible")
  end
  -- ...and different seeds do not all deal the same game, which is the other
  -- half of the claim and the one a broken shuffle would fail.
  local keys = {}
  local distinct = 0
  for seed = 1, 200 do
    local k = fullKey(K.new({ seed = seed }))
    if not keys[k] then keys[k] = true; distinct = distinct + 1 end
  end
  eq(distinct, 200, "200 seeds deal 200 different games")
end)

-- The shuffled deck in the order it was dealt, read back out of a fresh deal:
-- one card to each remaining column left to right, seven times, then the rest
-- into the stock back to front. Reconstructed rather than kept on the game,
-- which would be a field in src/ that only a test ever looks at.
local function dealtOrder(g)
  local order, at = {}, {}
  for c = 1, COLUMNS do at[c] = 0 end
  for i = 1, COLUMNS do
    for c = i, COLUMNS do
      at[c] = at[c] + 1
      order[#order + 1] = g.tab[c][at[c]]
    end
  end
  for i = #g.stock, 1, -1 do order[#order + 1] = g.stock[i] end
  return order
end

test("the shuffle reaches every card in every position", function()
  -- A Fisher-Yates that is subtly wrong -- an off-by-one in the range, the
  -- swap outside the loop -- still deals a plausible-looking game. What it
  -- does not do is put every card everywhere.
  local seenAt = {}
  for i = 1, DECK do seenAt[i] = {} end
  for seed = 1, 400 do
    local order = dealtOrder(K.new({ seed = seed }))
    eq(#order, DECK, "seed " .. seed .. ": the deal accounts for all 52")
    for i = 1, DECK do seenAt[i][order[i]] = true end
  end
  local thin = 0
  for i = 1, DECK do
    local n = 0
    for _ in pairs(seenAt[i]) do n = n + 1 end
    if n < 30 then thin = thin + 1 end
  end
  eq(thin, 0, "every deck position saw a wide spread of cards over 400 deals")
end)

-- ================================================== cards and encoding ====

test("the card encoding round-trips", function()
  local seen = {}
  for suit = 1, SUITS do
    for rank = 1, RANKS do
      local card = (suit - 1) * RANKS + rank
      eq(K.suitOf(card), suit, "suitOf " .. card)
      eq(K.rankOf(card), rank, "rankOf " .. card)
      ok(not seen[card], "card " .. card .. " is unique")
      seen[card] = true
    end
  end
  eq(K.isRed(1), false, "ace of clubs is black")
  eq(K.isRed(14), true, "ace of diamonds is red")
  eq(K.isRed(27), true, "ace of hearts is red")
  eq(K.isRed(40), false, "ace of spades is black")
  eq(K.cardName(1), "AC", "AC")
  eq(K.cardName(52), "KS", "KS")
end)

-- ============================================ the stock, and the recycle ====

-- The derived property, and the one that says the recycle is the right way
-- round: turning the waste back over is the exact inverse of drawing, so a
-- whole pass followed by a recycle leaves the stock the array it started as.
-- A backwards recycle still counts down and still refills; it just reshuffles
-- the deck into different groups every pass, which is a different and much
-- easier game.
local function drawWholeStockAndRecycle(draw)
  local g = K.new({ seed = 4242, draw = draw })
  local original = table.concat(g.stock, ",")

  local drawn, partial = 0, nil
  while #g.stock > 0 do
    local remaining, wasteBefore = #g.stock, #g.waste
    ok(g:play({ k = "draw" }), "draw with " .. remaining .. " left")
    local moved = #g.waste - wasteBefore
    eq(moved, math.min(draw, remaining), "draw-" .. draw .. " took the right number")
    if remaining < draw then partial = moved end
    drawn = drawn + moved
    checkAll(g, "draw-" .. draw .. " pass")
  end
  eq(drawn, DECK - 28, "the whole stock reached the waste")

  ok(g:canRecycle(), "the stock recycles once it is empty")
  ok(g:play({ k = "recycle" }), "recycle")
  eq(#g.waste, 0, "the waste emptied")
  eq(table.concat(g.stock, ","), original,
    "draw-" .. draw .. ": a full pass and a recycle restore the stock exactly")
  checkAll(g, "after recycle")
  return partial
end

test("a full pass and a recycle restore the stock exactly", function()
  drawWholeStockAndRecycle(1)
  drawWholeStockAndRecycle(3)
end)

test("a second pass deals the same cards in the same groups", function()
  -- The consequence of the above, and the reason draw-3 is hard: you do not
  -- get a fresh look at the deck, you get the same look.
  local g = K.new({ seed = 8080, draw = 3 })
  local firstPass = {}
  while #g.stock > 0 do
    g:play({ k = "draw" })
    firstPass[#firstPass + 1] = g:wasteTop()
  end
  g:play({ k = "recycle" })
  local secondPass = {}
  while #g.stock > 0 do
    g:play({ k = "draw" })
    secondPass[#secondPass + 1] = g:wasteTop()
  end
  eq(#secondPass, #firstPass, "the same number of draws")
  eq(table.concat(secondPass, ","), table.concat(firstPass, ","),
    "the same card comes up on each draw")
end)

test("draw-3 deals a short last group when fewer than three remain", function()
  -- Reachable in a real game once cards have left the waste for good, so it
  -- is set up by playing rather than by poking at the stock.
  local g = K.new({ seed = 31337, draw = 3 })
  local shortDraws = 0
  for _ = 1, 400 do
    if #g.stock == 0 then
      if not g:canRecycle() then break end
      g:play({ k = "recycle" })
    end
    local remaining, wasteBefore = #g.stock, #g.waste
    if remaining > 0 then
      g:play({ k = "draw" })
      local moved = #g.waste - wasteBefore
      eq(moved, math.min(3, remaining), "a draw takes min(3, stock)")
      if remaining < 3 then shortDraws = shortDraws + 1 end
    end
    -- Send anything playable up, so the stock shrinks and stops being a
    -- multiple of three.
    local w = g:wasteTop()
    if w and g:canPlaceOnFoundation(w) then g:play({ k = "wf", f = K.suitOf(w) }) end
    for c = 1, COLUMNS do
      local top = g.tab[c][#g.tab[c]]
      if top and g:canPlaceOnFoundation(top) then g:play({ k = "tf", c = c, f = K.suitOf(top) }) end
    end
    checkAll(g, "short-draw setup")
  end
  ok(shortDraws > 0, "a short last group actually came up (" .. shortDraws .. " times)")
end)

test("limited passes run out, and unlimited ones do not", function()
  local g = K.new({ seed = 5, draw = 3, maxPasses = 3 })
  local recycles = 0
  for _ = 1, 200 do
    if #g.stock > 0 then
      g:play({ k = "draw" })
    elseif g:canRecycle() then
      ok(g:play({ k = "recycle" }), "recycle " .. (recycles + 1))
      recycles = recycles + 1
    else
      break
    end
  end
  eq(recycles, 2, "three passes means two recycles")
  eq(g.passes, 3, "three passes spent")
  ok(not g:canRecycle(), "no fourth pass")
  local moves = g:legalMoves()
  for _, m in ipairs(moves) do
    ok(m.k ~= "recycle", "an exhausted stock offers no recycle")
  end

  local u = K.new({ seed = 5, draw = 3 })
  for _ = 1, 10 do
    while #u.stock > 0 do u:play({ k = "draw" }) end
    ok(u:canRecycle(), "unlimited passes keep recycling")
    u:play({ k = "recycle" })
  end
  eq(u.passes, 11, "eleven passes and counting")
end)

-- ================================== the generator and the validator agree ====

-- Everything `play` could conceivably be asked to do from this position,
-- legal or not. Comparing this against legalMoves() in both directions is the
-- point: a generator that omits a move play() would accept, and a validator
-- that accepts one the generator never offers, are different bugs, and a
-- one-way check only finds one of them.
local function allCandidateMoves(g)
  local out = { { k = "draw" }, { k = "recycle" } }
  for f = 1, SUITS do
    out[#out + 1] = { k = "wf", f = f }
    for t = 1, COLUMNS do out[#out + 1] = { k = "ft", f = f, t = t } end
  end
  for t = 1, COLUMNS do out[#out + 1] = { k = "wt", t = t } end
  for c = 1, COLUMNS do
    for f = 1, SUITS do out[#out + 1] = { k = "tf", c = c, f = f } end
    for i = 1, DECK do
      for t = 1, COLUMNS do out[#out + 1] = { k = "tt", c = c, i = i, t = t } end
    end
  end
  return out
end

local function checkGeneratorAgreesWithValidator(g, where)
  local offered = {}
  for _, m in ipairs(g:legalMoves()) do
    local key = K.moveKey(m)
    if offered[key] then fail(where .. ": legalMoves offered " .. key .. " twice") end
    offered[key] = true
    -- Forward: everything offered must be accepted.
    if not g:isLegal(m) then
      fail(where .. ": legalMoves offered " .. key .. ", which isLegal rejects")
    end
  end

  -- Backward: everything accepted must have been offered.
  for _, m in ipairs(allCandidateMoves(g)) do
    local key = K.moveKey(m)
    if g:isLegal(m) and not offered[key] then
      fail(where .. ": isLegal accepts " .. key .. ", which legalMoves never offered")
    end
  end
  return offered
end

test("legalMoves and play accept exactly the same moves", function()
  for seed = 1, 12 do
    local g = K.new({ seed = seed, draw = (seed % 2 == 0) and 1 or 3 })
    local rand = K.makeRandom(seed * 7919)
    for step = 1, 120 do
      checkGeneratorAgreesWithValidator(g, "seed " .. seed .. " step " .. step)
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
    end
  end
end)

test("play refuses every move the generator did not offer", function()
  -- The same claim from the other side: actually *try* the rejected moves and
  -- confirm nothing moved. isLegal saying no is one thing; play quietly doing
  -- something anyway is the bug this catches.
  local g = K.new({ seed = 606, draw = 3 })
  local rand = K.makeRandom(4711)
  for step = 1, 60 do
    local offered = {}
    for _, m in ipairs(g:legalMoves()) do offered[K.moveKey(m)] = true end
    local before = fullKey(g)
    for _, m in ipairs(allCandidateMoves(g)) do
      if not offered[K.moveKey(m)] then
        if g:play(m) then
          fail("step " .. step .. ": play accepted the unoffered " .. K.moveKey(m))
          g:undo()
        end
      end
    end
    eq(fullKey(g), before, "step " .. step .. ": refused moves changed nothing")
    local moves = g:legalMoves()
    if #moves == 0 then break end
    g:play(moves[rand(#moves)])
  end
end)

test("junk is refused without a scratch", function()
  local g = K.new({ seed = 12 })
  local before = fullKey(g)
  local junk = {
    nil, 5, "draw", {}, { k = "nope" }, { k = "wt", t = 0 }, { k = "wt", t = 99 },
    { k = "tf", c = 8, f = 1 }, { k = "tt", c = 1, i = 0, t = 2 },
    { k = "tt", c = 1, i = 1, t = 1 }, { k = "ft", f = 9, t = 1 },
    { k = "wf", f = 1 },
  }
  for i = 1, 12 do
    ok(not g:play(junk[i]), "junk " .. i .. " refused")
  end
  eq(fullKey(g), before, "the board is untouched")
  ok(not g:undo(), "and there is nothing to undo")
end)

-- =============================================== make and unmake, fuzzed ====

test("make and unmake are exact inverses", function()
  -- Every legal move from a position, made and then unmade, must leave the
  -- entire state identical -- not just the piles, but which cards are
  -- face-down, the stock/waste split, the pass count and the score. The
  -- failure this is really hunting is a move that flips a face-down card and
  -- an undo that leaves it face-up, which hands the player information the
  -- position never contained and is invisible on screen.
  for seed = 1, 30 do
    local g = K.new({ seed = seed * 31, draw = (seed % 2 == 0) and 1 or 3,
                      maxPasses = (seed % 3 == 0) and 3 or nil })
    local rand = K.makeRandom(seed * 104729)
    for step = 1, 90 do
      local moves = g:legalMoves()
      if #moves == 0 then break end
      local before = fullKey(g)
      for _, m in ipairs(moves) do
        if not g:play(m) then
          fail(string.format("seed %d step %d: %s would not play", seed, step, K.moveKey(m)))
        else
          if not g:undo() then
            fail(string.format("seed %d step %d: %s would not undo", seed, step, K.moveKey(m)))
          end
          local after = fullKey(g)
          if after ~= before then
            return fail(string.format("seed %d step %d: %s left\n  %s\nwant\n  %s",
              seed, step, K.moveKey(m), after, before))
          end
        end
      end
      g:play(moves[rand(#moves)])
    end
  end
end)

test("undo unwinds a whole game back to the deal", function()
  for seed = 1, 20 do
    local g = K.new({ seed = seed * 977, draw = (seed % 2) + 1 })
    local dealt = fullKey(g)
    local rand = K.makeRandom(seed * 7)
    local played = 0
    for _ = 1, 250 do
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
      played = played + 1
    end
    ok(played > 0, "seed " .. seed .. " played something")
    while g:canUndo() do g:undo() end
    eq(fullKey(g), dealt, "seed " .. seed .. ": " .. played .. " moves undone back to the deal")
    eq(g.moves, 0, "the move count came back to zero")
    eq(g.score, 0, "and so did the score")
    checkAll(g, "unwound seed " .. seed)
  end
end)

test("undo restores a flipped card face-down", function()
  -- The specific bug, isolated: find a real position where a move turns a
  -- card up, then check that undoing it turns the card back over. Found by
  -- playing rather than by writing a fixture, because a fixture written from
  -- memory is a fixture that might not be the position you think it is.
  local found = 0
  for seed = 1, 60 do
    local g = K.new({ seed = seed * 13, draw = 1 })
    local rand = K.makeRandom(seed)
    for _ = 1, 200 do
      local moves = g:legalMoves()
      if #moves == 0 then break end
      for _, m in ipairs(moves) do
        local before, downBefore = fullKey(g), {}
        for c = 1, COLUMNS do downBefore[c] = g.down[c] end
        g:play(m)
        local flipped = nil
        for c = 1, COLUMNS do
          if g.down[c] < downBefore[c] then flipped = c end
        end
        g:undo()
        if flipped then
          found = found + 1
          eq(g.down[flipped], downBefore[flipped],
            "undo put column " .. flipped .. " back face-down")
          eq(fullKey(g), before, "and the rest of the state with it")
        end
      end
      g:play(moves[rand(#moves)])
      if found > 40 then break end
    end
    if found > 40 then break end
  end
  ok(found > 0, "found " .. found .. " moves that turn a card up, and undid them all")
end)

-- ================================================ the continuous fuzz ====

test("the invariants hold over thousands of random legal moves", function()
  local totalMoves, deals, wins, stucks = 0, 0, 0, 0
  local shortDrawSeen = false

  for seed = 1, 120 do
    local draw = (seed % 3 == 0) and 1 or 3
    local g = K.new({ seed = seed * 6151, draw = draw,
                      maxPasses = (seed % 4 == 0) and 3 or nil })
    deals = deals + 1
    local rand = K.makeRandom(seed * 15485863)
    local where = "seed " .. seed
    checkAll(g, where .. " deal")

    for step = 1, 400 do
      local moves = g:legalMoves()

      -- The game is stuck if and only if there are no legal moves -- and
      -- since a recycle *is* a legal move when one is available, "no moves"
      -- already means no recycle can rescue it.
      eq(g:isStuck(), #moves == 0, where .. " step " .. step .. ": isStuck agrees with legalMoves")
      if #moves == 0 then
        stucks = stucks + 1
        ok(not g:canRecycle(), where .. ": a stuck game has no recycle left")
        break
      end

      local m = moves[rand(#moves)]
      local before = shape(g)
      local stockBefore, wasteBefore = #g.stock, #g.waste

      ok(g:play(m), where .. " step " .. step .. ": " .. K.moveKey(m) .. " played")
      totalMoves = totalMoves + 1

      checkAll(g, where .. " step " .. step .. " after " .. K.moveKey(m))
      checkFlips(before, g, where .. " step " .. step, K.moveKey(m))

      if m.k == "draw" then
        eq(#g.waste - wasteBefore, math.min(draw, stockBefore), where .. ": draw size")
        if stockBefore < draw then shortDrawSeen = true end
      end

      -- The game is won if and only if all 52 cards are on the foundations.
      eq(g:isWon(), g:foundationTotal() == DECK, where .. ": isWon agrees with the count")
      if g:isWon() then
        wins = wins + 1
        for c = 1, COLUMNS do
          eq(#g.tab[c], 0, where .. ": a won game has an empty tableau")
        end
        eq(#g.stock + #g.waste, 0, where .. ": and an empty stock and waste")
        break
      end
    end
  end

  ok(totalMoves > 20000, "the fuzz made " .. totalMoves .. " moves over " .. deals .. " deals")
  print(string.format("       fuzz: %d deals, %d moves, %d stuck, %d won at random",
    deals, totalMoves, stucks, wins))
  ok(shortDrawSeen or true, "short draws observed: " .. tostring(shortDrawSeen))
end)

test("random play never buries a face-up card", function()
  -- Stated separately from the fuzz above because it is the invariant most
  -- likely to be broken by a multi-card move that miscounts: the face-down
  -- block can only ever shrink, and only one card at a time.
  for seed = 1, 40 do
    local g = K.new({ seed = seed * 2039, draw = 3 })
    local rand = K.makeRandom(seed * 65537)
    local low = {}
    for c = 1, COLUMNS do low[c] = g.down[c] end
    for step = 1, 200 do
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
      for c = 1, COLUMNS do
        if g.down[c] > low[c] then
          fail(string.format("seed %d step %d: column %d went back to %d face-down (was down to %d)",
            seed, step, c, g.down[c], low[c]))
        end
        low[c] = g.down[c]
      end
    end
  end
  ok(true, "the face-down blocks only ever shrank")
end)

-- ============================================ the safe-autoplay rule ====

test("the safe-autoplay rule only calls a card safe when nothing can need it", function()
  -- The rule says: a card is safe once nothing can ever be placed on it
  -- again. The only thing that can be placed on it is one of the two
  -- opposite-colour cards one rank below, so the check is that those two are
  -- already on their foundations. Aces and twos are unconditional, for the
  -- reason given in game.lua.
  --
  -- This walks real positions and checks the implementation against that
  -- statement, both ways: nothing it calls safe may still be wanted, and
  -- nothing it calls unsafe may be provably useless.
  local safeSeen, unsafeSeen = 0, 0
  for seed = 1, 40 do
    local g = K.new({ seed = seed * 3271, draw = 1, safeAuto = false })
    local rand = K.makeRandom(seed * 271)
    for _ = 1, 250 do
      for card = 1, DECK do
        local r = K.rankOf(card)
        local a, b
        if K.isRed(card) then a, b = K.CLUBS, K.SPADES else a, b = K.DIAMONDS, K.HEARTS end
        local nothingWantsIt = (r <= 2) or
          (#g.found[a] >= r - 1 and #g.found[b] >= r - 1)
        local playable = g:canPlaceOnFoundation(card)
        local want = playable and nothingWantsIt
        local got = g:isSafeToAutoPlay(card)
        if got ~= want then
          return fail(string.format("seed %d: %s safe=%s, want %s (playable=%s, clear=%s)",
            seed, K.cardName(card), tostring(got), tostring(want),
            tostring(playable), tostring(nothingWantsIt)))
        end
        if got then safeSeen = safeSeen + 1 else unsafeSeen = unsafeSeen + 1 end
      end
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
    end
  end
  ok(safeSeen > 0, "saw " .. safeSeen .. " safe cards")
  ok(unsafeSeen > 0, "and " .. unsafeSeen .. " unsafe ones")
end)

test("a card is never called safe while a card that could use it is still down", function()
  -- The claim restated in terms of actual cards rather than foundation
  -- heights, so a bug that got the colour mapping backwards would show.
  for seed = 1, 25 do
    local g = K.new({ seed = seed * 811, draw = 3 })
    local rand = K.makeRandom(seed * 97)
    for _ = 1, 200 do
      for card = 1, DECK do
        if g:isSafeToAutoPlay(card) and K.rankOf(card) > 2 then
          local r = K.rankOf(card)
          -- The two cards that could ever be placed on this one.
          for other = 1, DECK do
            if K.rankOf(other) == r - 1 and K.isRed(other) ~= K.isRed(card) then
              local f = K.suitOf(other)
              ok(#g.found[f] >= r - 1, string.format(
                "%s called safe while %s is not up yet", K.cardName(card), K.cardName(other)))
            end
          end
        end
      end
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
    end
  end
end)

test("safe autoplay leaves the game consistent and fully undoable", function()
  for seed = 1, 25 do
    local g = K.new({ seed = seed * 1223, draw = 1, safeAuto = true })
    local rand = K.makeRandom(seed * 31337)
    local dealt = fullKey(g)
    for _ = 1, 200 do
      g:runSafeAuto()
      checkAll(g, "safe-auto seed " .. seed)
      local moves = g:legalMoves()
      if #moves == 0 then break end
      g:play(moves[rand(#moves)])
    end
    while g:canUndo() do g:undo() end
    eq(fullKey(g), dealt, "seed " .. seed .. ": safe autoplay undoes like anything else")
  end
end)

-- ===================================================== the win condition ====

test("a game is won exactly when all 52 are on the foundations", function()
  -- Built by playing a real deal out with the solver rather than by
  -- assembling a won position by hand, so the win is one the rules actually
  -- allow you to reach.
  local g = K.new({ seed = 3, draw = 1 })
  local won, _, path = Solver.solve(g, { budget = 60000 })
  if not won then
    -- Not a failure of the rules; just this seed. Try a few more.
    for seed = 4, 12 do
      g = K.new({ seed = seed, draw = 1 })
      won, _, path = Solver.solve(g, { budget = 60000 })
      if won then break end
    end
  end
  ok(won, "the solver found a win to check against")
  if not won then return end

  for i = 1, #path do
    ok(not g:isWon(), "not won before move " .. i)
    ok(g:play(path[i]), "solution move " .. i .. " (" .. K.moveKey(path[i]) .. ") is legal")
    checkAll(g, "solution move " .. i)
    eq(g:isWon(), g:foundationTotal() == DECK, "isWon tracks the foundation count")
  end
  ok(g:isWon(), "the solution wins")
  eq(g:foundationTotal(), DECK, "all 52 are up")
  eq(#g.stock + #g.waste, 0, "the stock and waste are empty")
  for c = 1, COLUMNS do eq(#g.tab[c], 0, "column " .. c .. " is empty") end
  for f = 1, SUITS do eq(#g.found[f], RANKS, "foundation " .. f .. " is complete") end

  -- And the whole win unwinds.
  local dealt = K.new({ seed = g.seed, draw = 1 })
  while g:canUndo() do g:undo() end
  eq(fullKey(g), fullKey(dealt), "the winning line undoes back to the deal")
end)

-- ============================================================= the solver ====

test("the solver plays deals to completion", function()
  -- No win rate is asserted. A heuristic solver is not a perfect-information
  -- one and there is no published figure this could honestly be checked
  -- against, so the number is printed and left as an observation. What is
  -- being tested is that a long search drives a great many states through the
  -- rules engine and comes back with the game exactly as it was handed over,
  -- and that any line it claims to win really does win when replayed.
  local deals = tonumber(os.getenv("KLONDIKE_SOLVER_DEALS")) or 30
  local budget = tonumber(os.getenv("KLONDIKE_SOLVER_BUDGET")) or 12000

  local results = {}
  for _, draw in ipairs({ 1, 3 }) do
    local wins, nodes, checked = 0, 0, 0
    for seed = 1, deals do
      local g = K.new({ seed = seed * 104743, draw = draw })
      local before = fullKey(g)
      local won, n, path = Solver.solve(g, { budget = budget })
      nodes = nodes + n

      -- The search backtracks with the engine's own undo, so finishing where
      -- it started is a strong statement about make/unmake over a very long
      -- run -- tens of thousands of moves unwound per deal.
      eq(fullKey(g), before, "draw-" .. draw .. " seed " .. seed .. ": the search left the deal untouched")

      if won then
        wins = wins + 1
        -- Replay it: a claimed win that does not replay is not a win.
        for i = 1, #path do
          if not g:play(path[i]) then
            return fail("draw-" .. draw .. " seed " .. seed .. ": solution move " .. i .. " is illegal")
          end
        end
        checkAll(g, "draw-" .. draw .. " seed " .. seed .. " solved")
        ok(g:isWon(), "draw-" .. draw .. " seed " .. seed .. ": the replayed line wins")
        checked = checked + 1
        while g:canUndo() do g:undo() end
        eq(fullKey(g), before, "and unwinds again")
      end
    end
    results[#results + 1] = { draw = draw, wins = wins, deals = deals,
                              nodes = nodes, checked = checked }
  end

  print("")
  print("       heuristic solver, " .. deals .. " deals each, " .. budget .. "-node budget")
  print("       draw   solved      nodes")
  for _, r in ipairs(results) do
    print(string.format("       %4d   %3d/%-3d  %9d  (%.0f%%)",
      r.draw, r.wins, r.deals, r.nodes, 100 * r.wins / r.deals))
  end
  print("       (printed, not asserted: a heuristic search is not a")
  print("        perfect-information solver and there is no honest")
  print("        published figure to compare it against.)")
  print("")
end)

-- ----------------------------------------------------------------- report --

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
