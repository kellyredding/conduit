.PHONY: all audit check build dev test lint format clean \
        cli-build cli-check cli-dev cli-test cli-lint cli-format cli-install cli-clean \
        app-build app-smoke app-check app-release app-clean

all: cli-build

# --- Disclosure audit ---

# Refuses deployment-specific details in tracked files. Part of `check`
# rather than an optional extra: a leak cannot be undone by a later commit,
# so the only useful time to catch one is before it is committed.
audit:
	./scripts/check-disclosure.sh

# --- Crystal CLI ---

cli-build:   ; $(MAKE) -C tools/conduit-vpn build
cli-check:   ; $(MAKE) -C tools/conduit-vpn check
cli-dev:     ; $(MAKE) -C tools/conduit-vpn dev
cli-test:    ; $(MAKE) -C tools/conduit-vpn test
cli-lint:    ; $(MAKE) -C tools/conduit-vpn lint
cli-format:  ; $(MAKE) -C tools/conduit-vpn format
# The CLI alone, unsigned, for iterating on it. The app is installed only by
# install.sh (`conduit-vpn update --local` for a checkout).
cli-install: ; $(MAKE) -C tools/conduit-vpn install
cli-clean:   ; $(MAKE) -C tools/conduit-vpn clean

# --- Swift app ---

app-build:     ; $(MAKE) -C ConduitApp build
app-smoke:     ; $(MAKE) -C ConduitApp smoke
app-check:     ; $(MAKE) -C ConduitApp check
app-release:   ; $(MAKE) -C ConduitApp release
app-clean:     ; $(MAKE) -C ConduitApp clean

# --- Aggregates ---

build:   cli-build app-build
clean:   cli-clean app-clean

# Delegates rather than restating the CLI's own gate. Spelling the steps out
# here once meant they drifted: this ran the specs and only then rebuilt the
# binary they exercise, so every run tested the previous build. A suite that
# reports on code that is no longer there is worse than no suite.
check:  audit cli-check
dev:    cli-dev
test:   cli-test
lint:   cli-lint
format: cli-format
