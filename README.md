# Snake, Flappy Bird and 2048 for the TI-Nspire CX II

Three games written in TI-Nspire Lua. They install by drag-and-drop — no
Ndless, no jailbreak, no root.

**Grab [`Snake.tns`](Snake.tns), [`Flappy.tns`](Flappy.tns) or
[`2048.tns`](2048.tns) and copy it onto your calculator.**

## Snake

![Title screen](docs/screenshots/title.png)
![In play](docs/screenshots/playing.png)

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

## Flappy Bird

![Title screen](docs/screenshots/flappy-title.png)
![In play](docs/screenshots/flappy-playing.png)

| Key | Action |
| --- | --- |
| `enter`, space, up arrow, `W`, `8`, `F`, or click | Flap |
| `esc`, `P`, or down arrow | Pause |
| `R` | Restart |

One tap per gap. The bird only ever goes up when you tell it to, and the flap
*sets* its speed rather than adding to it, so a tap out of a long dive lifts
exactly as much as a tap from a hover — panicking works. Each pipe cleared is
a point, and the gap tightens every 5 pipes down to a floor it never goes
below.

The pipe course is generated so that **every gap is reachable from the one
before it**. Dealt at random, a low gap followed by a high one is simply
impossible past some distance, and you lose to the generator instead of to
your own thumbs. Instead the generator is fenced by the physics: it asks how
far the bird can actually climb in the frames between two pipes, given the
gravity and flap strength in force, and never places a gap outside that. See
`src/flappy/game.lua` — and `tests/flappy/run.lua`, which checks the property
three ways: the arithmetic of the band, the courses actually produced, and a
deliberately crude autopilot that has to fly them.

## 2048

![Title screen](docs/screenshots/2048-title.png)
![In play](docs/screenshots/2048-playing.png)

| Key | Action |
| --- | --- |
| Arrows, `2`/`4`/`6`/`8`, or `WASD` | Slide the board |
| `enter` or space | Start, resume, keep going past 2048, play again |
| `esc` or `P` | Pause |
| `U` or `backspace` | Undo one move |
| `R` | Restart |
| Click | Slide toward the side of the board you clicked |

Slide the whole board at once; equal tiles that collide merge into their sum,
and the score goes up by whatever each merge produced. A tile that has just
merged is spent for the rest of that move, which is why a row of `4 4 4 4`
becomes `8 8` and never `16`. Which pair merges first depends on the direction
you pushed: `4 4 4` gives `8 4` going left, but `4 8` going right.

A move only counts if it changes something. Push against a wall nothing can
move toward and nothing happens — no new tile, no score, and the turn is not
spent. After every move that *did* change the board, a new `2` (or, one time in
ten, a `4`) appears on a uniformly chosen empty cell.

The round ends when **no** direction would change the board, which is not the
same as the board being full — a full board with two equal neighbours still has
a move in it. `U` or `backspace` undoes one move, the one that ended the round
included, which is worth having when a mis-keyed arrow costs you the game.

![Mid-slide](docs/screenshots/2048-sliding.png)

Being turn-based, it runs no game loop: the screen repaints when you press a
key and not otherwise. The timer has exactly one job — sliding tiles to their
new cells — and only asks for repaints while a slide is actually on screen.

All three games' high scores last for the session. They reset when you close
the document, because writing one back would mean saving the document on every
death.

## Installing

