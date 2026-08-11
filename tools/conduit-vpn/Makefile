.PHONY: build install clean test lint format check dev

PREFIX   ?= $(HOME)/.conduit
BINDIR   ?= $(PREFIX)/bin
LINKDIR  ?= $(HOME)/.local/bin
BUILDDIR ?= build

test:
	crystal spec

lint:
	crystal tool format --check src spec

format:
	crystal tool format src spec

# `dev` first: the integration specs exercise the built binary as a
# subprocess, so they have nothing to run until it exists.
check: dev test lint

dev: format
	@mkdir -p $(BUILDDIR)
	crystal build -o $(BUILDDIR)/conduit-vpn src/conduit_vpn.cr

build:
	@mkdir -p $(BUILDDIR)
	shards install
	crystal build --release --no-debug -o $(BUILDDIR)/conduit-vpn src/conduit_vpn.cr

# Two compilations on purpose. `check` validates behavior against the dev
# binary; `build` produces the optimized artifact that gets installed.
# Collapsing them would ship a binary no spec ever ran against.
install: check build
	install -d $(BINDIR) $(LINKDIR)
	install -m 755 $(BUILDDIR)/conduit-vpn $(BINDIR)/conduit-vpn
	ln -sfn $(BINDIR)/conduit-vpn $(LINKDIR)/conduit-vpn
	@# Documents every setting, and is never read back. Regenerated on each
	@# install so it tracks the defaults in the binary beside it, rather than
	@# the ones that happened to ship the first time it was written.
	$(BINDIR)/conduit-vpn config example > $(PREFIX)/config.example.json
	@echo "installed $(BINDIR)/conduit-vpn"
	@echo "linked    $(LINKDIR)/conduit-vpn"
	@echo "wrote     $(PREFIX)/config.example.json"

clean:
	rm -rf $(BUILDDIR) lib .shards
