#!/bin/bash
#
# set-version.sh: sets TextMouth's version number and regenerates the Xcode
# project, so that the next build carries it. `make set-version
# VERSION=0.2.0` runs it.
#
# The version is MARKETING_VERSION in project.yml, which Info.plist reads as
# CFBundleShortVersionString. While TextMouth is in beta its version is
# 0.MINOR.PATCH, until a 1.0: MINOR goes up when a merged feature set the
# user asked for reaches main, and PATCH goes up for an install that holds
# fixes only (see Versions in docs/developer/building.md). The build number,
# CFBundleVersion, is not set here: `make build` stamps each build with the
# UTC time as YYYYMMDDHHMMSS, which is unique and increasing, and `make
# install` names the dSYM it keeps for the build by it.
#
# Usage: Scripts/set-version.sh <version>
#        Scripts/set-version.sh --selftest
#
# <version> is MAJOR.MINOR.PATCH: three whole numbers joined by dots, none
# with a leading zero, such as 0.2.0. The script refuses a version that is
# not later than the current one, comparing each number as a number, so that
# 0.10.0 is later than 0.9.0. It changes nothing but the value of
# MARKETING_VERSION in project.yml, leaving every other byte of the file as it
# was, then runs `xcodegen generate` so that TextMouth.xcodeproj follows, and
# prints the old and the new version. If xcodegen fails, it puts project.yml
# back as it was. It commits nothing: commit project.yml together with the
# regenerated project.
#
# --selftest tests the script in a second, on a copy of project.yml in a
# temporary folder and with a stand-in for xcodegen, so that it changes
# nothing in the repository and builds nothing. `make check-selftest` runs it.
#
# Exit status: 0 on success, and when --selftest passes; 1 when the script
# refuses or fails, saying why on standard error, with project.yml as it was;
# 2 for a usage error, which includes a version of the wrong form.

set -u

# A fixed locale makes the patterns and comparisons below work on bytes, the
# same on every Mac.
export LC_ALL=C

# This script's folder and its own path, and the repository root, which is the
# folder above Scripts/ and holds the project.yml the script changes. A copy
# of the script in another folder, as --selftest makes, therefore changes that
# folder's project.yml and nobody else's.
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
readonly SELF_DIR
readonly SELF="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT=$(dirname "$SELF_DIR")
readonly ROOT
readonly PROJECT_YML="$ROOT/project.yml"

# Any line of project.yml that sets the version, whatever it sets it to.
readonly VERSION_KEY_RE='^[[:space:]]*MARKETING_VERSION:'

# The one form of that line this script reads and writes. Its parts are: 1 the
# text before the value, 2 the value's opening double quote (or nothing), 3
# the version, 4 its closing double quote (or nothing), and 5 the text after
# it, spaces and perhaps a comment. Part 6 is the comment inside part 5.
readonly VERSION_LINE_RE='^([[:space:]]*MARKETING_VERSION:[[:space:]]*)("?)([0-9]+\.[0-9]+\.[0-9]+)("?)([[:space:]]*(#.*)?)$'

# A version this script writes: three whole numbers joined by dots, a number
# being 0 or digits that do not begin with 0, so that 0.2.01 cannot be written
# (it would equal 0.2.1, which the script would then refuse as no later).
readonly NEW_VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# The temporary files a run makes, for the exit trap to remove: the new
# project.yml, written beside the old one so that moving it into place
# replaces the old one in one step, and a copy of the old one, kept until
# xcodegen has succeeded.
NEW_FILE=""
BACKUP_FILE=""

# say <text>: prints one line of the script's report.
say() {
  printf '==> %s\n' "$*"
}

# complain <text>: says, on standard error, why the script cannot go on.
complain() {
  printf 'set-version: %s\n' "$*" >&2
}

# die <status> <text>: complains, then ends the script with <status>.
die() {
  local status=$1
  shift
  complain "$@"
  exit "$status"
}

# usage: prints how to run the script.
usage() {
  echo "usage: Scripts/set-version.sh <version>   (for example 0.2.0, or: make set-version VERSION=0.2.0)"
  echo "       Scripts/set-version.sh --selftest"
}

# cleanup: the exit trap. It removes the temporary files a run made, however
# the run ended.
cleanup() {
  if [[ -n $NEW_FILE ]]; then
    rm -f "$NEW_FILE"
  fi
  if [[ -n $BACKUP_FILE ]]; then
    rm -f "$BACKUP_FILE"
  fi
}

