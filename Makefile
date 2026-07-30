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
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_NUMBER := $(shell date -u +"%Y%m%d%H%M%S")

.PHONY: all clean build run install uninstall generate test open help

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
	@echo "  make test       - Run the parser test suite"
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
	@mkdir -p $(BUILD_DIR)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(DERIVED_BUILD_DIR) \
		-destination 'platform=macOS' \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
		TEXTMOUTH_GIT_COMMIT="$(GIT_COMMIT)" \
		TEXTMOUTH_BUILD_DATE="$(BUILD_DATE)" \
		build \
		| tail -5
	@# Copy the .app bundle to build/ for easy access
	@APP_PATH=$$(find $(DERIVED_BUILD_DIR) -name "$(APP_NAME).app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			rm -rf "$(APP_BUNDLE)" && \
			cp -R "$$APP_PATH" "$(APP_BUNDLE)" && \
			echo "==> App built: $(APP_BUNDLE)"; \
		else \
			echo "ERROR: Could not find built .app bundle" && exit 1; \
		fi

## Build Debug
debug: generate
	@echo "==> Building $(APP_NAME) (Debug)..."
	@mkdir -p $(BUILD_DIR)
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		-derivedDataPath $(DERIVED_BUILD_DIR) \
		-destination 'platform=macOS' \
		CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" \
		TEXTMOUTH_GIT_COMMIT="$(GIT_COMMIT)" \
		TEXTMOUTH_BUILD_DATE="$(BUILD_DATE)" \
		build \
		| tail -5
	@APP_PATH=$$(find $(DERIVED_BUILD_DIR) -name "$(APP_NAME).app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			rm -rf "$(APP_BUNDLE)" && \
			cp -R "$$APP_PATH" "$(APP_BUNDLE)" && \
			echo "==> App built: $(APP_BUNDLE)"; \
		else \
			echo "ERROR: Could not find built .app bundle" && exit 1; \
		fi

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

## Run the parser test suite
test:
	@echo "==> Running parser tests..."
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
