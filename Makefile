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

# The Release app is compiled to be small: -Osize for the Swift packages as
# well as the app's own code. project.yml gives the app's targets the level
# (their Release blocks), but not the packages' targets, which it cannot
# reach; a setting on the command line does, as NO_COVERAGE's does. Given
# that way, Xcode compiles each package (ZIPFoundation, swift-cmark) file
# by file instead of whole-module, which is the smaller build for them, so do
# not add SWIFT_COMPILATION_MODE=wholemodule here. SwiftSoup is not a package
# but a vendored target (Vendor/SwiftSoup), which project.yml compiles
# whole-module: with its forced inlining removed, that is its smallest build.
# Only Release gets the level: `make debug` keeps Debug's own so that it can
# still be stepped through. `make check` and `make install` build through the
# build rule, so they get it too; an Xcode build from its window does not, as
# with NO_COVERAGE.
SMALL_CODE = $(if $(filter Release,$(CONFIG)),SWIFT_OPTIMIZATION_LEVEL=-Osize)

# The Release app's further size settings (November 23, 2026): link-time
# optimization of the Swift and C code, -Oz for the C code, and two
# experimental flags that drop unreferenced runtime records. Together they
# took the Mac app from 22,295,720 to 18,125,080 bytes and the iPhone app from
# 17,171,842 to 13,834,194 in the study of November 23, 2026
# (research/SWIFT-SIZE-FLAGS-2026-11-23.md). Scripts/size_settings.py defines
# them once, with what each one saved, and Scripts/ios/app-size.py reads the
# same list for the iPhone build. Given on the command line, like SMALL_CODE,
# they reach the Swift packages too. Release only: Debug, where the tests run,
# keeps its own settings. The shell's quoting of each word is kept as written
# (a value holds spaces and a "$(inherited)" xcodebuild reads itself).
#
# Which of them a build takes is its profile, SIZE_PROFILE: "full" takes them
# all, "light" only those that cost no memory at link time, and "auto" is full
# on GitHub Actions and light on a Mac. Full link-time optimization's link
# takes several GB of memory, which can freeze a Mac with 8 GB, so a Mac builds
# full only the app that ships: `make install` and `make release` (below).
# Every other build on a Mac, `make build`, `make check`, and the golden tests
# among them, is light. Give it on the command line to choose another, as in
# `make install SIZE_PROFILE=light`. No settings at all is an error, since every
# profile has some: the script refused its command line and said why.
SIZE_PROFILE = auto
SIZE_SETTINGS = $(if $(filter Release,$(CONFIG)),$(or $(shell python3 -I -B Scripts/size_settings.py --profile "$(SIZE_PROFILE)"),$(error Scripts/size_settings.py gave no settings for SIZE_PROFILE=$(SIZE_PROFILE))))

# Xcode records the exact Swift package revisions here. The file is committed,
# so every checkout and CI run builds the same package versions.
PACKAGE_RESOLVED = $(PROJECT)/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

# Where `make test` builds the app and its tests, relative to the repository
# root; empty means Xcode's default DerivedData folder. `make check` passes
# $(DERIVED_BUILD_DIR), the folder `make build` uses, once it has removed the
# compiled code earlier builds left there.
TEST_DERIVED_DATA =

# The branch that `make lint-tests`, `make lint-a11y`, and `make lint-docs` compare
# against: they check what was added since the merge-base of this ref and HEAD.
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
# `make open` all use the signed app. `make check` builds with `SIGN_APP=:`,
# so its app is ad hoc signed. The hosted tests build their own app
# with signing off, as before.
SIGN_APP = Scripts/make-signing-identity.sh --sign-app

# Package resolution uses the same derived data folder as `make build`, so the
# build reuses the package checkouts that resolution creates.
RESOLVE_PACKAGES = xcodebuild -resolvePackageDependencies \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-derivedDataPath "$(DERIVED_BUILD_DIR)"

