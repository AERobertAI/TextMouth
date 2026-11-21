#!/bin/bash
# merge-chain.sh: merge the named branches into main one after another. Each
# merge stops before it commits so the docs lint can check the merged tree; the
# full hosted suite (through the build-slot wrapper) then runs after the commit,
# and the chain stops at the first lint or suite that is not green. Run it from
# any folder of the main checkout; it changes to the repository root itself.
#
# Usage: Scripts/agents/merge-chain.sh <branch>:<message-file> [<branch>:<message-file> ...]
#   <message-file> holds the merge commit's message (a subject line, a blank
#   line, a paragraph saying what the branch does, and the Co-Authored-By
#   trailer); the merge is a non-squash merge (--no-ff), which the user
#   authorized for main, so every branch commit is kept.
#
# Environment:
#   MERGE_LOG_DIR       where each merge's log goes (default build/merge-logs)
#   MERGE_DERIVED_DATA  the build folder for main's suite (default build/DerivedData-main);
#                       delete it between merges when the disk is tight, and
#                       unregister its app first (see AGENTS.md)
#   MERGE_CO_AUTHOR     the Co-Authored-By trailer of a commit the chain makes
#                       itself (a regenerated project), naming the model the
#                       orchestrator runs on (default Claude Opus 5.5)
#
# A conflict in TextMouth.xcodeproj/project.pbxproj alone is resolved by
# regenerating the project with xcodegen (staged, then committed with the
# merge); any other conflict aborts the merge and stops the chain.
#
# Before the commit, when the merged tree has the doc-library skill, the docs
# lint runs on it (doclib.py lint --against HEAD). The log gets DOCS_LINT_OK,
# or DOCS_LINT_SKIPPED when the tree has no skill; on DOCS_LINT_FAILED the
# merge is aborted, the branch is left where it was, and the chain stops.
#
# Then, when the merged tree has the issue-library skill, its check runs too,
# since an issue file merged without its driver can keep a header line twice or
# mix two comments. It is a ratchet, as the lint is: the check's problems on main
# are written down before the merge, and the merged tree fails only on a problem
# that is new and in a file the merge changed (issuelib.py check --new-since).
# The log gets ISSUES_CHECK_OK, or ISSUES_CHECK_SKIPPED when the merged tree has
# no skill; on ISSUES_CHECK_FAILED the merge is aborted and the chain stops.
#
# Then, when the merged tree has the localization scanner (Scripts/l10n/scan.py),
# its lint runs on the merged tree (scan.py lint --base HEAD), since a branch
# that adds interface text that is not localized must not reach main. On
# success the baseline is lowered to match the merged code (scan.py lint
# --update-baseline) and Scripts/l10n/scan-baseline.json is staged into the
# merge itself, so main's baseline falls with every merge and no extra commit is
# made; branches never edit it. The log gets L10N_LINT_OK, or L10N_LINT_SKIPPED
# when the merged tree has no scanner; on L10N_LINT_FAILED the merge is aborted
# and the chain stops.
#
# A merge whose changed files all end in .md gets MARKDOWN_ONLY_NO_SUITE: it is
# committed and the chain goes on to the next branch with no project check and
# no suite, since the docs lint is the check on documentation.
# Any other merge then has its committed project checked against a fresh
# generation (a drifted one is regenerated and committed) and the suite run.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
LOG_DIR=${MERGE_LOG_DIR:-build/merge-logs}
DERIVED=${MERGE_DERIVED_DATA:-build/DerivedData-main}
CO_AUTHOR=${MERGE_CO_AUTHOR:-"Claude Opus 5.5 <noreply@anthropic.com>"}
WRAPPER=.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh
DOCLIB=.claude/skills/doc-library/scripts/doclib.py
ISSUELIB=.claude/skills/issue-library/scripts/issuelib.py
L10N_SCAN=Scripts/l10n/scan.py
L10N_BASELINE=Scripts/l10n/scan-baseline.json
mkdir -p "$LOG_DIR"

# summarize: print the lines of a merge's log that say how it went. The docs
# lint and markdown-only lines are always shown; the rest is the last few
# lines that match, since the suite writes many.
summarize() {
  local slug="$1" log="$2"
  echo "--- $slug ---"
  grep -E "^(DOCS_LINT_|ISSUES_CHECK_|L10N_LINT_|MARKDOWN_ONLY_)" "$log"
  grep -E "UNMERGED|ABORTING|RESOLVED|^[0-9a-f]{7,} |PBXPROJ_|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)|EXIT=|^Test Case '.*' failed" "$log" | tail -8
}

