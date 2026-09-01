-- Recovers an Arkanoid frame from its draw calls, and plays the game with it.
--
-- Shared by tests/arkanoid/ui.lua and tests/arkanoid/autoplay.lua. Everything
-- here reads the *painted frame* and never the game's own state, so no
-- test-only hook has to reach the shipped script. The cost is that the colours
-- below are a contract with src/arkanoid/main.lua: change one there and it has
-- to change here too.
--
-- The wall is painted two ways and this has to read both. Normally each brick
-- is one gc:drawImage of a sprite main.lua generated at load; where image.new
-- is refused, or the bricks are smaller than a bevel can be drawn in, the same
-- bricks arrive as fillRects instead. Either way a brick is identified by its
-- ink, so both paths land on the same answer -- which is the point, because
-- tests/arkanoid/ui.lua asserts the two encodings paint the same wall.

local M = {}

-- Colours are keyed at the handheld's own depth -- five bits a channel -- and
-- not at eight. A sprite blitted through TI.Image comes back up to 7/255 from
-- where it started, so at eight bits the same brick reads as two different
-- bricks depending on which encoding drew it. Reducing here is where the two
-- have to meet. src/arkanoid/main.lua's palette is chosen so that nothing
-- collides once reduced; ui.lua asserts exactly that.
local function key(c)
  return math.floor(c[1] / 8) .. "," .. math.floor(c[2] / 8) .. "," .. math.floor(c[3] / 8)
end
M.keyOf = key

M.PAGE    = key({  10,  12,  18 })
M.FIELD   = key({  16,  19,  30 })
M.PANEL   = key({  20,  24,  44 })
M.WALL    = key({  96, 104, 128 })
M.WALL_HI = key({ 148, 158, 184 })
M.HUD     = key({  26,  30,  42 })
M.BALL    = key({ 248, 248, 240 })
M.BALL_HI = key({ 255, 255, 255 })
M.PADDLE  = key({  70, 150, 250 })
M.PADDLE_HI  = key({ 190, 225, 255 })
M.PADDLE_CAP = key({ 236,  96,  72 })
M.LASER   = key({ 255, 236, 120 })

-- The eleven brick inks, in main.lua's order: eight colours, then silver,
-- silver already hit, and gold.
M.INKS = {
  key({ 236, 240, 246 }), key({ 242, 150,  52 }), key({  88, 206, 236 }),
  key({  96, 206, 110 }), key({ 230,  74,  68 }), key({  84, 124, 236 }),
  key({ 216,  96, 208 }), key({ 244, 214,  68 }),
  key({ 176, 182, 196 }), key({ 118, 124, 140 }), key({ 226, 182,  58 }),
}
M.INK_NAME = {
  "white", "orange", "cyan", "green", "red", "blue", "magenta", "yellow",
  "silver", "silver-hit", "gold",
}

local INK_INDEX = {}
for i, k in ipairs(M.INKS) do INK_INDEX[k] = i end
M.INK_INDEX = INK_INDEX

M.CAPSULE = {
  [key({ 232,  84,  76 })] = "wide",
  [key({  84, 204, 124 })] = "catch",
  [key({ 240, 154,  60 })] = "laser",
  [key({  92, 148, 244 })] = "slow",
  [key({ 108, 220, 232 })] = "split",
  [key({ 218, 122, 220 })] = "life",
}

-- Every colour above that main.lua fills a rectangle in, so a test can assert
-- they all stay distinct once the panel has had them.
function M.palette()
  local all = {
    PAGE = M.PAGE, FIELD = M.FIELD, PANEL = M.PANEL, WALL = M.WALL,
    WALL_HI = M.WALL_HI, HUD = M.HUD, BALL = M.BALL, BALL_HI = M.BALL_HI,
    PADDLE = M.PADDLE, PADDLE_HI = M.PADDLE_HI, PADDLE_CAP = M.PADDLE_CAP,
    LASER = M.LASER,
  }
  for i, k in ipairs(M.INKS) do all["ink:" .. M.INK_NAME[i]] = k end
  for k, name in pairs(M.CAPSULE) do all["capsule:" .. name] = k end
  return all
end

-- A blitted brick is identified by the pixel at its centre, which is the body
-- colour for any sprite big enough to carry a bevel -- and not by the most
-- common one, which for a very small brick is the highlight. Cached per image:
-- a full wall is a hundred blits a frame over the same eleven sprites.
local centreInk = {}
local function inkOfImage(img)
  local hit = centreInk[img.id]
  if hit ~= nil then return hit end
  local c = img.px[math.floor(img.h / 2) * img.w + math.floor(img.w / 2) + 1]
  hit = c and key(c) or false
  centreInk[img.id] = hit
  return hit