.PHONY: all clean build debug run install release full-build-note uninstall generate set-version bump-patch bump-minor resolve-packages update-packages test check release-goldens check-selftest issues-merge-driver test-area lint-tests lint-a11y lint-ogg lint-docs lint-l10n check-ios-plist check-ios-licenses typecheck-ios typecheck-mac typecheck-tests typecheck-ios-tests typecheck-tests-census mac-projection perf-baselines open xcode help signing-identity ios-size install-ios

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
	@echo "  make release-goldens - Once per release: run the golden tests against a Release build made with testability on, so an optimizer miscompile cannot hide behind the Debug suite (about 15 minutes; pass options through GOLDEN_ARGS)"
	@echo "  make check-selftest - Test the gate, make install's dSYM keeping, the baseline-recording script, the storage drill script, the version script, the Scripts/test tools, and the l10n tools in seconds, without building"
	@echo "  make issues-merge-driver - Define, once, the merge driver .gitattributes names for Issues/*.md (in the repository's config)"
	@echo "  make l10n-merge-driver - Define, once, the merge driver .gitattributes names for *.xcstrings (in the repository's config)"
	@echo "  make test-area AREAS=\"feeds bookmarks\" - Run only the hosted tests of some areas, in one build, with a short result"
	@echo "  make lint-tests - Check the test lines this branch adds for traps, and list what it did to existing tests"
	@echo "  make lint-a11y  - Check the SwiftUI lines this branch adds for accessibility mistakes"
	@echo "  make lint-ogg   - Check the app lines this branch adds for audio readers that must refuse Ogg first"
	@echo "  make lint-docs  - Check that no doc page has more rule violations than its baseline records (.claude/skills/doc-library/lint-baseline.json)"
	@echo "  make lint-l10n  - Check that no Swift file has more unlocalized interface text than Scripts/l10n/scan-baseline.json records for it (a branch never edits the baseline: the merge lowers it)"
	@echo "  make check-ios-plist - Fail if the iOS Info.plist is not what the Mac's gives (Scripts/ios/sync-info-plist.py --check)"
	@echo "  make check-ios-licenses - Fail if a library the iPhone app links has no licence in the app (Scripts/ios/check-licenses.py)"
	@echo "  make ios-size   - Build the iPhone app for a device (Release, unsigned) under the heavy-work lock, then measure it: app, IPA, App Store estimate, biggest files, libraries"
	@echo "  make install-ios - Build the iPhone app, signed, and install it on your own iPhone with no Xcode window (SIZE_PROFILE=light by default; TEAM=, DEVICE=, LAUNCH=1; once: add your Apple ID in Xcode, connect the iPhone, turn on Developer Mode; never run by an agent)"
	@echo "  make l10n-sync  - Read the code's InterfaceText.line calls and bring the String Catalog into step with them (seconds: no build, no lock)"
	@echo "  make l10n-status - Per language: the strings translated, machine translated, new, needing review, stale, and missing, and the English bytes (LANG_CODE=es for one language)"
	@echo "  make l10n-size  - The English bytes against the 150,000-byte budget, and each language's blob in the pack, and the pack's total"
	@echo "  make l10n-check - Check the String Catalog: shipped languages translated, placeholders and plural forms agreeing, a comment on every string, nothing stale, the bundle's language list equal to the catalog's, every engine lookup equal to Apple's own lookup of tables compiled from the catalog, and the system's choice of language as measured (run by make check)"
	@echo "  make typecheck-ios - Compile and link the app's sources for iOS with SwiftPM, no iOS platform needed (CENSUS=1 counts every AppKit use left)"
	@echo "  make typecheck-mac - The same for the Mac, in about two minutes, without xcodebuild"
	@echo "  make typecheck-tests - The same for the Mac's hosted test target too, before a train request (REF=commit checks that commit)"
	@echo "  make typecheck-ios-tests - The iPhone's unit tests (and the Mac test files they share) and its interface tests compiled for iOS"
	@echo "  make typecheck-tests-census - Which of the Mac's tests compile for the iPhone (slow; writes census.md)"
	@echo "  make mac-projection BASE=main - Show what a branch changes in the code the Mac compiles (DIFF=1 for every line)"
	@echo "  make perf-baselines - Record new performance baselines after a deliberate change"
	@echo "  make signing-identity - Once per Mac: make the identity builds are signed with, so macOS remembers the microphone permission"
	@echo "  make generate   - Regenerate the Xcode project (requires xcodegen), keeping the copy-files phases in their old order"
	@echo "  make set-version VERSION=0.2.0 - Set the app's version (MARKETING_VERSION in project.yml) and regenerate the Xcode project; commits nothing"
	@echo "  make bump-patch - Raise the version's PATCH by one (0.2.0 to 0.2.1), for a day of fixes and small changes an older TextMouth can follow; regenerates the Xcode project, commits nothing"
	@echo "  make bump-minor - Raise the version's MINOR by one and set PATCH to 0 (0.2.3 to 0.3.0), for a change an older TextMouth cannot follow; regenerates the Xcode project, commits nothing"
	@echo "  make resolve-packages - Resolve Swift packages exactly as Package.resolved pins them"
	@echo "  make update-packages  - Re-resolve after changing a package version in project.yml"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make xcode      - Open the project in Xcode"
	@echo ""

