#!/bin/bash
#
# perf-baselines.sh: records new performance baselines, run by
# `make perf-baselines` after a deliberate change to what
# PerformanceBaselineTests measure.
#
# It runs PerformanceBaselineTests alone, in the Debug build the hosted suite
# uses, with TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD=1. Each test first waits
# until the Mac is quiet (its one-minute load average at most its number of
# cores, for up to five minutes), then measures; once every measurement has
# its number, the run rewrites TextMouthProductionTests/performance-baselines.json
# with this Mac's model and today's date. The script then prints each
# measurement's old and new number.
#
# Nothing changes unless the whole run succeeds: when any test skips, as on a
# Mac that never quiets down, or fails, the baselines file is left as it was,
# and the script says why. Record on an otherwise idle Mac, and review and
# commit the file's diff with the change it records.
#
# Usage: Scripts/perf-baselines.sh [--help]
#
#   TEXTMOUTH_TEST_DERIVED_DATA=<folder>  build in <folder>, counted from the
#                                         repository root unless absolute, as
#                                         make perf-baselines TEST_DERIVED_DATA=
#                                         <folder> sets it; Xcode's default
#                                         DerivedData folder otherwise.
#
# Build slots: run it inside the build-slot wrapper during Claude Code agent
# sessions, as any xcodebuild command, for example
#   BBS_AGENT=<name> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh make perf-baselines
#
# Output: one line per old and new number, then the verdict, PASSED or
# FAILED, as the last line. xcodebuild's complete output is kept in
# build/perf-baselines.log.
#
# Exit status: 0 when the baselines were rewritten, 1 when they were not, 2
# for a usage or setup error.

set -u
set -o pipefail

# The repository root is this script's parent folder; the script runs there.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR
SCRIPT="$SCRIPT_DIR/$(basename "$0")"
readonly SCRIPT
ROOT=$(dirname "$SCRIPT_DIR")
readonly ROOT

# Paths relative to the repository root.
readonly BASELINES="TextMouthProductionTests/performance-baselines.json"
readonly LOG="build/perf-baselines.log"
# A copy of the baselines file as it was before the run, put back when the
# run does not succeed as a whole.
readonly PREVIOUS="build/perf-baselines.previous.json"
# The test class that measures, and the variable that has it record.
readonly TEST_CLASS="TextMouthProductionTests/PerformanceBaselineTests"
readonly RECORD_VARIABLE="TEST_RUNNER_TEXTMOUTH_PERFORMANCE_RECORD"

# say <text>: prints one line of the script's report.
say() {
  printf 'perf-baselines: %s\n' "$*"
}

# usage: prints the comment block at the top of this file, which doubles as
# the --help text, without its leading "# " markers.
usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT"
}

# setup_error <message>: reports a usage or setup problem and exits with 2.
setup_error() {
  printf 'perf-baselines: error: %s\n' "$*" >&2
  exit 2
}

# fail <reason>: puts the baselines file back as it was before the run, or
# removes one the run wrote where there was none, so a run that did not
# succeed as a whole changes nothing; then prints the FAILED verdict as the
# report's last line and exits with 1.
fail() {
  if [[ -f $PREVIOUS ]]; then
    cp "$PREVIOUS" "$BASELINES"
    rm -f "$PREVIOUS"
  else
    rm -f "$BASELINES"
  fi
  say "FAILED: $*"
  exit 1
}

# parse_arguments <arguments...>: reads the command line.
parse_arguments() {
  local argument
  for argument in "$@"; do
    case $argument in
      -h|--help) usage; exit 0 ;;
      *) setup_error "unknown argument: $argument (see $0 --help)" ;;
    esac
  done
}

# main <arguments...>: records the baselines.
main() {
  parse_arguments "$@"
  command -v xcodebuild >/dev/null 2>&1 || setup_error "xcodebuild is required (install Xcode)"
  cd "$ROOT" || setup_error "cannot enter the repository root: $ROOT"
  mkdir -p build || setup_error "cannot create build"
  rm -f "$PREVIOUS"
  if [[ -f $BASELINES ]]; then
    cp "$BASELINES" "$PREVIOUS" || setup_error "cannot copy $BASELINES"
  fi

  # Where xcodebuild builds, as `make test` chooses it.
  local -a derived_data=()
  local folder=${TEXTMOUTH_TEST_DERIVED_DATA:-}
  if [[ -n $folder ]]; then
    [[ $folder == /* ]] || folder="$ROOT/$folder"
    derived_data=(-derivedDataPath "$folder")
  fi

  say "measuring $TEST_CLASS; each test waits for a quiet Mac first"
  say "xcodebuild's output: $LOG"
  # A run stopped part of the way changes nothing either.
  trap 'fail "the run was interrupted"' INT TERM
  env "$RECORD_VARIABLE=1" xcodebuild test \
    -project TextMouth.xcodeproj \
    -scheme TextMouth \
    -destination 'platform=macOS' \
    -parallel-testing-enabled NO \
    CODE_SIGNING_ALLOWED=NO \
    "-only-testing:$TEST_CLASS" \
    ${derived_data[@]+"${derived_data[@]}"} > "$LOG" 2>&1
  local status=$?

  # Each old and new number, as the tests printed them.
  local line
  while IFS= read -r line; do
    say "${line#PERFORMANCE }"
  done < <(grep -E '^PERFORMANCE (RECORDED|BASELINES WRITTEN):' "$LOG")

  if (( status == 0 )) && grep -q '^PERFORMANCE BASELINES WRITTEN:' "$LOG"; then
    rm -f "$PREVIOUS"
    say "PASSED: review the diff of $BASELINES, then commit it with the change it records"
    return 0
  fi

  # Why not: each reason a test skipped, the errors, and xcodebuild's verdict.
  while IFS= read -r line; do
    say "  $line"
  done < <(grep -E '^PERFORMANCE SKIPPED:|error:|\*\* TEST [A-Z]+ \*\*' "$LOG" | awk '!seen[$0]++' | head -n 20)
  if (( status == 0 )); then
    fail "a measurement was not made, so $BASELINES is unchanged; see $LOG"
  fi
  fail "xcodebuild exited with status $status, so $BASELINES is unchanged; see $LOG"
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# run never reads past this point, even if the file is edited mid-run.
main "$@"; exit $?
