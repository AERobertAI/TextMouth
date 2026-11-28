#!/bin/bash
#
# check-selftest.sh: tests Scripts/check.sh in a few seconds, without building.
#
# Every case copies check.sh and the committed Package.resolved into a fresh
# sandbox folder, with a stub of Scripts/ios/app-size.py (the iPhone app's size
# tool, which would otherwise build the iPhone app), puts stub make, xcodebuild,
# xcodegen, xcrun, and swift commands first on PATH, runs the gate there, and checks its exit status, its
# report, and the commands it ran. Most cases use --dry-run together with the
# TEXTMOUTH_CHECK_SIMULATE_* variables; the rest run the gate for real against
# the stubs, which imitate passing and failing Makefile targets. No case can
# start a real build: the gate reaches build tools only through PATH, every
# build tool on that PATH is a stub, and the stubs for tools the gate must
# never call directly fail loudly. Two cases run the Makefile's own test
# target, whose swift command is then a stub that records what it was handed,
# and one prints its build target's commands (make -n) without running them.
# The install cases run the Makefile's install and uninstall targets, and the
# Scripts/keep-installed-dsym.sh that install runs, without building (make -o
# build) and never touching /Applications: the app goes to the case's own
# Applications folder, Launch Services' tool is a stub that records its call,
# and dwarfdump is a stub that reads the UUIDs the case planted. The signing
# cases run Scripts/make-signing-identity.sh: one for real, twice, against a
# throwaway keychain the case creates unlocked, so no password is ever asked
# for and the login keychain is never touched; the others with stub security
# and codesign commands.
#
# Usage: Scripts/check-selftest.sh   (or: make check-selftest)
#
# Output: one "ok" or "not ok" line per case, with the reasons and the gate's
# report under each failure, then the totals.
#
# Exit status: 0 when every case passes, 1 otherwise.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
readonly ROOT
readonly RESOLVED="TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

# The real make, found before the stubs shadow it, for the make check case.
REAL_MAKE=$(command -v make) || { echo "check-selftest: make is required" >&2; exit 1; }
readonly REAL_MAKE

# The Release app's two size limits, read from check.sh, which defines each
# once, so these cases follow them when they change: the gate warns above
# APP_SIZE_WARNING_MB and fails above APP_SIZE_LIMIT_MB. The expected reports
# below write a size of a whole number of megabytes as "<limit>.0 MB
# (<limit>,000,000 bytes)", which holds for a limit under 1,000 MB.
APP_SIZE_WARNING_MB=$(sed -n -E 's/^readonly APP_SIZE_WARNING_MB=([0-9]+)$/\1/p' "$ROOT/Scripts/check.sh")
APP_SIZE_LIMIT_MB=$(sed -n -E 's/^readonly APP_SIZE_LIMIT_MB=([0-9]+)$/\1/p' "$ROOT/Scripts/check.sh")
if [[ ! $APP_SIZE_WARNING_MB =~ ^[1-9][0-9]{0,2}$ || ! $APP_SIZE_LIMIT_MB =~ ^[1-9][0-9]{0,2}$ ]]; then
  echo "check-selftest: Scripts/check.sh must set APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB to whole numbers from 1 to 999" >&2
  exit 1
fi
if (( APP_SIZE_WARNING_MB >= APP_SIZE_LIMIT_MB )); then
  echo "check-selftest: Scripts/check.sh must set APP_SIZE_WARNING_MB below APP_SIZE_LIMIT_MB" >&2
  exit 1
fi
readonly APP_SIZE_WARNING_MB APP_SIZE_LIMIT_MB
readonly APP_SIZE_WARNING_BYTES=$(( APP_SIZE_WARNING_MB * 1000000 ))
readonly APP_SIZE_LIMIT_BYTES=$(( APP_SIZE_LIMIT_MB * 1000000 ))

# The braille-table packs' limits in bytes, read from check.sh, which defines each once (FR40), so the cases that plant a
# pack a byte over a limit follow it when it changes: the iPhone's pack holds every table TextMouth ships for it, the Mac's
# its four English ones.
BRAILLE_PACK_LIMIT_BYTES=$(sed -n -E 's/^readonly BRAILLE_PACK_LIMIT_BYTES=([0-9]+)$/\1/p' "$ROOT/Scripts/check.sh")
MAC_BRAILLE_PACK_LIMIT_BYTES=$(sed -n -E 's/^readonly MAC_BRAILLE_PACK_LIMIT_BYTES=([0-9]+)$/\1/p' "$ROOT/Scripts/check.sh")
if [[ ! $BRAILLE_PACK_LIMIT_BYTES =~ ^[1-9][0-9]{0,8}$ || ! $MAC_BRAILLE_PACK_LIMIT_BYTES =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "check-selftest: Scripts/check.sh must set BRAILLE_PACK_LIMIT_BYTES and MAC_BRAILLE_PACK_LIMIT_BYTES to whole numbers of bytes" >&2
  exit 1
fi
readonly BRAILLE_PACK_LIMIT_BYTES MAC_BRAILLE_PACK_LIMIT_BYTES

# How many installs keep their dSYMs, read from the Makefile, which defines it
# once, so the install cases follow it when it changes.
INSTALLED_DSYMS_KEPT=$(sed -n -E 's/^INSTALLED_DSYMS_KEPT = ([0-9]+)$/\1/p' "$ROOT/Makefile")
if [[ ! $INSTALLED_DSYMS_KEPT =~ ^[1-9][0-9]?$ ]]; then
  echo "check-selftest: the Makefile must set INSTALLED_DSYMS_KEPT to a whole number from 1 to 99" >&2
  exit 1
fi
readonly INSTALLED_DSYMS_KEPT

WORK=$(mktemp -d "${TMPDIR:-/tmp}/textmouth-check-selftest.XXXXXX") || exit 1
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly STUBS="$WORK/stubs"                  # stub build tools, first on PATH
readonly SLOT_STUB="$WORK/slot/build-slot.sh" # stub build-slot wrapper
readonly FIXTURES="$WORK/fixtures"            # Package.resolved variants and test logs
readonly CLAUDE_TMP="$WORK/claude-tmp"        # stands in for /tmp/claude-<uid>
readonly SESSION="selftest-session"           # stands in for a Claude Code session id
readonly SESSION_SLOT="$CLAUDE_TMP/-selftest-project/$SESSION/scratchpad/build-slot.sh"
readonly SWIFT_RECORDER="$WORK/swift-recorder" # a swift that records, for the Makefile cases
readonly SIGNING_STUBS="$WORK/signing-stubs"   # security and codesign, for the signing cases
readonly IOS_SIZE_STUB="$WORK/app-size-stub.py" # stands in for Scripts/ios/app-size.py in each sandbox
readonly IOS_SIZE_RUN="python3 -I -B Scripts/ios/app-size.py build --summary --check" # how the gate runs it
readonly IOS_SIZE_RECORD="app-size build --summary --check"                           # what the stub records
# The size of the app the make stub packages unless a case says otherwise:
# within any limit, and a number whose report shows its rounding and digit
# groups.
readonly DEFAULT_APP_BYTES=12345678
readonly DEFAULT_APP_TEXT="12.3 MB (12,345,678 bytes)"

first_identity=""  # identity of the committed file's first pin
first_version=""   # that pin's version, as the gate prints it

passed=0
failed=0
case_name=""     # description of the case in progress
case_problems="" # reasons the case in progress fails, one per line
sandbox=""       # the case's copy of the repository
stub_log=""      # where the stubs record the commands the gate ran
output=""        # the gate's report: standard output and error together
status=0         # the gate's exit status

# write_stubs: creates the stub tools. The make stub records "make <target>"
# and imitates the targets the gate runs, steered by STUB_* variables. The
# other build tools record their call and fail, because the gate must reach
# them only through make. The slot stub records the command it wraps and
# runs it.
write_stubs() {
  local tool
  mkdir -p "$STUBS" "$(dirname "$SLOT_STUB")" "$(dirname "$SESSION_SLOT")" "$FIXTURES"

  cat > "$STUBS/make" <<'STUB'
#!/bin/bash
# Stub make for check-selftest.sh: records the call, then imitates a target.
#   STUB_FAIL_TARGET=<target>   that target prints a compiler-style error and fails
#   STUB_RESOLVE_WRITES=<file>  resolve-packages copies <file> over Package.resolved
#   STUB_BUILD_WRITES=<file>    build copies <file> over Package.resolved
#   STUB_BUILD_LOG=<file>       build writes <file> as xcodebuild's Release log,
#                               build/xcodebuild-Release.log; empty writes none
#   STUB_APP_BYTES=<number>     build packages build/TextMouth.app, of <number>
#                               bytes (at least 600); empty packages none
#   STUB_APP_TEXT=<text>        build also writes <text> into the app, as
#                               Contents/Resources/planted.txt
#   STUB_PACK=<form>            the interface-text pack build packages (and, as STUB_IOS_PACK, the iPhone
#                               app's): ok (the default, 8 bytes), none, twice (a second copy in a
#                               Frameworks folder), misplaced (not in the resources folder), or big
#                               (1,500,001 bytes, written sparse)
#   STUB_BRAILLE_PACK=<form>    the braille-table pack build packages (and, as STUB_IOS_BRAILLE_PACK, the
#                               iPhone app's): ok (the default, 8 bytes), none, twice, misplaced, big (a
#                               byte over STUB_BRAILLE_PACK_LIMIT, the Mac's limit, written sparse),
#                               raw-folder (an empty liblouis/tables folder beside it), or raw-file (a
#                               table file beside it)
#   STUB_LPROJ=<form>           the language folder build packages in the app, in
#                               Contents/Resources/es.lproj: ok (the default: an
#                               InfoPlist.strings and nothing else), apple-strings
#                               (a Localizable.strings besides, a table of Apple's),
#                               apple-dict (a Localizable.stringsdict), apple-loctable
#                               (a Localizable.loctable), apple-catalog (a
#                               Localizable.xcstrings), xctest-fixture (a fixture
#                               catalog inside PlugIns/Tests.xctest, which is allowed), no-infoplist (an empty
#                               folder), or none (no .lproj folder at all)
#   STUB_TEST_OUTPUT=<file>     test prints <file>
#   STUB_TEST_STATUS=<number>   test exits with <number> (default 0)
# In the log and output files, @ROOT@ stands for the repository root, since
# xcodebuild names every source file by its full path.

# with_root <file>: prints <file> with the repository root in place of @ROOT@.
with_root() {
  sed "s#@ROOT@#$(pwd -P)#g" "$1"
}

# plant_pack <resources folder> <form>: writes the interface-text pack there as the build phase
# does (8 bytes), or not at all (none), or twice (a copy in a sibling Frameworks folder), or in
# the wrong place (misplaced: in a subfolder), or over the limit (big: 1,500,001 bytes, sparse).
plant_pack() {
  case $2 in
    none) return 0 ;;
    misplaced) mkdir -p "$1/Elsewhere"; printf 'TMSP0000' > "$1/Elsewhere/Strings.pack"; return 0 ;;
    big) dd if=/dev/zero of="$1/Strings.pack" bs=1 count=0 seek=1500001 2>/dev/null; return 0 ;;
  esac
  printf 'TMSP0000' > "$1/Strings.pack"
  case $2 in twice) mkdir -p "$1/../Frameworks"; printf 'TMSP0000' > "$1/../Frameworks/Strings.pack" ;; esac
}

