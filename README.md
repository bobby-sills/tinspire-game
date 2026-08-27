# Snake and Flappy Bird for the TI-Nspire CX II

Two games written in TI-Nspire Lua. They install by drag-and-drop — no Ndless,
no jailbreak, no root.

**Grab [`Snake.tns`](Snake.tns) or [`Flappy.tns`](Flappy.tns) and copy it onto
your calculator.**

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
`src/flappy.lua` — and `tests/run_flappy.lua`, which checks the property three
ways: the arithmetic of the band, the courses actually produced, and a
deliberately crude autopilot that has to fly them.

Both games' high scores last for the session. They reset when you close the
document, because writing one back would mean saving the document on every
death.

## Installing

1. Connect the calculator over USB and open **TI-Nspire Student Software**
   (or the Teacher Software — either works; the free trial is enough).
2. In the Content Explorer, drag `Snake.tns` or `Flappy.tns` into the
   calculator's folder list. They behave like any other document.
3. On the handheld, open **My Documents**, pick one, and press `enter`.

There is nothing else to install. Each `.tns` is a normal TI-Nspire document
that happens to contain a Lua script, so the OS runs it in its built-in
sandbox exactly like a TI-authored one.

Requires OS 3.0.2 or newer, which every CX II ships with.

## Building it yourself

You only need this if you want to change a game; the committed `.tns` files
are ready to use.

```
make          # bundle the sources and build both .tns files
make snake    # just Snake.tns
make flappy   # just Flappy.tns
make test     # run all four test suites
make screenshots  # render preview PNGs into build/screenshots*
make clean
```

Requirements:

