# Snake for the TI-Nspire CX II

A Snake game written in TI-Nspire Lua. It installs by drag-and-drop — no
Ndless, no jailbreak, no root.

**Grab [`Snake.tns`](Snake.tns) and copy it onto your calculator.**

![Title screen](docs/screenshots/title.png)
![In play](docs/screenshots/playing.png)

## Installing it

1. Connect the calculator over USB and open **TI-Nspire Student Software**
   (or the Teacher Software — either works; the free trial is enough).
2. In the Content Explorer, drag `Snake.tns` into the calculator's folder
   list. It behaves like any other document.
3. On the handheld, open **My Documents**, pick `Snake`, and press `enter`.

There is nothing else to install. `Snake.tns` is a normal TI-Nspire document
that happens to contain a Lua script, so the OS runs it in its built-in
sandbox exactly like a TI-authored one.

Requires OS 3.0.2 or newer, which every CX II ships with.

## Playing

| Key | Action |
| --- | --- |
| Arrows, `2`/`4`/`6`/`8`, or `WASD` | Steer |
| `enter` or space | Start, resume, play again |
| `esc` or `P` | Pause |
| `R` | Restart |
| `M` | Toggle solid walls vs. wrap-around (between rounds) |
| Click | Steer toward the click; confirm on menus |

Apples are worth `10 x level`. Every 4 apples raises the level and the snake
speeds up, to a cap at level 10. Following your own tail is legal — the cell
your tail is leaving this move is safe to enter. Fill the whole board and you
win.

The high score lasts for the session. It resets when you close the document,
because writing it back would mean saving the document on every death.

## Building it yourself

You only need this if you want to change the game; the committed `Snake.tns`
is ready to use.

```
make              # bundle the sources and build Snake.tns
make test         # run the test suites
make screenshots  # render preview PNGs into build/snake/screenshots
make clean
```

Add `GAME=<name>` to target another game under `src/`; it defaults to `snake`.

Requirements:

- **[luna](https://github.com/ndless-nspire/luna)** on your `PATH` — the
  open-source Lua-to-`.tns` converter. Clone it, `make`, and copy the binary
  somewhere on your path. It needs zlib (`zlib1g-dev` / `zlib-devel`).
- **python3** for the bundler.
- **Lua 5.1** for the tests (optional, but you want it).
- **Pillow** (`pip install Pillow`) for `make screenshots` (optional).

If you'd rather not build anything, paste `build/snake/snake.lua` into the Student
Software's script editor (**Insert > Script Editor**) and save the document
from there — same result, more clicking.

## How it's laid out

```
src/snake/game.lua   game rules -- pure Lua, no calculator APIs
src/snake/main.lua   drawing, input and timing for the Nspire
tests/snake/         logic tests, frame assertions, screenshot autoplay
tests/nspire_stub.lua + tests/run_ui.lua   shared mock of the Nspire runtime
tools/               shared: bundler, screenshot capture, PNG renderer
build/snake/snake.lua  generated: the script that goes into the .tns
Snake.tns            generated: the file you copy to the calculator
```

The `src/<game>/`, `tests/<game>/` layout is deliberate: the harness is shared
between games, so a second game reuses all of it. See `CLAUDE.md`.

The split matters more than it looks. `src/snake/game.lua` touches no `platform`,
`gc`, or `timer`, so the rules run under a desktop Lua and can be tested
directly. Everything calculator-shaped lives in `src/snake/main.lua`.

The handheld has no `require`, so `tools/bundle.py` inlines the logic module
into a single file and puts `platform.apilevel` on line 1, where the OS looks
for it.

## Testing without a calculator

Dragging a `.tns` over USB for every change gets old fast. Three options,
roughly in order of how quickly they catch things:

**`make test`** — two suites, no calculator involved. `tests/snake/run.lua` covers
the rules: turn queueing, the tail-follow exception, food placement on a
nearly-full board, the win condition, and a fuzz pass that checks structural
invariants over thousands of random moves. `tests/run_ui.lua` loads the *actual
bundled script* against `tests/nspire_stub.lua`, a mock of the calculator's
runtime that is deliberately stricter than the real one: it rejects colours
outside 0–255, unsupported font sizes, bad anchors, and negative rectangles.
The Nspire ignores a malformed drawing call silently, which on hardware shows
up as "the screen looks wrong" with nothing to debug — the mock turns that
into a failing test instead.

**`make screenshots`** — plays the game through the mock and rasterizes real
frames to PNG at the handheld's true 318x212, so you can see a layout change
without leaving the terminal. The simulated player reads the board back out of
the paint calls rather than reaching into the game's internals, so no
test-only hooks leak into the shipped script.

**An emulator** — [Firebird](https://github.com/nspire-emus/firebird) runs
CX II images and opens `.tns` files directly, with a Lua console for live
poking. This is the last check before real hardware. It needs a boot image and
OS dumped from a calculator you own.

## What isn't verified

The tests and screenshots run against a *model* of the calculator, not the
calculator. Two things only real hardware can settle:

- **Font metrics.** The mock measures text with DejaVu; the Nspire has its own
  font. The layout code always asks the device's own `getStringWidth` at
  runtime, so boxes size themselves correctly either way, and the HUD drops the
  "SNAKE" label rather than letting a long score collide with it. But the
  preview images are representative, not exact.
- **Timer pacing.** The game runs a fixed 0.05 s timer and counts ticks between
  moves rather than restarting the timer at a new interval, because granularity
  varies between Nspire OS versions. If your handheld's timer is coarser than
  0.05 s the game just runs proportionally slower — it won't misbehave, but the
  top speeds may not be reachable.
