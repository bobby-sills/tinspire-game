-- game.lua -- pure 2048 rules.
--
-- This module deliberately knows nothing about the TI-Nspire: no `platform`,
-- no `gc`, no `timer`. That keeps it runnable under a plain Lua 5.1
-- interpreter on a laptop, so the rules can be tested without a calculator.
-- All drawing, input and timing lives in src/2048/main.lua.

local Board = {}
Board.__index = Board

-- ------------------------------------------------------------------ tuning --
-- The only numbers worth playing with; the rest is 2048's actual rules.
local SIZE       = 4     -- board is SIZE x SIZE
local WIN_TILE   = 2048  -- reaching this shows the win panel; play may continue
local SPAWN_4_IN = 10    -- one spawn in SPAWN_4_IN is a 4, the rest are 2s
-- ---------------------------------------------------------------------------

Board.SIZE = SIZE
Board.WIN_TILE = WIN_TILE

-- Where the pos'th cell of `line` sits, counted from the edge the tiles pile
-- against. Collapsing a line in this order is the whole reason merge order
-- depends on direction: 4 4 4 becomes 8 4 moving left, but 4 8 moving right.
local TRAVERSE = {
  left  = function(n, line, pos) return pos, line end,
  right = function(n, line, pos) return n + 1 - pos, line end,
  up    = function(n, line, pos) return line, pos end,
  down  = function(n, line, pos) return line, n + 1 - pos end,
}

Board.DIRS = { "left", "right", "up", "down" }

