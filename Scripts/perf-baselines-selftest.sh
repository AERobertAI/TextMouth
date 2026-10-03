#!/bin/bash
#
# perf-baselines-selftest.sh: tests Scripts/perf-baselines.sh in a second,
# without building or measuring.
#
# Every case copies perf-baselines.sh into a fresh sandbox folder that stands
# for the repository, with a baselines file or none, puts a stub xcodebuild
# first on PATH, runs the script there, and checks its exit status, its
# report, the baselines file it leaves, and how it called xcodebuild. The
# stub imitates a recording run: it prints a test log and may write the
# baselines file, as the tests do, steered by STUB_* variables.
#
# Usage: Scripts/perf-baselines-selftest.sh   (make check-selftest runs it)
#
# Output: one "ok" or "not ok" line per case, with the reasons and the
# script's report under each failure, then the totals.
#
# Exit status: 0 when every case passes, 1 otherwise.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || exit 1
readonly ROOT
readonly BASELINES="TextMouthProductionTests/performance-baselines.json"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/textmouth-perf-baselines-selftest.XXXXXX") || exit 1
# Its physical path, as the script names the folders under its own root:
# the temporary folder is reached through the /var link to /private/var.
WORK=$(cd "$WORK" && pwd -P) || exit 1
readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly STUBS="$WORK/stubs"       # the stub xcodebuild, first on PATH
readonly FIXTURES="$WORK/fixtures" # test logs and baselines files

passed=0
failed=0
case_name=""     # description of the case in progress
case_problems="" # reasons the case in progress fails, one per line
sandbox=""       # the case's stand-in for the repository
stub_log=""      # where the stub records how it was called
output=""        # the script's report: standard output and error together
status=0         # the script's exit status

# write_stub: creates the stub xcodebuild. It records its arguments and the
# recording variable it was given, prints STUB_OUTPUT, copies STUB_WRITES
# over the baselines file when set, as a recording run's last test does, and
# exits with STUB_STATUS (default 0).
write_stub() {
  mkdir -p "$STUBS"
  cat > "$STUBS/xcodebuild" <<'STUB'
#!/bin/bash
# Stub xcodebuild for perf-baselines-selftest.sh.
printf '%s\n' "$@" > "$STUB_LOG"
echo "RECORD=${TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD-(unset)}" >> "$STUB_LOG"
if [ -n "${STUB_OUTPUT:-}" ]; then cat "$STUB_OUTPUT"; fi
if [ -n "${STUB_WRITES:-}" ]; then cp "$STUB_WRITES" TextMouthProductionTests/performance-baselines.json; fi
exit "${STUB_STATUS:-0}"
STUB
  chmod +x "$STUBS/xcodebuild"
}

