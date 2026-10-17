#!/bin/bash
#
# storage-drill.sh: runs the storage-failure drill (StorageDrillTests), which
# unplugs or fills a small disk image part-way through an import, a library
# save, and a data-directory move, and checks by checksum that the original
# files and the previous library survive every reported failure. Then it
# says plainly whether any image of the drill is still attached.
#
# What it does to this Mac: each test creates a disk image of 3 to 16 MB in
# the test host's sandbox (the temporary folder, TextMouthTests-<pid>),
# mounts it hidden from Finder, force-detaches it (as a pulled cable would),
# and deletes it when the test ends, whatever the outcome; at most a few
# dozen MB at a time, none of it kept. It never touches ~/.TextMouth, the
# preferences, or any volume but its own images, and a crashed earlier run's
# leftover images (named TMDrill-..., under that sandbox folder only) are
# detached at the start of the next. Nothing makes a sound.
#
# How long: one build plus the tests, about 3 to 6 minutes on a Mac that has
# built TextMouth before; the drill's tests themselves take under a minute.
#
# Usage: Scripts/test/storage-drill.sh [-h|--help] [run-area.py options]
#   Any other option goes to Scripts/test/run-area.py (for example
#   --derived-data DIR or --log FILE); the class and the environment variable
#   that switches the drill on are set here. During Claude Code agent
#   sessions set BBS_AGENT=<name> to report to the board.
#
# Output: run-area.py's lines (the result, each failure, the log's path,
# PASSED or FAILED), then one line about the images, then the verdict:
#   "Storage drill: PASSED"       only when the tests ran (at least one
#                                 executed and not every one skipped, since
#                                 the drill's tests all skip unless its switch
#                                 is on), none failed, and no image is left
#                                 attached;
#   "Storage drill: FAILED"       when a test failed or an image is left
#                                 attached;
#   "Storage drill: NOT RUN: ..." when no drill test ran: a --dry-run, --list,
#                                 or --clean option (run-area.py answers
#                                 those without running a test), or a run in
#                                 which every test skipped.
#
# Exit status: 0 only for PASSED; 1 when a test failed or an image is left
# attached; 2 for a usage or setup error and for NOT RUN.
#
# For the selftest (Scripts/test/storage-drill-selftest.sh), two environment
# variables replace the real tools; leave them unset otherwise:
#   TEXTMOUTH_DRILL_RUN_AREA  the program run in place of
#                             `python3 Scripts/test/run-area.py`
#   TEXTMOUTH_DRILL_HDIUTIL   the program run in place of `hdiutil`

set -u
set -o pipefail

# This script's folder, where run-area.py lives.
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 2
readonly SCRIPT_DIR

# usage: prints the header comment (from the second line to the first line
# that is not a comment) as the help text.
usage() {
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p;}' "$0"
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

# The tools, replaceable for the selftest (see the header).
HDIUTIL=${TEXTMOUTH_DRILL_HDIUTIL:-hdiutil}
if [ -n "${TEXTMOUTH_DRILL_RUN_AREA:-}" ]; then
    run_area=("$TEXTMOUTH_DRILL_RUN_AREA")
else
    run_area=(python3 "$SCRIPT_DIR/run-area.py")
fi

# run-area.py's lines are shown as they come and kept in this file, so its
# "Executed N tests ..." line can be read afterwards.
runner_lines=$(mktemp "${TMPDIR:-/tmp}/storage-drill.XXXXXX") || exit 2
trap 'rm -f "$runner_lines"' EXIT

# Run only the drill's class, with the variable that switches it on. With
# pipefail set, the status is run-area.py's, not tee's.
"${run_area[@]}" \
    --classes StorageDrillTests \
    --env TEXTMOUTH_STORAGE_DRILL=1 \
    "$@" 2>&1 | tee "$runner_lines"
tests_status=${PIPESTATUS[0]}

# tests_ran: succeeds when run-area.py's lines show a run in which at least
# one test executed and not every executed test was skipped. Its first line
# is "Executed N tests, with S tests skipped and F failures ..." (the skipped
# part is absent when none skipped) or "no tests ran".
tests_ran() {
    local line executed skipped
    line=$(grep -E '^Executed [0-9]+ tests?, with ' "$runner_lines" | tail -n 1)
    [ -n "$line" ] || return 1
    executed=$(printf '%s\n' "$line" | sed -E 's/^Executed ([0-9]+) .*/\1/')
    skipped=$(printf '%s\n' "$line" | sed -nE 's/.* with ([0-9]+) tests? skipped.*/\1/p')
    [ "$executed" -gt "${skipped:-0}" ]
}

# Any image of the drill still attached? Ask hdiutil, which lists every
# attached image with its path; the drill's are named TMDrill-... .
attached_report=$("$HDIUTIL" info 2>&1) || {
    echo "Could not run hdiutil info, so the check for attached drill images was skipped."
    exit 2
}
# Each image's device is on a line of its own after its "image-path" line;
# keep the whole-disk device (/dev/diskN) of every TMDrill- image.
leftover_devices=$(
    printf '%s\n' "$attached_report" | awk '
        /^image-path/ { drill = ($0 ~ /\/TMDrill-/) }
        drill && $1 ~ /^\/dev\/disk[0-9]+$/ { print $1 }
    '
)

if [ -z "$leftover_devices" ]; then
    echo "No TMDrill- disk image is attached."
    image_status=0
else
    echo "A TMDrill- disk image is STILL ATTACHED. Detach it with:"
    for device in $leftover_devices; do
        echo "  hdiutil detach -force $device"
    done
    image_status=1
fi

# The verdict. A failed test or a left image is FAILED (a setup error from the
# runner keeps its status 2); a run that ran no drill test is NOT RUN, never
# PASSED; only a clean run of at least one test is PASSED.
if [ "$tests_status" -ne 0 ] || [ "$image_status" -ne 0 ]; then
    echo "Storage drill: FAILED"
    [ "$tests_status" -eq 2 ] && exit 2
    exit 1
fi
if ! tests_ran; then
    echo "Storage drill: NOT RUN: no test ran (a dry run, a list, a clean, or every test skipped)"
    exit 2
fi
echo "Storage drill: PASSED"
exit 0