# plant_braille_pack <resources folder> <form>: writes the braille-table pack there as the build phase does (8 bytes here),
# or not at all (none), or twice (a copy in a sibling Frameworks folder), or in the wrong place (misplaced: in a subfolder),
# or a byte over the Mac's limit (big, sparse), or with a raw liblouis table beside it: the liblouis/tables folder the apps
# held before the pack, empty (raw-folder), or a table file (raw-file).
plant_braille_pack() {
  mkdir -p "$1"
  case $2 in
    none) return 0 ;;
    misplaced) mkdir -p "$1/Elsewhere"; printf 'TMSP0000' > "$1/Elsewhere/BrailleTables.pack"; return 0 ;;
    big)
      dd if=/dev/zero of="$1/BrailleTables.pack" bs=1 count=0 \
        seek=$(( ${STUB_BRAILLE_PACK_LIMIT:?the big form needs STUB_BRAILLE_PACK_LIMIT} + 1 )) 2>/dev/null
      return 0 ;;
  esac
  printf 'TMSP0000' > "$1/BrailleTables.pack"
  case $2 in
    twice) mkdir -p "$1/../Frameworks"; printf 'TMSP0000' > "$1/../Frameworks/BrailleTables.pack" ;;
    raw-folder) mkdir -p "$1/liblouis/tables" ;;
    raw-file) printf 'include x' > "$1/en-ueb-g2.ctb" ;;
  esac
}

# plant_language_files <resources folder> <form>: writes es.lproj there as the
# build phase leaves it (an InfoPlist.strings of 8 bytes), or with a table of
# Apple's beside it, or empty, or no folder at all.
plant_language_files() {
  mkdir -p "$1"
  plant_pack "$1" "${3:-ok}"
  case $2 in none) return 0 ;; esac
  mkdir -p "$1/es.lproj"
  case $2 in no-infoplist) return 0 ;; esac
  printf '"a"="b";' > "$1/es.lproj/InfoPlist.strings"
  case $2 in
    apple-strings) printf '"a"="b";' > "$1/es.lproj/Localizable.strings" ;;
    apple-dict) printf 'bplist0012345678' > "$1/es.lproj/Localizable.stringsdict" ;;
    apple-loctable) printf 'bplist0012345678' > "$1/es.lproj/Localizable.loctable" ;;
    apple-catalog) printf '{}' > "$1/es.lproj/Localizable.xcstrings" ;;
    renamed) printf '"CFBundleDisplayName" = "TextMouth Test";' > "$1/es.lproj/InfoPlist.strings" ;;
    xctest-fixture) mkdir -p "$1/../PlugIns/Tests.xctest/pack"; printf '{}' > "$1/../PlugIns/Tests.xctest/pack/lines.xcstrings" ;;
  esac
}

echo "make $*" >> "$STUB_LOG"
target=${1:-}
# The gate removes earlier builds' compiled code before it builds.
if [ "$target" = build ] && [ -e build/DerivedData/Build ]; then
  echo "make build found build/DerivedData/Build from an earlier build" >> "$STUB_LOG"
fi
if [ "${STUB_FAIL_TARGET:-}" = "$target" ]; then
  echo "/stub/Sources/Stub.swift:1:1: error: simulated failure of make $target"
  echo "make: *** [$target] Error 65"
  exit 2
fi
case $target in
  resolve-packages)
    if [ -n "${STUB_RESOLVE_WRITES:-}" ]; then cp "$STUB_RESOLVE_WRITES" "$STUB_RESOLVED"; fi ;;
  build)
    if [ -n "${STUB_BUILD_LOG:-}" ]; then
      mkdir -p build
      with_root "$STUB_BUILD_LOG" > build/xcodebuild-Release.log
    fi
    if [ -n "${STUB_APP_BYTES:-}" ]; then
      # Like make build, replace the packaged app: a 600-byte Info.plist and
      # an executable that brings the bundle to STUB_APP_BYTES bytes, written
      # sparse, so that even an app over the limit takes no disk space.
      rm -rf build/TextMouth.app
      mkdir -p build/TextMouth.app/Contents/MacOS
      head -c 600 /dev/zero > build/TextMouth.app/Contents/Info.plist
      # The language files and the packs count toward the size, so the executable is sized to leave the total at
      # STUB_APP_BYTES: every file planted in the resources and frameworks folders is counted.
      plant_language_files build/TextMouth.app/Contents/Resources "${STUB_LPROJ:-ok}" "${STUB_PACK:-ok}"
      plant_braille_pack build/TextMouth.app/Contents/Resources "${STUB_BRAILLE_PACK:-ok}"
      planted_bytes=$(find build/TextMouth.app/Contents/Resources build/TextMouth.app/Contents/Frameworks -type f -exec cat {} + 2>/dev/null | wc -c)
      dd if=/dev/zero of=build/TextMouth.app/Contents/MacOS/TextMouth bs=1 count=0 \
        seek=$(( STUB_APP_BYTES - 600 - planted_bytes )) 2>/dev/null
      if [ -n "${STUB_APP_TEXT:-}" ]; then
        mkdir -p build/TextMouth.app/Contents/Resources
        printf '%s' "$STUB_APP_TEXT" | sed "s#@ROOT@#$(pwd -P)#g" > build/TextMouth.app/Contents/Resources/planted.txt
      fi
    fi
    if [ -n "${STUB_BUILD_WRITES:-}" ]; then cp "$STUB_BUILD_WRITES" "$STUB_RESOLVED"; fi ;;
  test)
    with_root "$STUB_TEST_OUTPUT"
    exit "${STUB_TEST_STATUS:-0}" ;;
esac
exit 0
STUB

  for tool in xcodebuild xcodegen xcrun swift; do
    cat > "$STUBS/$tool" <<'STUB'
#!/bin/bash
# Stub build tool for check-selftest.sh: the gate must reach it only via make.
echo "$(basename "$0") $*" >> "$STUB_LOG"
echo "stub: Scripts/check.sh must not run $(basename "$0") directly" >&2
exit 97
STUB
  done

  # A swift for the cases that run the Makefile's test target: it records
  # its arguments and the variables that target hands the test runner, with
  # "(unset)" for one it did not set.
  mkdir -p "$SWIFT_RECORDER"
  cat > "$SWIFT_RECORDER/swift" <<'STUB'
#!/bin/bash
# Recording swift for check-selftest.sh's Makefile cases.
echo "swift $* in $(basename "$PWD")" >> "$STUB_LOG"
echo "TEXTMOUTH_TEST_DERIVED_DATA=${TEXTMOUTH_TEST_DERIVED_DATA-(unset)}" >> "$STUB_LOG"
echo "TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=${TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT-(unset)}" >> "$STUB_LOG"
exit 0
STUB
  chmod +x "$SWIFT_RECORDER/swift"

  # A dwarfdump for the install cases: `dwarfdump --uuid <path>` prints, as
  # a real one does for an arm64 binary, one UUID line for each line of the
  # file a real one would read, an app's executable or a dSYM's DWARF file,
  # where the cases write the UUIDs. It records nothing; it only answers.
  cat > "$STUBS/dwarfdump" <<'STUB'
#!/bin/bash
# Stub dwarfdump for check-selftest.sh's install cases.
path=${!#}
case $path in
  *.dSYM) file="$path/Contents/Resources/DWARF/TextMouth" ;;
  *) file=$path ;;
esac
if [ ! -f "$file" ]; then
  echo "error: $path: No such file or directory" >&2
  exit 1
fi
while IFS= read -r uuid; do
  [ -n "$uuid" ] && echo "UUID: $uuid (arm64) $file"
done < "$file"
exit 0
STUB

  # Launch Services' registration tool for the install cases, which the
  # Makefile is handed in its place: it records the call and does nothing.
  cat > "$STUBS/lsregister" <<'STUB'
#!/bin/bash
# Stub lsregister for check-selftest.sh's install cases.
echo "lsregister $*" >> "$STUB_LOG"
exit 0
STUB

  # The iPhone size tool, which the gate runs with python3: it records its call
  # (as "app-size <arguments>"), prints the file STUB_IOS_SIZE_OUTPUT names, and
  # exits with STUB_IOS_SIZE_STATUS (default 0). The real tool exits 3 for an
  # app over the strict limit and 1 for a build that failed.
  cat > "$IOS_SIZE_STUB" <<'STUB'
"""Stub Scripts/ios/app-size.py for check-selftest.sh."""
import os
import sys

with open(os.environ["STUB_LOG"], "a") as log:
    log.write("app-size " + " ".join(sys.argv[1:]) + "\n")
# The iPhone app the real tool builds, with the language folder STUB_IOS_LPROJ names (the forms of the Mac stub's
# STUB_LPROJ): ok (the default), apple-strings, apple-dict, apple-loctable, apple-catalog, no-infoplist, or none.
form = os.environ.get("STUB_IOS_LPROJ", "ok")
app = "build/ios-size-DerivedData/Build/Products/Release-iphoneos/TextMouth.app"
os.makedirs(app, exist_ok=True)
# The interface-text pack STUB_IOS_PACK names: ok (the default), none, twice, misplaced, or big.
pack = os.environ.get("STUB_IOS_PACK", "ok")
if pack == "misplaced":
    os.makedirs(app + "/Elsewhere", exist_ok=True)
    with open(app + "/Elsewhere/Strings.pack", "wb") as out:
        out.write(b"TMSP0000")
elif pack != "none":
    with open(app + "/Strings.pack", "wb") as out:
        if pack == "big":
            out.truncate(1500001)
        else:
            out.write(b"TMSP0000")
    if pack == "twice":
        os.makedirs(app + "/Frameworks", exist_ok=True)
        with open(app + "/Frameworks/Strings.pack", "wb") as out:
            out.write(b"TMSP0000")
# The braille-table pack STUB_IOS_BRAILLE_PACK names, in the forms of the Mac stub's STUB_BRAILLE_PACK: ok (the default),
# none, twice, misplaced, big (a byte over STUB_IOS_BRAILLE_PACK_LIMIT, the iPhone's limit, sparse), raw-folder, or raw-file.
braille = os.environ.get("STUB_IOS_BRAILLE_PACK", "ok")
if braille == "misplaced":
    os.makedirs(app + "/Elsewhere", exist_ok=True)
    with open(app + "/Elsewhere/BrailleTables.pack", "wb") as out:
        out.write(b"TMSP0000")
elif braille != "none":
    with open(app + "/BrailleTables.pack", "wb") as out:
        if braille == "big":
            out.truncate(int(os.environ["STUB_IOS_BRAILLE_PACK_LIMIT"]) + 1)
        else:
            out.write(b"TMSP0000")
    if braille == "twice":
        os.makedirs(app + "/Frameworks", exist_ok=True)
        with open(app + "/Frameworks/BrailleTables.pack", "wb") as out:
            out.write(b"TMSP0000")
    elif braille == "raw-folder":
        os.makedirs(app + "/liblouis/tables", exist_ok=True)
    elif braille == "raw-file":
        with open(app + "/en-ueb-g2.ctb", "wb") as out:
            out.write(b"include x")
if form != "none":
    folder = app + "/es.lproj"
    os.makedirs(folder, exist_ok=True)
    if form != "no-infoplist":
        with open(folder + "/InfoPlist.strings", "wb") as out:
            out.write(b'"a"="b";')
    # A table of Apple's, which the gate refuses: the file the form names.
    apple = {"apple-strings": "Localizable.strings", "apple-dict": "Localizable.stringsdict",
             "apple-loctable": "Localizable.loctable", "apple-catalog": "Localizable.xcstrings"}.get(form)
    if apple:
        with open(folder + "/" + apple, "wb") as out:
            out.write(b"bplist0012345678")
if os.environ.get("STUB_IOS_SIZE_OUTPUT"):
    with open(os.environ["STUB_IOS_SIZE_OUTPUT"]) as output:
        sys.stdout.write(output.read())
sys.exit(int(os.environ.get("STUB_IOS_SIZE_STATUS", "0")))
STUB

  cat > "$SLOT_STUB" <<'STUB'