# strip_zeros <digits>: prints a string of digits without its leading zeros,
# and "0" for a string of zeros.
strip_zeros() {
  local digits=${1#"${1%%[!0]*}"}
  printf '%s' "${digits:-0}"
}

# compare_numbers <a> <b>: prints -1, 0, or 1 as the whole number <a> is less
# than, equal to, or greater than <b>. Both are strings of digits, compared
# as text (the longer one is greater, and equal lengths character by
# character) so that no number can overflow the shell's arithmetic.
compare_numbers() {
  local a b
  a=$(strip_zeros "$1")
  b=$(strip_zeros "$2")
  if (( ${#a} < ${#b} )); then
    printf '%s\n' -1
  elif (( ${#a} > ${#b} )); then
    printf '%s\n' 1
  elif [[ $a == "$b" ]]; then
    printf '%s\n' 0
  elif [[ $a < $b ]]; then
    printf '%s\n' -1
  else
    printf '%s\n' 1
  fi
}

# version_is_later <new> <old>: succeeds when version <new> comes after
# version <old>. Both are three numbers joined by dots. The numbers are
# compared left to right, each as a number, so 0.10.0 is later than 0.9.0.
version_is_later() {
  local -a new old
  local i order
  IFS=. read -r -a new <<<"$1"
  IFS=. read -r -a old <<<"$2"
  for i in 0 1 2; do
    order=$(compare_numbers "${new[i]}" "${old[i]}")
    if [[ $order != 0 ]]; then
      [[ $order == 1 ]]
      return
    fi
  done
  return 1 # the same version is not a later one
}

# is_version_line <line>: succeeds when <line> sets MARKETING_VERSION in the
# form this script reads and writes (VERSION_LINE_RE), with its quotes
# matching: both present or both absent. It leaves the line's parts in
# BASH_REMATCH, as VERSION_LINE_RE numbers them.
is_version_line() {
  [[ $1 =~ $VERSION_LINE_RE ]] || return 1
  [[ ${BASH_REMATCH[2]} == "${BASH_REMATCH[4]}" ]]
}

# read_current_version <file>: prints the version that <file> sets as
# MARKETING_VERSION. It fails, saying why on standard error, unless the file
# sets it on exactly one line, in the form this script can also write.
read_current_version() {
  local file=$1 line number=0 count=0 numbers="" first=""
  # Find every line that sets the key, wherever it is, so that a second
  # setting (one for another target, say) is noticed instead of left behind.
  # The "|| [[ -n $line ]]" also reads a last line that has no newline.
  while IFS= read -r line || [[ -n $line ]]; do
    number=$(( number + 1 ))
    if [[ $line =~ $VERSION_KEY_RE ]]; then
      count=$(( count + 1 ))
      numbers="$numbers${numbers:+, }$number"
      if [[ -z $first ]]; then
        first=$line
      fi
    fi
  done < "$file"

  if (( count == 0 )); then
    complain "$file does not set MARKETING_VERSION"
    return 1
  elif (( count > 1 )); then
    complain "$file sets MARKETING_VERSION on $count lines ($numbers), and this script changes exactly one"
    return 1
  fi
  if ! is_version_line "$first"; then
    complain "line $numbers of $file is not a version of three numbers, such as MARKETING_VERSION: \"0.2.0\": $first"
    return 1
  fi
  printf '%s\n' "${BASH_REMATCH[3]}"
}

# version_line_with <line> <version>: prints <line> with its version replaced
# by <version> when it is the MARKETING_VERSION line, and as it was
# otherwise. It prints no newline.
version_line_with() {
  local line=$1 version=$2
  if is_version_line "$line"; then
    # Keep the text before the value, its quotes, and what follows it.
    printf '%s%s%s%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "$version" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
  else
    printf '%s' "$line"
  fi
}

# write_version <input> <output> <version>: writes to <output> a copy of the
# file <input> in which MARKETING_VERSION is <version>. Every other byte is
# copied as it was, including a last line that has no newline.
write_version() {
  local input=$1 output=$2 version=$3 line
  {
    while IFS= read -r line; do
      version_line_with "$line" "$version"
      printf '\n'
    done
    # The loop ends when read fails. At the end of a file that ends with a
    # newline, $line is then empty; if the last line has no newline, $line
    # holds its text, which still needs writing, without a newline.
    if [[ -n $line ]]; then
      version_line_with "$line" "$version"
    fi
  } < "$input" > "$output"
}

# set_version <version>: the script's work. It checks <version> against the
# one in project.yml, rewrites that one setting, and regenerates the project.
set_version() {
  local version=$1 current written

  # The new version must be of the right form.
  if [[ -z $version ]]; then
    die 2 "no version given. For example: Scripts/set-version.sh 0.2.0 (or: make set-version VERSION=0.2.0)"
  fi
  if [[ ! $version =~ $NEW_VERSION_RE ]]; then
    die 2 "'$version' is not a version of the form MAJOR.MINOR.PATCH: three whole numbers joined by dots, none with a leading zero, such as 0.2.0"
  fi

  # It must be later than the current one.
  [[ -f $PROJECT_YML ]] || die 1 "there is no project.yml at $PROJECT_YML"
  current=$(read_current_version "$PROJECT_YML") || exit 1
  if [[ $version == "$current" ]]; then
    die 1 "$version is already the current version"
  fi
  if ! version_is_later "$version" "$current"; then
    die 1 "$version is not later than the current version, $current"
  fi

  # xcodegen is needed after the change, so check for it before making one.
  command -v xcodegen >/dev/null 2>&1 ||
    die 1 "xcodegen is not installed (brew install xcodegen), and the project must be regenerated, so nothing was changed"

  say "Old version: $current"
  say "New version: $version"

  # Write the new project.yml beside the old one, with the old one's mode (a
  # temporary file is private), check it, and move it into place in one step.
  # The old one is kept in a backup until xcodegen has succeeded.
  trap cleanup EXIT
  BACKUP_FILE=$(mktemp "${TMPDIR:-/tmp}/textmouth-set-version-backup.XXXXXX") ||
    die 1 "could not make a temporary file"
  cp -p "$PROJECT_YML" "$BACKUP_FILE" || die 1 "could not copy project.yml to $BACKUP_FILE"
  NEW_FILE=$(mktemp "$PROJECT_YML.XXXXXX") || die 1 "could not make a temporary file beside project.yml"
  cp -p "$PROJECT_YML" "$NEW_FILE" || die 1 "could not copy project.yml to $NEW_FILE"
  write_version "$PROJECT_YML" "$NEW_FILE" "$version" || die 1 "could not write $NEW_FILE"
  # The copy must read back as the new version and have as many lines as the
  # old file: only the value of that one line has changed.
  written=$(read_current_version "$NEW_FILE") || exit 1
  if [[ $written != "$version" ]] || (( $(wc -l < "$NEW_FILE") != $(wc -l < "$PROJECT_YML") )); then
    die 1 "the rewritten project.yml was not as expected, so nothing was changed"
  fi
  mv "$NEW_FILE" "$PROJECT_YML" || die 1 "could not replace project.yml"
  NEW_FILE="" # moved into place; nothing is left to remove

  # Regenerate the project from the new project.yml, as `make generate` does.
  # If xcodegen fails, put project.yml back, so that it never claims a version
  # the project does not carry.
  say "Regenerating the Xcode project..."
  if ! (cd "$ROOT" && xcodegen generate); then
    if cp -p "$BACKUP_FILE" "$PROJECT_YML"; then
      die 1 "xcodegen failed, so project.yml is back at version $current. If TextMouth.xcodeproj changed, run make generate."
    fi
    # The old project.yml could not be put back: keep its backup.
    complain "xcodegen failed, and project.yml could not be put back at version $current; its copy is $BACKUP_FILE"
    BACKUP_FILE=""
    exit 1
  fi
  say "Done. Nothing is committed: commit project.yml with the regenerated TextMouth.xcodeproj."
}

# ---------------------------------------------------------------------------
# --selftest
#
# Every case copies this script into a fresh sandbox folder that stands for
# the repository, together with a project.yml: a copy of the real one, or a
# small made-up one. It puts a stand-in xcodegen first on PATH, runs the copy
# there, and checks its exit status, its report, the project.yml it leaves,
# and how it called xcodegen. The copy finds its repository from its own
# location, so it can change only the sandbox's project.yml, and the stand-in
# is the only xcodegen it can reach: no case can touch the real project.yml
# or regenerate the real project. The last cases check that the Makefile runs
# the script and this selftest, with make -n, which runs nothing.
#
# Output: one "ok" or "not ok" line per case, with the reasons and the
# script's report under each failure, then the totals.
# ---------------------------------------------------------------------------

passed=0
failed=0
case_name=""     # description of the case in progress
case_problems="" # reasons the case in progress fails, one per line
sandbox=""       # the case's stand-in for the repository ("" for a case with none)
fixture=""       # the project.yml the case started from
stub_log=""      # where the stand-in xcodegen records its calls
output=""        # the report of the script or of make: standard output and error together
status=0         # its exit status
WORK=""          # the selftest's temporary folder
STUBS=""         # the folder holding the stand-in xcodegen
FIXTURES=""      # the made-up project.yml files and the files the cases expect

# write_stub: creates the stand-in xcodegen. It records the folder it ran in
# and its arguments, prints a line, and exits with STUB_STATUS (default 0).
write_stub() {
  mkdir -p "$STUBS"
  cat > "$STUBS/xcodegen" <<'STUB'
#!/bin/bash
# Stand-in xcodegen for set-version.sh --selftest.
printf 'cwd=%s args=%s\n' "$(pwd -P)" "$*" >> "$STUB_LOG"
echo "stand-in xcodegen: generated nothing"
exit "${STUB_STATUS:-0}"
STUB
  chmod +x "$STUBS/xcodegen"
}

# fixture_path <name> <version line> [crlf|nofinal]: creates a small made-up
# project.yml, FIXTURES/<name>.yml, and prints its path. <version line> is the
# line that sets the version, in full. Around it are lines that must never
# change: a commented-out copy of the setting, settings beside it, and a
# setting that holds the digits 0.9.0, the version many cases start from. With
# crlf the lines end with CR LF, and with nofinal the last line has no newline.
fixture_path() {
  local version_line=$2 style=${3:-} eol line content file
  file="$FIXTURES/$1.yml"
  eol=$'\n'
  if [[ $style == crlf ]]; then
    eol=$'\r\n'
  fi
  for line in \
    'name: TextMouth' \
    'targets:' \
    '  TextMouth:' \
    '    settings:' \
    '      base:' \
    '        PRODUCT_NAME: TextMouth' \
    '        # MARKETING_VERSION: "0.0.1"' \
    "$version_line" \
    '        CURRENT_PROJECT_VERSION: "1"' \
    '        DOCS_VERSION: "0.9.0"'; do
    printf '%s%s' "$line" "$eol"
  done > "$file"
  if [[ $style == nofinal ]]; then
    # Command substitution drops the one newline at the end of the file.
    content=$(cat "$file")
    printf '%s' "$content" > "$file"
  fi
  printf '%s\n' "$file"
}

# begin_case <description> <project.yml to start from>: starts a case in a
# fresh sandbox holding a copy of this script and a copy of that project.yml.
begin_case() {
  case_name=$1
  case_problems=""
  fixture=$2
  sandbox="$WORK/case-$(( passed + failed + 1 ))"
  # The stand-in's log is kept beside the sandbox, not in it, so that the
  # sandbox holds only what the script could touch.
  stub_log="$sandbox.xcodegen.log"
  mkdir -p "$sandbox/Scripts"
  cp "$SELF" "$sandbox/Scripts/set-version.sh"
  chmod +x "$sandbox/Scripts/set-version.sh"
  cp "$fixture" "$sandbox/project.yml"
  : > "$stub_log"
}

# begin_check <description>: starts a case that needs no sandbox.
begin_check() {
  case_name=$1
  case_problems=""
  sandbox=""
}

# run_script [NAME=value...] [-- arguments...]: runs the sandbox's copy of the
# script with the stand-in first on PATH and the temporary folder of the
# selftest as TMPDIR, so that any temporary file the script leaves can be
# seen. NAME=value settings come after, so they can replace those (STUB_STATUS
# is the stand-in's exit status). Two settings are the case's own and are not
# passed on: RUN_DIR is the folder to run from, by default the selftest's own
# temporary folder, which is not the sandbox, and RUN_CMD is the command to
# run, by default the sandbox script's absolute path. The script must
# therefore find its repository from where it is, not from where it is run.
# Stores the report in $output and the exit status in $status.
run_script() {
  local -a settings=()
  local run_dir=$WORK run_cmd="$sandbox/Scripts/set-version.sh"
  while [[ $# -gt 0 && $1 != -- ]]; do
    case $1 in
      RUN_DIR=*) run_dir=${1#RUN_DIR=} ;;
      RUN_CMD=*) run_cmd=${1#RUN_CMD=} ;;
      *) settings+=("$1") ;;
    esac
    shift
  done
  if [[ $# -gt 0 ]]; then
    shift
  fi
  output=$(cd "$run_dir" && env PATH="$STUBS:$PATH" STUB_LOG="$stub_log" TMPDIR="$WORK/tmp" \
      ${settings[@]+"${settings[@]}"} "$run_cmd" "$@" 2>&1)
  status=$?
}

# problem <reason>: records why the case in progress fails.
problem() {
  case_problems+="    $1"$'\n'
}

# expect_status <number>: the run must have exited with <number>.
expect_status() {
  [[ $status -eq $1 ]] || problem "exit status was $status, expected $1"
}

# expect_report <text>: the report must contain <text>.
expect_report() {
  grep -F -q -- "$1" <<<"$output" || problem "the report lacks: $1"
}

# expect_unchanged: the sandbox's project.yml must be the one the case started
# from, byte for byte.
expect_unchanged() {
  cmp -s "$fixture" "$sandbox/project.yml" || problem "project.yml was changed"
}

# expect_project <file>: the sandbox's project.yml must be <file>, byte for
# byte.
expect_project() {
  cmp -s "$1" "$sandbox/project.yml" || problem "project.yml is not $(basename "$1") (diff: $(diff "$1" "$sandbox/project.yml" | head -n 6 | tr '\n' '|'))"
}

# expect_calls <number>: the stand-in xcodegen must have been run <number>
# times.
expect_calls() {
  local calls
  calls=$(( $(wc -l < "$stub_log") ))
  (( calls == $1 )) || problem "xcodegen was run $calls times, expected $1"
}

# expect_call <line>: the stand-in must have recorded <line> for a call.
expect_call() {
  grep -F -x -q -- "$1" "$stub_log" || problem "xcodegen was not run as: $1"
}

# end_case: checks what holds for every case with a sandbox, that the script
# left nothing behind (no temporary file in the sandbox or in TMPDIR), then
# prints the case's verdict, and under a failure its reasons and the report.
end_case() {
  local number=$(( passed + failed + 1 )) line listing
  if [[ -n $sandbox ]]; then
    listing=$(cd "$sandbox" && ls -A | tr '\n' ' ')
    [[ $listing == "Scripts project.yml " ]] || problem "the sandbox holds: $listing"
    listing=$(ls -A "$WORK/tmp" | tr '\n' ' ')
    [[ -z $listing ]] || problem "temporary files were left behind: $listing"
  fi
  if [[ -z $case_problems ]]; then
    passed=$(( passed + 1 ))
    printf 'ok %d - %s\n' "$number" "$case_name"
  else
    failed=$(( failed + 1 ))
    printf 'not ok %d - %s\n%s' "$number" "$case_name" "$case_problems"
    printf '    report:\n'
    while IFS= read -r line; do
      printf '      %s\n' "$line"
    done <<<"$output"
  fi
}

# refusal_case <description> <fixture> <version> <status> <report text>: a case
# in which running the script with <version> must be refused with <status>,
# saying <report text>, changing nothing and never calling xcodegen.
refusal_case() {
  begin_case "$1" "$2"
  run_script -- "$3"
  expect_status "$4"
  expect_report "$5"
  expect_unchanged
  expect_calls 0
  end_case
}

# raise_case <description> <fixture> <version> <expected file>: a case in which
# running the script with <version> must succeed, leave exactly <expected
# file> as project.yml, and run xcodegen once, in the sandbox, to generate.
raise_case() {
  begin_case "$1" "$2"
  run_script -- "$3"
  expect_status 0
  expect_report "New version: $3"
  expect_project "$4"
  expect_calls 1
  expect_call "cwd=$sandbox args=generate"
  end_case
}

# version_line <version>: prints the made-up fixtures' usual version line.
version_line() {
  printf '        MARKETING_VERSION: "%s"\n' "$1"
}

# real_project_cases: the script on a copy of the real project.yml, whose
# current version the cases read and build theirs from, so that they hold
# whatever the version is.
real_project_cases() {
  local current major minor patch next lower expected

  begin_check "the real project.yml sets MARKETING_VERSION once, in the form the script reads"
  if ! current=$(read_current_version "$ROOT/project.yml" 2>&1); then
    output=$current
    problem "read_current_version failed"
    end_case
    return
  fi
  output=""
  end_case
  IFS=. read -r major minor patch <<<"$current"

  # The next minor version (0.1.1 to 0.2.0), and a lower one when there is one.
  next="$major.$(( 10#$minor + 1 )).0"
  if (( 10#$patch > 0 )); then
    lower="$major.$minor.$(( 10#$patch - 1 ))"
  elif (( 10#$minor > 0 )); then
    lower="$major.$(( 10#$minor - 1 )).0"
  elif (( 10#$major > 0 )); then
    lower="$(( 10#$major - 1 )).0.0"
  else
    lower=""
  fi

  # What the real project.yml must become: the same file, with the version on
  # its one setting replaced.
  expected="$FIXTURES/real-expected.yml"
  sed -E "s/^([[:space:]]*MARKETING_VERSION:[[:space:]]*\"?)$current(\"?[[:space:]]*(#.*)?)\$/\\1$next\\2/" \
    "$ROOT/project.yml" > "$expected"
  cmp -s "$expected" "$ROOT/project.yml" && {
    begin_check "the selftest can build the file it expects"
    problem "replacing $current by $next in the real project.yml changed nothing"
    end_case
  }

  begin_case "raises $current to $next in a copy of the real project.yml, changing that one line and keeping the file's mode" "$ROOT/project.yml"
  chmod 640 "$sandbox/project.yml"
  run_script -- "$next"
  expect_status 0
  expect_report "Old version: $current"
  expect_report "New version: $next"
  expect_report "Nothing is committed"
  expect_project "$expected"
  [[ $(stat -f %Lp "$sandbox/project.yml") == 640 ]] || problem "project.yml's mode is not 640"
  expect_calls 1
  expect_call "cwd=$sandbox args=generate"
  end_case

  # make runs the script from the repository root by its relative path.
  begin_case "runs from the repository root by its relative path, as make runs it" "$ROOT/project.yml"
  run_script RUN_DIR="$sandbox" RUN_CMD=Scripts/set-version.sh -- "$next"
  expect_status 0
  expect_project "$expected"
  expect_calls 1
  expect_call "cwd=$sandbox args=generate"
  end_case

  refusal_case "refuses the current version, $current, again" "$ROOT/project.yml" "$current" 1 "already the current version"
  if [[ -n $lower ]]; then
    refusal_case "refuses $lower, which is lower than $current" "$ROOT/project.yml" "$lower" 1 "not later than the current version, $current"
  fi
}

# comparison_cases: versions are compared as numbers, one at a time, and not
# as text.
comparison_cases() {
  local nine ten big zero
  nine=$(fixture_path nine "$(version_line 0.9.0)")
  ten=$(fixture_path ten "$(version_line 0.10.0)")
  raise_case "0.10.0 is later than 0.9.0" "$nine" 0.10.0 "$ten"
  refusal_case "0.9.0 is not later than 0.10.0" "$ten" 0.9.0 1 "not later than the current version, 0.10.0"
  raise_case "1.0.0 is later than 0.99.99" "$(fixture_path pre-one "$(version_line 0.99.99)")" 1.0.0 \
    "$(fixture_path one "$(version_line 1.0.0)")"
  refusal_case "0.1.99 is not later than 0.2.0" "$(fixture_path two "$(version_line 0.2.0)")" 0.1.99 1 "not later than"
  # Numbers beyond 64 bits would wrap around in the shell's arithmetic: 2 to
  # the 64th power, 18446744073709551616, would count as 0, below 1.
  big=$(fixture_path big "$(version_line 0.0.18446744073709551616)")
  raise_case "0.0.18446744073709551616 is later than 0.0.1" "$(fixture_path small "$(version_line 0.0.1)")" 0.0.18446744073709551616 "$big"
  refusal_case "0.0.1 is not later than 0.0.18446744073709551616" "$big" 0.0.1 1 "not later than"
  # A leading zero that was typed by hand into project.yml is no part of the
  # number: 0.02.0 is 0.2.0.
  zero=$(fixture_path zero "$(version_line 0.02.0)")
  refusal_case "0.2.0 is not later than 0.02.0, which is the same version" "$zero" 0.2.0 1 "not later than the current version, 0.02.0"
  raise_case "0.3.0 is later than 0.02.0" "$zero" 0.3.0 "$(fixture_path three "$(version_line 0.3.0)")"
  refusal_case "0.1.0 is not later than 0.02.0" "$zero" 0.1.0 1 "not later than the current version, 0.02.0"
}

# form_cases: what is not three whole numbers joined by dots, without leading
# zeros, is refused as a usage error, before anything is read or changed.
form_cases() {
  local bad
  begin_case "refuses a version that is not MAJOR.MINOR.PATCH, changing nothing and not running xcodegen" "$(fixture_path form "$(version_line 0.1.1)")"
  for bad in 1.0 0.2 v0.2.0 0.2.0-beta 0.2.0.1 0.2.x 1..0 .1.0 0.2.0. ' 0.2.0' '0.2.0 ' 02.0.0 0.2.00 -1.0.0 1,2,3 $'0.2.0\n' 0.2.0+5 '0.2.0 0.3.0'; do
    run_script -- "$bad"
    [[ $status -eq 2 ]] || problem "'$bad' was not refused with status 2 (status $status)"
    grep -F -q "is not a version of the form MAJOR.MINOR.PATCH" <<<"$output" || problem "'$bad' was refused without saying why"
    expect_unchanged
  done
  expect_calls 0
  end_case

  refusal_case "refuses an empty version, as make set-version does without VERSION" "$(fixture_path empty "$(version_line 0.1.1)")" "" 2 "no version given"

  begin_case "prints its usage for no version, and for two" "$(fixture_path usage "$(version_line 0.1.1)")"
  run_script --
  expect_status 2
  expect_report "usage: Scripts/set-version.sh <version>"
  run_script -- 0.2.0 0.3.0
  expect_status 2
  expect_report "usage: Scripts/set-version.sh <version>"
  expect_unchanged
  expect_calls 0
  end_case

  begin_case "prints its usage for --help, and succeeds" "$(fixture_path help "$(version_line 0.1.1)")"
  run_script -- --help
  expect_status 0
  expect_report "usage: Scripts/set-version.sh <version>"
  expect_unchanged
  expect_calls 0
  end_case
}

# rewrite_cases: only the value changes. Quotes, a trailing comment, line
# ends, and the lack of a newline at the end of the file stay as they were,
# and so does every other line, even one holding the same digits.
rewrite_cases() {
  raise_case "keeps a value without quotes" "$(fixture_path bare '        MARKETING_VERSION: 0.9.0')" 0.10.0 \
    "$(fixture_path bare-expected '        MARKETING_VERSION: 0.10.0')"
  raise_case "keeps the comment after the value" "$(fixture_path comment '        MARKETING_VERSION: "0.9.0"   # the beta version')" 0.10.0 \
    "$(fixture_path comment-expected '        MARKETING_VERSION: "0.10.0"   # the beta version')"
  raise_case "keeps CR LF line ends" "$(fixture_path crlf "$(version_line 0.9.0)" crlf)" 0.10.0 \
    "$(fixture_path crlf-expected "$(version_line 0.10.0)" crlf)"
  raise_case "keeps a last line that has no newline" "$(fixture_path nofinal "$(version_line 0.9.0)" nofinal)" 0.10.0 \
    "$(fixture_path nofinal-expected "$(version_line 0.10.0)" nofinal)"
  # A file that is only the version line, with no newline after it: the line
  # that holds the version is then the last line, the one with no newline.
  printf '%s' "$(version_line 0.9.0)" > "$FIXTURES/only-line.yml"
  printf '%s' "$(version_line 0.10.0)" > "$FIXTURES/only-line-expected.yml"
  raise_case "changes a version that is on the last line, which has no newline" \
    "$FIXTURES/only-line.yml" 0.10.0 "$FIXTURES/only-line-expected.yml"
}

# unreadable_cases: a project.yml that does not set the version on exactly one
# line, in the form the script writes, is refused untouched.
unreadable_cases() {
  refusal_case "refuses a project.yml with no MARKETING_VERSION setting" \
    "$(fixture_path none '        # MARKETING_VERSION: "0.9.0"')" 0.10.0 1 "does not set MARKETING_VERSION"
  refusal_case "refuses a project.yml that sets MARKETING_VERSION twice" \
    "$(fixture_path twice "$(version_line 0.9.0)"$'\n'"$(version_line 0.8.0)")" 0.10.0 1 "sets MARKETING_VERSION on 2 lines (8, 9)"
  refusal_case "refuses a version of two numbers in project.yml" \
    "$(fixture_path short "$(version_line 1.0)")" 1.1.0 1 "is not a version of three numbers"
  refusal_case "refuses a single-quoted version in project.yml" \
    "$(fixture_path single "        MARKETING_VERSION: '0.9.0'")" 0.10.0 1 "is not a version of three numbers"
  refusal_case "refuses a version with only one quote in project.yml" \
    "$(fixture_path onequote '        MARKETING_VERSION: "0.9.0')" 0.10.0 1 "is not a version of three numbers"
}

# xcodegen_cases: what the script does when xcodegen fails or is missing.
xcodegen_cases() {
  local nine
  nine=$(fixture_path xnine "$(version_line 0.9.0)")

  begin_case "puts project.yml back when xcodegen fails" "$nine"
  run_script STUB_STATUS=1 -- 0.10.0
  expect_status 1
  expect_report "xcodegen failed, so project.yml is back at version 0.9.0"
  expect_unchanged
  expect_calls 1
  end_case

  begin_case "stops before changing anything when xcodegen is not installed" "$nine"
  run_script PATH="$WORK/no-tools:/usr/bin:/bin:/usr/sbin:/sbin" -- 0.10.0
  expect_status 1
  expect_report "xcodegen is not installed"
  expect_unchanged
  expect_calls 0
  end_case
}

# makefile_cases: the Makefile runs this script for make set-version, runs
# this selftest in make check-selftest, and lists set-version in its help.
# make -n prints what a target would run and runs none of it.
makefile_cases() {
  local real_make
  real_make=$(command -v make) || {
    begin_check "the Makefile cases need make"
    problem "make was not found"
    end_case
    return
  }
  mkdir -p "$WORK/make"
  cp "$ROOT/Makefile" "$WORK/make/Makefile"

  begin_check "make -n set-version VERSION=0.2.0 runs the script with that version"
  output=$(cd "$WORK/make" && "$real_make" -n set-version VERSION=0.2.0 2>&1)
  status=$?
  expect_status 0
  expect_report 'Scripts/set-version.sh "0.2.0"'
  end_case

  begin_check "make -n check-selftest runs this selftest"
  output=$(cd "$WORK/make" && "$real_make" -n check-selftest 2>&1)
  status=$?
  expect_status 0
  expect_report "Scripts/set-version.sh --selftest"
  end_case

  begin_check "make help lists set-version"
  output=$(cd "$WORK/make" && "$real_make" help 2>&1)
  status=$?
  expect_status 0
  expect_report "make set-version VERSION=0.2.0"
  end_case
}

# selftest: runs every case and prints the totals; succeeds only when all
# pass.
selftest() {
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/textmouth-set-version-selftest.XXXXXX") || return 1
  # Its physical path, as the script names its folders: the temporary folder
  # is reached through the /var link to /private/var.
  WORK=$(cd "$WORK" && pwd -P) || return 1
  trap 'rm -rf "${WORK:?}"' EXIT
  STUBS="$WORK/stubs"
  FIXTURES="$WORK/fixtures"
  mkdir -p "$FIXTURES" "$WORK/tmp"
  write_stub

  real_project_cases
  comparison_cases
  form_cases
  rewrite_cases
  unreadable_cases
  xcodegen_cases
  makefile_cases
  printf '%d passed, %d failed\n' "$passed" "$failed"
  (( failed == 0 ))
}

# main <arguments>: runs the self-test, prints the usage, or sets the version.
main() {
  if [[ $# -eq 1 && $1 == --selftest ]]; then
    selftest
    return
  fi
  if [[ $# -eq 1 && ( $1 == -h || $1 == --help ) ]]; then
    usage
    return 0
  fi
  if [[ $# -ne 1 ]]; then
    usage >&2
    return 2
  fi
  set_version "$1"
}

# bash reads a script as it runs it. Exiting on the same line as main means a
# run never reads past this point, even if the file is edited mid-run.
main "$@"; exit $?
