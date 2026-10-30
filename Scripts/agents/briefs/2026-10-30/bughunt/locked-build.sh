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
# run-area.py's status, or 3 when the disk is too full to build (tell
# bughunt-lead, and do not build).
#
# The disk is short tonight (the orchestrator, October 30, 19:40): a build in
# an existing folder needs 4 GB free, a new folder 5 GB, and the team's
# folder is deleted whenever no other member waits to build next. So once
# the build ends and nobody waits, this script unregisters the folder's app
# and deletes the folder itself. Never delete it yourself, and never pass
# --clean.
set -u

slug="$1"
shift

lock=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-build.lock
waiting=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-build.waiting
data=/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-bughunt
log="/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/bughunt-$slug.log"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Deletes the team's build folder when no member waits to build next:
# unregisters the test host app first, as every build folder's removal does.
delete_folder_unless_awaited() {
    if [ -n "$(ls -A "$waiting" 2>/dev/null)" ]; then
        echo "$slug: the build folder stays: $(ls "$waiting" | tr '\n' ' ')waits to build"
        return
    fi
    case "$data" in
        */TextMouth-DerivedData-bughunt) ;;
        *) return ;;
    esac
    if [ -d "$data" ]; then
        "$lsregister" -u "$data/Build/Products/Debug/TextMouth.app" 2>/dev/null
        rm -rf "$data"
        echo "$slug: deleted the team's build folder (nobody waits to build)"
    fi
}

# Frees the lock, and the folder too when nobody waits: called on every way
# out once the lock is held.
release() {
    delete_folder_unless_awaited
    rm -f "$lock/holder"
    rmdir "$lock" 2>/dev/null
}

# Wait for the lock, saying so in the waiting folder, so the build before
# this one keeps the folder for it.
mkdir -p "$waiting"
touch "$waiting/$slug"
until mkdir "$lock" 2>/dev/null; do
    sleep 20
done
rm -f "$waiting/$slug"
echo "$slug since $(date '+%H:%M:%S')" > "$lock/holder"
trap release EXIT

# A new build folder needs 5 GB free, an existing one 4 GB.
need=5
if [ -d "$data" ]; then
    need=4
fi
avail=$(df -g /System/Volumes/Data | awk 'NR==2 {print $4}')
if [ "$avail" -lt "$need" ]; then
    echo "NOT BUILT: only ${avail} GB free, ${need} GB needed; post this to bughunt-lead and do not build"
    exit 3
fi

echo "$slug: building in $data, log $log"
BBS_AGENT="$slug" python3 Scripts/test/run-area.py --derived-data "$data" --log "$log" "$@"
