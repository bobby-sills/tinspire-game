# Games for the TI-Nspire CX II

Nine games written in TI-Nspire Lua. They install by drag-and-drop — **no
Ndless, no jailbreak, no root**. Each `.tns` is an ordinary TI-Nspire document
that happens to contain a Lua script, so the OS runs it in its built-in sandbox
exactly like a TI-authored one.

Grab the ones you want and copy them onto your calculator:

[`Snake.tns`](Snake.tns) ·
[`Flappy.tns`](Flappy.tns) ·
[`2048.tns`](2048.tns) ·
[`Connect4.tns`](Connect4.tns) ·
[`Chess.tns`](Chess.tns) ·
[`Wordle.tns`](Wordle.tns) ·
[`Klondike.tns`](Klondike.tns) ·
[`Slide.tns`](Slide.tns) ·
[`Fruits.tns`](Fruits.tns)

## Installing

1. Connect the calculator over USB. On a Mac the easiest route is
   [TI-Nspire CX II Connect](https://nspireconnect.ti.com) — free, web-based,
   nothing to install, but it **requires Chrome**; Safari has no WebUSB and
   fails in a way that looks like a hardware fault. TI-Nspire Student or
   Teacher Software works too.
2. Drag the `.tns` files into the calculator's file list. They must land in
   **My Documents** directly, not a subfolder.
3. On the handheld, open **My Documents**, pick one, and press `enter`.

Requires OS 3.0.2 or newer, which every CX II ships with. There is nothing else
to install.

Every game is played with the arrow keys, `enter` and `esc`; `esc` or `P`
pauses, and `R` restarts. Clicking with the touchpad works everywhere too.

## The games

### Snake

![Title screen](docs/screenshots/title.png)
![In play](docs/screenshots/playing.png)

Steer with the arrows, `WASD` or the number pad. Apples are worth `10 x level`,
every 4 apples speeds the snake up to a cap at level 10, and following your own
tail is legal. `M` toggles solid walls and wrap-around between rounds. Fill the
board and you win.

### Flappy Bird

![Title screen](docs/screenshots/flappy-title.png)
![In play](docs/screenshots/flappy-playing.png)

One tap per gap — `enter`, space, up, or a click. The flap *sets* the bird's
speed rather than adding to it, so panicking out of a dive works. Each pipe is
a point and the gap tightens every 5 pipes, and every gap is generated to be
reachable from the one before it, so you only ever lose to your own thumbs.

### 2048

![Title screen](docs/screenshots/2048-title.png)
![In play](docs/screenshots/2048-playing.png)

Slide the whole board with the arrows; equal tiles that collide merge into
their sum. A move that changes nothing costs nothing — no new tile, no turn
spent. `U` or `backspace` undoes a move, including the one that ended the game.

### Connect Four

![In play](docs/screenshots/connect4-playing.png)
![The bot thinking](docs/screenshots/connect4-thinking.png)

Two players on one calculator, or one against a bot with four difficulties.
Left/right moves the cursor, `enter` drops, and `1`–`7` drops straight into a
column. Red always moves first, and who opens alternates between rounds.

### Chess

![A piece picked up](docs/screenshots/chess-selected.png)
![Checkmate](docs/screenshots/chess-checkmate.png)

Full legal chess — castling, en passant, promotion to any piece, the fifty-move
rule, threefold repetition and insufficient material — against a bot with three
difficulties, or hot-seat. Picking a piece up marks every square it may legally
go to: a dot for a quiet move, a ring for a capture. `U` takes a move back, `F`
turns the board round.

### Wordle

![In play](docs/screenshots/wordle-playing.png)
![A win](docs/screenshots/wordle-win.png)

Six goes at a five-letter word, typed on the calculator's own keyboard. Green
is the right letter in the right place, yellow the right letter in the wrong
place. `H` on the title screen turns on hard mode. Guesses are checked against
a 13,732-word dictionary baked into the document.

### Klondike

![The deal](docs/screenshots/klondike-deal.png)
![A run picked up](docs/screenshots/klondike-selected.png)

Solitaire, the one that shipped with Windows. Draw one or draw three, unlimited
or three stock passes, and optional autoplay to the foundations. **Every pile a
card can legally go to is highlighted**, which on a 318-pixel screen is the
difference between playing and guessing. `U` undoes all the way back to the
deal.

### Slide

![In play](docs/screenshots/slide-playing.png)
![Solved](docs/screenshots/slide-solved.png)

The 15-puzzle, at 3x3, 4x4 or 5x5 (`S`). Tiles already in their final place are
drawn green. `H` plays one move toward a solution, `U` undoes without limit,
and every puzzle it deals is guaranteed solvable.

### Fruits

![Title screen](docs/screenshots/fruits-title.png)
![A cascade](docs/screenshots/fruits-cascade.png)

Match three: swap two neighbouring fruit to line up three or more, they clear,
the ones above fall in, and whatever lands may line up again. Pick a fruit up
with `enter` and press a direction to swap it. Longer matches leave special
fruit behind, and cascades multiply the score up to x12. `H` lights a swap that
works, for 20 points.

## Building it yourself

You only need this if you want to change a game — the committed `.tns` files
are ready to use.

```
make GAME=snake                # build Snake.tns   (GAME defaults to snake)
make GAME=snake test           # that game's logic + runtime tests
make GAME=snake screenshots    # preview PNGs -> build/snake/screenshots
make all-games                 # build everything under src/
make list                      # list games
```

Needs [luna](https://github.com/ndless-nspire/luna) (the open-source
Lua-to-`.tns` converter) on your `PATH`, plus python3; Lua 5.1 for the tests
and Pillow for the screenshots are optional. If you'd rather not build
anything, paste `build/<game>/<game>.lua` into the Student Software's script
editor (**Insert > Script Editor**) and save the document from there.

[**docs/DESIGN.md**](docs/DESIGN.md) is the long version: how each game works,
why it is built the way it is, what the handheld's constraints forced, and what
the tests can and cannot prove without real hardware.

## Credits

The playing cards are
[Kin Pixel Playing Cards](https://the-wild-kin.itch.io/kin-pixel-playing-cards)
by **KIN**. The chess pieces are
[Pixel Chess](https://brosen.itch.io/pixel-chess) by **brosen**. Fruits'
sprites are a CC0 sheet supplied by the repository owner. Wordle's
accepted-guess list is **SCOWL**, Copyright 2000-2011 Kevin Atkinson, filtered
to five letters; its notice travels with it in
[`assets/wordle/SCOWL-COPYRIGHT.txt`](assets/wordle/SCOWL-COPYRIGHT.txt).

Each pack's terms, and what could and could not be verified about them from
here, are recorded in the `README.md` beside the art in `assets/`. Everything
else here is original.
