-- Drives the built Klondike bundle from the outside, for tests/klondike/ui.lua
-- and tests/klondike/autoplay.lua.
--
-- Playing a solitaire game through a UI needs to know what is in the *hidden*
-- half of the board, which no amount of reading the screen can tell you. So
-- this reconstructs the deal instead: tests/nspire_stub.lua pins math.random
-- and neutralises the script's own reseeding, and the game draws its seed
-- through math.random precisely so a test can pin it. Replaying that same
-- sequence here gives the seed the bundle used, and the rules module deals the
-- identical game.
--
-- That is a piece of the host's behaviour being relied on, so it is checked
-- rather than trusted: `attach` compares the reconstructed deal against the
-- cards actually on screen and fails if they have drifted apart. A driver that
-- quietly went on driving the wrong game would make every test downstream of
-- it meaningless.
--
-- Moves are played by clicking, not by walking the cursor with arrow keys.
-- Two clicks is one move whatever the board looks like, which keeps the driver
-- short and exercises on.mouseDown at the same time.

local Frame = require("klondike.frame")

local Drive = {}

local STUB_SEED = 20240101   -- tests/nspire_stub.lua's default

-- The seed the bundle will have drawn: the stub seeds and draws twice, then
-- the script's own reseed draws twice more before taking the value.
function Drive.expectedSeed(stub, stubSeed)
  -- Through the stub's own saved handle: by the time a game's ui.lua runs,
  -- the global math.randomseed has been replaced by the no-op that keeps the
  -- script under test from reseeding itself.
  stub.randomseed(stubSeed or STUB_SEED)
  math.random(); math.random()
  math.random(); math.random()
  return math.random(1, 2147483646)
end

