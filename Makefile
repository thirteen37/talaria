CONFIGURATION ?= Debug
INSTALL_DIR ?= /Applications

DERIVED_DATA_PATH := build/DerivedData
APP_PATH := $(DERIVED_DATA_PATH)/Build/Products/$(CONFIGURATION)/Talaria.app

.PHONY: generate build install clean
.DEFAULT_GOAL := build

generate:
	@command -v xcodegen >/dev/null 2>&1 || { echo "xcodegen not found on PATH; install it (e.g. 'brew install xcodegen')" >&2; exit 1; }
	xcodegen generate

build: generate
	xcodebuild build \
		-project Talaria.xcodeproj \
		-scheme Talaria \
		-configuration $(CONFIGURATION) \
		-destination 'platform=macOS' \
		-derivedDataPath $(DERIVED_DATA_PATH)

install: build
	@test -d "$(APP_PATH)" || { echo "$(APP_PATH) not found; build did not produce an app" >&2; exit 1; }
	rm -rf "$(INSTALL_DIR)/Talaria.app"
	ditto "$(APP_PATH)" "$(INSTALL_DIR)/Talaria.app"

clean:
	rm -rf $(DERIVED_DATA_PATH)
