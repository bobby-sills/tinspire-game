# Fruit art

`Fruit+.png` is a 608x96 sprite sheet: a 38x6 grid of 16x16 RGBA sprites, six
variants each of thirty-eight fruits and vegetables. The whole sheet uses only
38 distinct colours, and no single sprite uses more than seven.

## Licence and provenance — read this before redistributing

The sheet was supplied by the repository owner, who says it was published under
**a Creative Commons licence**.

**Which Creative Commons licence was not recorded, and cannot be checked from
this container** — the asset sites these packs are published on are blocked by
the egress proxy here, and nothing in the PNG itself carries the terms. That
distinction matters and this file will not paper over it:

- **CC0** would require nothing at all.
- **CC BY** would require crediting the author by name, which this file
  currently cannot do because the author's name was not recorded either.
- **CC BY-SA** would additionally impose share-alike terms on derived art —
  which the generated sprite data in `src/fruits/main.lua` arguably is.
- **CC BY-NC** would forbid commercial use.

So: the art is used here in good faith on the owner's word, in a
non-commercial hobby repository. **Anyone redistributing this, and anyone
putting it to commercial use, should establish the specific licence and the
author's name first, and fill them in above.** The klondike pack next door
carries a similar note for a similar reason; both are gaps to close, not
conclusions.

## What is kept here

The sheet is committed whole, byte-for-byte as supplied, rather than as seven
extracted sprites. Two reasons: which seven the game uses is a *tuning*
decision that `tools/fruitart.py` records in one table and someone may well
want to revisit, and extracting sprites would produce a derived file whose own
licence position is murkier than the original's.

```
Fruit+.png    608x96 RGBA, a 38x6 grid of 16x16 sprites
```

## Which seven the game uses, and why those

`tools/fruitart.py` names them, as (column, row) into the sheet:

| Kind | Fruit | Cell | Reads as |
| --- | --- | --- | --- |
| 1 | Apple | 0, 0 | red, round |
| 2 | Banana | 7, 2 | yellow, crescent bunch |
| 3 | Grapes | 5, 1 | magenta, big loose cluster |
| 4 | Orange | 9, 4 | orange, cut wedge |
| 5 | Pear | 10, 1 | green, teardrop |
| 6 | Watermelon | 26, 3 | pink and green, triangle |
| 7 | Blueberry | 16, 1 | navy, small tight cluster |

Seven rather than all thirty-eight because an 8x8 board with more colours than
that makes runs rare and deadlock quick — seven is what Bejeweled settled on
for the same reason.

Chosen to differ by **silhouette** and not only by colour, because that is what
a player reads a board by at sixteen pixels and at speed. The near-misses were
deliberately left out, and they are instructive: cherry and strawberry are
Apple's red, pineapple and lemon are Banana's yellow, and the *whole* orange is
Apple's circle again — which is why the orange used here is a cut slice.

## How it reaches the calculator

`tools/fruitart.py` turns these seven into two encodings of the same pixels,
both written into `src/fruits/main.lua`:

- a **TI.Image** string per sprite for `image.new` + `gc:drawImage`, which is
  one draw call a fruit; and
- the **identical pixels as `fillRect` rects**, grouped by colour, for cells
  too small to take a native 16-pixel sprite and for an OS that will not accept
  the string form of `image.new`.

No quantisation is involved in either: at four to seven colours a sprite, there
is nothing to quantise. The generator rebuilds both encodings from exactly the
characters it wrote, compares each against the source pixels, and compares the
two against each other, so a sprite that would draw wrong on the handheld is a
build failure here instead.

The TI.Image byte layout is documented only by TI, and education.ti.com is
blocked here. It came from `wiki.inspired-lua.org/TI.Image` and was then
**confirmed on a real CX II** with `tools/probe/imageprobe2.lua` before
anything depended on it. See the "Drawing images" section of the top-level
README for what that probe established.
