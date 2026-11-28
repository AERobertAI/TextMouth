#!/bin/bash
#
# check.sh: TextMouth's reproducibility gate, run by `make check` and by CI.
#
# From a clean checkout the gate
#   1. regenerates TextMouth.xcodeproj from project.yml (make generate), then
#      checks the String Catalog (make l10n-check: fast, builds nothing);
#   2. resolves Swift packages exactly as the committed Package.resolved pins
#      them (make resolve-packages) and verifies that every pin's package,
#      version, revision, and URL still matches the committed file;
#   3. builds the Release app from scratch (make build SIGN_APP=:, so the app
#      keeps Xcode's ad hoc signature and the gate never asks for the keychain)
#      and requires that the build reports no Swift warning, and that the app it packages,
#      build/TextMouth.app, which `make install` copies, is no larger than
#      APP_SIZE_LIMIT_MB megabytes, a limit this script sets once. It warns,
#      without failing, when the app is larger than APP_SIZE_WARNING_MB, and
#      reports the app's size either way, so growth is noticed long before
#      the limit is reached. No file of the app may hold a folder of this
#      Mac (its home folder, the checkout, or $TMPDIR). No app may ship a table
#      of Apple's (FR39): no Localizable.strings, Localizable.stringsdict,
#      .loctable, or .xcstrings anywhere in it, and every .lproj folder holds an
#      InfoPlist.strings, which the build phase "Pack interface text" writes
#      (Scripts/l10n/pack.py). Each app must also hold exactly
#      one interface-text pack, Strings.pack, in its resources folder, of at most
#      PACK_LIMIT_BYTES (1.5 MB), as that build phase writes
#      it (FR39; Scripts/l10n/pack.py); the gate reports its size. Each app must
#      likewise hold exactly one braille-table pack, BrailleTables.pack, in its resources
#      folder (the build phase "Pack braille tables", Scripts/packs/braille_tables.py, FR40),
#      within its limit, and no liblouis/tables folder of raw tables. Still in step 3, a
#      plain run (not --without-tests) then builds the iPhone app for a device
#      (Scripts/ios/app-size.py build) and holds it to the same two limits: a
#      warning above APP_SIZE_WARNING_MB and a failure above APP_SIZE_LIMIT_MB,
#      by the sum of its files' sizes. The build takes about 8 minutes the
#      first time and about 1 after that, in build/ios-size-DerivedData;
#   4. runs the hosted XCTest suite with the Makefile's flags (make test),
#      built from scratch in the same folder, and requires that this build
#      reports no Swift warning either. The performance baselines tests run
#      strictly (PERFORMANCE_STRICT=1): a busy Mac does not skip them, so a
#      number more than twice its baseline fails the gate. The gate repeats
#      each of their warnings (a number at 1.5 times its baseline or more)
#      and why they skipped, if they did, as on a Mac other than the one the
#      baselines were recorded on; neither fails it;
# and finally confirms that no step changed the pins. It fails on any
# generation, resolution, compile, or test error, on any Swift warning, on a
# Release app larger than its limit, on an iPhone app larger than its limit,
# and when the test run reports no executed tests.
#
# The app's size is the sum of the sizes of the files in it, the number
# Finder gives as its size in bytes, and a megabyte is a million bytes, as
# Finder counts them.
#
# A Swift warning is a line in which the Swift compiler reports one, as
# "<file>.swift:<line>:<column>: warning: ..." or, about its own settings,
# "<unknown>:0: warning: ...", whatever it is about. Every target checks
# concurrency completely (project.yml), so a new concurrency problem fails
# the gate. Other tools' warnings, such as the linker's, and anything a test
# prints are not Swift warnings, and package warnings never reach the logs:
# Xcode builds packages with their warnings suppressed. A failing step names
# the first five warnings; its log holds them all.
#
# Both builds start from scratch, because xcodebuild reports a file's
# warnings only when it compiles that file. Before step 3 the gate removes
# the compiled code earlier builds left (build/DerivedData/Build and
# TextMouthTests/.build), keeping the package checkouts step 2 verified, so
# every source compiles in the gate's own run, on this Mac as on CI.
#
# Usage: Scripts/check.sh [--dry-run] [--help]
#
#   --dry-run  Print the build commands instead of running them. The pin
#              comparison still reads the real files, so a dry run checks the
#              gate's own logic in about a second. Two variables simulate
#              failures, and are accepted only with --dry-run:
#                TEXTMOUTH_CHECK_SIMULATE_FAILURE=generate|l10n|resolve|build|ios-size|test
#                  makes that step fail as though its command had failed;
#                TEXTMOUTH_CHECK_SIMULATE_RESOLVED=<file>
#                  treats <file> as the Package.resolved that resolution wrote.
#
#   --without-tests  Run steps 1 to 3 only: no hosted suite. The iPhone app is
#              still built and held to its size limits (the release gate runs
#              `make check --without-tests`, and no other gate fails an
#              oversized iPhone app), except on a GitHub runner
#              (GITHUB_ACTIONS=true), where the step is skipped and the report
#              says so: that job's workflow cannot be changed to opt out, and
#              the trains measure the iPhone app there. GitHub's check
#              workflow (.github/workflows/check.yml) runs the gate this way,
#              and runs the suite beside it in parallel jobs, from nothing, on
#              the same shards and skips as the TestBuild runs, with the
#              strict baselines and the no-Swift-warning rule applied there
#              (Scripts/agents/run-on-runner.py reads those from its request).
#              A plain `make check` still runs all four steps.
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
SCRIPT="$SCRIPT_DIR/$(basename "$0")"
readonly SCRIPT
ROOT=$(dirname "$SCRIPT_DIR")
readonly ROOT

