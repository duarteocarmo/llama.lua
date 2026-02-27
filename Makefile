default: help

TESTS_INIT=tests/minimal_init.lua
TESTS_DIR=tests/

.PHONY: help
help: # Show help for each of the Makefile recipes.
	@grep -E '^[a-zA-Z0-9 -]+:.*#'  Makefile | sort | while read -r l; do printf "\033[1;32m$$(echo $$l | cut -f 1 -d':')\033[00m:$$(echo $$l | cut -f 2- -d'#')\n"; done

.PHONY: test
test: # Run tests
	@nvim \
		--headless \
		--noplugin \
		-u ${TESTS_INIT} \
		-c "PlenaryBustedDirectory ${TESTS_DIR} { minimal_init = '${TESTS_INIT}' }"

.PHONY: format
format: # Format with stylua
	stylua lua/ tests/

.PHONY: lint
lint: # Lint with selene and check formatting with stylua
	selene lua/
	stylua --check lua/ tests/

.PHONY: check
check: lint test # Run lint and tests