-- Slot geometry, read off a frame rather than copied from main.lua: the seven
-- tableau columns give the left edge and the pitch, and the two rows give the
-- two y positions. Everything the driver clicks is derived from those.
function Drive.layout(f)
  local xs, ys = {}, {}
  for _, c in ipairs(f.cards) do xs[c.x] = true; ys[c.y] = true end
  for _, s in ipairs(f.slots) do xs[s.x] = true; ys[s.y] = true end
  local xl, yl = {}, {}
  for x in pairs(xs) do xl[#xl + 1] = x end
  for y in pairs(ys) do yl[#yl + 1] = y end
  table.sort(xl); table.sort(yl)
  local x0 = xl[1]
  -- The pitch is the smallest gap between distinct slot columns that is at
  -- least a card wide; the draw-3 waste spread sits at a finer offset.
  local pitch = nil
  for i = 2, #xl do
    local d = xl[i] - x0
    if d >= f.art.w and (not pitch or d < pitch) then pitch = d end
  end
  return { x0 = x0, pitch = pitch, topY = yl[1], tabY = yl[#yl >= 2 and 2 or 1] }
end

function Drive.slotX(L, slot) return L.x0 + (slot - 1) * L.pitch end

-- ------------------------------------------------------------------ session --

-- The seeds the script will draw for its first `n` deals, leaving the RNG
-- stream exactly where stub.load had it -- so a caller can look ahead at which
-- deals are coming, pick one, and then let the script deal them for real.
--
-- Each deal costs three draws: the two main.lua throws away after reseeding,
-- because the first values out of a fresh seed are weakly mixed, and the one
-- it keeps.
function Drive.dealSeeds(stub, stubSeed, n)
  stubSeed = stubSeed or STUB_SEED
  stub.randomseed(stubSeed)
  math.random(); math.random()           -- stub.load's own two
  local out = {}
  for i = 1, n do
    math.random(); math.random()
    out[i] = math.random(1, 2147483646)
  end
  stub.randomseed(stubSeed)
  math.random(); math.random()           -- put the stream back
  return out
end

-- Wraps a harness that has already been booted and dealt, for a caller that
-- was handed one -- tools/screenshot.lua does exactly that.
function Drive.session(hs, K, bundle, seed, opts)
  local _, ops = hs:paint()
  local f = Frame.read(ops, bundle)
  local L = Drive.layout(f)

  opts = opts or {}
  local g = K.new({ seed = seed, draw = opts.draw or 3,
                    maxPasses = opts.maxPasses, safeAuto = opts.safeAuto })

  local session = { hs = hs, game = g, layout = L, bundle = bundle,
                    frame = f, seed = seed }
  local wrong = Drive.disagreement(session, f)
  session.verified = (wrong == nil)
  session.mismatch = wrong
  return session
end

-- Boots the bundle, deals, and returns a handle carrying both the harness and
-- a rules-module game that mirrors it. `stubSeed` picks which deal comes out:
-- the stub pins math.random to it on every load, so a test wanting several
-- different games asks for several different values rather than hoping
-- consecutive boots drift apart.
function Drive.attach(stub, K, bundle, w, h, stubSeed)
  -- Before stub.load, which is where math.randomseed stops working: the stub
  -- replaces it with a no-op so the script under test cannot reseed itself out
  -- of a reproducible run, and that applies to this replay too.
  local seed = Drive.expectedSeed(stub, stubSeed)

  local hs = stub.load(bundle, w or 318, h or 212, stubSeed)
  hs:resize(w or 318, h or 212)
  hs.on.enterKey()                       -- deal, with the menu's defaults

  -- Those defaults: three-card draw, unlimited passes, safe cards stay put.
  return Drive.session(hs, K, bundle, seed, { draw = 3 })
end

-- Every card the frame shows, compared against where the shadow game says it
-- should be. Returns nil when they agree, or a description of the first
-- difference.
function Drive.disagreement(s, f)
  local K = s.game
  local L = s.layout
  local piles = {}
  for _, c in ipairs(f.cards) do
    local slot = (c.x - L.x0) / L.pitch
    if slot == math.floor(slot) then
      local row = (c.y < L.tabY) and "top" or "tab"
      piles[row .. ":" .. (slot + 1)] = piles[row .. ":" .. (slot + 1)] or {}
      local p = piles[row .. ":" .. (slot + 1)]
      p[#p + 1] = c
    end
  end

  local SUIT = { "C", "D", "H", "S" }
  local function nameOf(card)
    return K.RANK_NAMES[K.rankOf(card)] .. SUIT[K.suitOf(card)]
  end

  for col = 1, 7 do
    local shown = piles["tab:" .. col] or {}
    table.sort(shown, function(a, b) return a.y < b.y end)
    local n = #K.tab[col]
    local up = n - K.down[col]

    -- Fewer cards may be drawn than the column holds, but never more, and
    -- never fewer than the face-up ones: a squeezed fan can stack the whole
    -- face-down block into one visible back, and nothing else.
    if #shown > n then
      return string.format("column %d shows %d cards, the rules say %d", col, #shown, n)
    end
    if #shown < up then
      return string.format("column %d shows %d cards but %d are face up", col, #shown, up)
    end

    for k = 1, #shown do
      local c = shown[k]
      local i = n - (#shown - k)          -- counted from the bottom
      local want = (i <= K.down[col]) and "back" or nameOf(K.tab[col][i])
      if c.name and c.name ~= want then
        return string.format("column %d card %d is %s on screen, %s in the rules",
          col, i, c.name, want)
      end
    end
  end
  return nil
end

-- ------------------------------------------------------------------- moves --

-- A point inside the pile a move starts from.
local function sourcePoint(s, m)
  local L, g = s.layout, s.game
  if m.k == "draw" or m.k == "recycle" then
    return Drive.slotX(L, 1) + 18, L.topY + 26
  elseif m.k == "wf" or m.k == "wt" then
    -- Anywhere in the waste slot picks the waste, spread or not.
    return Drive.slotX(L, 2) + 18, L.topY + 26
  elseif m.k == "ft" then
    return Drive.slotX(L, 3 + m.f) + 18, L.topY + 26
  elseif m.k == "tf" or m.k == "tt" then
    local i = (m.k == "tf") and #g.tab[m.c] or m.i
    local y = Drive.cardY(s, m.c, i)
    if not y then return nil end
    -- The card's own top row. Anywhere lower can fall inside the *next*
    -- card's box once the fan is tight, and the hit test takes the topmost
    -- card at a row, which would pick up the wrong one.
    return Drive.slotX(L, m.c) + 18, y
  end
end

local function targetPoint(s, m)
  local L = s.layout
  if m.k == "wf" or m.k == "tf" then
    return Drive.slotX(L, 3 + m.f) + 18, L.topY + 26
  elseif m.k == "wt" or m.k == "tt" or m.k == "ft" then
    local col = s.game.tab[m.t]
    if #col == 0 then return Drive.slotX(L, m.t) + 18, L.tabY + 26 end
    local y = Drive.cardY(s, m.t, #col)
    return Drive.slotX(L, m.t) + 18, y
  end
end

-- The cards of column `c` as the current frame drew them, top to bottom.
function Drive.column(s, c)
  local L = s.layout
  local want = Drive.slotX(L, c)
  local list = {}
  for _, card in ipairs(s.frame.cards) do
    if card.x == want and card.y >= L.tabY then list[#list + 1] = card end
  end
  table.sort(list, function(a, b) return a.y < b.y end)
  return list
end

-- Where card `i` of column `c` is drawn. The fan is the game's business, not
-- the driver's, so the position is looked up rather than recomputed -- but it
-- is counted from the *bottom* of the pile, which is what makes it exact.
--
-- On a window short enough to squeeze the fan the face-down step can reach
-- zero, and then the whole face-down block draws as a single visible back: the
-- frame holds fewer cards than the column does. Every face-up card always
-- keeps at least one pixel, so the last cards drawn are always the face-up
-- ones in order, and counting back from the end lines up either way.
function Drive.cardY(s, c, i)
  local list = Drive.column(s, c)
  local idx = #list - (#s.game.tab[c] - i)
  return list[idx] and list[idx].y or nil
end

-- Identifying every card on screen costs real time, and most callers only
-- want the geometry, so it is opt-in past the first frame.
function Drive.repaint(s, identify)
  local _, ops = s.hs:paint()
  s.frame = Frame.read(ops, s.bundle, { identify = identify and true or false })
  return s.frame
end

-- Is a run currently picked up? Read off the screen, because that is the only
-- honest way to ask: the selection lives inside the script under test.
function Drive.isHolding(s)
  local key = table.concat(s.frame.art.ui.SEL_COL, ",")
  local rings = s.frame.rings[key]
  return rings ~= nil and #rings > 0
end

-- Cancels a pick-up if there is one. Pressing escape with nothing held would
-- pause the game instead, which is right for a player and wrong for a test
-- that is only looking at things.
function Drive.release(s)
  if Drive.isHolding(s) then
    s.hs.on.escapeKey()
    Drive.repaint(s)
  end
end

-- A cheap structural comparison of screen against rules: no card identities,
-- just how many cards each column drew. Fewer than the column holds is fine
-- when a squeezed fan stacks the face-down block, but never fewer than the
-- face-up count and never more than the column.
function Drive.shapeMismatch(s)
  for c = 1, 7 do
    local shown = #Drive.column(s, c)
    local n = #s.game.tab[c]
    local up = n - s.game.down[c]
    if shown > n then
      return string.format("column %d draws %d cards, the rules say %d", c, shown, n)
    end
    if shown < up then
      return string.format("column %d draws %d cards but %d are face up", c, shown, up)
    end
  end
  return nil
end

-- Plays one move through the UI and mirrors it in the shadow game. Returns
-- false if the UI would not accept it, which is itself a finding.
function Drive.play(s, m)
  Drive.repaint(s)
  if Drive.isHolding(s) then s.hs.on.escapeKey(); Drive.repaint(s) end
  if m.k == "draw" or m.k == "recycle" then
    local x, y = sourcePoint(s, m)
    s.hs.on.mouseDown(x, y)
  else
    local sx, sy = sourcePoint(s, m)
    if not sx then return false end
    s.hs.on.mouseDown(sx, sy)          -- pick up
    local tx, ty = targetPoint(s, m)
    if not tx then return false end
    s.hs.on.mouseDown(tx, ty)          -- put down
  end
  if not s.game:play(m) then return false end
  Drive.repaint(s)

  -- Confirm the screen actually did it. Without this a click that missed
  -- would leave the shadow game running ahead of the UI, and every check
  -- afterwards would be comparing two different games -- which is exactly the
  -- kind of quiet divergence that makes a test suite worthless.
  local wrong = Drive.shapeMismatch(s)
  if wrong then
    s.refusal = wrong
    return false
  end
  return true
end

return Drive