# Paths relative to the repository root.
readonly RESOLVED_FILE="TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
readonly LOG_DIR="build/check"
# The committed pins, copied before any tool can rewrite Package.resolved.
readonly COMMITTED_COPY="$LOG_DIR/committed-Package.resolved"
# Where `make build` builds (DERIVED_BUILD_DIR in the Makefile). The gate has
# `make test` build there too (TEST_DERIVED_DATA), so one removal before
# step 3 starts both builds from scratch.
readonly DERIVED_DATA="build/DerivedData"
# The compiled code earlier builds left: Xcode's products and intermediates,
# and SwiftPM's build of the hosted test runner. The package checkouts, in
# build/DerivedData/SourcePackages, are kept.
readonly EARLIER_XCODE_BUILD="$DERIVED_DATA/Build"
readonly EARLIER_RUNNER_BUILD="TextMouthTests/.build"
# The log `make build` keeps xcodebuild's output in (BUILD_LOG in the
# Makefile, for the Release configuration).
readonly RELEASE_BUILD_LOG="build/xcodebuild-Release.log"
# The app `make build` packages (APP_BUNDLE in the Makefile), which `make
# install` copies to /Applications.
readonly RELEASE_APP="build/TextMouth.app"
# The tool that builds the iPhone app for a device and measures it. It keeps
# its derived data in an absolute folder of its own (build/ios-size-DerivedData
# of the repository, its one definition, which `make ios-size` uses too), and
# takes the heavy-work lock from no one: the gate's caller holds it.
readonly IOS_SIZE_TOOL="Scripts/ios/app-size.py"
# The iPhone app that tool builds (its derived data, in the products folder it
# names, under the app's own name): where the gate looks for its language files.
readonly IOS_APP="build/ios-size-DerivedData/Build/Products/Release-iphoneos/TextMouth.app"
# The folder of the Mac app that holds its *.lproj folders; the iPhone app's is
# the bundle itself.
readonly MAC_RESOURCES="$RELEASE_APP/Contents/Resources"
# What an app must not hold (FR39): the names of Apple's tables of text. Nothing in the apps reads them, so a file of one
# would be dead weight and a sign that the build still compiles the String Catalog.
readonly APPLE_TABLE_NAMES=(-name Localizable.strings -o -name Localizable.stringsdict -o -name '*.loctable' -o -name '*.xcstrings')
# The table every .lproj folder holds, which keeps the bundle's languages for the system.
readonly INFO_PLIST_TABLE="InfoPlist.strings"
# The interface-text pack's name, and the most bytes it may hold (1.5 MB of a million bytes; it is 1.28 MB today).
readonly PACK_NAME="Strings.pack"
readonly PACK_LIMIT_BYTES=1500000
# The braille-table pack's name (FR40), and the most bytes each app's may hold, each below: the iPhone's holds every table
# TextMouth ships for it, the Mac's the four English tables with what they include. The gate enforces both limits, and that
# no raw liblouis table is in either app: the folder the apps once held, liblouis/tables, is looked for. Each pack's size is
# reported with every check, so growth shows long before a limit; no size is written here, where it would go stale.
readonly BRAILLE_PACK_NAME="BrailleTables.pack"
readonly BRAILLE_PACK_LIMIT_BYTES=2100000
readonly MAC_BRAILLE_PACK_LIMIT_BYTES=100000
# The Release app's two size limits, in megabytes of a million bytes. Its
# developer's real limit is 30 MB and its strict one 40 MB (November 16, 2026,
# when FFmpeg was built in: the 20 MB of before was a target to optimize
# under, not a limit). The gate warns above APP_SIZE_WARNING_MB and fails
# above APP_SIZE_LIMIT_MB, so the app cannot quietly grow past either. It was
# 33 MB before the size work of October 2026, 11 MB after it, 23.55 MB on
# November 13, 2026, before -Osize and the missing export trie brought it to
# 18.98 MB, and 18.5 MB at version 0.5.0. These are the limits' only
# definitions: Scripts/check-selftest.sh and Scripts/ios/app-size.py (the
# iPhone app's limits) read them here.
readonly APP_SIZE_WARNING_MB=30
readonly APP_SIZE_LIMIT_MB=40
# A line in which the Swift compiler reports a warning (see the header).
readonly SWIFT_WARNING_PATTERN='^(.+\.swift:[0-9]+:[0-9]+|<unknown>:0): warning: '
# How many warnings a step that fails on them names.
readonly WARNINGS_NAMED=5

