# Snake, Flappy Bird, 2048, Connect Four and Chess for the TI-Nspire CX II

Five games written in TI-Nspire Lua. They install by drag-and-drop — no
Ndless, no jailbreak, no root.

**Grab [`Snake.tns`](Snake.tns), [`Flappy.tns`](Flappy.tns),
[`2048.tns`](2048.tns), [`Connect4.tns`](Connect4.tns) or
[`Chess.tns`](Chess.tns) and copy it onto your calculator.**

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

## Connect Four

![Title screen](docs/screenshots/connect4-title.png)
![In play](docs/screenshots/connect4-playing.png)

Two players on one calculator, or one player against a bot with four
difficulties.

| Key | Action |
| --- | --- |
| Left/right, or `A`/`D` | Move the cursor |
| `enter`, down arrow, or `S` | Drop into the cursor's column |
| `1`–`7` | Drop straight into that column |
| `esc` or `P` | Pause |
| `R` | Restart the round |
| `M` | Back to the title screen |
| Click | Drop into the column you clicked; confirm on menus |

On the title screen, up/down picks a row and left/right changes it. Red always
moves first, and who opens alternates between rounds. The match tally in the
status bar survives a restart; it resets when you go back to the menu.

"Two players" means two players **on one calculator**, taking turns. Nspire Lua
has no networking of any kind — no sockets, no link cable, no wireless — so
hot-seat is the only multiplayer there can be.

### The bot

The interesting part. There are no threads on this machine, so a search that
ran to completion inside one `on.timer()` callback would freeze the screen and
queue up keypresses for as long as it took, which to a player is
indistinguishable from a crash.

So the search never runs to completion in one go. It is an explicit state
machine over its own stack of frames — `ai:think(n)` advances it by `n` nodes
and returns either a column or "still thinking" — and `main.lua` feeds it one
slice per tick, painting a thinking indicator meanwhile. Because the search is
pure logic, the tests can drive the very same code straight through to the end
and check that slicing it changes *when* it answers and never *what* it
answers.

It searches by iterative deepening: depth 1, then 2, then 3, keeping the best
move found so far. That is what makes a budget usable — however little work the
bot was allowed, the last completed depth has already left a move behind.
Alpha-beta with centre-first ordering does the pruning; Connect Four's
branching factor is seven, and a centre disc sits in more of the 69 winning
lines than any other, so trying the middle first cuts the effective branching
hard.

Two things it deliberately does not do. It does not use bitboards, the usual
trick for this game: Lua 5.1 has no bitwise operators and the Nspire has no
`bit` library, so it is a plain array board. And it does not search the board
you are playing on — the search is suspended between ticks with several discs
still played, and painting *that* board showed phantom discs flickering in and
out while the bot thought, so it works on a copy.

Difficulty is search depth, plus deliberate blunders at Easy so a beginner can
actually win. What each level really gets is a number of ticks; the depth that
fits in them is whatever the machine can manage. The numbers behind that, and
what was measured to pick them, are in the comment above `Board.LEVELS` in
`src/connect4/game.lua`.

![The bot thinking](docs/screenshots/connect4-thinking.png)
![Game over](docs/screenshots/connect4-gameover.png)

## Chess

![The menu](docs/screenshots/chess-menu.png)
![A piece picked up](docs/screenshots/chess-selected.png)

Full legal chess. Two players on one calculator, or one player against a bot
with three difficulties.

| Key | Action |
| --- | --- |
| Arrows | Move the cursor (and choose on the menu and the promotion panel) |
| `enter` | Pick a piece up, then put it down on a square |
| `esc` | Put the piece back down; again to pause; from a finished game, the menu |
| `U` | Take the last move back |
| `F` | Turn the board round |
| `R` | Restart the game |
| `M` | Back to the title screen |
| Click | Same as moving the cursor there and pressing `enter` |

Picking a piece up lights its square and marks every square it may legally go
to — a dot for a quiet move, a ring for a capture. On a board of twenty-pixel
squares that is the difference between playing and guessing. A king in check
gets its square painted red, and keeps it after mate, which is the answer to
"why is that the end".

