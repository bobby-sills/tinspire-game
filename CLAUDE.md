# TI-Nspire CX II games

Lua games that install by drag-and-drop — no Ndless, no jailbreak. Each builds
to a `.tns`, an ordinary TI-Nspire document containing a script, which the OS
runs in its built-in sandbox.

**The harness here is game-agnostic and already built. Reuse it — do not write
your own mock runtime, bundler, or screenshot pipeline.**

Games: `snake` (grid-stepped, turn-based feel) and `flappy` (continuous
physics, fixed timestep). Between them they cover both shapes a new game is
likely to take — read whichever is closer to what you're building.

## Commands

```
make GAME=<name>              build src/<name> -> <Name>.tns
make GAME=<name> test         logic tests + runtime tests
make GAME=<name> screenshots  preview PNGs -> build/<name>/screenshots
make all-games                build everything under src/
make list                     list games
```

`GAME` defaults to `snake`. Set `LUA=` if your Lua 5.1 binary isn't `lua`.

## Layout

```
src/<game>/game.lua     rules — pure Lua, no calculator APIs
src/<game>/main.lua     drawing, input, timing
tests/<game>/run.lua    logic tests (desktop Lua)
tests/<game>/ui.lua     optional: game-specific frame assertions
tests/<game>/autoplay.lua  optional: plays itself for screenshots

tests/nspire_stub.lua   mock of the Nspire runtime      -- shared, don't fork
tests/run_ui.lua        generic runtime tests           -- shared
tools/bundle.py         inlines game+main into one file -- shared
tools/screenshot.lua    frame capture driver            -- shared
tools/render.py         draw-ops -> PNG                 -- shared
tools/fontmetrics.py    font metrics for the mock       -- shared
```

## Architecture, and why

`game.lua` must not touch `platform`, `gc`, or `timer`. That split is what lets
the rules run under a desktop Lua and be tested directly; everything
calculator-shaped lives in `main.lua`. Keep it.

The handheld has no `require`, so `tools/bundle.py` inlines `game.lua` into
`main.lua` as an immediately-invoked function bound to a local, and puts
`platform.apilevel` on line 1, where the OS looks for it.

`main.lua` must open with `local X = X or require("game")`. That line is what
makes the file work both bundled (X is the inlined local) and under a desktop
Lua, and the bundler reads it to learn what to call the module — so a game can
name it `Game`, `Flappy`, `Board`, whatever reads best in its drawing code,
with no registry to keep in sync. The module file is always `game.lua`, so the
require string is always `"game"` regardless of the local's name.

## Device constraints that shape design

- **Screen** 318x212 usable, full colour.
- **Frame rate** the timer realistically caps near 0.05 s, so **~20 FPS is the
  ceiling**. Run a fixed fast timer and count ticks between updates rather than
  restarting the timer at new intervals — granularity varies between OS
  versions, and tick counting degrades gracefully instead of breaking.
- **Input is discrete only**: `on.arrowKey`, `on.charIn`, `on.enterKey`,
  `on.escapeKey`, `on.mouseDown`. There is no key-down polling and no key-up
  event, so anything needing a *held* key routes through OS auto-repeat and
  feels laggy. Turn-based and tap-based games fit best.
- **No file I/O** in the sandbox. High scores last only for the session unless
  you save the document, which prompts the user on every death.
- **Repaint is all-or-nothing.** `platform.window:invalidate()` redraws
  everything; only call it when something changed. A turn-based game can skip
  the timer entirely and repaint on input.
- **Font metrics are unknown until runtime.** Always size boxes with
  `gc:getStringWidth`, never a character-count estimate. Have layouts degrade
  when text is wider than expected rather than assuming it fits.
- **Colours** are integers 0–255. Font sizes are limited (7, 9, 10, 11, 12, 16,
  24); the mock rejects others. Anchors are `top`/`middle`/`baseline`.
- Changing colour is a call, so quantise gradients into bands instead of
  setting a new colour per element.
- **Seed the RNG from more than `os.time()`** — it can return the same value on
  a freshly reset handheld, dealing an identical game every launch. Mix in how
  many idle ticks passed before the player's first input.

## Testing without a calculator

Three layers, cheapest first. All of it runs in this container.

1. `tests/<game>/run.lua` — the rules, under desktop Lua. Fuzz over many random
   moves and assert structural invariants, not just happy paths.
2. `tests/run_ui.lua` — loads **the actual built bundle** against
   `tests/nspire_stub.lua`, a mock deliberately stricter than the real runtime:
   it rejects out-of-range colours, unsupported font sizes, bad anchors and
   negative rectangles. The Nspire drops a malformed drawing call *silently*,
   which on hardware looks like "the screen is wrong" with nothing to debug —
   the mock turns that into a failing test. Add game-specific frame assertions
   in `tests/<game>/ui.lua`.
3. `make screenshots` — rasterizes real frames at true 318x212. Write
   `tests/<game>/autoplay.lua` to play the game and capture interesting states.
   Recover state from the paint calls rather than reaching into game internals,
   so no test-only hooks reach the shipped script.

Beyond that, [Firebird](https://github.com/nspire-emus/firebird) runs CX II
images and opens `.tns` files, but needs a boot image dumped from real hardware.

**What none of this proves:** the mock measures text with DejaVu, not the
Nspire's font, and it can't tell you a game *feels* good. Tuning constants
(gravity, speed, difficulty curves) needs real play — keep them in one clearly
marked block so they're easy to change.

## Environment setup

None of this is preinstalled. Set it up before building:

- **luna** (Lua → `.tns`): clone https://github.com/ndless-nspire/luna and run
  `make` (needs zlib). It is **its own repo**, not a subdirectory of Ndless —
  in Ndless it appears only as a submodule pointer.
- **Lua 5.1** for tests: **lua.org is blocked by the egress proxy.** Get it from
  https://github.com/lua/lua — only the `v5.1.1` tag exists there, which is
  fine. Build with `gcc -O2 -DLUA_USE_POSIX *.c -lm`, excluding `ltests.c`.
- **Pillow** (`pip install Pillow`) for `make screenshots`.
- **education.ti.com is blocked**, so TI's API docs can't be fetched here.

## Adding a game

1. `src/<name>/game.lua` and `src/<name>/main.lua`, following Snake's shape.
2. `tests/<name>/run.lua` for the rules — copy Snake's test framework header.
3. Optionally `tests/<name>/ui.lua` and `tests/<name>/autoplay.lua`.
4. `make GAME=<name> test && make GAME=<name>`.
5. Commit the built `<Name>.tns` at the repo root — it's the deliverable people
   download and drag onto the calculator. Verify it's byte-identical to a fresh
   rebuild before committing.

## Conventions

- Commit the generated `.tns` and `build/<game>/<game>.lua`; the bundle is
  useful for pasting into TI's Script Editor.
- Don't add test-only hooks to `src/`.
- Comment the non-obvious *why*, not the obvious *what*.
