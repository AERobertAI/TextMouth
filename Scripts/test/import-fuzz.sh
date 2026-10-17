#!/bin/bash
#
# import-fuzz.sh: the import fuzz sweep. It damages a copy of each TestData
# document in a dozen seeded ways (truncated, emptied, bytes flipped, a
# window zeroed or removed, ZIP ends corrupted, NULs and invalid UTF-8 put
# into text, a megabyte line, 5,000 nested divs) and imports every copy as
# the library does, checking that each import finishes, refuses cleanly or
# gives a book that loads, leaves nothing behind when it refuses, and leaves
# the damaged file alone (TextMouthProductionTests/ImportFuzzTests.swift).
#
# It runs ImportFuzzTests through Scripts/test/run-area.py with
# TEXTMOUTH_IMPORT_FUZZ=1, then prints the report's path, the report's
# closing counts line, and the run's verdict.
#
# A crash of the test host is a FINDING, not a script failure: the sweep
# exists to find one. The user will see a crash dialog if one happens. When
# the report has no closing "done:" line the host died, and the script
# prints the case that was running (the log's last "FUZZ CASE" line) and the
# command that reproduces it. Everything the sweep records is flushed case by
# case, so the report holds every case before the crash.
#
# Usage: Scripts/test/import-fuzz.sh [options] [report.md]
#
#   --seed N         the seed; the same seed damages the same bytes on any
#                    Mac (default 20261016)
#   --docs A,B       comma-separated TestData file names (default: every
#                    recorded book under 300 KB)
#   --pdf            also sweep the two small PDFs (their import can use
#                    Vision OCR, which is slow)
#   --seconds N      the watchdog for one import (default 60)
#   --derived-data D the build folder for run-area.py
#   --log FILE       where xcodebuild's output goes
#   report.md        where the report goes (default in the temporary folder)
#   -h, --help       this text
#
# Build slots: run it inside the build-slot wrapper during Claude Code agent
# sessions (run-area.py does this itself; set BBS_AGENT=<name> to report to
# the board).
#
# Exit status: 0 when the sweep passed, 1 when it found a violation (listed
# in the run's output and the report), 3 when the test host crashed or the
# sweep did not finish, 2 for a usage or setup error.

set -u
set -o pipefail

# This script's own folder, where run-area.py lives, and the repository root
# above Scripts/test.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR
SCRIPT="$SCRIPT_DIR/$(basename "$0")"
readonly SCRIPT
ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P) || exit 2
readonly ROOT

# say <text>: prints one line of the script's output.
say() {
  printf 'import-fuzz: %s\n' "$*"
}

# usage: prints the comment block at the top of this file, which doubles as
# the --help text, without its leading "# " markers.
usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT"
}

# setup_error <message>: reports a usage or setup problem and exits with 2.
setup_error() {
  printf 'import-fuzz: error: %s\n' "$*" >&2
  exit 2
}

# Options, with their defaults; the test applies the defaults of the ones
# left empty.
SEED=""
DOCS=""
PDF=0
SECONDS_PER_IMPORT=""
DERIVED_DATA=""
LOG=""
REPORT=""

# parse_arguments <arguments...>: reads the command line into the variables
# above.
parse_arguments() {
  while (($# > 0)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --seed|--docs|--seconds|--derived-data|--log)
        (($# >= 2)) || setup_error "$1 needs a value"
        case $1 in
          --seed) SEED=$2 ;;
          --docs) DOCS=$2 ;;
          --seconds) SECONDS_PER_IMPORT=$2 ;;
          --derived-data) DERIVED_DATA=$2 ;;
          --log) LOG=$2 ;;
        esac
        shift 2
        ;;
      --pdf) PDF=1; shift ;;
      -*) setup_error "unknown option: $1 (see $0 --help)" ;;
      *)
        [[ -z $REPORT ]] || setup_error "more than one report path: $REPORT and $1"
        REPORT=$1
        shift
        ;;
    esac
  done
  [[ -z $SEED || $SEED =~ ^[0-9]+$ ]] || setup_error "--seed must be a whole number, not $SEED"
  [[ -z $SECONDS_PER_IMPORT || $SECONDS_PER_IMPORT =~ ^[0-9]+$ ]] \
    || setup_error "--seconds must be a whole number, not $SECONDS_PER_IMPORT"
}

# absolute <path>: prints <path> made absolute against the current folder.
absolute() {
  case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# crash_report <report> <log> <seed>: the sweep did not finish. Prints the
# case that was running, from the log's last "FUZZ CASE" line (the report
# holds only the cases that finished), and the command that reproduces it.
crash_report() {
  local report=$1 log=$2 seed=$3 last_case="" document=""
  [[ -f $log ]] && last_case=$(grep -o 'FUZZ CASE .*' "$log" | tail -1 | sed 's/^FUZZ CASE //')
  if [[ -z $last_case ]]; then
    say "the sweep did not finish, and the log names no case; see $log"
    return
  fi
  document=${last_case%%#*}
  say "CRASH: the test host died or hung in case: $last_case"
  say "reproduce with: Scripts/test/import-fuzz.sh --docs $document --seed $seed"
  say "(a finding to post, not a script failure; the report holds every case before it: $report)"
}

# main <arguments...>: runs the sweep and reports.
main() {
  parse_arguments "$@"
  cd "$ROOT" || setup_error "cannot enter $ROOT"

  [[ -n $REPORT ]] || REPORT="${TMPDIR:-/tmp}/import-fuzz-report-$(date +%Y%m%d-%H%M%S).md"
  REPORT=$(absolute "$REPORT")
  [[ -n $LOG ]] || LOG="${TMPDIR:-/tmp}/import-fuzz-$$.log"
  LOG=$(absolute "$LOG")

  # The options become the variables the test reads; the report's path is
  # always given, so this script can read it afterwards. A stale report from
  # an earlier run must not be mistaken for this run's.
  rm -f "$REPORT"
  local arguments=(--classes ImportFuzzTests --log "$LOG" --env TEXTMOUTH_IMPORT_FUZZ=1 --env "TEXTMOUTH_IMPORT_FUZZ_REPORT=$REPORT")
  [[ -z $SEED ]] || arguments+=(--env "TEXTMOUTH_IMPORT_FUZZ_SEED=$SEED")
  [[ -z $DOCS ]] || arguments+=(--env "TEXTMOUTH_IMPORT_FUZZ_DOCS=$DOCS")
  [[ -z $SECONDS_PER_IMPORT ]] || arguments+=(--env "TEXTMOUTH_IMPORT_FUZZ_SECONDS=$SECONDS_PER_IMPORT")
  ((PDF == 0)) || arguments+=(--env "TEXTMOUTH_IMPORT_FUZZ_PDF=1")
  [[ -z $DERIVED_DATA ]] || arguments+=(--derived-data "$DERIVED_DATA")

  python3 "$SCRIPT_DIR/run-area.py" "${arguments[@]}"
  local status=$?
  ((status != 2)) || setup_error "run-area.py could not run (see its output above)"

  say "report: $REPORT"
  local counts=""
  [[ -f $REPORT ]] && counts=$(grep '^done: ' "$REPORT" | tail -1)
  if [[ -n $counts ]]; then
    say "$counts"
  else
    crash_report "$REPORT" "$LOG" "${SEED:-20261016}"
    exit 3
  fi
  exit "$status"
}

main "$@"