# How many steps this run has: four, or three with --without-tests.
STEP_COUNT=4
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
without_tests=0      # 1 when --without-tests was given
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
      --without-tests) without_tests=1; STEP_COUNT=3 ;;
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
    ""|generate|l10n|resolve|build|ios-size|test) ;;
    *) setup_error "TEXTMOUTH_CHECK_SIMULATE_FAILURE must be generate, l10n, resolve, build, ios-size, or test, not: $simulate_failure" ;;
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

# remove_earlier_builds: removes the compiled code earlier builds left, so
# every source compiles in this run, and the Release log and app an earlier
# build left, so no warning or size check can read them. A dry run only says
# what it would remove.
remove_earlier_builds() {
  local removed="$EARLIER_XCODE_BUILD and $EARLIER_RUNNER_BUILD"
  if (( dry_run )); then
    detail "would remove the compiled code of earlier builds: $removed"
    return 0
  fi
  rm -rf "$EARLIER_XCODE_BUILD" "$EARLIER_RUNNER_BUILD" "$RELEASE_BUILD_LOG" "$RELEASE_APP" ||
    fail "step $step_number of $STEP_COUNT ($step_title): cannot remove the compiled code of earlier builds: $removed"
  detail "removed the compiled code of earlier builds, so every source compiles: $removed"
}

# swift_warnings <log>: prints each Swift warning in <log> once, in the order
# the build first reported it, with the repository root left off its path.
# A Release build compiles every file once for each architecture, so the
# same warning can appear twice.
swift_warnings() {
  local line
  grep -E "$SWIFT_WARNING_PATTERN" "$1" 2>/dev/null |
    awk '!seen[$0]++' |
    while IFS= read -r line; do
      printf '%s\n' "${line#"$ROOT/"}"
    done
}

# require_no_swift_warnings <log>: says that the current step's build log
# holds no Swift warning, or fails the gate with their number and the first
# few of them. A missing log fails too, since its warnings cannot be known.
require_no_swift_warnings() {
  local log=$1 warnings count
  if (( dry_run )); then
    detail "would require no Swift warnings in $log"
    return 0
  fi
  [[ -f $log ]] ||
    fail "step $step_number of $STEP_COUNT ($step_title): $log is missing, so the build's Swift warnings are unknown"
  warnings=$(swift_warnings "$log")
  if [[ -z $warnings ]]; then
    detail "no Swift warnings in $log"
    return 0
  fi
  count=$(grep -c '' <<<"$warnings")
  if (( count > WARNINGS_NAMED )); then
    detail "$(count_of "$count" "Swift warning") in $log; the first $WARNINGS_NAMED:"
  else
    detail "$(count_of "$count" "Swift warning") in $log:"
  fi
  detail_lines "| " "$(head -n "$WARNINGS_NAMED" <<<"$warnings")"
  detail "the gate allows no Swift warning, about concurrency or anything else"
  fail "step $step_number of $STEP_COUNT ($step_title): $(count_of "$count" "Swift warning")"
}

