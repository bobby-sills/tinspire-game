-- Drives a built bundle through the mock Nspire runtime and dumps frames as
-- draw-op logs for tools/render.py to rasterize. Lets you see what a game
-- actually looks like without a calculator or an emulator.
--
--   lua tools/screenshot.lua <outdir> <bundle> <game>
--
-- Everything here is game-agnostic. Each game supplies tests/<game>/autoplay.lua,
-- a function(harness, capture) that plays itself and calls capture(name, ops)
-- for each frame worth keeping.

package.path = "tests/?.lua;" .. package.path
local stub = require("nspire_stub")

local OUTDIR = ... or "build/frames"
local BUNDLE = select(2, ...) or "build/snake/snake.lua"
local GAME   = select(3, ...) or BUNDLE:match("build/([^/]+)/") or "snake"

-- One line per operation, tab separated, so render.py needs no Lua parser.
--
-- drawImage needs the pixels as well as the placement, so each frame file
-- opens with an `image` line per distinct image it uses and the drawImage
-- lines then refer to it by id. Per frame rather than in a sidecar, so a
-- frame file stays a complete description of one frame.
local function dumpImages(ops, f)
  local seen = {}
  for _, o in ipairs(ops) do
    local img = o.img
    if img and not seen[img.id] then
      seen[img.id] = true
      local px = {}
      for i = 1, img.w * img.h do
        local c = img.px[i]
        px[i] = c and string.format("%02x%02x%02x", c[1], c[2], c[3]) or "------"
      end
      f:write(string.format("image\t%d\t%d\t%d\t%s\n",
                            img.id, img.w, img.h, table.concat(px)))
    end
  end
end

local function dump(ops, path)
  local f = assert(io.open(path, "w"))
  dumpImages(ops, f)
  for _, o in ipairs(ops) do
    local c = o.color
    if o.op == "drawString" then
      f:write(string.format("drawString\t%d\t%d\t%d\t%d\t%d\t%d\t%s\t%s\n",
        o.x, o.y, c[1], c[2], c[3], o.size, o.style, o.text))
    elseif o.op == "drawLine" then
      f:write(string.format("drawLine\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        o.x, o.y, o.x2, o.y2, c[1], c[2], c[3]))
    elseif o.op == "drawImage" then
      f:write(string.format("drawImage\t%d\t%d\t%d\n", o.x, o.y, o.img.id))
    elseif o.op == "fillArc" then
      f:write(string.format("fillArc\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        o.x, o.y, o.w, o.h, c[1], c[2], c[3]))
    else -- fillRect / drawRect
      f:write(string.format("%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s\n",
        o.op, o.x, o.y, o.w, o.h, c[1], c[2], c[3], o.pen or "smooth"))
    end
  end
  f:close()
end

os.execute("mkdir -p " .. OUTDIR)
-- Clear previous frames, or a run that captures fewer than the last one leaves
-- stale files behind and render.py turns them into screenshots that look
-- current. Only the .txt this tool writes, never anything else in the way.
os.execute("rm -f " .. OUTDIR .. "/*.txt")

local harness = stub.load(BUNDLE, 318, 212)
harness:resize(318, 212)

local n = 0
local function capture(name, ops)
  n = n + 1
  local path = string.format("%s/%d-%s.txt", OUTDIR, n, name)
  dump(ops, path)
  print("wrote " .. path)
end

local autoplay = require(GAME .. ".autoplay")
autoplay(harness, capture)

print(string.format("captured %d frames for %s", n, GAME))
