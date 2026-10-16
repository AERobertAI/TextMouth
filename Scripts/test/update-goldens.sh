#!/bin/bash
#
# update-goldens.sh: records new golden files for the documents in TestData,
# run after a deliberate change to what a parser, the text pipeline, or
# heading detection produces (DocumentGoldenTests names the difference and
# points here).
#
# It runs DocumentGoldenTests alone, through Scripts/test/run-area.py, with
# TEXTMOUTH_UPDATE_GOLDENS=1. In that mode the tests do not compare: each
# imports its document and writes TestData/golden/<file name>.golden into the
# source tree. The two large optional DAISY books are never recorded, and a
# PDF's golden notes the macOS it was recorded on. The script then lists the
# goldens that changed.
#
# Review the diff of TestData/golden, then commit it with the change it
# records. A golden that looks wrong (a missing heading, a wrong title) is a
# bug to report, not a record to commit.
#
# Usage: Scripts/test/update-goldens.sh [-h|--help] [run-area.py options]
#
#   Any other argument goes to run-area.py unchanged, for example
#   --derived-data <folder> or --log <file>. Set BBS_AGENT=<name> during a
#   Claude Code agent session so the build reports to the board.
#
# Output: run-area.py's short result (the tests run, any failure, the log's
# path, then PASSED or FAILED), then `git status --short TestData/golden`.
#
# Exit status: run-area.py's: 0 when the goldens were recorded, 1 when the
# tests failed, 2 for a usage or setup error.

set -u

# The script's own folder and the repository root, two folders up.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR
SCRIPT="$SCRIPT_DIR/$(basename "$0")"
readonly SCRIPT
ROOT=$(dirname "$(dirname "$SCRIPT_DIR")")
readonly ROOT

# usage: prints the comment block at the top of this file, which doubles as
# the --help text, without its leading "# " markers.
usage() {
  awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$SCRIPT"
}

case ${1:-} in
  -h|--help) usage; exit 0 ;;
esac

cd "$ROOT" || exit 2

# One run of the hosted tests, recording instead of comparing.
python3 "$SCRIPT_DIR/run-area.py" --classes DocumentGoldenTests --env TEXTMOUTH_UPDATE_GOLDENS=1 "$@"
status=$?

# What the run changed, whether or not it passed.
echo
git status --short TestData/golden
echo "Review the diff of TestData/golden, then commit it with the change it records."
exit "$status"
