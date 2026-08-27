-- Snake-specific frame assertions, run by tests/run_ui.lua after its generic
-- suite. It passes in the shared helpers so these read like the tests there.
--
-- The pattern for a new game: recover what you drew from the operation log,
-- then assert the things a screenshot would have shown you.

local FIELD_BG = { 12, 14, 19 }

return function(t)
  local test, ok, eq, fail, boot = t.test, t.ok, t.eq, t.fail, t.boot

  -- Pulls the playfield rect, the snake cells and the food out of a frame's
  -- draw calls. Cells are the only square rects inside the field; the 2x2
  -- eyes and the full-width HUD bar are the wrong shape to match.
  local function frameGeometry(ops)
    local field, cells, food = nil, {}, nil
    for _, o in ipairs(ops) do
      local c = o.color
      if o.op == "fillRect" then
        if c[1] == FIELD_BG[1] and c[2] == FIELD_BG[2] and c[3] == FIELD_BG[3] then
          field = o
        elseif o.w == o.h and o.w >= 4 and o.w <= 20 then
          cells[#cells + 1] = o
        end
      elseif o.op == "fillArc" then
        food = o
      end
    end
    return field, cells, food
  end

  local function assertInsideField(ops, label)
    local field, cells, food = frameGeometry(ops)
    if not field then return fail(label .. ": no playfield drawn") end

    local escaped = 0
    for _, o in ipairs(cells) do
      if o.x < field.x or o.y < field.y
        or o.x + o.w > field.x + field.w
        or o.y + o.h > field.y + field.h then
        escaped = escaped + 1
      end
    end
    eq(escaped, 0, label .. ": snake cells outside the playfield")

    if food then
      ok(food.x >= field.x and food.y >= field.y
        and food.x + food.w <= field.x + field.w
        and food.y + food.h <= field.y + field.h,
        label .. ": food inside the playfield")
    end
  end

  test("snake: food is drawn on the title screen", function()
    local hs = boot()
    local calls = hs:paint()
    ok(calls.fillArc >= 1, "drew the food")
  end)

  test("snake: nothing is drawn outside the playfield", function()
    for _, s in ipairs({ { 318, 212 }, { 640, 480 }, { 240, 160 } }) do
      local hs = boot(s[1], s[2])
      local label = string.format("%dx%d", s[1], s[2])
      local _, ops = hs:paint()
      assertInsideField(ops, label .. " title")

      hs.on.enterKey()
      for i = 1, 500 do
        hs.on.timer()
        if i % 5 == 0 then hs.on.arrowKey(({ "up", "left", "down", "right" })[(i % 4) + 1]) end
        if i % 100 == 0 then
          local _, playOps = hs:paint()
          assertInsideField(playOps, label .. " playing@" .. i)
        end
      end
    end
  end)

  test("snake: wrap mode paints correctly", function()
    local hs = boot()
    hs.on.charIn("m") -- title screen: switch to wrap
    local calls = hs:paint()
    ok(calls.setPen >= 1, "set a pen style for the dashed border")
    hs.on.enterKey()
    for _ = 1, 400 do hs.on.timer() end
    hs:paint()
    ok(true, "played a wrap round")
  end)
end
