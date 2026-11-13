#!/bin/bash
#
# release-goldens.sh: runs the golden tests that pin what every reader makes of
# a book against a RELEASE build of the app, made with testability on, so that
# a miscompile by the optimizer (the app's own code and the Swift packages are
# built with -Osize in Release) cannot hide behind the Debug suite, which is
# the only build the ordinary suite ever tests.
#
# Run it once per release, before `make install`, and after any change to the
# build settings in project.yml or the Makefile's build rule. It runs
#   TextPipelineGoldenTests, DocumentGoldenTests (the 57 files of
#   TestData/golden), MarkupGuardTests (SwiftSoup's own output compared),
#   PortableXMLDifferentialTests, and ParserContentFidelityTests.
#
# The Release build here is the shipped one with only what a test host needs
# changed, so the compiled Swift code is the shipped code:
#   -configuration Release       Release's optimization (-Osize in project.yml)
#   SWIFT_OPTIMIZATION_LEVEL     -Osize for the Swift packages too, as the
#                                Makefile's build rule gives it (SMALL_CODE)
#   ENABLE_TESTABILITY=YES       so the tests' @testable import finds the
#                                app's internal types
#   LD_EXPORT_SYMBOLS=YES        keep the app's export trie, which the shipped
#                                app leaves out (-no_exported_symbols): the
#                                test bundle links against the app's exports
#   DEAD_CODE_STRIPPING=NO, DEPLOYMENT_POSTPROCESSING=NO,
#   STRIP_INSTALLED_PRODUCT=NO   keep the symbols the tests call, which the
#                                shipped app strips
#   CLANG_COVERAGE_MAPPING=NO    no coverage data, as in the shipped app
# What it cannot show: the export trie, dead stripping, and stripping change no
# code, but they are not in the tested binary.
#
# How long: one Release build of the app, its packages, and the tests, then
# the tests, 14 minutes on the development Mac on November 13, 2026 (129
# tests in 14 seconds of that); the build folder takes 1.5 GB. It plays no sound. Run it under the heavy lock
# when other agents work (python3 -I Scripts/agents/run_locked.py <name>
# Scripts/test/release-goldens.sh), and unregister the app it builds afterwards
# with lsregister -u on <derived data>/Build/Products/Release/TextMouth.app.
#
# Usage: Scripts/test/release-goldens.sh [-h|--help] [run-area.py options]
#   Any option goes to Scripts/test/run-area.py (--dry-run, --derived-data DIR,
#   --log FILE); the classes and the build settings are set here. During
#   Claude Code agent sessions set BBS_AGENT=<name> to report to the board.
#
# Output and exit status: run-area.py's (the result, each failure, the log's
# path, then PASSED or FAILED; exit 0 only on PASSED).

set -u

# This script's folder, where run-area.py lives.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR

# usage: prints the header comment (from the second line to the first line
# that is not a comment) as the help text.
usage() {
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# The golden classes, kept in one list so a class is added in one place.
readonly GOLDEN_CLASSES=(
    TextPipelineGoldenTests
    DocumentGoldenTests
    MarkupGuardTests
    PortableXMLDifferentialTests
    ParserContentFidelityTests
)

# The settings that make a Release build testable, each as one argument for
# xcodebuild (see the header for why each is here).
readonly RELEASE_TESTABLE_SETTINGS=(
    -configuration Release
    SWIFT_OPTIMIZATION_LEVEL=-Osize
    ENABLE_TESTABILITY=YES
    LD_EXPORT_SYMBOLS=YES
    DEAD_CODE_STRIPPING=NO
    DEPLOYMENT_POSTPROCESSING=NO
    STRIP_INSTALLED_PRODUCT=NO
    CLANG_COVERAGE_MAPPING=NO
)

# run-area.py takes each xcodebuild argument as --xcodebuild-arg=ARG (with an
# equals sign, since a few start with a hyphen), so build the list here.
xcodebuild_args=()
for setting in "${RELEASE_TESTABLE_SETTINGS[@]}"; do
    xcodebuild_args+=("--xcodebuild-arg=$setting")
done

exec python3 -I -B "$SCRIPT_DIR/run-area.py" "$@" "${xcodebuild_args[@]}" "${GOLDEN_CLASSES[@]}"
