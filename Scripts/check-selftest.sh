#!/bin/bash
#
# check-selftest.sh: tests Scripts/check.sh in a few seconds, without building.
#
# Every case copies check.sh and the committed Package.resolved into a fresh
# sandbox folder, puts stub make, xcodebuild, xcodegen, xcrun, and swift
# commands first on PATH, runs the gate there, and checks its exit status, its
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

# The Release app's size limit, read from check.sh, which defines it once, so
# these cases follow the limit when it changes. The expected reports below
# write a size of a whole number of megabytes as "<limit>.0 MB (<limit>,000,000
# bytes)", which holds for a limit under 1,000 MB.
APP_SIZE_LIMIT_MB=$(sed -n -E 's/^readonly APP_SIZE_LIMIT_MB=([0-9]+)$/\1/p' "$ROOT/Scripts/check.sh")
if [[ ! $APP_SIZE_LIMIT_MB =~ ^[1-9][0-9]{0,2}$ ]]; then
  echo "check-selftest: Scripts/check.sh must set APP_SIZE_LIMIT_MB to a whole number from 1 to 999" >&2
  exit 1
fi
readonly APP_SIZE_LIMIT_MB
readonly APP_SIZE_LIMIT_BYTES=$(( APP_SIZE_LIMIT_MB * 1000000 ))

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
#   STUB_TEST_OUTPUT=<file>     test prints <file>
#   STUB_TEST_STATUS=<number>   test exits with <number> (default 0)
# In the log and output files, @ROOT@ stands for the repository root, since
# xcodebuild names every source file by its full path.

# with_root <file>: prints <file> with the repository root in place of @ROOT@.
with_root() {
  sed "s#@ROOT@#$(pwd -P)#g" "$1"
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
      dd if=/dev/zero of=build/TextMouth.app/Contents/MacOS/TextMouth bs=1 count=0 \
        seek=$(( STUB_APP_BYTES - 600 )) 2>/dev/null
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
  cp "$ROOT/$RESOLVED" "$sandbox/$RESOLVED"
  stub_log="$sandbox/commands.log"
  : > "$stub_log"
}

