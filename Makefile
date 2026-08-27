# TI-Nspire CX II games
#
# One game per directory under src/. Pick which one with GAME=<name>:
#
#   make                    build src/snake  -> Snake.tns
#   make GAME=2048          build src/2048   -> 2048.tns
#   make GAME=2048 test     run that game's tests
#   make screenshots        render preview PNGs into build/<game>/screenshots
#   make all-games          build every game under src/
#   make clean
#
# Requires: python3, and `luna` on your PATH to produce the .tns
# (https://github.com/ndless-nspire/luna -- `make` in that repo).
# `make test` additionally needs a Lua 5.1 interpreter.

LUA    ?= lua
LUNA   ?= luna
PYTHON ?= python3

GAME   ?= snake

# TNS is the handheld-visible document name: capitalised, no extension fuss.
# Override for a game whose directory name isn't the display name.
TNS_NAME ?= $(shell echo $(GAME) | sed 's/^./\U&/')

SRCDIR := src/$(GAME)
OUTDIR := build/$(GAME)
BUNDLE := $(OUTDIR)/$(GAME).lua
TNS    := $(TNS_NAME).tns

GAMES  := $(notdir $(wildcard src/*))

.PHONY: all bundle tns test check screenshots all-games list clean

all: tns

list:
	@echo "games: $(GAMES)"

bundle: $(BUNDLE)

$(BUNDLE): $(SRCDIR)/game.lua $(SRCDIR)/main.lua tools/bundle.py
	@$(PYTHON) tools/bundle.py $(SRCDIR) $@
	@if command -v $(LUA) >/dev/null 2>&1; then \
		$(LUA) -e "assert(loadfile('$@'))" && echo "syntax OK -> $@"; \
	else \
		echo "note: '$(LUA)' not found, skipping the syntax check"; \
	fi

tns: $(TNS)

$(TNS): $(BUNDLE)
	@if ! command -v $(LUNA) >/dev/null 2>&1; then \
		echo "error: '$(LUNA)' not found on PATH."; \
		echo "       Build it from https://github.com/ndless-nspire/luna (needs zlib), then re-run."; \
		echo "       The bundled script is still available at $(BUNDLE)."; \
		exit 1; \
	fi
	@$(LUNA) $(BUNDLE) $@
	@echo "built -> $@"

# Logic tests run standalone against src/$(GAME); the UI tests drive the built
# bundle through a mock of the calculator's runtime, so they need it built.
test: $(BUNDLE)
	@echo "--- $(GAME): game logic ---"
	@GAME_SRC=$(SRCDIR) $(LUA) tests/$(GAME)/run.lua
	@echo "--- $(GAME): nspire runtime ---"
	@$(LUA) tests/run_ui.lua $(BUNDLE)

# Render preview PNGs of real frames.
screenshots: $(BUNDLE)
	@$(PYTHON) tools/fontmetrics.py
	@$(LUA) tools/screenshot.lua $(OUTDIR)/frames $(BUNDLE) $(GAME)
	@$(PYTHON) tools/render.py $(OUTDIR)/frames $(OUTDIR)/screenshots 3

all-games:
	@for g in $(GAMES); do $(MAKE) --no-print-directory GAME=$$g || exit 1; done

# Bundle + tests, the way CI would check a change.
check: bundle test

clean:
	@rm -rf build *.tns
	@echo "cleaned"
