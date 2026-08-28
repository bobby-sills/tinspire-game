-- A heuristic Klondike solver, shared by tests/klondike/run.lua (where it is a
-- way to drive millions of states through the rules engine, and a proof that a
-- legal path to all-foundations exists for the deals it wins) and by
-- tests/klondike/autoplay.lua (where it is what plays the game for the
-- screenshots).
--
-- It lives under tests/ on purpose. Nothing here ships to the calculator, and
-- the game does not import it -- searching a whole Klondike deal is far past
-- what a handheld can do inside a timer tick, so there is no on-device solver
-- to share this with.
--
-- Depth-first with a transposition set, a node budget and heuristic move
-- ordering. Backtracking is the engine's own make/unmake, which means the
-- search is also a very long-running test of undo: a single deal unwinds tens
-- of thousands of moves, and any state the undo failed to restore would send
-- the search down a path the position never actually allowed.

local Solver = {}

-- Position identity for the transposition set. Deliberately *not* the full
-- state: the score, the move count and the undo history are all consequences
-- of how you arrived, not of where you are, and folding them in would defeat
-- the whole point of the set.
--
-- The foundations are their heights, since a foundation is indexed by suit and
-- so its contents are implied. Everything else is written out in full: the
-- face-down count matters (two columns holding the same cards with a different
-- split are genuinely different positions) and so does the stock/waste split.
function Solver.posKey(g)
  local p = {}
  for c = 1, g.COLUMNS do
    p[#p + 1] = g.down[c] .. ":" .. table.concat(g.tab[c], ",")
  end
  p[#p + 1] = #g.found[1] .. "," .. #g.found[2] .. "," .. #g.found[3] .. "," .. #g.found[4]
  p[#p + 1] = table.concat(g.stock, ",")
  p[#p + 1] = table.concat(g.waste, ",")
  return table.concat(p, "|")
end

-- How promising a move looks, high first. Klondike search lives or dies on
-- this: the branching factor is small but the depth is enormous, so the
-- ordering is what decides whether a deal falls out in a thousand nodes or
-- never.
local function priority(g, m)
  if m.k == "tf" or m.k == "wf" then
    local card = (m.k == "wf") and g:wasteTop() or g.tab[m.c][#g.tab[m.c]]
    -- A card that can never be needed below again costs nothing to send up.
    if g:isSafeToAutoPlay(card) then return 100 end
    -- Otherwise it might still be wanted as a base, so it is a real choice.
    -- Emptying a column is worth more than the card is.
    if m.k == "tf" and #g.tab[m.c] == 1 then return 70 end
    if m.k == "tf" and g.down[m.c] == #g.tab[m.c] - 1 and g.down[m.c] > 0 then return 80 end
    return 40
  end

  if m.k == "tt" then
    local col = g.tab[m.c]
    -- Uncovering a face-down card is the only move that adds information, so
    -- it is almost always the right one.
    if m.i == g.down[m.c] + 1 and g.down[m.c] > 0 then return 90 end
    -- Moving a whole column that hides nothing just relocates it. Worth
    -- something only because it frees a column for a king.
    if m.i == 1 and g.down[m.c] == 0 then
      return (#g.tab[m.t] > 0) and 60 or -10
    end
    -- Splitting a run to expose part of it: mildly useful, often a shuffle.
    if m.i > 1 and col[m.i - 1] and g.down[m.c] < m.i - 1 then return 20 end
    return 30
  end

  if m.k == "wt" then return 50 end   -- gets a card out of the waste
  if m.k == "draw" then return 10 end
  if m.k == "recycle" then return 0 end
  return -20
end

-- The moves the search will consider, best first.
--
-- Foundation-to-tableau is dropped. It is a legal Klondike move and the game
-- offers it, but it is almost never what wins a deal, and including it turns
-- every foundation into a two-move cycle that the search has to keep proving
-- pointless. Leaving it out costs a small number of deals and buys a great
-- deal of depth, which is the better trade for something whose job is to
-- exercise the engine.
local function orderedMoves(g)
  local all, out = g:legalMoves(), {}
  for i = 1, #all do
    local m = all[i]
    if m.k ~= "ft" then
      out[#out + 1] = { m = m, p = priority(g, m), i = i }
    end
  end
  -- Index as the tiebreak keeps the order total, so a run is reproducible.
  table.sort(out, function(a, b)
    if a.p ~= b.p then return a.p > b.p end
    return a.i < b.i
  end)
  local moves = {}
  for i = 1, #out do moves[i] = out[i].m end
  return moves
end

Solver.orderedMoves = orderedMoves

-- Searches for a win from the current position. Returns won, nodes, path --
-- where `path` is the winning move list, playable from the position the search
-- started at. The game is left exactly as it was found either way: every move
-- made is unmade.
--
-- opts.budget   nodes before giving up (default 20000)
-- opts.maxDepth ply cap, to keep Lua's stack out of it (default 400)
function Solver.solve(g, opts)
  opts = opts or {}
  local budget = opts.budget or 20000
  local maxDepth = opts.maxDepth or 400

  local seen, nodes, path = {}, 0, {}
  local won = false

  local function dfs(depth)
    if g:isWon() then return true end
    if depth >= maxDepth then return false end
    nodes = nodes + 1
    if nodes > budget then return false end

    local key = Solver.posKey(g)
    if seen[key] then return false end
    seen[key] = true

    local moves = orderedMoves(g)
    for i = 1, #moves do
      if g:play(moves[i]) then
        path[#path + 1] = moves[i]
        if dfs(depth + 1) then return true end
        path[#path] = nil
        g:undo()
      end
    end
    return false
  end

  won = dfs(0)

  local solution = nil
  if won then
    solution = {}
    for i = 1, #path do solution[i] = path[i] end
    -- Rewind, so the caller gets the position it handed over.
    for _ = 1, #path do g:undo() end
  end

  return won, nodes, solution
end

return Solver
