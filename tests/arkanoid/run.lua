-- Tests for the pure Arkanoid rules. Run with:  make GAME=arkanoid test
--
-- Two things here are worth more than everything else put together.
--
-- The first is the collision fuzz. Arkanoid lives or dies on a 4-pixel ball
-- meeting a 5-pixel paddle at five pixels a frame, and the failure is not a
-- wrong bounce -- it is the ball passing clean through and the player losing a
-- life to nothing they did. `stepBall` promises that cannot happen; the sweeps
-- below fire a ball at maximum speed at a brick, at the paddle and at a wall
-- from every sub-pixel phase of a frame and check the promise directly.
--
-- The second is the level oracle. `Arkanoid.isClearable` is a flood fill the
-- game never calls, written against a generator that was built so it can never
-- fail -- so the two have to agree over every authored level and thousands of
-- generated ones, having no code in common to agree wrongly with.

package.path = (os.getenv("GAME_SRC") or "src/arkanoid") .. "/?.lua;" .. package.path
local Arkanoid = require("game")

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

local function near(got, want, tol, msg)
  if math.abs(got - want) <= tol then passed = passed + 1
  else fail(string.format("%s: got %s, want %s +/- %s",
                          msg, tostring(got), tostring(want), tostring(tol))) end
end

local function test(name, fn)
  current = name
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- helpers --

-- The playfield a handheld actually hands the rules: 318 wide, 212 minus the
-- 20px HUD tall.
local FW, FH = 318, 192
local COLS = Arkanoid.COLS

local function newGame(opts)
  opts = opts or {}
  opts.rand = opts.rand or Arkanoid.newRandom(opts.seed or 12345)
  return Arkanoid.new(opts.w or FW, opts.h or FH, opts)
end

local function playing(opts)
  local g = newGame(opts)
  g:start()
  g:fire()
  return g
end

-- Strips the board back to nothing so a test can put one brick where it wants
-- it. `remaining` is left at 1 so the caller's brick, once placed, keeps the
-- level from clearing itself out from under the test.
local function bareBoard(g)
  for r = 1, g.rows do
    for c = 1, COLS do g.bricks[r][c] = false end
  end
  g.remaining = 0
end

local function putBrick(g, r, c, kind, hp)
  g.bricks[r][c] = { kind = kind or "normal", color = 5, hp = hp or 1 }
  if kind ~= "gold" then g.remaining = g.remaining + 1 end
end

local function speedOf(b)
  return math.sqrt(b.vx * b.vx + b.vy * b.vy)
end

