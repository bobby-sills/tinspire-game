-- A stand-in for the TI-Nspire Lua runtime, strict enough to catch API misuse.
--
-- The calculator silently ignores a bad drawing call, so a typo or an
-- out-of-range colour shows up on hardware as "the screen looks wrong" with no
-- error to chase. This mock asserts on anything the real API would reject,
-- which lets tests/run_ui.lua drive the real bundle and fail loudly instead.

local stub = {}

-- Optional: measured font metrics from tools/fontmetrics.py. Present only
-- after `make screenshots`; the mock falls back to an estimate without it.
do
  local loaded, metrics = pcall(require, "metrics")
  stub.metrics = loaded and metrics or nil
end

-- Values the Nspire's own font machinery accepts.
local FONT_FAMILIES = { sansserif = true, serif = true, mono = true }
local FONT_STYLES   = { r = true, b = true, i = true, bi = true }
local FONT_SIZES    = { [7]=true, [9]=true, [10]=true, [11]=true, [12]=true, [16]=true, [24]=true }
local PEN_SIZES     = { thin = true, medium = true, thick = true }
local PEN_STYLES    = { smooth = true, dotted = true, dashed = true }
local ANCHORS       = { top = true, middle = true, baseline = true }

local function num(v, what, call)
  assert(type(v) == "number", call .. ": " .. what .. " must be a number, got " .. type(v))
  assert(v == v and v ~= math.huge and v ~= -math.huge, call .. ": " .. what .. " must be finite")
  return v
end

local function byte(v, what, call)
  num(v, what, call)
  assert(v >= 0 and v <= 255, string.format("%s: %s out of 0..255 (%s)", call, what, tostring(v)))
  assert(math.floor(v) == v, string.format("%s: %s must be an integer (%s)", call, what, tostring(v)))
end

