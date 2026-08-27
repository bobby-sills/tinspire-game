# Snake and Flappy Bird for the TI-Nspire CX II
#
#   make          bundle the sources and build both .tns files
#   make snake    just Snake.tns
#   make flappy   just Flappy.tns
#   make test     run the logic and runtime tests for both games
#   make clean    remove generated files
#
# Requires: python3, and `luna` on your PATH to produce the .tns
# (https://github.com/ndless-nspire/luna -- `make` in that repo).
# `make test` additionally needs a Lua 5.1 interpreter.

LUA    ?= lua
LUNA   ?= luna
PYTHON ?= python3

SNAKE_BUNDLE  := build/snake.lua
SNAKE_TNS     := Snake.tns
FLAPPY_BUNDLE := build/flappy.lua
FLAPPY_TNS    := Flappy.tns

BUNDLES := $(SNAKE_BUNDLE) $(FLAPPY_BUNDLE)

.PHONY: all bundle snake flappy test check screenshots clean

all: snake flappy

bundle: $(BUNDLES)

# A bundle is only worth shipping if it parses, so the syntax check rides along
# with every build rather than waiting for `make test`.
define check_syntax
	@if command -v $(LUA) >/dev/null 2>&1; then \
		$(LUA) -e "assert(loadfile('$(1)'))" && echo "syntax OK -> $(1)"; \
	else \
		echo "note: '$(LUA)' not found, skipping the syntax check"; \
	fi
endef

$(SNAKE_BUNDLE): src/game.lua src/main.lua tools/bundle.py
	@$(PYTHON) tools/bundle.py $@ snake
	$(call check_syntax,$@)

$(FLAPPY_BUNDLE): src/flappy.lua src/flappy_main.lua tools/bundle.py
	@$(PYTHON) tools/bundle.py $@ flappy
	$(call check_syntax,$@)

snake: $(SNAKE_TNS)
flappy: $(FLAPPY_TNS)

define build_tns
	@if ! command -v $(LUNA) >/dev/null 2>&1; then \
		echo "error: '$(LUNA)' not found on PATH."; \
		echo "       Build it from https://github.com/ndless-nspire/luna (needs zlib), then re-run."; \
		echo "       The bundled script is still available at $(1)."; \
		exit 1; \
	fi
	@$(LUNA) $(1) $(2)
	@echo "built -> $(2)"
endef

$(SNAKE_TNS): $(SNAKE_BUNDLE)
	$(call build_tns,$(SNAKE_BUNDLE),$@)

$(FLAPPY_TNS): $(FLAPPY_BUNDLE)
	$(call build_tns,$(FLAPPY_BUNDLE),$@)

# Logic tests run standalone; the UI tests drive the built bundles through a
# mock of the calculator's runtime, so they need them built first.
test: $(BUNDLES)
	@echo "--- snake logic ---"
	@$(LUA) tests/run.lua
	@echo "--- snake runtime ---"
	@$(LUA) tests/run_ui.lua $(SNAKE_BUNDLE)
	@echo "--- flappy logic ---"
	@$(LUA) tests/run_flappy.lua
	@echo "--- flappy runtime ---"
	@$(LUA) tests/run_ui_flappy.lua $(FLAPPY_BUNDLE)

# Render preview PNGs of real frames into build/screenshots.
screenshots: $(BUNDLES)
	@$(PYTHON) tools/fontmetrics.py
	@$(LUA) tools/screenshot.lua build/frames $(SNAKE_BUNDLE)
	@$(LUA) tools/screenshot_flappy.lua build/frames-flappy $(FLAPPY_BUNDLE)
	@$(PYTHON) tools/render.py build/frames build/screenshots 3
	@$(PYTHON) tools/render.py build/frames-flappy build/screenshots-flappy 3

# Bundle + tests, the way CI would check a change.
check: bundle test

clean:
	@rm -rf build $(SNAKE_TNS) $(FLAPPY_TNS)
	@echo "cleaned"
