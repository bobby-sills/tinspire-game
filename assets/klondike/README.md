# Card art

The 52 card faces and the back are **"Kin Pixel Playing Cards"** by **KIN**,
published at <https://the-wild-kin.itch.io/kin-pixel-playing-cards> as a free
("name your own price") pixel-art asset pack.

## Licence

The pack does not carry a named licence such as CC0 or MIT. What it carries is
a sentence in its own description:

> Feel free to use these assets in anyway you please, although I'd appreciate
> paying the suggested price if used commercially.

**That quote could not be read from the source in this container.**
`itch.io` is blocked by the egress proxy here, so the wording above is what two
independent web searches returned for the pack, agreeing with each other; it
has not been checked against the page itself. Anyone relying on it should open
the itch.io page and confirm. The pack's own resolution — 37x52 — *was*
verified here, directly from the pixels, and matches what those searches say.

This repository is not a commercial use. If that ever changes, the sentence
above asks for the suggested price to be paid, which is a small and easy thing
to honour.

## What is kept here, and what is not

The files are byte-for-byte as published. The pack also ships a `All.png`
sprite sheet, two jokers and four further back designs (`Back_2`..`Back_5`,
the same lattice in other inks); none of them is used, so none of them is
committed.

```
Clubs_ACE.png .. Spades_K.png   52 faces, 37x52, RGBA
Back_1.png                      the one card back the game draws
```

`tools/cardart.py` turns these into the run-length spans in
`src/klondike/main.lua`. It rebuilds every sprite from the spans it emitted and
compares against the PNG pixel for pixel, so a card that draws wrong on the
calculator is a build failure here rather than a surprise on the handheld.

## Why the art shapes the layout

The pack puts a rank glyph and a suit pip in the **top-left corner** of each
card (rows 3-7 and 9-14 of 52), mirrored in the bottom-right. That is what
makes a fanned tableau column readable: a covered card only shows its top
strip, and ~9 visible rows are enough for the rank, ~16 for the rank and the
suit. Art that centred a large pip with no corner index could not be fanned at
all, and the game would have had to draw an index over the top of it.
