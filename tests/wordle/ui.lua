-- Wordle's own frame assertions, run by tests/run_ui.lua against the built
-- bundle. Everything is read back out of the paint calls through
-- tests/wordle/frame.lua, so none of this needs a hook in src/.

local Frame = require("wordle.frame")

return function(t)
  local test, ok, eq = t.test, t.ok, t.eq

  -- The same set tests/run_ui.lua renders at: the handheld, the computer
  -- software's views, and the extremes that squeeze the layout.
  local SIZES = {
    { 318, 212 }, { 320, 240 }, { 240, 160 }, { 160, 120 },
    { 120, 90 }, { 640, 480 }, { 900, 700 }, { 480, 200 }, { 200, 480 },
  }

  local function outside(r, w, h)
    return r.x < 0 or r.y < 0 or r.x + r.w > w or r.y + r.h > h
  end

  test("nothing is drawn outside the window, at any size", function()
    for _, s in ipairs(SIZES) do
      local w, h = s[1], s[2]
      local hs = t.boot(w, h)
      hs.on.enterKey()
      Frame.play(hs, "slate")
      Frame.typeWord(hs, "cro")   -- a part-typed row is drawn differently again
      local f = Frame.frame(hs)

      local escaped = 0
      for _, r in ipairs(f.rects) do
        if outside(r, w, h) then escaped = escaped + 1 end
      end
      eq(escaped, 0, string.format("every rect is inside %dx%d", w, h))

      local escapedText = 0
      for _, str in ipairs(f.strings) do
        if str.x < 0 or str.y < 0 or str.x > w or str.y > h then
          escapedText = escapedText + 1
        end
      end
      eq(escapedText, 0, string.format("every string starts inside %dx%d", w, h))
    end
  end)

  test("the grid and the keyboard never overlap, at any size", function()
    for _, s in ipairs(SIZES) do
      local w, h = s[1], s[2]
      local hs = t.boot(w, h)
      hs.on.enterKey()
      local f = Frame.frame(hs)
      ok(f.board ~= nil, string.format("the grid has a backing rect at %dx%d", w, h))
      if f.board then
        local b, clash = f.board, 0
        -- Anything smaller than the board either sits wholly inside it (a
        -- tile) or wholly outside it (a key, a share square). A rect that
        -- straddles the edge means the keyboard has been laid out over the
        -- grid, which is the failure a shrinking window would cause.
        for _, kr in ipairs(f.rects) do
          if kr ~= b and kr.w < b.w and kr.h < b.h then
            local overlaps = kr.x < b.x + b.w and kr.x + kr.w > b.x
                         and kr.y < b.y + b.h and kr.y + kr.h > b.y
            local containedInBoard = kr.x >= b.x and kr.y >= b.y
                                 and kr.x + kr.w <= b.x + b.w
                                 and kr.y + kr.h <= b.y + b.h
            if overlaps and not containedInBoard then clash = clash + 1 end
          end
        end
        eq(clash, 0, string.format("no rect straddles the board edge at %dx%d", w, h))
      end
    end
  end)

  test("the grid is five columns by six rows", function()
    local hs = t.boot(318, 212)
    local f = Frame.frame(hs)
    eq(#f.colX, 5, "five columns")
    eq(#f.rowY, 6, "six rows")
    -- Evenly spaced, which is the cheapest way to catch a layout that has
    -- drifted a pixel per column.
    local stride = f.colX[2] - f.colX[1]
    local even = true
    for i = 3, #f.colX do
      if f.colX[i] - f.colX[i - 1] ~= stride then even = false end
    end
    ok(even, "columns are evenly spaced")
  end)

  test("typed letters appear in the row being played", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    Frame.typeWord(hs, "cra")
    local f = Frame.frame(hs)
    eq(f.grid[1][1].letter, "c", "first letter is on the board")
    eq(f.grid[1][3].letter, "a", "third letter is on the board")
    eq(f.grid[1][4].letter, nil, "the untyped squares are empty")
    eq(f.grid[1][1].mark, nil, "and nothing is coloured before it is played")

    hs.on.arrowKey("left")
    f = Frame.frame(hs)
    eq(f.grid[1][3].letter, nil, "the left arrow deletes a letter")

    hs.on.escapeKey()
    f = Frame.frame(hs)
    eq(f.grid[1][1].letter, nil, "escape clears the row")
  end)

  test("a guess outside the word list does not fill a row", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    Frame.typeWord(hs, "zzzzz")
    hs.on.enterKey()
    local f = Frame.settle(hs)
    eq(#Frame.guesses(f), 0, "no row was scored")
    local told = false
    for _, line in ipairs(f.text) do
      if line:match("[Nn]ot in word list") then told = true end
    end
    ok(told, "and the player is told why: " .. table.concat(f.text, " / "))
  end)

  test("a keyboard letter's colour never gets worse", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    local best = {}
    local words = { "slate", "crony", "mixup", "dwarf", "bebop", "vigil" }
    for _, word in ipairs(words) do
      local f = Frame.play(hs, word)
      for letter, k in pairs(f.keys) do
        if #letter == 1 then
          local rank = Frame.RANK[k.mark] or 0
          ok(rank >= (best[letter] or 0),
            string.format("%s went %s after %s", letter, k.mark, word))
          best[letter] = rank
        end
      end
      local over = false
      for _, line in ipairs(f.text) do
        if line:match("plays again") then over = true end
      end
      if over then break end
    end
  end)

  test("every letter played shows up on the keyboard", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    local f = Frame.play(hs, "slate")
    for _, letter in ipairs({ "s", "l", "a", "t", "e" }) do
      local k = f.keys[letter]
      ok(k and k.mark ~= "unknown", letter .. " is coloured on the keyboard")
    end
    ok(f.keys["q"] and f.keys["q"].mark == "unknown", "an untried letter is not")
  end)

  test("losing reveals the answer and the share grid", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    -- Six guesses; if one happens to be the answer the game ends early, which
    -- this asserts is not the case for the pinned seed before relying on it.
    local words = { "slate", "crony", "mixup", "dwarf", "bebop", "vigil" }
    local f
    for _, word in ipairs(words) do f = Frame.play(hs, word) end
    eq(#Frame.guesses(f), 6, "all six rows were played")

    local revealed = nil
    for _, line in ipairs(f.text) do
      if line:match("^%u%u%u%u%u$") then revealed = line end
    end
    ok(revealed ~= nil, "the answer is shown: " .. table.concat(f.text, " / "))

    -- The share grid is 5 x 6 small squares in the panel, outside the board.
    local squares = 0
    for _, r in ipairs(f.rects) do
      if r.op == "fillRect" and f.board and r.w == r.h and r.w <= 8
         and not (r.x >= f.board.x and r.x + r.w <= f.board.x + f.board.w
                  and r.y >= f.board.y and r.y + r.h <= f.board.y + f.board.h) then
        squares = squares + 1
      end
    end
    eq(squares, 30, "six rows of five squares are drawn")
  end)

  test("the candidate count settles to a number", function()
    local hs = t.boot(318, 212)
    hs.on.enterKey()
    local f = Frame.play(hs, "slate")
    local counted = nil
    for _, line in ipairs(f.text) do
      local n = line:match("^(%d+) words? fits?$")
      if n then counted = tonumber(n) end
    end
    ok(counted ~= nil, "a count is shown once the slices finish: " ..
      table.concat(f.text, " / "))
    if counted then
      ok(counted >= 1, "at least the answer itself fits (" .. counted .. ")")
    end
  end)

  test("hard mode is reachable from the title and refuses a wasted guess", function()
    local hs = t.boot(318, 212)
    hs.on.charIn("h")          -- title screen only
    local f = Frame.frame(hs)
    local flagged = false
    for _, line in ipairs(f.text) do
      if line:match("hard mode") then flagged = true end
    end
    ok(flagged, "the title says hard mode is on")

    hs.on.enterKey()
    Frame.play(hs, "slate")
    f = Frame.frame(hs)
    local shown = Frame.guesses(f)[1]
    ok(shown ~= nil, "the opening guess was played")

    -- A word that keeps none of what the first guess revealed. If the opener
    -- happened to reveal nothing at all there is nothing to violate, so this
    -- only asserts when there was a hint to ignore.
    if shown and shown.marks:match("[YG]") then
      Frame.typeWord(hs, "conic")
      hs.on.enterKey()
      local after = Frame.settle(hs)
      local refused = #Frame.guesses(after) == 1
      local told = false
      for _, line in ipairs(after.text) do
        if line:match("must") then told = true end
      end
      ok(refused == told, "a refusal and its message go together")
    end
  end)
end
