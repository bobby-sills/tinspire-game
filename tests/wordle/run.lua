-- Tests for the pure game logic. Run with:  make GAME=wordle test
--
-- The scoring rule is this game's equivalent of chess's perft: the loop is
-- trivial and the colouring of repeated letters is where implementations go
-- wrong. So it is pinned by properties over a fuzz of thousands of real word
-- pairs, not by a handful of examples someone thought of, and the worked
-- examples below exist as regression anchors with their derivations attached.

package.path = (os.getenv("GAME_SRC") or "src/wordle") .. "/?.lua;" .. package.path
local Wordle = require("game")

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

local LEN, ROWS = Wordle.LEN, Wordle.ROWS
local GREY, YELLOW, GREEN = Wordle.GREY, Wordle.YELLOW, Wordle.GREEN

-- Marks as a readable string: B(lack) Y(ellow) G(reen). Every expectation in
-- this file is written in this alphabet so a failure prints something a person
-- can compare at a glance.
local LETTER = { [GREY] = "B", [YELLOW] = "Y", [GREEN] = "G" }

local function pat(guess, answer)
  local marks = Wordle.score(guess, answer)
  local out = {}
  for i = 1, LEN do out[i] = LETTER[marks[i]] or "?" end
  return table.concat(out)
end

-- Deterministic RNG so a failure can be reproduced. Same generator the other
-- games' tests use.
local function seededRand(seed)
  local s = seed or 12345
  return function(n)
    s = (1103515245 * s + 12345) % 2147483648
    return (s % n) + 1
  end
end

local function counts(word)
  local c = {}
  for i = 1, #word do
    local ch = word:sub(i, i)
    c[ch] = (c[ch] or 0) + 1
  end
  return c
end

-- Every word in the guess list, as an array. Built once; several tests fuzz
-- over it and rebuilding it each time is the slowest thing in the file.
local ALL_GUESSES = {}
for i = 1, Wordle.guessCount() do ALL_GUESSES[i] = Wordle.guessAt(i) end
local ALL_ANSWERS = {}
for i = 1, Wordle.answerCount() do ALL_ANSWERS[i] = Wordle.answerAt(i) end

-- ------------------------------------------------------------ dictionary --

test("dictionary is well formed", function()
  ok(Wordle.answerCount() > 0, "there are answers")
  ok(Wordle.guessCount() >= Wordle.answerCount(), "guesses is the larger list")

  -- The stride assumption: `[[` swallows the newline right after it, so word 1
  -- has to start at byte 1. If that ever changed, every word would shift by one
  -- byte and the whole dictionary would quietly become garbage.
  local bad = 0
  for i = 1, Wordle.guessCount() do
    local w = ALL_GUESSES[i]
    if not w:match("^[a-z]" .. string.rep("[a-z]", LEN - 1) .. "$") then
      if bad == 0 then fail("guess " .. i .. " is not five lowercase letters: " .. w) end
      bad = bad + 1
    end
  end
  eq(bad, 0, "every guess is five lowercase letters")

  bad = 0
  for i = 1, Wordle.answerCount() do
    if not ALL_ANSWERS[i]:match("^[a-z][a-z][a-z][a-z][a-z]$") then bad = bad + 1 end
  end
  eq(bad, 0, "every answer is five lowercase letters")
end)

test("dictionary is sorted and free of duplicates", function()
  local unsorted, dupes = 0, 0
  for i = 2, #ALL_GUESSES do
    if ALL_GUESSES[i] < ALL_GUESSES[i - 1] then unsorted = unsorted + 1 end
    if ALL_GUESSES[i] == ALL_GUESSES[i - 1] then dupes = dupes + 1 end
  end
  eq(unsorted, 0, "guess list is sorted")
  eq(dupes, 0, "guess list has no duplicates")

  unsorted, dupes = 0, 0
  for i = 2, #ALL_ANSWERS do
    if ALL_ANSWERS[i] < ALL_ANSWERS[i - 1] then unsorted = unsorted + 1 end
    if ALL_ANSWERS[i] == ALL_ANSWERS[i - 1] then dupes = dupes + 1 end
  end
  eq(unsorted, 0, "answer list is sorted")
  eq(dupes, 0, "answer list has no duplicates")
end)