# grouped <whole number>: prints the number with a comma between groups of
# three digits, such as 12,345,678, so that it reads clearly in speech and
# braille.
grouped() {
  local digits=$1 groups=""
  while (( ${#digits} > 3 )); do
    groups=",${digits: -3}$groups"
    digits=${digits:0:${#digits}-3}
  done
  printf '%s%s' "$digits" "$groups"
}

# describe_size <bytes>: prints a size in megabytes, to a tenth, followed by
# the exact bytes, such as "12.3 MB (12,345,678 bytes)". The bytes settle a
# size that rounds to the limit itself.
describe_size() {
  printf '%s MB (%s bytes)' "$(awk -v bytes="$1" 'BEGIN { printf "%.1f", bytes / 1000000 }')" "$(grouped "$1")"
}

# app_size <app>: prints the size of the app bundle at <app> in bytes: the
# sum of the sizes of the regular files in it, as Finder adds them up.
app_size() {
  find "$1" -type f -exec stat -f %z {} + | awk '{ total += $1 } END { printf "%.0f\n", total }'
}

# require_app_within_size_limit: reports the size of the app the Release
# build packaged; warns, without failing, when it is larger than
# APP_SIZE_WARNING_MB megabytes; and fails the gate when the app is missing,
# cannot be measured, or is larger than APP_SIZE_LIMIT_MB megabytes.
require_app_within_size_limit() {
  local bytes warning=$(( APP_SIZE_WARNING_MB * 1000000 )) limit=$(( APP_SIZE_LIMIT_MB * 1000000 ))
  if (( dry_run )); then
    detail "would require $RELEASE_APP to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
    return 0
  fi
  [[ -d $RELEASE_APP ]] ||
    fail "step $step_number of $STEP_COUNT ($step_title): $RELEASE_APP is missing, so the app's size is unknown"
  if ! bytes=$(app_size "$RELEASE_APP") || [[ ! $bytes =~ ^[0-9]+$ ]]; then
    fail "step $step_number of $STEP_COUNT ($step_title): cannot measure the size of $RELEASE_APP"
  fi
  if (( bytes > limit )); then
    detail "the limits are APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB in Scripts/check.sh; find what grew before raising them"
    fail "step $step_number of $STEP_COUNT ($step_title): $RELEASE_APP is $(describe_size "$bytes"), more than the $APP_SIZE_LIMIT_MB MB strict limit"
  fi
  if (( bytes > warning )); then
    detail "WARNING: $RELEASE_APP is $(describe_size "$bytes"), more than the $APP_SIZE_WARNING_MB MB limit; the gate fails above $APP_SIZE_LIMIT_MB MB"
    return 0
  fi
  detail "$RELEASE_APP is $(describe_size "$bytes"), within the $APP_SIZE_WARNING_MB MB limit"
}

# require_app_free_of_mac_paths: fails the gate when a file of the Release app
# holds a folder of the Mac that built it: its home folder, this checkout, or
# the temporary folder ($TMPDIR). The app is published, and the user's rule of
# November 16, 2026 keeps every path of this Mac out of what the repository
# makes as well as what it holds; FFmpeg's libraries, which configure would
# write such paths into, are checked by their own script too
# (Scripts/vendor/ffmpeg/build.py). Names the files, as paths in the app.
require_app_free_of_mac_paths() {
  if (( dry_run )); then
    detail "would require $RELEASE_APP to hold no folder of this Mac"
    return 0
  fi
  local folder files="" temporary=${TMPDIR:-}
  temporary=${temporary%/}
  for folder in "$HOME" "$ROOT" "$temporary"; do
    # An unset or root folder would match everything.
    (( ${#folder} > 1 )) || continue
    files+=$(grep -r -l -a -F -e "$folder" "$RELEASE_APP" 2>/dev/null)$'\n'
  done
  files=$(sort -u <<<"$files" | sed '/^$/d')
  if [[ -n $files ]]; then
    detail_lines "| " "$(sed "s#^$RELEASE_APP/##" <<<"$files" | head -n 5)"
    fail "step $step_number of $STEP_COUNT ($step_title): $RELEASE_APP holds a folder of this Mac (its home folder, the checkout, or \$TMPDIR)"
  fi
  detail "$RELEASE_APP holds no folder of this Mac"
}

# require_language_layout <app folder> <resources folder> <app name>: the app
# ships no table of Apple's (no Localizable.strings, Localizable.stringsdict,
# .loctable, or .xcstrings anywhere in it), and the folder that holds its *.lproj
# folders has at least one, each with an InfoPlist.strings. A table means the
# build still compiles the String Catalog (FR39); a missing or empty language
# folder means the build phase "Pack interface text" did not write it (the bundle
# would lose its languages). No InfoPlist.strings may rename the app either: only
# a Debug build, the tests', is named "TextMouth Test" (TEXTMOUTH_TEST_DISPLAY_NAME
# in project.yml), and the app make install copies must stay "TextMouth".
# Reports what it found.
require_language_layout() {
  local app_folder=$1 resources=$2 app=$3 tables folder count=0 missing="" renamed=""
  if (( dry_run )); then
    detail "would require $app to hold no table of Apple's, and an $INFO_PLIST_TABLE in each .lproj folder"
    return 0
  fi
  # A test bundle in PlugIns/ (*.xctest) holds the tool tests' fixture catalogs, not the app's language files.
  tables=$(find "$app_folder" -not -path "*/PlugIns/*.xctest/*" \( "${APPLE_TABLE_NAMES[@]}" \) -type f | sort)
  if [[ -n $tables ]]; then
    detail_lines "APPLE TABLE: " "$(sed "s#^$app_folder/##" <<<"$tables")"
    fail "step $step_number of $STEP_COUNT ($step_title): $app ships a table of Apple's (the apps read Strings.pack; the build must not compile the String Catalog)"
  fi
  for folder in "$resources"/*.lproj; do
    [[ -d $folder ]] || continue
    count=$(( count + 1 ))
    [[ -f $folder/$INFO_PLIST_TABLE ]] || missing+="${folder#"$resources"/}"$'\n'
    if [[ -f $folder/$INFO_PLIST_TABLE ]] && grep -q 'CFBundleDisplayName' "$folder/$INFO_PLIST_TABLE"; then
      renamed+="${folder#"$resources"/}"$'\n'
    fi
  done
  if (( count == 0 )); then
    detail "NO LANGUAGES: no .lproj folder found in $resources"
    fail "step $step_number of $STEP_COUNT ($step_title): $app holds no .lproj folder (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes one for each language)"
  fi
  if [[ -n $missing ]]; then
    detail_lines "NO $INFO_PLIST_TABLE: " "$(sed '/^$/d' <<<"$missing")"
    fail "step $step_number of $STEP_COUNT ($step_title): $app has a .lproj folder with no $INFO_PLIST_TABLE (the build phase \"Pack interface text\", Scripts/l10n/pack.py, writes it)"
  fi
  if [[ -n $renamed ]]; then
    detail_lines "RENAMED: " "$(sed '/^$/d' <<<"$renamed")"
    fail "step $step_number of $STEP_COUNT ($step_title): $app is renamed by an $INFO_PLIST_TABLE (only a Debug build, the tests', takes the name TEXTMOUTH_TEST_DISPLAY_NAME gives)"
  fi
  detail "$app holds $count .lproj folders, each with an $INFO_PLIST_TABLE, and no table of Apple's"
}

# require_one_pack <app folder> <resources folder> <app name> <pack name> <limit> <phase> <writer>: the app holds exactly one
# file named <pack name>, in its resources folder, no larger than <limit> bytes. A missing pack means the build phase <phase>,
# which runs the script <writer>, did not run (every line would show English, or no braille table could be unpacked); a
# second one is a stray copy that would ship twice; a pack over the limit means the budget is spent (FR39, FR40). Reports
# the pack's size.
require_one_pack() {
  local app_folder=$1 resources=$2 app=$3 pack_name=$4 limit=$5 phase=$6 writer=$7 found count size
  if (( dry_run )); then
    detail "would require $app to hold exactly one $pack_name of at most $limit bytes"
    return 0
  fi
  found=$(find "$app_folder" -name "$pack_name" -type f)
  count=$(grep -c . <<<"$found" || true)
  if (( count != 1 )); then
    detail_lines "| " "$found"
    fail "step $step_number of $STEP_COUNT ($step_title): $app holds $count files named $pack_name, not one (the build phase \"$phase\", $writer, writes exactly one into its resources)"
  fi
  if [[ $found != "$resources/$pack_name" ]]; then
    fail "step $step_number of $STEP_COUNT ($step_title): $app holds its $pack_name at ${found#"$app_folder"/}, not in its resources folder"
  fi
  size=$(wc -c < "$found" | tr -d ' ')
  detail "$app's $pack_name is $size bytes (the limit is $limit)"
  if (( size > limit )); then
    fail "step $step_number of $STEP_COUNT ($step_title): $app's $pack_name is $size bytes, over the $limit-byte limit"
  fi
}

# require_one_interface_pack <app folder> <resources folder> <app name>: the app holds exactly one Strings.pack (FR39,
# Scripts/l10n/pack.py), within PACK_LIMIT_BYTES.
require_one_interface_pack() {
  require_one_pack "$1" "$2" "$3" "$PACK_NAME" "$PACK_LIMIT_BYTES" "Pack interface text" "Scripts/l10n/pack.py"
}

# require_braille_pack <app folder> <resources folder> <app name> <limit>: the app holds exactly one BrailleTables.pack
# (FR40, Scripts/packs/braille_tables.py) within <limit> bytes, and no raw liblouis tables: no folder named tables inside a
# folder named liblouis, which the apps held before the pack, and no table file (.ctb .cti .utb .uti .tbl .dis .dic) anywhere.
require_braille_pack() {
  local app_folder=$1 resources=$2 app=$3 limit=$4 raw
  require_one_pack "$app_folder" "$resources" "$app" "$BRAILLE_PACK_NAME" "$limit" "Pack braille tables" \
    "Scripts/packs/braille_tables.py"
  if (( dry_run )); then
    return 0
  fi
  raw=$(find "$app_folder" \( -type d -path '*/liblouis/tables' -o -type f \( -name '*.ctb' -o -name '*.cti' -o -name '*.utb' -o -name '*.uti' -o -name '*.tbl' -o -name '*.dis' -o -name '*.dic' \) \))
  if [[ -n $raw ]]; then
    detail_lines "| " "$raw"
    fail "step $step_number of $STEP_COUNT ($step_title): $app holds raw liblouis tables (the tables are in $BRAILLE_PACK_NAME, which the app unpacks at first use, and no other file of the app is one)"
  fi
  detail "$app holds no raw liblouis tables"
}

# require_ios_app_within_size_limit: builds the iPhone app for a device and
# measures it with Scripts/ios/app-size.py, which counts the app's size as
# app_size does and has the same two limits (its own tests check that they
# match APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB). Reports the app, its IPA,
# and the App Store download estimate; warns, without failing, above the
# warning size; and fails the gate when the build fails or the app is over the
# strict limit, which the tool signals with its exit status 3. The tool is run
# directly, not through run_locked.py: this gate's caller already holds the
# heavy-work lock, which a second wait for it would never get.
require_ios_app_within_size_limit() {
  local status=0 headlines app_line
  run_step ios-size yes python3 -I -B "$IOS_SIZE_TOOL" build --summary --check || status=$?
  if (( dry_run )); then
    if (( status != 0 )); then
      step_failed ios-size "$status"
    fi
    detail "would require the iPhone app to be no larger than $APP_SIZE_LIMIT_MB MB, and warn above $APP_SIZE_WARNING_MB MB"
    return 0
  fi
  # The headline lines of the tool's summary: the app, the IPA, the download.
  headlines=$(sed -n -E 's/^Size: //p' "$LOG_DIR/ios-size.log")
  # The app's own headline: the IPA and download lines follow it, and only the app is held to the limits.
  app_line=$(grep -m 1 -E '^iPhone app: ' <<<"$headlines")
  # Exit status 3 says the app is over the strict limit; so does its headline, a second guard.
  if (( status == 3 )) || grep -q -F -e "over the strict" <<<"$app_line"; then
    detail_lines "" "$headlines"
    detail "the limits are APP_SIZE_WARNING_MB and APP_SIZE_LIMIT_MB in Scripts/check.sh; the biggest files and libraries are in $LOG_DIR/ios-size.log"
    fail "step $step_number of $STEP_COUNT ($step_title): the iPhone app is more than the $APP_SIZE_LIMIT_MB MB strict limit"
  elif (( status != 0 )); then
    # Name the iPhone in the verdict: a failed Mac build ends the same line.
    step_title="$step_title, the iPhone app's device build"
    step_failed ios-size "$status" "The iPhone device build (Scripts/ios/app-size.py) failed, not the Mac's build."
  fi
  if [[ -z $app_line ]]; then
    fail "step $step_number of $STEP_COUNT ($step_title): $LOG_DIR/ios-size.log has no size lines, so the iPhone app's size is unknown"
  fi
  if grep -q -F -e "over the $APP_SIZE_WARNING_MB MB limit" <<<"$app_line"; then
    detail "WARNING: the iPhone app is more than the $APP_SIZE_WARNING_MB MB limit; the gate fails above $APP_SIZE_LIMIT_MB MB"
  fi
  detail_lines "" "$headlines"
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
  if [[ $summary =~ $count_pattern ]] && (( BASH_REMATCH[1] > 0 )); then
    return 0
  fi
  detail "full log: $log"
  fail "the hosted test run executed no tests"
}

# report_performance: repeats what the performance baselines tests said
# beyond passing, once each: every number at 1.5 times its baseline or more
# (a line beginning "PERFORMANCE WARNING:"), and every reason they skipped
# ("PERFORMANCE SKIPPED:"). Neither fails the gate: a number more than twice
# its baseline has already failed the test step.
report_performance() {
  local log="$LOG_DIR/test.log" lines
  if (( dry_run )); then
    detail "would repeat the performance tests' warnings and skips from $log"
    return 0
  fi
  lines=$(grep -E '^PERFORMANCE (WARNING|SKIPPED):' "$log" 2>/dev/null | awk '!seen[$0]++')
  detail_lines "" "$lines"
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
  # The String Catalog's rules (FR34): every string of a shipped language translated, placeholders and plural forms
  # agreeing, a comment on every string, nothing stale. It reads the catalog and builds nothing, so it runs here, where
  # a failure costs seconds and not a Release build.
  step_title="$step_title, then check the String Catalog"
  run_step l10n no make l10n-check || step_failed l10n $? "Run make l10n-check for the whole list; make l10n-status says what each language lacks."

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
  remove_earlier_builds
  # SIGN_APP=: keeps the ad hoc signature Xcode gives the app. The gate's app is
  # never installed (make install builds and signs its own), and an unattended
  # gate must never ask for the keychain: it once kept a password dialog on the
  # user's screen for hours, and then failed.
  run_step build yes make build SIGN_APP=: || step_failed build $?
  # The sizes below are the profile's: a Mac's development build is light (no
  # link-time optimization), so it is larger than the app make install ships.
  detail "the size settings' profile: $(python3 -I -B Scripts/size_settings.py --which) (full on GitHub Actions and for make install and make release; light for a Mac's other builds)"
  require_no_swift_warnings "$RELEASE_BUILD_LOG"
  require_app_within_size_limit
  require_app_free_of_mac_paths
  require_language_layout "$RELEASE_APP" "$MAC_RESOURCES" "$RELEASE_APP"
  require_one_interface_pack "$RELEASE_APP" "$MAC_RESOURCES" "$RELEASE_APP"
  require_braille_pack "$RELEASE_APP" "$MAC_RESOURCES" "$RELEASE_APP" "$MAC_BRAILLE_PACK_LIMIT_BYTES"
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    detail "the iPhone app is not built or measured on a GitHub runner (GITHUB_ACTIONS=true); the trains measure it there"
  else
    require_ios_app_within_size_limit
    require_language_layout "$IOS_APP" "$IOS_APP" "the iPhone app"
    require_one_interface_pack "$IOS_APP" "$IOS_APP" "the iPhone app"
    require_braille_pack "$IOS_APP" "$IOS_APP" "the iPhone app" "$BRAILLE_PACK_LIMIT_BYTES"
  fi

  if (( without_tests )); then
    say "the hosted XCTest suite is not run by this gate (--without-tests)"
  else
    begin_step 4 "run the hosted XCTest suite"
    run_step test yes make test "TEST_DERIVED_DATA=$DERIVED_DATA" PERFORMANCE_STRICT=1 || step_failed test $?
    report_tests
    report_performance
    require_no_swift_warnings "$LOG_DIR/test.log"
  fi

  # No later step may re-resolve packages behind the gate's back.
  verify_pins "$RESOLVED_FILE" "Package.resolved changed during the build or tests"
  detail "Package.resolved still holds the committed pins"

  if (( dry_run )); then
    say "PASSED (dry run)"
  else
    say "PASSED"
  fi
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# gate run never reads past this point, even if the file is edited mid-run.
main "$@"; exit $?
