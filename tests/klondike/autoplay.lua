-- Plays Klondike for `make GAME=klondike screenshots`, so the preview PNGs
-- show real frames of a real game rather than a board arranged by hand.
--
-- The solver in tests/klondike/solver.lua does the playing, and the moves go
-- in through on.mouseDown like a player's would. The win at the end is a deal
-- the solver actually solved: it looks ahead at the seeds the script is about
-- to draw (tests/klondike/drive.lua explains how that is possible and why it
-- is checked rather than trusted), solves them offline, and then presses N
-- until the game deals the one it can finish.

package.path = (os.getenv("GAME_SRC") or "src/klondike") .. "/?.lua;"
  .. "tests/?.lua;" .. package.path
local K      = require("game")
local stub   = require("nspire_stub")
local Drive  = require("klondike.drive")
local Solver = require("klondike.solver")

local BUNDLE = "build/klondike/klondike.lua"

-- Enough deals to find one the heuristic solver finishes. It wins around two
-- in five at draw-1, so a dozen is generous; the budget is what a screenshot
-- run can afford to spend, not what the solver is capable of.
local WIN_SEARCH_DEALS  = 14
local WIN_SEARCH_BUDGET = 30000

return function(harness, capture)
  local function shot(hs, name)
    local _, ops = hs:paint()
    capture(name, ops)
  end

  -- ------------------------------------------------ the three-card game --

  shot(harness, "menu")

  -- dealSeeds rather than expectedSeed: this harness was booted by
  -- tools/screenshot.lua before we got here, so the stream has to be looked at
  -- and put back rather than re-seeded out from under it.
  local seed = Drive.dealSeeds(stub, nil, 1)[1]
  harness.on.enterKey()
  local s = Drive.session(harness, K, BUNDLE, seed, { draw = 3 })
  if not s.verified then
    error("autoplay lost track of the deal: " .. tostring(s.mismatch))
  end
  shot(harness, "deal")

  -- Play until a column has a run worth picking up, then pick it up: the
  -- highlights are the thing worth a picture, because being shown every legal
  -- destination is what makes this playable on a 318-pixel screen.
  local picked = false
  for _ = 1, 60 do
    if not picked then
      for c = 1, 7 do
        for i = s.game.down[c] + 1, #s.game.tab[c] - 1 do
          -- A run of two or more with somewhere to go.
          if #s.game:movesFrom("tab", c, i) > 0 then
            local y = Drive.cardY(s, c, i)
            if y then
              s.hs.on.mouseDown(Drive.slotX(s.layout, c) + 18, y)
              Drive.repaint(s)
              if Drive.isHolding(s) then
                shot(harness, "picked-up")
                picked = true
                Drive.release(s)
              end
            end
            break
          end
        end
        if picked then break end
      end
    end
    local m = Solver.orderedMoves(s.game)[1]
    if not m then break end
    if not Drive.play(s, m) then break end
    if picked and s.game:foundationTotal() >= 6 then break end
  end
  shot(harness, "foundations")

  harness.on.charIn("p")
  shot(harness, "paused")
  harness.on.charIn("p")

  -- ------------------------------------------------------ a game won ----

  -- A second boot, so the win can have a deal chosen for it. One card at a
  -- time: the solver finishes far more of those, and a screenshot run should
  -- not spend a minute looking for a three-card deal it can beat.
  local seeds = Drive.dealSeeds(stub, nil, WIN_SEARCH_DEALS)
  local pick, solution
  for i, sd in ipairs(seeds) do
    local g = K.new({ seed = sd, draw = 1 })
    local won, _, path = Solver.solve(g, { budget = WIN_SEARCH_BUDGET })
    if won then pick, solution = i, path; break end
  end

  if not pick then
    print("autoplay: no deal in " .. WIN_SEARCH_DEALS ..
          " was solved inside the budget; skipping the win frame")
    return
  end

  local hs = stub.load(BUNDLE, 318, 212)
  hs:resize(318, 212)
  hs.on.arrowKey("left")                 -- menu row 1: draw one card
  shot(hs, "menu-draw-one")
  hs.on.enterKey()                       -- deal 1
  for _ = 2, pick do hs.on.charIn("n") end

  local w = Drive.session(hs, K, BUNDLE, seeds[pick], { draw = 1 })
  if not w.verified then
    error("autoplay lost track of the winning deal: " .. tostring(w.mismatch))
  end

  local shownNearly = false
  for i = 1, #solution do
    if not Drive.play(w, solution[i]) then
      error("the UI refused solution move " .. i .. " (" .. tostring(w.refusal) .. ")")
    end
    if not shownNearly and w.game:foundationTotal() >= 40 then
      shot(hs, "nearly-there")
      shownNearly = true
    end
  end
  if not w.game:isWon() then error("the replayed solution did not win") end
  shot(hs, "win")
end
