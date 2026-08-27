-- game.lua -- pure Connect Four logic, plus the bot that plays it.
--
-- Like the other games here, this module knows nothing about the TI-Nspire:
-- no `platform`, no `gc`, no `timer`. All drawing and input lives in main.lua.
-- The bot lives here too, deliberately: keeping the search as pure logic is
-- what lets the tests drive it to completion synchronously while the handheld
-- runs the very same code in slices.

local Board = {}
Board.__index = Board

local COLS, ROWS, CONNECT = 7, 6, 4
Board.COLS, Board.ROWS, Board.CONNECT = COLS, ROWS, CONNECT

local CELLS = COLS * ROWS

-- Row 1 is the top row, row ROWS the bottom, so gravity fills downwards and
-- the drawing code can walk rows in screen order. Cell (c, r) lives at
-- (r - 1) * COLS + c, written out at each use because these are the hottest
-- lines in the file.

-- The four line directions. Their opposites are covered by scanning both ways
-- from the placed disc, so east/north/north-east/south-east is the whole set.
local DC = { 1, 0, 1, 1 }
local DR = { 0, 1, 1, -1 }

-- Centre-first. Connect Four's branching factor is 7, and a centre disc sits
-- in more of the 69 winning lines than any other, so trying the middle first
-- is what makes alpha-beta's cutoffs cheap.
local ORDER = { 4, 3, 5, 2, 6, 1, 7 }

-- ------------------------------------------------- the positional score ----
--
-- Every four-in-a-row window on the board -- 24 horizontal, 21 vertical and
-- 12 of each diagonal, 69 in all -- flattened to raw cell indices, four in a
-- row per window.
local WINDOWS = (function()
  local w = {}
  local function add(c, r, dc, dr)
    for k = 0, CONNECT - 1 do
      w[#w + 1] = (r + k * dr - 1) * COLS + (c + k * dc)
    end
  end
  for r = 1, ROWS do for c = 1, COLS - 3 do add(c, r, 1, 0) end end
  for r = 1, ROWS - 3 do for c = 1, COLS do add(c, r, 0, 1) end end
  for r = 1, ROWS - 3 do for c = 1, COLS - 3 do add(c, r, 1, 1) end end
  for r = CONNECT, ROWS do for c = 1, COLS - 3 do add(c, r, 1, -1) end end
  return w
end)()
Board.WINDOWS = WINDOWS

local NWINDOWS = #WINDOWS / 4

-- What a window is worth to player 1, by how many discs of each colour sit in
-- it. A window holding both colours can never be completed by either, so it
-- is worth exactly nothing; otherwise near-complete lines are worth a lot more
-- than sparse ones. Antisymmetric by construction: swap the colours and the
-- score negates, which is what lets negamax read one number for both sides.
-- The count-4 entry is only ever passed through: a completed line is a win,
-- and the search scores that before it ever looks at the position.
local WEIGHT = { [0] = 0, 1, 8, 60, 1000 }
local CENTRE = 4 -- per disc in column 4, the one thing the window count misses

-- Indexed by ones * 5 + twos + 1, so a window's contribution is one lookup.
local WSCORE = (function()
  local t = {}
  for a = 0, CONNECT do
    for b = 0, CONNECT do
      local v = 0
      if a > 0 and b == 0 then v = WEIGHT[a]
      elseif b > 0 and a == 0 then v = -WEIGHT[b] end
      t[a * 5 + b + 1] = v
    end
  end
  return t
end)()
Board.WSCORE = WSCORE
Board.CENTRE_WEIGHT = CENTRE

-- Which windows each cell belongs to (between 3 and 13 of them), so placing a
-- disc can patch the running score instead of rescanning all 69. Recomputing
-- the whole board at every leaf was measured at 12us a call against 0.6us for
-- everything else a node does -- it was the search, near enough.
local CELLWIN, CELLWINN = {}, {}
for i = 1, CELLS do CELLWIN[i], CELLWINN[i] = {}, 0 end
for wid = 1, NWINDOWS do
  local base = (wid - 1) * CONNECT
  for k = 1, CONNECT do
    local cell = WINDOWS[base + k]
    local n = CELLWINN[cell] + 1
    CELLWIN[cell][n], CELLWINN[cell] = wid, n
  end
end

-- opts.rand:  function(n) -> integer in [1, n]. Injectable, so tests get a
--             bot whose blunders are reproducible.
-- opts.mode:  "hotseat" (two players on one calculator) or "bot".
--
-- There is no networked mode and there never can be: Nspire Lua has no socket
-- API, no link-cable access and no wireless. Two players means one calculator.
function Board.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Board)
  self.rand = opts.rand or function(n) return math.random(n) end
  self.mode = opts.mode or "bot"
  self.botPlayer = opts.botPlayer or 2
  self.wins = { 0, 0 }
  self.draws = 0
  self:reset(opts.starter)
  return self
