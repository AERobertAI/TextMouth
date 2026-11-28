#!/usr/bin/env python3
"""Proves that TextMouth's own engine, reading the interface-text pack, says in every language what Apple's lookup would say
of the String Catalog's tables, and that the system's choice of language is unchanged by a bundle that ships no table
(TL16, TL18, FR34, FR39).

Run by `make l10n-check` (and so by `make check`), against the String Catalog in the repository, without building the app.
Since the switch (FR39 phase 8) neither app ships a table of Apple's, so the tables here exist only to be compared with:

  1. `xcrun xcstringstool compile` writes Apple's language files from the catalog (the same compiler Xcode's build used to
     run), into build/l10n-packs/apple;
  2. `pack.py build` writes the interface-text pack from the same catalog, into build/l10n-packs/engine, with the
     `<language>.lproj/InfoPlist.strings` files the apps' bundles hold;
  3. a small Swift program (Scripts/l10n/pack-probe/main.swift, compiled with the lookups of
     TextMouthProductionTests/LanguagePackTests.swift and the engine's core files) runs a copy of itself in the folder of
     step 1, which makes the folder `Bundle.main`, once for each language with `-AppleLanguages (language)`. The folder holds
     every language, so a lookup that a language's table lacks falls back to English's, as Apple's lookup does. In each
     process the probe asks the engine for every ID at the 13 counts of
     TextMouthProductionTests/InterfaceTextShippedPackTests.swift (a second number three places on), and Apple's tables for
     the same ID, written by Foundation with the same arguments. The two texts must be equal and the engine must report no
     problem;
  4. the system's choice of language (the design's "Language choice"): the folder of step 2 is laid out as the apps'
     bundles are, an Info.plist with `CFBundleLocalizations` and an `.lproj` for each language, no table. For each preference
     list of PREFERENCES the probe runs a copy there and prints `Bundle.main.preferredLocalizations.first`, and the same in the
     folder of step 1, which holds the tables besides. Each must be what the design measured, and the two must agree.

The folders under build/ are overwritten on every run and never deleted by this script; only the languages the catalog names
are compared, so a leftover folder of a removed language changes nothing.

Usage: python3 -I -B Scripts/l10n/verify_packs.py [CATALOG]   exit 0 when every lookup is identical and every choice is as
measured

CATALOG defaults to the repository's catalog; a test names a small synthetic catalog and a work folder of its own.
"""

from __future__ import annotations

import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

# No bytecode beside the scripts it imports (the policy of Scripts/agents/tests/test_bytecode_policy.py).
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent

ROOT = HERE.parent.parent
CATALOG = ROOT / "TextMouth" / "Localization" / "Localizable.xcstrings"
# The engine's core files, the ones that use Foundation, Compression, and `os` only (see InterfaceText.swift's note):
# the files that read the app's state (InterfaceLanguage, InterfaceTextLine) are left out.
ENGINE_SOURCES = [
    ROOT / "TextMouth" / "Localization" / "InterfaceText" / name
    for name in (
        "FormatSpecifiers.swift", "InterfaceTextEngine.swift", "InterfaceTextFormat.swift", "InterfaceTextPack.swift",
        "InterfaceTextTables.swift", "InterfaceTextWording.swift", "PluralRules.swift",
    )
] + [
    # The container the pack is read through (FR40), which `InterfaceTextPack.swift` uses.
    ROOT / "TextMouth" / "Packs" / "PackContainer.swift",
]
# The Swift sources of the probe: its own main file, the lookups and the proof's calls it shares with the hosted tests,
# and the engine.
PROBE_SOURCES = [
    HERE / "pack-probe" / "main.swift",
    ROOT / "TextMouthProductionTests" / "LanguagePackTests.swift",
    ROOT / "TextMouthProductionTests" / "InterfaceTextShippedPackTests.swift",
    *ENGINE_SOURCES,
]
# The system bzip2's module map, which the engine's pack reader imports (the module links the SDK's libbz2).
CBZIP2_INCLUDE = ROOT / "Vendor" / "CBZip2" / "include"
# The pack builder.
PACK_TOOL = HERE / "pack.py"
WORK = ROOT / "build" / "l10n-packs"