# merge_without_commit: start the merge of one branch and stop before it
# commits. A conflicted project file is regenerated with xcodegen and staged.
# Returns 0 with the merge in progress; 1 (the merge aborted) on a conflict in
# any other file or when the merge did not start; 2 when the branch is
# already merged, so there is nothing to commit.
merge_without_commit() {
  local branch="$1" log="$2"
  if git merge-base --is-ancestor "$branch" HEAD 2>/dev/null; then
    echo "ALREADY_MERGED: $branch" >> "$log"
    return 2
  fi
  git merge --no-ff --no-commit -q "$branch" >> "$log" 2>&1
  local unmerged
  unmerged=$(git diff --name-only --diff-filter=U)
  echo "UNMERGED=[$unmerged]" >> "$log"
  if [ -n "$unmerged" ] && [ "$unmerged" != "TextMouth.xcodeproj/project.pbxproj" ]; then
    echo "ABORTING: unexpected conflicts" >> "$log"
    git merge --abort
    return 1
  fi
  if [ -n "$unmerged" ]; then
    if xcodegen generate >> "$log" 2>&1 && git add TextMouth.xcodeproj/project.pbxproj; then
      echo "RESOLVED_PBXPROJ_VIA_XCODEGEN" >> "$log"
    else
      echo "ABORTING: could not regenerate the project" >> "$log"
      git merge --abort
      return 1
    fi
  fi
  # No merge in progress and no conflict: git refused to start (an unknown branch, say).
  if ! git rev-parse -q --verify MERGE_HEAD > /dev/null; then
    echo "ABORTING: the merge did not start" >> "$log"
    return 1
  fi
}

# lint_docs: run the docs lint on the merged, uncommitted tree. Logs
# DOCS_LINT_OK, DOCS_LINT_SKIPPED (no skill in the tree), or DOCS_LINT_FAILED,
# which aborts the merge and returns 1.
lint_docs() {
  local log="$1" lint_output status
  if [ ! -f "$DOCLIB" ]; then
    echo DOCS_LINT_SKIPPED >> "$log"
    return 0
  fi
  # -B: no bytecode next to the skill, where a forced git add would pick it up.
  lint_output=$(python3 -I -B "$DOCLIB" lint --against HEAD 2>&1)
  status=$?
  echo "$lint_output" >> "$log"
  if [ "$status" = 0 ]; then
    echo DOCS_LINT_OK >> "$log"
    return 0
  fi
  echo DOCS_LINT_FAILED >> "$log"
  # Say what got worse; the whole output is in the log.
  echo "$lint_output" | head -20
  git merge --abort
  return 1
}

# issues_snapshot: write the issue tracker's problems on the tree as it is now
# (main, before a merge) to a file, one JSON object a line; the file is empty
# when the tree has no issue-library skill.
issues_snapshot() {
  local snapshot="$1"
  : > "$snapshot"
  [ -f "$ISSUELIB" ] || return 0
  python3 -I -B "$ISSUELIB" check --json > "$snapshot" 2>/dev/null
  return 0
}

# check_issues: run the issue tracker's check on the merged, uncommitted tree,
# failing only problems not in the snapshot of main and in the files the merge
# changed. Logs ISSUES_CHECK_OK, ISSUES_CHECK_SKIPPED (no skill in the merged
# tree), or ISSUES_CHECK_FAILED, which aborts the merge and returns 1.
check_issues() {
  local log="$1" snapshot="$2" check_output status
  if [ ! -f "$ISSUELIB" ]; then
    echo ISSUES_CHECK_SKIPPED >> "$log"
    return 0
  fi
  check_output=$(python3 -I -B "$ISSUELIB" check --new-since "$snapshot" 2>&1)
  status=$?
  echo "$check_output" >> "$log"
  if [ "$status" = 0 ]; then
    echo ISSUES_CHECK_OK >> "$log"
    return 0
  fi
  echo ISSUES_CHECK_FAILED >> "$log"
  # Say what is wrong; the whole output is in the log.
  echo "$check_output" | head -20
  git merge --abort
  return 1
}

