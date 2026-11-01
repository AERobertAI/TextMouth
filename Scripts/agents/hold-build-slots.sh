#!/bin/bash
# hold-build-slots.sh: hold every build slot, so the build train is the only builder.
#
# On October 31, 2026 the Mac (8 GB of memory) froze under the agents' builds
# and had to be restarted, and the user asked for one build at a time on a
# schedule. Scripts/agents/build-train.py builds outside the slots, so while
# it runs, this script holds all three slots of the board's wrapper
# (.claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh): an agent that
# tries to build on its own waits for a slot instead of starting a second
# build beside the train's.
#
# Each slot is taken with the wrapper's own mkdir lock as soon as it is free
# (a build already running keeps its slot until it ends), and touched every
# minute so the wrapper's 40-minute stale rule never reclaims it.
#
# Usage: hold-build-slots.sh RELEASE_FLAG
#   Run it as a background task. It ends, removing the slots it holds, once
#   the file RELEASE_FLAG exists (create it with `touch`), so the flag should
#   live in the orchestrator's scratch folder and not exist beforehand.

# The release flag is required: without one the slots could never be freed.
if [ $# -ne 1 ]; then
  echo "usage: hold-build-slots.sh RELEASE_FLAG" >&2
  exit 2
fi
RELEASE_FLAG=$1
if [ -e "$RELEASE_FLAG" ]; then
  echo "hold-build-slots: $RELEASE_FLAG exists already; remove it first" >&2
  exit 2
fi

# The same slot folder the wrapper uses, honouring its override.
SLOT_ROOT=${BUILD_SLOT_ROOT:-/tmp/textmouth-build-slots}
mkdir -p "$SLOT_ROOT"

# The numbers of the slots this script holds, space separated.
held=""
while [ ! -e "$RELEASE_FLAG" ]; do
  for i in 1 2 3; do
    slot="$SLOT_ROOT/slot$i"
    # A slot already held is touched, so it never looks stale.
    case " $held " in *" $i "*) touch "$slot"; continue ;; esac
    # mkdir is atomic: it succeeds only when no build holds the slot.
    if mkdir "$slot" 2>/dev/null; then
      echo $$ > "$slot/pid"
      held="$held $i"
      echo "holding slot$i from $(date '+%H:%M:%S')"
    fi
  done
  sleep 60
done

# Free only the slots this script took, never a build's.
for i in $held; do
  rm -r "$SLOT_ROOT/slot$i"
done
echo "released slots$held at $(date '+%H:%M:%S')"