# run_gate [--via-make] [NAME=value...] [-- arguments...]: runs the sandbox's
# gate, or `make check` with --via-make, with the stubs first on PATH, none of
# the caller's build-slot or simulation settings, and the given variables,
# which override the defaults. Stores the report in $output and the exit
# status in $status.
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
      -u TEXTMOUTH_CHECK_SIMULATE_FAILURE -u TEXTMOUTH_CHECK_SIMULATE_RESOLVED \
      PATH="$STUBS:$PATH" STUB_LOG="$stub_log" STUB_RESOLVED="$RESOLVED" \
      STUB_BUILD_LOG="$FIXTURES/build-clean.log" STUB_TEST_OUTPUT="$FIXTURES/tests-pass.log" \
      STUB_APP_BYTES="$DEFAULT_APP_BYTES" \
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
  expect_report "would run: make resolve-packages"
  expect_report "would remove the compiled code of earlier builds: build/DerivedData/Build and TextMouthTests/.build"
  expect_report "would run: make build"
  expect_report "would require no Swift warnings in build/xcodebuild-Release.log"
  expect_report "would require build/TextMouth.app to be no larger than $APP_SIZE_LIMIT_MB MB"
  expect_report "would run: make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "would repeat the performance tests' warnings and skips from build/check/test.log"
  expect_report "would require no Swift warnings in build/check/test.log"
  expect_report "pins match Package.resolved: "
  expect_report "$first_identity $first_version"
  expect_verdict "check: PASSED (dry run)"
  expect_commands
  end_case

  begin_case "a dry run with --without-tests reports three steps and never the suite"
  run_gate -- --dry-run --without-tests
  expect_status 0
  expect_report "step 1 of 3: regenerate the Xcode project from project.yml"
  expect_report "step 3 of 3: build the Release app"
  expect_report "would run: make build"
  expect_report "would require no Swift warnings in build/xcodebuild-Release.log"
  expect_report "would require build/TextMouth.app to be no larger than $APP_SIZE_LIMIT_MB MB"
  expect_report "the hosted XCTest suite is not run by this gate (--without-tests)"
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

  begin_case "a dry run stops at a failed resolution and explains how to update"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=resolve -- --dry-run
  expect_status 1
  expect_report "make update-packages"
  refute_report "step 3 of 4"
  expect_verdict "check: FAILED: step 2 of 4"
  end_case

  begin_case "a dry run stops at a failed project generation"
  run_gate TEXTMOUTH_CHECK_SIMULATE_FAILURE=generate -- --dry-run
  expect_status 1
  refute_report "step 2 of 4"
  expect_verdict "check: FAILED: step 1 of 4 (regenerate the Xcode project from project.yml)"
  end_case

  begin_case "make check runs the gate with CHECK_ARGS"
  cp "$ROOT/Makefile" "$sandbox/Makefile"
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
  expect_report "must be generate, resolve, build, or test, not: deploy"
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
  expect_commands "make generate" \
    "slot make resolve-packages" "make resolve-packages" \
    "slot make build" "make build" \
    "slot make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1" \
    "make test TEST_DERIVED_DATA=build/DerivedData PERFORMANCE_STRICT=1"
  expect_report "Executed 3 tests, with 1 test skipped and 0 failures"
  refute_report "Executed 2 tests"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "build/TextMouth.app is $DEFAULT_APP_TEXT, within the $APP_SIZE_LIMIT_MB MB limit"
  expect_report "no Swift warnings in build/check/test.log"
  expect_report "Package.resolved still holds the committed pins"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a run with --without-tests resolves and builds, checks the size, and never runs the suite"
  run_gate -- --without-tests
  expect_status 0
  expect_commands "make generate" "make resolve-packages" "make build"
  expect_report "step 3 of 3: build the Release app"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "build/TextMouth.app is $DEFAULT_APP_TEXT, within the $APP_SIZE_LIMIT_MB MB limit"
  expect_report "the hosted XCTest suite is not run by this gate (--without-tests)"
  expect_report "Package.resolved still holds the committed pins"
  refute_report "Executed"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app of exactly the size limit passes"
  run_gate STUB_APP_BYTES="$APP_SIZE_LIMIT_BYTES"
  expect_status 0
  expect_report "build/TextMouth.app is $APP_SIZE_LIMIT_MB.0 MB ($APP_SIZE_LIMIT_MB,000,000 bytes), within the $APP_SIZE_LIMIT_MB MB limit"
  expect_verdict "check: PASSED"
  end_case

  begin_case "a Release app one byte over the size limit fails the gate before the tests"
  run_gate STUB_APP_BYTES=$(( APP_SIZE_LIMIT_BYTES + 1 ))
  expect_status 1
  expect_commands "make generate" "make resolve-packages" "make build"
  expect_report "no Swift warnings in build/xcodebuild-Release.log"
  expect_report "the limit is APP_SIZE_LIMIT_MB in Scripts/check.sh; find what grew before raising it"
  refute_report "within the $APP_SIZE_LIMIT_MB MB limit"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app is $APP_SIZE_LIMIT_MB.0 MB ($APP_SIZE_LIMIT_MB,000,001 bytes), more than the $APP_SIZE_LIMIT_MB MB limit"
  end_case

  begin_case "a Release build that packages no app fails the gate, never measuring an earlier build's"
  plant_earlier_builds
  run_gate STUB_APP_BYTES=
  expect_status 1
  expect_commands "make generate" "make resolve-packages" "make build"
  refute_report " MB ("
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/TextMouth.app is missing, so the app's size is unknown"
  end_case

  begin_case "a Swift warning in the Release build fails the gate before the tests, naming the first five"
  run_gate STUB_BUILD_LOG="$FIXTURES/build-warnings.log"
  expect_status 1
  expect_commands "make generate" "make resolve-packages" "make build"
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
  expect_commands "make generate" "make resolve-packages" "make build"
  refute_report "left by an earlier build"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app): build/xcodebuild-Release.log is missing, so the build's Swift warnings are unknown"
  end_case

  begin_case "a run removes earlier builds' compiled code before building and keeps the package checkouts"
  plant_earlier_builds
  run_gate
  expect_status 0
  # The make stub would have recorded finding an earlier build.
  expect_commands "make generate" "make resolve-packages" "make build" \
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
  expect_commands "make generate" "make resolve-packages" "make build"
  expect_report "error: simulated failure of make build"
  expect_report "make: *** [build] Error 65"
  expect_verdict "check: FAILED: step 3 of 4 (build the Release app)"
  end_case

  begin_case "xcodebuild rejecting the pins fails the gate before the build"
  run_gate STUB_FAIL_TARGET=resolve-packages
  expect_status 1
  expect_commands "make generate" "make resolve-packages"
  expect_report "make update-packages"
  expect_verdict "check: FAILED: step 2 of 4"
  end_case

  begin_case "a resolution that rewrites a pin fails the gate before the build"
  run_gate STUB_RESOLVE_WRITES="$FIXTURES/version-drift.resolved"
  expect_status 1
  expect_commands "make generate" "make resolve-packages"
  expect_report "$first_identity: pinned at $first_version"
  expect_report "resolved to 999.0.0"
  expect_verdict "check: FAILED: package resolution does not reproduce the committed Package.resolved"
  end_case

  begin_case "a pin changed during the build fails the final check"
  run_gate STUB_BUILD_WRITES="$FIXTURES/revision-drift.resolved"
  expect_status 1
  expect_commands "make generate" "make resolve-packages" "make build" \
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
  cp "$ROOT/Makefile" "$sandbox/Makefile"
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
  cp "$ROOT/Makefile" "$sandbox/Makefile"
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
  cp "$ROOT/Makefile" "$sandbox/Makefile"
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build 2>&1)
  status=$?
  expect_status 0
  expect_report "SWIFT_OPTIMIZATION_LEVEL=-Osize"
  refute_report "SWIFT_COMPILATION_MODE"
  output=$(cd "$sandbox" && "$REAL_MAKE" -n build CONFIG=Debug 2>&1)
  status=$?
  expect_status 0
  expect_report "-configuration Debug"
  refute_report "SWIFT_OPTIMIZATION_LEVEL"
  end_case

  # The once-per-release run of the golden tests against a Release build must
  # build what ships (Release, -Osize) with testability on and the settings
  # that would hide the app's symbols from the test bundle switched back.
  begin_case "release-goldens.sh builds a testable Release app and names the golden classes"
  output=$("$ROOT/Scripts/test/release-goldens.sh" --dry-run --no-slot 2>&1)
  status=$?
  expect_status 0
  expect_report "-configuration Release"
  expect_report "SWIFT_OPTIMIZATION_LEVEL=-Osize"
  expect_report "ENABLE_TESTABILITY=YES"
  expect_report "LD_EXPORT_SYMBOLS=YES"
  expect_report "DEAD_CODE_STRIPPING=NO"
  expect_report "DEPLOYMENT_POSTPROCESSING=NO"
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
  cp "$ROOT/Makefile" "$sandbox/Makefile"
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
  cp "$ROOT/Makefile" "$sandbox/Makefile"
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
