-- Tests for the pure Flappy Bird logic. Run with:  make test
-- (or: lua tests/run_flappy.lua   from the repo root)

package.path = "src/?.lua;" .. package.path
local Flappy = require("flappy")

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
  else fail(string.format("%s: got %s, want %s +/- %s", msg, tostring(got), tostring(want), tostring(tol))) end
end

local function test(name, fn)
  current = name
  local success, err = pcall(fn)
  if not success then fail("error: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- helpers --

-- Park-Miller with Schrage's trick. A textbook 32-bit LCG is *wrong* in Lua
-- 5.1: `1103515245 * s` runs past 2^53 and the double silently drops the low
-- bits, so every seed collapses onto the same stream and a "randomised" test
-- only ever exercises one course. Every intermediate below stays under 2^31.
local function seededRand(seed)
  local s = (seed or 1) % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    local hi = math.floor(s / 127773)
    local lo = s % 127773
    s = 16807 * lo - 2836 * hi
    if s <= 0 then s = s + 2147483647 end
    return (s % n) + 1
  end
end

-- The playfield a handheld actually hands the rules: 318 wide, 212 minus the
-- 22px HUD tall.
local FW, FH = 318, 190

local function newGame(w, h, opts)
  opts = opts or {}
  opts.rand = opts.rand or seededRand(12345)
  return Flappy.new(w or FW, h or FH, opts)
end

local function playing(opts)
  local g = newGame(nil, nil, opts)
  g:start()
  return g
end

-- Flap when the bird is below where it needs to be. Deliberately the crudest
-- controller that could work -- no lookahead, no damping -- because a course
-- that this can fly is a course a person can fly with room to spare.
local function autopilot(g)
  local p = g:nextPipe()
  local target = p and (p.gapTop + p.gap / 2) or (g:groundY() / 2)
  if g:birdCenterY() > target then g:flap() end
end

-- ------------------------------------------------------------ basic shape --

test("starts in a sane state", function()
  local g = newGame()
  eq(g.state, "ready", "starts ready")
  eq(g.score, 0, "no score yet")
  ok(#g.pipes >= 1, "a pipe is already queued")
  ok(g.bird.y > 0 and g.bird.y + Flappy.BIRD_H < g:groundY(), "bird starts in open sky")
  eq(g.bird.v, 0, "bird starts at rest")
end)

test("step does nothing unless playing", function()
  local g = newGame()
  local y0 = g.bird.y
  for _ = 1, 20 do g:step() end
  eq(g.bird.y, y0, "ready: bird does not move")
  eq(g.frame, 0, "ready: no frames advanced")

  g:start(); g:step(); g:pause()
  local y1 = g.bird.y
  for _ = 1, 20 do g:step() end
  eq(g.bird.y, y1, "paused: bird does not move")
end)

test("pause, resume and game-over transitions", function()
  local g = playing()
  g:pause();  eq(g.state, "paused", "pause from playing")
  g:resume(); eq(g.state, "playing", "resume from paused")
  g:pause();  g:start()
  eq(g.state, "paused", "start does not un-pause")
  g:resume()

  -- Fall to the ground without ever flapping.
  for _ = 1, 500 do g:step() end
  eq(g.state, "over", "hits the ground eventually")
  ok(g:isOver(), "isOver agrees")
  local frame = g.frame
  for _ = 1, 20 do g:step() end
  eq(g.frame, frame, "over: no further frames")
end)

-- ------------------------------------------------------------- physics ---- --

test("gravity accelerates the bird downward", function()
  local g = playing()
  local prev = 0
  for i = 1, 5 do
    g:step()
    local dv = g.bird.v - prev
    near(dv, Flappy.GRAVITY, 1e-9, "frame " .. i .. " gained exactly GRAVITY")
    prev = g.bird.v
  end
  ok(g.bird.y > 0, "bird has fallen")
end)

test("fall speed is capped at terminal velocity", function()
  local g = playing()
  for _ = 1, 200 do
    if g.state ~= "playing" then break end
    g:step()
    ok(g.bird.v <= Flappy.MAX_FALL + 1e-9, "velocity never exceeds MAX_FALL")
    break
  end
  -- Drive it properly in a tall field so it has room to reach the cap.
  local tall = Flappy.new(FW, 4000, { rand = seededRand(3) })
  tall:start()
  local maxV = 0
  for _ = 1, 400 do
    tall:step()
    if tall.bird.v > maxV then maxV = tall.bird.v end
  end
  near(maxV, Flappy.MAX_FALL, 1e-9, "reaches exactly MAX_FALL and stops there")
end)

test("flap sets velocity outright rather than adding to it", function()
  local g = playing()
  for _ = 1, 10 do g:step() end -- build up a dive, but stay off the ground
  ok(g.bird.v > 0, "bird is diving")
  g:flap()
  near(g.bird.v, Flappy.FLAP_IMPULSE, 1e-9, "flap out of a dive sets FLAP_IMPULSE")

  local g2 = playing()
  g2:flap()
  near(g2.bird.v, Flappy.FLAP_IMPULSE, 1e-9, "flap from rest sets the same velocity")

  -- Two flaps in one frame are worth exactly one; the velocity is a set.
  g2:flap()
  near(g2.bird.v, Flappy.FLAP_IMPULSE, 1e-9, "a double tap does not stack")
end)

test("flap is ignored outside play", function()
  local g = newGame()
  eq(g:flap(), false, "ready: flap refused")
  eq(g.bird.v, 0, "ready: velocity untouched")
  g:start(); g:pause()
  eq(g:flap(), false, "paused: flap refused")
end)

test("flapping climbs, and the ceiling stops the bird without killing it", function()
  -- Held clear of the pipes, so this measures the ceiling and nothing else.
  -- (A bird pinned to the ceiling *should* die on the top of a pipe; that the
  -- sky is safe and the pipes are not is exactly the distinction being made.)
  local g = playing()
  local below = 0
  for _ = 1, 200 do
    for _, p in ipairs(g.pipes) do p.x = g.w end
    g:flap()
    g:step()
    if g.bird.y < 0 then below = below + 1 end
    if g.state ~= "playing" then break end
  end
  eq(g.state, "playing", "open sky above is not lethal")
  eq(below, 0, "never rose past the top of the field")
  eq(g.bird.y, 0, "held against the ceiling")
  eq(g.bird.v, 0, "ceiling zeroes the velocity")

  -- ...whereas a pipe up there most certainly is.
  local g2 = playing()
  g2.pipes = { { x = Flappy.BIRD_X, gap = 40, gapTop = 120, scored = false } }
  g2.bird.y = 0
  g2:step()
  eq(g2.state, "over", "a column at ceiling height still kills")
end)

test("the ground is lethal and the bird comes to rest on it", function()
  local g = playing()
  for _ = 1, 500 do
    g:step()
    if g.state ~= "playing" then break end
  end
  eq(g.state, "over", "died")
  near(g.bird.y + Flappy.BIRD_H, g:groundY(), 1e-9, "rests exactly on the ground")
  eq(g.bird.v, 0, "velocity zeroed on impact")
end)

test("physics never rounds -- positions stay fractional between steps", function()
  local g = playing()
  local sawFraction = false
  for _ = 1, 40 do
    g:step()
    if g.bird.y ~= math.floor(g.bird.y) then sawFraction = true end
  end
  ok(sawFraction, "sub-pixel bird position is preserved for the renderer to floor")
end)

test("the world scrolls a whole number of pixels per frame", function()
  eq(Flappy.SCROLL_SPEED, math.floor(Flappy.SCROLL_SPEED), "SCROLL_SPEED is an integer")
  local g = playing()
  local p = g.pipes[1]
  local x0 = p.x
  g:step()
  near(x0 - p.x, Flappy.SCROLL_SPEED, 1e-9, "pipe moved exactly SCROLL_SPEED")
  ok(p.x == math.floor(p.x), "pipe x stays on a whole pixel, so it cannot shimmer")
end)

-- --------------------------------------------------------------- pipes ---- --

test("pipes keep exact spacing and are retired once offscreen", function()
  local g = playing()
  local seen = {}
  for _ = 1, 3000 do
    if g.state ~= "playing" then break end
    autopilot(g)
    g:step()
    for i = 2, #g.pipes do
      local d = g.pipes[i].x - g.pipes[i - 1].x
      if math.abs(d - Flappy.PIPE_SPACING) > 1e-9 then
        seen[#seen + 1] = d
      end
    end
    ok(#g.pipes <= math.ceil(FW / Flappy.PIPE_SPACING) + 2, "pipe list stays bounded")
    break
  end
  -- Full run, checked in aggregate rather than one assertion per frame.
  local g2 = playing()
  local bad, maxPipes = 0, 0
  for _ = 1, 4000 do
    if g2.state ~= "playing" then break end
    autopilot(g2)
    g2:step()
    if #g2.pipes > maxPipes then maxPipes = #g2.pipes end
    for i = 2, #g2.pipes do
      if math.abs((g2.pipes[i].x - g2.pipes[i - 1].x) - Flappy.PIPE_SPACING) > 1e-9 then
        bad = bad + 1
      end
    end
    for _, p in ipairs(g2.pipes) do
      if p.x + Flappy.PIPE_W < 0 then bad = bad + 1 end
    end
  end
  eq(bad, 0, "spacing exact and nothing lingers offscreen")
  ok(maxPipes <= math.ceil(FW / Flappy.PIPE_SPACING) + 2,
    "pipe list stayed bounded (peak " .. maxPipes .. ")")
end)

test("pipe rects are well formed and never negative", function()
  local g = playing()
  for _ = 1, 2000 do
    if g.state ~= "playing" then break end
    autopilot(g)
    g:step()
  end
  local bad = 0
  for _, p in ipairs(g.pipes) do
    local top, bottom = g:pipeRects(p)
    if top.h < 0 or bottom.h < 0 then bad = bad + 1 end
    if top.y ~= 0 then bad = bad + 1 end
    if math.abs((top.y + top.h + p.gap) - bottom.y) > 1e-9 then bad = bad + 1 end
    if math.abs((bottom.y + bottom.h) - g:groundY()) > 1e-9 then bad = bad + 1 end
  end
  eq(bad, 0, "top/bottom columns tile the field around the gap")
end)

test("every gap sits inside the sky, clear of ceiling and ground", function()
  for seed = 1, 25 do
    local g = playing({ rand = seededRand(seed) })
    for _ = 1, 1500 do
      if g.state ~= "playing" then break end
      autopilot(g)
      g:step()
      for _, p in ipairs(g.pipes) do
        if p.gapTop < 0 or p.gapTop + p.gap > g:groundY() then
          return fail("seed " .. seed .. ": gap escapes the playfield")
        end
      end
    end
  end
  passed = passed + 1
end)

test("scoring counts each pipe exactly once, as the bird passes it", function()
  local g = playing()
  local passes = 0
  for _ = 1, 3000 do
    if g.state ~= "playing" then break end
    autopilot(g)
    local before = g.score
    g:step()
    if g.score ~= before then
      eq(g.score - before, 1, "score rises one pipe at a time")
      passes = passes + 1
    end
  end
  eq(g.score, passes, "score equals the number of scoring events")
  ok(passes > 20, "the autopilot actually cleared pipes (" .. passes .. ")")

  -- A scored pipe stays scored, so a pipe cannot be double-counted.
  local doubles = 0
  for _, p in ipairs(g.pipes) do
    if p.scored and p.x + Flappy.PIPE_W > Flappy.BIRD_X then doubles = doubles + 1 end
  end
  eq(doubles, 0, "nothing is marked scored before it is passed")
end)

test("colliding with a pipe ends the round", function()
  -- Park a pipe directly in front of the bird with the gap far above it.
  local g = playing()
  g.pipes = { { x = Flappy.BIRD_X, gap = 40, gapTop = 0, scored = false } }
  g.bird.y = 100
  g:step()
  eq(g.state, "over", "flying into a column is fatal")
end)

test("flying cleanly through a gap is not a collision", function()
  local g = playing()
  local gap = 52
  local top = 60
  g.pipes = { { x = Flappy.BIRD_X, gap = gap, gapTop = top, scored = false } }
  -- Centre the bird in the gap and hold it there.
  g.bird.y = top + gap / 2 - Flappy.BIRD_H / 2
  g.bird.v = -Flappy.GRAVITY -- cancels this frame's gravity exactly
  g:step()
  eq(g.state, "playing", "dead centre of the gap is safe")
end)

test("the gap tightens with the score and then holds at GAP_MIN", function()
  local g = newGame()
  eq(g:gapSize(), Flappy.GAP_START, "starts at GAP_START")

  local prev = g:gapSize()
  local monotone = true
  for s = 0, 400 do
    g.score = s
    local gap = g:gapSize()
    if gap > prev then monotone = false end
    if gap < Flappy.GAP_MIN then
      return fail("gap fell below GAP_MIN at score " .. s .. ": " .. gap)
    end
    prev = gap
  end
  ok(monotone, "the gap never widens as the score climbs")
  g.score = 10000
  eq(g:gapSize(), Flappy.GAP_MIN, "bottoms out at GAP_MIN")
end)

-- ---------------------------------------------------- reachability ------- --
--
-- The property the whole generator exists to provide: consecutive gaps are
-- flyable one to the next. Checked three ways -- the arithmetic of the band,
-- the courses actually produced, and a bird actually flying them.

test("the reach limits are derived from the real physics", function()
  eq(Flappy.TRAVEL_FRAMES,
     math.floor((Flappy.PIPE_SPACING - Flappy.PIPE_W) / Flappy.SCROLL_SPEED),
     "travel window is the pipe-free distance over the scroll speed")
  ok(Flappy.REACH_CLIMB > 0, "there is some climb budget")
  ok(Flappy.REACH_DROP > 0, "there is some drop budget")

  -- Independently re-derive the climb: flapping every frame holds the bird at
  -- FLAP_IMPULSE + GRAVITY, and the generator only spends part of that.
  local frames = Flappy.TRAVEL_FRAMES - 4
  local free = -(Flappy.FLAP_IMPULSE + Flappy.GRAVITY) * frames
  ok(Flappy.REACH_CLIMB < free,
     "the budget is strictly inside what the physics allows (safety margin held back)")
end)

test("generated gap centres always land inside the reachable band", function()
  local violations, pipes = 0, 0
  for seed = 1, 40 do
    local g = playing({ rand = seededRand(seed * 977) })
    local prevCenter = nil
    local trail = {}
    for _, p in ipairs(g.pipes) do trail[#trail + 1] = p end

    for _ = 1, 2500 do
      if g.state ~= "playing" then break end
      autopilot(g)
      local n = #g.pipes
      local lastBefore = g.pipes[n]
      g:step()
      -- A spawn appended exactly one pipe; check it against its predecessor.
      if #g.pipes > 0 and g.pipes[#g.pipes] ~= lastBefore and lastBefore then
        local a = lastBefore.gapTop + lastBefore.gap / 2
        local b = g.pipes[#g.pipes].gapTop + g.pipes[#g.pipes].gap / 2
        pipes = pipes + 1
        -- Down is positive y, so a *larger* centre is a descent.
        if b - a > Flappy.REACH_DROP + 1e-6 then violations = violations + 1 end
        if a - b > Flappy.REACH_CLIMB + 1e-6 then violations = violations + 1 end
        prevCenter = b
      end
    end
  end
  ok(pipes > 500, "checked a meaningful number of transitions (" .. pipes .. ")")
  eq(violations, 0, "no transition asks for more climb or drop than the bird has")
end)

test("a bird can actually fly the courses the generator produces", function()
  -- The band arithmetic could be right and the game still unplayable. This is
  -- the check that matters: the crude autopilot above flies real courses, past
  -- the score where the gap has already tightened to GAP_MIN.
  local worstScore, worstSeed = math.huge, nil
  local tightest = math.huge

  for seed = 1, 30 do
    local g = playing({ rand = seededRand(seed * 7919 + 13) })
    for _ = 1, 12000 do
      if g.state ~= "playing" then break end
      local p = g:nextPipe()
      autopilot(g)
      g:step()
      -- Record how close to a column the bird came while inside a pipe.
      if p and p.x + Flappy.PIPE_W > Flappy.BIRD_X
        and p.x < Flappy.BIRD_X + Flappy.BIRD_W and g.state == "playing" then
        local m = math.min(g.bird.y - p.gapTop,
                           (p.gapTop + p.gap) - (g.bird.y + Flappy.BIRD_H))
        if m < tightest then tightest = m end
      end
    end
    if g.score < worstScore then worstScore, worstSeed = g.score, seed end
  end

  local minGapScore = Flappy.PIPES_PER_SHRINK
    * math.ceil((Flappy.GAP_START - Flappy.GAP_MIN) / Flappy.GAP_SHRINK)
  ok(worstScore > minGapScore,
    string.format("survives past the GAP_MIN threshold on every seed "
      .. "(worst: %d pipes on seed %d, threshold %d)", worstScore, worstSeed, minGapScore))
  ok(worstScore >= 200,
    "clears a long course unaided (worst seed managed " .. worstScore .. " pipes)")
  ok(tightest > 0,
    string.format("never actually clipped a column (tightest clearance %.2f px)", tightest))
end)

test("the reachable band is a real constraint, not a formality", function()
  -- If the band were wider than the playfield it would be decorative and the
  -- test above would prove nothing. It has to bind at least sometimes.
  local g = newGame()
  local lo, hi = g:centerLimits(Flappy.GAP_MIN)
  local span = hi - lo

  -- Climbing is the direction that actually costs the bird something, so that
  -- is the side the guarantee rides on: the budget has to be narrower than the
  -- sky, or it fences nothing and the test below proves nothing.
  ok(Flappy.REACH_CLIMB < span,
    string.format("climb budget %.1f is narrower than the %.1f px of sky",
      Flappy.REACH_CLIMB, span))

  -- Falling, by contrast, is free: gravity and terminal velocity carry the
  -- bird further than the whole field within one travel window, so the drop
  -- side of the band is expected to be slack and the playfield edge is what
  -- limits it. Asserting it binds would be asserting the physics is worse
  -- than it is -- but it must never be *tighter* than the climb, which would
  -- mean falling had somehow become the harder direction.
  ok(Flappy.REACH_DROP >= Flappy.REACH_CLIMB,
    string.format("falling is never harder than climbing (drop %.1f, climb %.1f)",
      Flappy.REACH_DROP, Flappy.REACH_CLIMB))

  -- ...and the generator does reach both extremes over a long enough run, so
  -- the band is not quietly pinning every gap to the middle either.
  local g2 = playing({ rand = seededRand(4242) })
  local lowest, highest = math.huge, -math.huge
  for _ = 1, 8000 do
    if g2.state ~= "playing" then break end
    autopilot(g2)
    g2:step()
    for _, p in ipairs(g2.pipes) do
      local c = p.gapTop + p.gap / 2
      if c < lowest then lowest = c end
      if c > highest then highest = c end
    end
  end
  local l2, h2 = g2:centerLimits(Flappy.GAP_MIN)
  ok(highest - lowest > span * 0.8,
    string.format("gaps range widely over a run (%.0f..%.0f of %.0f..%.0f)",
      lowest, highest, l2, h2))
end)

test("the guarantee holds when the constants are retuned", function()
  -- The band is computed from the constants, so a different playfield must not
  -- be able to produce a course with an unreachable jump in it.
  for _, size in ipairs({ { 318, 190 }, { 240, 140 }, { 640, 460 }, { 200, 96 } }) do
    local w, h = size[1], size[2]
    local g = Flappy.new(w, h, { rand = seededRand(w * h) })
    g:start()
    local bad = 0
    for _ = 1, 1500 do
      if g.state ~= "playing" then break end
      autopilot(g)
      local last = g.pipes[#g.pipes]
      g:step()
      local now = g.pipes[#g.pipes]
      if now and now ~= last and last then
        local d = (now.gapTop + now.gap / 2) - (last.gapTop + last.gap / 2)
        if d > Flappy.REACH_DROP + 1e-6 or -d > Flappy.REACH_CLIMB + 1e-6 then
          bad = bad + 1
        end
      end
      for _, p in ipairs(g.pipes) do
        if p.gapTop < -1e-9 or p.gapTop + p.gap > g:groundY() + 1e-9 then bad = bad + 1 end
      end
    end
    eq(bad, 0, string.format("%dx%d field stays reachable and in bounds", w, h))
  end
end)

-- ------------------------------------------------------------------ misc --

test("high score carries across rounds and only ever rises", function()
  local g = playing()
  for _ = 1, 3000 do
    if g.state ~= "playing" then break end
    autopilot(g)
    g:step()
  end
  local score = g.score
  ok(score > 0, "the autopilot scored (" .. score .. ")")
  -- The best is banked on death, so end the round before reading it.
  while g.state == "playing" do g:step() end
  local best = g.highScore
  eq(best, score, "high score matches the round just played")

  g:reset()
  eq(g.highScore, best, "reset keeps the best")
  eq(g.score, 0, "reset clears the score")
  g:start()
  for _ = 1, 60 do g:step() end -- die quickly, without flapping
  eq(g.highScore, best, "a worse round does not lower the best")
end)

test("reset returns a dead game to a playable one", function()
  local g = playing()
  for _ = 1, 500 do g:step() end
  eq(g.state, "over", "died")
  g:reset()
  eq(g.state, "ready", "back to ready")
  eq(g.frame, 0, "frame counter cleared")
  eq(g.bird.v, 0, "velocity cleared")
  ok(#g.pipes >= 1, "a fresh pipe is queued")
  g:start()
  g:step()
  eq(g.state, "playing", "plays again")
end)

test("nextPipe points at the pipe still ahead of the bird", function()
  local g = playing()
  for _ = 1, 800 do
    if g.state ~= "playing" then break end
    autopilot(g)
    g:step()
    local p = g:nextPipe()
    if p then
      ok(p.x + Flappy.PIPE_W > Flappy.BIRD_X, "nextPipe is not already behind the bird")
      break
    end
  end
end)

test("survives absurd playfields without crashing", function()
  for _, size in ipairs({ { 80, 48 }, { 100, 30 }, { 2000, 1400 }, { 90, 200 } }) do
    current = string.format("absurd playfield %dx%d", size[1], size[2])
    local g = Flappy.new(size[1], size[2], { rand = seededRand(7) })
    g:start()
    for i = 1, 400 do
      if i % 3 == 0 then g:flap() end
      g:step()
      if g.state ~= "playing" then g:reset(); g:start() end
    end
    passed = passed + 1
  end
end)

test("a fixed seed replays identically", function()
  local function run(seed)
    local g = Flappy.new(FW, FH, { rand = seededRand(seed) })
    g:start()
    local trace = {}
    for i = 1, 600 do
      if i % 9 == 0 then g:flap() end
      g:step()
      local p = g:nextPipe()
      trace[#trace + 1] = string.format("%.6f:%.6f:%d:%s", g.bird.y, g.bird.v,
        g.score, p and string.format("%.1f@%.1f", p.gapTop, p.x) or "-")
      if g.state ~= "playing" then break end
    end
    return table.concat(trace, "|")
  end
  eq(run(99), run(99), "same seed, same frames -- physics is deterministic")
  ok(run(99) ~= run(100), "a different seed deals a different course")
end)

-- ----------------------------------------------------------------- report --

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
