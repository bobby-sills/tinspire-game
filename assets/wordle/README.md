# Wordle word lists

Two lists, both plain text, one lowercase five-letter word per line, sorted in
byte order with no duplicates. `tools/wordlist.py` bakes them into
`src/wordle/game.lua` and refuses to emit anything that breaks those rules.

They are kept here rather than only in generated form so the dictionary is
reviewable: a bad entry is a word the player can never guess, or worse, an
answer they can never reach.

## `answers.txt` — 2,315 words

The pool the game draws its answer from.

Supplied by the repository owner, extracted from the JavaScript bundle of the
original (pre-New-York-Times) Wordle. It is the game's curated answer list:
common words, no plurals of the `-s` kind, nothing obscure.

**Licence: none stated.** The selection is Josh Wardle's, and the New York
Times has owned Wordle since 2022. Individual words are facts and carry no
copyright, and a bare alphabetical list of common English words is thin
material for a claim — but the *curation* is the part with any originality in
it, and no permission to redistribute it has ever been given. It is reproduced
here for a non-commercial hobby port. If that matters for your use, replace
`answers.txt` with any list you like and re-run `tools/wordlist.py`; nothing in
`src/wordle/` knows or cares where the words came from.

## `guesses.txt` — 11,417 words

Every word the game will accept as a guess. A superset of `answers.txt`, which
`tools/wordlist.py` enforces — an answer the player cannot type would be a
cruel bug.

Built from Debian's `wamerican-huge` package, version `2020.12.07-2`:

    LC_ALL=C grep -E '^[a-z]{5}$' /usr/share/dict/american-english-huge

11,406 words, plus the 11 answers SCOWL does not carry — de-accented loanwords
(`eclat`, `etude`, `melee`, `ombre`, `saute`, `voila`), British spellings
(`fibre`, `moult`, `leant`), and `cyber` and `masse`.

That package is **SCOWL** (Spell Checker Oriented Word Lists), Copyright
2000–2011 Kevin Atkinson. Its terms are permissive and require the notice to
travel with the words, which is why `SCOWL-COPYRIGHT.txt` sits beside them here:

> Permission to use, copy, modify, distribute and sell these word lists, the
> associated scripts, the output created from the scripts, and its
> documentation for any purpose is hereby granted without fee, provided that
> the above copyright notice appears in all copies and that both that
> copyright notice and this permission notice appear in supporting
> documentation.

`SCOWL-COPYRIGHT.txt` is Debian's copyright file for the package, verbatim. It
credits the components SCOWL is assembled from, several of which (Moby Words
II, Brian Kelk's frequency list) are explicitly public domain.

## Regenerating

    python3 tools/wordlist.py            # rewrite the block in src/wordle/game.lua
    python3 tools/wordlist.py --check    # exit 1 if that block is out of date
