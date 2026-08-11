SCHEME         := ConduitApp
DERIVED_DATA   := build
CONFIG_DEBUG   := Debug
CONFIG_RELEASE := Release

APP_NAME       := Conduit
USER_APPS_DIR  := $(HOME)/Applications
BUILT_APP      := $(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/$(APP_NAME).app
USER_APP_LINK  := $(USER_APPS_DIR)/$(APP_NAME).app

.PHONY: all generate build release install uninstall clean smoke check

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild \
	  -project ConduitApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

# Sandboxed model checks: build the standalone tool and run it. No app launch,
# no subprocess, no network.
#
# `** BUILD SUCCEEDED **` proves nothing about whether the coding keys match
# what the client emits — a Codable type compiles either way and fails at
# runtime as an empty menu.
smoke: generate
	xcodebuild \
	  -project ConduitApp.xcodeproj \
	  -scheme VPNSmoke \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build
	"$(DERIVED_DATA)/Build/Products/$(CONFIG_DEBUG)/VPNSmoke"

# The pre-commit gate for app changes.
check: build smoke

release: generate
	xcodebuild \
	  -project ConduitApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_RELEASE) \
	  -derivedDataPath $(DERIVED_DATA) \
	  build

# Symlink the built app into ~/Applications so Spotlight, Launchpad, and
# `open -a Conduit` find it. Launch Services registers the underlying bundle,
# so the bundle identifier stays consistent across rebuilds.
install: build
	@mkdir -p "$(USER_APPS_DIR)"
	ln -sfn "$(CURDIR)/$(BUILT_APP)" "$(USER_APP_LINK)"
	@echo "Linked $(USER_APP_LINK) -> $(CURDIR)/$(BUILT_APP)"
	/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister \
	  -f -R "$(USER_APP_LINK)" || true

uninstall:
	rm -f "$(USER_APP_LINK)"
	@echo "Removed $(USER_APP_LINK)"

clean:
	-xcodebuild \
	  -project ConduitApp.xcodeproj \
	  -scheme $(SCHEME) \
	  -configuration $(CONFIG_DEBUG) \
	  -derivedDataPath $(DERIVED_DATA) \
	  clean
	rm -rf $(DERIVED_DATA)