- **[luna](https://github.com/ndless-nspire/luna)** on your `PATH` — the
  open-source Lua-to-`.tns` converter. It is its own repository, not a
  subdirectory of Ndless: clone it, `make`, and copy the binary somewhere on
  your path. It needs zlib (`zlib1g-dev` / `zlib-devel`).
- **python3** for the bundler.
- **Lua 5.1** for the tests (optional, but you want it). If your package
  manager has no 5.1, the [`lua/lua`](https://github.com/lua/lua) mirror's
  `v5.1.1` tag builds with
  `gcc -O2 -DLUA_USE_POSIX *.c -lm` once you drop `ltests.c`.
- **Pillow** (`pip install Pillow`) for `make screenshots` (optional).

If you'd rather not build anything, paste `build/snake.lua` or
`build/flappy.lua` into the Student Software's script editor
(**Insert > Script Editor**) and save the document from there — same result,
more clicking.

## How it's laid out

```
src/game.lua          Snake rules   -- pure Lua, no calculator APIs
src/main.lua          Snake drawing, input and timing for the Nspire
src/flappy.lua        Flappy rules  -- pure Lua, no calculator APIs
src/flappy_main.lua   Flappy drawing, input and timing for the Nspire
tools/bundle.py       inlines a rules module + its main into one script
tools/screenshot*.lua + tools/render.py    turn real frames into PNGs
tests/                logic tests, plus a mock of the Nspire runtime
build/*.lua           generated: the scripts that go into the .tns files
Snake.tns Flappy.tns  generated: the files you copy to the calculator
```

The split matters more than it looks. `src/game.lua` and `src/flappy.lua`
touch no `platform`, `gc`, or `timer`, so the rules run under a desktop Lua
and can be tested directly. Everything calculator-shaped lives in the matching
`*main.lua`.

The handheld has no `require`, so `tools/bundle.py` inlines the rules module
into a single file and puts `platform.apilevel` on line 1, where the OS looks
for it. Both games go through the same bundler; `bundle.py <out> flappy`
selects the target.

## Two games, one problem shape

Snake is **grid-stepped**: it moves a whole cell at a time on a tick counter,
so a position is always an integer and there is nothing to round. Flappy is
**continuous** — the bird accelerates and the world scrolls past it — which
needs a different discipline:

- **Fixed timestep.** One physics step per timer tick, with every constant in
  `src/flappy.lua` expressed per frame. No wall clock and no delta time, so
  the same seed replays frame-for-frame identically and a slow handheld runs
  the whole game proportionally slower rather than skipping physics.
- **Floats until the draw boundary.** Positions stay fractional in the rules
  module; `src/flappy_main.lua` floors them at the moment it draws, and only
  there. Rounding inside the simulation would let error accumulate.
- **Whole-pixel scrolling.** The Nspire's timer will not reliably go below
  ~0.05 s, so 20 FPS is the ceiling. At that rate a fractional scroll speed
  reads as a stutter, because the pipes land on a different pixel column on
  some frames and not others. `SCROLL_SPEED` is therefore an integer.

Everything that decides how Flappy *feels* — gravity, flap impulse, pipe gap,
pipe spacing, scroll speed — is in one marked constants block at the top of
`src/flappy.lua`, and nowhere else. The reachability guarantee re-derives
itself from whatever you set them to, and `tests/run_flappy.lua` re-checks it
against the new values.

Both games seed their RNG the same way. `os.time()` alone is a poor seed on a
handheld: one that has just been reset can report the same value every launch,
which would deal the same apples — or the same pipes — every game. Both mix in
how many timer ticks the player sat on the title screen before their first
input.

## Testing without a calculator

Dragging a `.tns` over USB for every change gets old fast. Three options,
roughly in order of how quickly they catch things:

**`make test`** — four suites, no calculator involved. `tests/run.lua` and
`tests/run_flappy.lua` cover the rules directly: for Snake, turn queueing, the
tail-follow exception, food placement on a nearly-full board and the win
condition; for Flappy, the physics constants, terminal velocity, the ceiling
and ground, scoring, and the reachability property above. `tests/run_ui.lua`
and `tests/run_ui_flappy.lua` then load the *actual bundled scripts* against
`tests/nspire_stub.lua`, a mock of the calculator's runtime that is
deliberately stricter than the real one: it rejects colours outside 0–255,
unsupported font sizes, bad anchors, and negative rectangles. The Nspire
ignores a malformed drawing call silently, which on hardware shows up as "the
screen looks wrong" with nothing to debug — the mock turns that into a failing
test instead.

**`make screenshots`** — plays both games through the mock and rasterizes real
frames to PNG at the handheld's true 318x212, so you can see a layout change
without leaving the terminal. Each simulated player reads the world back out
of the paint calls rather than reaching into the game's internals, so no
test-only hooks leak into the shipped scripts. Snake's recovers a grid from
cell-sized rects; Flappy's has no grid to recover, so it picks the bird and
the pipe columns out by the colours the renderer reserves for them, rebuilds
each gap from the two columns that share an x, and flies the course by
flapping whenever the bird is below the gap it is aiming at.

**An emulator** — [Firebird](https://github.com/nspire-emus/firebird) runs
CX II images and opens `.tns` files directly, with a Lua console for live
poking. This is the last check before real hardware. It needs a boot image and
OS dumped from a calculator you own.

## What isn't verified

The tests and screenshots run against a *model* of the calculator, not the
calculator. Two things only real hardware can settle:

- **Font metrics.** The mock measures text with DejaVu; the Nspire has its own
  font. The layout code always asks the device's own `getStringWidth` at
  runtime, so boxes size themselves correctly either way, and both HUDs drop
  their title label rather than letting a long score collide with it. But the
  preview images are representative, not exact.
- **Timer pacing.** Both games run a fixed 0.05 s timer. Snake counts ticks
  between moves rather than restarting the timer at a new interval, because
  granularity varies between Nspire OS versions; if your handheld's timer is
  coarser than 0.05 s it just runs proportionally slower, and the top speeds
  may not be reachable. Flappy has the same exposure with a sharper edge: it
  is a reflex game, so a handheld pacing at, say, 0.06 s makes the bird feel
  heavier than these previews suggest. The physics stays correct — every frame
  is simulated, none are dropped — but the feel is the one thing a mock cannot
  tell you. That is what the constants block is for.
