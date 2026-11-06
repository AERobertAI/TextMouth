#!/usr/bin/env python3
"""sync-info-plist.py: writes the iOS app's Info.plist from the Mac app's.

Until now the iOS app used the Mac's plist as it stood: XcodeGen sets
INFOPLIST_FILE to the first Info.plist it finds among a target's sources, even
one the target excludes, so the iOS configurations of the project said
`INFOPLIST_FILE = TextMouth/Resources/Info.plist`. That was by accident, and it
offered "Open in TextMouth" for books the iOS app cannot import, and carried
keys that mean nothing there. The iOS plist is now a file of its own
(TextMouth/Platform/iOS/Info.plist, named by INFOPLIST_FILE in project.yml),
which Xcode merges into the plist it generates (GENERATE_INFOPLIST_FILE). It is
the Mac's plist, so the two cannot drift apart by hand, less what iOS refuses
or has no use for, and with one addition. This script writes it.

What iOS leaves out, and why:
- The document types "Ogg Audio" and "Audio Converted at Import": the import
  converts that audio with Apple's afconvert program
  (ImportAudioConverter), and iOS lets an app start no program.
- The keys `LSMinimumSystemVersion` and `NSAppleEventsUsageDescription`, which
  are macOS's.

What iOS adds: ".azw3" beside the extensions of the Kindle MOBI type (the Mac's
list does not name it yet), so a KF8 book that the MOBI reader opens is
offered too.

Everything else is the Mac's, including the Kindle MOBI and KFX types, the
network settings feeds need, and the build identity.

Usage, from the repository's root or a worktree's:
    python3 -I Scripts/ios/sync-info-plist.py           write the file
    python3 -I Scripts/ios/sync-info-plist.py --check   exit 1 if it is stale
"""
import plistlib
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# The Mac's plist (the source) and the iOS plist (the output), from the root.
MAC_PLIST = Path("TextMouth/Resources/Info.plist")
IOS_PLIST = Path("TextMouth/Platform/iOS/Info.plist")

# The document types iOS refuses, by the name the Mac's plist gives them.
REFUSED = {
    "Ogg Audio",
    "Audio Converted at Import",
}

# The keys of the Mac's plist that mean nothing on iOS.
MAC_ONLY_KEYS = {
    "LSMinimumSystemVersion",
    "NSAppleEventsUsageDescription",
}

# The Kindle MOBI type: its document type's name, and its type's identifier.
MOBI_NAME = "Kindle Book (MOBI)"
MOBI_TYPE = "com.textmouth.mobi"
# The extension iOS adds to it.
ADDED_EXTENSION = "azw3"


def with_added_extension(extensions):
    """`extensions` with `ADDED_EXTENSION` after them, once."""
    return extensions if ADDED_EXTENSION in extensions else extensions + [ADDED_EXTENSION]


def ios_plist(mac):
    """The iOS plist's contents, derived from the Mac's (a dict)."""
    result = {key: value for key, value in mac.items() if key not in MAC_ONLY_KEYS}

    document_types = []
    for entry in mac["CFBundleDocumentTypes"]:
        name = entry["CFBundleTypeName"]
        if name in REFUSED:
            continue
        entry = dict(entry)
        if name == MOBI_NAME:
            entry["CFBundleTypeExtensions"] = with_added_extension(entry["CFBundleTypeExtensions"])
        document_types.append(entry)
    result["CFBundleDocumentTypes"] = document_types

    # Every type declaration stays: none is used by a refused type alone.
    imported = []
    for declaration in mac["UTImportedTypeDeclarations"]:
        declaration = dict(declaration)
        if declaration["UTTypeIdentifier"] == MOBI_TYPE:
            tags = dict(declaration["UTTypeTagSpecification"])
            tags["public.filename-extension"] = with_added_extension(tags["public.filename-extension"])
            declaration["UTTypeTagSpecification"] = tags
        imported.append(declaration)
    result["UTImportedTypeDeclarations"] = imported
    return result


def main():
    """Writes the iOS plist, or with --check says whether it is current."""
    with open(MAC_PLIST, "rb") as source:
        wanted = plistlib.dumps(ios_plist(plistlib.load(source)), fmt=plistlib.FMT_XML)
    if "--check" in sys.argv[1:]:
        current = IOS_PLIST.read_bytes() if IOS_PLIST.exists() else b""
        if current != wanted:
            print(f"{IOS_PLIST} is not what {MAC_PLIST} gives; run {sys.argv[0]} without --check")
            return 1
        return 0
    IOS_PLIST.write_bytes(wanted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
