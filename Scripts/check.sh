#!/bin/bash
#
# check.sh: TextMouth's reproducibility gate, run by `make check` and by CI.
#
# From a clean checkout the gate
#   1. regenerates TextMouth.xcodeproj from project.yml (make generate);
#   2. resolves Swift packages exactly as the committed Package.resolved pins
#      them (make resolve-packages) and verifies that every pin's package,
#      version, revision, and URL still matches the committed file;
#   3. builds the Release app (make build);
#   4. runs the hosted XCTest suite with the Makefile's flags (make test);
# and finally confirms that no step changed the pins. It fails on any
# generation, resolution, compile, or test error, and when the test run
# reports no executed tests.
#
# Usage: Scripts/check.sh [--dry-run] [--help]
#
#   --dry-run  Print the build commands instead of running them. The pin
#              comparison still reads the real files, so a dry run checks the
#              gate's own logic in about a second. Two variables simulate
#              failures, and are accepted only with --dry-run:
#                TEXTMOUTH_CHECK_SIMULATE_FAILURE=generate|resolve|build|test
#                  makes that step fail as though its command had failed;
#                TEXTMOUTH_CHECK_SIMULATE_RESOLVED=<file>
#                  treats <file> as the Package.resolved that resolution wrote.
#
# Build slots: during Claude Code agent sessions on the development Mac, a
# wrapper script caps how many xcodebuild processes run at once. The resolve,
# build, and test steps run inside that wrapper when there is one:
#   TEXTMOUTH_BUILD_SLOT=<path>  use the wrapper at <path> (must be executable);
#   TEXTMOUTH_BUILD_SLOT=        (set but empty) never use a wrapper;
#   (unset)                      use build-slot.sh from the scratchpad of the
#                                Claude Code session in CLAUDE_CODE_SESSION_ID,
#                                looked up under TEXTMOUTH_CLAUDE_TMP_ROOT
#                                (default /tmp/claude-<uid>), when it exists;
#                                otherwise build directly, as on CI.
#
# Output: one line per step on standard output, plus the most useful log lines
# when a step fails; the last line is always the verdict, PASSED or FAILED.
# Each step's complete output is kept in build/check/<step>.log.
#
# Exit status: 0 when the gate passes, 1 when it fails, 2 for a usage or setup
# error.

set -u
set -o pipefail

# The repository root is this script's parent folder; the gate runs there.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR
readonly SCRIPT="$SCRIPT_DIR/$(basename "$0")"
ROOT=$(dirname "$SCRIPT_DIR")
readonly ROOT

# Paths relative to the repository root.
readonly RESOLVED_FILE="TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
readonly LOG_DIR="build/check"
# The committed pins, copied before any tool can rewrite Package.resolved.
readonly COMMITTED_COPY="$LOG_DIR/committed-Package.resolved"

readonly STEP_COUNT=4
readonly UPDATE_HINT="If a package version changed on purpose, run make update-packages, review the Package.resolved diff, and commit it with project.yml."

# jq definitions shared by the pin helpers. checked_pins rejects anything that
# is not a Package.resolved document (format version 2 or 3) with a pins array.
readonly JQ_PIN_DEFINITIONS='
  def checked_pins:
    if type == "object" and (.pins | type) == "array" then .pins
    else error("not a Package.resolved file with a pins array") end;
  def pin_version: .state.version // ("branch " + (.state.branch // "unknown"));
  def describe_pin:
    "\(pin_version) (revision \((.state.revision // "unknown")[0:12]) from \(.location // "an unknown location"))";
'

dry_run=0            # 1 when --dry-run was given
slot=""              # path of the build-slot wrapper, or empty to build directly
slot_origin=""       # how the wrapper was or was not chosen, for the report
simulate_failure=""  # step a dry run should fail, from TEXTMOUTH_CHECK_SIMULATE_FAILURE
simulate_resolved="" # file a dry run treats as the resolution's Package.resolved
step_number=0        # number of the step in progress, for failure reports
step_title=""        # title of the step in progress
step_started=0       # value of $SECONDS when the step in progress began

# say <text>: prints one line of the gate's report.
say() {
  printf 'check: %s\n' "$*"
}

# detail <text>: prints an indented report line belonging to the current step.
detail() {
  printf 'check:   %s\n' "$*"
}

# detail_lines <prefix> <text>: prints every line of <text> as a detail line
# that starts with <prefix>, and nothing when <text> is empty.
detail_lines() {
  local prefix=$1 line
  [[ -n $2 ]] || return 0
  while IFS= read -r line; do
    detail "$prefix$line"
  done <<<"$2"
}