## Regenerate the Xcode project from project.yml. xcodegen deals the copy-files
## phases out in another order each run, so the script puts the committed order
## back when the phases mean the same. build and install come through here, and
## set-version and the bumps run the same script, so none leaves such noise.
generate:
	@echo "==> Generating Xcode project..."
	@python3 -I -B Scripts/agents/regenerate-project.py
	@echo "==> Done."

## Set the app's version number, MARKETING_VERSION in project.yml, and
## regenerate the Xcode project, committing nothing: make set-version
## VERSION=0.2.0. The script refuses a version that is not MAJOR.MINOR.PATCH or
## not later than the current one. While TextMouth is in beta its version is
## 0.MINOR.PATCH (Versions in docs/developer/building.md). The build number is
## not set here: make build stamps each build with BUILD_NUMBER, the UTC time.
## For the usual change of version use bump-patch or bump-minor, below.
set-version:
	@Scripts/set-version.sh "$(VERSION)"

## Raise the version's PATCH by one, 0.2.0 to 0.2.1: the bump for a day on
## which main gained bug fixes or small backward-compatible features. It works
## the new version out of project.yml, then goes the way set-version goes:
## it regenerates the Xcode project and commits nothing. The new version needs
## a dated section at the top of docs/user/changelog.md (Versions in
## docs/developer/building.md).
bump-patch:
	@Scripts/set-version.sh --patch

## Raise the version's MINOR by one and set PATCH to 0, 0.2.3 to 0.3.0: the
## bump for a day on which main gained a change that is not backward
## compatible: an older TextMouth can no longer open the library, every book is
## read again (a cache-format change), a stored format changes, or a setting,
## shortcut, or file is removed or renamed. A day without one is bump-patch.
bump-minor:
	@Scripts/set-version.sh --minor

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
		$(SMALL_CODE) \
		$(SIZE_SETTINGS) \
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

## Build the app as it ships, with every size setting (SIZE_PROFILE=full), into
## build/ without installing it. Its link takes several GB of memory: on a Mac
## with 8 GB, quit other heavy apps first
release: SIZE_PROFILE = full
release: full-build-note build
	@echo "==> Release build ready: $(APP_BUNDLE)"

# What `make install` and `make release` say before their build, when it is
# full: its link can take several GB of memory for some minutes.
full-build-note:
	@if [ "$(SIZE_PROFILE)" = "full" ]; then \
		echo "==> Building with every size setting: the last step, the link, takes several GB of memory for some minutes."; \
		echo "==> On a Mac with 8 GB, quit other heavy apps (a web browser, TextMouth) before it starts."; \
	fi

