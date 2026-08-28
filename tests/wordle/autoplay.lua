-- Plays Wordle through the mock runtime so tools/screenshot.lua can capture
-- representative frames: an empty board, a game part-way through with mixed
-- colours and a keyboard that has learned something, a win, and a loss.
--
-- Every guess is chosen from what the *painted frame* says, via
-- tests/wordle/frame.lua, so nothing here reaches into the game's state and no
-- test-only hook has to exist in src/. The dictionary is loaded separately
-- because a player needs to know the words too -- that is the same list the
-- shipped script carries, not a peek at the answer.

package.path = "src/wordle/?.lua;" .. package.path
local Wordle = require("game")
local Frame = require("wordle.frame")

local CODE = { B = Wordle.GREY, Y = Wordle.YELLOW, G = Wordle.GREEN }

local ANSWERS = {}
for i = 1, Wordle.answerCount() do ANSWERS[i] = Wordle.answerAt(i) end

local function marksOf(text)
  local out = {}
  for i = 1, #text do out[i] = CODE[text:sub(i, i)] end
  return out
end

local function consistent(candidate, word, marks)
  local got = Wordle.score(word, candidate)
  for i = 1, Wordle.LEN do
    if got[i] ~= marks[i] then return false end
  end
  return true
end

-- Narrows the answer pool using only what the screen has shown.
local function candidates(f)
  local pool = ANSWERS
  for _, g in ipairs(Frame.guesses(f)) do
    local marks, kept = marksOf(g.marks), {}
    for i = 1, #pool do
      if consistent(pool[i], g.word, marks) then kept[#kept + 1] = pool[i] end
    end
    pool = kept
  end
  return pool
end

local function isOver(f)
  for _, line in ipairs(f.text) do
    if line:match("plays again") then return true end
  end
  return false
end

-- A guess that cannot possibly be the answer, so a run of six of them is a
-- guaranteed loss rather than a hopeful one.
local function wrongGuess(f, nth)
  local pool, live = candidates(f), {}
  for _, w in ipairs(pool) do live[w] = true end
  -- `nth` walks the starting point along, so the six rows of the losing game
  -- are six different words. Picking the first non-candidate every time is
  -- just as valid a loss and makes a screenshot of the same word six times.
  local n = Wordle.guessCount()
  for i = 1, n do
    local w = Wordle.guessAt(((nth * 3571 + i * 907) % n) + 1)
    if not live[w] then return w end
  end
  return "zzzzz"
end

return function(hs, capture)
  -- 1. The title screen, over an empty board.
  capture("title", select(2, hs:paint()))

  -- 2 and 3. A game in progress: three real guesses in, so the grid has mixed
  -- colours and the keyboard has learned a dozen letters.
  hs.on.enterKey()
  local f = Frame.frame(hs)
  local guesses = 0
  while not isOver(f) do
    local pool = candidates(f)
    local pick = pool[1] or "slate"
    if guesses == 0 then pick = "slate" end
    f = Frame.play(hs, pick)
    guesses = guesses + 1
    if guesses == 3 and not isOver(f) then
      capture("playing", select(2, hs:paint()))
    end
    if guesses >= Wordle.ROWS then break end
  end
  if guesses < 3 then capture("playing", select(2, hs:paint())) end
  capture("win", select(2, hs:paint()))

  -- 4. A loss, with the answer revealed and the share grid filled in. Every
  -- guess is drawn from outside the surviving candidates, so this cannot
  -- accidentally win and capture the wrong frame.
  hs.on.enterKey()
  f = Frame.frame(hs)
  for i = 1, Wordle.ROWS do
    if isOver(f) then break end
    f = Frame.play(hs, wrongGuess(f, i))
  end
  capture("loss", select(2, hs:paint()))

  -- 5. Hard mode, refusing a guess that throws a hint away. H toggles it from
  -- the title screen, so this starts from a fresh one.
  hs.on.enterKey()
  hs.on.charIn("h")
  capture("hardmode", select(2, hs:paint()))
end