# usage: prints the comment block at the top of this file, which doubles as
# the --help text, without its leading "# " markers.
usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT"
}

# setup_error <message>: reports a usage or setup problem and exits with 2.
setup_error() {
  printf 'check: error: %s\n' "$*" >&2
  exit 2
}

# fail <reason>: prints the FAILED verdict as the report's last line and exits
# with 1.
fail() {
  say "FAILED: $*"
  exit 1
}

# absolute_path <path>: prints <path> made absolute against the caller's
# working directory, so it stays valid after the gate moves to the root.
absolute_path() {
  case $1 in
    /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$PWD" "$1" ;;
  esac
}

# count_of <number> <unit>: prints "<number> <unit>", adding a plural "s"
# unless the number is 1.
count_of() {
  if (( $1 == 1 )); then
    printf '%d %s' "$1" "$2"
  else
    printf '%d %ss' "$1" "$2"
  fi
}

# format_duration <seconds>: renders an elapsed time in words, such as
# "4 minutes 2 seconds", so it reads clearly in speech and braille.
format_duration() {
  local seconds=$1
  if (( seconds >= 60 )); then
    printf '%s %s' "$(count_of $(( seconds / 60 )) minute)" "$(count_of $(( seconds % 60 )) second)"
  else
    count_of "$seconds" second
  fi
}

# parse_arguments <arguments...>: reads the command line.
parse_arguments() {
  local argument
  for argument in "$@"; do
    case $argument in
      --dry-run) dry_run=1 ;;
      -h|--help) usage; exit 0 ;;
      *) setup_error "unknown argument: $argument (see $0 --help)" ;;
    esac
  done
}

# read_simulation_settings: accepts the TEXTMOUTH_CHECK_SIMULATE_* variables
# only in a dry run, so a real gate run can never be told to fake a result.
read_simulation_settings() {
  simulate_failure=${TEXTMOUTH_CHECK_SIMULATE_FAILURE:-}
  simulate_resolved=${TEXTMOUTH_CHECK_SIMULATE_RESOLVED:-}
  if [[ -z $simulate_failure && -z $simulate_resolved ]]; then
    return 0
  fi
  if (( ! dry_run )); then
    setup_error "TEXTMOUTH_CHECK_SIMULATE_FAILURE and TEXTMOUTH_CHECK_SIMULATE_RESOLVED are accepted only with --dry-run"
  fi
  case $simulate_failure in
    ""|generate|resolve|build|test) ;;
    *) setup_error "TEXTMOUTH_CHECK_SIMULATE_FAILURE must be generate, resolve, build, or test, not: $simulate_failure" ;;
  esac
  if [[ -n $simulate_resolved ]]; then
    [[ -f $simulate_resolved ]] ||
      setup_error "TEXTMOUTH_CHECK_SIMULATE_RESOLVED names no file: $simulate_resolved"
    simulate_resolved=$(absolute_path "$simulate_resolved")
  fi
}

