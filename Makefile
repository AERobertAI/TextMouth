# TextMouth Makefile
# Build and package the app for testing

APP_NAME = TextMouth
SCHEME = TextMouth
PROJECT = TextMouth.xcodeproj
CONFIG = Release
BUILD_DIR = build
APP_BUNDLE = $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR = /Applications

# Launch Services' registration tool, which `make install` runs so that the
# installed app appears in Open With menus. Named here so that the gate's
# self-test can run `make install` against a stand-in.
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Where `make install` keeps the dSYM of each app it installs, as
# TextMouth-<build number>-<UUID>.app.dSYM (Scripts/keep-installed-dsym.sh).
# The Release app's symbols are stripped, so its crash reports can be read
# only with its own build's dSYM, which the next build replaces in the build
# products. Later builds never touch this folder, and `make uninstall` leaves
# it; `make clean` removes it with the rest of build/. It keeps the dSYMs of
# the last 5 installs: the installed build and the four before it, so a crash
# report that arrives after a few more installs can still be read. Each dSYM
# is about 58 MB, so five take about 290 MB of a disk that is nearly full,
# and a report from a build older than that describes code that has usually
# changed since.
INSTALLED_DSYMS_DIR = $(BUILD_DIR)/installed-dSYMs
INSTALLED_DSYMS_KEPT = 5

# Where xcodebuild puts the built product
DERIVED_BUILD_DIR = $(BUILD_DIR)/DerivedData
BUILT_APP = $(DERIVED_BUILD_DIR)/Build/Products/$(CONFIG)/$(APP_NAME).app
BUILD_LOG = $(BUILD_DIR)/xcodebuild-$(CONFIG).log
GIT_COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")
BUILD_NUMBER := $(shell date -u +"%Y%m%d%H%M%S")

# The app `make build` makes carries no code coverage. Xcode creates the
# TextMouth scheme itself (none is committed), that scheme gathers coverage
# when testing (CLANG_COVERAGE_MAPPING), and Xcode builds the scheme's build
# action the same way. Without this setting every target, the Swift packages
# too, would be compiled to count how often each piece of its code runs,
# carry about 3 MB of coverage data, and link the profiling runtime, which
# writes a default.profraw file when the app quits. Nothing reads coverage
# from these builds. A setting on the command line outranks the scheme's and
# reaches the package targets, which project.yml cannot. `make test` builds
# separately and still gathers coverage.
NO_COVERAGE = CLANG_COVERAGE_MAPPING=NO

# Xcode records the exact Swift package revisions here. The file is committed,
# so every checkout and CI run builds the same package versions.
PACKAGE_RESOLVED = $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Where `make test` builds the app and its tests, relative to the repository
# root; empty means Xcode's default DerivedData folder. `make check` passes
# $(DERIVED_BUILD_DIR), the folder `make build` uses, once it has removed the
# compiled code earlier builds left there.
TEST_DERIVED_DATA =

# The branch that `make lint-tests` and `make lint-a11y` compare against: they
# check the lines added since the merge-base of this ref and HEAD.
LINT_BASE = main

# Set to 1, as `make check` sets it, to have the performance baselines tests
# (PerformanceBaselineTests) measure even on a busy Mac rather than skip.
# The runner hands it to xcodebuild as TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT,
# which reaches the test host without its TEST_RUNNER_ prefix.
PERFORMANCE_STRICT =

# Signs an app with this Mac's "TextMouth Developer" identity, which
# `make signing-identity` makes once, or leaves its ad hoc signature with a
# note when there is none. macOS keeps the microphone permission of an app
# signed with the same certificate from one build to the next; an ad hoc
# signature changes with every build, so macOS would ask again each time.
# `make build` signs the app it packages, so `make install`, `make run`, and
# `make open` all use the signed app. The hosted tests build their own app
# with signing off, as before.
SIGN_APP = Scripts/make-signing-identity.sh --sign-app

# Package resolution uses the same derived data folder as `make build`, so the
# build reuses the package checkouts that resolution creates.
RESOLVE_PACKAGES = xcodebuild -resolvePackageDependencies \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-derivedDataPath "$(DERIVED_BUILD_DIR)"

