-- Reads the visible state of a Klondike frame back out of the paint calls.
--
-- Written before tests/klondike/ui.lua and tests/klondike/autoplay.lua,
-- because it is what lets both of them drive the game without a test-only hook
-- in src/. Everything here comes from the drawing operations the mock
-- recorded; nothing reaches into the game.
--
-- What it can recover is exactly what a player can see, which is the point
-- rather than a limitation. Cards overlap: a covered card shows only its top
-- strip, so this reports the strip height alongside the identity and says
-- `ambiguous` when a strip is too thin to tell two cards apart. A test that
-- wanted more than that would be testing something the screen does not say.
--
-- Identification works off the art itself. The generated block in the bundle
-- lists every card's ink runs and names each row in a comment, so the runs
-- observed at a card's origin are matched against every candidate's runs
-- clipped to the same strip height. That is the shipped data being read back,
-- not a fixture that could drift away from it.

local Frame = {}

local DEFAULT_BUNDLE = "build/klondike/klondike.lua"

local SUIT_LETTER = { Clubs = "C", Diamonds = "D", Hearts = "H", Spades = "S" }

-- ------------------------------------------------------- the art, re-read --

local art = nil

local function parseArt(path)
  local f = assert(io.open(path, "r"), "cannot open bundle " .. path)
  local src = f:read("*a")
  f:close()

  local a = {}
  a.w, a.h = src:match("local CARD_W, CARD_H = (%d+), (%d+)")
  a.w, a.h = tonumber(a.w), tonumber(a.h)
  a.pack = tonumber(src:match("local CARD_PACK = (%d+)"))
  local br, bg, bb = src:match("local CARD_BODY%s*= { (%d+), (%d+), (%d+) }")
  a.body = { tonumber(br), tonumber(bg), tonumber(bb) }
  local fr, fg, fb = src:match("local CARD_FRAME = { (%d+), (%d+), (%d+) }")
  a.frame = { tonumber(fr), tonumber(fg), tonumber(fb) }
  assert(a.w and a.pack and a.body[1] and a.frame[1], "bundle has no card art block")

  -- The frame is drawn in the same value as the black ink, so its rects have
  -- to be subtracted before the ink can be read. Their offsets come from the
  -- bundle rather than from a copy kept here.
  a.frameRects = {}
  local fr_ = src:match("local CARD_FRAME_RECTS = { (.-) }")
  do
    local nums = {}
    for n in (fr_ or ""):gmatch("%-?%d+") do nums[#nums + 1] = tonumber(n) end
    for i = 1, #nums, 4 do
      a.frameRects[#a.frameRects + 1] =
        { x = nums[i], y = nums[i + 1], w = nums[i + 2], h = nums[i + 3] }
    end
  end
  assert(#a.frameRects > 0, "bundle has no CARD_FRAME_RECTS")

  -- The interface colours, read from the same place the game uses them, so a
  -- test never carries its own copy of a literal that could drift.
  a.ui = {}
  for name in ("PAGE_BG SLOT_LINE SLOT_FILL DEST_COL SEL_COL CURSOR_COL ACCENT")
      :gmatch("%S+") do
    local r, g, b = src:match("local " .. name .. "%s*=%s*{%s*(%d+),%s*(%d+),%s*(%d+)%s*}")
    assert(r, "bundle has no colour " .. name)
    a.ui[name] = { tonumber(r), tonumber(g), tonumber(b) }
  end

  a.ink = {}
  local inkBlock = src:match("local CARD_INK = {\n(.-)\n}")
  for r, g, b in (inkBlock or ""):gmatch("{ (%d+), (%d+), (%d+) }") do
    a.ink[#a.ink + 1] = { tonumber(r), tonumber(g), tonumber(b) }
  end

  -- Card runs, with the name from each row's trailing comment.
  a.cards, a.names = {}, {}
  local runsBlock = src:match("local CARD_RUNS = {\n(.-)\n}\n")
  assert(runsBlock, "bundle has no CARD_RUNS")
  for line in runsBlock:gmatch("[^\n]+") do
    local body, name = line:match("^%s*{ (.*) }, %-%- (%S+)%s*$")
    assert(body, "unparsed CARD_RUNS line: " .. line)
    local entry = assert(loadstring("return { " .. body .. " }"))()
    local runs = {}
    for e = 1, #entry, 2 do
      local ci, s = entry[e], entry[e + 1]
      for j = 1, #s, 3 do
        runs[#runs + 1] = { y = s:byte(j) - a.pack, x = s:byte(j + 1) - a.pack,
                            len = s:byte(j + 2) - a.pack, ink = ci }
      end
    end
    table.sort(runs, function(p, q)
      if p.y ~= q.y then return p.y < q.y end
      return p.x < q.x
    end)
    a.cards[#a.cards + 1] = runs

    local suit, rank = name:match("^(%a+)_(%w+)$")
    if suit == "Back" then
      a.names[#a.names + 1] = "back"
    else
      a.names[#a.names + 1] = (rank == "ACE" and "A" or rank) .. SUIT_LETTER[suit]
    end
  end
  return a
end

function Frame.art(path)
  if not art then art = parseArt(path or DEFAULT_BUNDLE) end
  return art
end

-- ------------------------------------------------------------- reading it --

local function sameColour(c, want)
  return c[1] == want[1] and c[2] == want[2] and c[3] == want[3]
end

local function inkIndex(a, c)
  for i = 1, #a.ink do
    if sameColour(c, a.ink[i]) then return i end
  end
  return nil
end

-- Signature of the runs a candidate card would show through a strip `strip`
-- pixels tall, and of what was actually drawn. Compared as strings so a
-- mismatch anywhere -- a dropped run, a run one pixel wide -- fails.
local function signature(runs, strip)
  local parts = {}
  for _, r in ipairs(runs) do
    if r.y < strip then
      parts[#parts + 1] = r.ink .. "/" .. r.y .. "/" .. r.x .. "/" .. r.len
    end
  end
  table.sort(parts)
  return table.concat(parts, " ")
end

-- Reads one frame. `ops` is the draw log from the mock; `bundle` is where to
-- find the art (defaults to the usual build path).
--
-- Returns:
--   cards      { { x, y, strip, name, candidates } }  -- name is nil if unsure
--   slots      { { x, y } }                           -- empty piles
--   rings      { colourKey = { { x, y, w, h } } }     -- highlight outlines
--   strings    { { x, y, text, size } }
-- Candidate signatures are the same for every card showing the same strip
-- height, and one frame holds only a handful of distinct heights, so they are
-- worked out once per height and kept. Without this the reader is comfortably
-- the slowest thing in the suite.
local function signaturesFor(a, strip)
  a.sigs = a.sigs or {}
  local row = a.sigs[strip]
  if not row then
    row = {}
    for i = 1, #a.cards do row[i] = signature(a.cards[i], strip) end
    a.sigs[strip] = row
  end
  return row
end

-- opts.identify = false skips working out which card is which, for a caller
-- that only wants the geometry.
function Frame.read(ops, bundle, opts)
  local a = Frame.art(bundle)
  local identify = not (opts and opts.identify == false)

  local cards, slots, rects, strings = {}, {}, {}, {}
  for _, o in ipairs(ops) do
    if o.op == "drawString" then
      strings[#strings + 1] = { x = o.x, y = o.y, text = o.text, size = o.size }
    elseif o.op == "fillRect" then
      rects[#rects + 1] = o
      -- A card always starts with its widest body rect: full card width less
      -- the rounded corners, at the card's own top-left, its height clipped to
      -- whatever strip is visible. That makes the origin and the strip
      -- readable straight off one rect.
      if sameColour(o.color, a.body) and o.w == a.w - 2 then
        cards[#cards + 1] = { x = o.x - 1, y = o.y, strip = o.h }
      end
    end
  end

  -- Ink belonging to each card: one-pixel-tall rects in a known ink colour
  -- inside the card's box. Assigned to the last card drawn at that origin,
  -- since piles are painted back to front.
  for _, c in ipairs(cards) do
    c.runs = {}
    -- The frame rects this card would have drawn, clipped to its strip.
    c.frame = {}
    for _, r in ipairs(a.frameRects) do
      local y0 = c.y + r.y
      local y1 = math.min(y0 + r.h, c.y + c.strip)
      if y1 > y0 then
        c.frame[(c.x + r.x) .. "," .. y0 .. "," .. r.w .. "," .. (y1 - y0)] = true
      end
    end
  end
  -- Cards are indexed by their left edge so a rect is only offered to the pile
  -- it can actually be inside, rather than to every card on screen.
  local byX = {}
  for i = 1, #cards do
    local c = cards[i]
    byX[c.x] = byX[c.x] or {}
    table.insert(byX[c.x], i)
  end
  local everything = {}
  for i = 1, #cards do everything[i] = i end

  if identify then
    for _, o in ipairs(rects) do
      local ci = inkIndex(a, o.color)
      if ci then
        -- A card's ink starts at least one pixel in from its own left edge,
        -- but the waste spread means two piles can share a row, so fall back
        -- to a full scan when the x does not land on a known pile.
        local column = byX[o.x] or byX[o.x - 1] or byX[o.x - 2] or byX[o.x - 3]
                       or everything
        for k = #column, 1, -1 do
          local c = cards[column[k]]
          if o.x >= c.x and o.x + o.w <= c.x + a.w
             and o.y >= c.y and o.y < c.y + c.strip then
            local key = o.x .. "," .. o.y .. "," .. o.w .. "," .. o.h
            if c.frame[key] then
              c.frame[key] = nil          -- the outline, not the artwork
            elseif o.h == 1 then
              c.runs[#c.runs + 1] =
                ci .. "/" .. (o.y - c.y) .. "/" .. (o.x - c.x) .. "/" .. o.w
            end
            break
          end
        end
      end
    end
  end

  for _, c in ipairs(cards) do
    if identify then
      table.sort(c.runs)
      local got = table.concat(c.runs, " ")
      c.candidates = {}
      local sigs = signaturesFor(a, c.strip)
      for i = 1, #sigs do
        if sigs[i] == got then c.candidates[#c.candidates + 1] = a.names[i] end
      end
      -- A thin strip can genuinely show nothing that separates two cards; say
      -- so rather than picking one.
      if #c.candidates == 1 then c.name = c.candidates[1] end
    end
    c.runs, c.frame = nil, nil
  end

  -- Empty piles: the slot's inner fill is the one rect of that size in a
  -- colour no card uses.
  for _, o in ipairs(rects) do
    if sameColour(o.color, a.ui.SLOT_FILL) and o.w == a.w - 2 and o.h == a.h - 2 then
      slots[#slots + 1] = { x = o.x - 1, y = o.y - 1 }
    end
  end

  -- Empty piles and highlight rings, both drawn as flat rects in colours
  -- nothing else uses. A ring is four rects, so it is recovered as the
  -- bounding box of a connected group at one colour.
  local rings = {}
  for _, o in ipairs(rects) do
    if not sameColour(o.color, a.body) and not sameColour(o.color, a.frame)
       and not inkIndex(a, o.color) then
      local key = o.color[1] .. "," .. o.color[2] .. "," .. o.color[3]
      rings[key] = rings[key] or {}
      local g = rings[key]
      g[#g + 1] = o
    end
  end

  return { cards = cards, slots = slots, rects = rects, strings = strings,
           rings = rings, art = a }
end

-- Groups rects of one colour into bounding boxes of things that touch. Used
-- for the highlight outlines, which are drawn as four separate rects.
function Frame.boxes(rectList)
  local boxes = {}
  for _, o in ipairs(rectList or {}) do
    local placed = false
    for _, b in ipairs(boxes) do
      if o.x <= b.x + b.w and o.x + o.w >= b.x
         and o.y <= b.y + b.h and o.y + o.h >= b.y then
        local x2 = math.max(b.x + b.w, o.x + o.w)
        local y2 = math.max(b.y + b.h, o.y + o.h)
        b.x, b.y = math.min(b.x, o.x), math.min(b.y, o.y)
        b.w, b.h = x2 - b.x, y2 - b.y
        placed = true
        break
      end
    end
    if not placed then
      boxes[#boxes + 1] = { x = o.x, y = o.y, w = o.w, h = o.h }
    end
  end
  table.sort(boxes, function(p, q)
    if p.x ~= q.x then return p.x < q.x end
    return p.y < q.y
  end)
  return boxes
end

-- The cards of a frame grouped into piles by their left edge, each pile in
-- top-to-bottom order. That is all the geometry a test needs: which column a
-- card is in, and how far down it sits.
function Frame.piles(f)
  local byX = {}
  for _, c in ipairs(f.cards) do
    byX[c.x] = byX[c.x] or {}
    table.insert(byX[c.x], c)
  end
  local xs = {}
  for x in pairs(byX) do xs[#xs + 1] = x end
  table.sort(xs)
  local piles = {}
  for _, x in ipairs(xs) do
    table.sort(byX[x], function(p, q) return p.y < q.y end)
    piles[#piles + 1] = { x = x, cards = byX[x] }
  end
  return piles
end

return Frame
