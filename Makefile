.PHONY: all audit check build dev test lint format install clean \
        cli-build cli-dev cli-test cli-lint cli-format cli-install cli-clean

all: cli-build

# --- Disclosure audit ---

# Refuses deployment-specific details in tracked files. Part of `check`
# rather than an optional extra: a leak cannot be undone by a later commit,
# so the only useful time to catch one is before it is committed.
audit:
	./scripts/check-disclosure.sh

# --- Crystal CLI ---

cli-build:   ; $(MAKE) -C tools/conduit-vpn build
cli-dev:     ; $(MAKE) -C tools/conduit-vpn dev
cli-test:    ; $(MAKE) -C tools/conduit-vpn test
cli-lint:    ; $(MAKE) -C tools/conduit-vpn lint
cli-format:  ; $(MAKE) -C tools/conduit-vpn format
cli-install: ; $(MAKE) -C tools/conduit-vpn install
cli-clean:   ; $(MAKE) -C tools/conduit-vpn clean

# --- Aggregates ---
#
# The macOS app has no targets here yet. They arrive with the app rather
# than being stubbed now, so every target in this file works when invoked.

build:   cli-build
install: cli-install
clean:   cli-clean

check:  audit cli-lint cli-test cli-build
dev:    cli-dev
test:   cli-test
lint:   cli-lint
format: cli-format