.PHONY: all clean build debug run install uninstall generate resolve-packages update-packages test check check-selftest test-area lint-tests lint-a11y perf-baselines open xcode help signing-identity

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
	@echo "  make install    - Copy the app to /Applications, keeping its dSYM in build/installed-dSYMs"
	@echo "  make uninstall  - Remove from /Applications, keeping the dSYMs"
	@echo "  make test       - Run the hosted production test suite"
	@echo "  make check      - Run the reproducibility gate: package pins, Release build, hosted tests, no Swift warnings"
	@echo "  make check-selftest - Test the gate, make install's dSYM keeping, the baseline-recording script, and the Scripts/test tools in seconds, without building"
	@echo "  make test-area AREAS=\"feeds bookmarks\" - Run only the hosted tests of some areas, in one build, with a short result"
	@echo "  make lint-tests - Check the test lines this branch adds for traps, and list what it did to existing tests"
	@echo "  make lint-a11y  - Check the SwiftUI lines this branch adds for accessibility mistakes"
	@echo "  make perf-baselines - Record new performance baselines after a deliberate change"
	@echo "  make signing-identity - Once per Mac: make the identity builds are signed with, so macOS remembers the microphone permission"
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
		$(NO_COVERAGE) \
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
	@# Sign the packaged copy, leaving the build products as Xcode made them.
	@$(SIGN_APP) "$(APP_BUNDLE)"
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

## Install to /Applications, keeping the installed build's dSYM in
## INSTALLED_DSYMS_DIR for reading its crash reports
install: build
	@echo "==> Installing to $(INSTALL_DIR)/$(APP_NAME).app..."
	@rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP_BUNDLE)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@# Register the app with Launch Services so Open With menus update
	"$(LSREGISTER)" -f "$(INSTALL_DIR)/$(APP_NAME).app"
	@Scripts/keep-installed-dsym.sh "$(INSTALL_DIR)/$(APP_NAME).app" "$(BUILT_APP).dSYM" \
		"$(INSTALLED_DSYMS_DIR)" "$(INSTALLED_DSYMS_KEPT)"
	@echo "==> Installed. TextMouth should now appear in Open With menus."

## Remove from /Applications, leaving the dSYMs make install kept, which can
## still read crash reports from the app
uninstall:
	@echo "==> Removing $(INSTALL_DIR)/$(APP_NAME).app..."
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "==> Removed. The dSYMs in $(INSTALLED_DSYMS_DIR) stay, for reading its crash reports."

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

## Test the gate script, the performance baselines' recording script and the
## tools in Scripts/test (the area runner, the diff linters, the log reader,
## the corpus generator) themselves: dry runs, stubbed build tools, canned
## logs and snippets, no building
check-selftest:
	@Scripts/check-selftest.sh
	@Scripts/perf-baselines-selftest.sh
	@python3 Scripts/test/run-area.py --selftest
	@python3 Scripts/test/difflint.py --selftest
	@python3 Scripts/test/trap-lint.py --selftest
	@python3 Scripts/test/a11y-lint.py --selftest
	@python3 Scripts/test/test-diff.py --selftest
	@python3 Scripts/test/test-logs.py --selftest
	@python3 Scripts/test/make-corpus.py --selftest

## Run only the hosted tests of some areas (or test classes) in one build,
## printing a short summary: make test-area AREAS="feeds bookmarks". The areas
## are listed in Scripts/test/areas.conf; AREA_ARGS passes options, such as
## AREA_ARGS=--dry-run or AREA_ARGS="--env NAME=VALUE".
test-area:
	@python3 Scripts/test/run-area.py $(AREAS) $(AREA_ARGS)

## Check the lines this branch added to the hosted tests (since LINT_BASE) for
## what can crash a test host, play sound aloud, record, or touch the real
## library, then list what it did to tests that already existed: removed or
## changed assertions, skips, raised timeouts. No building.
lint-tests:
	@python3 Scripts/test/trap-lint.py --base $(LINT_BASE)
	@python3 Scripts/test/test-diff.py --base $(LINT_BASE)

## Check the SwiftUI lines this branch added (since LINT_BASE) for accessibility
## mistakes a VoiceOver or braille user would meet: unlabelled controls, tap
## gestures with no VoiceOver action, and the like. No building.
lint-a11y:
	@python3 Scripts/test/a11y-lint.py --base $(LINT_BASE)

## Rewrite TextMouthProductionTests/performance-baselines.json from a fresh
## run of PerformanceBaselineTests, which waits for a quiet Mac, printing
## each old and new number; for after a deliberate change. Builds in
## TEST_DERIVED_DATA when it names a folder.
perf-baselines: generate
	@TEXTMOUTH_TEST_DERIVED_DATA="$(TEST_DERIVED_DATA)" Scripts/perf-baselines.sh

## Make the self-signed code-signing identity "TextMouth Developer" in the
## login keychain, once per Mac, so that every build make build signs keeps
## macOS's microphone permission; safe to run again, when it changes nothing
signing-identity:
	@Scripts/make-signing-identity.sh

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
