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
or has no use for, and with what only iOS needs. This script writes it.

What iOS leaves out, and why. iOS goes by the types a document type names
(`LSItemContentTypes`) and the extensions that the declarations of those types
tag (`UTImportedTypeDeclarations`), not by `CFBundleTypeExtensions`, so a type
is left out by name, with the declaration of any type nothing else names:
- "Ogg Audio" and "Audio Converted at Import": the import converts that audio
  with Apple's afconvert program (ImportAudioConverter), and iOS lets an app
  start no program.
- (Until November 17, 2026, also "Audio and Video Converted with ffmpeg"
  (WMA, WebM, Matroska, AVI, and the rest of FFmpegAudioConverter), which the
  Mac converts with the FFmpeg helper it carries. Since FMT54 the iPhone runs
  the same FFmpeg session in the app itself, so they are offered as on the
  Mac, with the declarations of their own types.)
- (Until November 18, 2026, also "Lossless Audio Read by TextMouth" (True
  Audio, WavPack, and Monkey's Audio, with their type declarations):
  TextMouth's own readers decode them inside the app, so nothing stopped the
  iPhone but its import's refusal of every converted format. Since that refusal
  lets them by, they are offered as on the Mac.)
- "ALAC Audio": the one type it names, `com.apple.coreaudio-format`, is the
  system's type for `.caf` files too (the system types `tones-*.caf` so), which
  are converted at import with afconvert. Leaving the type in would offer every
  `.caf`; leaving it out leaves `.alac` unoffered on iOS, which is the lesser
  harm.
- "NLS BARD Braille Package" (`.bopf`, FMT56): the iPhone copies only the
  file it is handed, and a package file alone would arrive without the BRF
  volumes it lists. A BARD download is a ZIP, which the iPhone does import,
  and a folder is chosen with Import Folder.
- (Until November 16, 2026, also "BRF Braille File", "BRL Braille File", and
  "PEF Braille File", which the Mac's braille helper program reads. Since DR34
  the iPhone translates braille in the app itself, so they are offered as on
  the Mac, with their type declarations.)
- The keys `LSMinimumSystemVersion` and `NSAppleEventsUsageDescription`, which
  are macOS's.

What iOS adds:
- The keys only iOS has (`IOS_ONLY_KEYS`): the audio background mode, without
  which every book stops as the screen locks, the identifiers of a spoken audio
  export's continued processing task (a wildcard), and a scene manifest of one
  scene at a time, also on an iPad, since one reading session cannot serve two
  windows. The scene's delegate is named in code, by TextMouthAppDelegate, so
  the manifest names no configuration. project.yml leaves out Xcode's
  generated manifest, which would allow several scenes.

Everything else is the Mac's, including the Kindle MOBI type (whose list names
.azw3 since 0.4.2, as the Mac's own does) and the KFX type, the network
settings feeds need, and the build identity.

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
    "ALAC Audio",
    "NLS BARD Braille Package",
}

# The keys of the Mac's plist that mean nothing on iOS.
MAC_ONLY_KEYS = {
    "LSMinimumSystemVersion",
    "NSAppleEventsUsageDescription",
}

# The keys iOS needs and the Mac's plist cannot have, with their values (the
# docstring says why each is there). IOSInfoPlistTests pins both.
IOS_ONLY_KEYS = {
    "UIBackgroundModes": ["audio"],
    # The continued processing task of a spoken audio export (FR31, phase 2): one name for each export, this wildcard's
    # prefix and a UUID, which `PhoneExportBackgroundTask` registers and submits as Export is pressed.
    "BGTaskSchedulerPermittedIdentifiers": ["com.textmouth.TextMouth.iOS.export.*"],
    "UIApplicationSceneManifest": {"UIApplicationSupportsMultipleScenes": False},
}


def ios_plist(mac):
    """The iOS plist's contents, derived from the Mac's (a dict)."""
    result = {key: value for key, value in mac.items() if key not in MAC_ONLY_KEYS}

    document_types = []
    for entry in mac["CFBundleDocumentTypes"]:
        name = entry["CFBundleTypeName"]
        if name in REFUSED:
            continue
        document_types.append(dict(entry))
    result["CFBundleDocumentTypes"] = document_types

    # The declaration of a type that a kept document type names stays; one
    # that only a refused type named goes with it.
    named = {uti for entry in document_types for uti in entry["LSItemContentTypes"]}
    imported = []
    for declaration in mac["UTImportedTypeDeclarations"]:
        if declaration["UTTypeIdentifier"] not in named:
            continue
        imported.append(dict(declaration))
    result["UTImportedTypeDeclarations"] = imported

    # The keys only iOS has. The Mac's plist holding one of them would be a
    # mistake there, and the iOS value would hide it, so stop instead.
    clash = sorted(set(IOS_ONLY_KEYS) & set(mac))
    if clash:
        sys.exit(f"{MAC_PLIST} holds keys only iOS should have: {', '.join(clash)}")
    result.update(IOS_ONLY_KEYS)
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
