#!/bin/bash
# Runs Scripts/test/run-area.py for one member of team bughunt while it holds
# the team's build lock, so that at most one of the team's builds runs at a
# time, always in the team's one shared build folder (teams-common.md,
# "Builds": one build and one build folder per team).
#
# Usage, from the root of your worktree, in the background:
#   bash Scripts/agents/briefs/2026-10-30/bughunt/locked-build.sh SLUG NAME [NAME ...]
# Each NAME is an area or a test class, as run-area.py takes them; options
# such as --classes A,B pass through too. The script waits for the lock
# (mkdir is atomic, so one holder at a time), checks the free disk, runs the
# build, frees the lock however the build ends, and exits with run-area.py's
# status (3 when the disk is too full to build: tell bughunt-lead).
#
# Never delete the shared build folder, and never pass --clean: the lead
# deletes it once the team's last build has run.
set -u

slug="$1"
shift

lock=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-build.lock
data=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-bughunt
log="/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-$slug.log"

# Frees the lock: called on every way out once it is held.
release() {
    rm -f "$lock/holder"
    rmdir "$lock" 2>/dev/null
}

# Wait for the lock. Another member's build holds it; checking every 20
# seconds costs nothing while that build runs.
until mkdir "$lock" 2>/dev/null; do
    sleep 20
done
echo "$slug since $(date '+%H:%M:%S')" > "$lock/holder"
trap release EXIT

# A new build folder needs 5 GB free, an existing one 2 GB (teams-common.md).
need=5
if [ -d "$data" ]; then
    need=2
fi
avail=$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')
if [ "$avail" -lt "$need" ]; then
    echo "NOT BUILT: only ${avail} GB free, ${need} GB needed; post this to bughunt-lead"
    exit 3
fi

echo "$slug: building in $data, log $log"
BBS_AGENT="$slug" python3 Scripts/test/run-area.py --derived-data "$data" --log "$log" "$@"