local function gridFromStrings(rows)
  local grid = { rows = #rows, cols = COLS }
  for r = 1, #rows do
    grid[r] = {}
    for c = 1, COLS do
      local ch = string.sub(rows[r], c, c)
      if ch == "G" then grid[r][c] = { kind = "gold", color = 0, hp = -1 }
      elseif ch == "#" then grid[r][c] = { kind = "normal", color = 1, hp = 1 }
      elseif ch == "s" then grid[r][c] = { kind = "silver", color = 0, hp = 2 }
      else grid[r][c] = false end
    end
  end
  return grid
end

-- =========================================================== the oracle ====

-- Pinned first, against boards whose answer follows from the way they are
-- drawn rather than from anything the game believes. A backwards oracle
-- agreeing with a backwards generator would prove nothing at all.
test("isClearable: pinned against hand-drawn boards", function()
  local function clearable(rows) return (Arkanoid.isClearable(gridFromStrings(rows))) end

  ok(not clearable({ ".............",
                     "............." }), "an empty board is not clearable: nothing to clear")

  ok(clearable({ "......#......" }), "one brick, in the open, is clearable")

  ok(not clearable({ "GGGGGGGGGGGGG" }), "a board of nothing but gold is not clearable")

  ok(clearable({ "GGGGGGGGGGGGG",
                 "......#......" }), "gold above a brick does not block it: the ball comes from below")

  ok(not clearable({ "......#......",
                     "GGGGGGGGGGGGG" }), "a full gold row seals off everything above it")

  ok(clearable({ "......#......",
                 "GGGGGG.GGGGGG" }), "one gap in that row is enough")

  -- The shape the generator's sublattice exists to make unrepresentable.
  ok(not clearable({ ".GGG.........",
                     ".G#G.........",
                     ".GGG........." }), "a brick ringed in gold can never be reached")

  ok(clearable({ ".G.G.........",
                 ".G#G.........",
                 ".G.G........." }), "the same ring with its corners open is fine")

  -- Diagonal gold still severs a 4-connected path, which is why the lattice
  -- rules out diagonal neighbours and not just orthogonal ones.
  ok(not clearable({ "#G...........",
                     "G............",
                     "............." }), "two gold on a diagonal seal the corner between them")

  local grid = gridFromStrings({ "##.GG", "#####" })
  local _, destructible, reached = Arkanoid.isClearable(grid)
  eq(destructible, 7, "counts destructible bricks, gold excluded")
  eq(reached, 7, "and reports how many the flood got to")
end)

test("every authored level is clearable", function()
  for i = 1, Arkanoid.AUTHORED do
    local grid = Arkanoid.buildLevel(i, Arkanoid.newRandom(1))
    local clear, destructible, reached = Arkanoid.isClearable(grid)
    ok(clear, string.format("level %d is clearable (%d of %d reachable)",
                            i, reached, destructible))
    ok(destructible > 0, "level " .. i .. " has something to break")
  end
end)

test("every authored level's rows are the right length and legal", function()
  for i, rows in ipairs(Arkanoid.LEVELS) do
    ok(#rows <= Arkanoid.MAX_ROWS, "level " .. i .. " fits in MAX_ROWS")
    for r, line in ipairs(rows) do
      eq(#line, COLS, string.format("level %d row %d is %d columns", i, r, COLS))
      for c = 1, #line do
        local ch = string.sub(line, c, c)
        ok(ch == "." or ch == "G" or ch == "s" or string.find("wocgrbmy", ch, 1, true) ~= nil,
           string.format("level %d row %d column %d: '%s' is a legal character", i, r, c, ch))
      end
    end
  end
end)

-- The generator's whole safety argument in one assertion: gold cells that
-- never touch cannot form a barrier, and a barrier is what seals a brick in.
local function goldTouches(grid)
  for r = 1, grid.rows do
    for c = 1, (grid.cols or COLS) do
      local b = grid[r][c]
      if b and b.kind == "gold" then
        for dr = -1, 1 do
          for dc = -1, 1 do
            if not (dr == 0 and dc == 0) then
              local o = grid[r + dr] and grid[r + dr][c + dc]
              if o and o.kind == "gold" then return r, c, r + dr, c + dc end
            end
          end
        end
      end
    end
  end
  return nil
end

test("no two gold bricks ever touch, authored or generated", function()
  for i = 1, Arkanoid.AUTHORED do
    local r1, c1, r2, c2 = goldTouches(Arkanoid.buildLevel(i, Arkanoid.newRandom(1)))
    ok(r1 == nil, r1 and string.format("level %d: gold at %d,%d touches %d,%d", i, r1, c1, r2, c2)
                      or ("authored level " .. i .. " keeps its gold apart"))
  end

  local checked = 0
  for seed = 1, 40 do
    local rand = Arkanoid.newRandom(seed)
    for level = Arkanoid.AUTHORED + 1, Arkanoid.AUTHORED + 25 do
      local grid = Arkanoid.generateLevel(level, rand)
      if goldTouches(grid) then
        return fail(string.format("generated level %d (seed %d) has touching gold", level, seed))
      end
      checked = checked + 1
    end
  end
  ok(true, checked .. " generated levels keep their gold apart")
end)

test("generated levels are always clearable, and always have work to do", function()
  local worst, checked = math.huge, 0
  for seed = 1, 60 do
    local rand = Arkanoid.newRandom(seed * 977)
    for level = Arkanoid.AUTHORED + 1, Arkanoid.AUTHORED + 50 do
      local grid = Arkanoid.generateLevel(level, rand)
      local clear, destructible, reached = Arkanoid.isClearable(grid)
      if not clear then
        return fail(string.format("generated level %d (seed %d): %d of %d bricks unreachable",
                                  level, seed, destructible - reached, destructible))
      end
      if grid.rows < 5 or grid.rows > 8 then
        return fail("generated level " .. level .. " has " .. grid.rows .. " rows")
      end
      -- Row 1 is what guarantees the level is never all gold: every family
      -- fills it and the gold sublattice never reaches it.
      for c = 1, COLS do
        local b = grid[1][c]
        if not b or b.kind == "gold" then
          return fail("generated level " .. level .. " row 1 column " .. c .. " is not a plain brick")
        end
      end
      if destructible < worst then worst = destructible end
      checked = checked + 1
    end
  end
  ok(true, checked .. " generated levels clearable; leanest held " .. worst .. " bricks")
end)

test("the gold sublattice really is what the generator claims", function()
  -- Independently of any level: no two allowed positions are 8-adjacent.
  local allowed = {}
  for r = 1, 12 do
    for c = 1, COLS do
      if Arkanoid.goldAllowed(r, c) then allowed[#allowed + 1] = { r, c } end
    end
  end
  ok(#allowed > 0, "the sublattice is not empty (" .. #allowed .. " cells in 12 rows)")
  for i = 1, #allowed do
    for j = i + 1, #allowed do
      local a, b = allowed[i], allowed[j]
      if math.abs(a[1] - b[1]) <= 1 and math.abs(a[2] - b[2]) <= 1 then
        return fail(string.format("%d,%d and %d,%d are neighbours", a[1], a[2], b[1], b[2]))
      end
    end
  end
  ok(true, "no two of them are 8-adjacent, so no subset can enclose anything")
  for c = 1, COLS do
    ok(not Arkanoid.goldAllowed(1, c), "row 1 column " .. c .. " can never be gold")
  end
end)

-- ========================================================= ball physics ====

test("the ball cannot pass through a brick at any speed or phase", function()
  -- Fire it up into a brick from every sub-pixel offset a frame can leave it
  -- at. If substepping were wrong, only some of these would miss.
  local misses, hits = 0, 0
  for phase = 0, 40 do
    for _, vx in ipairs({ 0, 0.8, -0.8, 1.9, -1.9 }) do
      local g = playing()
      bareBoard(g)
      local r, c = 4, 7
      putBrick(g, r, c)

      local by = g:brickY(r) + g.brickH
      local b = {
        x = g:brickX(c) + g.brickW / 2 - g.ballSize / 2,
        y = by + phase * 0.13,
        vx = vx, vy = -Arkanoid.SPEED_MAX, stuck = false, hold = 0,
      }
      g.slow = false
      g.hits = 1000            -- pin the speed at its ceiling
      g.topHit = true
      g:stepBall(b)

      if g.bricks[r][c] then
        -- Not hit: then it must not have got past the brick either.
        if b.y + g.ballSize <= g:brickY(r) + g.brickH and b.y < by then
          misses = misses + 1
        end
      else
        hits = hits + 1
        if b.vy <= 0 then misses = misses + 1 end   -- broke it but kept going up
      end
    end
  end
  ok(misses == 0, "no ball tunnelled or kept going through a brick (" .. misses .. " bad)")
  ok(hits > 120, "and the sweep really was hitting things (" .. hits .. " breaks)")
end)

test("the ball cannot pass through the paddle at any speed or phase", function()
  local escapes, saves = 0, 0
  for phase = 0, 60 do
    for _, vx in ipairs({ 0, 1.5, -1.5, 2.6, -2.6 }) do
      local g = playing()
      bareBoard(g)
      g.remaining = 1
      g.hits = 1000
      g.topHit = true

      local px = g.paddle.x
      local b = {
        x = px + g.paddle.w / 2 - g.ballSize / 2,
        y = g.padY - g.ballSize - phase * 0.1,
        vx = vx, vy = Arkanoid.SPEED_MAX, stuck = false, hold = 0,
      }
      g:stepBall(b)
      if b.dead or b.y > g.padY then escapes = escapes + 1 else saves = saves + 1 end
    end
  end
  eq(escapes, 0, "the paddle never let a ball through from directly above")
  ok(saves > 250, "and it was actually asked to (" .. saves .. " returns)")
end)

test("the ball never leaves the walls, however hard it is thrown at them", function()
  local out = 0
  for phase = 0, 40 do
    for _, dir in ipairs({ -1, 1 }) do
      local g = playing()
      bareBoard(g)
      g.remaining = 1
      g.hits = 1000
      local b = {
        x = (dir < 0) and (g:left() + phase * 0.1)
                       or (g:right() - g.ballSize - phase * 0.1),
        y = g.padY - 40,
        vx = dir * Arkanoid.SPEED_MAX, vy = -0.2, stuck = false, hold = 0,
      }
      for _ = 1, 4 do g:stepBall(b) end
      if b.x < g:left() - 0.001 or b.x + g.ballSize > g:right() + 0.001 then out = out + 1 end
      if b.y < g:top() - 0.001 then out = out + 1 end
    end
  end
  eq(out, 0, "no ball ended a step outside the playfield")
end)

test("a bounce off the paddle steers by where it landed", function()
  local g = playing()
  bareBoard(g)
  g.remaining = 1

  local function bounceFrom(fraction)
    local p = g.paddle
    local b = { x = p.x + p.w * fraction - g.ballSize / 2, y = g.padY - g.ballSize,
                vx = 0, vy = 2, stuck = false, hold = 0 }
    g:bounceOffPaddle(b)
    return b
  end

  local leftRim, middle, rightRim = bounceFrom(0.02), bounceFrom(0.5), bounceFrom(0.98)
  ok(leftRim.vx < -1, "the left rim throws the ball left (" .. string.format("%.2f", leftRim.vx) .. ")")
  ok(math.abs(middle.vx) < 0.35, "the middle sends it more or less straight up")
  ok(rightRim.vx > 1, "the right rim throws it right (" .. string.format("%.2f", rightRim.vx) .. ")")
  for _, b in ipairs({ leftRim, middle, rightRim }) do
    ok(b.vy < 0, "and every one of them goes upward")
    near(speedOf(b), g:speed(), 0.001, "the paddle changes the angle, never the speed")
  end

  -- Monotonic across the whole face: no dead spot, no reversal.
  local prev = -math.huge
  for i = 0, 20 do
    local b = bounceFrom(i / 20)
    ok(b.vx >= prev - 1e-9, "landing further right never steers further left")
    prev = b.vx
  end
end)

test("no trajectory is flat enough to stall the rally", function()
  local g = playing()
  for _, v in ipairs({ { 5, 0.001 }, { -5, -0.001 }, { 3, 0 }, { -0.2, 0.05 } }) do
    local b = { vx = v[1], vy = v[2] }
    local before = speedOf(b)
    Arkanoid.steepen(b)
    if before > 1e-9 then
      near(speedOf(b), before, 1e-6, "steepening preserves the speed exactly")
      ok(math.abs(b.vy) >= Arkanoid.MIN_VY_FRAC * before - 1e-9,
         "and leaves enough vertical speed to make progress")
    end
  end
end)

test("a long fuzzed rally never breaks a physical invariant", function()
  local checks, frames = 0, 0
  for seed = 1, 6 do
    local rand = Arkanoid.newRandom(seed * 31 + 7)
    local g = playing({ rand = rand, seed = seed })

    for i = 1, 3500 do
      -- A player who is roughly, but not exactly, tracking the ball.
      local t
      for _, b in ipairs(g.balls) do if not t or b.y > t.y then t = b end end
      if t then g:aim(t.x + rand(19) - 10) end
      if i % 9 == 0 then g:steer(rand(2) == 1 and -1 or 1) end
      if i % 13 == 0 then g:fire() end

      g:step()
      frames = frames + 1

      if g.state == "cleared" then g:nextLevel() end
      if g.state == "serve" then g:fire() end
      if g.state == "over" then g:reset(1); g:start(); g:fire() end

      -- Paddle.
      local p = g.paddle
      if p.x < g:left() - 1e-9 or p.x + p.w > g:right() + 1e-9 then
        return fail(string.format("seed %d frame %d: paddle at %.2f escaped the walls", seed, i, p.x))
      end

      -- Balls.
      for _, b in ipairs(g.balls) do
        checks = checks + 1
        if not b.stuck then
          if b.x < g:left() - 1e-9 or b.x + g.ballSize > g:right() + 1e-9
             or b.y < g:top() - 1e-9 then
            return fail(string.format("seed %d frame %d: ball outside at %.2f,%.2f", seed, i, b.x, b.y))
          end
          if g:brickUnder(b.x, b.y, g.ballSize, g.ballSize, "y", 1) then
            return fail(string.format("seed %d frame %d: ball inside a brick at %.2f,%.2f", seed, i, b.x, b.y))
          end
          if Arkanoid.overlap(b.x, b.y, g.ballSize, g.ballSize, p.x, g.padY, p.w, g.padH) then
            return fail(string.format("seed %d frame %d: ball inside the paddle", seed, i))
          end
          local sp = speedOf(b)
          if sp > Arkanoid.SPEED_MAX + 1e-6 then
            return fail(string.format("seed %d frame %d: ball at %.3f exceeds the speed cap", seed, i, sp))
          end
          if math.abs(b.vy) < Arkanoid.MIN_VY_FRAC * sp - 1e-6 then
            return fail(string.format("seed %d frame %d: trajectory too flat (vy %.3f of %.3f)",
                                      seed, i, b.vy, sp))
          end
          -- A Slow capsule caught this frame moves the target 30%, so this
          -- brackets the ball rather than chasing the frame's exact figure:
          -- what a bug would look like is a ball quietly losing its energy.
          if sp < 2.4 then
            return fail(string.format("seed %d frame %d: ball has gone limp at %.3f", seed, i, sp))
          end
        end
      end

      -- The remaining counter is a cache of a full scan; they must agree.
      if i % 250 == 0 then
        local scan = 0
        for r = 1, g.rows do
          for c = 1, COLS do
            local b = g.bricks[r][c]
            if b and b.kind ~= "gold" then scan = scan + 1 end
          end
        end
        if scan ~= g.remaining then
          return fail(string.format("seed %d frame %d: remaining says %d, board holds %d",
                                    seed, i, g.remaining, scan))
        end
      end
    end
  end
  ok(true, string.format("%d frames, %d ball-checks, no invariant broken", frames, checks))
end)

test("balls held on the paddle ride with it and never drift off", function()
  local g = newGame()
  g:start()
  eq(g.state, "serve", "a new round waits on the serve")
  eq(#g.balls, 1, "with one ball")
  ok(g.balls[1].stuck, "and it is sitting on the paddle")

  for i = 1, 200 do
    g:steer(i < 100 and -1 or 1)
    g:step()
    local b = g.balls[1]
    ok(b.stuck, "still held")
    ok(b.x >= g:left() - 1e-9 and b.x + g.ballSize <= g:right() + 1e-9,
       "and still inside the walls")
    if not b.stuck then break end
  end
  eq(g.state, "serve", "and the game did not start on its own")

  ok(g:fire(), "firing serves")
  eq(g.state, "playing", "which starts play")
  ok(g.balls[1].vy < 0, "the ball leaves upward")
end)

-- =============================================================== bricks ====

test("bricks take the right number of hits and pay the right score", function()
  local g = playing()
  bareBoard(g)

  putBrick(g, 2, 2, "normal")
  g.bricks[2][2].color = 8            -- yellow, the 120-point ink
  local before = g.score
  ok(g:hitBrick(2, 2), "a plain brick breaks in one")
  eq(g.score - before, 120, "and pays its colour's score")
  eq(g.bricks[2][2], false, "and is gone")

  local hp = Arkanoid.silverHP(g.level)
  putBrick(g, 3, 3, "silver", hp)
  for i = 1, hp - 1 do
    ok(not g:hitBrick(3, 3), "silver survives hit " .. i)
    ok(g.bricks[3][3] ~= false, "and is still there")
  end
  ok(g:hitBrick(3, 3), "and breaks on hit " .. hp)

  putBrick(g, 4, 4, "gold")
  local goldScore = g.score
  for _ = 1, 30 do
    ok(not g:hitBrick(4, 4), "gold never breaks")
  end
  eq(g.score, goldScore, "and never pays")
  ok(g.bricks[4][4] ~= false, "and is still standing after thirty hits")
end)

test("silver bricks get tougher deeper in", function()
  eq(Arkanoid.silverHP(1), 2, "level 1 silver takes two")
  eq(Arkanoid.silverHP(8), 2, "and so does level 8")
  eq(Arkanoid.silverHP(9), 3, "level 9 takes three")
  eq(Arkanoid.silverHP(17), 4, "level 17 takes four")
  local prev = 0
  for level = 1, 60 do
    local hp = Arkanoid.silverHP(level)
    ok(hp >= prev, "never gets easier at level " .. level)
    prev = hp
  end
end)

test("only gold counts against clearing the level", function()
  local g = playing({ seed = 4 })
  local grid = Arkanoid.buildLevel(5, g.rand)     -- "Rivets": the gold level
  g.bricks, g.rows = grid, grid.rows
  local gold, destructible = 0, 0
  for r = 1, g.rows do
    for c = 1, COLS do
      local b = g.bricks[r][c]
      if b and b.kind == "gold" then gold = gold + 1
      elseif b then destructible = destructible + 1 end
    end
  end
  ok(gold > 0, "the level really does have gold in it (" .. gold .. ")")
  g.remaining = destructible
  g.startRemaining = destructible

  for r = 1, g.rows do
    for c = 1, COLS do
      local b = g.bricks[r][c]
      if b and b.kind ~= "gold" then
        for _ = 1, 6 do g:hitBrick(r, c) end
      end
    end
  end
  eq(g.remaining, 0, "breaking everything breakable clears the level")
  local left = 0
  for r = 1, g.rows do
    for c = 1, COLS do if g.bricks[r][c] then left = left + 1 end end
  end
  eq(left, gold, "and leaves exactly the gold behind")
end)

-- ============================================================= capsules ====

test("each capsule does what its letter says", function()
  local g = playing()

  g:applyCapsule("wide")
  eq(g.power, "wide", "E takes the Enlarge slot")
  ok(g:paddleWidth() > g.baseW, "and the paddle is wider")

  g:applyCapsule("laser")
  eq(g.power, "laser", "L replaces it")
  eq(g:paddleWidth(), g.baseW, "and the paddle goes back to normal width")

  local before = g.lives
  g:applyCapsule("life")
  eq(g.lives, before + 1, "P is an extra life")
  eq(g.power, "laser", "and does not disturb the paddle")

  local fast = g:speed()
  g:applyCapsule("slow")
  ok(g:speed() < fast, "S slows the ball down (" .. string.format("%.2f -> %.2f", fast, g:speed()) .. ")")

  eq(#g.balls, 1, "one ball to start")
  g:applyCapsule("split")
  eq(#g.balls, Arkanoid.MAX_BALLS, "D splits it up to the cap")
  g:step()          -- the ball already in flight is renormalised on its own step
  for _, b in ipairs(g.balls) do
    ok(not b.stuck, "and every ball is in play")
    near(speedOf(b), g:speed(), 1e-6, "at the right speed")
    ok(math.abs(b.vy) >= Arkanoid.MIN_VY_FRAC * speedOf(b) - 1e-9, "and a usable angle")
  end
  g:applyCapsule("split")
  eq(#g.balls, Arkanoid.MAX_BALLS, "and splitting again cannot go past the cap")
end)

test("an extra life is capped, and Enlarge cannot push the paddle through a wall", function()
  local g = playing()
  for _ = 1, 40 do g:applyCapsule("life") end
  ok(g.lives <= 6, "lives are bounded (" .. g.lives .. ")")

  for _, side in ipairs({ "left", "right" }) do
    local h = playing()
    for _ = 1, 200 do
      h:steer(side == "left" and -1 or 1)
      h:step()
    end
    h:applyCapsule("wide")
    h:step()
    ok(h.paddle.x >= h:left() - 1e-9, side .. ": still inside the left wall")
    ok(h.paddle.x + h.paddle.w <= h:right() + 1e-9, side .. ": still inside the right wall")
  end
end)

test("Catch holds the ball and hands it back", function()
  local g = playing()
  g:applyCapsule("catch")
  local b = g.balls[1]
  b.stuck = false
  b.x = g.paddle.x + g.paddle.w / 2
  b.y = g.padY - g.ballSize
  b.vx, b.vy = 0, 2
  g:bounceOffPaddle(b)
  ok(b.stuck, "the ball is caught")
  eq(b.vx, 0, "and stops dead")

  ok(g:fire(), "firing lets it go")
  ok(not g.balls[1].stuck, "and it is away")

  -- And it lets go by itself rather than waiting forever on a player who has
  -- not realised the ball is theirs to release.
  local h = playing()
  h:applyCapsule("catch")
  local c = h.balls[1]
  c.stuck = false; c.x = h.paddle.x + h.paddle.w / 2; c.y = h.padY - h.ballSize
  c.vx, c.vy = 0, 2
  h:bounceOffPaddle(c)
  ok(c.stuck, "caught again")
  for _ = 1, 200 do
    h:step()
    if not h.balls[1] or not h.balls[1].stuck then break end
  end
  ok(h.balls[1] and not h.balls[1].stuck, "and released itself within a few seconds")
end)

test("the laser only fires when it is armed, and only so fast", function()
  local g = playing()
  eq(#g.bullets, 0, "no bullets to begin with")
  g:fire()
  eq(#g.bullets, 0, "and firing without the capsule shoots nothing")

  g:applyCapsule("laser")
  ok(g:fire(), "armed, firing works")
  eq(#g.bullets, 2, "two barrels, two bullets")
  g:fire()
  eq(#g.bullets, 2, "and it will not fire again on the next frame")

  for _ = 1, 20 do g:step() end
  local rearmed = false
  for _ = 1, 20 do
    g:step()
    if g:fire() then rearmed = true break end
  end
  ok(rearmed, "but it does rearm")
end)

test("a bullet breaks the brick above it and stops there", function()
  local g = playing()
  bareBoard(g)
  local r, c = g.rows, 7
  putBrick(g, r, c)
  putBrick(g, r - 1, c)            -- a second one directly behind the first

  g.bullets = { { x = g:brickX(c) + g.brickW / 2, y = g:brickY(r) + g.brickH + 2 } }
  for _ = 1, 6 do g:stepBullets() end
  eq(g.bricks[r][c], false, "the near brick broke")
  ok(g.bricks[r - 1][c] ~= false, "the one behind it did not: a bullet is spent on one brick")
  eq(#g.bullets, 0, "and the bullet is gone")
end)

test("capsules fall, are caught by the paddle, and expire off the bottom", function()
  local g = playing()
  g.capsules = { { kind = "wide", x = g.paddle.x, y = g.padY - 40 } }
  local caught = false
  for _ = 1, 200 do
    g:stepCapsules()
    if g.power == "wide" then caught = true break end
  end
  ok(caught, "a capsule dropped onto the paddle is caught")
  eq(#g.capsules, 0, "and leaves the screen")

  local h = playing()
  h.capsules = { { kind = "wide", x = h:left() + 1, y = 0 } }
  for _ = 1, 400 do h:stepCapsules() end
  eq(#h.capsules, 0, "one that misses falls off the bottom")
  eq(h.power, nil, "without being collected")
end)

test("no more than a handful of capsules are ever on screen", function()
  local worst = 0
  for seed = 1, 8 do
    local g = playing({ rand = Arkanoid.newRandom(seed), seed = seed })
    for i = 1, 2500 do
      local t
      for _, b in ipairs(g.balls) do if not t or b.y > t.y then t = b end end
      if t then g:aim(t.x) end
      g:step()
      if g.state == "cleared" then g:nextLevel() end
      if g.state == "serve" then g:fire() end
      if g.state == "over" then break end
      if #g.capsules > worst then worst = #g.capsules end
    end
  end
  ok(worst <= Arkanoid.MAX_CAPSULES,
     "peak capsules on screen was " .. worst .. ", cap is " .. Arkanoid.MAX_CAPSULES)
  ok(worst > 0, "and capsules do actually drop")
end)

-- =============================================================== paddle ====

test("a tap nudges and coasts; holding the key keeps going", function()
  -- Driven from the serve rather than from play: `step` moves the paddle there
  -- too, and a ball lost mid-test would recentre the paddle under the assertion.
  local g = newGame()
  g:start()
  local start = g.paddle.x

  g:steer(1)
  for _ = 1, 40 do g:step() end
  local afterTap = g.paddle.x
  ok(afterTap > start + 8, "one tap moved the paddle a useful distance ("
     .. string.format("%.1f", afterTap - start) .. " px)")
  local settled = g.paddle.x
  for _ = 1, 40 do g:step() end
  near(g.paddle.x, settled, 0.01, "then it stopped rather than sliding forever")

  -- What the OS's auto-repeat looks like: an event every few frames.
  local h = newGame()
  h:start()
  local from = h.paddle.x
  for i = 1, 40 do
    if i % 3 == 0 then h:steer(1) end
    h:step()
  end
  ok(h.paddle.x - from > (afterTap - start) * 2,
     "a held key travels much further than a tap")
end)

test("a click aims and the paddle drives there without overshooting", function()
  local g = newGame()
  g:start()
  local want = g:left() + 40
  g:aim(want)
  for _ = 1, 200 do g:step() end
  near(g.paddle.x + g.paddle.w / 2, want, 6, "the paddle arrived under the click")

  -- Off the end of the world: it should pin to the wall, not wander.
  g:aim(-500)
  for _ = 1, 200 do g:step() end
  near(g.paddle.x, g:left(), 0.01, "aiming past the left wall parks it on the wall")
  g:aim(99999)
  for _ = 1, 200 do g:step() end
  near(g.paddle.x + g.paddle.w, g:right(), 0.01, "and past the right wall, on that one")
end)

test("steering is ignored when the game is not being played", function()
  local g = newGame()
  eq(g.state, "ready", "a fresh game is on the title screen")
  ok(not g:steer(-1), "which does not steer")
  ok(not g:aim(100), "and does not aim")
  g:start(); g:fire()
  ok(g:steer(-1), "playing does")
  g:pause()
  ok(not g:steer(1), "paused does not")
  local x = g.paddle.x
  for _ = 1, 50 do g:step() end
  near(g.paddle.x, x, 1e-9, "and nothing moves while paused")
end)

-- ================================================== rounds, lives, levels ====

test("losing every ball costs a life and takes the powers with it", function()
  local g = playing()
  g:applyCapsule("wide")
  g:applyCapsule("slow")
  g.capsules = { { kind = "life", x = 20, y = 20 } }
  local lives = g.lives

  -- Send the only ball out through the floor.
  g.balls[1].stuck = false
  g.balls[1].y = g.h - 1
  g.balls[1].vy = Arkanoid.SPEED_MAX
  g.balls[1].vx = 0
  g:step()

  eq(g.lives, lives - 1, "a life is gone")
  eq(g.state, "serve", "and the game waits to serve again")
  eq(g.power, nil, "the paddle powers went with it")
  eq(g.slow, false, "so did the slow ball")
  eq(#g.capsules, 0, "and the capsules still falling")
  eq(#g.balls, 1, "with a fresh ball on the paddle")
  ok(g.balls[1].stuck, "waiting")
end)

test("running out of lives ends the game and books the score", function()
  local g = playing()
  g.score = 4321
  for _ = 1, Arkanoid.START_LIVES do
    for _, b in ipairs(g.balls) do
      b.stuck = false; b.y = g.h - 1; b.vy = Arkanoid.SPEED_MAX; b.vx = 0
    end
    g:step()
    if g.state == "serve" then g:fire() end
  end
  eq(g.state, "over", "the game is over")
  eq(g.lives, 0, "with no lives left")
  eq(g.highScore, 4321, "and the score was recorded")

  local h = Arkanoid.new(FW, FH, { rand = Arkanoid.newRandom(3), highScore = 9999 })
  h:start(); h:fire()
  h.score = 10
  h:recordScore()
  eq(h.highScore, 9999, "a smaller score does not overwrite a better one")
end)

test("clearing a level pays the bonus and deals the next one", function()
  local g = playing()
  bareBoard(g)
  putBrick(g, 2, 2)
  local before, level = g.score, g.level

  g:hitBrick(2, 2)
  g:step()
  eq(g.state, "cleared", "the board is clear")
  eq(g.score - before, 90 + 500 * level, "the last brick plus the level bonus")

  ok(g:nextLevel(), "and the next level deals")
  eq(g.level, level + 1, "which is the one after")
  eq(g.state, "serve", "waiting on a serve")
  ok(g.remaining > 0, "with a wall to break")
  ok(not g:nextLevel(), "advancing twice from one clear does nothing")
end)

test("clearing the last brick beats losing the last ball in the same frame", function()
  -- Both things happen on the one frame: the wall is already down and the only
  -- ball goes past the paddle. The level was won before the ball was lost, so
  -- charging a life here would take one for a round that was already over.
  local g = playing()
  bareBoard(g)                       -- remaining is now 0: the wall is clear
  local b = g.balls[1]
  b.stuck = false
  b.x = g.paddle.x + g.paddle.w / 2
  b.y = g.h - 1
  b.vx, b.vy = 0, Arkanoid.SPEED_MAX

  g:step()
  eq(g.state, "cleared", "the level cleared rather than costing a life")
  eq(g.lives, Arkanoid.START_LIVES, "and every life is intact")
end)

test("a step leaves every ball travelling at exactly the level's speed", function()
  local g = playing()
  bareBoard(g)
  g.remaining = 1
  for _, start in ipairs({ { 3.1, -1.2 }, { -0.4, 4.9 }, { 0.01, -0.02 }, { -6, 6 } }) do
    local b = { x = g.w / 2, y = g.padY - 60, vx = start[1], vy = start[2],
                stuck = false, hold = 0 }
    g:stepBall(b)
    if not b.dead then
      near(speedOf(b), g:speed(), 1e-9,
           string.format("a ball entering at (%.2f,%.2f) leaves at the level's speed",
                         start[1], start[2]))
    end
  end

  -- ... including one that was standing still, which would otherwise divide by
  -- zero on its way to being normalised.
  local dead = { x = g.w / 2, y = g.padY - 60, vx = 0, vy = 0, stuck = false, hold = 0 }
  g:stepBall(dead)
  ok(dead.x == g.w / 2 and dead.y == g.padY - 60, "a motionless ball simply does not move")
end)

test("the ball speeds up over a level and never past the cap", function()
  local g = playing()
  local opening = g:speed()
  g.hits = 500
  ok(g:speed() > opening, "a long rally winds it up")
  g.topHit = true
  ok(g:speed() <= Arkanoid.SPEED_MAX + 1e-9, "but never past the cap")

  local deep = Arkanoid.new(FW, FH, { rand = Arkanoid.newRandom(2), level = 30 })
  deep:start()
  ok(deep:speed() >= opening, "and a deeper level opens no slower")
  ok(deep:speed() <= Arkanoid.SPEED_MAX + 1e-9, "still under the cap")

  local slow = playing()
  local fast = slow:speed()
  slow.slow = true
  ok(slow:speed() < fast, "the Slow capsule still bites at every level")
end)

test("pause freezes the world and resume puts it back", function()
  local g = playing()
  for _ = 1, 25 do g:step() end
  local b = g.balls[1]
  local x, y, level = b.x, b.y, g.level
  g:pause()
  eq(g.state, "paused", "paused")
  for _ = 1, 80 do g:step() end
  near(g.balls[1].x, x, 1e-9, "the ball did not move")
  near(g.balls[1].y, y, 1e-9, "in either direction")
  g:resume()
  eq(g.state, "playing", "resumed into play, not into a serve")
  eq(g.level, level, "on the same level")
  for _ = 1, 10 do g:step() end
  ok(g.balls[1].x ~= x or g.balls[1].y ~= y, "and it is moving again")

  -- Pausing during a serve comes back to the serve, not to play.
  local h = newGame()
  h:start()
  h:pause()
  h:resume()
  eq(h.state, "serve", "a paused serve resumes as a serve")
end)

-- ================================================================== RNG ====

test("the generator is owned, deterministic and spread", function()
  local a, b = Arkanoid.newRandom(99), Arkanoid.newRandom(99)
  for _ = 1, 200 do eq(a(1000), b(1000), "the same seed replays exactly") end

  local r = Arkanoid.newRandom(5)
  local lo, hi = math.huge, -math.huge
  for _ = 1, 20000 do
    local v = r(6)
    if v < lo then lo = v end
    if v > hi then hi = v end
    if v ~= math.floor(v) then return fail("rand returned a non-integer: " .. tostring(v)) end
  end
  eq(lo, 1, "rand(6) never goes below 1")
  eq(hi, 6, "and never above 6")

  -- The bug this exists to prevent: two launches of the document differ by a
  -- few idle ticks, so neighbouring seeds must not deal the same round.
  local seen = {}
  for seed = 1, 12 do
    local rr = Arkanoid.newRandom(seed)
    local key = {}
    for i = 1, 8 do key[i] = rr(100) end
    key = table.concat(key, ",")
    ok(seen[key] == nil, "seed " .. seed .. " deals differently from seed " .. tostring(seen[key]))
    seen[key] = seed
  end

  local acc = 1
  for i = 1, 500 do acc = Arkanoid.mix(acc, i) end
  ok(acc > 0 and acc < 2147483647 and acc == math.floor(acc),
     "mix stays an exact integer inside the modulus (" .. acc .. ")")
  ok(Arkanoid.mix(1, 5) ~= Arkanoid.mix(1, 6), "and different inputs fold differently")
end)

test("two games from the same seed play identically", function()
  local function run(seed)
    local g = playing({ rand = Arkanoid.newRandom(seed), seed = seed })
    for i = 1, 900 do
      local t
      for _, b in ipairs(g.balls) do if not t or b.y > t.y then t = b end end
      if t then g:aim(t.x) end
      g:step()
      if g.state == "cleared" then g:nextLevel() end
      if g.state == "serve" then g:fire() end
    end
    return string.format("%d/%d/%d/%d", g.score, g.level, g.remaining, #g.capsules)
  end
  eq(run(777), run(777), "same seed, same game")
  ok(run(777) ~= run(778), "a different seed is a different game")
end)

-- ============================================================= geometry ====

test("the layout survives every window the software can produce", function()
  local sizes = {
    { 318, 192 }, { 320, 220 }, { 240, 140 }, { 160, 100 },
    { 120, 70 }, { 640, 460 }, { 900, 680 }, { 480, 180 }, { 200, 460 },
  }
  for _, s in ipairs(sizes) do
    local g = Arkanoid.new(s[1], s[2], { rand = Arkanoid.newRandom(11) })
    local label = string.format("%dx%d", s[1], s[2])
    g:start(); g:fire()

    ok(g.brickW >= 2 and g.brickH >= 2, label .. ": bricks have a size")
    ok(g.fieldX >= g:left(), label .. ": the wall does not sit on the bricks")
    ok(g.fieldX + g.fieldW <= g:right(), label .. ": nor does the right one")
    ok(g:brickY(g.rows) + g.brickH <= g.padY,
       label .. ": the bottom row is above the paddle")
    ok(g.padY + g.padH <= g.h, label .. ": the paddle is on the screen")
    ok(g.paddle.w <= g:right() - g:left(), label .. ": the paddle fits between the walls")
    ok(g.wideW > g.baseW, label .. ": Enlarge is still an enlargement")
    ok(g.ballSize >= 2, label .. ": the ball is visible")

    for i = 1, 400 do
      if i % 7 == 0 then g:steer(i % 14 == 0 and -1 or 1) end
      g:step()
      if g.state == "cleared" then g:nextLevel() end
      if g.state == "serve" then g:fire() end
      if g.state == "over" then break end
      for _, b in ipairs(g.balls) do
        if not b.stuck and (b.x < g:left() - 1e-9
            or b.x + g.ballSize > g:right() + 1e-9 or b.y < g:top() - 1e-9) then
          return fail(label .. ": ball escaped at frame " .. i)
        end
      end
    end
    passed = passed + 1
  end
end)

test("a deep run keeps dealing playable levels", function()
  local rand = Arkanoid.newRandom(2024)
  local g = Arkanoid.new(FW, FH, { rand = rand })
  for level = 1, 120 do
    g:loadLevel(level)
    ok(g.remaining > 0, "level " .. level .. " has bricks to break")
    ok(g.rows >= 1 and g.rows <= Arkanoid.MAX_ROWS, "level " .. level .. " has a legal row count")
    local clear = Arkanoid.isClearable(g.bricks)
    if not clear then return fail("level " .. level .. " is not clearable") end
    ok(g:brickY(g.rows) + g.brickH <= g.padY, "level " .. level .. " fits above the paddle")
  end
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
