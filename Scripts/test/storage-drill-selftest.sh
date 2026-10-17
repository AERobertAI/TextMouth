#!/bin/bash
#
# storage-drill-selftest.sh: tests Scripts/test/storage-drill.sh in a second,
# without building, without running a test, and without ever running the real
# hdiutil or xcodebuild.
#
# Every case runs storage-drill.sh with TEXTMOUTH_DRILL_RUN_AREA and
# TEXTMOUTH_DRILL_HDIUTIL pointing at stubs in a fresh folder. The run-area
# stub prints the lines a case gives it (as run-area.py would print them) and
# exits with the status the case gives it; the hdiutil stub prints a listing
# with or without a drill image attached. A case checks the drill script's
# verdict line and its exit status, and that the options reached the runner.
#
# Usage: Scripts/test/storage-drill-selftest.sh   (make check-selftest runs it)
#
# Output: only the verdict, "storage-drill-selftest: N cases passed", and
# under a failing case, one line per problem.
#
# Exit status: 0 when every case passes, 1 otherwise.

set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
readonly SCRIPT_DIR
readonly DRILL="$SCRIPT_DIR/storage-drill.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/storage-drill-selftest.XXXXXX") || exit 1
readonly WORK
trap 'rm -rf "$WORK"' EXIT

# What hdiutil info prints for no image, and for a drill image still attached.
readonly NO_IMAGE_LISTING="framework       : 700
driver          : 700"
readonly DRILL_IMAGE_LISTING="image-path      : /var/folders/zz/T/TextMouthTests-4242/TMDrill-0a1b2c3d-x.dmg
/dev/disk9          	GUID_partition_scheme
/dev/disk9s1        	Apple_HFS	/var/folders/zz/T/mnt"

passed=0
failed=0

# write_stubs RUN_LINES RUN_STATUS HDIUTIL_LISTING: writes the two stubs. The
# run-area stub records its arguments in $WORK/runner-args, prints RUN_LINES,
# and exits with RUN_STATUS; the hdiutil stub prints HDIUTIL_LISTING.
write_stubs() {
    printf '%s\n' "$1" > "$WORK/runner-lines"
    printf '%s\n' "$3" > "$WORK/hdiutil-listing"
    cat > "$WORK/run-area" <<STUB
#!/bin/bash
printf '%s\n' "\$@" > "$WORK/runner-args"
cat "$WORK/runner-lines"
exit $2
STUB
    cat > "$WORK/hdiutil" <<STUB
#!/bin/bash
cat "$WORK/hdiutil-listing"
STUB
    chmod +x "$WORK/run-area" "$WORK/hdiutil"
}

# run_case NAME EXPECTED_VERDICT EXPECTED_STATUS RUN_LINES RUN_STATUS LISTING
# [OPTION...]: runs the drill script with the stubs and the options, and
# checks that its output has the verdict line EXPECTED_VERDICT as its last
# line, that its status is EXPECTED_STATUS, and that the runner got the
# drill's class, its switch, and the options.
run_case() {
    local name=$1 verdict=$2 expected_status=$3 lines=$4 run_status=$5 listing=$6
    shift 6
    local problems="" output status last
    write_stubs "$lines" "$run_status" "$listing"
    output=$(TEXTMOUTH_DRILL_RUN_AREA="$WORK/run-area" TEXTMOUTH_DRILL_HDIUTIL="$WORK/hdiutil" \
        "$DRILL" ${1+"$@"} 2>&1)
    status=$?
    last=$(printf '%s\n' "$output" | tail -n 1)
    # Compare the start of the line: a NOT RUN verdict goes on to say why.
    case "$last" in
        "$verdict"*) ;;
        *) problems+="  last line is \"$last\", not \"$verdict...\""$'\n' ;;
    esac
    [ "$status" -eq "$expected_status" ] || problems+="  exit status is $status, not $expected_status"$'\n'
    # The runner's own lines are copied through.
    printf '%s\n' "$output" | grep -qxF -- "$(head -n 1 "$WORK/runner-lines")" \
        || problems+="  the runner's first line was not copied through"$'\n'
    grep -qxF -- "StorageDrillTests" "$WORK/runner-args" || problems+="  the runner was not given the drill's class"$'\n'
    grep -qxF -- "TEXTMOUTH_STORAGE_DRILL=1" "$WORK/runner-args" || problems+="  the runner was not given the drill's switch"$'\n'
    local option
    for option in ${1+"$@"}; do
        grep -qxF -- "$option" "$WORK/runner-args" || problems+="  the runner was not given $option"$'\n'
    done
    if [ -z "$problems" ]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        echo "not ok: $name"
        printf '%s' "$problems"
        printf '%s\n' "$output" | sed 's/^/    | /'
    fi
}

readonly RAN="Executed 12 tests, with 0 failures (0 unexpected) in 31.2 (31.4) seconds"

run_case "a passing run prints PASSED" \
    "Storage drill: PASSED" 0 "$RAN" 0 "$NO_IMAGE_LISTING"
run_case "a run with some tests skipped still prints PASSED" \
    "Storage drill: PASSED" 0 "Executed 12 tests, with 2 tests skipped and 0 failures (0 unexpected) in 3.1 (3.2) seconds" 0 "$NO_IMAGE_LISTING"
run_case "a run of one test prints PASSED" \
    "Storage drill: PASSED" 0 "Executed 1 test, with 0 failures (0 unexpected) in 1.0 (1.0) seconds" 0 "$NO_IMAGE_LISTING"
run_case "a dry run is NOT RUN" \
    "Storage drill: NOT RUN" 2 "xcodebuild test -project TextMouth.xcodeproj -only-testing:TextMouthProductionTests/StorageDrillTests" 0 "$NO_IMAGE_LISTING" --dry-run
run_case "a list is NOT RUN" \
    "Storage drill: NOT RUN" 2 "StorageDrillTests" 0 "$NO_IMAGE_LISTING" --list
run_case "a clean is NOT RUN" \
    "Storage drill: NOT RUN" 2 "no tests ran" 0 "$NO_IMAGE_LISTING" --clean
run_case "a run that says no tests ran is NOT RUN" \
    "Storage drill: NOT RUN" 2 "no tests ran" 0 "$NO_IMAGE_LISTING"
run_case "a run in which every test skipped is NOT RUN" \
    "Storage drill: NOT RUN" 2 "Executed 6 tests, with 6 tests skipped and 0 failures (0 unexpected) in 0.1 (0.1) seconds" 0 "$NO_IMAGE_LISTING"
run_case "a run of no tests is NOT RUN" \
    "Storage drill: NOT RUN" 2 "Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds" 0 "$NO_IMAGE_LISTING"
run_case "a failing run prints FAILED" \
    "Storage drill: FAILED" 1 "Executed 12 tests, with 1 failure (1 unexpected) in 31.2 (31.4) seconds" 1 "$NO_IMAGE_LISTING"
run_case "an image left attached is FAILED, even after a passing run" \
    "Storage drill: FAILED" 1 "$RAN" 0 "$DRILL_IMAGE_LISTING"
run_case "an image left attached is FAILED, even after a dry run" \
    "Storage drill: FAILED" 1 "xcodebuild test" 0 "$DRILL_IMAGE_LISTING" --dry-run
run_case "a setup error from the runner is FAILED with status 2" \
    "Storage drill: FAILED" 2 "run-area.py: unknown name" 2 "$NO_IMAGE_LISTING"

if [ "$failed" -eq 0 ]; then
    echo "storage-drill-selftest: $passed cases passed"
    exit 0
fi
echo "storage-drill-selftest: $failed of $((passed + failed)) cases failed"
exit 1
