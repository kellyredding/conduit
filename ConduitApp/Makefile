SCHEME         := ConduitApp
DERIVED_DATA   := build
CONFIG_DEBUG   := Debug
CONFIG_RELEASE := Release

APP_NAME       := Conduit
VERSION        := $(shell cat ../VERSION)
LSREGISTER     := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

XCODEBUILD     = xcodebuild -project ConduitApp.xcodeproj -derivedDataPath $(DERIVED_DATA) \
                   MARKETING_VERSION=$(VERSION)

.PHONY: all generate build release clean smoke check

all: build

generate:
	xcodegen generate

# Builds unregister their own product, which Xcode registers with Launch
# Services, so a development build never shadows the installed app.
build: generate
	$(XCODEBUILD) -scheme $(SCHEME) -configuration $(CONFIG_DEBUG) build
	@$(LSREGISTER) -u "$(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/$(APP_NAME).app" 2>/dev/null || true

# Sandboxed model checks: build the standalone tool and run it. No app launch,
# no subprocess, no network.
#
# `** BUILD SUCCEEDED **` proves nothing about whether the coding keys match
# what the client emits — a Codable type compiles either way and fails at
# runtime as an empty menu.
smoke: generate
	$(XCODEBUILD) -scheme VPNSmoke -configuration $(CONFIG_DEBUG) build
	"$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/VPNSmoke"

# The pre-commit gate for app changes.
check: build smoke

release: generate
	$(XCODEBUILD) -scheme $(SCHEME) -configuration $(CONFIG_RELEASE) build
	@$(LSREGISTER) -u "$(CURDIR)/$(DERIVED_DATA)/Build/Products/$(CONFIG_RELEASE)/$(APP_NAME).app" 2>/dev/null || true

clean:
	-$(XCODEBUILD) -scheme $(SCHEME) -configuration $(CONFIG_DEBUG) clean
	rm -rf $(DERIVED_DATA)
