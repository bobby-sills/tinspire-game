platform.apilevel = '2.0'

-- imageprobe.lua -- a throwaway document that asks the handheld what
-- `image.new` actually wants, because nothing in this container can.
--
-- gc:drawImage exists on the CX II, but the byte layout image.new accepts is
-- documented only by TI, education.ti.com is blocked by the egress proxy here,
-- and a wrong guess paints nothing at all with no error to chase. So rather
-- than guess once and ship it, this tries a dozen candidate layouts and
-- signatures side by side and labels each one, and a human with a calculator
-- reads off which of them painted.
--
-- Every slot draws a green control bar first. If a slot shows its control bar
-- and its number but no magenta square, that candidate was built and drawn and
-- produced nothing. If a slot shows no control bar at all, the script died
-- before reaching it -- which is itself the answer.
--
-- Build:  make probe     ->  ImageProbe.tns
-- This is not a game and is not under src/; it ships nothing.

local W, H = 8, 8                    -- the test image, deliberately tiny
local INK = { 255, 0, 255 }          -- magenta: nothing else on screen is

-- ---------------------------------------------------------------- packing --

local function u16le(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u16be(v) return string.char(math.floor(v / 256) % 256, v % 256) end
local function u32le(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
                     math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- RGB565, the format every 16-bit ARM framebuffer of this era uses. Both byte
-- orders, because that is exactly the kind of thing a wrong guess turns into a
-- blank screen.
local function rgb565(r, g, b)
  return math.floor(r / 8) * 2048 + math.floor(g / 4) * 32 + math.floor(b / 8)
end

local function body565(le)
  local v = rgb565(INK[1], INK[2], INK[3])
  local px = le and u16le(v) or u16be(v)
  return string.rep(px, W * H)
end

local function body888()
  return string.rep(string.char(INK[1], INK[2], INK[3]), W * H)
end

local function body8888()
  return string.rep(string.char(INK[1], INK[2], INK[3], 255), W * H)
end

-- ------------------------------------------------------------- candidates --
--
-- Each entry is { label, builder }. The builder returns either a string to
-- hand to image.new(string), or a table {w, h, data} to try the three-argument
-- signature -- which is a real possibility and costs nothing to include.

local CANDS = {
  { "u16le w,h + 565le", function()
      return u16le(W) .. u16le(H) .. body565(true) end },

  { "u16le w,h + 565be", function()
      return u16le(W) .. u16le(H) .. body565(false) end },

  { "u16be w,h + 565be", function()
      return u16be(W) .. u16be(H) .. body565(false) end },

  { "w,h,stride,0 + 565le", function()
      return u16le(W) .. u16le(H) .. u16le(W * 2) .. u16le(0) .. body565(true) end },

  { "w,h,bpp16 + 565le", function()
      return u16le(W) .. u16le(H) .. u16le(16) .. body565(true) end },

  -- The 16-byte header shape that keeps turning up in community conversions:
  -- a leading zero word, then the dimensions, then a stride and a format flag.
  { "16B hdr + 565le", function()
      return u32le(0) .. u16le(W) .. u16le(H) .. u16le(0)
          .. u16le(W * 2) .. u16le(1) .. u16le(0) .. body565(true) end },

  { "16B hdr fmt=0 + 565le", function()
      return u32le(0) .. u16le(W) .. u16le(H) .. u16le(0)
          .. u16le(W * 2) .. u16le(0) .. u16le(0) .. body565(true) end },

  { "u32le w,h + 565le", function()
      return u32le(W) .. u32le(H) .. body565(true) end },

  { "u16le w,h + rgb888", function()
      return u16le(W) .. u16le(H) .. body888() end },

  { "u16le w,h + rgba8888", function()
      return u16le(W) .. u16le(H) .. body8888() end },

  { "raw 565le, no header", function()
      return body565(true) end },

  -- Not a layout but a signature: image.new(w, h, data).
  { "new(w,h,565le) 3-arg", function()
      return { W, H, body565(true) } end },
}

-- Built once at load, not per paint: image.new could be slow, could error, and
-- on.paint is not the place to find that out.
local built = {}

local function buildAll()
  for i, c in ipairs(CANDS) do
    local rec = { label = c[1] }
    local okData, data = pcall(c[2])
    if not okData then
      rec.status, rec.note = "build", tostring(data)
    elseif type(image) ~= "table" or type(image.new) ~= "function" then
      rec.status, rec.note = "noapi", type(image)
    else
      local okNew, img
      if type(data) == "table" then
        okNew, img = pcall(image.new, data[1], data[2], data[3])
      else
        okNew, img = pcall(image.new, data)
      end
      if not okNew then
        rec.status, rec.note = "err", tostring(img)
      elseif img == nil then
        rec.status = "nil"
      else
        rec.status, rec.img, rec.note = "ok", img, type(img)
      end
    end
    built[i] = rec
  end
end

buildAll()

local ui = { w = 318, h = 212 }

function on.resize(w, h)
  ui.w, ui.h = w, h
  platform.window:invalidate()
end

-- Slot geometry: four columns of candidates down the page.
local COLS = 3
local SLOT_W, SLOT_H = 104, 30

function on.paint(gc)
  gc:setColorRGB(16, 18, 24)
  gc:fillRect(0, 0, ui.w, ui.h)

  gc:setFont("sansserif", "b", 9)
  gc:setColorRGB(240, 240, 245)
  gc:drawString("image.new probe -- magenta square = that layout works", 4, 2, "top")

  gc:setFont("sansserif", "r", 7)

  for i, rec in ipairs(built) do
    local cx = ((i - 1) % COLS) * SLOT_W + 3
    local cy = math.floor((i - 1) / COLS) * SLOT_H + 16

    -- The control bar. Present means this slot was reached and painted.
    gc:setColorRGB(60, 200, 90)
    gc:fillRect(cx, cy, 3, SLOT_H - 4)

    gc:setColorRGB(190, 196, 210)
    gc:drawString(i .. " " .. rec.label, cx + 6, cy, "top")

    -- Where the image should land, outlined so an absent image is obvious.
    local ix, iy = cx + 6, cy + 11
    gc:setColorRGB(80, 86, 100)
    gc:drawRect(ix - 1, iy - 1, W + 1, H + 1)

    local shown = rec.status
    if rec.img then
      -- Every drawImage is pcall'd: an error here would abort on.paint and
      -- blank the whole screen, losing every other result on the page.
      local okDraw, err = pcall(function() gc:drawImage(rec.img, ix, iy) end)
      shown = okDraw and "drawn" or ("draw!" .. tostring(err):sub(1, 12))
    end

    gc:setColorRGB(150, 156, 172)
    gc:drawString(shown, ix + W + 4, cy + 10, "top")
  end

  gc:setColorRGB(120, 128, 148)
  gc:drawString("report: which numbers show a magenta square", 4, ui.h - 11, "top")
end

function on.timer() end
function on.arrowKey() end
function on.charIn() end
function on.enterKey() end
function on.escapeKey() end
function on.mouseDown() end
