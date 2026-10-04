#!/bin/bash
#
# keep-installed-dsym.sh: keeps the dSYM of the app `make install` has just
# installed, so that crash reports from that app can still be read after
# later builds replace the dSYM in the build products. `make install` runs it
# once the app is in place.
#
# The Release app is stripped of its symbols (project.yml), so a crash report
# gives each of TextMouth's own frames as an offset, such as TextMouth +
# 0x372e00, and only the dSYM the same build made turns those offsets back
# into functions, files, and lines. A crash report names that build twice: by
# its build number (CFBundleVersion, the UTC time `make build` stamped, as
# YYYYMMDDHHMMSS) and by TextMouth's UUID.
#
# Usage: Scripts/keep-installed-dsym.sh <installed app> <dSYM> <folder> <count>
#
# Copies <dSYM> into <folder> as TextMouth-<build number>-<UUID>.app.dSYM,
# then removes the oldest dSYMs named that way until <count> remain, the one
# just kept always among them. Anything else in <folder> is left alone.
#
# It keeps nothing, and says why, when the build made no dSYM (a Debug build
# makes none), or when the dSYM's UUID is not the installed app's, since a
# dSYM of another build would give a crash report's offsets the wrong names.
#
# Exit status: 0, also when it keeps nothing, since the app is installed
# either way; 2 for a usage error.

set -u

# say <text>: prints one line of make install's report.
say() {
  printf '==> %s\n' "$*"
}

# keep_nothing <reason>: says why no dSYM is kept, and ends the script
# successfully: the app is installed either way.
keep_nothing() {
  say "warning: kept no dSYM for the installed app: $*"
  exit 0
}

# uuids_of <path>: prints the UUIDs dwarfdump reports for the Mach-O file or
# dSYM at <path>, one for each architecture, sorted and joined by "-", or
# nothing when it reports none.
uuids_of() {
  dwarfdump --uuid "$1" 2>/dev/null | awk '$1 == "UUID:" { print $2 }' | LC_ALL=C sort | paste -s -d - -
}

# older_dsyms <folder> <name> <except>: prints the names of the dSYMs kept in
# <folder> for <name> other than <except>, oldest first: each name carries
# its build number, a timestamp, which they are sorted by.
older_dsyms() {
  local folder=$1 name=$2 except=$3 path file
  for path in "$folder/$name"-*.app.dSYM; do
    file=${path##*/}
    if [[ $file != "$except" && $file =~ ^$name-([0-9]+)-.+\.app\.dSYM$ ]]; then
      printf '%s\t%s\n' "${BASH_REMATCH[1]}" "$file"
    fi
  done | LC_ALL=C sort -n -k 1,1 | cut -f 2
}

if [[ $# -ne 4 || ! $4 =~ ^[1-9][0-9]*$ ]]; then
  echo "usage: $0 <installed app> <dSYM> <folder> <how many dSYMs to keep, at least 1>" >&2
  exit 2
fi
app=$1
dsym=$2
folder=$3
count=$4
name=$(basename "$app" .app)

# Keep the dSYM only when it is this very app's: its build made one, and its
# UUIDs are the installed executable's.
[[ -d $dsym ]] || keep_nothing "the build made no dSYM at $dsym"
build=$(plutil -extract CFBundleVersion raw -o - "$app/Contents/Info.plist" 2>/dev/null)
[[ $build =~ ^[0-9]+$ ]] || keep_nothing "$app has no build number of digits (CFBundleVersion: ${build:-none})"
app_uuids=$(uuids_of "$app/Contents/MacOS/$name")
[[ -n $app_uuids ]] || keep_nothing "dwarfdump reports no UUID for $app"
dsym_uuids=$(uuids_of "$dsym")
[[ $dsym_uuids == "$app_uuids" ]] ||
  keep_nothing "$dsym is another build's (UUID ${dsym_uuids:-unknown}; the installed app's is $app_uuids)"

kept_name="$name-$build-$app_uuids.app.dSYM"
if ! { mkdir -p "$folder" && rm -rf "${folder:?}/$kept_name" && cp -R "$dsym" "$folder/$kept_name"; }; then
  # A copy cut short, by a full disk say, must not pass for this build's.
  rm -rf "${folder:?}/$kept_name"
  keep_nothing "could not copy $dsym to $folder/$kept_name"
fi
say "kept this build's dSYM, for its crash reports: $folder/$kept_name"

# Remove the oldest of the others until, with the one just kept, <count>
# remain.
older=$(older_dsyms "$folder" "$name" "$kept_name")
excess=$(( $(grep -c . <<<"$older") - (count - 1) ))
if (( excess > 0 )); then
  while IFS= read -r file; do
    rm -rf "${folder:?}/$file" &&
      say "removed an older install's dSYM, keeping the last $count: $folder/$file"
  done < <(head -n "$excess" <<<"$older")
fi
exit 0
