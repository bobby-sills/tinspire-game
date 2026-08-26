-- game.lua -- pure Snake game logic.
--
-- This module deliberately knows nothing about the TI-Nspire: no `platform`,
-- no `gc`, no `timer`. That keeps it runnable under a plain Lua 5.1
-- interpreter on a laptop, so the rules can be tested without a calculator.
-- All drawing and input lives in src/main.lua.

local Game = {}
Game.__index = Game

local DIRS = {
  up    = { x =  0, y = -1 },
  down  = { x =  0, y =  1 },
  left  = { x = -1, y =  0 },
  right = { x =  1, y =  0 },
}
Game.DIRS = DIRS

local START_LEN       = 4   -- segments the snake starts with
local GROW_PER_FOOD   = 2   -- segments gained per apple
local FOODS_PER_LEVEL = 4   -- apples needed to speed up
local QUEUE_MAX       = 3   -- buffered turns, so fast double-taps register

-- Ticks of the host timer to wait between moves, indexed by level. The host
-- runs a fixed fast timer and counts ticks rather than restarting the timer
-- at a new interval, because timer granularity varies between Nspire OSes.
local STEP_TICKS = { 4, 4, 3, 3, 2, 2, 2, 1, 1, 1 }

Game.MAX_LEVEL = #STEP_TICKS
Game.START_LEN = START_LEN
Game.GROW_PER_FOOD = GROW_PER_FOOD
Game.FOODS_PER_LEVEL = FOODS_PER_LEVEL

-- cols, rows: playfield size in cells.
-- opts.rand:      function(n) -> integer in [1, n]. Injectable for tests.
-- opts.wrap:      true = edges wrap around, false = edges kill.
-- opts.highScore: carried across rounds.
function Game.new(cols, rows, opts)
  opts = opts or {}
  local self = setmetatable({}, Game)
  self.cols = cols
  self.rows = rows
  self.rand = opts.rand or function(n) return math.random(n) end
  self.wrap = opts.wrap or false
  self.highScore = opts.highScore or 0
  self:reset()
  return self
end

-- Cells are stored in a deque (`cells` indexed by `tail`..`head`) rather than
-- an array we shift, so growing the snake stays O(1) per move even when it is
-- hundreds of segments long. `occupied` mirrors it as a set for O(1) hit tests.
function Game:cellKey(x, y)
  return (y - 1) * self.cols + x
end

function Game:length()
  return self.head - self.tail + 1
end

function Game:pushFront(x, y)
  self.head = self.head + 1
  self.cells[self.head] = { x = x, y = y }
  self.occupied[self:cellKey(x, y)] = true
end

function Game:popBack()
  local c = self.cells[self.tail]
  self.cells[self.tail] = nil
  self.tail = self.tail + 1
  self.occupied[self:cellKey(c.x, c.y)] = nil
  return c
end

-- Segments head-first. Convenient for tests; the renderer walks the deque
-- directly to avoid allocating a table every frame.
function Game:segments()
  local out = {}
  for i = self.head, self.tail, -1 do
    out[#out + 1] = self.cells[i]
  end
  return out
end

function Game:reset()
  self.cells = {}
  self.occupied = {}
  self.head, self.tail = 0, 1 -- empty deque: length == 0
  self.queue = {}
  self.growth = 0
  self.score = 0
  self.foodEaten = 0
  self.level = 1
  self.state = "ready" -- ready | playing | paused | over | won
  self.dir = DIRS.right

  local cy = math.ceil(self.rows / 2)
  local sx = math.max(START_LEN, math.floor(self.cols / 4))
  -- Build tail-first so the final pushFront leaves the head at sx.
  for i = START_LEN - 1, 0, -1 do
    self:pushFront(sx - i, cy)
  end

  self:spawnFood()
end

-- Places food on a random free cell. Rejection sampling is fast while the
-- board is mostly empty; once it fills up we index directly into the free
-- cells instead, so a nearly-complete game can't spin here.
function Game:spawnFood()
  local total = self.cols * self.rows
  local free = total - self:length()
  if free <= 0 then
    self.food = nil
    return false
  end

  if free > total * 0.25 then
    for _ = 1, 40 do
      local x, y = self.rand(self.cols), self.rand(self.rows)
      if not self.occupied[self:cellKey(x, y)] then
        self.food = { x = x, y = y }
        return true
      end
    end
  end

  local n = self.rand(free)
  for y = 1, self.rows do
    for x = 1, self.cols do
      if not self.occupied[self:cellKey(x, y)] then
        n = n - 1
        if n == 0 then
          self.food = { x = x, y = y }
          return true
        end
      end
    end
  end

  self.food = nil
  return false
end

function Game:ticksPerStep()
  return STEP_TICKS[self.level] or 1
end

function Game:start()
  if self.state == "ready" then self.state = "playing" end
end

function Game:pause()
  if self.state == "playing" then self.state = "paused" end
end

function Game:resume()
  if self.state == "paused" then self.state = "playing" end
end

function Game:isOver()
  return self.state == "over" or self.state == "won"
end

function Game:recordScore()
  if self.score > self.highScore then self.highScore = self.score end
end

-- Queues a turn. Reversals are rejected against the last *queued* direction
-- rather than the current one, so pressing up-then-right inside a single tick
-- turns the corner instead of the second press being read as a reversal.
function Game:setDirection(name)
  local d = DIRS[name]
  if not d then return false end
  if self.state ~= "playing" then return false end
  if #self.queue >= QUEUE_MAX then return false end

  local last = self.queue[#self.queue] or self.dir
  if d.x == last.x and d.y == last.y then return false end
  if self:length() > 1 and d.x == -last.x and d.y == -last.y then return false end

  self.queue[#self.queue + 1] = d
  return true
end

function Game:step()
  if self.state ~= "playing" then return end

  if #self.queue > 0 then
    self.dir = table.remove(self.queue, 1)
  end

  local h = self.cells[self.head]
  local nx, ny = h.x + self.dir.x, h.y + self.dir.y

  if self.wrap then
    if nx < 1 then nx = self.cols elseif nx > self.cols then nx = 1 end
    if ny < 1 then ny = self.rows elseif ny > self.rows then ny = 1 end
  elseif nx < 1 or nx > self.cols or ny < 1 or ny > self.rows then
    self.state = "over"
    self:recordScore()
    return
  end

  -- The tail cell is fair game when the tail is about to vacate it this move,
  -- which is what lets the snake follow its own tail without dying.
  local vacating = (self.growth == 0) and self:length() > 1
  local tailCell = self.cells[self.tail]
  local blocked = self.occupied[self:cellKey(nx, ny)] or false
  if blocked and vacating and nx == tailCell.x and ny == tailCell.y then
    blocked = false
  end
  if blocked then
    self.state = "over"
    self:recordScore()
    return
  end

  if vacating then
    self:popBack()
  elseif self.growth > 0 then
    self.growth = self.growth - 1
  end
  self:pushFront(nx, ny)

  if self.food and nx == self.food.x and ny == self.food.y then
    self.growth = self.growth + GROW_PER_FOOD
    self.foodEaten = self.foodEaten + 1
    self.score = self.score + 10 * self.level
    self.level = math.min(Game.MAX_LEVEL, 1 + math.floor(self.foodEaten / FOODS_PER_LEVEL))
    if not self:spawnFood() then
      self.state = "won"
      self:recordScore()
    end
  end
end

return Game
