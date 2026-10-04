#!/bin/bash
# merge-chain.sh: merge the named branches into main one after another, running
# the full hosted suite (through the build-slot wrapper) after each merge and
# stopping at the first suite that is not green. Run it from any folder of the
# main checkout; it changes to the repository root itself.
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
#
# A conflict in TextMouth.xcodeproj/project.pbxproj alone is resolved by
# regenerating the project with xcodegen; any other conflict aborts the merge
# and stops the chain. The committed project must equal a fresh generation,
# so a drifted one is regenerated and committed before the suite runs.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
LOG_DIR=${MERGE_LOG_DIR:-build/merge-logs}
DERIVED=${MERGE_DERIVED_DATA:-build/DerivedData-main}
WRAPPER=.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh
mkdir -p "$LOG_DIR"

# merge_and_test: merge one branch with its message file, resolve a
# pbxproj-only conflict, regenerate the project if it drifted, run the suite.
merge_and_test() {
  local branch="$1" message="$2"
  local slug; slug=$(basename "$branch")
  local log="$LOG_DIR/main-after-$slug-merge.log"
  : > "$log"
  echo "=== merging $branch at $(date +%H:%M:%S) ===" >> "$log"
  git merge --no-ff "$branch" -q -F "$message" >> "$log" 2>&1
  local unmerged
  unmerged=$(git diff --name-only --diff-filter=U)
  echo "UNMERGED=[$unmerged]" >> "$log"
  if [ -n "$unmerged" ] && [ "$unmerged" != "TextMouth.xcodeproj/project.pbxproj" ]; then
    echo "ABORTING: unexpected conflicts" >> "$log"
    git merge --abort
    return 1
  fi
  if [ -n "$unmerged" ]; then
    xcodegen generate >> "$log" 2>&1 \
      && git add TextMouth.xcodeproj/project.pbxproj \
      && git commit -q --no-edit >> "$log" 2>&1 \
      && echo "RESOLVED_PBXPROJ_VIA_XCODEGEN" >> "$log"
  fi
  xcodegen generate >> "$log" 2>&1
  if git diff --quiet -- TextMouth.xcodeproj/project.pbxproj; then
    echo PBXPROJ_OK >> "$log"
  else
    git add TextMouth.xcodeproj/project.pbxproj \
      && git commit -q -m "Regenerate the Xcode project after the $slug merge

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>" >> "$log" 2>&1 \
      && echo PBXPROJ_REGENERATED_AND_COMMITTED >> "$log"
  fi
  git log --oneline -1 >> "$log"
  "$WRAPPER" xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth \
    -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
    COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath "$DERIVED" >> "$log" 2>&1
  local status=$?
  echo "EXIT=$status" >> "$log"
  echo "--- $slug ---"
  grep -E "UNMERGED|ABORTING|RESOLVED|^[0-9a-f]{7} |PBXPROJ_|Executed [0-9]+ tests, with|TEST (SUCCEEDED|FAILED)|EXIT=|^Test Case '.*' failed" "$log" | tail -8
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
