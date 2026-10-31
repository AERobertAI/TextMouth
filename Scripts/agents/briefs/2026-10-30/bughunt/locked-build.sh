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
# build, and frees the lock however the build ends. It exits with
# run-area.py's status, or 3 when the disk stayed too full for an hour (tell
# bughunt-lead, and do not build).
#
# The disk is short tonight (the orchestrator, October 30, 19:40 and 23:13):
# a build needs 4 GB free, and the team's folder is deleted right after each
# run. So once the build ends, this script unregisters the folder's app and
# deletes the folder itself. Never delete it yourself, and never pass
# --clean.
set -u

slug="$1"
shift

lock=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-build.lock
waiting=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-build.waiting
data=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-bughunt
log="/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-$slug.log"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Deletes the team's build folder once a build has run, as the orchestrator
# asked at 23:13 ("Delete a folder right after its run"): unregisters the
# test host app first, as every build folder's removal does. The next
# member's build makes the folder again.
delete_folder() {
    case "$data" in
        */TextMouth-DerivedData-bughunt) ;;
        *) return ;;
    esac
    if [ -d "$data" ]; then
        "$lsregister" -u "$data/Build/Products/Debug/TextMouth.app" 2>/dev/null
        rm -rf "$data"
        echo "$slug: deleted the team's build folder after its run"
    fi
}

# Frees the lock and deletes the folder: called on every way out once the
# lock is held.
release() {
    delete_folder
    rm -f "$lock/holder"
    rmdir "$lock" 2>/dev/null
}

# Wait for the lock, saying so in the waiting folder, which shows the lead
# who is queued.
mkdir -p "$waiting"
touch "$waiting/$slug"
until mkdir "$lock" 2>/dev/null; do
    sleep 20
done
rm -f "$waiting/$slug"
echo "$slug since $(date '+%H:%M:%S')" > "$lock/holder"
trap release EXIT

# A build needs 4 GB free (the orchestrator, 23:13). No member of the
# team can build while the disk is short, so the lock is held while this
# waits for room, checking each minute, for an hour at most.
need=4
for minute in $(seq 1 60); do
    avail=$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')
    if [ "$avail" -ge "$need" ]; then
        break
    fi
    if [ "$minute" -eq 60 ]; then
        echo "NOT BUILT: only ${avail} GB free after an hour, ${need} GB needed; post this to bughunt-lead and do not build"
        exit 3
    fi
    sleep 60
done

echo "$slug: building in $data, log $log"
BBS_AGENT="$slug" python3 Scripts/test/run-area.py --derived-data "$data" --log "$log" "$@"
