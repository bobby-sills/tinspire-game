# Snake for the TI-Nspire CX II
#
#   make          bundle the sources and build Snake.tns
#   make test     run the logic tests under a desktop Lua
#   make clean    remove generated files
#
# Requires: python3, and `luna` on your PATH to produce the .tns
# (https://github.com/ndless-nspire/luna -- `make` in that repo).
# `make test` additionally needs a Lua 5.1 interpreter.

LUA    ?= lua
LUNA   ?= luna
PYTHON ?= python3

BUNDLE := build/snake.lua
TNS    := Snake.tns

.PHONY: all bundle tns test check screenshots clean

all: tns

bundle: $(BUNDLE)

$(BUNDLE): src/game.lua src/main.lua tools/bundle.py
	@$(PYTHON) tools/bundle.py $@
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

# Logic tests run standalone; the UI tests drive the built bundle through a
# mock of the calculator's runtime, so they need it built first.
test: $(BUNDLE)
	@echo "--- game logic ---"
	@$(LUA) tests/run.lua
	@echo "--- nspire runtime ---"
	@$(LUA) tests/run_ui.lua $(BUNDLE)

# Render preview PNGs of real frames into build/screenshots.
screenshots: $(BUNDLE)
	@$(PYTHON) tools/fontmetrics.py
	@$(LUA) tools/screenshot.lua build/frames $(BUNDLE)
	@$(PYTHON) tools/render.py build/frames build/screenshots 3

# Bundle + tests, the way CI would check a change.
check: bundle test

clean:
	@rm -rf build $(TNS)
	@echo "cleaned"