# lint_l10n: run the unlocalized-text lint on the merged, uncommitted tree, then
# lower the baseline to the merged code and stage it into the merge. The lint
# compares each file's count with the baseline and names the literals on the
# lines the merge adds (--base HEAD). Logs L10N_LINT_OK, L10N_LINT_SKIPPED (no
# scanner in the merged tree), or L10N_LINT_FAILED, which aborts the merge and
# returns 1; a baseline that cannot be lowered or staged fails the same way.
lint_l10n() {
  local log="$1" lint_output status
  if [ ! -f "$L10N_SCAN" ]; then
    echo L10N_LINT_SKIPPED >> "$log"
    return 0
  fi
  # -B: no bytecode next to the scanner, where a forced git add would pick it up.
  lint_output=$(python3 -I -B "$L10N_SCAN" lint --base HEAD 2>&1)
  status=$?
  if [ "$status" = 0 ]; then
    lint_output="$lint_output
$(python3 -I -B "$L10N_SCAN" lint --update-baseline 2>&1)"
    status=$?
  fi
  echo "$lint_output" >> "$log"
  if [ "$status" = 0 ] && git add "$L10N_BASELINE" >> "$log" 2>&1; then
    echo L10N_LINT_OK >> "$log"
    return 0
  fi
  echo L10N_LINT_FAILED >> "$log"
  # Say what is wrong; the whole output is in the log.
  echo "$lint_output" | head -20
  git merge --abort
  return 1
}

# merge_and_test: merge one branch with its message file, check the docs lint
# on the merged tree, commit, then (unless only Markdown changed) regenerate
# the project if it drifted and run the suite.
merge_and_test() {
  local branch="$1" message="$2"
  local slug; slug=$(basename "$branch")
  local log="$LOG_DIR/main-after-$slug-merge.log"
  : > "$log"
  echo "=== merging $branch at $(date +%H:%M:%S) ===" >> "$log"
  local snapshot="$LOG_DIR/main-before-$slug-issues.json"
  issues_snapshot "$snapshot"
  merge_without_commit "$branch" "$log"
  local merged=$?
  if [ "$merged" = 2 ]; then
    summarize "$slug" "$log"
    return 0
  fi
  [ "$merged" = 0 ] || return 1
  if ! lint_docs "$log"; then
    summarize "$slug" "$log"
    return 1
  fi
  if ! check_issues "$log" "$snapshot"; then
    summarize "$slug" "$log"
    return 1
  fi
  # The files this merge changes, one to a line: Markdown-only when there are some and all end in .md.
  # Taken before the baseline is lowered, so a lowered baseline alone does not make a suite run.
  local changed other
  changed=$(git diff --cached --name-only -z HEAD | tr '\0' '\n')
  other=$(echo "$changed" | grep -v '\.md$')
  if ! lint_l10n "$log"; then
    summarize "$slug" "$log"
    return 1
  fi
  git commit -q -F "$message" >> "$log" 2>&1 || { echo "ABORTING: the commit failed" >> "$log"; return 1; }
  if [ -n "$changed" ] && [ -z "$other" ]; then
    echo MARKDOWN_ONLY_NO_SUITE >> "$log"
    git log --oneline -1 >> "$log"
    summarize "$slug" "$log"
    return 0
  fi
  xcodegen generate >> "$log" 2>&1
  if git diff --quiet -- TextMouth.xcodeproj/project.pbxproj; then
    echo PBXPROJ_OK >> "$log"
  else
    git add TextMouth.xcodeproj/project.pbxproj \
      && git commit -q -m "Regenerate the Xcode project after the $slug merge

Co-Authored-By: $CO_AUTHOR" >> "$log" 2>&1 \
      && echo PBXPROJ_REGENERATED_AND_COMMITTED >> "$log"
  fi
  git log --oneline -1 >> "$log"
  "$WRAPPER" xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth \
    -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "$DERIVED" >> "$log" 2>&1
  local status=$?
  echo "EXIT=$status" >> "$log"
  summarize "$slug" "$log"
  [ "$status" = 0 ] && grep -q 'TEST SUCCEEDED' "$log"
}

for spec in "$@"; do
  branch="${spec%%:*}"
  message="${spec#*:}"
  if [ ! -f "$message" ]; then echo "no message file: $message"; exit 1; fi
  if ! merge_and_test "$branch" "$message"; then
    echo "CHAIN_STOPPED after $branch"
    exit 1
  fi
done
echo CHAIN_COMPLETE
