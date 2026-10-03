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
# never call directly fail loudly.
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

WORK=$(mktemp -d "${TMPDIR:-/tmp}/textmouth-check-selftest.XXXXXX") || exit 1
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly STUBS="$WORK/stubs"                  # stub build tools, first on PATH
readonly SLOT_STUB="$WORK/slot/build-slot.sh" # stub build-slot wrapper
readonly FIXTURES="$WORK/fixtures"            # Package.resolved variants and test logs
readonly CLAUDE_TMP="$WORK/claude-tmp"        # stands in for /tmp/claude-<uid>
readonly SESSION="selftest-session"           # stands in for a Claude Code session id
readonly SESSION_SLOT="$CLAUDE_TMP/-selftest-project/$SESSION/scratchpad/build-slot.sh"

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
#   STUB_TEST_OUTPUT=<file>     test prints <file>
#   STUB_TEST_STATUS=<number>   test exits with <number> (default 0)
echo "make $*" >> "$STUB_LOG"
target=${1:-}
if [ "${STUB_FAIL_TARGET:-}" = "$target" ]; then
  echo "/stub/Sources/Stub.swift:1:1: error: simulated failure of make $target"
  echo "make: *** [$target] Error 65"
  exit 2
fi
case $target in
  resolve-packages)
    if [ -n "${STUB_RESOLVE_WRITES:-}" ]; then cp "$STUB_RESOLVE_WRITES" "$STUB_RESOLVED"; fi ;;
  build)
    if [ -n "${STUB_BUILD_WRITES:-}" ]; then cp "$STUB_BUILD_WRITES" "$STUB_RESOLVED"; fi ;;
  test)
    cat "$STUB_TEST_OUTPUT"
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
      STUB_TEST_OUTPUT="$FIXTURES/tests-pass.log" \
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
  expect_report "would run: make build"
  expect_report "would run: make test"
  expect_report "pins match Package.resolved: "
  expect_report "$first_identity $first_version"
  expect_verdict "check: PASSED (dry run)"
  expect_commands
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
    "slot make test" "make test"
  expect_report "Executed 3 tests, with 1 test skipped and 0 failures"
  refute_report "Executed 2 tests"
  expect_report "Package.resolved still holds the committed pins"
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
  expect_commands "make generate" "make resolve-packages" "make build" "make test"
  expect_report "revision 000000000000"
  expect_verdict "check: FAILED: Package.resolved changed during the build or tests"
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

# main: runs every case and prints the totals; succeeds only when all pass.
main() {
  write_stubs
  write_fixtures
  dry_run_cases
  refusal_cases
  build_slot_cases
  real_run_cases
  printf '%d passed, %d failed\n' "$passed" "$failed"
  (( failed == 0 ))
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# run never reads past this point, even if the file is edited mid-run.
main; exit $?
