#!/usr/bin/env python3
"""check-licenses.py: fails when the iPhone app links a library whose licence it does not ship.

The Mac app copies the licence of every library it bundles into
Contents/Resources/Licenses, and BundledLicenseTests reads them from the built
app. The iPhone app cannot be built or run on the Macs the agents use (no
simulator), so this script checks the same promise from project.yml and the
committed Package.resolved, with no build:

1. Every library the TextMouthiOS target links is one the table below knows:
   a Swift package (named by its identity), a library target of project.yml,
   or TextMouth's own code. A library that is in none of them is new, and the
   script fails until someone decides where its licence goes.
2. Every licence file the table names for a linked library exists in the
   repository, is not empty, and is copied into the iPhone app's
   Licenses/<folder> by a copyFiles entry of the TextMouthiOS target's
   sources, from that exact path.
3. TextMouthiOS copies no licence the table does not account for, so a
   licence of a library that has been dropped does not stay in the app.

Usage, from the repository's root or a worktree's:
    python3 -I -B Scripts/ios/check-licenses.py
Exit 0 when the app is complete, 1 with one line per problem otherwise.
"""
import json
import sys
from pathlib import Path

import yaml

# The repository's root: this file is in Scripts/ios.
ROOT = Path(__file__).resolve().parents[2]

# The iPhone app's target in project.yml, and where it keeps licences.
IOS_TARGET = "TextMouthiOS"
LICENSES_ROOT = "Licenses"

# The licence files of each library the iPhone app links, as
# (the Licenses subfolder, the repository paths copied into it). A package is
# named by its identity in Package.resolved; a library target by its name in
# project.yml.
LIBRARY_LICENCES = {
    "zipfoundation": ("ZIPFoundation", ["Vendor/package-licenses/ZIPFoundation/LICENSE"]),
    "swift-cmark": ("swift-cmark", ["Vendor/package-licenses/swift-cmark/COPYING"]),
    "SwiftSoup_iOS": ("SwiftSoup", ["Vendor/SwiftSoup/LICENSE"]),
    "LAME_iOS": ("LAME", ["Vendor/lame/COPYING", "Vendor/lame/LICENSE"]),
    # FFmpeg (FMT50), which the iPhone app links to run the FFmpeg session in its own process (FMT54): the release's
    # own LICENSE.md and COPYING.LGPLv2.1, and Scripts/vendor/ffmpeg/build.py's README, as the Mac app ships them.
    "FFmpeg_iOS": ("FFmpeg", ["Vendor/package-licenses/FFmpeg/LICENSE.md", "Vendor/package-licenses/FFmpeg/COPYING.LGPLv2.1",
                              "Vendor/package-licenses/FFmpeg/README"]),
    # liblouis, the braille translator (DR34), under the GNU Lesser General Public License 2.1.
    # Its tables are under licenses of their own, which Vendor/liblouis/TABLES-LICENSES.md lists (FR40).
    "liblouis_iOS": ("liblouis", ["Vendor/liblouis/COPYING.LESSER", "Vendor/liblouis/README", "Vendor/liblouis/TABLES-LICENSES.md"]),
}

# Targets that are TextMouth's own code, which need no third-party notice: the
# exception catcher, and the braille translation around liblouis (DR34).
OWN_CODE = {"ObjCExceptionCatcher_iOS", "TextMouthBrailleLibrary_iOS"}

# Code the iPhone app does not link but its shared readers follow, whose
# licence asks that its notice travel with the app (the MOBI reader follows
# foliate-js's mobi.js; TextMouth's own audio readers follow the BSD-licensed
# True Audio, WavPack, and Monkey's Audio decoders; the Mac app ships the same
# files).
FOLLOWED_CODE = {
    "foliate-js": ("foliate-js", ["Vendor/foliate-js/LICENSE"]),
    "TrueAudio": ("TrueAudio", [
        "Vendor/package-licenses/TrueAudio/README", "Vendor/package-licenses/TrueAudio/COPYRIGHT"]),
    "WavPack": ("WavPack", ["Vendor/package-licenses/WavPack/COPYING"]),
    "MonkeysAudio": ("MonkeysAudio", ["Vendor/package-licenses/MonkeysAudio/License.txt"]),
}