test("binary search finds every word and rejects non-words", function()
  local missed = 0
  for i = 1, #ALL_GUESSES do
    if not Wordle.isAllowed(ALL_GUESSES[i]) then missed = missed + 1 end
  end
  eq(missed, 0, "every word in the list is found by search")

  -- Every answer must be typeable, or the game can pick a word it then refuses.
  local unplayable = 0
  for i = 1, #ALL_ANSWERS do
    if not Wordle.isAllowed(ALL_ANSWERS[i]) then unplayable = unplayable + 1 end
  end
  eq(unplayable, 0, "every answer is also a legal guess")

  -- A sample of things that are not words, including near-misses either side
  -- of a real entry and the empty and over-long cases.
  local rand = seededRand(99)
  local nonwords, rejected = 0, 0
  for _ = 1, 2000 do
    local w = {}
    for i = 1, LEN do w[i] = string.char(96 + rand(26)) end
    w = table.concat(w)
    if not Wordle.isAnswer(w) and not Wordle.isAllowed(w) then
      nonwords = nonwords + 1
      rejected = rejected + 1
    elseif not Wordle.isAllowed(w) then
      nonwords = nonwords + 1
    end
  end
  eq(rejected, nonwords, "random letter strings outside the list are rejected")

  for _, junk in ipairs({ "", "a", "abcd", "abcdef", "ABACK", "ab de", "12345" }) do
    ok(not Wordle.isAllowed(junk), "rejects " .. string.format("%q", junk))
  end
end)

-- ------------------------------------------------------------------- rng --
-- The answer generator is the module's own, because the handheld will not
-- reseed math.random -- see the comment in game.lua. These check the
-- properties the answer draw actually depends on.

test("the generator stays in range", function()
  local N = Wordle.answerCount()
  local r = Wordle.newRandom(20240101)
  local low, high, bad = math.huge, -math.huge, 0
  for _ = 1, 200000 do
    local v = r(N)
    if v < 1 or v > N or v ~= math.floor(v) then bad = bad + 1 end
    if v < low then low = v end
    if v > high then high = v end
  end
  eq(bad, 0, "every draw is a whole number in 1..N")
  eq(low, 1, "the first word can come up")
  eq(high, N, "the last word can come up")
  eq(Wordle.newRandom(7)(1), 1, "a one-element range always gives 1")
end)

test("the generator is deterministic for a seed", function()
  local a, b = Wordle.newRandom(4242), Wordle.newRandom(4242)
  local same = true
  for _ = 1, 1000 do
    if a(2315) ~= b(2315) then same = false end
  end
  ok(same, "two generators on the same seed agree")

  local c = Wordle.newRandom(4243)
  local differs = false
  for _ = 1, 20 do
    if Wordle.newRandom(4242)(2315) ~= c(2315) then differs = true end
  end
  ok(differs, "a different seed gives a different sequence")
end)

test("neighbouring seeds give different words", function()
  -- The property that actually matters on the device: the seed is a count of
  -- timer ticks, so two launches differ by a handful. A raw MINSTD fails this
  -- badly -- from a small seed its first output is tiny, and seeds 1 through
  -- 10 all floor to the same word -- which is why newRandom scrambles and
  -- warms up before handing the closure back.
  local N = Wordle.answerCount()
  local seen, distinct = {}, 0
  for seed = 1, 40 do
    local w = Wordle.answerAt(Wordle.newRandom(seed)(N))
    if not seen[w] then seen[w] = true; distinct = distinct + 1 end
  end
  ok(distinct >= 38, "40 consecutive seeds gave " .. distinct .. " different words")
end)