end

-- starter: which player moves first, 1 (red) or 2 (yellow).
function Board:reset(starter)
  local cells = {}
  for i = 1, CELLS do cells[i] = 0 end
  self.cells = cells
  self.heights = { 0, 0, 0, 0, 0, 0, 0 }
  -- Discs of each colour per window, packed as ones * 5 + twos, and the
  -- running positional score the two of them add up to. Both are maintained
  -- by place/unplace; an empty board scores zero.
  local wcode = {}
  for i = 1, NWINDOWS do wcode[i] = 0 end
  self.wcode = wcode
  self.score = 0
  self.nplaced = 0
  self.turn = starter or 1
  self.state = "ready" -- ready | playing | paused | won | draw
  self.winner = nil
  self.line = nil      -- the winning run, for highlighting
  self.last = nil      -- { c, r } of the most recent disc
end

-- ------------------------------------------------------------- board reads --

function Board:at(c, r)
  if c < 1 or c > COLS or r < 1 or r > ROWS then return nil end
  return self.cells[(r - 1) * COLS + c]
end

-- True when a disc can physically go in column c. Deliberately says nothing
-- about whose turn it is or whether the game is over -- the search needs the
-- purely geometric question, and Board:drop adds the rules on top.
function Board:open(c)
  if type(c) ~= "number" or c ~= math.floor(c) then return false end
  if c < 1 or c > COLS then return false end
  return self.heights[c] < ROWS
end

-- The row a disc dropped into column c would come to rest in, or nil.
function Board:landing(c)
  if not self:open(c) then return nil end
  return ROWS - self.heights[c]
end

function Board:isFull()
  return self.nplaced >= CELLS
end

function Board:isOver()
  return self.state == "won" or self.state == "draw"
end