Castling, en passant, promotion to any of the four pieces, checkmate,
stalemate, the fifty-move rule, threefold repetition and insufficient material
are all there. Promotion raises a chooser rather than assuming a queen:
underpromotion to a knight is the one that wins games.

"Two players" means two players **on one calculator**, taking turns. Nspire Lua
has no networking of any kind — no sockets, no link cable, no wireless — so
hot-seat is the only multiplayer there can be. Because both players are on the
same side of the screen, the menu offers to turn the board round between turns.

![The bot thinking](docs/screenshots/chess-thinking.png)
![Checkmate](docs/screenshots/chess-checkmate.png)

### How the rules are checked

Move generation is the whole game: get it wrong and everything above is
decoration. It is verified by **perft**, which counts the leaves of the legal
move tree to a given depth. The counts for a handful of standard positions are
published and exact, so matching them proves castling, en passant, promotion
and check evasion all at once — in combinations nobody would think to write a
test for.

| Position | Depth 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- |
| Initial | 20 | 400 | 8,902 | 197,281 | 4,865,609 |
| Kiwipete | 48 | 2,039 | 97,862 | 4,085,603 | |
| Position 3 | 14 | 191 | 2,812 | 43,238 | 674,624 |
| Position 4 | 6 | 264 | 9,467 | 422,333 | |
| Position 5 | 44 | 1,486 | 62,379 | 2,103,487 | |
| Position 6 | 46 | 2,079 | 89,890 | 3,894,594 | |

All six match. `make GAME=chess test` runs them to depth 3 (and position 3 to
5); `CHESS_SLOW=1 make GAME=chess test` runs every depth in the table, which
takes a couple of minutes because 4.8M nodes of interpreted Lua is not a unit
test.

The board is a **10x12 padded mailbox**, not bitboards and not 0x88. Lua 5.1
has no bitwise operators and the Nspire has no `bit` library, so bitboards are
out — and 64 bits does not fit exactly in a double anyway. The textbook 0x88
trick is `sq & 0x88`, which without an AND is worse than useless. The padding
makes "is that off the board?" a single array lookup, and the two border rows
at each end are what keep a knight's reach inside the array from every square.
Repetition detection, which normally wants Zobrist hashing, builds a string key
instead and counts it in a table; it happens once per played move and never
inside the search.

Moves are packed into a single integer rather than a table, and the search uses
make/unmake with an undo record rather than copying the board — a table per
node would have spent more time in the collector than in the search.

### The bot

Same shape as Connect Four's, and for the same reason: there are no threads on
this machine, so a search that ran to completion inside one `on.timer()`
callback would freeze the screen and queue up keypresses for as long as it
took, which to a player is indistinguishable from a crash. `ai:think(n)`
advances an explicit state machine by `n` nodes and answers either with a move
or "still thinking"; `main.lua` feeds it one slice per tick and paints an
indicator. Because the search is pure logic, the tests drive the very same code
straight through and check that slicing changes *when* it answers and never
*what*.

Iterative deepening with alpha-beta, captures first by MVV-LVA, and a
quiescence search that extends captures only. That last one is not optional: a
two-ply search without it stops in the middle of an exchange and counts the
half that went its way, so it hangs pieces constantly. There is a test for
exactly that — the same position, with and without.

Evaluation is material plus piece-square tables, kept as a running total by
make/unmake so a leaf costs one field read.

**Depth is honestly two to three ply**, plus quiescence. That is what
interpreted Lua on a 396 MHz ARM supports, and the bot is built for it: it
plays legal, sensible chess and punishes a hanging piece. It does not play
well, and is not meant to.

So difficulty comes from move **selection**, not depth — there is no room left
to search less. Every level searches about as deeply as it can, then picks from
the scored root moves with a temperature-weighted softmax: at temperature zero
that is the best move, and as it rises, moves within a pawn or two start to
come up. Easy plays plausible moves that are merely not the best ones, which is
a very different thing from "a random move with probability p" — uniform
blunders are instantly recognisable as a computer throwing a game away.