-- Slides and merges every line of `grid` toward `dir`. Pure: it reads the grid
-- it is given and returns a new one, which is what lets `wouldChange` below
-- ask "does this move do anything?" without having to undo a real move.
--
-- Also returns the per-tile motion, so the host can animate the slide without
-- re-deriving it, and the merges, for the pop and the score.
local function collapse(grid, n, dir)
  local tr = TRAVERSE[dir]
  local out = {}
  for i = 1, n * n do out[i] = 0 end

  local gained, moves, merges = 0, {}, {}

  for line = 1, n do
    -- This line's tiles in travel order: nearest the destination edge first.
    local src, count = {}, 0
    for pos = 1, n do
      local x, y = tr(n, line, pos)
      local v = grid[(y - 1) * n + x]
      if v ~= 0 then
        count = count + 1
        src[count] = { v = v, x = x, y = y }
      end
    end

    local slot, i = 1, 1
    while i <= count do
      local a, b = src[i], src[i + 1]
      local dx, dy = tr(n, line, slot)

      -- When `a` and `b` pair up, `b` is consumed here and the loop skips past
      -- it, so neither tile can merge again this move. That is what stops
      -- 4 4 4 4 from collapsing all the way to 16 instead of 8 8.
      local pair = (b ~= nil and b.v == a.v)
      local value = pair and a.v * 2 or a.v

      out[(dy - 1) * n + dx] = value
      moves[#moves + 1] = { fromX = a.x, fromY = a.y, toX = dx, toY = dy, value = a.v }

      if pair then
        moves[#moves + 1] = { fromX = b.x, fromY = b.y, toX = dx, toY = dy, value = b.v }
        merges[#merges + 1] = { x = dx, y = dy, value = value }
        gained = gained + value
        i = i + 2
      else
        i = i + 1
      end
      slot = slot + 1
    end
  end

  return out, gained, moves, merges
end

local function differs(a, b, cells)
  for i = 1, cells do
    if a[i] ~= b[i] then return true end
  end
  return false
end

-- opts.rand: function(n) -> integer in [1, n]. Injectable so tests are
--            deterministic; defaults to math.random.
-- opts.best: high score carried across rounds.
-- opts.size: board edge, for tests that want a smaller board.
function Board.new(opts)
  opts = opts or {}
  local self = setmetatable({}, Board)
  self.size = opts.size or SIZE
  self.cells = self.size * self.size
  self.rand = opts.rand or function(n) return math.random(n) end
  self.best = opts.best or 0
  self:reset()
  return self
end

-- ------------------------------------------------------------------- cells --

function Board:index(x, y)
  return (y - 1) * self.size + x
end

function Board:get(x, y)
  if x < 1 or x > self.size or y < 1 or y > self.size then return nil end
  return self.grid[self:index(x, y)]
end

function Board:set(x, y, v)
  self.grid[self:index(x, y)] = v
end

function Board:emptyCount()
  local n = 0
  for i = 1, self.cells do
    if self.grid[i] == 0 then n = n + 1 end
  end
  return n
end

function Board:tileCount()
  return self.cells - self:emptyCount()
end

function Board:maxTile()
  local m = 0
  for i = 1, self.cells do
    if self.grid[i] > m then m = self.grid[i] end
  end
  return m
end

-- ------------------------------------------------------------------ rounds --

function Board:reset()
  self.grid = {}
  for i = 1, self.cells do self.grid[i] = 0 end
  self.score = 0
  self.moves = 0
  self.won = false
  self.prev = nil        -- undo snapshot; nil means nothing to undo
  self.slide = nil       -- last move's tile motion, for the host's animation
  self.merges = nil
  self.spawned = nil
  self.gained = 0
  self.state = "ready"   -- ready | playing | paused | over | won
  self:spawn()
  self:spawn()
end

-- Places a tile on a uniformly chosen empty cell: a 2 unless the second draw
-- comes up 1, which is one time in SPAWN_4_IN. Cell first, then value, so a
-- seeded rand deals the same board in tests every run.
function Board:spawn()
  local empties, count = {}, 0
  for i = 1, self.cells do
    if self.grid[i] == 0 then
      count = count + 1
      empties[count] = i
    end
  end
  if count == 0 then
    self.spawned = nil
    return false
  end

  local idx = empties[self.rand(count)]
  local value = (self.rand(SPAWN_4_IN) == 1) and 4 or 2
  self.grid[idx] = value
  self.spawned = {
    x = (idx - 1) % self.size + 1,
    y = math.floor((idx - 1) / self.size) + 1,
    value = value,
  }
  return true
end

-- ------------------------------------------------------------------- moves --

-- True if sliding toward `dir` would change the board -- which is exactly
-- what makes a move legal, and (over all four directions) what "game over"
-- means. A full board is not the same thing: a full board with two equal
-- neighbours still has a move in it.
function Board:wouldChange(dir)
  if not TRAVERSE[dir] then return false end
  local out = collapse(self.grid, self.size, dir)
  return differs(out, self.grid, self.cells)
end

function Board:canMove()
  for _, dir in ipairs(Board.DIRS) do
    if self:wouldChange(dir) then return true end
  end
  return false
end

function Board:snapshot()
  local g = {}
  for i = 1, self.cells do g[i] = self.grid[i] end
  return { grid = g, score = self.score, moves = self.moves,
           state = self.state, won = self.won }
end

function Board:recordBest()
  if self.score > self.best then self.best = self.score end
end

-- Returns changed, gained. A move that does not change the board is not a
-- move at all: no score, no spawn, no undo point, and the turn is not spent.
function Board:move(dir)
  if self.state ~= "playing" then return false, 0 end
  if not TRAVERSE[dir] then return false, 0 end

  local out, gained, moves, merges = collapse(self.grid, self.size, dir)
  if not differs(out, self.grid, self.cells) then return false, 0 end

  self.prev = self:snapshot()   -- taken before any mutation, so undo is exact
  self.grid = out
  self.score = self.score + gained
  self.gained = gained
  self.moves = self.moves + 1
  self.slide, self.merges = moves, merges
  self:spawn()
  self:recordBest()

  -- Order matters: a board with no moves left is over even if this same move
  -- was the one that reached 2048.
  if not self:canMove() then
    self.state = "over"
  elseif not self.won and self:maxTile() >= WIN_TILE then
    self.won = true
    self.state = "won"
  end

  return true, gained
end

-- One level of undo. Cheap -- a 16-entry grid copy -- and it is what makes
-- 2048 bearable on a calculator, where a mis-keyed arrow is easy.
function Board:canUndo()
  return self.prev ~= nil
end

function Board:undo()
  local p = self.prev
  if not p then return false end
  self.grid = p.grid
  self.score = p.score
  self.moves = p.moves
  self.state = p.state
  self.won = p.won
  self.prev = nil               -- one level only; no undoing the undo
  self.slide, self.merges, self.spawned = nil, nil, nil
  self.gained = 0
  return true
end

-- ------------------------------------------------------------------ states --

function Board:start()
  if self.state == "ready" then self.state = "playing" end
end

function Board:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Board:resume()
  if self.state == "paused" then self.state = "playing" end
end

-- Dismisses the win panel and plays on past 2048, as the original does.
function Board:keepPlaying()
  if self.state == "won" then self.state = "playing" end
end

function Board:isOver()
  return self.state == "over"
end

return Board