-- Returns a mock graphics context, a table of call counts, and an ordered log
-- of the drawing operations. The log is what tools/screenshot.lua replays to
-- turn a real frame into a PNG.
function stub.newGC()
  local calls = setmetatable({}, { __index = function() return 0 end })
  local ops = {}
  local gc = { _color = { 0, 0, 0 } }

  local function count(name) calls[name] = calls[name] + 1 end

  local function log(op, t)
    t.op = op
    t.color = { gc._color[1], gc._color[2], gc._color[3] }
    ops[#ops + 1] = t
  end

  function gc:setColorRGB(r, g, b)
    byte(r, "r", "setColorRGB"); byte(g, "g", "setColorRGB"); byte(b, "b", "setColorRGB")
    self._color = { r, g, b }
    count("setColorRGB")
  end

  function gc:setFont(family, style, size)
    assert(FONT_FAMILIES[family], "setFont: bad family " .. tostring(family))
    assert(FONT_STYLES[style], "setFont: bad style " .. tostring(style))
    assert(FONT_SIZES[size], "setFont: unsupported size " .. tostring(size))
    self._family, self._style, self._size = family, style, size
    count("setFont")
  end

  function gc:setPen(size, style)
    assert(PEN_SIZES[size], "setPen: bad size " .. tostring(size))
    assert(PEN_STYLES[style], "setPen: bad style " .. tostring(style))
    self._pen = style
    count("setPen")
  end

  local function rectLike(call)
    return function(self, x, y, w, h)
      num(x, "x", call); num(y, "y", call)
      num(w, "w", call); num(h, "h", call)
      assert(w >= 0, call .. ": negative width " .. tostring(w))
      assert(h >= 0, call .. ": negative height " .. tostring(h))
      count(call)
      log(call, { x = x, y = y, w = w, h = h, pen = self._pen })
    end
  end

  gc.fillRect = rectLike("fillRect")
  gc.drawRect = rectLike("drawRect")

  function gc:fillArc(x, y, w, h, a1, a2)
    num(x, "x", "fillArc"); num(y, "y", "fillArc")
    num(w, "w", "fillArc"); num(h, "h", "fillArc")
    num(a1, "startAngle", "fillArc"); num(a2, "arcAngle", "fillArc")
    assert(w >= 0 and h >= 0, "fillArc: negative size")
    count("fillArc")
    log("fillArc", { x = x, y = y, w = w, h = h, a1 = a1, a2 = a2 })
  end

  function gc:drawLine(x1, y1, x2, y2)
    num(x1, "x1", "drawLine"); num(y1, "y1", "drawLine")
    num(x2, "x2", "drawLine"); num(y2, "y2", "drawLine")
    count("drawLine")
    log("drawLine", { x = x1, y = y1, x2 = x2, y2 = y2 })
  end

  -- gc:drawImage(img, x, y). `img` must be something image.new made; the real
  -- one ignores anything else, which on hardware is a blank screen with no
  -- error, so the mock refuses instead.
  function gc:drawImage(img, x, y)
    assert(type(img) == "table" and img.__tiimage,
           "drawImage: not an image (got " .. type(img) .. ")")
    num(x, "x", "drawImage"); num(y, "y", "drawImage")
    count("drawImage")
    log("drawImage", { x = x, y = y, w = img.w, h = img.h, img = img })
  end

  function gc:drawString(text, x, y, anchor)
    assert(type(text) == "string", "drawString: text must be a string, got " .. type(text))
    num(x, "x", "drawString"); num(y, "y", "drawString")
    assert(ANCHORS[anchor], "drawString: bad anchor " .. tostring(anchor))
    count("drawString")
    log("drawString", { x = x, y = y, text = text, anchor = anchor,
                        size = self._size or 10, style = self._style or "r" })
    return self:getStringWidth(text)
  end

  -- Measured widths when tools/fontmetrics.py has been run (so previews agree
  -- with the layout), otherwise a rough but monotonic estimate.
  function gc:getStringWidth(text)
    assert(type(text) == "string", "getStringWidth: needs a string")
    local size = self._size or 10
    local table_ = stub.metrics and stub.metrics[self._style or "r"]
    local widths = table_ and table_[size]
    if not widths then
      return math.floor(#text * (size * 0.55))
    end
    local total = 0
    for i = 1, #text do
      local code = string.byte(text, i)
      total = total + (widths[code - 31] or widths[1] or 0)
    end
    return total
  end

  function gc:getStringHeight(text)
    assert(type(text) == "string", "getStringHeight: needs a string")
    return (self._size or 10) + 4
  end

  return gc, calls, ops
end


-- ------------------------------------------------------------------ images --
--
-- A model of TI.Image, the binary string image.new takes at apilevel < 2.3.
-- The layout is documented at wiki.inspired-lua.org/TI.Image and was then
-- confirmed against a real CX II with tools/probe/imageprobe2.lua: a 20-byte
-- little-endian header, then 16-bit pixels laid out A RRRRR GGGGG BBBBB with
-- alpha in the TOP bit.
--
-- This is validated as strictly as the hardware, which is the whole point of
-- modelling it at all. The probe showed the OS rejects a malformed header
-- outright -- it answered "image header mismatch" to a stride of zero -- so a
-- mock that accepted anything would let a broken sprite reach the calculator
-- and paint nothing, with no error to chase.

local nextImageId = 0

local function le(s, off, n)
  local v = 0
  for i = 0, n - 1 do
    v = v + string.byte(s, off + i) * (256 ^ i)
  end
  return v
end

-- Five bits back out to eight the way the panel does, so a preview shows what
-- the handheld shows rather than the original the format cannot hold.
local function expand5(v)
  return math.floor(v * 8 + math.floor(v / 4))
end

local imageModule = {}

function imageModule.new(data)
  if type(data) ~= "string" then
    error("image.new: expected a TI.Image string, got " .. type(data), 2)
  end
  if #data < 20 then error("image.new: image header mismatch (too short)", 2) end

  local w, h = le(data, 1, 4), le(data, 5, 4)
  local align, flags, pad = le(data, 9, 1), le(data, 10, 1), le(data, 11, 2)
  local stride = le(data, 13, 4)
  local bpp, planes = le(data, 17, 2), le(data, 19, 2)

  if w < 1 or h < 1 then error("image.new: image header mismatch (size)", 2) end
  if align ~= 0 or flags ~= 0 or pad ~= 0 then
    error("image.new: image header mismatch (reserved fields)", 2)
  end
  if stride ~= w * 2 then error("image.new: image header mismatch (stride)", 2) end
  if bpp ~= 16 then error("image.new: image header mismatch (bpp)", 2) end
  if planes ~= 1 then error("image.new: image header mismatch (planes)", 2) end
  if #data ~= 20 + w * h * 2 then
    error("image.new: image header mismatch (data length)", 2)
  end

  local px = {}
  for i = 0, w * h - 1 do
    local v = le(data, 21 + i * 2, 2)
    if v >= 32768 then
      local rest = v - 32768
      local r = math.floor(rest / 1024)
      local g = math.floor(rest / 32) % 32
      local b = rest % 32
      px[i + 1] = { expand5(r), expand5(g), expand5(b) }
    else
      px[i + 1] = false          -- top bit clear: not drawn
    end
  end

  nextImageId = nextImageId + 1
  local img = { __tiimage = true, id = nextImageId, w = w, h = h, px = px }
  function img:width() return self.w end
  function img:height() return self.h end
  return img
end

function imageModule.__reset() nextImageId = 0 end

stub.image = imageModule
stub.resetImageIds = imageModule.__reset

-- Saved before stub.load replaces math.randomseed below. Without it the
-- replacement would stop the *next* load from reseeding, so only the first
-- boot in a process would be pinned and every one after it would run on
-- wherever the stream had got to. Also exposed, for a test that needs to
-- predict what the script under test is about to draw.
local realRandomseed = math.randomseed
stub.randomseed = realRandomseed

-- Installs the globals a .tns script expects, then loads and runs `path`.
-- Returns the harness handle (window state, timer state, paint driver).
-- seed: pins the RNG so a run is reproducible. A game deliberately reseeds
-- itself from os.time() plus idle ticks, because a freshly reset handheld can
-- report the same time every launch -- good on the device, useless in a test,
-- where a failure you cannot reproduce is barely a failure at all. So seed the
-- sequence here and neutralise the script's own reseeding for the run.
function stub.load(path, w, h, seed)
  w, h = w or 318, h or 212
  realRandomseed(seed or 20240101)
  math.random(); math.random()
  math.randomseed = function() end

  local harness = { invalidated = 0, timerPeriod = nil, timerRunning = false, w = w, h = h }

  local window = {}
  function window:width() return harness.w end
  function window:height() return harness.h end
  function window:invalidate() harness.invalidated = harness.invalidated + 1 end

  _G.platform = { window = window, apilevel = nil }
  _G.timer = {
    start = function(period)
      assert(type(period) == "number" and period > 0, "timer.start: bad period")
      harness.timerPeriod, harness.timerRunning = period, true
    end,
    stop = function() harness.timerRunning = false end,
  }
  _G.on = {}
  _G.var = { store = function() end, recall = function() return nil end }
  _G.image = imageModule

  -- Image handles are numbered from 1 for each document loaded, not for the
  -- life of the process. A test that boots twice and compares what the two
  -- drew needs the same sprite to carry the same id both times.
  stub.resetImageIds()

  local chunk = assert(loadfile(path))
  chunk()

  harness.on = _G.on
  harness.platform = _G.platform

  function harness:paint()
    local gc, calls, ops = stub.newGC()
    assert(self.on.paint, "script defines no on.paint")
    self.on.paint(gc)
    return calls, ops
  end

  function harness:resize(nw, nh)
    self.w, self.h = nw, nh
    if self.on.resize then self.on.resize(nw, nh) end
  end

  return harness
end

return stub