1. Connect the calculator over USB. On a Mac the easiest route is
   [TI-Nspire CX II Connect](https://nspireconnect.ti.com) — free, web-based,
   nothing to install, but it **requires Chrome**; Safari has no WebUSB and
   will fail in a way that looks like a hardware fault. TI-Nspire Student or
   Teacher Software works too.
2. Drag `Snake.tns`, `Flappy.tns` or `2048.tns` into the calculator's file
   list. They must land in **My Documents** directly, not a subfolder.
3. On the handheld, open **My Documents**, pick one, and press `enter`.

There is nothing else to install. Each `.tns` is a normal TI-Nspire document
that happens to contain a Lua script, so the OS runs it in its built-in
sandbox exactly like a TI-authored one.

Requires OS 3.0.2 or newer, which every CX II ships with.

## Building it yourself

You only need this if you want to change a game; the committed `.tns` files
are ready to use.

```
make GAME=snake                # build Snake.tns   (GAME defaults to snake)
make GAME=flappy               # build Flappy.tns
make GAME=2048                 # build 2048.tns
make GAME=flappy test          # that game's logic + runtime tests
make GAME=flappy screenshots   # preview PNGs -> build/flappy/screenshots
make all-games                 # build everything under src/
make list                      # list games
make clean
```

Requirements:

- **[luna](https://github.com/ndless-nspire/luna)** on your `PATH` — the
  open-source Lua-to-`.tns` converter. Clone it, `make`, and copy the binary
  somewhere on your path. It needs zlib (`zlib1g-dev` / `zlib-devel`).
- **python3** for the bundler.
- **Lua 5.1** for the tests (optional, but you want it).
- **Pillow** (`pip install Pillow`) for `make screenshots` (optional).

If you'd rather not build anything, paste `build/<game>/<game>.lua` into the
Student Software's script editor (**Insert > Script Editor**) and save the
document from there — same result, more clicking.

## How it's laid out

```
src/<game>/game.lua       rules -- pure Lua, no calculator APIs
src/<game>/main.lua       drawing, input and timing for the Nspire
tests/<game>/run.lua      logic tests
tests/<game>/ui.lua       game-specific frame assertions
tests/<game>/autoplay.lua plays itself, for screenshots

tests/nspire_stub.lua     shared: mock of the Nspire runtime
tests/run_ui.lua          shared: game-agnostic runtime tests
tools/                    shared: bundler, frame capture, PNG renderer
build/<game>/<game>.lua   generated: the script that goes into the .tns
<Game>.tns                generated: the file you copy to the calculator
```

The harness is shared between games; only the files under `src/<game>/` and
`tests/<game>/` are per-game. `CLAUDE.md` has the details for adding another.

The logic/presentation split matters more than it looks. `game.lua` touches no
`platform`, `gc`, or `timer`, so the rules run under a desktop Lua and can be
tested directly. Everything calculator-shaped lives in `main.lua`.

The handheld has no `require`, so `tools/bundle.py` inlines the logic module
into a single file and puts `platform.apilevel` on line 1, where the OS looks
for it.

## Testing without a calculator

Dragging a `.tns` over USB for every change gets old fast. Three options,
roughly in order of how quickly they catch things:

**`make GAME=<game> test`** — two suites, no calculator involved.
`tests/<game>/run.lua` covers the rules: for Snake, turn queueing, the
tail-follow exception, food placement on a nearly-full board and the win
condition; for Flappy, the physics and the reachability of every generated
gap; for 2048, the merge rules where all the bugs live — merge-once-per-move,
merge order by direction, what makes a move legal, and game over as "no
direction changes the board" rather than "the board is full". All three end
with a fuzz pass checking structural invariants over thousands of steps.

`tests/run_ui.lua` loads the *actual bundled script* against
`tests/nspire_stub.lua`, a mock of the calculator's runtime that is
deliberately stricter than the real one: it rejects colours outside 0–255,
unsupported font sizes, bad anchors, and negative rectangles. The Nspire
ignores a malformed drawing call silently, which on hardware shows up as "the
screen looks wrong" with nothing to debug — the mock turns that into a failing
test instead. Each game adds its own frame assertions in `tests/<game>/ui.lua`.

**`make GAME=<game> screenshots`** — plays the game through the mock and
rasterizes real frames to PNG at the handheld's true 318x212, so you can see a
layout change without leaving the terminal. The simulated player reads the
world back out of the paint calls rather than reaching into the game's
internals, so no test-only hooks leak into the shipped script.

**An emulator** — [Firebird](https://github.com/nspire-emus/firebird) runs
CX II images and opens `.tns` files directly, with a Lua console for live
poking. This is the last check before real hardware. It needs a boot image and
OS dumped from a calculator you own.

## What isn't verified

The tests and screenshots run against a *model* of the calculator, not the
calculator. Two things only real hardware can settle:

- **Font metrics.** The mock measures text with DejaVu; the Nspire has its own
  font. The layout code always asks the device's own `getStringWidth` at
  runtime, so boxes size themselves correctly either way, and the HUD drops its
  title rather than letting a long score collide with it. But the preview
  images are representative, not exact.
- **Timer pacing.** Snake and Flappy run a fixed 0.05 s timer and count ticks
  rather than restarting the timer at new intervals, because granularity varies
  between Nspire OS versions. If your handheld's timer is coarser than 0.05 s
  they run proportionally slower — they won't misbehave, but Snake's top speeds
  may not be reachable, and Flappy will feel heavier than intended. 2048 is
  unaffected: it is turn-based, and a coarse timer only makes its slide
  animation longer.