-- Centre-first, so the caller that wants "a reasonable move" can take the
-- first entry and the search gets its ordering for free.
function Board:legalMoves(out)
  out = out or {}
  for i = #out, 1, -1 do out[i] = nil end
  for i = 1, COLS do
    local c = ORDER[i]
    if self.heights[c] < ROWS then out[#out + 1] = c end
  end
  return out
end

-- ------------------------------------------------------- make / unmake ------
--
-- The search explores by mutating this board and undoing, rather than copying
-- it: a copy per node would dominate the cost of the search on a handheld.
-- These two are the only writers, and they are exact inverses.

function Board:place(c)
  local p = self.turn
  local h = self.heights[c]
  local r = ROWS - h
  local cell = (r - 1) * COLS + c

  self.cells[cell] = p
  self.heights[c] = h + 1
  self.nplaced = self.nplaced + 1
  self.turn = 3 - p

  local wc, s = self.wcode, self.score
  local list, n = CELLWIN[cell], CELLWINN[cell]
  local step = (p == 1) and 5 or 1
  for k = 1, n do
    local wid = list[k]
    local old = wc[wid]
    local new = old + step
    wc[wid] = new
    s = s + WSCORE[new + 1] - WSCORE[old + 1]
  end
  if c == 4 then s = s + ((p == 1) and CENTRE or -CENTRE) end
  self.score = s

  return r
end

function Board:unplace(c)
  local p = 3 - self.turn
  local h = self.heights[c] - 1
  local r = ROWS - h
  local cell = (r - 1) * COLS + c

  self.cells[cell] = 0
  self.heights[c] = h
  self.nplaced = self.nplaced - 1
  self.turn = p

  local wc, s = self.wcode, self.score
  local list, n = CELLWIN[cell], CELLWINN[cell]
  local step = (p == 1) and 5 or 1
  for k = 1, n do
    local wid = list[k]
    local old = wc[wid]
    local new = old - step
    wc[wid] = new
    s = s + WSCORE[new + 1] - WSCORE[old + 1]
  end
  if c == 4 then s = s - ((p == 1) and CENTRE or -CENTRE) end
  self.score = s
end

-- Copies the part of a position the search cares about into `dst`.
--
-- The bot searches a scratch copy rather than the board being played on. It
-- has to: the search is suspended between timer ticks with several discs
-- still played, and on a shared board those half-explored discs get painted
-- to the screen -- the player watches phantom pieces appear and vanish while
-- the bot thinks. One copy per move is nothing; a copy per node would have
-- cost more than the search.
function Board:copyInto(dst)
  local src, out = self.cells, dst.cells
  for i = 1, CELLS do out[i] = src[i] end
  src, out = self.heights, dst.heights
  for i = 1, COLS do out[i] = src[i] end
  src, out = self.wcode, dst.wcode
  for i = 1, NWINDOWS do out[i] = src[i] end

  dst.nplaced = self.nplaced
  dst.turn = self.turn
  dst.score = self.score
  dst.state = "playing" -- the search only ever asks about live positions
  return dst
end

-- ------------------------------------------------------- win detection ------
--
-- Only a line through the disc that was just played can be new, so both of
-- these scan four directions outward from one cell instead of walking the
-- whole board. tests/connect4/run.lua checks that this finds exactly what a
-- full-board scan finds, at every cell and in every direction.

-- Allocation-free, because the search calls it at every node.
--
-- Assumes p's disc is already sitting at (c, r): it counts that cell as one
-- and scans outward. Every caller asks immediately after placing there, which
-- is the only time the question means anything. Ask it about an empty cell and
-- it will happily count a gap as filled.
function Board:winsAt(c, r, p)
  local cells = self.cells
  for d = 1, 4 do
    local dc, dr = DC[d], DR[d]
    local n = 1

    local cc, rr = c + dc, r + dr
    while cc >= 1 and cc <= COLS and rr >= 1 and rr <= ROWS
        and cells[(rr - 1) * COLS + cc] == p do
      n = n + 1
      cc, rr = cc + dc, rr + dr
    end

    cc, rr = c - dc, r - dr
    while cc >= 1 and cc <= COLS and rr >= 1 and rr <= ROWS
        and cells[(rr - 1) * COLS + cc] == p do
      n = n + 1
      cc, rr = cc - dc, rr - dr
    end

    if n >= CONNECT then return true end
  end
  return false
end

-- The winning run itself, for highlighting. Returns every disc in the run,
-- which is four but can be five or more when a drop joins two groups.
function Board:lineAt(c, r)
  local p = self:at(c, r)
  if not p or p == 0 then return nil end

  for d = 1, 4 do
    local dc, dr = DC[d], DR[d]

    -- Walk back to the start of the run, then collect forwards.
    local sc, sr = c, r
    while self:at(sc - dc, sr - dr) == p do
      sc, sr = sc - dc, sr - dr
    end

    local run = {}
    local cc, rr = sc, sr
    while self:at(cc, rr) == p do
      run[#run + 1] = { c = cc, r = rr }
      cc, rr = cc + dc, rr + dr
    end

    if #run >= CONNECT then return run end
  end
  return nil
end

-- ---------------------------------------------------------------- the game --

function Board:start()
  if self.state == "ready" then self.state = "playing" end
end

function Board:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Board:resume()
  if self.state == "paused" then self.state = "playing" end
end

-- Plays a disc for the player to move. Returns the row it landed in, or nil
-- if the move was illegal (full column, out of range, or game not running).
function Board:drop(c)
  if self.state ~= "playing" then return nil end
  if not self:open(c) then return nil end

  local p = self.turn
  local r = self:place(c)
  self.last = { c = c, r = r }

  if self:winsAt(c, r, p) then
    self.state = "won"
    self.winner = p
    self.line = self:lineAt(c, r)
    self.wins[p] = self.wins[p] + 1
  elseif self:isFull() then
    self.state = "draw"
    self.draws = self.draws + 1
  end
  return r
end

-- ============================================================== the bot =====

local AI = {}
AI.__index = AI
Board.AI = AI

-- Far enough above any positional score that a mate always outranks one, and
-- small enough that WIN_SCORE - ply stays comfortably inside a double.
local WIN_SCORE = 100000
AI.WIN_SCORE = WIN_SCORE

-- Nodes of search the host should spend per timer tick, and the difficulty
-- table those slices add up to.
--
-- The whole point of the incremental search is that this number is bounded: a
-- search that ran to completion inside one on.timer() would freeze the screen
-- and queue up keypresses, which reads to the player as a crash.
--
-- Measured on the build container (tests/connect4/run.lua prints this table):
--
--   depth    1     2     3     4      5      6       7       8
--   nodes    7    26   115   387   1943   4404   14067   23534   (mean, cumulative)
--
-- at ~3.2us a node, so ~310k nodes/sec here. The handheld's 396MHz ARM runs
-- interpreted Lua far slower than this x86 -- call it 50x, which is the one
-- number in this file that is an estimate rather than a measurement -- so
-- ~6k nodes/sec, ~310 nodes in a 0.05s tick. Half of that is the budget:
Board.TICK_NODES = 150

-- Half rather than the third a game loop would want, because overrunning a
-- tick costs almost nothing *here specifically*: while the bot is thinking
-- there is no animation and nothing blinking, so a late timer just means the
-- bot's turn takes a little longer. Even if the 50x estimate is out by two,
-- the failure is a slower bot, not a stuck one.

-- Difficulty is search depth, plus deliberate blunders at the bottom so a
-- beginner can actually win a game.
--
-- maxDepth and nodeBudget are ceilings, not promises: what the bot really
-- gets is thinkTicks * TICK_NODES nodes, and iterative deepening turns that
-- into "the deepest complete search that fit". So the levels are separated by
-- *time* as well as by depth. Measured at 150 nodes a tick, over 40 random
-- midgame positions each (tests/connect4/run.lua prints this one too):
--
--   Easy    10 ticks (0.5s)      34 nodes   depth 2.0
--   Medium  20 ticks (1.0s)    1941 nodes   depth 4.7
--   Hard    40 ticks (2.0s)    5922 nodes   depth 5.6
--   Expert  80 ticks (4.0s)   12000 nodes   depth 6.2
--
-- nodeBudget is what binds instead on a desktop, where the same eighty ticks
-- would otherwise be four seconds of a search that finished in a tenth of one.
Board.LEVELS = {
  { name = "Easy",   maxDepth = 2, blunder = 0.35, nodeBudget = 2000,   thinkTicks = 10 },
  { name = "Medium", maxDepth = 5, blunder = 0.06, nodeBudget = 12000,  thinkTicks = 20 },
  { name = "Hard",   maxDepth = 7, blunder = 0,    nodeBudget = 60000,  thinkTicks = 40 },
  { name = "Expert", maxDepth = 9, blunder = 0,    nodeBudget = 250000, thinkTicks = 80 },
}

function AI.new(board, opts)
  opts = opts or {}
  local self = setmetatable({}, AI)
  -- root is the game's board and is only ever read; board is the scratch copy
  -- the search mutates. See Board:copyInto for why they are not the same one.
  self.root = board
  self.board = Board.new({ rand = board.rand })
  self.maxDepth = opts.maxDepth or 6
  self.nodeBudget = opts.nodeBudget or 40000
  self.blunder = opts.blunder or 0
  self.rand = opts.rand or board.rand
  self.stack = {}
  self.rootOrder = {}
  self.legal = {}
  self:cancel()
  return self
end

function AI.fromLevel(board, level, opts)
  local L = Board.LEVELS[level] or Board.LEVELS[#Board.LEVELS]
  local o = { maxDepth = L.maxDepth, blunder = L.blunder, nodeBudget = L.nodeBudget }
  if opts then for k, v in pairs(opts) do o[k] = v end end
  return AI.new(board, o)
end

-- Puts back every disc the search still has on its scratch board.
--
-- Abandoning an iteration part-way -- which running out of budget does, and
-- which is the normal case on a handheld -- leaves one played disc per live
-- stack frame. begin() copies the position in fresh and would overwrite them
-- anyway, so this is belt and braces: it keeps ai.board a legal position at
-- every moment between calls, which is cheap to hold and unpleasant to debug
-- the absence of. Deepest frame first, because that disc went down last.
function AI:unwind()
  local sp = self.sp or 0
  while sp >= 1 do
    local f = self.stack[sp]
    if f and f.child then
      self.board:unplace(f.child)
      f.child = nil
    end
    sp = sp - 1
  end
  self.sp = 0
end

-- Throws away any search in progress, leaving the board untouched, and
-- readies a fresh one.
function AI:cancel()
  self:unwind()
  self.active = false
  self.done = false
  self.result = nil
  self.sp = 0
  self.nodes = 0
  self.searchDepth = 0
  self.completedDepth = nil
  self.best = nil
  self.bestValue = 0
  self.blundered = false
end

-- Static evaluation from `p`'s point of view; positive is good for p.
--
-- There is no work left to do here: Board:place keeps the score up to date as
-- the search walks, and it is antisymmetric, so one side reads the negation of
-- the other. tests/connect4/run.lua checks it against a full rescan of all 69
-- windows after every move of a long fuzz.
function AI:evaluate(p)
  local s = self.board.score
  if p == 1 then return s end
  return -s
end

-- --------------------------------------------------- the incremental search --
--
-- There are no threads on this machine, and a search that runs to completion
-- inside one on.timer() callback freezes the screen and queues up keypresses,
-- which reads to the player as a crash. So the search is an explicit state
-- machine over its own stack of frames: main.lua calls think(budget) once per
-- tick and the search advances by that many nodes and no more.
--
-- Frames mirror what a recursive negamax would keep in locals:
--   depth     plies left to search below this node
--   alpha,beta  the window, already negated for this side
--   best,bestMove  the best seen so far at this node
--   moves,i   the move list and how far through it we are
--   child     the column currently played on the board, awaiting its value
--   pending   a child's returned value, waiting to be folded in

function AI:frame(n)
  local f = self.stack[n]
  if not f then
    f = {}
    self.stack[n] = f
  end
  return f
end

-- Root move order: last iteration's best first, then centre-out. Searching
-- the previous best first is most of what makes iterative deepening pay for
-- itself rather than just costing extra.
function AI:buildRootOrder()
  local out = self.rootOrder
  for i = #out, 1, -1 do out[i] = nil end
  if self.best then out[1] = self.best end
  for _, c in ipairs(self.legal) do
    if c ~= self.best then out[#out + 1] = c end
  end
  return out
end

function AI:startDepth(d)
  self.searchDepth = d
  self.sp = 1
  local f = self:frame(1)
  f.depth = d
  f.alpha = -math.huge
  f.beta = math.huge
  f.best = -math.huge
  f.bestMove = nil
  f.moves = self:buildRootOrder()
  f.i = 0
  f.child = nil
  f.pending = nil
end

-- Begins a search for whoever is to move. Safe to call on a finished board:
-- it just reports "no move".
function AI:begin()
  self:cancel()
  self.root:copyInto(self.board)
  self.board:legalMoves(self.legal)

  if #self.legal == 0 then
    self.done = true
    return
  end

  -- Centre-most legal column: the fallback that guarantees think() can always
  -- name a legal move, however little work it has been allowed to do.
  self.best = self.legal[1]

  if self.blunder > 0 and self.rand(1000) <= self.blunder * 1000 then
    self.result = self.legal[self.rand(#self.legal)]
    self.blundered = true
    self.done = true
    return
  end

  self.active = true
  self:startDepth(1)
end

-- Pops the top frame, handing `value` to its parent -- or finishing the
-- iteration when the frame that returned was the root.
function AI:ret(value)
  self.sp = self.sp - 1
  if self.sp == 0 then
    self:finishDepth(value)
  else
    self.stack[self.sp].pending = value
  end
end

function AI:finishDepth(value)
  local root = self.stack[1]
  if root.bestMove then
    self.best = root.bestMove
    self.bestValue = value
    self.completedDepth = self.searchDepth
  end

  -- Stop when there is nothing more to learn: the depth cap, a board with
  -- fewer empty cells than that, or a result already forced either way.
  local empties = CELLS - self.board.nplaced
  if self.searchDepth >= self.maxDepth
      or self.searchDepth >= empties
      or self.bestValue >= WIN_SCORE - 1000
      or self.bestValue <= -WIN_SCORE + 1000 then
    self.active = false
    self.done = true
    self.result = self.best
  else
    self:startDepth(self.searchDepth + 1)
  end
end

-- One unit of work: try one move at the current node. Costs at most one node.
function AI:step()
  local f = self.stack[self.sp]
  local board = self.board

  -- A child finished while we were away. Negamax: its value is from the other
  -- side's point of view, so it comes back negated.
  if f.pending ~= nil then
    local v = -f.pending
    f.pending = nil
    board:unplace(f.child)
    f.child = nil
    if v > f.best then
      f.best, f.bestMove = v, f.moves[f.i]
      if v > f.alpha then f.alpha = v end
    end
    if f.alpha >= f.beta then return self:ret(f.best) end
  end

  local moves, heights = f.moves, board.heights
  local i = f.i + 1
  while moves[i] and heights[moves[i]] >= ROWS do i = i + 1 end
  f.i = i

  local c = moves[i]
  if not c then return self:ret(f.best) end

  local p = board.turn
  local r = board:place(c)
  self.nodes = self.nodes + 1

  -- Terminal and horizon cases are scored here rather than in a child frame,
  -- which keeps the stack one level shallower than the nominal depth.
  local v
  if board:winsAt(c, r, p) then
    -- Distance from the root, so a win found sooner beats the same win found
    -- later and the bot actually finishes games off instead of dawdling.
    v = WIN_SCORE - (self.searchDepth - f.depth)
  elseif board:isFull() then
    v = 0
  elseif f.depth <= 1 then
    -- Board:place already folded this move into board.score, so the horizon
    -- evaluation is a sign flip. Inlined because this is the innermost line
    -- of the whole search.
    v = (p == 1) and board.score or -board.score
  end

  if v then
    board:unplace(c)
    if v > f.best then
      f.best, f.bestMove = v, c
      if v > f.alpha then f.alpha = v end
    end
    if f.alpha >= f.beta then return self:ret(f.best) end
    return
  end

  f.child = c
  local g = self:frame(self.sp + 1)
  g.depth = f.depth - 1
  g.alpha = -f.beta
  g.beta = -f.alpha
  g.best = -math.huge
  g.bestMove = nil
  g.moves = ORDER
  g.i = 0
  g.child = nil
  g.pending = nil
  self.sp = self.sp + 1
end

-- Does up to maxNodes nodes of work. Returns the chosen column once the
-- search has settled, or nil to mean "still thinking, call me again".
--
-- Slicing changes nothing about the answer: the budget only ever decides
-- *when* this returns, never *what*. That is worth keeping true -- it is what
-- tests/connect4/run.lua leans on to check the sliced search against the
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
    self:unwind()
    self.active = false
    self.done = true
    self.result = self.best
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
  if not self.done then
    self:unwind()
    self.active = false
    self.done = true
    self.result = self.best
  end
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

return Board