# write_fixtures: the baselines files and test logs the cases use.
write_fixtures() {
  mkdir -p "$FIXTURES"
  printf '{ "about" : "the baselines before the run", "launch" : 120 }\n' > "$FIXTURES/old.json"
  printf '{ "about" : "the baselines the run recorded", "launch" : 130 }\n' > "$FIXTURES/new.json"

  # A run whose every test measured and the last one wrote the file.
  {
    printf "Test Case '-[PerformanceBaselineTests testLaunch]' started.\n"
    printf 'PERFORMANCE: launch: median 130.000 milliseconds of 130.000 (load 1.00 on 8 cores)\n'
    printf 'PERFORMANCE MEASURED: launch: 130.000 milliseconds\n'
    printf 'PERFORMANCE RECORDED: launch: from 120.000 milliseconds to 130.000 milliseconds, 1.08 times the old baseline\n'
    printf 'PERFORMANCE BASELINES WRITTEN: /repo/%s for a Mac15,12 (Apple M3, 8 cores, 8 GB), Debug build, 2026-10-03\n' "$BASELINES"
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/recorded.log"

  # A run in which a test skipped, so nothing was written.
  {
    printf 'PERFORMANCE: waiting to record until the Mac quiets down: the Mac is busy\n'
    printf 'PERFORMANCE SKIPPED: the Mac is busy after waiting 300 seconds; nothing was recorded\n'
    printf 'PERFORMANCE SKIPPED: an earlier test gave up waiting for a quiet Mac, so nothing will be recorded\n'
    printf 'PERFORMANCE SKIPPED: an earlier test gave up waiting for a quiet Mac, so nothing will be recorded\n'
    printf '** TEST SUCCEEDED **\n'
  } > "$FIXTURES/skipped.log"

  # A run that wrote the file, then failed a test.
  {
    printf 'PERFORMANCE BASELINES WRITTEN: /repo/%s for a Mac15,12 (Apple M3, 8 cores, 8 GB), Debug build, 2026-10-03\n' "$BASELINES"
    printf '/repo/TextMouthProductionTests/PerformanceBaselineTests.swift:90: error: -[PerformanceBaselineTests testLaunch] : XCTAssertTrue failed\n'
    printf '** TEST FAILED **\n'
  } > "$FIXTURES/failed.log"
}

# begin_case <description> [baselines file]: starts a case in a fresh sandbox
# holding a copy of perf-baselines.sh and, when given, that baselines file.
begin_case() {
  case_name=$1
  case_problems=""
  sandbox="$WORK/case-$(( passed + failed + 1 ))"
  mkdir -p "$sandbox/Scripts" "$sandbox/TextMouthProductionTests"
  cp "$ROOT/Scripts/perf-baselines.sh" "$sandbox/Scripts/perf-baselines.sh"
  if [[ -n ${2:-} ]]; then
    cp "$2" "$sandbox/$BASELINES"
  fi
  stub_log="$sandbox/xcodebuild-call.log"
}

# run_script [NAME=value...] [-- arguments...]: runs the sandbox's script with
# the stub first on PATH, no derived data folder or recording variable from
# the caller, and the given variables. Stores the report in $output and the
# exit status in $status.
run_script() {
  local -a settings=()
  while [[ $# -gt 0 && $1 != -- ]]; do
    settings+=("$1")
    shift
  done
  if [[ $# -gt 0 ]]; then
    shift
  fi
  output=$(cd "$sandbox" && env \
      -u TEXTMOUTH_TEST_DERIVED_DATA -u TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD \
      PATH="$STUBS:$PATH" STUB_LOG="$stub_log" \
      ${settings[@]+"${settings[@]}"} ./Scripts/perf-baselines.sh "$@" 2>&1)
  status=$?
}

# problem <reason>: records why the case in progress fails.
problem() {
  case_problems+="    $1"$'\n'
}

# expect_status <number>: the script must exit with <number>.
expect_status() {
  [[ $status -eq $1 ]] || problem "exit status was $status, expected $1"
}

# expect_report <text>: the script's report must contain <text>.
expect_report() {
  grep -F -q -- "$1" <<<"$output" || problem "the report lacks: $1"
}

# expect_verdict <text>: the report's last line must start with <text>.
expect_verdict() {
  local last
  last=$(tail -n 1 <<<"$output")
  [[ $last == "$1"* ]] || problem "the last line was '$last', expected it to start with '$1'"
}

# expect_baselines <file>: the sandbox's baselines file must equal <file>.
expect_baselines() {
  cmp -s "$1" "$sandbox/$BASELINES" || problem "the baselines file is not $(basename "$1")"
}

# expect_no_baselines: the sandbox must hold no baselines file.
expect_no_baselines() {
  [[ ! -e $sandbox/$BASELINES ]] || problem "a baselines file was left behind"
}

# expect_call <line>: the stub must have been handed <line>, an argument or
# the recording variable, as a line of its own.
expect_call() {
  grep -F -x -q -- "$1" "$stub_log" 2>/dev/null || problem "xcodebuild was not handed: $1"
}

# end_case: prints the case's verdict, and under a failure its reasons and
# the script's report.
end_case() {
  local number=$(( passed + failed + 1 )) line
  if [[ -z $case_problems ]]; then
    passed=$(( passed + 1 ))
    printf 'ok %d - %s\n' "$number" "$case_name"
  else
    failed=$(( failed + 1 ))
    printf 'not ok %d - %s\n%s' "$number" "$case_name" "$case_problems"
    printf '    report of the script:\n'
    while IFS= read -r line; do
      printf '      %s\n' "$line"
    done <<<"$output"
  fi
}

# cases: every outcome of a recording run.
cases() {
  begin_case "a complete run rewrites the baselines and prints each old and new number" "$FIXTURES/old.json"
  run_script STUB_OUTPUT="$FIXTURES/recorded.log" STUB_WRITES="$FIXTURES/new.json"
  expect_status 0
  expect_report "perf-baselines: RECORDED: launch: from 120.000 milliseconds to 130.000 milliseconds"
  expect_report "perf-baselines: BASELINES WRITTEN: /repo/$BASELINES"
  expect_verdict "perf-baselines: PASSED"
  expect_baselines "$FIXTURES/new.json"
  expect_call "test"
  expect_call "-only-testing:TextMouthProductionTests/PerformanceBaselineTests"
  expect_call "-parallel-testing-enabled"
  expect_call "RECORD=1"
  [[ ! -e $sandbox/build/perf-baselines.previous.json ]] || problem "the copy of the old baselines was left in build/"
  grep -F -q "PERFORMANCE BASELINES WRITTEN" "$sandbox/build/perf-baselines.log" 2>/dev/null ||
    problem "xcodebuild's output was not kept in build/perf-baselines.log"
  end_case

  begin_case "a run in which a test skipped changes nothing and says why, once each" "$FIXTURES/old.json"
  run_script STUB_OUTPUT="$FIXTURES/skipped.log"
  expect_status 1
  expect_report "perf-baselines:   PERFORMANCE SKIPPED: the Mac is busy after waiting 300 seconds"
  if [[ $(grep -c -F 'an earlier test gave up' <<<"$output") -ne 1 ]]; then
    problem "a repeated reason was not printed exactly once"
  fi
  expect_verdict "perf-baselines: FAILED: a measurement was not made"
  expect_baselines "$FIXTURES/old.json"
  end_case

  begin_case "a run that wrote the baselines and then failed puts the old ones back" "$FIXTURES/old.json"
  run_script STUB_OUTPUT="$FIXTURES/failed.log" STUB_WRITES="$FIXTURES/new.json" STUB_STATUS=65
  expect_status 1
  expect_report "XCTAssertTrue failed"
  expect_report "** TEST FAILED **"
  expect_verdict "perf-baselines: FAILED: xcodebuild exited with status 65"
  expect_baselines "$FIXTURES/old.json"
  end_case

  begin_case "a first recording records a baselines file where there was none"
  run_script STUB_OUTPUT="$FIXTURES/recorded.log" STUB_WRITES="$FIXTURES/new.json"
  expect_status 0
  expect_verdict "perf-baselines: PASSED"
  expect_baselines "$FIXTURES/new.json"
  end_case

  begin_case "a failed first recording leaves no baselines file behind"
  run_script STUB_OUTPUT="$FIXTURES/failed.log" STUB_WRITES="$FIXTURES/new.json" STUB_STATUS=65
  expect_status 1
  expect_verdict "perf-baselines: FAILED"
  expect_no_baselines
  end_case

  begin_case "a derived data folder is handed to xcodebuild, counted from the repository root" "$FIXTURES/old.json"
  run_script TEXTMOUTH_TEST_DERIVED_DATA=build/DerivedData STUB_OUTPUT="$FIXTURES/recorded.log"
  expect_call "-derivedDataPath"
  expect_call "$sandbox/build/DerivedData"
  end_case

  begin_case "an absolute derived data folder is handed to xcodebuild as it is" "$FIXTURES/old.json"
  run_script TEXTMOUTH_TEST_DERIVED_DATA="$WORK/elsewhere" STUB_OUTPUT="$FIXTURES/recorded.log"
  expect_call "$WORK/elsewhere"
  end_case

  begin_case "without a derived data folder, xcodebuild uses its own" "$FIXTURES/old.json"
  run_script STUB_OUTPUT="$FIXTURES/recorded.log"
  if grep -F -x -q -- "-derivedDataPath" "$stub_log" 2>/dev/null; then
    problem "xcodebuild was handed a derived data folder"
  fi
  end_case

  begin_case "--help prints the usage and runs nothing" "$FIXTURES/old.json"
  run_script -- --help
  expect_status 0
  expect_report "Usage: Scripts/perf-baselines.sh [--help]"
  [[ ! -e $stub_log ]] || problem "xcodebuild ran"
  end_case

  begin_case "an unknown argument is refused and runs nothing" "$FIXTURES/old.json"
  run_script -- --frobnicate
  expect_status 2
  expect_report "unknown argument: --frobnicate"
  [[ ! -e $stub_log ]] || problem "xcodebuild ran"
  expect_baselines "$FIXTURES/old.json"
  end_case
}

# main: runs every case and prints the totals; succeeds only when all pass.
main() {
  write_stub
  write_fixtures
  cases
  printf '%d passed, %d failed\n' "$passed" "$failed"
  (( failed == 0 ))
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# run never reads past this point, even if the file is edited mid-run.
main; exit $?
