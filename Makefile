# TextMouth Makefile
# Build and package the app for testing

APP_NAME = TextMouth
SCHEME = TextMouth
PROJECT = TextMouth.xcodeproj
CONFIG = Release
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications

# Where xcodebuild puts the built product
DERIVED_BUILD_DIR = $(BUILD_DIR)/DerivedData
BUILT_APP = $(DERIVED_BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME).app
BUILD_LOG = $(BUILD_DIR)/xcodebuild-$(CONFIG).log
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_NUMBER := $(shell date -u +"%Y%m%d%H%M%S")

.PHONY: all clean build debug run install uninstall generate test open xcode help

## Default: build the app
all: build

## Show available targets
help:
	@echo "TextMouth Build System"
	@echo "====================="
	@echo ""
	@echo "  make build      - Build the app (Release)"
	@echo "  make debug      - Build the app (Debug)"
	@echo "  make run        - Build and run the app"
	@echo "  make open       - Build, package, and open the .app"
	@echo "  make install    - Copy the app to /Applications"
	@echo "  make uninstall  - Remove from /Applications"
	@echo "  make test       - Run the hosted production test suite"
	@echo "  make generate   - Regenerate the Xcode project (requires xcodegen)"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make xcode      - Open the project in Xcode"
	@echo ""

## Regenerate the Xcode project from project.yml
generate:
	@echo "==> Generating Xcode project..."
	xcodegen generate
	@echo "==> Done."

## Build Release
build: generate
	@echo "==> Building $(APP_NAME) ($(CONFIG))..."
	@mkdir -p "$(BUILD_DIR)"
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath "$(DERIVED_BUILD_DIR)" \
		-destination 'platform=macOS' \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
		TEXTMOUTH_GIT_COMMIT="$(GIT_COMMIT)" \
		TEXTMOUTH_BUILD_DATE="$(BUILD_DATE)" \
		build > "$(BUILD_LOG)" 2>&1 || { cat "$(BUILD_LOG)"; exit 1; }
	@tail -5 "$(BUILD_LOG)"
	@# Only package the requested configuration after xcodebuild succeeds.
	@# Searching DerivedData can select an older app from another configuration.
	@test -d "$(BUILT_APP)"
	@rm -rf "$(APP_BUNDLE)"
	cp -R "$(BUILT_APP)" "$(APP_BUNDLE)"
	@echo "==> App built: $(APP_BUNDLE)"

## Build Debug
debug: CONFIG = Debug
debug: build

## Build and launch the app
run: build
	@echo "==> Launching $(APP_NAME)..."
	open "$(APP_BUNDLE)"

## Build and open the .app in Finder (so you can inspect or drag it)
open: build
	@echo "==> Opening $(APP_NAME).app..."
	open "$(APP_BUNDLE)"

## Install to /Applications
install: build
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@# Register the app with Launch Services so Open With menus update
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Installed. TextMouth should now appear in Open With menus."

## Remove from /Applications
uninstall:
	@echo "==> Removing $(INSTALL_DIR)/$(APP_NAME).app..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Removed."

## Run tests against the real application through the hosted test runner
test:
	@echo "==> Running hosted production tests..."
	@cd TextMouthTests && swift run 2>&1
	@echo ""

## Open the project in Xcode
xcode: generate
	open $(PROJECT)

## Clean all build artifacts
clean:
	@echo "==> Cleaning..."
	rm -rf $(BUILD_DIR)
	rm -rf TextMouthTests/.build
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean 2>/dev/null || true
	@echo "==> Clean."