# locate_build_slot: chooses the build-slot wrapper as the header describes,
# setting slot and slot_origin.
locate_build_slot() {
  # An explicit setting wins: a path names the wrapper, an empty value
  # turns wrappers off.
  if [[ -n ${TEXTMOUTH_BUILD_SLOT+set} ]]; then
    if [[ -z $TEXTMOUTH_BUILD_SLOT ]]; then
      slot_origin="none (TEXTMOUTH_BUILD_SLOT is empty)"
    elif [[ -f $TEXTMOUTH_BUILD_SLOT && -x $TEXTMOUTH_BUILD_SLOT ]]; then
      slot=$(absolute_path "$TEXTMOUTH_BUILD_SLOT")
      slot_origin="$slot (from TEXTMOUTH_BUILD_SLOT)"
    else
      setup_error "TEXTMOUTH_BUILD_SLOT is not an executable file: $TEXTMOUTH_BUILD_SLOT"
    fi
    return 0
  fi

  # Otherwise look in this Claude Code session's scratchpad, which lives at
  # <tmp root>/<project folder>/<session id>/scratchpad. The wildcard stands
  # for the project folder; the session id, a UUID, keeps another session's
  # wrapper from ever matching.
  local session=${CLAUDE_CODE_SESSION_ID:-} candidate
  if [[ -n $session ]]; then
    for candidate in "${TEXTMOUTH_CLAUDE_TMP_ROOT:-/tmp/claude-$(id -u)}"/*/"$session"/scratchpad/build-slot.sh; do
      if [[ -f $candidate && -x $candidate ]]; then
        slot=$candidate
        slot_origin="$slot (this Claude Code session's scratchpad)"
        return 0
      fi
    done
  fi
  slot_origin="none, so builds run directly"
}

# require_tools: confirms the tools the gate depends on are installed, with an
# installation hint for each missing one. A dry run needs only jq.
require_tools() {
  command -v jq >/dev/null 2>&1 ||
    setup_error "jq is required to read Package.resolved (macOS 15 and later include /usr/bin/jq)"
  if (( dry_run )); then
    return 0
  fi
  command -v make >/dev/null 2>&1 ||
    setup_error "make is required (xcode-select --install)"
  command -v xcodegen >/dev/null 2>&1 ||
    setup_error "XcodeGen is required to regenerate the project (brew install xcodegen)"
}

# pin_summary <file>: prints every pin in a Package.resolved file as
# "identity version", sorted and comma separated, or fails when the file is
# not a readable Package.resolved.
pin_summary() {
  jq -r "$JQ_PIN_DEFINITIONS"'
    checked_pins | map("\(.identity) \(pin_version)") | sort | join(", ")' "$1"
}

# pin_differences <committed file> <resolved file>: prints one line for every
# package whose pin (kind, URL, version or branch, revision) differs between
# the two files, nothing when they match, and fails when either is unreadable.
pin_differences() {
  jq -n -r --slurpfile committed "$1" --slurpfile resolved "$2" "$JQ_PIN_DEFINITIONS"'
    def by_identity: checked_pins | map({key: .identity, value: .}) | from_entries;
    ($committed[0] | by_identity) as $c
    | ($resolved[0] | by_identity) as $r
    | ($c + $r | keys)[] as $id
    | if $r[$id] == null then
        "\($id): pinned at \($c[$id] | describe_pin) but missing from the resolution"
      elif $c[$id] == null then
        "\($id): resolved to \($r[$id] | describe_pin) but not pinned in Package.resolved"
      elif ($c[$id] | {kind, location, state}) != ($r[$id] | {kind, location, state}) then
        "\($id): pinned at \($c[$id] | describe_pin), resolved to \($r[$id] | describe_pin)"
      else
        empty
      end'
}

# verify_pins <file> <reason>: compares the pins in <file> with the committed
# copy, and fails the gate with <reason> and every difference listed when
# they disagree or <file> cannot be read.
verify_pins() {
  local file=$1 reason=$2 differences
  if ! differences=$(pin_differences "$COMMITTED_COPY" "$file" 2>&1); then
    detail "cannot read the pins in $file:"
    detail_lines "| " "$differences"
    fail "$reason"
  fi
  if [[ -n $differences ]]; then
    detail "these pins differ from the committed Package.resolved:"
    detail_lines "- " "$differences"
    detail "$UPDATE_HINT"
    fail "$reason"
  fi
}

# begin_step <number> <title>: announces the next step of the gate.
begin_step() {
  step_number=$1
  step_title=$2
  step_started=$SECONDS
  say "step $step_number of $STEP_COUNT: $step_title"
}

# run_step <log name> <yes|no: use the build slot> <command...>: runs the
# current step's command with all of its output in build/check/<log name>.log,
# inside the build slot when asked and a wrapper exists, and returns the
# command's exit status. A dry run prints the command instead, and fails only
# when TEXTMOUTH_CHECK_SIMULATE_FAILURE names this step.
run_step() {
  local name=$1 use_slot=$2
  shift 2
  local log="$LOG_DIR/$name.log" where=""
  if [[ $use_slot == yes && -n $slot ]]; then
    where=" in a build slot"
  fi

  if (( dry_run )); then
    detail "would run$where: $*"
    if [[ $simulate_failure == "$name" ]]; then
      echo "error: simulated failure of the $name step (TEXTMOUTH_CHECK_SIMULATE_FAILURE=$name)" > "$log"
      return 1
    fi
    return 0
  fi

  detail "running$where: $*"
  if [[ -n $where ]]; then
    set -- "$slot" "$@"
  fi
  "$@" > "$log" 2>&1
  local status=$?
  if (( status == 0 )); then
    detail "passed in $(format_duration $(( SECONDS - step_started )))"
  fi
  return "$status"
}

# show_failure_lines <log>: prints the lines of a failed step's log a reader
# needs first: errors with two lines of context (where compiler diagnostics
# show the source line and caret), xcodebuild's verdict, and make's failure
# line. Repeats are dropped, at most 30 lines are shown, and the log's last 15
# lines stand in when nothing matches.
show_failure_lines() {
  local log=$1 lines
  lines=$(grep -E -A 2 'error:|\*\* [A-Z ]+ FAILED \*\*|make(\[[0-9]+\])?: \*\*\*|command not found' "$log" 2>/dev/null |
    grep -v -x -e '--' |
    grep -v -E "^Test Case '.*' (started|passed)" |
    awk '!seen[$0]++' |
    head -n 30)
  if [[ -z $lines ]]; then
    lines=$(tail -n 15 "$log" 2>/dev/null)
  fi
  detail_lines "| " "$lines"
}

# step_failed <log name> <exit status> [hint]: reports why the current step
# failed, using the most useful lines of its log, then fails the gate.
step_failed() {
  local log="$LOG_DIR/$1.log" status=$2 hint=${3:-} summary
  detail "failed with exit status $status after $(format_duration $(( SECONDS - step_started )))"
  summary=$(test_summary "$log")
  if [[ -n $summary ]]; then
    detail "$summary"
  fi
  show_failure_lines "$log"
  detail "full log: $log"
  if [[ -n $hint ]]; then
    detail "$hint"
  fi
  fail "step $step_number of $STEP_COUNT ($step_title)"
}

# test_summary <log>: prints XCTest's last "Executed N tests" line, which is
# the total for every test, or nothing when the log has none.
test_summary() {
  grep -E '^[[:space:]]*Executed [0-9]+ tests?, with ' "$1" 2>/dev/null |
    tail -n 1 |
    sed -E 's/^[[:space:]]+//'
}

# report_tests: prints the hosted suite's totals after the test step passed,
# and fails the gate when the log has no totals or they count no executed
# tests, so a scheme that silently lost its test target cannot pass.
report_tests() {
  local log="$LOG_DIR/test.log" summary count_pattern='^Executed ([0-9]+) tests?, with '
  if (( dry_run )); then
    detail "would require XCTest totals with at least one executed test in $log"
    return 0
  fi
  summary=$(test_summary "$log")
  if [[ -z $summary ]]; then
    detail "full log: $log"
    fail "the hosted test run printed no XCTest totals, so no test is known to have run"
  fi
  detail "$summary"
  if [[ $summary =~ $count_pattern ]] && (( ${BASH_REMATCH[1]} > 0 )); then
    return 0
  fi
  detail "full log: $log"
  fail "the hosted test run executed no tests"
}

# main <arguments...>: runs the gate.
main() {
  parse_arguments "$@"
  read_simulation_settings
  locate_build_slot
  require_tools
  cd "$ROOT" || setup_error "cannot enter the repository root: $ROOT"
  mkdir -p "$LOG_DIR" || setup_error "cannot create $LOG_DIR"
  rm -f "$LOG_DIR"/*.log "$COMMITTED_COPY"

  if (( dry_run )); then
    say "TextMouth reproducibility gate (dry run: build commands are printed, not run)"
  else
    say "TextMouth reproducibility gate"
  fi
  say "build slot: $slot_origin"
  say "step logs: $LOG_DIR"

  # Copy the committed pins before any tool can rewrite Package.resolved.
  # xcodebuild's lock flag accepts a missing file, so a missing one fails here.
  if [[ ! -f $RESOLVED_FILE ]]; then
    fail "$RESOLVED_FILE is missing; restore it with: git checkout -- $RESOLVED_FILE"
  fi
  cp "$RESOLVED_FILE" "$COMMITTED_COPY" || setup_error "cannot copy $RESOLVED_FILE"
  local committed_pins
  if ! committed_pins=$(pin_summary "$COMMITTED_COPY" 2>&1); then
    detail_lines "| " "$committed_pins"
    fail "cannot read the pins in $RESOLVED_FILE"
  fi

  begin_step 1 "regenerate the Xcode project from project.yml"
  run_step generate no make generate || step_failed generate $?

  begin_step 2 "resolve Swift packages exactly as Package.resolved pins them"
  run_step resolve yes make resolve-packages || step_failed resolve $? "$UPDATE_HINT"
  local resolution=$RESOLVED_FILE
  if [[ -n $simulate_resolved ]]; then
    resolution=$simulate_resolved
  fi
  verify_pins "$resolution" "package resolution does not reproduce the committed Package.resolved"
  detail "pins match Package.resolved: $committed_pins"
  if ! cmp -s "$COMMITTED_COPY" "$resolution"; then
    detail "note: xcodebuild rewrote Package.resolved without changing a pin; see git diff"
  fi

  begin_step 3 "build the Release app"
  run_step build yes make build || step_failed build $?

  begin_step 4 "run the hosted XCTest suite"
  run_step test yes make test || step_failed test $?
  report_tests

  # No later step may re-resolve packages behind the gate's back.
  verify_pins "$RESOLVED_FILE" "Package.resolved changed during the build or tests"
  detail "Package.resolved still holds the committed pins"

  if (( dry_run )); then
    say "PASSED (dry run)"
  else
    say "PASSED"
  fi
}

main "$@"