def load_yaml(path):
    """The parsed YAML file at `path`, relative to the repository root."""
    with open(ROOT / path, encoding="utf-8") as handle:
        return yaml.safe_load(handle)


def linked_libraries(project):
    """The names of what TextMouthiOS links, from project.yml's dependencies.

    A package dependency is named by its package; a target dependency by its
    target. Packages the listed ones build on are added by
    `package_identities`.
    """
    names = []
    for dependency in project["targets"][IOS_TARGET].get("dependencies", []):
        if "package" in dependency:
            names.append(("package", dependency["package"]))
        elif "target" in dependency:
            names.append(("target", dependency["target"]))
    return names


def package_identities(resolved_path):
    """Every package identity pinned in Package.resolved, transitive ones too.

    The iPhone app links every pinned package: the lock file holds the
    direct packages and what they build on, and nothing else.
    """
    with open(ROOT / resolved_path, encoding="utf-8") as handle:
        pins = json.load(handle)["pins"]
    return [pin["identity"] for pin in pins]


def copied_licences(project):
    """The (subfolder, source path) pairs TextMouthiOS copies into Licenses/."""
    copied = set()
    for source in project["targets"][IOS_TARGET].get("sources", []):
        if not isinstance(source, dict):
            continue
        copy = (source.get("buildPhase") or {}).get("copyFiles") or {}
        subpath = copy.get("subpath", "")
        if copy.get("destination") == "resources" and subpath.startswith(LICENSES_ROOT + "/"):
            copied.add((subpath[len(LICENSES_ROOT) + 1:], source["path"]))
    return copied


def problems(project, identities):
    """One line for each way the iPhone app's licences fall short.

    - project: the parsed project.yml.
    - identities: every package identity in Package.resolved.
    """
    found = []
    needed = {}  # Licenses subfolder -> the repository paths it must hold

    # 1. Every linked library is known; a known one's licences are required.
    linked = [name for kind, name in linked_libraries(project) if kind == "target"]
    # A package is named in project.yml by its display name; Package.resolved
    # lowercases it (identity), so compare case-insensitively.
    linked_packages = {name.lower() for kind, name in linked_libraries(project) if kind == "package"}
    for identity in identities:
        # The pinned packages are what the app links, direct or not.
        linked.append(identity)
    for name in linked:
        if name in OWN_CODE:
            continue
        if name not in LIBRARY_LICENCES:
            found.append(f"{name} is linked into the iPhone app and has no licence entry in check-licenses.py")
            continue
        folder, paths = LIBRARY_LICENCES[name]
        needed[folder] = paths
    for name in linked_packages:
        if name not in identities:
            found.append(f"{name} is a package of {IOS_TARGET} that Package.resolved does not pin")
    for folder, paths in FOLLOWED_CODE.values():
        needed[folder] = paths

    # 2. Every needed file exists, is not empty, and is copied from its path.
    copied = copied_licences(project)
    for folder, paths in sorted(needed.items()):
        for path in paths:
            file = ROOT / path
            if not file.is_file() or file.stat().st_size == 0:
                found.append(f"{path} is missing or empty")
            if (folder, path) not in copied:
                found.append(f"{IOS_TARGET} does not copy {path} into {LICENSES_ROOT}/{folder}")

    # 3. Nothing is copied that no linked library accounts for.
    wanted = {(folder, path) for folder, paths in needed.items() for path in paths}
    for folder, path in sorted(copied - wanted):
        found.append(f"{IOS_TARGET} copies {path} into {LICENSES_ROOT}/{folder}, which no linked library needs")
    return found


def main():
    """Print the problems and exit 1, or print that the licences are complete."""
    project = load_yaml("project.yml")
    identities = package_identities(
        "TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
    )
    found = problems(project, identities)
    for line in found:
        print(f"check-licenses: {line}")
    if found:
        return 1
    print("check-licenses: every library the iPhone app links has its licence in the app")
    return 0


if __name__ == "__main__":
    sys.exit(main())