#!/bin/bash
# Stub build-slot wrapper for check-selftest.sh: records the wrap, runs the command.
echo "slot $*" >> "$STUB_LOG"
exec "$@"
STUB
  cp "$SLOT_STUB" "$SESSION_SLOT"
  chmod +x "$STUBS"/* "$SLOT_STUB" "$SESSION_SLOT"

  # A PATH folder holding every stub except xcodegen, plus jq, for the case
  # that checks the gate's advice when XcodeGen is missing.
  mkdir -p "$WORK/stubs-without-xcodegen"
  for tool in make xcodebuild xcrun swift; do
    ln -s "$STUBS/$tool" "$WORK/stubs-without-xcodegen/$tool"
  done
  ln -s "$(command -v jq)" "$WORK/stubs-without-xcodegen/jq"
}

# write_ios_size_fixture <file> <verdict> <size> [download verdict]: writes a
# summary like the one the iPhone size tool prints, for an app of <size> that
# stands <verdict>; the download estimate stands the same unless told otherwise.
write_ios_size_fixture() {
  {
    printf 'Size: iPhone app: %s in 41 files, %s.\n' "$3" "$2"
    printf 'Size: iPhone app IPA: 10.0 MB (10,000,000 bytes).\n'
    printf 'Size: iPhone app App Store download, estimated (Mach-O files at full size): 11.0 MB (11,000,000 bytes), %s.\n' "${4:-$2}"
    printf 'Size detail: 8.0 MB (8,000,000 bytes)  TextMouth\n'
  } > "$FIXTURES/$1"
}

# write_fixtures: derives Package.resolved variants from the committed file
# by changing its first pin, so the cases survive any future dependency
# change, and writes the test logs the make stub prints.
write_fixtures() {
  local committed="$ROOT/$RESOLVED"
  first_identity=$(jq -r '.pins[0].identity' "$committed")
  first_version=$(jq -r '.pins[0] | .state.version // ("branch " + (.state.branch // "unknown"))' "$committed")

  jq '.pins[0].state.version = "999.0.0"' "$committed" > "$FIXTURES/version-drift.resolved"
  jq '.pins[0].state.revision = "0000000000000000000000000000000000000000"' \
    "$committed" > "$FIXTURES/revision-drift.resolved"
  jq '.pins = .pins[1:] + [{
        identity: "selftest-extra",
        kind: "remoteSourceControl",
        location: "https://example.invalid/selftest-extra.git",
        state: {revision: "1111111111111111111111111111111111111111", version: "1.0.0"}
      }]' "$committed" > "$FIXTURES/membership-drift.resolved"
  printf '{ "pins": [\n' > "$FIXTURES/malformed.resolved"

  # XCTest prints totals for every suite; the last "Executed" line is the
  # total for all tests, and the gate must report that one.
  {
    printf "Test Suite 'StubTests' passed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 2 tests, with 0 failures (0 unexpected) in 0.010 (0.011) seconds\n'
    printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.020 (0.021) seconds\n'
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/tests-pass.log"

  # A passing test starts right after the failure, inside the two lines of
  # context the gate shows, so the gate must filter it out.
  {
    printf '/stub/StubTests.swift:12: error: -[StubTests testFails] : XCTAssertTrue failed\n'
    printf "Test Case '-[StubTests testFails]' failed (0.001 seconds).\n"
    printf "Test Case '-[StubTests testPasses]' started.\n"
    printf "Test Case '-[StubTests testPasses]' passed (0.001 seconds).\n"
    printf "Test Suite 'All tests' failed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 3 tests, with 1 failure (0 unexpected) in 0.020 (0.021) seconds\n'
    printf '** TEST FAILED **\n'
  } > "$FIXTURES/tests-fail.log"

  # A Release build log with no Swift warning, only other tools' warnings,
  # which the gate must not count.
  {
    printf "SwiftCompile normal arm64 @ROOT@/TextMouth/Services/Ledger.swift (in target 'TextMouth' from project 'TextMouth')\n"
    printf "ld: warning: ignoring duplicate libraries: '-lc++'\n"
    printf '2026-01-01 00:00:00.000 appintentsmetadataprocessor[100:200] warning: Metadata extraction skipped. No AppIntents.framework dependency found.\n'
    printf '** BUILD SUCCEEDED **\n'
  } > "$FIXTURES/build-clean.log"

  # A Release build log with six different Swift warnings, the compiler's
  # own warning about its settings among them, and the first reported again
  # when the second architecture compiles, among other tools' warnings.
  {
    printf "SwiftCompile normal arm64 @ROOT@/TextMouth/Services/Ledger.swift (in target 'TextMouth' from project 'TextMouth')\n"
    printf "@ROOT@/TextMouth/Services/Ledger.swift:12:9: warning: capture of 'entry' with non-Sendable type 'Entry' in a '@Sendable' closure [#SendableClosureCaptures]\n"
    printf '        entry.total += 1\n'
    printf '        ^\n'
    printf "@ROOT@/TextMouth/Services/Ledger.swift:20:13: warning: initialization of immutable value 'unused' was never used\n"
    printf "@ROOT@/TextMouth/Models/Tally.swift:7:5: warning: var 'sharedTally' is not concurrency-safe because it is nonisolated global shared mutable state [#MutableGlobalVariable]\n"
    printf "@ROOT@/TextMouth/Views/Shelf.swift:44:17: warning: 'reload()' is deprecated: use refresh() [#DeprecatedDeclaration]\n"
    printf '@ROOT@/TextMouth/Views/Shelf.swift:51:9: warning: will never be executed\n'
    printf '<unknown>:0: warning: the compiler ignored an option\n'
    printf "SwiftCompile normal x86_64 @ROOT@/TextMouth/Services/Ledger.swift (in target 'TextMouth' from project 'TextMouth')\n"
    printf "@ROOT@/TextMouth/Services/Ledger.swift:12:9: warning: capture of 'entry' with non-Sendable type 'Entry' in a '@Sendable' closure [#SendableClosureCaptures]\n"
    printf "ld: warning: ignoring duplicate libraries: '-lc++'\n"
    printf '2026-01-01 00:00:00.000 appintentsmetadataprocessor[100:200] warning: Metadata extraction skipped. No AppIntents.framework dependency found.\n'
    printf '** BUILD SUCCEEDED **\n'
  } > "$FIXTURES/build-warnings.log"

  # A passing hosted test run whose build reported a Swift warning in a test
  # file, and whose tests printed lines that only look like warnings: with
  # no column, or with no file.
  {
    printf "@ROOT@/TextMouthProductionTests/LedgerTests.swift:30:13: warning: variable 'total' was never mutated; consider changing to 'let' constant\n"
    printf "Test Case '-[StubTests testPrints]' started.\n"
    printf '@ROOT@/TextMouthProductionTests/LedgerTests.swift:41: warning: printed by a test, with no column\n'
    printf 'warning: printed by a test, with no file\n'
    printf "Test Case '-[StubTests testPrints]' passed (0.001 seconds).\n"
    printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 3 tests, with 0 failures (0 unexpected) in 0.020 (0.021) seconds\n'
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/tests-warning.log"

  # A passing run whose performance tests printed every kind of line: the
  # gate repeats each warning and skip once, and nothing else.
  {
    printf "Test Case '-[PerformanceBaselineTests testLaunch]' started.\n"
    printf 'PERFORMANCE: launch: median 120.000 milliseconds of 120.000 (load 1.00 on 8 cores)\n'
    printf 'PERFORMANCE WARNING: launch: 182.000 milliseconds, 1.52 times its baseline of 120.000 milliseconds; the test fails above twice its baseline.\n'
    printf 'PERFORMANCE NOTE: open.audiobook: 4.000 milliseconds, 0.40 times its baseline of 10.000 milliseconds; make perf-baselines would tighten the check.\n'
    printf 'PERFORMANCE SKIPPED: the baselines were recorded on a Mac15,12, and this Mac is a VirtualMac2,1\n'
    printf 'PERFORMANCE SKIPPED: the baselines were recorded on a Mac15,12, and this Mac is a VirtualMac2,1\n'
    printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 3 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.020 (0.021) seconds\n'
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/tests-performance.log"

  # What app-size.py build --summary prints: the three headline lines, then a
  # detail line, for an app within the limit, one over the warning size, and one
  # over the strict limit.
  write_ios_size_fixture ios-size-ok.txt "within the 30 MB limit" "12.3 MB (12,345,678 bytes)"
  write_ios_size_fixture ios-size-warn.txt "over the 30 MB limit, within the strict 40 MB" "35.0 MB (35,000,000 bytes)"
  write_ios_size_fixture ios-size-over.txt "over the strict 40 MB limit" "41.0 MB (41,000,000 bytes)"
  # An app within the limit whose estimated download is over the warning size.
  write_ios_size_fixture ios-size-download.txt "within the 30 MB limit" "12.3 MB (12,345,678 bytes)" "over the 30 MB limit, within the strict 40 MB"

  printf '** TEST SUCCEEDED **\n' > "$FIXTURES/tests-without-totals.log"
  {
    printf "Test Suite 'All tests' passed at 2026-01-01 00:00:00.000.\n"
    printf '\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.001) seconds\n'
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/tests-zero.log"
}

# begin_case <description>: starts a case in a fresh sandbox that holds a copy
# of check.sh and the committed Package.resolved.
begin_case() {
  case_name=$1
  case_problems=""
  sandbox="$WORK/case-$(( passed + failed + 1 ))"
  mkdir -p "$sandbox/Scripts" "$sandbox/$(dirname "$RESOLVED")"
  cp "$ROOT/Scripts/check.sh" "$sandbox/Scripts/check.sh"
  mkdir -p "$sandbox/Scripts/ios"
  cp "$IOS_SIZE_STUB" "$sandbox/Scripts/ios/app-size.py"
  cp "$ROOT/$RESOLVED" "$sandbox/$RESOLVED"
  stub_log="$sandbox/commands.log"
  : > "$stub_log"
}

# run_gate [--via-make] [NAME=value...] [-- arguments...]: runs the sandbox's
# gate, or `make check` with --via-make, with the stubs first on PATH, none of
# the caller's build-slot or simulation settings, and the given variables,
# which override the defaults. Stores the report in $output and the exit
# status in $status.
# Copies the Makefile into the case's sandbox with the script its size settings
# come from (SIZE_SETTINGS): a Release build stops when the script gives none.
copy_makefile() {
  cp "$ROOT/Makefile" "$sandbox/Makefile"
  mkdir -p "$sandbox/Scripts"
  cp "$ROOT/Scripts/size_settings.py" "$sandbox/Scripts/size_settings.py"
}

run_gate() {
  local -a command=(./Scripts/check.sh) settings=()
  if [[ ${1:-} == --via-make ]]; then
    command=("$REAL_MAKE" -s check)
    shift
  fi
  while [[ $# -gt 0 && $1 != -- ]]; do
    settings+=("$1")
    shift
  done
  if [[ $# -gt 0 ]]; then
    shift
  fi
  output=$(cd "$sandbox" && env \
      -u TEXTMOUTH_BUILD_SLOT -u CLAUDE_CODE_SESSION_ID -u TEXTMOUTH_CLAUDE_TMP_ROOT \
      -u TEXTMOUTH_CHECK_SIMULATE_FAILURE -u TEXTMOUTH_CHECK_SIMULATE_RESOLVED -u GITHUB_ACTIONS \
      PATH="$STUBS:$PATH" STUB_LOG="$stub_log" STUB_RESOLVED="$RESOLVED" \
      STUB_BUILD_LOG="$FIXTURES/build-clean.log" STUB_TEST_OUTPUT="$FIXTURES/tests-pass.log" \
      STUB_APP_BYTES="$DEFAULT_APP_BYTES" STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-ok.txt" \
      STUB_BRAILLE_PACK_LIMIT="$MAC_BRAILLE_PACK_LIMIT_BYTES" STUB_IOS_BRAILLE_PACK_LIMIT="$BRAILLE_PACK_LIMIT_BYTES" \
      ${settings[@]+"${settings[@]}"} "${command[@]}" "$@" 2>&1)
  status=$?
}

# problem <reason>: records why the case in progress fails.
problem() {
  case_problems+="    $1"$'\n'
}

# expect_status <number>: the gate must exit with <number>.
expect_status() {
  [[ $status -eq $1 ]] || problem "exit status was $status, expected $1"
}

# expect_report <text>: the gate's report must contain <text>.
expect_report() {
  grep -F -q -- "$1" <<<"$output" || problem "the report lacks: $1"
}

# refute_report <text>: the gate's report must not contain <text>.
refute_report() {
  if grep -F -q -- "$1" <<<"$output"; then
    problem "the report should not contain: $1"
  fi
}

# expect_verdict <text>: the report's last line must start with <text>.
expect_verdict() {
  local last
  last=$(tail -n 1 <<<"$output")
  [[ $last == "$1"* ]] || problem "the last line was '$last', expected it to start with '$1'"
}

# plant_earlier_builds: fills the sandbox with stand-ins for what earlier
# builds leave: Xcode's compiled code, SwiftPM's build of the test runner,
# the package checkouts that resolution made, and the app make build
# packaged.
plant_earlier_builds() {
  local folder
  for folder in build/DerivedData/Build/Products TextMouthTests/.build/debug build/DerivedData/SourcePackages/checkouts build/TextMouth.app/Contents; do
    mkdir -p "$sandbox/$folder"
    : > "$sandbox/$folder/stand-in"
  done
}

# expect_present <path>: the sandbox must still hold <path>.
expect_present() {
  [[ -e $sandbox/$1 ]] || problem "$1 was removed"
}

# expect_absent <path>: the sandbox must no longer hold <path>.
expect_absent() {
  [[ ! -e $sandbox/$1 ]] || problem "$1 is still there"
}

# expect_commands [command...]: the stubs must have recorded exactly these
# commands, in this order; with no arguments, none at all.
expect_commands() {
  local expected="" actual
  if [[ $# -gt 0 ]]; then
    expected=$(printf '%s\n' "$@")
  fi
  actual=$(cat "$stub_log")
  [[ $actual == "$expected" ]] ||
    problem "commands run: [$(paste -s -d ';' - <<<"$actual")], expected [$(paste -s -d ';' - <<<"$expected")]"
}

# end_case: prints the case's verdict, and under a failure its reasons and
# the gate's report.
end_case() {
  local number=$(( passed + failed + 1 )) line
  if [[ -z $case_problems ]]; then
    passed=$(( passed + 1 ))
    printf 'ok %d - %s\n' "$number" "$case_name"
  else
    failed=$(( failed + 1 ))
    printf 'not ok %d - %s\n%s' "$number" "$case_name" "$case_problems"
    printf '    report of the gate:\n'
    while IFS= read -r line; do
      printf '      %s\n' "$line"
    done <<<"$output"
  fi
}

# dry_run_cases: the gate's logic, with every build command only printed.
dry_run_cases() {
  begin_case "a dry run reports all four steps and runs no command"
  run_gate -- --dry-run
  expect_status 0
  expect_report "step 1 of 4: regenerate the Xcode project from project.yml"
  expect_report "would run: make generate"
  expect_report "would run: make l10n-check"
  expect_report "would run: make resolve-packages"
  expect_report "would remove the compiled code of earlier builds: build/DerivedData/Build and TextMouthTests/.build"
  expect_report "would run: make build"
  expect_report "would require no Swift warnings in build/xcodebuild-Release.log"
  expect_report "would require build/TextMouth.app to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
  expect_report "would run: $IOS_SIZE_RUN"
  expect_report "would require the iPhone app to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
  expect_report "would run: make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "would repeat the performance tests' warnings and skips from build/check/test.log"
  expect_report "would require no Swift warnings in build/check/test.log"
  expect_report "pins match Package.resolved: "
  expect_report "$first_identity $first_version"
  expect_verdict "check: PASSED (dry run)"
  expect_commands
  end_case

  begin_case "the gate's build passes SIGN_APP=: so it never asks for the keychain"
  run_gate -- --dry-run --without-tests
  expect_status 0
  expect_report "would run: make build SIGN_APP=:"
  end_case

  begin_case "a dry run with --without-tests reports three steps and never the suite"
  run_gate -- --dry-run --without-tests
  expect_status 0
  expect_report "step 1 of 3: regenerate the Xcode project from project.yml"
  expect_report "step 3 of 3: build the Release app"
  expect_report "would run: make build"
  expect_report "would require no Swift warnings in build/xcodebuild-Release.log"
  expect_report "would require build/TextMouth.app to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
  expect_report "the hosted XCTest suite is not run by this gate (--without-tests)"
  expect_report "would run: $IOS_SIZE_RUN"
  expect_report "would require the iPhone app to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
  expect_report "pins match Package.resolved: "
  refute_report "step 4"
  refute_report "make test"
  refute_report "performance"
  expect_verdict "check: PASSED (dry run)"
  expect_commands
  end_case

  begin_case "a dry run with --without-tests still fails when the resolution changes a version"
  run_gate TEXTMOUTH_CHECK_SIMULATE_RESOLVED="$FIXTURES/version-drift.resolved" -- --dry-run --without-tests
  expect_status 1
  expect_report "resolved to 999.0.0"
  refute_report "step 3 of 3"
  expect_verdict "check: FAILED: package resolution does not reproduce the committed Package.resolved"
  end_case

  begin_case "a dry run removes no earlier build"
  plant_earlier_builds
  run_gate -- --dry-run
  expect_status 0
  expect_present build/DerivedData/Build/Products/stand-in
  expect_present TextMouthTests/.build/debug/stand-in
  expect_present build/TextMouth.app/Contents/stand-in
  end_case

  begin_case "a dry run fails when the resolution changes a version"
  run_gate TEXTMOUTH_CHECK_SIMULATE_RESOLVED="$FIXTURES/version-drift.resolved" -- --dry-run
  expect_status 1
  expect_report "$first_identity: pinned at $first_version (revision"
  expect_report "resolved to 999.0.0"
  expect_report "make update-packages"
  refute_report "step 3 of 4"
  expect_verdict "check: FAILED: package resolution does not reproduce the committed Package.resolved"
  expect_commands
  end_case

  begin_case "a dry run fails when the resolution changes only a revision"
  run_gate TEXTMOUTH_CHECK_SIMULATE_RESOLVED="$FIXTURES/revision-drift.resolved" -- --dry-run
  expect_status 1
  expect_report "resolved to $first_version (revision 000000000000"
  expect_verdict "check: FAILED: package resolution does not reproduce"
  end_case

  begin_case "a dry run fails when the resolution drops or adds a package"
  run_gate TEXTMOUTH_CHECK_SIMULATE_RESOLVED="$FIXTURES/membership-drift.resolved" -- --dry-run
  expect_status 1
  expect_report "$first_identity: pinned at $first_version"
  expect_report "but missing from the resolution"
  expect_report "selftest-extra: resolved to 1.0.0"
  expect_report "but not pinned in Package.resolved"
  expect_verdict "check: FAILED: package resolution does not reproduce"
  end_case

  begin_case "a dry run fails when the hosted tests fail"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=test -- --dry-run
  expect_status 1
  expect_report "simulated failure of the test step"
  expect_report "full log: build/check/test.log"
  expect_verdict "check: FAILED: step 4 of 4 (run the hosted XCTest suite)"
  expect_commands
  end_case

  begin_case "a dry run stops at a failed Release build"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=build -- --dry-run
  expect_status 1
  refute_report "step 4 of 4"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app)"
  end_case

  begin_case "a dry run stops at a failed iPhone size step, before the suite"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=ios-size -- --dry-run
  expect_status 1
  expect_report "simulated failure of the ios-size step"
  refute_report "step 4 of 4"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app)"
  end_case

  begin_case "a dry run stops at a failed resolution and explains how to update"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=resolve -- --dry-run
  expect_status 1
  expect_report "make update-packages"
  refute_report "step 3 of 4"
  expect_verdict "check: FAILED: step 2 of 4"
  end_case

  begin_case "a dry run stops at a failed String Catalog check, before the packages are resolved"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=l10n -- --dry-run
  expect_status 1
  expect_report "simulated failure of the l10n step"
  expect_report "full log: build/check/l10n.log"
  refute_report "step 2 of 4"
  expect_verdict "check: FAILED: step 1 of 4 (regenerate the Xcode project from project.yml, then check the String Catalog)"
  end_case

  begin_case "a dry run stops at a failed project generation"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=generate -- --dry-run
  expect_status 1
  refute_report "step 2 of 4"
  expect_verdict "check: FAILED: step 1 of 4 (regenerate the Xcode project from project.yml)"
  end_case

  begin_case "make check runs the gate with CHECK_ARGS"
  copy_makefile
  run_gate --via-make -- CHECK_ARGS=--dry-run
  expect_status 0
  expect_verdict "check: PASSED (dry run)"
  expect_commands
  end_case
}

# refusal_cases: settings and states the gate must reject before it runs a
# single command.
refusal_cases() {
  begin_case "simulation variables are refused without --dry-run"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=test
  expect_status 2
  expect_report "accepted only with --dry-run"
  expect_commands
  end_case

  begin_case "an unknown simulated step is refused"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=deploy -- --dry-run
  expect_status 2
  expect_report "must be generate, l10n, resolve, build, ios-size, or test, not: deploy"
  end_case

  begin_case "a missing simulated Package.resolved is refused"
  run_gate TEXTMOUTH_CHECK_SIMULATE_RESOLVED="$WORK/no-such-file" -- --dry-run
  expect_status 2
  expect_report "TEXTMOUTH_CHECK_SIMULATE_RESOLVED names no file"
  end_case

  begin_case "an unknown argument is refused"
  run_gate -- --frobnicate
  expect_status 2
  expect_report "unknown argument: --frobnicate"
  expect_commands
  end_case

  begin_case "--help prints the usage text and runs nothing"
  run_gate -- --help
  expect_status 0
  expect_report "Usage: Scripts/check.sh [--dry-run] [--help]"
  expect_commands
  end_case

  begin_case "a missing Package.resolved fails before any command runs"
  rm "$sandbox/$RESOLVED"
  run_gate
  expect_status 1
  expect_verdict "check: FAILED: $RESOLVED is missing; restore it with: git checkout -- $RESOLVED"
  expect_commands
  end_case

  begin_case "an unreadable Package.resolved fails before any command runs"
  cp "$FIXTURES/malformed.resolved" "$sandbox/$RESOLVED"
  run_gate
  expect_status 1
  expect_verdict "check: FAILED: cannot read the pins in $RESOLVED"
  expect_commands
  end_case

  begin_case "a real run without XcodeGen explains how to install it"
  run_gate PATH="$WORK/stubs-without-xcodegen:/usr/bin:/bin"
  expect_status 2
  expect_report "brew install xcodegen"
  expect_commands
  end_case
}

# build_slot_cases: how the gate chooses the build-slot wrapper.
build_slot_cases() {
  begin_case "TEXTMOUTH_BUILD_SLOT must name an executable file"
  run_gate TEXTMOUTH_BUILD_SLOT="$WORK/no-such-slot.sh" -- --dry-run
  expect_status 2
  expect_report "TEXTMOUTH_BUILD_SLOT is not an executable file"
  end_case

  begin_case "TEXTMOUTH_BUILD_SLOT wraps every xcodebuild step but not generation"
  run_gate TEXTMOUTH_BUILD_SLOT="$SLOT_STUB" -- --dry-run
  expect_status 0
  expect_report "build slot: $SLOT_STUB (from TEXTMOUTH_BUILD_SLOT)"
  expect_report "would run: make generate"
  expect_report "would run: make l10n-check"
  expect_report "would run in a build slot: make resolve-packages"
  expect_report "would run in a build slot: make build"
  expect_report "would run in a build slot: make test"
  end_case

  begin_case "the slot in this Claude Code session's scratchpad is found"
  run_gate CLAUDE_CODE_SESSION_ID="$SESSION" TEXTMOUTH_CLAUDE_TMP_ROOT="$CLAUDE_TMP" -- --dry-run
  expect_status 0
  expect_report "build slot: $SESSION_SLOT (this Claude Code session's scratchpad)"
  expect_report "would run in a build slot: make build"
  end_case

  begin_case "another session's scratchpad slot is not used"
  run_gate CLAUDE_CODE_SESSION_ID=another-session TEXTMOUTH_CLAUDE_TMP_ROOT="$CLAUDE_TMP" -- --dry-run
  expect_status 0
  expect_report "build slot: none, so builds run directly"
  expect_report "would run: make build"
  end_case

  begin_case "an empty TEXTMOUTH_BUILD_SLOT turns the session's slot off"
  run_gate TEXTMOUTH_BUILD_SLOT= CLAUDE_CODE_SESSION_ID="$SESSION" TEXTMOUTH_CLAUDE_TMP_ROOT="$CLAUDE_TMP" -- --dry-run
  expect_status 0
  expect_report "build slot: none (TEXTMOUTH_BUILD_SLOT is empty)"
  expect_report "would run: make build"
  end_case
}

# real_run_cases: the gate's own command handling, against the stubs.
real_run_cases() {
  begin_case "a passing run executes each step in order inside the build slot"
  run_gate TEXTMOUTH_BUILD_SLOT="$SLOT_STUB"
  expect_status 0
  expect_commands "make generate" "make l10n-check" \
    "slot make resolve-packages" "make resolve-packages" \
    "slot make build SIGN_APP=:" "make build SIGN_APP=:" \
    "slot $IOS_SIZE_RUN" "$IOS_SIZE_RECORD" \
    "slot make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1" \
    "make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "Executed 3 tests, with 1 test skipped and 0 failures"
  refute_report "Executed 2 tests"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "build/TextMouth.app is $DEFAULT_APP_TEXT, within the $APP_SIZE_WARNING_MB MB limit"
  expect_report "iPhone app: 12.3 MB (12,345,678 bytes) in 41 files, within the $APP_SIZE_WARNING_MB MB limit."
  expect_report "iPhone app IPA: 10.0 MB (10,000,000 bytes)."
  expect_report "no Swift warnings in build/check/test.log"
  expect_report "Package.resolved still holds the committed pins"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a run with --without-tests resolves and builds, checks both sizes, and never runs the suite"
  run_gate -- --without-tests
  expect_status 0
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD"
  expect_report "iPhone app: 12.3 MB (12,345,678 bytes) in 41 files, within the $APP_SIZE_WARNING_MB MB limit."
  expect_report "step 3 of 3: build the Release app"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "build/TextMouth.app is $DEFAULT_APP_TEXT, within the $APP_SIZE_WARNING_MB MB limit"
  expect_report "the hosted XCTest suite is not run by this gate (--without-tests)"
  expect_report "Package.resolved still holds the committed pins"
  refute_report "Executed"
  expect_verdict "check: PASSED"
  end_case

  begin_case "the release gate (--without-tests) fails an iPhone app over the strict limit"
  run_gate STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-over.txt" STUB_IOS_SIZE_STATUS=3 -- --without-tests
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD"
  expect_verdict "check: FAILED: step 3 of 3 (build the Release app): the iPhone app is more than the $APP_SIZE_LIMIT_MB MB strict limit"
  end_case

  begin_case "on a GitHub runner the iPhone app is neither built nor measured, with or without the suite"
  run_gate GITHUB_ACTIONS=true -- --without-tests
  expect_status 0
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  expect_report "the iPhone app is not built or measured on a GitHub runner (GITHUB_ACTIONS=true)"
  refute_report "iPhone app:"
  expect_verdict "check: PASSED"
  end_case

  begin_case "GITHUB_ACTIONS set to anything but true does not skip the iPhone app"
  run_gate GITHUB_ACTIONS=false -- --without-tests
  expect_status 0
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD"
  end_case

  begin_case "a Release app that names no folder of this Mac passes, and says so"
  run_gate STUB_APP_TEXT="built in /Users/reader/TextMouth"
  expect_status 0
  expect_report "build/TextMouth.app holds no folder of this Mac"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app that holds the checkout's folder fails the gate before the tests, naming the file"
  run_gate STUB_APP_TEXT="built in @ROOT@/TextMouth"
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  expect_report "| Contents/Resources/planted.txt"
  refute_report "holds no folder of this Mac"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds a folder of this Mac (its home folder, the checkout, or \$TMPDIR)"
  end_case

  begin_case "a Release app with an InfoPlist.strings in each language folder and no table of Apple's passes, and the gate reports what it found (FR39)"
  run_gate
  expect_status 0
  expect_report "build/TextMouth.app holds 1 .lproj folders, each with an InfoPlist.strings, and no table of Apple's"
  expect_verdict "check: PASSED"
  end_case

  begin_case "the iPhone app's language folders are checked too, after its size"
  run_gate
  expect_status 0
  expect_report "the iPhone app holds 1 .lproj folders, each with an InfoPlist.strings, and no table of Apple's"
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD" "make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  end_case

  begin_case "a Mac app that still ships a Localizable.strings fails the gate before the iPhone app is built, naming the file"
  run_gate STUB_LPROJ=apple-strings
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  expect_report "APPLE TABLE: Contents/Resources/es.lproj/Localizable.strings"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app ships a table of Apple's (the apps read Strings.pack; the build must not compile the String Catalog)"
  end_case

  begin_case "a Mac app that still ships a Localizable.stringsdict fails the gate, naming the file"
  run_gate STUB_LPROJ=apple-dict
  expect_status 1
  expect_report "APPLE TABLE: Contents/Resources/es.lproj/Localizable.stringsdict"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app ships a table of Apple's"
  end_case

  begin_case "a Mac app that ships a .loctable fails the gate, naming the file"
  run_gate STUB_LPROJ=apple-loctable
  expect_status 1
  expect_report "APPLE TABLE: Contents/Resources/es.lproj/Localizable.loctable"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app ships a table of Apple's"
  end_case

  begin_case "a Mac app that ships the String Catalog fails the gate, naming the file"
  run_gate STUB_LPROJ=apple-catalog
  expect_status 1
  expect_report "APPLE TABLE: Contents/Resources/es.lproj/Localizable.xcstrings"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app ships a table of Apple's"
  end_case

  begin_case "a fixture catalog inside a test bundle in PlugIns is no table of the app's: the gate passes"
  run_gate STUB_LPROJ=xctest-fixture
  expect_status 0
  expect_report "build/TextMouth.app holds 1 .lproj folders, each with an InfoPlist.strings, and no table of Apple's"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Mac app with a language folder that holds no InfoPlist.strings fails the gate, naming the folder"
  run_gate STUB_LPROJ=no-infoplist
  expect_status 1
  expect_report "NO InfoPlist.strings: es.lproj"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app has a .lproj folder with no InfoPlist.strings (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes it)"
  end_case

  begin_case "a Release Mac app that an InfoPlist.strings renames (the tests' name, TextMouth Test) fails the gate, naming the folder"
  run_gate STUB_LPROJ=renamed
  expect_status 1
  expect_report "RENAMED: es.lproj"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app is renamed by an InfoPlist.strings (only a Debug build, the tests', takes the name TEXTMOUTH_TEST_DISPLAY_NAME gives)"
  end_case

  begin_case "a Mac app with no language folder fails the gate"
  run_gate STUB_LPROJ=none
  expect_status 1
  expect_report "NO LANGUAGES: no .lproj folder found in build/TextMouth.app/Contents/Resources"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds no .lproj folder (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes one for each language)"
  end_case

  begin_case "an iPhone app with no language folder fails the gate"
  run_gate STUB_IOS_LPROJ=none
  expect_status 1
  expect_report "NO LANGUAGES: no .lproj folder found in build/ios-size-DerivedData/Build/Products/Release-iphoneos/TextMouth.app"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds no .lproj folder"
  end_case

  begin_case "an iPhone app that ships a Localizable.strings fails the gate, naming the file"
  run_gate STUB_IOS_LPROJ=apple-strings
  expect_status 1
  expect_report "APPLE TABLE: es.lproj/Localizable.strings"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app ships a table of Apple's"
  end_case

  begin_case "an iPhone app that ships a Localizable.stringsdict fails the gate, naming the file"
  run_gate STUB_IOS_LPROJ=apple-dict -- --without-tests
  expect_status 1
  expect_report "APPLE TABLE: es.lproj/Localizable.stringsdict"
  expect_verdict "check: FAILED: step 3 of 3 (build the Release app): the iPhone app ships a table of Apple's"
  end_case

  begin_case "an iPhone app with a language folder that holds no InfoPlist.strings fails the gate"
  run_gate STUB_IOS_LPROJ=no-infoplist
  expect_status 1
  expect_report "NO InfoPlist.strings: es.lproj"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app has a .lproj folder with no InfoPlist.strings"
  end_case

  begin_case "a Release app and an iPhone app with one small Strings.pack pass, and the gate reports each pack's size (FR39)"
  run_gate
  expect_status 0
  expect_report "build/TextMouth.app's Strings.pack is 8 bytes (the limit is 1500000)"
  expect_report "the iPhone app's Strings.pack is 8 bytes (the limit is 1500000)"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Mac app with no Strings.pack fails the gate (the build phase did not run)"
  run_gate STUB_PACK=none
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds 0 files named Strings.pack, not one (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes exactly one into its resources)"
  end_case

  begin_case "a Mac app with a second Strings.pack fails the gate"
  run_gate STUB_PACK=twice
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds 2 files named Strings.pack, not one (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes exactly one into its resources)"
  end_case

  begin_case "a Mac app whose Strings.pack is not in its resources folder fails the gate"
  run_gate STUB_PACK=misplaced
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds its Strings.pack at Contents/Resources/Elsewhere/Strings.pack, not in its resources folder"
  end_case

  begin_case "a Mac app whose Strings.pack is a byte over 1.5 MB fails the gate"
  run_gate STUB_PACK=big
  expect_status 1
  expect_report "build/TextMouth.app's Strings.pack is 1500001 bytes (the limit is 1500000)"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app's Strings.pack is 1500001 bytes, over the 1500000-byte limit"
  end_case

  begin_case "an iPhone app with no Strings.pack fails the gate"
  run_gate STUB_IOS_PACK=none
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds 0 files named Strings.pack, not one (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes exactly one into its resources)"
  end_case

  begin_case "an iPhone app with a second Strings.pack fails the gate"
  run_gate STUB_IOS_PACK=twice
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds 2 files named Strings.pack, not one (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes exactly one into its resources)"
  end_case

  begin_case "an iPhone app whose Strings.pack is over 1.5 MB fails the gate"
  run_gate STUB_IOS_PACK=big
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app's Strings.pack is 1500001 bytes, over the 1500000-byte limit"
  end_case

  # The braille-table pack (FR40): the same rules as the interface-text pack's, each app with its own limit, and no raw
  # liblouis table anywhere in either app.
  local braille_missing="(the build phase \"Pack braille tables\", Scripts/packs/braille_tables.py, writes exactly one into its resources)"
  local braille_raw="raw liblouis tables (the tables are in BrailleTables.pack, which the app unpacks at first use, and no other file of the app is one)"

  begin_case "a Release app and an iPhone app with one small BrailleTables.pack and no raw table pass, and the gate reports each pack's size (FR40)"
  run_gate
  expect_status 0
  expect_report "build/TextMouth.app's BrailleTables.pack is 8 bytes (the limit is $MAC_BRAILLE_PACK_LIMIT_BYTES)"
  expect_report "build/TextMouth.app holds no raw liblouis tables"
  expect_report "the iPhone app's BrailleTables.pack is 8 bytes (the limit is $BRAILLE_PACK_LIMIT_BYTES)"
  expect_report "the iPhone app holds no raw liblouis tables"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Mac app with no BrailleTables.pack fails the gate, naming the build phase and its script"
  run_gate STUB_BRAILLE_PACK=none
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds 0 files named BrailleTables.pack, not one $braille_missing"
  end_case

  begin_case "a Mac app with a second BrailleTables.pack fails the gate"
  run_gate STUB_BRAILLE_PACK=twice
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds 2 files named BrailleTables.pack, not one $braille_missing"
  end_case

  begin_case "a Mac app whose BrailleTables.pack is not in its resources folder fails the gate"
  run_gate STUB_BRAILLE_PACK=misplaced
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds its BrailleTables.pack at Contents/Resources/Elsewhere/BrailleTables.pack, not in its resources folder"
  end_case

  begin_case "a Mac app whose BrailleTables.pack is a byte over the Mac's limit fails the gate"
  run_gate STUB_BRAILLE_PACK=big
  expect_status 1
  expect_report "build/TextMouth.app's BrailleTables.pack is $(( MAC_BRAILLE_PACK_LIMIT_BYTES + 1 )) bytes (the limit is $MAC_BRAILLE_PACK_LIMIT_BYTES)"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app's BrailleTables.pack is $(( MAC_BRAILLE_PACK_LIMIT_BYTES + 1 )) bytes, over the $MAC_BRAILLE_PACK_LIMIT_BYTES-byte limit"
  end_case

  begin_case "a Mac app with a liblouis/tables folder fails the gate, even an empty one"
  run_gate STUB_BRAILLE_PACK=raw-folder
  expect_status 1
  expect_report "| build/TextMouth.app/Contents/Resources/liblouis/tables"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds $braille_raw"
  end_case

  begin_case "a Mac app with a table file beside its BrailleTables.pack fails the gate"
  run_gate STUB_BRAILLE_PACK=raw-file
  expect_status 1
  expect_report "| build/TextMouth.app/Contents/Resources/en-ueb-g2.ctb"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app holds $braille_raw"
  end_case

  begin_case "an iPhone app with no BrailleTables.pack fails the gate, naming the build phase and its script"
  run_gate STUB_IOS_BRAILLE_PACK=none
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds 0 files named BrailleTables.pack, not one $braille_missing"
  end_case

  begin_case "an iPhone app with a second BrailleTables.pack fails the gate"
  run_gate STUB_IOS_BRAILLE_PACK=twice
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds 2 files named BrailleTables.pack, not one $braille_missing"
  end_case

  begin_case "an iPhone app whose BrailleTables.pack is a byte over the iPhone's limit fails the gate"
  run_gate STUB_IOS_BRAILLE_PACK=big
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app's BrailleTables.pack is $(( BRAILLE_PACK_LIMIT_BYTES + 1 )) bytes, over the $BRAILLE_PACK_LIMIT_BYTES-byte limit"
  end_case

  begin_case "an iPhone app with a table file beside its BrailleTables.pack fails the gate"
  run_gate STUB_IOS_BRAILLE_PACK=raw-file
  expect_status 1
  expect_report "TextMouth.app/en-ueb-g2.ctb"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app holds $braille_raw"
  end_case

  begin_case "a dry run says it would require no table of Apple's, an InfoPlist.strings in each language folder, and one of each pack"
  run_gate -- --dry-run
  expect_status 0
  expect_report "would require build/TextMouth.app to hold no table of Apple's, and an InfoPlist.strings in each .lproj folder"
  expect_report "would require the iPhone app to hold no table of Apple's, and an InfoPlist.strings in each .lproj folder"
  expect_report "would require build/TextMouth.app to hold exactly one Strings.pack of at most 1500000 bytes"
  expect_report "would require the iPhone app to hold exactly one Strings.pack of at most 1500000 bytes"
  expect_report "would require build/TextMouth.app to hold exactly one BrailleTables.pack of at most $MAC_BRAILLE_PACK_LIMIT_BYTES bytes"
  expect_report "would require the iPhone app to hold exactly one BrailleTables.pack of at most $BRAILLE_PACK_LIMIT_BYTES bytes"
  end_case

  begin_case "a Release app of exactly the warning size passes with no warning"
  run_gate STUB_APP_BYTES="$APP_SIZE_WARNING_BYTES"
  expect_status 0
  expect_report "build/TextMouth.app is $APP_SIZE_WARNING_MB.0 MB ($APP_SIZE_WARNING_MB,000,000 bytes), within the $APP_SIZE_WARNING_MB MB limit"
  refute_report "WARNING: build/TextMouth.app"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app one byte over the warning size passes with a warning"
  run_gate STUB_APP_BYTES=$(( APP_SIZE_WARNING_BYTES + 1 ))
  expect_status 0
  expect_report "WARNING: build/TextMouth.app is $APP_SIZE_WARNING_MB.0 MB ($APP_SIZE_WARNING_MB,000,001 bytes), more than the $APP_SIZE_WARNING_MB MB limit; the gate fails above $APP_SIZE_LIMIT_MB MB"
  refute_report "build/TextMouth.app is $APP_SIZE_WARNING_MB.0 MB ($APP_SIZE_WARNING_MB,000,001 bytes), within the"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app of exactly the strict limit passes with a warning"
  run_gate STUB_APP_BYTES="$APP_SIZE_LIMIT_BYTES"
  expect_status 0
  expect_report "WARNING: build/TextMouth.app is $APP_SIZE_LIMIT_MB.0 MB ($APP_SIZE_LIMIT_MB,000,000 bytes), more than the $APP_SIZE_WARNING_MB MB limit; the gate fails above $APP_SIZE_LIMIT_MB MB"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app one byte over the strict limit fails the gate before the tests"
  run_gate STUB_APP_BYTES=$(( APP_SIZE_LIMIT_BYTES + 1 ))
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "the limits are APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB in Scripts/check.sh; find what grew before raising them"
  refute_report "build/TextMouth.app is $APP_SIZE_LIMIT_MB.0 MB ($APP_SIZE_LIMIT_MB,000,001 bytes), within the"
  refute_report "WARNING: build/TextMouth.app"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app is $APP_SIZE_LIMIT_MB.0 MB ($APP_SIZE_LIMIT_MB,000,001 bytes), more than the $APP_SIZE_LIMIT_MB MB strict limit"
  end_case

  begin_case "an iPhone app over the warning size passes with a warning"
  run_gate STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-warn.txt"
  expect_status 0
  expect_report "WARNING: the iPhone app is more than the $APP_SIZE_WARNING_MB MB limit; the gate fails above $APP_SIZE_LIMIT_MB MB"
  expect_report "iPhone app: 35.0 MB (35,000,000 bytes) in 41 files, over the $APP_SIZE_WARNING_MB MB limit, within the strict $APP_SIZE_LIMIT_MB MB."
  expect_verdict "check: PASSED"
  end_case

  begin_case "an iPhone app over the strict limit fails the gate before the tests"
  run_gate STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-over.txt" STUB_IOS_SIZE_STATUS=3
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD"
  expect_report "iPhone app: 41.0 MB (41,000,000 bytes) in 41 files, over the strict $APP_SIZE_LIMIT_MB MB limit."
  expect_report "the biggest files and libraries are in build/check/ios-size.log"
  refute_report "Executed"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app is more than the $APP_SIZE_LIMIT_MB MB strict limit"
  end_case

  begin_case "a failed iPhone device build fails the gate before the tests, naming the log"
  run_gate STUB_IOS_SIZE_OUTPUT= STUB_IOS_SIZE_STATUS=1
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD"
  expect_report "failed with exit status 1"
  expect_report "full log: build/check/ios-size.log"
  expect_report "The iPhone device build (Scripts/ios/app-size.py) failed, not the Mac's build."
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app, the iPhone app's device build)"
  end_case

  begin_case "a download estimate over the warning size does not call a small iPhone app over the limit"
  run_gate STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-download.txt"
  expect_status 0
  refute_report "WARNING: the iPhone app"
  expect_verdict "check: PASSED"
  end_case

  begin_case "an iPhone app whose headline is over the strict limit fails even when the tool exits 0"
  run_gate STUB_IOS_SIZE_OUTPUT="$FIXTURES/ios-size-over.txt"
  expect_status 1
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): the iPhone app is more than the $APP_SIZE_LIMIT_MB MB strict limit"
  end_case

  begin_case "an iPhone size tool that prints no size fails the gate, never passing on silence"
  run_gate STUB_IOS_SIZE_OUTPUT=
  expect_status 1
  expect_report "build/check/ios-size.log has no size lines"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/check/ios-size.log has no size lines, so the iPhone app's size is unknown"
  end_case

  begin_case "a Release build that packages no app fails the gate, never measuring an earlier build's"
  plant_earlier_builds
  run_gate STUB_APP_BYTES=
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  refute_report " MB ("
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app is missing, so the app's size is unknown"
  end_case

  begin_case "a Swift warning in the Release build fails the gate before the tests, naming the first five"
  run_gate STUB_BUILD_LOG="$FIXTURES/build-warnings.log"
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  # Six, not seven: the warning reported again for x86_64 counts once.
  expect_report "6 Swift warnings in build/xcodebuild-Release.log; the first 5:"
  expect_report "| TextMouth/Services/Ledger.swift:12:9: warning: capture of 'entry' with non-Sendable type"
  expect_report "| TextMouth/Services/Ledger.swift:20:13: warning: initialization of immutable value 'unused'"
  expect_report "| TextMouth/Models/Tally.swift:7:5: warning: var 'sharedTally' is not concurrency-safe"
  expect_report "| TextMouth/Views/Shelf.swift:44:17: warning: 'reload()' is deprecated"
  expect_report "| TextMouth/Views/Shelf.swift:51:9: warning: will never be executed"
  refute_report "<unknown>:0: warning"
  refute_report "ld: warning"
  refute_report "appintentsmetadataprocessor"
  expect_report "the gate allows no Swift warning, about concurrency or anything else"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): 6 Swift warnings"
  end_case

  begin_case "a Swift warning in the hosted test build fails the gate; lines a test prints do not"
  run_gate STUB_TEST_OUTPUT="$FIXTURES/tests-warning.log"
  expect_status 1
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "Executed 3 tests, with 0 failures"
  expect_report "1 Swift warning in build/check/test.log:"
  expect_report "| TextMouthProductionTests/LedgerTests.swift:30:13: warning: variable 'total' was never mutated"
  refute_report "printed by a test"
  expect_verdict "check: FAILED: step 4 of 4 (run the hosted XCTest suite): 1 Swift warning"
  end_case

  begin_case "a Release build that leaves no log fails the gate, never reading an earlier build's"
  mkdir -p "$sandbox/build"
  printf '%s/TextMouth/Old.swift:1:1: warning: left by an earlier build\n' "$sandbox" > "$sandbox/build/xcodebuild-Release.log"
  run_gate STUB_BUILD_LOG=
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  refute_report "left by an earlier build"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/xcodebuild-Release.log is missing, so the build's Swift warnings are unknown"
  end_case

  begin_case "a run removes earlier builds' compiled code before building and keeps the package checkouts"
  plant_earlier_builds
  run_gate
  expect_status 0
  # The make stub would have recorded finding an earlier build.
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD" \
    "make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "removed the compiled code of earlier builds, so every source compiles: build/DerivedData/Build and TextMouthTests/.build"
  expect_absent build/DerivedData/Build
  expect_absent TextMouthTests/.build
  expect_present build/DerivedData/SourcePackages/checkouts/stand-in
  expect_report "build/TextMouth.app is $DEFAULT_APP_TEXT"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a failing hosted test fails the gate and names the failure"
  run_gate STUB_TEST_OUTPUT="$FIXTURES/tests-fail.log" STUB_TEST_STATUS=65
  expect_status 1
  expect_report "failed with exit status 65"
  expect_report "Executed 3 tests, with 1 failure (0 unexpected)"
  expect_report "XCTAssertTrue failed"
  refute_report "testPasses]' started"
  expect_report "full log: build/check/test.log"
  expect_verdict "check: FAILED: step 4 of 4 (run the hosted XCTest suite)"
  end_case

  begin_case "a compile error fails the gate before the tests run"
  run_gate STUB_FAIL_TARGET=build
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:"
  expect_report "error: simulated failure of make build"
  expect_report "make: *** [build] Error 65"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app)"
  end_case

  begin_case "xcodebuild rejecting the pins fails the gate before the build"
  run_gate STUB_FAIL_TARGET=resolve-packages
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages"
  expect_report "make update-packages"
  expect_verdict "check: FAILED: step 2 of 4"
  end_case

  begin_case "a resolution that rewrites a pin fails the gate before the build"
  run_gate STUB_RESOLVE_WRITES="$FIXTURES/version-drift.resolved"
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages"
  expect_report "$first_identity: pinned at $first_version"
  expect_report "resolved to 999.0.0"
  expect_verdict "check: FAILED: package resolution does not reproduce the committed Package.resolved"
  end_case

  begin_case "a pin changed during the build fails the final check"
  run_gate STUB_BUILD_WRITES="$FIXTURES/revision-drift.resolved"
  expect_status 1
  expect_commands "make generate" "make l10n-check" "make resolve-packages" "make build SIGN_APP=:" "$IOS_SIZE_RECORD" \
    "make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "revision 000000000000"
  expect_verdict "check: FAILED: Package.resolved changed during the build or tests"
  end_case

  begin_case "the gate repeats the performance tests' warnings and skips, once each, and still passes"
  run_gate STUB_TEST_OUTPUT="$FIXTURES/tests-performance.log"
  expect_status 0
  expect_report "check:   PERFORMANCE WARNING: launch: 182.000 milliseconds, 1.52 times its baseline"
  expect_report "check:   PERFORMANCE SKIPPED: the baselines were recorded on a Mac15,12"
  if [[ $(grep -c -F 'PERFORMANCE SKIPPED:' <<<"$output") -ne 1 ]]; then
    problem "the skip was not repeated exactly once"
  fi
  refute_report "PERFORMANCE NOTE:"
  refute_report "PERFORMANCE: launch"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a test run without XCTest totals fails the gate"
  run_gate STUB_TEST_OUTPUT="$FIXTURES/tests-without-totals.log"
  expect_status 1
  expect_verdict "check: FAILED: the hosted test run printed no XCTest totals"
  end_case

  begin_case "a test run that executes no tests fails the gate"
  run_gate STUB_TEST_OUTPUT="$FIXTURES/tests-zero.log"
  expect_status 1
  expect_report "Executed 0 tests"
  expect_verdict "check: FAILED: the hosted test run executed no tests"
  end_case
}

# run_make_test [make arguments...]: runs the Makefile's own test target in
# the case's sandbox, with the recording swift first on PATH and no
# strictness from the caller's environment, storing the report in $output
# and the exit status in $status.
run_make_test() {
  copy_makefile
  mkdir -p "$sandbox/TextMouthTests"
  output=$(cd "$sandbox" && env -u TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT \
      PATH="$SWIFT_RECORDER:$PATH" STUB_LOG="$stub_log" \
      "$REAL_MAKE" -s test "$@" 2>&1)
  status=$?
}

# makefile_cases: the Makefile's test target, which the gate runs, hands its
# options to the hosted test runner as the variables the runner reads.
makefile_cases() {
  begin_case "make test PERFORMANCE_STRICT=1 has the performance tests measure on a busy Mac"
  run_make_test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1
  expect_status 0
  expect_commands "swift run in TextMouthTests" \
    "TEXTMOUTH_TEST_DERIVED_DATA=build/DerivedData" \
    "TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=1"
  end_case

  begin_case "make test without PERFORMANCE_STRICT leaves the performance tests free to skip"
  run_make_test
  expect_status 0
  expect_commands "swift run in TextMouthTests" \
    "TEXTMOUTH_TEST_DERIVED_DATA=" \
    "TEST_RUNNER_TEXTMOUTH_PERFORMANCE_STRICT=(unset)"
  end_case

  # make -n prints the build's commands and runs none of them.
  begin_case "make build turns off the code coverage the scheme would build into the app"
  copy_makefile
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build 2>&1)
  status=$?
  expect_status 0
  expect_report "-configuration Release"
  expect_report "CLANG_COVERAGE_MAPPING=NO"
  end_case

  # The Release app is compiled for size, the Swift packages' targets
  # included, which only a setting on the command line reaches; Debug keeps
  # its own level, so make debug must not pass it.
  begin_case "make build compiles the Release app and its packages with -Osize, and make debug does not"
  copy_makefile
  # On GitHub Actions a build takes every size setting (the profile "auto").
  output=$(cd "$sandbox" && env GITHUB_ACTIONS=true "$REAL_MAKE" -n build 2>&1)
  status=$?
  expect_status 0
  expect_report "SWIFT_OPTIMIZATION_LEVEL=-Osize"
  expect_report "SWIFT_LTO=YES"
  refute_report "SWIFT_REFLECTION_METADATA_LEVEL"
  expect_report "-Xfrontend -internalize-at-link"
  refute_report "SWIFT_COMPILATION_MODE"
  # On a Mac a development build is light: no link-time optimization, which
  # takes several GB of memory, and none of the flags tested only with it.
  output=$(cd "$sandbox" && env -u GITHUB_ACTIONS "$REAL_MAKE" -n build 2>&1)
  status=$?
  expect_status 0
  expect_report "SWIFT_OPTIMIZATION_LEVEL=-Osize"
  expect_report "GCC_OPTIMIZATION_LEVEL=z"
  refute_report "SWIFT_LTO"
  refute_report "LLVM_LTO"
  refute_report "-Xfrontend"
  # The app that ships is full on a Mac too: make install and make release.
  output=$(cd "$sandbox" && env -u GITHUB_ACTIONS "$REAL_MAKE" -n release 2>&1)
  status=$?
  expect_status 0
  expect_report "SWIFT_LTO=YES"
  expect_report "-Xfrontend -internalize-at-link"
  expect_report "quit other heavy apps"
  # A profile the script does not know stops the build rather than leave the settings out.
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build SIZE_PROFILE=fulll 2>&1)
  status=$?
  expect_status 2
  expect_report "gave no settings for SIZE_PROFILE=fulll"
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build CONFIG=Debug 2>&1)
  status=$?
  expect_status 0
  expect_report "-configuration Debug"
  refute_report "SWIFT_OPTIMIZATION_LEVEL"
  refute_report "SWIFT_LTO"
  refute_report "SWIFT_REFLECTION_METADATA_LEVEL"
  end_case

  # make install-ios builds the iPhone app for the user's own iPhone. `make -n` prints its commands and
  # runs none of them: nothing here signs, builds, or installs.
  begin_case "make install-ios is light by default, takes the lock, and passes TEAM, DEVICE, and LAUNCH through"
  copy_makefile
  output=$(cd "$sandbox" && "$REAL_MAKE" -n install-ios 2>&1)
  status=$?
  expect_status 0
  expect_report "run_locked.py install-ios"
  expect_report "install-on-device.py --profile \"light\""
  refute_report "--team"
  refute_report "--device"
  refute_report "--launch"
  # make -n prints the note's command either way: its test says whether the note would be printed.
  expect_report 'if [ "light" = "full" ]'
  # SIZE_PROFILE=full overrides the target's light, and then the memory note is printed.
  output=$(cd "$sandbox" && "$REAL_MAKE" -n install-ios SIZE_PROFILE=full TEAM=X DEVICE=Y LAUNCH=1 2>&1)
  status=$?
  expect_status 0
  expect_report "--profile \"full\" --team \"X\" --device \"Y\" --launch"
  expect_report 'if [ "full" = "full" ]'
  refute_report 'if [ "light" = "full" ]'
  end_case

  # The once-per-release run of the golden tests against a Release build must
  # build what ships (Release, -Osize) with testability on and the settings
  # that would hide the app's symbols from the test bundle switched back.
  begin_case "release-goldens.sh builds a testable Release app and names the golden classes"
  output=$(env -u GITHUB_ACTIONS "$ROOT/Scripts/test/release-goldens.sh" --dry-run --no-slot 2>&1)
  status=$?
  expect_status 0
  expect_report "-configuration Release"
  expect_report "SWIFT_OPTIMIZATION_LEVEL=-Osize"
  expect_report "ENABLE_TESTABILITY=YES"
  expect_report "LD_EXPORT_SYMBOLS=YES"
  expect_report "DEAD_CODE_STRIPPING=NO"
  expect_report "DEPLOYMENT_POSTPROCESSING=NO"
  # The size settings are the profile's ("auto"): on a Mac, light.
  expect_report "GCC_OPTIMIZATION_LEVEL=z"
  refute_report "SWIFT_LTO"
  refute_report "SWIFT_REFLECTION_METADATA_LEVEL"
  # On GitHub Actions, every one, less the one flag a test bundle cannot link against.
  output=$(env GITHUB_ACTIONS=true "$ROOT/Scripts/test/release-goldens.sh" --dry-run --no-slot 2>&1)
  status=$?
  expect_status 0
  expect_report "SWIFT_LTO=YES"
  expect_report "-Xfrontend -conditional-runtime-records"
  refute_report "-internalize-at-link"
  expect_report "-only-testing:TextMouthProductionTests/TextPipelineGoldenTests"
  expect_report "-only-testing:TextMouthProductionTests/DocumentGoldenTests"
  expect_report "-only-testing:TextMouthProductionTests/MarkupGuardTests"
  end_case
}

# A UUID of the form dwarfdump prints, made from a number, so each planted
# build has one of its own: fake_uuid 7 is 00000007-0000-4000-8000-000000000007.
fake_uuid() {
  printf '%08X-0000-4000-8000-%012X' "$1" "$1"
}

# A build number of the form make build stamps, YYYYMMDDHHMMSS, made from a
# number below 60: fake_build 7 is 20260101000007.
fake_build() {
  printf '202601010000%02d' "$1"
}

# plant_install_products <build number> <UUID>...: fills the sandbox with
# what make build leaves for make install: the packaged app, build/TextMouth.app,
# with <build number> as its CFBundleVersion, and its build's dSYM in the
# build products. The stub dwarfdump reads each one's UUIDs, one for each
# architecture, from its executable or DWARF file.
plant_install_products() {
  local build=$1
  shift
  local app="$sandbox/build/TextMouth.app"
  local dsym="$sandbox/build/DerivedData/Build/Products/Release/TextMouth.app.dSYM"
  rm -rf "$app" "$dsym"
  mkdir -p "$app/Contents/MacOS" "$dsym/Contents/Resources/DWARF"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleVersion</key><string>%s</string></dict></plist>\n' \
    "$build" > "$app/Contents/Info.plist"
  printf '%s\n' "$@" > "$app/Contents/MacOS/TextMouth"
  printf '%s\n' "$@" > "$dsym/Contents/Resources/DWARF/TextMouth"
}

# kept_dsym <build number> <UUIDs joined by "-">: the path, in the sandbox, of
# the dSYM make install keeps for that build.
kept_dsym() {
  printf 'build/installed-dSYMs/TextMouth-%s-%s.app.dSYM' "$1" "$2"
}

# run_make_install <target>: runs the Makefile's install or uninstall target
# in the case's sandbox without building it (make -o build) and without ever
# reaching /Applications: the app goes to the sandbox's own Applications
# folder, Launch Services' tool is the recording stub, and dwarfdump is the
# stub that reads the planted UUIDs. Stores the report in $output and the
# exit status in $status.
run_make_install() {
  local target=$1
  # INSTALL_DIR below must lie inside this case's sandbox, which is checked
  # here first, so no mistake in a case can reach the real /Applications.
  if [[ -z $sandbox || $sandbox != "$WORK"/case-* ]]; then
    problem "refused to run make $target outside a case's sandbox: '$sandbox'"
    output=""
    status=1
    return
  fi
  copy_makefile
  mkdir -p "$sandbox/Scripts" "$sandbox/Applications"
  cp "$ROOT/Scripts/keep-installed-dsym.sh" "$sandbox/Scripts/keep-installed-dsym.sh"
  output=$(cd "$sandbox" && env PATH="$STUBS:$PATH" STUB_LOG="$stub_log" \
      "$REAL_MAKE" -s -o build "$target" \
      INSTALL_DIR="$sandbox/Applications" LSREGISTER="$STUBS/lsregister" 2>&1)
  status=$?
}

# install_cases: make install keeps the installed build's dSYM where later
# builds leave it, for the last few installs, and make uninstall leaves them.
install_cases() {
  local uuid build number

  begin_case "make install installs the app and keeps its dSYM, named by build number and UUID"
  plant_install_products "$(fake_build 1)" "$(fake_uuid 1)"
  run_make_install install
  expect_status 0
  expect_present Applications/TextMouth.app/Contents/MacOS/TextMouth
  expect_present "$(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)")/Contents/Resources/DWARF/TextMouth"
  expect_commands "lsregister -f $sandbox/Applications/TextMouth.app"
  expect_report "kept this build's dSYM, for its crash reports: $(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)")"
  expect_report "==> Installed."
  end_case

  begin_case "make install keeps the dSYMs of the last $INSTALLED_DSYMS_KEPT installs and nothing else in their folder goes"
  mkdir -p "$sandbox/build/installed-dSYMs/Other.app.dSYM"
  : > "$sandbox/build/installed-dSYMs/notes.txt"
  for (( number = 1; number <= INSTALLED_DSYMS_KEPT + 2; number++ )); do
    plant_install_products "$(fake_build "$number")" "$(fake_uuid "$number")"
    run_make_install install
    expect_status 0
  done
  for (( number = 1; number <= INSTALLED_DSYMS_KEPT + 2; number++ )); do
    if (( number <= 2 )); then
      expect_absent "$(kept_dsym "$(fake_build "$number")" "$(fake_uuid "$number")")"
    else
      expect_present "$(kept_dsym "$(fake_build "$number")" "$(fake_uuid "$number")")"
    fi
  done
  expect_present build/installed-dSYMs/Other.app.dSYM
  expect_present build/installed-dSYMs/notes.txt
  expect_report "removed an older install's dSYM, keeping the last $INSTALLED_DSYMS_KEPT: $(kept_dsym "$(fake_build 2)" "$(fake_uuid 2)")"
  end_case

  begin_case "make install always keeps the dSYM it just kept, even beside dSYMs of later build numbers"
  for (( number = 11; number <= 10 + INSTALLED_DSYMS_KEPT; number++ )); do
    plant_install_products "$(fake_build "$number")" "$(fake_uuid "$number")"
    run_make_install install
  done
  plant_install_products "$(fake_build 1)" "$(fake_uuid 1)"
  run_make_install install
  expect_status 0
  expect_present "$(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)")"
  expect_absent "$(kept_dsym "$(fake_build 11)" "$(fake_uuid 11)")"
  expect_present "$(kept_dsym "$(fake_build 12)" "$(fake_uuid 12)")"
  end_case

  begin_case "make install names a universal build's dSYM by all its UUIDs"
  plant_install_products "$(fake_build 1)" "$(fake_uuid 2)" "$(fake_uuid 1)"
  run_make_install install
  expect_status 0
  expect_present "$(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)-$(fake_uuid 2)")"
  end_case

  begin_case "make install keeps no dSYM of another build, and still installs"
  plant_install_products "$(fake_build 1)" "$(fake_uuid 1)"
  printf '%s\n' "$(fake_uuid 2)" > "$sandbox/build/DerivedData/Build/Products/Release/TextMouth.app.dSYM/Contents/Resources/DWARF/TextMouth"
  run_make_install install
  expect_status 0
  expect_present Applications/TextMouth.app/Contents/MacOS/TextMouth
  expect_absent "$(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)")"
  expect_report "warning: kept no dSYM for the installed app: build/DerivedData/Build/Products/Release/TextMouth.app.dSYM is another build's (UUID $(fake_uuid 2); the installed app's is $(fake_uuid 1))"
  end_case

  begin_case "make install of a build that made no dSYM installs and says it kept none"
  plant_install_products "$(fake_build 1)" "$(fake_uuid 1)"
  rm -rf "$sandbox/build/DerivedData/Build/Products/Release/TextMouth.app.dSYM"
  run_make_install install
  expect_status 0
  expect_present Applications/TextMouth.app/Contents/MacOS/TextMouth
  expect_absent build/installed-dSYMs
  expect_report "warning: kept no dSYM for the installed app: the build made no dSYM at build/DerivedData/Build/Products/Release/TextMouth.app.dSYM"
  end_case

  begin_case "make uninstall removes the installed app and leaves the kept dSYMs"
  plant_install_products "$(fake_build 1)" "$(fake_uuid 1)"
  run_make_install install
  : > "$stub_log"
  run_make_install uninstall
  expect_status 0
  expect_absent Applications/TextMouth.app
  expect_present "$(kept_dsym "$(fake_build 1)" "$(fake_uuid 1)")/Contents/Resources/DWARF/TextMouth"
  expect_commands
  expect_report "The dSYMs in build/installed-dSYMs stay"
  end_case
}

# write_signing_stubs: creates the security and codesign stubs for the
# signing cases, in a folder of their own, so no other case meets them. The
# security stub answers `find-identity` as the real one does, with one
# "TextMouth Developer" identity whose SHA-1 is STUB_IDENTITY_HASH, or none
# when that is empty. The codesign stub records its call; it signs, exiting
# with STUB_CODESIGN_STATUS (default 0), and displays the designated
# requirement a self-signed identity gives.
write_signing_stubs() {
  mkdir -p "$SIGNING_STUBS"
  cat > "$SIGNING_STUBS/security" <<'STUB'
#!/bin/bash
# Stub security for check-selftest.sh's signing cases.
echo "security $*" >> "$STUB_LOG"
if [ "${1:-}" = find-identity ]; then
  echo "Policy: Code Signing"
  echo "  Matching identities"
  if [ -n "${STUB_IDENTITY_HASH:-}" ]; then
    echo "  1) $STUB_IDENTITY_HASH \"TextMouth Developer\" (CSSMERR_TP_NOT_TRUSTED)"
    echo "     1 identities found"
  else
    echo "     0 identities found"
  fi
  echo ""
  echo "  Valid identities only"
  echo "     0 valid identities found"
  exit 0
fi
echo "stub: the signing script must not run security $1 when it signs" >&2
exit 97
STUB
  cat > "$SIGNING_STUBS/codesign" <<'STUB'
#!/bin/bash
# Stub codesign for check-selftest.sh's signing cases.
echo "codesign $*" >> "$STUB_LOG"
case " $* " in
  *" --display "*)
    hash=$(tr 'A-F' 'a-f' <<<"${STUB_IDENTITY_HASH:-}")
    echo "designated => identifier \"com.textmouth.TextMouth\" and certificate leaf = H\"$hash\"" ;;
  *)
    exit "${STUB_CODESIGN_STATUS:-0}" ;;
esac
exit 0
STUB
  chmod +x "$SIGNING_STUBS"/*
}

# run_signing_script [NAME=value...] -- [arguments...]: runs the case's copy of
# make-signing-identity.sh with the signing stubs first on PATH and the given
# variables, storing the report in $output and the exit status in $status.
run_signing_script() {
  local -a settings=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    settings+=("$1")
    shift
  done
  [[ $# -gt 0 ]] && shift
  mkdir -p "$sandbox/Scripts"
  cp "$ROOT/Scripts/make-signing-identity.sh" "$sandbox/Scripts/make-signing-identity.sh"
  output=$(cd "$sandbox" && env PATH="$SIGNING_STUBS:$PATH" STUB_LOG="$stub_log" \
      ${settings[@]+"${settings[@]}"} ./Scripts/make-signing-identity.sh "$@" 2>&1)
  status=$?
}

# identities_in <keychain>: prints how many "TextMouth Developer" code-signing
# identities <keychain> holds, and the SHA-1 of the first, if any.
identities_in() {
  security find-identity -p codesigning "$1" 2>/dev/null |
    awk '/"TextMouth Developer"/ { count++; if (count == 1) first = $2 } END { print count + 0, first }'
}

# signing_identity_cases: make-signing-identity.sh makes the identity once,
# in a throwaway keychain that no prompt can guard, and signs an app with it
# or leaves the app's ad hoc signature; make build runs it on the app it
# packages.
signing_identity_cases() {
  local keychain first second
  write_signing_stubs

  begin_case "make-signing-identity.sh makes the identity once, and a second run changes nothing"
  # The real security and OpenSSL, on a keychain of the case's own: created
  # with a known password, unlocked, and never locked by a timeout, so
  # nothing can ask for a password. The login keychain is never touched.
  keychain="$sandbox/selftest.keychain-db"
  if security create-keychain -p selftest "$keychain" >/dev/null 2>&1 &&
     security set-keychain-settings "$keychain" >/dev/null 2>&1; then
    mkdir -p "$sandbox/Scripts"
    cp "$ROOT/Scripts/make-signing-identity.sh" "$sandbox/Scripts/make-signing-identity.sh"
    output=$(cd "$sandbox" && TEXTMOUTH_SIGNING_KEYCHAIN="$keychain" ./Scripts/make-signing-identity.sh 2>&1)
    status=$?
    expect_status 0
    expect_report "Created the signing identity \"TextMouth Developer\""
    first=$(identities_in "$keychain")
    [[ $first == 1\ * ]] || problem "after the first run the keychain held '$first' identities, expected 1"

    output=$(cd "$sandbox" && TEXTMOUTH_SIGNING_KEYCHAIN="$keychain" ./Scripts/make-signing-identity.sh 2>&1)
    status=$?
    expect_status 0
    expect_report "is already in $keychain"
    expect_report "nothing to do"
    second=$(identities_in "$keychain")
    [[ $second == "$first" ]] || problem "the second run changed the keychain's identities from '$first' to '$second'"
    security delete-keychain "$keychain" >/dev/null 2>&1
  else
    problem "security could not make a throwaway keychain at $keychain"
  fi
  end_case

  begin_case "make-signing-identity.sh --sign-app leaves the ad hoc signature, with a note, when there is no identity"
  mkdir -p "$sandbox/TextMouth.app/Contents/MacOS"
  run_signing_script STUB_IDENTITY_HASH= -- --sign-app TextMouth.app
  expect_status 0
  expect_report "note: this Mac has no \"TextMouth Developer\" signing identity, so TextMouth.app keeps its ad hoc"
  expect_report "Run make signing-identity once to make one."
  expect_commands "security find-identity -p codesigning"
  end_case

  begin_case "make-signing-identity.sh --sign-app signs by the identity's hash, keeping the build's entitlements"
  mkdir -p "$sandbox/TextMouth.app/Contents/MacOS"
  run_signing_script STUB_IDENTITY_HASH=E534CDBBF5662D052E8EF84D0781B0E89FC70D8D -- --sign-app TextMouth.app
  expect_status 0
  expect_commands "security find-identity -p codesigning" \
    "codesign --force --sign E534CDBBF5662D052E8EF84D0781B0E89FC70D8D --preserve-metadata=entitlements --timestamp=none TextMouth.app" \
    "codesign --display --requirements - TextMouth.app"
  expect_report "==> Signed TextMouth.app with \"TextMouth Developer\"; its designated requirement: identifier \"com.textmouth.TextMouth\" and certificate leaf = H\"e534cdbbf5662d052e8ef84d0781b0e89fc70d8d\""
  end_case

  begin_case "make-signing-identity.sh --sign-app fails, saying why, when codesign cannot use the identity"
  mkdir -p "$sandbox/TextMouth.app/Contents/MacOS"
  run_signing_script STUB_IDENTITY_HASH=E534CDBBF5662D052E8EF84D0781B0E89FC70D8D STUB_CODESIGN_STATUS=1 -- --sign-app TextMouth.app
  expect_status 1
  expect_report "codesign could not sign TextMouth.app with \"TextMouth Developer\""
  expect_report "security unlock-keychain"
  refute_report "==> Signed"
  end_case

  # make -n prints the targets' commands and runs none of them.
  begin_case "make build signs the app it packages, and make signing-identity makes the identity"
  copy_makefile
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build signing-identity 2>&1)
  status=$?
  expect_status 0
  expect_report "Scripts/make-signing-identity.sh --sign-app \"build/TextMouth.app\""
  # make signing-identity runs the script with no arguments: a line of its own.
  grep -x -F -q "Scripts/make-signing-identity.sh" <<<"$output" ||
    problem "make signing-identity does not run Scripts/make-signing-identity.sh on its own"
  end_case
}

# main: runs every case and prints the totals; succeeds only when all pass.
main() {
  write_stubs
  write_fixtures
  dry_run_cases
  refusal_cases
  build_slot_cases
  real_run_cases
  makefile_cases
  install_cases
  signing_identity_cases
  printf '%d passed, %d failed\n' "$passed" "$failed"
  (( failed == 0 ))
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# run never reads past this point, even if the file is edited mid-run.
main; exit $?
