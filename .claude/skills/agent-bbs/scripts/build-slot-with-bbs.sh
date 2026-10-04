#!/bin/bash
# Runs one command while holding one of a fixed number of machine-wide build
# slots, so several agents can work at once without more than SLOTS xcodebuild
# processes competing for this 8 GB Mac's memory. Slots are directories made
# atomically with mkdir; a slot is released on exit, including on signals, and
# a slot older than STALE_SECONDS whose owner process is gone is reclaimed.
#
# This is the orchestrator's build-slot.sh, with the same lock, plus hooks
# into the agent message board (bbs.py, beside this script). When BBS_AGENT
# names a registered board agent, the wrapper:
#   * prints that agent's unread board messages on stderr before it waits for
#     a slot, leaving them unread so `bbs.py inbox NAME --unread` still shows
#     them (build output usually goes to a log nobody reads in full);
#   * sets the agent's activity to "building", with the command as its note,
#     once it holds a slot, and back to "idle" when it exits.
# With BBS_AGENT unset the hooks are skipped silently. A board problem (an
# unregistered name, say) is reported once on stderr, switches the hooks off
# for the rest of the run, and never stops the build.
#
# Usage: [BBS_AGENT=<name>] build-slot-with-bbs.sh <command...>
# BUILD_SLOT_ROOT overrides the slot directory. The default is the directory
# build-slot.sh uses, so both wrappers share the same three slots.
SLOT_ROOT=${BUILD_SLOT_ROOT:-/tmp/textmouth-build-slots}
SLOTS=3
STALE_SECONDS=2400
BBS_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bbs.py"
mkdir -p "$SLOT_ROOT"
held=""
building=""

# board_failed <message>: report a board error once and switch the hooks off.
board_failed() {
  echo "[build-slot] board hooks off for this run: $1" >&2
  BBS_AGENT=""
}

# show_unread: print the agent's unread board messages, leaving them unread.
# `watch --once` exits with 0 when nothing is unread and 2 when it printed.
show_unread() {
  [ -n "$BBS_AGENT" ] || return 0
  local output
  output=$(python3 "$BBS_PY" watch "$BBS_AGENT" --once --peek 2>&1)
  case $? in
    0) ;;
    2) echo "[build-slot] unread board messages for $BBS_AGENT (still unread; read them with bbs.py inbox $BBS_AGENT --unread):" >&2
       printf '%s\n' "$output" >&2 ;;
    *) board_failed "$output" ;;
  esac
}

# set_activity <activity> [--note=TEXT]: set the agent's board activity.
# Returns non-zero when the hooks are off or the board refused.
set_activity() {
  [ -n "$BBS_AGENT" ] || return 1
  local output
  output=$(python3 "$BBS_PY" activity "$BBS_AGENT" "$@" 2>&1) || { board_failed "$output"; return 1; }
}

release() {
  [ -n "$held" ] && rm -rf "$held"
  held=""
  if [ -n "$building" ]; then
    building=""
    set_activity idle
  fi
}
trap 'release; exit 130' INT TERM
trap 'release' EXIT

if [ -n "$BBS_AGENT" ] && ! command -v python3 > /dev/null 2>&1; then
  board_failed "python3 was not found"
fi
show_unread

while [ -z "$held" ]; do
  for i in $(seq 1 $SLOTS); do
    slot="$SLOT_ROOT/slot$i"
    if mkdir "$slot" 2>/dev/null; then
      echo $$ > "$slot/pid"; held="$slot"; break
    fi
    # Reclaim a slot whose owner died or that is implausibly old.
    if [ -f "$slot/pid" ]; then
      owner=$(cat "$slot/pid" 2>/dev/null)
      age=$(( $(date +%s) - $(stat -f %m "$slot" 2>/dev/null || echo 0) ))
      if ! kill -0 "$owner" 2>/dev/null || [ "$age" -gt "$STALE_SECONDS" ]; then
        rm -rf "$slot"
      fi
    fi
  done
  [ -z "$held" ] && sleep 15
done
echo "[build-slot] acquired $(basename "$held") at $(date '+%H:%M:%S')" >&2

# The note is the command line, cut to stay within the board's one-line limit.
command_line="$*"
if set_activity building "--note=${command_line:0:180}"; then
  building=1
fi
"$@"
status=$?
release
exit $status
