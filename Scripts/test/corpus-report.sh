#!/bin/bash
#
# corpus-report.sh: writes a Markdown report of what TextMouth's importers
# make of every document in a folder: one section per file with its format,
# title, author, headings and their levels, text length, first lines, every
# warning or refusal, and a checksum of the reading text. The report is plain
# words, headings and bullet lists, written to be read through VoiceOver and
# a braille display. It is the machine's half of checking the importers on
# real documents; whether the reading order is right is still a person's.
#
# It runs CorpusReportTests alone, through Scripts/test/run-area.py, with
# TEXTMOUTH_CORPUS_DIR set to the folder and TEXTMOUTH_CORPUS_REPORT set to
# the report. Each file is copied into a sandbox and the copy is imported, so
# the folder is only ever read and its files are never changed or deleted.
# Ogg audio (and a ZIP holding it) is never decoded: its section says
# `skipped`. The report is rewritten after every file, so a crash or a hang
# leaves a report that is complete up to the last file that finished.
#
# Usage: Scripts/test/corpus-report.sh <folder> [report.md] [run-area.py options]
#        Scripts/test/corpus-report.sh -h|--help
#
#   <folder>     the folder of documents to read (searched recursively)
#   report.md    where to write the report; default
#                ${TMPDIR}textmouth-corpus-report.md. It must be outside the
#                repository, which ignores *.md files.
#   Anything after that goes to run-area.py unchanged, for example
#   --derived-data <folder> or --log <file>. Set BBS_AGENT=<name> during a
#   Claude Code agent session so the build reports to the board.
#
#   TEXTMOUTH_CORPUS_MAX_FILES=N       read at most N files (default 200)
#   TEXTMOUTH_CORPUS_FILE_SECONDS=N    give each file N seconds (default 180)
#
#   To try it on a folder of nasty-but-valid documents, make one with
#   Scripts/test/make-corpus.py --out <folder>.
#
# Output: run-area.py's short result (the tests run, any failure, the log's
# path, then PASSED or FAILED), then the report's path and its counts line,
# for example `12 files: 8 imported, 1 with warnings, 2 refused, 1 skipped`.
#
# Exit status: run-area.py's: 0 when the report was written, 1 when the run
# failed, 2 for a usage or setup error.

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

# setup_error <message>: reports a usage or setup problem and exits with 2.
setup_error() {
  printf 'corpus-report: error: %s\n' "$*" >&2
  exit 2
}

# absolute <path>: prints the path made absolute, relative to the directory
# the script was started in, with no symbolic link resolved.
absolute() {
  case $1 in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$START_DIR" "$1" ;;
  esac
}

START_DIR=$PWD

case ${1:-} in
  -h|--help) usage; exit 0 ;;
  "") setup_error "no folder given (see $0 --help)" ;;
esac

# The folder must exist; it is passed by absolute path.
[[ -d $1 ]] || setup_error "not a folder: $1"
FOLDER=$(absolute "$1")
shift

# The report: the next argument when it is not an option, else the default.
if [[ ${1:-} != "" && $1 != -* ]]; then
  REPORT=$(absolute "$1")
  shift
else
  REPORT="${TMPDIR:-/tmp/}"
  REPORT="${REPORT%/}/textmouth-corpus-report.md"
fi
[[ -d $(dirname "$REPORT") ]] || setup_error "the report's folder does not exist: $(dirname "$REPORT")"
[[ $REPORT != "$ROOT"/* ]] || setup_error "the report must be outside the repository: $REPORT"

cd "$ROOT" || exit 2

# A report left by an earlier run must not be taken for this one's.
rm -f "$REPORT"

# The variables the test host is given: the folder and the report, and the
# two limits when the person has set them (run-area.py hands the host only
# what it is told to).
ENVIRONMENT=(--env "TEXTMOUTH_CORPUS_DIR=$FOLDER" --env "TEXTMOUTH_CORPUS_REPORT=$REPORT")
[[ -z ${TEXTMOUTH_CORPUS_MAX_FILES:-} ]] || ENVIRONMENT+=(--env "TEXTMOUTH_CORPUS_MAX_FILES=$TEXTMOUTH_CORPUS_MAX_FILES")
[[ -z ${TEXTMOUTH_CORPUS_FILE_SECONDS:-} ]] || ENVIRONMENT+=(--env "TEXTMOUTH_CORPUS_FILE_SECONDS=$TEXTMOUTH_CORPUS_FILE_SECONDS")

# One run of the hosted tests: reads the folder and writes the report.
python3 "$SCRIPT_DIR/run-area.py" --classes CorpusReportTests "${ENVIRONMENT[@]}" "$@"
status=$?

# Where the report is and what it counted, whether or not the run passed (a
# failed run may still have left a report that is complete up to a point).
echo
if [[ -f $REPORT ]]; then
  echo "Report: $REPORT"
  grep -m 1 -E '^[0-9]+ files:' "$REPORT" || echo "The report has no counts line."
else
  echo "No report was written."
fi
exit "$status"
