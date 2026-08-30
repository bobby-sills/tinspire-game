# TI-Nspire CX II games

Lua games that install by drag-and-drop — no Ndless, no jailbreak. Each builds
to a `.tns`, an ordinary TI-Nspire document containing a script, which the OS
runs in its built-in sandbox.

**The harness here is game-agnostic and already built. Reuse it — do not write
your own mock runtime, bundler, or screenshot pipeline.**

Games: `snake` (grid-stepped, turn-based feel), `flappy` (continuous physics,
fixed timestep), `2048` (strictly turn-based: no game loop, repaints on input,
timer used only for the slide animation), `connect4` (turn-based, plus a
search that has to be sliced across timer ticks), `chess` (the same, with
rules complicated enough that verifying them is most of the work), `wordle`
(text input rather than steering, bulk data baked into the bundle, and a rule
whose correctness is the whole job), `klondike` (hidden state, unlimited undo,
and a layout that has to adapt at paint time to how much it is asked to show),
`slide` (a generator that has to make illegal states unrepresentable, plus
an independent oracle for the tests to check it against) and `fruits`
(match-three: the same unrepresentable-illegal-state trick, a cascade sliced
across ticks, special pieces that change what a legal move *is*). `fruits` and
`chess` are the two that draw with `gc:drawImage`. Between
them they cover the shapes a new game is likely to take — read whichever is closest to
what you're building.

## Commands