# The system's choice (the design's "Language choice", System): each preference list (languages separated by commas, in
# order) and the language `Bundle.main.preferredLocalizations.first` chooses, as measured. The last group is every language
# the catalog has, which must choose itself.
PREFERENCES = {
    "zh-Hant-TW": "zh-Hant", "zh-Hant-HK": "zh-Hant", "zh-HK": "zh-Hant", "zh-TW": "zh-Hant", "zh-MO": "zh-Hant",
    "zh-CN": "zh-Hans", "zh-SG": "zh-Hans", "zh": "zh-Hans",
    "pt-PT": "pt-BR", "pt": "pt-BR", "pt-AO": "pt-BR",
    "es-419": "es", "es-MX": "es", "es-US": "es",
    "iw": "he",
    # Norwegian Bokmal alone has no interface: the development region, English; with Swedish after it, Swedish.
    "nb": "en", "nb,sv": "sv",
    # Catalan with Spanish after it gives Spanish; Hindi in Latin script is not Hindi.
    "ca,es": "es", "hi-Latn": "en",
    # A language the interface lacks gives the development region, and a region of one it has gives that language.
    "en-GB": "en", "de-AT": "de", "fr-CA": "fr", "ru-RU": "ru", "ar-SA": "ar", "ko-KR": "ko", "ja-JP": "ja",
    "xx": "en",
}


def run(command: list[str], what: str) -> subprocess.CompletedProcess:
    """Run a command, capturing its output; stop with its output when it fails."""
    done = subprocess.run(command, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.exit(f"verify_packs: {what} failed ({done.returncode}):\n{done.stdout}{done.stderr}")
    return done


def catalog_languages(catalog: Path = CATALOG) -> list[str]:
    """The languages `catalog` holds a localization for, sorted."""
    strings = json.loads(catalog.read_text(encoding="utf-8"))["strings"]
    return sorted({language for entry in strings.values() for language in entry.get("localizations", {})})


def expected_preferences(languages: list[str]) -> dict[str, str]:
    """The preference lists to try and the language each must choose: PREFERENCES, and each of `languages` choosing itself
    (a catalog of fewer languages leaves out the measured lists whose answer it lacks)."""
    wanted = {lists: chosen for lists, chosen in PREFERENCES.items()
              if all(language in languages for language in {chosen, "en"})}
    wanted.update({language: language for language in languages})
    return wanted


def build_probe(work: Path = WORK) -> Path:
    """Compile the probe into `work`/probe, unless it is newer than every source."""
    work.mkdir(parents=True, exist_ok=True)
    probe = work / "probe"
    if probe.exists() and all(probe.stat().st_mtime >= source.stat().st_mtime for source in PROBE_SOURCES):
        return probe
    run(
        ["xcrun", "swiftc", "-D", "PACK_PROBE", "-O", "-I", str(CBZIP2_INCLUDE), "-o", str(probe), *map(str, PROBE_SOURCES)],
        "compiling the probe",
    )
    return probe


def write_app_info(folder: Path, languages: list[str]) -> None:
    """Write the Info.plist that makes `folder` an app's resources: English the development region, and `languages` in
    CFBundleLocalizations, as the apps' own Info.plists have them.

    The probe runs from a copy of itself placed in the folder, so the folder is that run's main bundle; the
    development region decides which language a person with none of the bundle's gets.
    """
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleIdentifier": "org.textmouth.packprobe",
        "CFBundleLocalizations": languages,
    }
    (folder / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))


def build_engine_pack(catalog: Path, work: Path) -> Path:
    """Build the interface-text pack of `catalog` (keyed by ID) into `work`/engine/Strings.pack, with the InfoPlist.strings of
    each language beside it, as the apps' build does.

    Always rebuilt, without a stamp, so that the pack the probe reads is the one this catalog makes.
    """
    folder = work / "engine"
    folder.mkdir(parents=True, exist_ok=True)
    out = folder / "Strings.pack"
    run(
        [sys.executable, "-I", "-B", str(PACK_TOOL), "build", "--catalog", str(catalog), "--out", str(out), "--no-stamp"],
        "building the interface-text pack",
    )
    return out