end

-- Returns a table describing the frame:
--   field     the playfield rect (the one full-bleed FIELD fill)
--   bricks    { x, y, w, h, ink (1..11), name }, in paint order
--   paddle    the paddle rect, or nil
--   balls     every ball rect
--   capsules  { x, y, kind }
--   bullets   every laser bolt in flight
--   text      every string drawn, in order, with its position and size
--   blitted   true if this frame used the gc:drawImage path
function M.read(ops)
  local f = { bricks = {}, balls = {}, capsules = {}, bullets = {}, text = {},
              blitted = false, panels = {} }

  for _, o in ipairs(ops) do
    if o.op == "drawImage" then
      f.blitted = true
      local ink = INK_INDEX[inkOfImage(o.img)]
      f.bricks[#f.bricks + 1] = {
        x = o.x, y = o.y, w = o.img.w, h = o.img.h,
        ink = ink, name = ink and M.INK_NAME[ink] or "?",
      }

    elseif o.op == "fillRect" then
      local k = key(o.color)
      local ink = INK_INDEX[k]
      if k == M.FIELD and o.w > 40 then
        f.field = { x = o.x, y = o.y, w = o.w, h = o.h }
      elseif k == M.PANEL then
        f.panels[#f.panels + 1] = { x = o.x, y = o.y, w = o.w, h = o.h }
      elseif ink then
        f.bricks[#f.bricks + 1] = { x = o.x, y = o.y, w = o.w, h = o.h,
                                    ink = ink, name = M.INK_NAME[ink] }
      elseif k == M.BALL then
        f.balls[#f.balls + 1] = { x = o.x, y = o.y, w = o.w, h = o.h }
      elseif k == M.PADDLE then
        -- The HUD draws the spare lives in the paddle's own colours, so the
        -- two are told apart by where they are rather than by what colour
        -- they are: only one of them is in the playfield.
        if not f.field or o.y >= f.field.y then
          f.paddle = { x = o.x, y = o.y, w = o.w, h = o.h }
        else
          f.spares = (f.spares or 0) + 1
        end
      elseif k == M.LASER then
        -- The barrels on the paddle share the bolts' colour; a bolt is the
        -- tall one.
        if o.h > o.w then f.bullets[#f.bullets + 1] = { x = o.x, y = o.y } end
      elseif M.CAPSULE[k] then
        f.capsules[#f.capsules + 1] = { x = o.x, y = o.y, kind = M.CAPSULE[k] }
      end

    elseif o.op == "drawString" then
      f.text[#f.text + 1] = { text = o.text, x = o.x, y = o.y, size = o.size }
    end
  end

  return f
end

-- The HUD line is "<score>   L<level>   Best <best>", which is the only place
-- either number is on screen, so this is how a test asks what they are without
-- reaching into the game.
function M.hud(f)
  for _, t in ipairs(f.text) do
    local score, level, best = string.match(t.text, "^(%d+)%s+L(%d+)%s+Best (%d+)$")
    if score then
      return { score = tonumber(score), level = tonumber(level), best = tonumber(best) }
    end
  end
  return nil
end

function M.hasText(f, want)
  for _, t in ipairs(f.text) do
    if string.find(t.text, want, 1, true) then return true, t end
  end
  return false
end

-- The lowest ball that is on its way down -- what a paddle should be under.
function M.chaseBall(f)
  local best
  for _, b in ipairs(f.balls) do
    if not best or b.y > best.y then best = b end
  end
  return best
end

-- Where the paddle should be aiming, in window coordinates. Leads the ball a
-- little, and falls back to the middle of the field when there is nothing to
-- chase (between a life and the next serve).
function M.aimPoint(f)
  local b = M.chaseBall(f)
  if b then return b.x + b.w / 2 end
  if f.field then return f.field.x + f.field.w / 2 end
  return 159
end

-- One frame of a simulated player: look at what was painted, put the paddle
-- under the ball, and press enter often enough to serve, to shoot the laser
-- and to let a caught ball go. Returns the frame it read.
--
-- Deliberately the crudest controller that could work -- it has no idea where
-- the bricks are -- because a game this can play is a game a person can play.
function M.playFrame(hs, i)
  local _, ops = hs:paint()
  local f = M.read(ops)
  hs.on.mouseDown(M.aimPoint(f), 150)
  if i % 5 == 0 then hs.on.enterKey() end
  hs.on.timer()
  return f
end

return M