```
make GAME=<name>              build src/<name> -> <Name>.tns
make GAME=<name> test         logic tests + runtime tests
make GAME=<name> screenshots  preview PNGs -> build/<name>/screenshots
make all-games                build everything under src/
make list                     list games
make probes                   hardware probes -> <Name>.tns (not committed)
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
tools/cardart.py        klondike only: card art -> Lua run-length spans
tools/fruitart.py       fruits only: sprites -> TI.Image strings + rects
tools/wordlist.py       wordle only: lists -> Lua string
tools/probe/            throwaway .tns that ask real hardware a question
assets/<game>/          source data, where a game has any
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
  you save the document, which prompts the user on every death. Anything the
  game needs to *know* has to be compiled into the script: Wordle carries a
  13,732-word dictionary as two long Lua strings, one word per line, binary
  searched with `string.sub`. Measure the representation rather than picking
  one -- a table of packed integers was 19% bigger in the `.tns` and 10x slower
  to parse than the plain string it was supposed to beat.
- **There are no threads, and no way to yield to the OS.** Anything expensive
  — a search, a solver, a generator — must be an explicit state machine with a
  work budget that the timer advances one slice per tick. Run it to completion
  inside one `on.timer()` and the screen freezes and keypresses queue up, which
  a player reads as a crash. `src/connect4/game.lua` is the worked example:
  `ai:think(maxNodes)` does bounded work and answers "still thinking" or a
  move, and iterative deepening means there is always a usable answer to give
  whenever the budget runs out. Keep the sliced thing in `game.lua` so tests
  can drive it straight through and check that slicing changes only *when* it
  answers, never *what*.
- **Hidden state is where the bugs live, and undo is where they surface.** If
  a game has information the player cannot see, prefer make/unmake against a
  small undo record over a snapshot per move -- it is smaller, it makes undo
  unlimited for free, and it forces you to write down exactly what a move
  changed. Record the *concealment* too: `src/klondike/game.lua` stores whether
  a move turned a face-down card up, because an undo that leaves it face-up has
  handed the player information the position never contained, and nothing on
  screen says so. Test it by fuzzing every legal move from thousands of
  positions: make it, unmake it, and compare a serialisation of the *entire*
  state, hidden parts included. `tests/chess/run.lua` and
  `tests/klondike/run.lua` both do this, and it is the highest-value test in
  either file.
- **If half the states a generator can produce are broken, don't filter them
  out -- make them unrepresentable.** Exactly half of all permutations of a
  sliding puzzle cannot be reached from the solved state, and the player cannot
  tell an impossible board from a hard one, so they lose to the generator with
  nothing on screen to say so. `src/slide/game.lua` never permutes anything: it
  walks random *legal moves* out of the solved position, which is the same
  reason Flappy's pipes are fenced by the physics rather than filtered
  afterwards. Then implement the check you decided not to need anyway, purely
  as a test oracle -- `Puzzle.isSolvable` counts inversions and nothing in the
  game ever calls it -- so that two mechanisms sharing no code have to agree.
  Pin the oracle first against cases whose answer follows from how they were
  built, because a backwards oracle agreeing with a backwards generator proves
  nothing. The invariant worth the most here is the third one: assert that a
  legal *move* never changes solvability, over thousands of them. That is what
  catches a move implementation quietly corrupting the board.
- **Anything long-running gets a copy of the state, not the live one.** A
  suspended search is suspended mid-mutation; if it shares the board with the
  renderer, `on.paint` draws its half-explored guesses. Connect Four hit this
  exactly.
- **No bitwise operators.** This is Lua 5.1 with no `bit` library, so the usual
  bitboard tricks are out. Plain arrays. `src/chess/game.lua` is the worked
  example of what that costs: no bitboards, and the textbook 0x88 board is out
  too since it is an AND — a padded mailbox instead, where off-board detection
  is one array lookup. Zobrist hashing needs XOR, so repetition detection
  builds a string key and counts it in a table. `src/klondike/game.lua` encodes
  a card as one integer `(suit - 1) * 13 + rank` and unpacks it with division
  and modulo, for the same reason.
- **Anything that animates a *settled* board is a new running cost, so gate
  it.** `fruits` flashes a white outline on its power fruit, which means
  repainting a board that is otherwise doing nothing. It repaints only when the
  flash turns over, and only while a power fruit is on the board, so the common
  case stays at zero repaints. Note what *scaling* costs, which is why the
  sprite itself no longer throbs: `gc:drawImage` cannot scale, so anything that
  changes size drops off the one-call image path onto the rects -- 73 of them
  against one blit. It repaints only when the throb
  changes step -- once every three ticks, not every tick -- and only while a
  power fruit is actually on the board, so the common case stays at zero
  repaints. And watch what it does to the tests: `tests/fruits/frame.lua` used
  to decide the board had settled by waiting for the repaint requests to stop,
  which a board that throbs forever never does. Settling is now judged from
  whether the *fruit* have stopped moving, which is what it always meant.
- **Repaint is all-or-nothing.** `platform.window:invalidate()` redraws
  everything; only call it when something changed. A turn-based game can skip
  the timer entirely and repaint on input.
- **`image.new` works, and the format is written down below.** This used to
  say the layout was undocumented and a wrong guess painted nothing -- true,
  and it cost a day. It is now settled, on real hardware, by
  `tools/probe/imageprobe2.lua`: a document that builds a dozen candidate
  encodings and labels each on screen, so a human with a calculator can read
  back which one painted. Build your own with `make probes` whenever a
  question can only be answered by the device; it is far cheaper than guessing.

  TI.Image is a **20-byte little-endian header** -- u32 width, u32 height, u8
  alignment (0), u8 flags (0), u16 padding (0), u32 stride (2 * width), u16
  bits per pixel (16), u16 planes (1) -- then 16-bit little-endian pixels laid
  out `A RRRRR GGGGG BBBBB`: **RGB555 with alpha in the TOP bit**, 0 meaning
  the pixel is not drawn. Note 555 and not 565, and 20 bytes and not 16; either
  mistake alone is fatal. The OS validates the header and rejects a bad one
  with "image header mismatch", so this fails loudly rather than silently.
  `image.new` takes the string only at `apilevel < 2.3`; from 2.3 it wants a
  `TI.ResourceHandle` from TI's SDK. `tools/bundle.py` emits 2.0, so the string
  path is the one you get. `tests/nspire_stub.lua` models it and validates just
  as strictly, and `tools/render.py` rasterises `drawImage`.

  This matters most when a game repaints on a timer rather than on a key:
  `fruits` draws a full 8x8 board in 64 `drawImage` calls where the same pixels
  cost ~4100 rects. Wrap `image.new` in a `pcall` and keep a `fillRect` path
  behind it anyway -- one calculator on one OS is what has been checked, and
  the rects are also what scales when a cell is smaller than the sprite. Make
  the fallback all-or-nothing: half a board in each encoding reads as a bug.

  Note what the blit costs in colour: TI.Image holds five bits a channel, so an
  ink comes back off the image up to 7/255 from where it started. That is why
  `tests/chess/frame.lua` and `tests/fruits/frame.lua` both key colours at the
  handheld's depth rather than at eight bits -- otherwise the same sprite reads
  as two different things depending on which encoding drew it.

- **Whether to blit or to run is a question about size and repaint rate, and it
  is answered by measuring, not by taste.** Both are now worked examples:
  - `chess` blits. 12 sprites at 16x16 are 25 KB of escaped source, and a full
    board went from ~940 rects to 32 `drawImage` calls. It repaints only on a
    key, but that is *every* key, and the arrow keys move a cursor one square
    at a time. `tools/sprites.py` emits both encodings and checks them against
    the art and against each other.
  - `klondike` does not, and that is measured too: 53 cards at 37x52 come to
    721 KB of escaped Lua source, **9.4x the whole 77 KB bundle**, and the
    twelve face cards' unique art (~180 KB) means decomposing into shared pips
    would not rescue it either. It repaints only on a key, so the rects cost
    once per keystroke. `tools/cardart.py` carries the working.

  So: a flat shape is already one call and gains nothing from an image; art
  that repaints on a timer should almost always be blitted; art that repaints
  on a key should be blitted if it fits. Everything else here -- `snake`,
  `flappy`, `2048`, `connect4`, `wordle`, `slide` -- draws 90 rects a frame or
  fewer and has nothing to win. Measured, per frame, across all nine games.

- **When runs are the answer, group them by colour**, because the colour change
  is the expensive part, not the rect. `tools/sprites.py` still emits its runs
  that way for the fallback path.
- **Encode only what is not a flat fill.** A sprite that is mostly one colour
  should be a couple of rects plus run-encoded ink, not runs all the way
  through: `tools/cardart.py` takes a 37x52 card from 1924 pixels to ~150 runs
  that way, and packs each run into three printable ASCII characters rather
  than a comma-separated list of numbers, which is a third of the source size
  and decodes with `string.byte` alone. Emit the runs in row order so a
  partially covered sprite can stop reading as soon as it passes the bottom of
  its visible strip. Whatever the scheme, have the generator rebuild each
  sprite from what it emitted and compare against the source image -- a
  mis-encoded sprite is otherwise a silent wrong picture on the handheld and
  nowhere else.
- **Font metrics are unknown until runtime -- HEIGHTS as well as widths.**
  Always size boxes with `gc:getStringWidth` and `gc:getStringHeight`, never a
  character-count estimate and never a row height written down as a number.
  Have layouts degrade when text is bigger than expected rather than assuming
  it fits. `fruits` shipped a side panel whose row heights were constants
  tuned against the mock's DejaVu; on the calculator, whose font is taller, the
  rule ran through its own heading and the progress bar sat on the word it
  labelled. The preview could not see it, because the preview measures with
  the font the layout was tuned against.
  `tests/nspire_stub.lua` has a `stub.metricsScale` knob that inflates both
  measurements, so a layout can be tested against a font *bigger* than
  DejaVu -- `tests/fruits/ui.lua` renders the panel at up to 1.5x and asserts
  nothing collides. Use it for any panel of stacked text.
- **Colours** are integers 0–255. Font sizes are limited (7, 9, 10, 11, 12, 16,
  24); the mock rejects others. Anchors are `top`/`middle`/`baseline`. The
  preview renderer anchors text at the top left, so use `"top"` and centre by
  hand from `getStringHeight` — `"middle"` looks right on the device and wrong
  in `make screenshots`.
- **Size a glyph from the widest glyph, not the one in hand.** Fitting each
  letter to its own box independently gives `I` a bigger font than `W` in the
  key beside it, and a row of keys comes out visibly ragged.
  `src/wordle/main.lua` measures all 26 letters once per box size and caches
  the result.
- Changing colour is a call, so quantise gradients into bands instead of
  setting a new colour per element.
- **`math.randomseed` does not take on the handheld.** It returns without
  complaint and changes nothing, so `math.random` replays one sequence from
  launch to launch and a game deals an identical round every time the document
  is opened. Found by playing the built `.tns` on real hardware: Wordle's answer
  was "fatal" every single time. `os` is not there to fall back on either.
  So don't seed `math.random` — own the generator. `src/wordle/game.lua` has
  `Wordle.newRandom`, a MINSTD LCG in plain arithmetic (no bitwise operators,
  and every product under 2^53 so it stays exact in a double), seeded from
  entropy the host folds in from every tick, key and click. Seed it from a
  *count of timer ticks* and remember that two launches differ by only a few:
  a raw LCG from a small seed returns a tiny first value, so seeds 1..10 all
  pick the same word until you scramble and warm up.
- **The mock hides this.** `tests/nspire_stub.lua` seeds `math.random` itself
  and only then neutralises `randomseed`, so each round in a test draws a fresh
  value and the launch-to-launch repeat never appears. To test seeding, nil out
  `os` and pin `math.random` to a constant first — `tests/wordle/ui.lua`'s
  `withSandbox` does exactly that, and fails on the old code.
- `slide` and `fruits` own their generators the same way and for the same
  reason: a board that deals the identical opening at every launch is that bug
  wearing different clothes. The other six games still seed with
  `math.randomseed(os.time() + ...)` and so deal the same opening every launch
  on hardware.
- **Owning the generator is only half of it -- deal at the right moment too.**
  `fruits` owned its RNG from the start and still dealt the same board every
  launch, because the board behind the title screen is dealt at *load*, when
  the only entropy there has ever been is the seed's initial value, and
  pressing enter started the round without dealing a new one. Deal when play
  starts, from entropy accumulated while the player sat on the title screen.
- **A test that identifies things by a handle can pass on handle churn alone.**
  The test that should have caught the above compared boards by the identity of
  the sprite in each cell, and the mock numbered images from a counter that ran
  for the life of the process rather than per document -- so two launches of
  the same board looked different. `stub.load` now restarts image numbering per
  document, which is what the calculator does. If a test tells two things apart
  by an identifier, check the identifier is a property of the thing.

## Testing without a calculator

Three layers, cheapest first. All of it runs in this container.

1. `tests/<game>/run.lua` — the rules, under desktop Lua. Fuzz over many random
   moves and assert structural invariants, not just happy paths. Where the
   rules are standard enough to have published reference numbers, use them:
   chess's move generator is checked by perft against counts the outside world
   already knows, which proves more in one test than every hand-written rule
   case in that file put together. Where a rule has an exact characterisation
   instead, assert *that*, over a fuzz of thousands of real inputs: Wordle's
   colouring is pinned by five properties that between them leave the answer
   no freedom, which is worth more than any number of examples. Prove a
   fixture is what you think it is rather than asserting from memory — several
   "mate in one" positions written from memory here were not mates in one, and
   a hard-mode fixture written the same way passed for the wrong reason.
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

Nor does it tell you how fast the handheld is. If you need a work budget,
measure the cost on this container, say so in the comment, state the
device factor you assumed, and then design so that being wrong about it
degrades gracefully rather than breaking — Connect Four caps the bot's turn in
*ticks* and lets iterative deepening decide the depth that fits.

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
3. Optionally `tests/<name>/ui.lua` and `tests/<name>/autoplay.lua`. A
   `tests/<name>/frame.lua` that reads the board back out of the paint calls
   is worth writing before either — see 2048 and connect4 — because it is what
   lets both of them drive the game without a test-only hook in `src/`.
   If two things on screen share a colour (Wordle's tiles and its keyboard
   both use the mark colours), give one of them a backing rect in a colour
   nothing else uses; the frame reader can then separate them by geometry.
4. `make GAME=<name> test && make GAME=<name>`.
5. Commit the built `<Name>.tns` at the repo root — it's the deliverable people
   download and drag onto the calculator. Verify it's byte-identical to a fresh
   rebuild before committing.

## Conventions

- Commit the generated `.tns` and `build/<game>/<game>.lua`; the bundle is
  useful for pasting into TI's Script Editor.
- Don't add test-only hooks to `src/`.
- Comment the non-obvious *why*, not the obvious *what*.