def preferred_languages(probe: Path, folder: Path, lists: list[str]) -> dict[str, str]:
    """The language `Bundle.main.preferredLocalizations.first` chooses in `folder` for each preference list of `lists`
    (languages separated by commas), as the probe reports it."""
    done = run([str(probe), "--preferences", str(folder), *lists], "the probe's choice of language")
    found = dict(re.findall(r"^PREFERRED (\S+) -> (\S+)$", done.stdout, re.MULTILINE))
    missing = [lists_ for lists_ in lists if lists_ not in found]
    if missing:
        sys.exit(f"verify_packs: the probe reported no choice for {missing}:\n{done.stdout}{done.stderr}")
    return found


def check_preferences(probe: Path, app: Path, apple: Path, languages: list[str]) -> list[str]:
    """The sentences about the system's choice of language that differ from what the design measured, or between the app's
    layout (`app`: Info.plist and the .lproj folders, no table) and the folder with the tables (`apple`); the results are
    printed, one line for each preference list. Empty when every choice is as measured."""
    wanted = expected_preferences(languages)
    lists = sorted(wanted)
    in_app = preferred_languages(probe, app, lists)
    with_tables = preferred_languages(probe, apple, lists)
    problems = []
    for choice in lists:
        verdict = "ok" if in_app[choice] == wanted[choice] else "DIFFERENT"
        print(f"verify_packs: system choice for {choice}: {in_app[choice]} (measured {wanted[choice]}; with the tables {with_tables[choice]}): {verdict}")
        if in_app[choice] != wanted[choice]:
            problems.append(f"preferences {choice}: the app's layout chooses {in_app[choice]}, the design measured {wanted[choice]}")
        if with_tables[choice] != in_app[choice]:
            problems.append(f"preferences {choice}: {in_app[choice]} with no table, {with_tables[choice]} with the tables")
    return problems


def verify(catalog: Path = CATALOG, work: Path = WORK) -> int:
    """Compile `catalog` into Apple's tables, build its pack, and compare every lookup (the engine's reading of the pack
    against Apple's tables, in every language) and the system's choice of language (see the top of this file); 0 when all
    are as they should be. The files go under `work`, overwriting what an earlier run left.
    """
    languages = catalog_languages(catalog)
    apple = work / "apple"
    apple.mkdir(parents=True, exist_ok=True)

    # 1. Apple's tables, as Xcode used to compile them (xcstringstool warns about ambiguous plurals; the sync tools report
    # those), and the Info.plist that makes the folder a bundle holding every language.
    run(["xcrun", "xcstringstool", "compile", "--output-directory", str(apple), str(catalog)], "xcstringstool compile")
    for language in languages:
        if not (apple / f"{language}.lproj").is_dir():
            sys.exit(f"verify_packs: xcstringstool wrote no {language}.lproj for the catalog's language {language}")
    write_app_info(apple, languages)

    # 2. The pack, and the app's own layout: the InfoPlist.strings folders and an Info.plist, no table.
    probe = build_probe(work)
    pack = build_engine_pack(catalog, work)
    write_app_info(pack.parent, languages)

    # 3. Every lookup: the engine's reading of the pack against Apple's tables.
    done = subprocess.run(
        [str(probe), str(apple), str(catalog), "--pack", str(pack), *languages],
        capture_output=True, text=True, check=False,
    )
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        print("verify_packs: FAILED: the engine's text differs from Apple's tables (or the engine reported a problem)",
              file=sys.stderr)
        return 1

    # 4. The system's choice of language, in the app's own layout.
    problems = check_preferences(probe, pack.parent, apple, languages)
    if problems:
        print("verify_packs: FAILED: the system's choice of language is not what the design measured:", file=sys.stderr)
        for sentence in problems:
            print(f"  {sentence}", file=sys.stderr)
        return 1
    print(f"verify_packs: ok (every lookup in {', '.join(languages)} equals Apple's table, and the system chooses as "
          "measured in a bundle with no table)")
    return 0


def main() -> int:
    """The command line: an optional catalog path (the repository's by default)."""
    return verify(Path(sys.argv[1]) if len(sys.argv) > 1 else CATALOG)


if __name__ == "__main__":
    sys.exit(main())