## Install to /Applications with every size setting (SIZE_PROFILE=full), as
## make release builds, keeping the installed build's dSYM in
## INSTALLED_DSYMS_DIR for reading its crash reports
install: SIZE_PROFILE = full
install: full-build-note build
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

## Run the golden tests that pin every reader's output against a Release build
## made with testability on (Scripts/test/release-goldens.sh), once per release
## and after a change to the Release build settings. Pass options through
## GOLDEN_ARGS, for example: make release-goldens GOLDEN_ARGS=--dry-run
release-goldens:
	@Scripts/test/release-goldens.sh $(GOLDEN_ARGS)

## Test the gate script, the performance baselines' recording script, the
## storage drill script, the version script and the tools in Scripts/test (the
## area runner, the diff linters, the log reader, the corpus generator)
## themselves: dry runs, stubbed build tools, canned logs and snippets, copies
## of project.yml, no building. It also runs the policy test that no tracked file
## holds a path of one Mac (Scripts/agents/tests/test_no_mac_paths.py), with the
## tests of the helper and the script that fix one, and the issue tracker's tests
## (.claude/skills/issue-library/tests), which work only in temporary folders
check-selftest:
	@Scripts/check-selftest.sh
	@Scripts/perf-baselines-selftest.sh
	@Scripts/test/storage-drill-selftest.sh
	@Scripts/set-version.sh --selftest
	@python3 Scripts/test/run-area.py --selftest
	@python3 Scripts/test/difflint.py --selftest
	@python3 Scripts/test/trap-lint.py --selftest
	@python3 Scripts/test/a11y-lint.py --selftest
	@python3 Scripts/test/test-diff.py --selftest
	@python3 Scripts/test/test-logs.py --selftest
	@python3 Scripts/test/ogg-lint.py --selftest
	@python3 Scripts/test/make-corpus.py --selftest
	@python3 -I -B Scripts/vendor/swiftsoup/test_make_vendor.py
	@python3 -I -B Scripts/vendor/ffmpeg/test_build.py
	@python3 -I -B -m unittest discover -s Scripts/agents/tests -p 'test_*_paths.py'
	@python3 -I -B -m unittest discover -s .claude/skills/issue-library/tests
	@python3 -I -B Scripts/ios/app-size.py --selftest
	@python3 -I -B -m unittest discover -s Scripts/l10n/tests
	@python3 -I -B -m unittest discover -s Scripts/packs/tests

## Build the iPhone app for a device (Release, unsigned, small code) in its own
## derived data folder, build/ios-size-DerivedData (an absolute path, which
## app-size.py defines once and `make check` uses too), and measure it the way `make check` measures
## the Mac app, plus the IPA and the App Store download estimate. The build takes
## the heavy-work lock, so it waits behind any build or test run already going.
## IOS_SIZE_ARGS passes options to Scripts/ios/app-size.py build, such as --json.
ios-size: generate
	@python3 -I -B Scripts/agents/run_locked.py ios-size python3 -I -B Scripts/ios/app-size.py build $(IOS_SIZE_ARGS)

## Build the iPhone app signed for your own team and install it on your own
## iPhone, from the command line (Scripts/ios/install-on-device.py: its --help
## and docs/developer/building-ios.md say the one-time steps). The profile is
## light unless you give SIZE_PROFILE=full, whose link takes several GB of
## memory (full-build-note says so). It takes the heavy-work lock like ios-size,
## so it waits behind any build already going on this Mac, and says so. TEAM
## (a 10-character team identifier), DEVICE (the iPhone's name or UDID), and
## LAUNCH=1 (start the app after installing) are passed through when given.
## Run it yourself: no agent runs it, since it signs and installs.
## Make's variables are case-sensitive, so `device=` in lower case is taken as DEVICE=, and so are `team=` and
## `launch=` (a value given as DEVICE, in the environment, or on the command line wins).
install-ios: SIZE_PROFILE = light
install-ios: DEVICE ?= $(device)
install-ios: TEAM ?= $(team)
install-ios: LAUNCH ?= $(launch)
install-ios: full-build-note generate
	@python3 -I -B Scripts/agents/run_locked.py install-ios python3 -I -B Scripts/ios/install-on-device.py --profile "$(SIZE_PROFILE)" $(if $(TEAM),--team "$(TEAM)") $(if $(DEVICE),--device "$(DEVICE)") $(if $(LAUNCH),--launch)