![The promotion chooser](docs/screenshots/chess-promotion.png)

Snake, Flappy and 2048 keep high scores for the session, and Connect Four
keeps a match tally. They reset when you close the document, because writing
one back would mean saving the document on every death. Chess keeps nothing
between games, but `U` will walk a game back move by move for as long as you
have the patience.

## Installing

1. Connect the calculator over USB. On a Mac the easiest route is
   [TI-Nspire CX II Connect](https://nspireconnect.ti.com) — free, web-based,
   nothing to install, but it **requires Chrome**; Safari has no WebUSB and
   will fail in a way that looks like a hardware fault. TI-Nspire Student or
   Teacher Software works too.
2. Drag `Snake.tns`, `Flappy.tns`, `2048.tns`, `Connect4.tns` or `Chess.tns`
   into the calculator's file list. They must land in **My Documents** directly, not a
   subfolder.
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
make GAME=connect4             # build Connect4.tns
make GAME=chess                # build Chess.tns
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
tests/<game>/frame.lua    reads a game's state back out of a painted frame
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
direction changes the board" rather than "the board is full". All of them end
with a fuzz pass checking structural invariants over thousands of steps.

Connect Four has unusually strong testable properties, and its suite leans on
them. Win detection is checked in all four directions at every position on the
board, and — because the game only ever looks at lines through the last disc
played — against a full-board scan after every move of twelve hundred random
games. The pruned search is checked against a slow, obviously-correct minimax
written inside the test file: over many random positions, at the same depth,
alpha-beta has to pick a move of equal value. The sliced search is checked
against the same search run in one shot, node for node. And the bot plays
fuzz matches against a random player, which it must essentially never lose.

Between them those caught two bugs that no amount of reading would have: the
search left its discs on the board when a budget ran out part-way, and the
board being painted was the board being searched.

Chess is checked the same way and then some. Perft is the centre of it — see
the table above — because a rule test can only be as good as the case someone
thought to write, while perft counts every leaf of the whole move tree against
a number the outside world already knows. On top of that: castling rejected out
of, through and into check but *not* when only b1 is attacked, which is the
half of that rule usually got wrong; en passant legal only on the move right
after the double push, and rejected when taking would uncover the king; every
drawing rule; the pruned search against a plain negamax written in the test
file; the sliced search against the one-shot, node for node; and mate-in-one
and mate-in-two positions, each proved to be one by a brute-force prover in the
test before the bot is asked to find it. That last habit caught two of the
author's own "mate in one" positions being nothing of the sort.

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
- **Bot speed.** How many search nodes a second the handheld manages is the
  one number in Connect Four and Chess that is an estimate rather than a
  measurement —
  the container the tests run on is an x86 desktop. The design does not depend
  on getting it right: the bot's turn is capped in *ticks*, and iterative
  deepening means a slower machine simply plays a shallower search rather than
  hanging. If your calculator is slower than assumed, the bot is a little
  weaker; if it is faster, the bot finishes early and the node budget takes
  over.
- **Timer pacing.** Snake and Flappy run a fixed 0.05 s timer and count ticks
  rather than restarting the timer at new intervals, because granularity varies
  between Nspire OS versions. If your handheld's timer is coarser than 0.05 s
  they run proportionally slower — they won't misbehave, but Snake's top speeds
  may not be reachable, and Flappy will feel heavier than intended. 2048 is
  unaffected: it is turn-based, and a coarse timer only makes its slide
  animation longer, and Connect Four and Chess only spend longer on the bot's
  turn.
- **Whether the font has chess glyphs.** It is not verified that the Nspire's
  font carries U+2654–U+265F, and a missing glyph on this OS is a silent empty
  box — which across sixty-four squares would be unreadable rather than merely
  ugly. So Chess draws letters on coloured discs and does not try.
