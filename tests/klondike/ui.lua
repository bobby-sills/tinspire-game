-- Klondike's frame assertions, run by tests/run_ui.lua against the built
-- bundle. The generic suite there already proves the script loads and survives
-- input; these are the claims specific to this game's layout and its rules.

package.path = (os.getenv("GAME_SRC") or "src/klondike") .. "/?.lua;"
  .. "tests/?.lua;" .. package.path
local K      = require("game")
local Frame  = require("klondike.frame")
local Drive  = require("klondike.drive")
local Solver = require("klondike.solver")

local BUNDLE = "build/klondike/klondike.lua"

return function(t)
  local test, ok, eq, fail, stub = t.test, t.ok, t.eq, t.fail, t.stub

  -- The sizes tests/run_ui.lua itself renders at, so the layout is checked
  -- against exactly the windows the rest of the suite drives.
  local SIZES = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
  }

  -- Measuring text needs a context, since the op log records what was drawn
  -- but not how wide the font made it.
  local function textWidth(size, style, text)
    local gc = stub.newGC()
    gc:setFont("sansserif", style or "r", size or 10)
    return gc:getStringWidth(text), gc:getStringHeight(text)
  end

  local function outside(ops, w, h)
    for _, o in ipairs(ops) do
      if o.op == "drawString" then
        local tw, th = textWidth(o.size, o.style, o.text)
        if o.x < 0 or o.y < 0 or o.x + tw > w or o.y + th > h then
          return string.format("text %q at %d,%d (%dx%d)", o.text, o.x, o.y, tw, th)
        end
      else
        local x2 = o.x + (o.w or 0)
        local y2 = o.y + (o.h or 0)
        if o.op == "drawLine" then x2, y2 = o.x2, o.y2 end
        if math.min(o.x, x2) < 0 or math.min(o.y, y2) < 0
           or math.max(o.x, x2) > w or math.max(o.y, y2) > h then
          return string.format("%s at %d,%d %sx%s", o.op, o.x, o.y,
            tostring(o.w or o.x2), tostring(o.h or o.y2))
        end
      end
    end
    return nil
  end

  -- ============================================================ layout ====

  test("nothing is ever drawn outside the window", function()
    for _, sz in ipairs(SIZES) do
      local w, h = sz[1], sz[2]
      local hs = stub.load(BUNDLE, w, h)
      hs:resize(w, h)

      local _, ops = hs:paint()
      local bad = outside(ops, w, h)
      if bad then fail(string.format("%dx%d menu: %s", w, h, bad)) end

      hs.on.enterKey()                      -- deal
      -- Walk the cursor everywhere and pick things up, since a highlight is
      -- drawn round whatever it lands on and that is what escapes a frame.
      local keys = { "up", "down", "left", "right" }
      for i = 1, 120 do
        hs.on.arrowKey(keys[(i % 4) + 1])
        if i % 5 == 0 then hs.on.enterKey() end
        if i % 17 == 0 then hs.on.escapeKey() end
        if i % 31 == 0 then hs.on.charIn("u") end
        local _, o2 = hs:paint()
        local b2 = outside(o2, w, h)
        if b2 then
          return fail(string.format("%dx%d step %d: %s", w, h, i, b2))
        end
      end
      for _, panel in ipairs({ "p", "m" }) do
        hs.on.charIn(panel)
        local _, o3 = hs:paint()
        local b3 = outside(o3, w, h)
        if b3 then fail(string.format("%dx%d %s panel: %s", w, h, panel, b3)) end
      end
      ok(true, string.format("%dx%d stayed inside its frame", w, h))
    end
  end)

  test("a window too small for a deal says so instead of drawing one", function()
    -- Seven 37-pixel cards will not scale down -- pixel art at a fractional
    -- factor is ruined art -- so below the minimum the game draws a panel.
    for _, sz in ipairs({ { 120, 90 }, { 160, 120 }, { 240, 160 }, { 200, 480 } }) do
      local hs = stub.load(BUNDLE, sz[1], sz[2])
      hs:resize(sz[1], sz[2])
      hs.on.enterKey()
      local _, ops = hs:paint()
      local f = Frame.read(ops, BUNDLE)
      eq(#f.cards, 0, string.format("%dx%d draws no cards", sz[1], sz[2]))
      local said = false
      for _, s in ipairs(f.strings) do
        if s.text:lower():find("small") or s.text:lower():find("bigger")
           or s.text:lower():find("need") then said = true end
      end
      ok(said, string.format("%dx%d explains itself", sz[1], sz[2]))
    end
  end)

  -- ============================================================== fan ====

  -- The claim: however long a column gets and however short the window is,
  -- every card stays inside the tableau area. The fan is adaptive, so this is
  -- not something a fixed offset guarantees -- it has to be checked on real
  -- frames.
  local function tableauBounds(f, L, h)
    return L.tabY, h - 1
  end

  local function checkFan(f, L, w, h, where)
    local top, bottom = tableauBounds(f, L, h)
    for _, c in ipairs(f.cards) do
      if c.y >= L.tabY then
        if c.y < top then
          fail(string.format("%s: a card starts at y=%d, above the tableau at %d",
            where, c.y, top))
        end
        if c.y + c.strip > bottom + 1 then
          fail(string.format("%s: a card runs to y=%d, past the bottom at %d",
            where, c.y + c.strip, bottom + 1))
        end
      end
    end
  end

  test("the fan keeps every column inside the tableau, however long", function()
    local longest, frames = 0, 0

    -- Real play first, with a chooser that deliberately piles cards onto the
    -- longest column it can, since that is what stresses the fan.
    local function stacker(g)
      local best, bestScore = nil, -1
      for _, m in ipairs(g:legalMoves()) do
        local s = -1
        if m.k == "tt" then s = 100 + #g.tab[m.t]
        elseif m.k == "wt" then s = 80 + #g.tab[m.t]
        elseif m.k == "draw" then s = 10
        elseif m.k == "recycle" then s = 5 end
        if s > bestScore then best, bestScore = m, s end
      end
      return best
    end

    -- Several window heights and several deals. The short windows are the
    -- interesting ones: at 318x140 the tableau has six pixels to spend on the
    -- whole fan, so even a seven-card column has to squeeze, which is the same
    -- code path a nineteen-card column takes on the handheld.
    local CASES = {
      { 318, 212, 20240101 }, { 318, 212, 777 }, { 318, 212, 31337 },
      { 318, 140, 20240101 }, { 318, 150, 4242 }, { 318, 160, 99 },
      { 640, 480, 5150 },
    }
    for _, sz in ipairs(CASES) do
      local w, h = sz[1], sz[2]
      local s = Drive.attach(stub, K, BUNDLE, w, h, sz[3])
      if not s.verified then
        fail(string.format("%dx%d: the driver lost track of the deal: %s",
          w, h, tostring(s.mismatch)))
      else
        for step = 1, 150 do
          local m = stacker(s.game)
          if not m then break end
          if not Drive.play(s, m) then
            fail(string.format("%dx%d step %d: the UI refused %s (%s)",
              w, h, step, K.moveKey(m), tostring(s.refusal)))
            break
          end
          for c = 1, 7 do
            if #s.game.tab[c] > longest then longest = #s.game.tab[c] end
          end
          checkFan(s.frame, s.layout, w, h,
            string.format("%dx%d step %d", w, h, step))
          frames = frames + 1
          -- Re-read the faces from time to time: a driver that had drifted
          -- off the real game would make every check above meaningless.
          if step % 40 == 0 then
            Drive.repaint(s, true)
            local bad = Drive.disagreement(s, s.frame)
            if bad then
              fail(string.format("%dx%d step %d: %s", w, h, step, bad))
              break
            end
          end
        end
      end
    end

    ok(longest >= 11, "columns got long enough to matter: " .. longest .. " cards")
    print(string.format("       fan: %d frames checked, longest column %d cards",
      frames, longest))
  end)

  -- =================================================== the highlights ====

  test("the highlighted destinations are exactly the legal ones", function()
    local s = Drive.attach(stub, K, BUNDLE)
    if not s.verified then
      return fail("the driver lost track of the deal: " .. tostring(s.mismatch))
    end
    local L = s.layout

    -- A ring's bounding box back to the pile it surrounds.
    local function pileOf(box)
      local slot = (box.x - L.x0) / L.pitch
      if slot ~= math.floor(slot) then return nil end
      slot = slot + 1
      if box.y < L.tabY then
        if slot >= 4 then return "found:" .. (slot - 3) end
        return (slot == 1) and "stock" or "waste"
      end
      return "tab:" .. slot
    end

    local function shownDests()
      local set = {}
      for _, b in ipairs(Frame.boxes(s.frame.rings[
          table.concat(s.frame.art.ui.DEST_COL, ",")])) do
        local p = pileOf(b)
        if p then set[p] = true end
      end
      return set
    end

    local function wantDests(moves)
      local set = {}
      for _, m in ipairs(moves) do
        if m.k == "wf" or m.k == "tf" then set["found:" .. m.f] = true
        elseif m.k == "wt" or m.k == "tt" or m.k == "ft" then set["tab:" .. m.t] = true end
      end
      return set
    end

    local function compare(where, want, got)
      for k in pairs(want) do
        if not got[k] then fail(where .. ": " .. k .. " is legal but not highlighted") end
      end
      for k in pairs(got) do
        if not want[k] then fail(where .. ": " .. k .. " is highlighted but not legal") end
      end
    end

    local checked, withDests = 0, 0
    for round = 1, 22 do
      Drive.repaint(s)
      -- Every face-up tableau card, plus the waste and the foundations.
      for c = 1, 7 do
        for i = s.game.down[c] + 1, #s.game.tab[c] do
          local y = Drive.cardY(s, c, i)
          if y then
            s.hs.on.mouseDown(Drive.slotX(L, c) + 18, y + 1)
            Drive.repaint(s)
            local want = wantDests(s.game:movesFrom("tab", c, i))
            compare(string.format("round %d, column %d card %d", round, c, i),
                    want, shownDests())
            checked = checked + 1
            if next(want) then withDests = withDests + 1 end
            Drive.release(s)
          end
        end
      end

      s.hs.on.mouseDown(Drive.slotX(L, 2) + 18, L.topY + 26)
      Drive.repaint(s)
      compare("round " .. round .. ", waste",
              wantDests(s.game:movesFrom("waste")), shownDests())
      checked = checked + 1
      Drive.release(s)

      for f = 1, 4 do
        s.hs.on.mouseDown(Drive.slotX(L, 3 + f) + 18, L.topY + 26)
        Drive.repaint(s)
        compare("round " .. round .. ", foundation " .. f,
                wantDests(s.game:movesFrom("found", f)), shownDests())
        checked = checked + 1
        Drive.release(s)
      end

      local m = Solver.orderedMoves(s.game)[1]
      if not m then break end
      if not Drive.play(s, m) then
        fail("round " .. round .. ": the UI refused " .. K.moveKey(m)
             .. " (" .. tostring(s.refusal) .. ")")
        break
      end
    end

    ok(checked > 200, checked .. " selections checked against the rules")
    ok(withDests > 20, withDests .. " of them actually had somewhere to go")
  end)

  -- ================================================ what is on screen ====

  test("no card is ever drawn twice in one frame", function()
    -- The 52-card invariant as the screen sees it. The rules tests prove the
    -- piles hold one of each; this proves the drawing does not put one of them
    -- in two places, which is a different bug and a visible one.
    local s = Drive.attach(stub, K, BUNDLE)
    if not s.verified then
      return fail("the driver lost track of the deal: " .. tostring(s.mismatch))
    end
    local worstRects, frames = 0, 0
    for step = 1, 90 do
      local seen = {}
      for _, c in ipairs(s.frame.cards) do
        -- Only fully identified faces: a thin strip may honestly match more
        -- than one card, and that is not a duplicate.
        if c.name and c.name ~= "back" then
          if seen[c.name] then
            fail("step " .. step .. ": " .. c.name .. " is on screen twice")
          end
          seen[c.name] = true
        end
      end
      local n = 0
      for _, o in ipairs(s.frame.rects) do n = n + 1 end
      if n > worstRects then worstRects = n end
      frames = frames + 1

      local m = Solver.orderedMoves(s.game)[1]
      if not m then break end
      if not Drive.play(s, m) then break end
    end

    -- Klondike repaints on a key press, never on a timer, so this is a
    -- per-keypress cost rather than a per-frame one. Chess draws a whole board
    -- in about 940 rects and is comfortable; the ceiling here is generous
    -- enough to catch a runaway, not to pin the current number.
    ok(worstRects < 6000, "worst repaint was " .. worstRects .. " rects")
    print(string.format("       paint: %d frames, worst repaint %d rects",
      frames, worstRects))
  end)

  test("the foundations show the suit they are waiting for", function()
    -- The pips are drawn from the card art, not from the font: the Nspire is
    -- not guaranteed to carry U+2660-2667 and a missing glyph on this OS is a
    -- silent empty box.
    local hs = stub.load(BUNDLE, 318, 212)
    hs:resize(318, 212)
    hs.on.enterKey()
    local _, ops = hs:paint()
    local f = Frame.read(ops, BUNDLE)
    -- Five empty piles at the deal: the four foundations and the waste, which
    -- nothing has been turned onto yet.
    eq(#f.slots, 5, "four foundations and an empty waste")

    -- A pip is ink from the card palette, which the slot's own outline is not.
    -- Two of the four are red and two are black; a wrong pip lookup would
    -- break exactly that.
    local function inkAt(slot)
      local red, black = 0, 0
      for _, o in ipairs(f.rects) do
        if o.x >= slot.x and o.x < slot.x + f.art.w
           and o.y >= slot.y and o.y < slot.y + f.art.h and o.h == 1 then
          for _, ink in ipairs(f.art.ink) do
            if o.color[1] == ink[1] and o.color[2] == ink[2] and o.color[3] == ink[3] then
              if ink[1] > ink[3] then red = red + 1 else black = black + 1 end
            end
          end
        end
      end
      return red, black
    end

    local reds, blacks, bare = 0, 0, 0
    for _, slot in ipairs(f.slots) do
      local red, black = inkAt(slot)
      if red > 0 then reds = reds + 1
      elseif black > 0 then blacks = blacks + 1
      else bare = bare + 1 end
    end
    eq(reds, 2, "two red pips")
    eq(blacks, 2, "two black pips")
    eq(bare, 1, "and the waste, which waits for no particular suit")
  end)
end