test("the generator spreads over the whole answer list", function()
  -- Not a randomness proof, just a check that no large part of the list is
  -- unreachable: draw plenty and count how much of the list gets hit.
  local N = Wordle.answerCount()
  local r = Wordle.newRandom(31337)
  local seen, distinct = {}, 0
  for _ = 1, N * 8 do
    local i = r(N)
    if not seen[i] then seen[i] = true; distinct = distinct + 1 end
  end
  -- 8N draws with replacement leave about N*e^-8 words unseen, well under 1%.
  ok(distinct > N * 0.99,
    string.format("%d of %d words reachable", distinct, N))

  -- And that the draws are not piled into one end of the list.
  local halves = { 0, 0 }
  local r2 = Wordle.newRandom(99)
  for _ = 1, 20000 do
    local i = r2(N)
    local h = i <= N / 2 and 1 or 2
    halves[h] = halves[h] + 1
  end
  local ratio = halves[1] / halves[2]
  ok(ratio > 0.9 and ratio < 1.1,
    string.format("both halves come up about equally (%d vs %d)", halves[1], halves[2]))
end)

test("mix folds a value in without leaving the exact-integer range", function()
  local acc = 1
  for i = 1, 5000 do
    acc = Wordle.mix(acc, i)
    if acc ~= math.floor(acc) or acc < 0 or acc >= 2147483647 then
      fail("mix left the range at step " .. i .. ": " .. tostring(acc))
      return
    end
  end
  ok(true, "5000 folds stayed a whole number below 2^31-1")

  -- Different histories have to land somewhere different, or the entropy the
  -- host accumulates is wasted.
  local a, b = 1, 1
  for _, v in ipairs({ 3, 1, 4, 1, 5 }) do a = Wordle.mix(a, v) end
  for _, v in ipairs({ 3, 1, 4, 1, 6 }) do b = Wordle.mix(b, v) end
  ok(a ~= b, "a one-value difference changes the accumulator")
end)

-- --------------------------------------------------------------- scoring --
-- The five properties below characterise the two-pass rule exactly. Together
-- they leave no freedom in the answer, which is why they are worth more than
-- any number of hand-written cases.