## Define the merge driver that .gitattributes names for Issues/*.md, in this
## repository's config, which every worktree (the train's too) shares; run it once.
## It merges an issue file's header field by field, its description as git would,
## and each comment whole. Without it git merges them as text, with markers.
issues-merge-driver:
	git config merge.issuefile.name "an issue file, merged by its parts"
	git config merge.issuefile.driver "python3 -I -B .claude/skills/issue-library/scripts/issuelib.py merge-driver %O %A %B %L %P"

## Define, once, the merge driver that .gitattributes names for *.xcstrings, in this
## repository's config, which every worktree (the train's too) shares. It merges two
## branches' String Catalogs by key, language, and plural form, so two branches that
## add or translate different strings never conflict; a piece both changed differently
## is a conflict (ours is kept and both values are printed). See Scripts/l10n/merge.py.
.PHONY: l10n-merge-driver
l10n-merge-driver:
	git config merge.xcstrings.name "a String Catalog, merged by key, language, and plural form"
	git config merge.xcstrings.driver "python3 -I -B Scripts/l10n/l10n.py merge-driver %O %A %B %P"

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

## Check the app lines this branch added (since LINT_BASE) for calls that open
## an audio file with an Apple reader (AVURLAsset, AVAssetReader, AVAudioFile,
## the AVPlayers, AudioFileOpenURL). Each must refuse an Ogg file first, since
## Apple's Vorbis decoder once locked up the Mac (AGENTS.md, B06); a reviewed
## line ends with `// lint-ok: <how this path refuses Ogg>`. No building.
lint-ogg:
	@python3 Scripts/test/ogg-lint.py --base $(LINT_BASE)

## Check the docs against docs/agents/writing-docs.md: no page may have more
## violations of a rule than .claude/skills/doc-library/lint-baseline.json
## records for it, and the baseline's totals may not rise above those at the
## merge-base of LINT_BASE and HEAD. Prints what got worse. No building.
lint-docs:
	@python3 -I -B .claude/skills/doc-library/scripts/doclib.py lint --against $(LINT_BASE)

## Check that no Swift file of the app has more interface text that is not
## localized than Scripts/l10n/scan-baseline.json records for it, and that no
## new file has any (Scripts/l10n/scan.py lint). Text is localized when it is the
## English of an InterfaceText.line("<ID>", "<English>") call; a line ending with
## `// l10n: no` is left out on purpose. The lint also fails, in every file, on a
## lookup into Apple's tables, which no app ships any more (FR39): String(localized:),
## LocalizedStringResource, String.LocalizationValue, LocalizedStringKey,
## NSLocalizedString, or a SwiftUI literal such as Text("..."); each would show its
## key, and its message names InterfaceText.line. A failure
## prints each literal, on the lines this branch added (since LINT_BASE) when git
## can tell. A branch never edits the baseline (a baseline left high fails nothing): the
## merge chain lowers it after every merge (L10N_ARGS=--update-baseline does the same by hand); the
## orchestrator alone rebuilds the baseline (--rebuild-baseline). No building.
lint-l10n:
	@python3 -I -B Scripts/l10n/scan.py lint --base $(LINT_BASE) $(L10N_ARGS)

