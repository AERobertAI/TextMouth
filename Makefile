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

# Xcode records the exact Swift package revisions here. The file is committed,
# so every checkout and CI run builds the same package versions.
PACKAGE_RESOLVED = $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Where `make test` builds the app and its tests, relative to the repository
# root; empty means Xcode's default DerivedData folder. `make check` passes
# $(DERIVED_BUILD_DIR), the folder `make build` uses, once it has removed the
# compiled code earlier builds left there.
TEST_DERIVED_DATA =

# Set to 1, as `make check` sets it, to have the performance baselines tests
# (PerformanceBaselineTests) measure even on a busy Mac rather than skip.
# The runner hands it to xcodebuild as TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT,
# which reaches the test host without its TEST_RUNNER_ prefix.
PERFORMANCE_STRICT =

# Package resolution uses the same derived data folder as `make build`, so the
# build reuses the package checkouts that resolution creates.
RESOLVE_PACKAGES = xcodebuild -resolvePackageDependencies \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-derivedDataPath "$(DERIVED_BUILD_DIR)"

.PHONY: all clean build debug run install uninstall generate resolve-packages update-packages test check check-selftest perf-baselines open xcode help

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
	@echo "  make check      - Run the reproducibility gate: package pins, Release build, hosted tests, no Swift warnings"
	@echo "  make check-selftest - Test the gate and baseline-recording scripts in seconds, without building"
	@echo "  make perf-baselines - Record new performance baselines after a deliberate change"
	@echo "  make generate   - Regenerate the Xcode project (requires xcodegen)"
	@echo "  make resolve-packages - Resolve Swift packages exactly as Package.resolved pins them"
	@echo "  make update-packages  - Re-resolve after changing a package version in project.yml"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make xcode      - Open the project in Xcode"
	@echo ""

## Regenerate the Xcode project from project.yml
generate:
	@echo "==> Generating Xcode project..."
	xcodegen generate
	@echo "==> Done."

## Resolve Swift packages exactly as the committed Package.resolved pins them.
## xcodebuild then refuses to move any pin, so a project.yml version that no
## longer matches Package.resolved fails here instead of silently re-resolving.
## That flag accepts a missing Package.resolved, so its presence is checked first.
resolve-packages: generate
	@test -f "$(PACKAGE_RESOLVED)" || { echo "error: $(PACKAGE_RESOLVED) is missing; restore it with: git checkout -- $(PACKAGE_RESOLVED)"; exit 1; }
	@echo "==> Resolving Swift packages from Package.resolved..."
	$(RESOLVE_PACKAGES) -onlyUsePackageVersionsFromResolvedFile

## Re-resolve after deliberately changing a package version in project.yml.
## Xcode rewrites Package.resolved to satisfy the new requirements while keeping
## every other pin; review that diff and commit it together with project.yml.
update-packages: generate
	@echo "==> Re-resolving Swift packages for project.yml..."
	$(RESOLVE_PACKAGES)
	@echo "==> Review the Package.resolved diff, then commit it with project.yml."

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

## Run tests against the real application through the hosted test runner,
## building in TEST_DERIVED_DATA when it names a folder, with the performance
## baselines tests strict when PERFORMANCE_STRICT is 1
test:
	@echo "==> Running hosted production tests..."
	@cd TextMouthTests && TEXTMOUTH_TEST_DERIVED_DATA="$(TEST_DERIVED_DATA)" \
		$(if $(filter 1,$(PERFORMANCE_STRICT)),TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1) swift run 2>&1
	@echo ""

## Run the reproducibility gate: regenerate the project, verify the package
## pins, build Release and run the hosted tests from scratch, and fail on any
## Swift warning. Pass options through CHECK_ARGS, for example:
## make check CHECK_ARGS=--dry-run
check:
	@Scripts/check.sh $(CHECK_ARGS)

## Test the gate script and the performance baselines' recording script
## themselves: dry runs and stubbed build tools, no building
check-selftest:
	@Scripts/check-selftest.sh
	@Scripts/perf-baselines-selftest.sh

## Rewrite TextMouthProductionTests/performance-baselines.json from a fresh
## run of PerformanceBaselineTests, which waits for a quiet Mac, printing
## each old and new number; for after a deliberate change. Builds in
## TEST_DERIVED_DATA when it names a folder.
perf-baselines: generate
	@TEXTMOUTH_TEST_DERIVED_DATA="$(TEST_DERIVED_DATA)" Scripts/perf-baselines.sh

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