-- Draws pairs from the real list rather than from invented strings: the point
-- is to exercise the repeated-letter cases English actually produces.
local function fuzzPairs(n, seed, fn)
  local rand = seededRand(seed)
  for _ = 1, n do
    local guess = ALL_GUESSES[rand(#ALL_GUESSES)]
    local answer = ALL_ANSWERS[rand(#ALL_ANSWERS)]
    fn(guess, answer)
  end
end

test("property: greens + yellows for a letter = min(count in guess, in answer)", function()
  local bad = 0
  fuzzPairs(8000, 1, function(guess, answer)
    local marks = Wordle.score(guess, answer)
    local gc, ac, nongrey = counts(guess), counts(answer), {}
    for i = 1, LEN do
      if marks[i] ~= GREY then
        local ch = guess:sub(i, i)
        nongrey[ch] = (nongrey[ch] or 0) + 1
      end
    end
    for ch in pairs(gc) do
      local want = math.min(gc[ch], ac[ch] or 0)
      if (nongrey[ch] or 0) ~= want then
        if bad == 0 then
          fail(string.format("%s/%s -> %s: letter %s marked %d times, want %d",
            guess, answer, pat(guess, answer), ch, nongrey[ch] or 0, want))
        end
        bad = bad + 1
      end
    end
  end)
  eq(bad, 0, "multiset count holds over 8000 real pairs")
end)

test("property: a position is green if and only if the letters match", function()
  local bad = 0
  fuzzPairs(8000, 2, function(guess, answer)
    local marks = Wordle.score(guess, answer)
    for i = 1, LEN do
      local same = guess:sub(i, i) == answer:sub(i, i)
      if same ~= (marks[i] == GREEN) then bad = bad + 1 end
    end
  end)
  eq(bad, 0, "green is exactly positional equality")
end)

test("property: among positions competing for a letter, the leftmost is yellow", function()
  -- If a later position got a yellow for letter L, every earlier non-green
  -- position holding L must have got one too -- pass 2 runs left to right and
  -- consumes the pool as it goes, so the leftmost claims the scarce copy.
  local bad = 0
  fuzzPairs(8000, 3, function(guess, answer)
    local marks = Wordle.score(guess, answer)
    for j = 2, LEN do
      if marks[j] == YELLOW then
        for i = 1, j - 1 do
          if guess:sub(i, i) == guess:sub(j, j) and marks[i] == GREY then
            if bad == 0 then
              fail(string.format("%s/%s -> %s: position %d yellow but %d grey",
                guess, answer, pat(guess, answer), j, i))
            end
            bad = bad + 1
          end
        end
      end
    end
  end)
  eq(bad, 0, "yellows are assigned left to right")
end)

test("property: a word scored against itself is all green", function()
  local bad = 0
  for i = 1, #ALL_GUESSES do
    local w = ALL_GUESSES[i]
    local marks = Wordle.score(w, w)
    for k = 1, LEN do
      if marks[k] ~= GREEN then bad = bad + 1 end
    end
  end
  eq(bad, 0, "score(w, w) is all green for all " .. #ALL_GUESSES .. " words")
end)

test("property: the multiset of non-grey letters is symmetric", function()
  -- Swapping which word is the answer cannot change how many of each letter
  -- come back non-grey, because min(a, b) does not care about order. The marks
  -- themselves may differ -- green in one direction can be yellow in the other
  -- is impossible, but the *split* between green and yellow can move.
  local bad = 0
  fuzzPairs(8000, 4, function(a, b)
    local function tally(g, ans)
      local marks, t = Wordle.score(g, ans), {}
      for i = 1, LEN do
        if marks[i] ~= GREY then
          local ch = g:sub(i, i)
          t[ch] = (t[ch] or 0) + 1
        end
      end
      return t
    end
    local x, y = tally(a, b), tally(b, a)
    for ch in pairs(x) do
      if (y[ch] or 0) ~= x[ch] then bad = bad + 1 end
    end
    for ch in pairs(y) do
      if (x[ch] or 0) ~= y[ch] then bad = bad + 1 end
    end
  end)
  eq(bad, 0, "non-grey letter counts agree in both directions")
end)

-- ------------------------------------------------------ regression anchors --
-- Each pattern below was derived by hand against the two-pass algorithm before
-- being written down, not recalled. The workings are the comments.

test("SPEED against ABIDE", function()
  -- answer a b i d e / guess s p e e d
  -- Pass 1: no position matches, so the pool is the whole answer {a,b,i,d,e}.
  -- Pass 2: s no, p no, e takes the single e (pool e now 0), the second e
  --         finds none, d takes the d.
  eq(pat("speed", "abide"), "BBYBY", "SPEED/ABIDE")
end)

test("EERIE against THERE", function()
  -- answer t h e r e / guess e e r i e
  -- Pass 1: position 5 is e = e, green; that e leaves the pool, which is
  --         therefore {t,h,e,r} -- one e, not two.
  -- Pass 2: first e takes the remaining e, second e finds none, r takes the r,
  --         i finds none.
  eq(pat("eerie", "there"), "YBYBG", "EERIE/THERE")
end)

test("ANNAL against BANAL", function()
  -- answer b a n a l / guess a n n a l
  -- Pass 1: positions 3, 4, 5 match (n, a, l), so the pool is {b, a}.
  -- Pass 2: the leading a takes the one remaining a; the n at position 2 finds
  --         no n left, because the only other n was claimed green.
  eq(pat("annal", "banal"), "YBGGG", "ANNAL/BANAL")
end)

test("LOLLY against ALLOW", function()
  -- answer a l l o w / guess l o l l y
  -- The case that catches greens claiming ahead of yellows.
  -- Pass 1: position 3 is l = l, green. Pool is {a, l, o, w} -- one l left of
  --         the answer's two.
  -- Pass 2: position 1 l takes it (leftmost wins), position 2 o takes the o,
  --         position 4 l finds nothing, y finds nothing.
  eq(pat("lolly", "allow"), "YYGBB", "LOLLY/ALLOW")
end)

test("a guess with no letters in common is all grey", function()
  -- answer a b i d e / guess m u c k y: nothing shared at all.
  eq(pat("mucky", "abide"), "BBBBB", "MUCKY/ABIDE")
end)

-- ------------------------------------------------------------ game rules --

local function playable(answer, opts)
  opts = opts or {}
  opts.answer = answer
  opts.rand = opts.rand or seededRand(7)
  local g = Wordle.new(opts)
  g:start()
  return g
end

local function typeWord(g, word)
  for i = 1, #word do g:typeLetter(word:sub(i, i)) end
end

test("typing, deleting and submitting", function()
  local g = playable("crane")
  typeWord(g, "sl")
  eq(g.typed, "sl", "letters accumulate")
  g:backspace()
  eq(g.typed, "s", "backspace removes one")
  typeWord(g, "later")
  eq(g.typed, "slate", "stops accepting at five letters")
  ok(g:submit(), "a real word submits")
  eq(#g.rows, 1, "the guess took a row")
  eq(g.typed, "", "the input line cleared")
end)

test("junk from on.charIn is ignored", function()
  local g = playable("crane")
  for _, junk in ipairs({ "", " ", "\n", "1", "!", "ab", "\t" }) do
    ok(not g:typeLetter(junk), "rejects " .. string.format("%q", junk))
  end
  eq(g.typed, "", "nothing was typed")
  ok(g:typeLetter("Q"), "accepts an upper-case letter")
  eq(g.typed, "q", "and folds it to lower case")
end)

-- Serialises everything a guess could possibly touch, so "unchanged" means
-- unchanged rather than "the fields I remembered to check".
local function snapshot(g)
  local parts = { g.state, g.typed, g.answer, tostring(#g.rows) }
  for _, r in ipairs(g.rows) do
    parts[#parts + 1] = r.word .. ":" .. table.concat(r.marks, ",")
  end
  for i = 1, 26 do parts[#parts + 1] = tostring(g.letters[i]) end
  return table.concat(parts, "|")
end

test("a guess outside the word list is rejected and costs nothing", function()
  local g = playable("crane")
  typeWord(g, "slate")
  ok(g:submit(), "a real word is accepted")

  local before = snapshot(g)
  typeWord(g, "zzzzz")
  local okay, reason, msg = g:submit()
  ok(not okay, "a non-word is refused")
  eq(reason, "unknown", "and says why")
  eq(msg, "Not in word list", "with a message for the player")
  eq(#g.rows, 1, "no row was consumed")
  -- typed is deliberately left alone so the player can edit rather than retype.
  eq(g.typed, "zzzzz", "the typed word survives for editing")
  g.typed = ""
  local after = snapshot(g)
  eq(after, before:gsub("|zzzzz|", "||"), "state is otherwise identical")
end)

test("a short guess is rejected and costs nothing", function()
  local g = playable("crane")
  local before = snapshot(g)
  typeWord(g, "sla")
  local okay, reason = g:submit()
  ok(not okay, "three letters is refused")
  eq(reason, "short", "and says why")
  eq(#g.rows, 0, "no row was consumed")
  g.typed = ""
  eq(snapshot(g), before, "state is byte-for-byte what it was")
end)

test("a correct guess wins immediately, even on the last row", function()
  local g = playable("crane")
  for _ = 1, ROWS - 1 do
    typeWord(g, "slate")
    ok(g:submit(), "filler guess accepted")
  end
  eq(g.state, "playing", "still going after five wrong guesses")
  typeWord(g, "crane")
  ok(g:submit(), "the sixth guess submits")
  eq(g.state, "won", "a correct sixth guess wins rather than running out")
  eq(#g.rows, ROWS, "it used the last row")
  ok(g:isOver(), "the game is over")
end)

test("running out of rows loses and the answer is still available", function()
  local g = playable("crane")
  for i = 1, ROWS do
    typeWord(g, "slate")
    ok(g:submit(), "guess " .. i .. " accepted")
  end
  eq(g.state, "lost", "six wrong guesses loses")
  eq(g.answer, "crane", "the answer is there for the host to reveal")
  ok(not g:typeLetter("a"), "typing does nothing once the game is over")
  local okay, reason = g:submit()
  ok(not okay, "submitting does nothing once the game is over")
  eq(reason, "over", "and says why")
end)

test("a won game cannot be played further", function()
  local g = playable("crane")
  typeWord(g, "crane")
  ok(g:submit(), "won")
  eq(g.state, "won", "state is won")
  ok(not g:typeLetter("a"), "no more typing")
  ok(not g:backspace(), "no more deleting")
end)

-- ------------------------------------------------------- keyboard colours --

test("a letter's keyboard colour never gets worse", function()
  -- The keyboard is where the per-letter state lives, and a colour that went
  -- backwards would be worse than no colour at all.
  local rand = seededRand(11)
  local worse = 0
  for _ = 1, 400 do
    local g = playable(ALL_ANSWERS[rand(#ALL_ANSWERS)], { rand = rand })
    local seen = {}
    for i = 1, 26 do seen[i] = 0 end
    while g.state == "playing" do
      local word = ALL_GUESSES[rand(#ALL_GUESSES)]
      typeWord(g, word)
      g:submit()
      for i = 1, 26 do
        local now = g.letters[i]
        if now < seen[i] then worse = worse + 1 end
        seen[i] = now
      end
    end
  end
  eq(worse, 0, "no letter ever moved down the scale over 400 games")
end)

test("the keyboard shows the best mark a letter has earned", function()
  local g = playable("crane")
  typeWord(g, "eerie")  -- e is yellow at 1, grey at 2, green at 5
  g:submit()
  eq(g:letterMark("e"), GREEN, "e is green, not the grey from position 2")
  eq(g:letterMark("r"), YELLOW, "r is yellow")
  eq(g:letterMark("i"), GREY, "i is grey")
  eq(g:letterMark("z"), Wordle.UNKNOWN, "an untried letter is unknown")
  eq(g:letterMark("E"), GREEN, "upper case asks about the same letter")
end)

-- -------------------------------------------------------------- hard mode --

test("hard mode pins a green letter to its square", function()
  local g = playable("crane", { hard = true })
  typeWord(g, "crime")   -- c r _ _ e : c, r, e green
  ok(g:submit(), "opening guess accepted")
  eq(pat("crime", "crane"), "GGBBG", "CRIME/CRANE derivation")

  typeWord(g, "shale")   -- drops the green c and r
  local okay, reason, msg = g:submit()
  ok(not okay, "a guess that abandons a green is refused")
  eq(reason, "hard", "for the hard-mode reason")
  ok(msg and msg:match("^C must be letter 1"), "naming the letter: " .. tostring(msg))
  eq(#g.rows, 1, "and costs no row")

  g.typed = ""
  typeWord(g, "crude")
  ok(g:submit(), "keeping the greens in place is accepted")
end)

test("hard mode requires a yellow letter to reappear", function()
  local g = playable("crane", { hard = true })
  typeWord(g, "tenor")   -- answer c r a n e
  -- t no; e is in crane but not at 2 -> yellow; n is at 4 in crane, guess has
  -- n at 3 -> yellow; o no; r is at 2 in crane, guess has r at 5 -> yellow.
  eq(pat("tenor", "crane"), "BYYBY", "TENOR/CRANE derivation")
  ok(g:submit(), "opening guess accepted")

  typeWord(g, "silly")
  local okay, reason, msg = g:submit()
  ok(not okay, "a guess dropping the yellows is refused")
  eq(reason, "hard", "for the hard-mode reason")
  ok(msg and msg:match("Guess must contain"), "with a message: " .. tostring(msg))

  g.typed = ""
  typeWord(g, "crane")
  ok(g:submit(), "a guess reusing all three is accepted")
  eq(g.state, "won", "and it was the answer")
end)

test("hard mode counts duplicates rather than just presence", function()
  -- A row showing the same letter non-grey twice has proved there are two.
  local g = playable("geese", { hard = true })
  typeWord(g, "sheep")
  -- answer g e e s e / guess s h e e p
  -- Pass 1: position 3 e = e green. Pool {g, e, s} (the answer's other two e's
  --         minus... careful: answer letters not matched are g, e, s, e -> the
  --         pool is {g:1, e:2, s:1}).
  -- Pass 2: s takes the s (yellow), h nothing, position 4 e takes an e
  --         (yellow), p nothing.
  eq(pat("sheep", "geese"), "YBGYB", "SHEEP/GEESE derivation")
  ok(g:submit(), "opening guess accepted")

  -- Two e's have been shown, so one e is not enough. AHEAD is the careful
  -- choice here: it keeps the green e on square 3, so the position rule passes
  -- and the count rule is what actually refuses it. A word that moved the e
  -- would be refused for the other reason and prove nothing. (The first draft
  -- of this test used WEDGE, which has d on square 3 and failed for the wrong
  -- reason -- derive the fixture, do not recall it.)
  typeWord(g, "ahead")
  local okay, _, msg = g:submit()
  ok(not okay, "one e does not satisfy a two-e requirement")
  ok(msg and msg:match("2 EE"), "the message asks for two: " .. tostring(msg))

  g.typed = ""
  -- OBESE: e on square 3, two e's, and the s -- every obligation met, and it
  -- is not the answer, so acceptance is the only thing being tested.
  typeWord(g, "obese")
  local okay2 = g:submit()
  ok(okay2, "a guess with two e's, an s and the green e in place is accepted")
  eq(g.state, "playing", "and it was not itself the answer")
end)

test("hard mode off lets any real word through", function()
  local g = playable("crane", { hard = false })
  typeWord(g, "crime")
  ok(g:submit(), "opening guess")
  typeWord(g, "sushi")
  ok(g:submit(), "a guess ignoring every hint is fine in normal mode")
end)

-- ------------------------------------------------- sliced candidate filter --

test("slicing changes when the filter answers, never what it answers", function()
  -- The whole point of the state machine: a small budget must take more calls
  -- and reach the same number. If that ever stopped holding, the count on
  -- screen would depend on the speed of the calculator.
  local function countWith(budget, answer, guesses)
    local g = playable(answer)
    local steps = 0
    for _, word in ipairs(guesses) do
      typeWord(g, word)
      g:submit()
      g:beginFilter()
      while not g:filterStep(budget) do
        steps = steps + 1
        ok(g:remaining() == nil, "no count is offered mid-pass")
      end
      steps = steps + 1
    end
    return g:remaining(), steps
  end

  local guesses = { "slate", "crony" }
  local whole, fewSteps = countWith(100000, "crane", guesses)
  local sliced, manySteps = countWith(25, "crane", guesses)
  eq(sliced, whole, "a 25-word budget reaches the same count")
  ok(manySteps > fewSteps, "and takes more calls to get there (" ..
    manySteps .. " vs " .. fewSteps .. ")")

  local tiny = countWith(1, "crane", guesses)
  eq(tiny, whole, "a one-word budget reaches the same count")
end)

test("the filter keeps exactly the answers consistent with every guess", function()
  local rand = seededRand(31)
  for _ = 1, 20 do
    local answer = ALL_ANSWERS[rand(#ALL_ANSWERS)]
    local g = playable(answer)
    local played = {}
    for _ = 1, 2 do
      local word = ALL_GUESSES[rand(#ALL_GUESSES)]
      played[#played + 1] = word
      typeWord(g, word)
      g:submit()
      g:beginFilter()
      while not g:filterStep(500) do end
    end

    -- The same question answered the slow, obvious way.
    local want = 0
    for i = 1, #ALL_ANSWERS do
      local cand, fits = ALL_ANSWERS[i], true
      for k, word in ipairs(played) do
        local a, b = Wordle.score(word, cand), g.rows[k].marks
        for j = 1, LEN do
          if a[j] ~= b[j] then fits = false break end
        end
        if not fits then break end
      end
      if fits then want = want + 1 end
    end
    eq(g:remaining(), want, "candidate count for " .. answer)
    ok(want >= 1, "the real answer is always among them")
  end
end)

test("the answer is always one of the surviving candidates", function()
  local rand = seededRand(41)
  local missing = 0
  for _ = 1, 60 do
    local answer = ALL_ANSWERS[rand(#ALL_ANSWERS)]
    local g = playable(answer)
    for _ = 1, 3 do
      typeWord(g, ALL_GUESSES[rand(#ALL_GUESSES)])
      g:submit()
      g:beginFilter()
      while not g:filterStep(400) do end
    end
    local found = false
    for _, w in ipairs(g.possible or {}) do
      if w == answer then found = true break end
    end
    if not found then missing = missing + 1 end
  end
  eq(missing, 0, "the answer survived every filter pass")
end)

-- --------------------------------------------------------------- a solver --
-- Plays every word in the answer list. This is not an assertion about quality
-- -- the numbers are printed, not checked -- but it drives the scoring
-- function over two thousand complete games, which is a far harder workout
-- than any hand-written case, and it is the same routine autoplay needs to
-- type words for the screenshots.

local OPENER = "slate"

local function markKey(marks)
  return marks[1] .. marks[2] .. marks[3] .. marks[4] .. marks[5]
end

-- Buckets the whole answer pool by how the opener scores against it. The
-- opener never changes, so this is computed once and every game reuses it
-- instead of filtering 2,315 candidates 2,315 times over.
local function openerBuckets()
  local buckets = {}
  for i = 1, #ALL_ANSWERS do
    local k = markKey(Wordle.score(OPENER, ALL_ANSWERS[i]))
    local b = buckets[k]
    if not b then b = {}; buckets[k] = b end
    b[#b + 1] = ALL_ANSWERS[i]
  end
  return buckets
end

local function filter(candidates, guess, marks)
  local key, out = markKey(marks), {}
  for i = 1, #candidates do
    if markKey(Wordle.score(guess, candidates[i])) == key then
      out[#out + 1] = candidates[i]
    end
  end
  return out
end

-- Picks the candidate whose worst-case bucket is smallest: the guess that
-- guarantees the most information. Restricted to the candidate set itself, so
-- every guess can also be the winner.
local function bestGuess(candidates)
  if #candidates <= 2 then return candidates[1] end
  local best, bestWorst = candidates[1], math.huge
  local limit = math.min(#candidates, 120) -- keep the whole run under a second
  for i = 1, limit do
    local buckets, worst = {}, 0
    for j = 1, #candidates do
      local k = markKey(Wordle.score(candidates[i], candidates[j]))
      local n = (buckets[k] or 0) + 1
      buckets[k] = n
      if n > worst then worst = n end
    end
    if worst < bestWorst then best, bestWorst = candidates[i], worst end
  end
  return best
end

test("a solver plays the whole answer list", function()
  local buckets = openerBuckets()
  local dist, failures, total = {}, 0, 0
  for i = 1, ROWS do dist[i] = 0 end

  for i = 1, #ALL_ANSWERS do
    local answer = ALL_ANSWERS[i]
    local g = playable(answer)
    local candidates, guess, n = nil, OPENER, 0

    while g.state == "playing" do
      n = n + 1
      typeWord(g, guess)
      local accepted = g:submit()
      if not accepted then
        fail("solver guess " .. guess .. " was rejected for answer " .. answer)
        break
      end
      if g.state == "playing" then
        local marks = g.rows[#g.rows].marks
        if n == 1 then
          candidates = buckets[markKey(marks)] or {}
        else
          candidates = filter(candidates, guess, marks)
        end
        if #candidates == 0 then
          fail("solver eliminated every candidate for " .. answer)
          break
        end
        guess = bestGuess(candidates)
      end
    end

    total = total + 1
    if g.state == "won" then
      dist[n] = dist[n] + 1
    else
      failures = failures + 1
    end
  end

  local sum = 0
  for k = 1, ROWS do sum = sum + k * dist[k] end
  local solved = total - failures

  print(string.format("  solver over %d answers, opening %s:", total, OPENER:upper()))
  for k = 1, ROWS do
    print(string.format("    %d guesses: %5d  %5.1f%%", k, dist[k], dist[k] / total * 100))
  end
  print(string.format("    failed:    %5d  %5.1f%%", failures, failures / total * 100))
  print(string.format("    mean guesses (solved games): %.3f", solved > 0 and sum / solved or 0))

  ok(total == #ALL_ANSWERS, "every answer was played")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