## The String Catalog's tools (Scripts/l10n/l10n.py, FR34, FR39): sync reads the
## code's InterfaceText.line calls with the lexer (seconds: no build, no
## heavy-work lock) and brings TextMouth/Localization/Localizable.xcstrings into
## step with them; status, size, and check read the catalog (check, the code too)
## and build nothing. check is part of `make check`.
.PHONY: l10n-sync l10n-status l10n-size l10n-check
l10n-sync:
	@python3 -I -B Scripts/l10n/l10n.py sync

l10n-status:
	@python3 -I -B Scripts/l10n/l10n.py status $(if $(LANG_CODE),--lang $(LANG_CODE),)

l10n-size:
	@python3 -I -B Scripts/l10n/l10n.py size

l10n-check:
	@python3 -I -B Scripts/l10n/l10n.py check
	@python3 -I -B Scripts/l10n/verify_packs.py

## Compile and link the app's sources for iOS with SwiftPM, which needs only
## the iOS SDK Xcode includes, not the iOS platform xcodebuild asks for
## (Scripts/ios/typecheck.py). CENSUS=1 reads AppKit imports as UIKit in the
## copy, so every AppKit use left is counted. It takes the Mac's heavy-work
## lock, which the build train shares, and commits nothing.
## The iOS app's Info.plist (TextMouth/Platform/iOS/Info.plist) is written
## from the Mac's by Scripts/ios/sync-info-plist.py: this fails when the Mac's
## plist has changed and the iOS one has not been written again.
check-ios-plist:
	@python3 -I Scripts/ios/sync-info-plist.py --check

## Fail when the iPhone app links a library whose licence it does not ship, or
## ships a licence no linked library needs (no build; reads project.yml).
check-ios-licenses:
	@python3 -I -B Scripts/ios/check-licenses.py

typecheck-ios:
	@python3 -I Scripts/ios/typecheck.py --platform ios $(if $(CENSUS),--census,)

## The same for the Mac: compile and link the committed sources in about two
## minutes, without xcodebuild or the hosted tests.
typecheck-mac:
	@python3 -I Scripts/ios/typecheck.py --platform macos

## The Mac's hosted tests as well as the app, compiled and linked with SwiftPM
## and not run: finds a test file that does not compile before a train does.
## REF=<commit> checks that commit, from any worktree (default HEAD, as with
## the other type-checks, so commit first).
typecheck-tests:
	@python3 -I Scripts/ios/typecheck.py --platform macos --tests $(if $(REF),--ref $(REF),)

## The iPhone's unit tests (TextMouthiOSTests, with the Mac test files that
## project.yml lists for it by path) and its interface tests (TextMouthiOSUITests,
## the XCUITest bundle that runs only on GitHub) compiled for the iPhone with
## SwiftPM, no simulator needed: run it, with typecheck-tests, before a train
## request that touches either bundle's files (REF=<commit> as above). One
## target covers both bundles, so that the interface tests' check cannot be skipped.
typecheck-ios-tests:
	@python3 -I Scripts/ios/typecheck.py --platform ios --tests $(if $(REF),--ref $(REF),)

## The census of the Mac's hosted tests for the iPhone: compiles all of them
## for iOS, leaving out the files that fail until a build is clean, and writes
## census.md (which classes could run on the iPhone, by area) beside the
## results. Slow (about ten builds) and takes the heavy-work lock the whole time.
typecheck-tests-census:
	@python3 -I Scripts/ios/typecheck.py --platform ios --tests-census $(if $(REF),--ref $(REF),)

## What this branch changes in the code the Mac compiles, since BASE: files
## moved, wrapped in #if os(macOS), or given a platform alias count as
## unchanged (Scripts/ios/mac-projection.py). DIFF=1 prints every line.
mac-projection:
	@python3 -I Scripts/ios/mac-projection.py $(or $(BASE),main) $(or $(HEAD),HEAD) $(if $(DIFF),--diff,)

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
