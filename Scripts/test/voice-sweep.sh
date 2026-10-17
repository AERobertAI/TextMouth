#!/bin/bash
#
# voice-sweep.sh: renders one fixed sample with every voice installed on this
# Mac, offline, and writes a plain Markdown report of what each voice did.
#
# Run it after installing voices or updating macOS. The sample is rendered with
# AVSpeechSynthesizer.write, the call the app itself uses, which plays nothing
# and records nothing: no sound comes out of the Mac. For each voice the report
# says whether it produced audio, how long the audio is, how long the render
# took, and whether the voice hung (the watchdog stops it) or refused. Three
# timeouts in a row stop the sweep, as they mean the speech service is wedged;
# the voices after them are reported as not tried. The report is written after
# every voice, so a crash leaves a partial one.
#
# It runs VoiceSweepTests through Scripts/test/run-area.py, which builds the
# tests (several minutes the first time) and launches the test host once.
#
# Usage: Scripts/test/voice-sweep.sh [report.md]
#
#   report.md   where to write the report (an absolute path, or one counted from
#               the current folder); default ${TMPDIR}textmouth-voice-sweep.md
#
# Filters and settings, given as environment variables to this script, for
# example VOICE_SWEEP_LANGUAGE=en Scripts/test/voice-sweep.sh:
#
#   TEXTMOUTH_VOICE_SWEEP_LANGUAGE=en        only voices whose language starts
#                                            with this
#   TEXTMOUTH_VOICE_SWEEP_VOICES=id1,id2     only these voice identifiers
#   TEXTMOUTH_VOICE_SWEEP_SECONDS=20         the watchdog per voice, in seconds
#                                            (default 20)
#
# (VOICE_SWEEP_LANGUAGE, VOICE_SWEEP_VOICES, and VOICE_SWEEP_SECONDS are
# accepted as shorter names for the same three variables.)
#
# Output: run-area.py's lines (the result, any failure, the log's path, and
# PASSED or FAILED), then the report's path and its counts line, such as
#   30 voices: 28 ok, 1 no audio, 1 timed out, 0 not tried
# A voice that is not ok never makes the run FAILED; the report lists them
# under "## Problems". The run fails only when the sweep itself could not run.
#
# Exit status: run-area.py's (0 passed, 1 failed, 2 a usage or setup error).

set -u
set -o pipefail

# This script's own folder, where run-area.py lives.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR
SCRIPT="$SCRIPT_DIR/$(basename "$0")"
readonly SCRIPT

# usage: prints the comment block at the top of this file, which doubles as
# the -h text, without its leading "# " markers.
usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT"
}

# setup_error <message>: reports a usage or setup problem and exits with 2.
setup_error() {
  printf 'voice-sweep: error: %s\n' "$*" >&2
  exit 2
}

# absolute_path <path>: prints <path> made absolute from the current folder,
# without needing the file to exist (the test host runs elsewhere, so a
# relative path would mean a different place there).
absolute_path() {
  case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

# add_setting <variable> <short name>: when <variable> (or its shorter name)
# is set and not empty in this script's environment, adds it to RUN_ARGS as an
# --env for run-area.py. The long name wins over the short one.
add_setting() {
  local long=$1 short=$2 value
  value=${!long:-}
  if [[ -z $value ]]; then
    value=${!short:-}
  fi
  if [[ -n $value ]]; then
    RUN_ARGS+=(--env "$long=$value")
  fi
}

# parse_arguments <arguments...>: reads the command line into REPORT.
parse_arguments() {
  local argument
  for argument in "$@"; do
    case $argument in
      -h|--help) usage; exit 0 ;;
      -*) setup_error "unknown option: $argument (see $0 -h)" ;;
      *)
        if [[ -n ${REPORT:-} ]]; then
          setup_error "more than one report path given (see $0 -h)"
        fi
        REPORT=$(absolute_path "$argument")
        ;;
    esac
  done
}

REPORT=
parse_arguments "$@"
if [[ -z $REPORT ]]; then
  REPORT="${TMPDIR:-/tmp/}"
  # TMPDIR normally ends with a slash; make sure of it.
  REPORT="${REPORT%/}/textmouth-voice-sweep.md"
fi
command -v python3 >/dev/null 2>&1 || setup_error "python3 is not installed"

# A stale report from an earlier run must not be shown as this run's.
rm -f "$REPORT"

RUN_ARGS=(
  --classes VoiceSweepTests
  --env TEXTMOUTH_VOICE_SWEEP=1
  --env "TEXTMOUTH_VOICE_SWEEP_REPORT=$REPORT"
)
add_setting TEXTMOUTH_VOICE_SWEEP_LANGUAGE VOICE_SWEEP_LANGUAGE
add_setting TEXTMOUTH_VOICE_SWEEP_VOICES VOICE_SWEEP_VOICES
add_setting TEXTMOUTH_VOICE_SWEEP_SECONDS VOICE_SWEEP_SECONDS

python3 "$SCRIPT_DIR/run-area.py" "${RUN_ARGS[@]}"
STATUS=$?

# Show where the report is and what it found, whatever the run's result: a
# partial report from a crashed run is still worth reading.
if [[ -f $REPORT ]]; then
  printf 'Report: %s\n' "$REPORT"
  grep -E '^[0-9]+ voices?: ' "$REPORT" || printf 'The report has no counts line yet; the sweep did not finish a voice.\n'
else
  printf 'No report was written (expected at %s).\n' "$REPORT"
fi
exit "$STATUS"
