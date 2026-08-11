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

# --- Swift app ---

app-build:     ; $(MAKE) -C ConduitApp build
app-smoke:     ; $(MAKE) -C ConduitApp smoke
app-check:     ; $(MAKE) -C ConduitApp check
app-release:   ; $(MAKE) -C ConduitApp release
app-install:   ; $(MAKE) -C ConduitApp install
app-uninstall: ; $(MAKE) -C ConduitApp uninstall
app-clean:     ; $(MAKE) -C ConduitApp clean

# --- Aggregates ---

build:   cli-build app-build
install: cli-install app-install
clean:   cli-clean app-clean

check:  audit cli-lint cli-test cli-build
dev:    cli-dev
test:   cli-test
lint:   cli-lint
format: cli-format
