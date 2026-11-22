#!/usr/bin/env python3
"""Proves that compacting the language files, and reading them through TextMouth's own engine, leave every lookup
unchanged (TL16, TL18, FR34, FR39).

Run by `make l10n-check` (and so by `make check`), against the String Catalog in the
repository, without building the app:

  1. `xcrun xcstringstool compile` writes the language files as Xcode ships them
     (the same compiler Xcode's build step runs), into build/l10n-packs/xcode;
  2. a copy of those files is compacted by `compact_packs.py`, into build/l10n-packs/compact;
  3. a small Swift program (Scripts/l10n/pack-probe/main.swift, compiled with the lookups of
     TextMouthProductionTests/LanguagePackTests.swift) reads both folders as the app's main bundle,
     one language at a time with every language in the bundle (so a lookup that falls back to
     English falls back here too), and compares every key in every language: each string's text,
     and each plural string's text at the counts 0, 1, 2, 5, 21, 100, and 1,000,000. Any difference
     fails;
  4. the third reading (FR39, when the ID table is given, as it is for the repository's catalog): `pack.py build`
     writes the interface-text pack from the same catalog, into build/l10n-packs/engine, and in each language's
     process the probe asks the engine (the core files of TextMouth/Localization/InterfaceText/, compiled into the
     probe) for every ID of every key, and Foundation's `String(localized:)` for the same call, at the 13 counts of
     TextMouthProductionTests/InterfaceTextShippedPackTests.swift (a key's second number three places on). The two
     texts must be equal, the engine must report no problem, and the probe prints the number of lookups compared.

The folders under build/ are overwritten on every run and never deleted by this script; only the
languages the catalog names are copied and compared, so a leftover folder of a removed language
changes nothing.

Usage: python3 -I -B Scripts/l10n/verify_packs.py [CATALOG [IDS]]   exit 0 when every lookup is identical

CATALOG defaults to the repository's catalog, and then IDS to the repository's ID table (Scripts/l10n/ids.json);
a test names a small synthetic catalog and a work folder of its own, with an ID table of its own or none (no third
reading).
"""

from __future__ import annotations

import json
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

# No bytecode beside the scripts it imports (the policy of Scripts/agents/tests/test_bytecode_policy.py).
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compact_packs  # noqa: E402  (imported by path, after sys.path is set)

ROOT = HERE.parent.parent
CATALOG = ROOT / "TextMouth" / "Localization" / "Localizable.xcstrings"
# The engine's core files, the ones that use Foundation, Compression, and `os` only (see InterfaceText.swift's note):
# the files that read the app's state (InterfaceLanguage, InterfaceTextLine) are left out.
ENGINE_SOURCES = [
    ROOT / "TextMouth" / "Localization" / "InterfaceText" / name
    for name in (
        "FormatSpecifiers.swift", "InterfaceTextEngine.swift", "InterfaceTextFormat.swift", "InterfaceTextPack.swift",
        "InterfaceTextTables.swift", "PluralRules.swift",
    )
]
# The Swift sources of the probe: its own main file, the lookups and the proof's calls it shares with the hosted tests,
# and the engine.
PROBE_SOURCES = [
    HERE / "pack-probe" / "main.swift",
    ROOT / "TextMouthProductionTests" / "LanguagePackTests.swift",
    ROOT / "TextMouthProductionTests" / "InterfaceTextShippedPackTests.swift",
    *ENGINE_SOURCES,
]
# The ID table of the repository's catalog, and the pack builder.
IDS = HERE / "ids.json"
PACK_TOOL = HERE / "pack.py"
WORK = ROOT / "build" / "l10n-packs"


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


def build_probe(work: Path = WORK) -> Path:
    """Compile the probe into `work`/probe, unless it is newer than every source."""
    work.mkdir(parents=True, exist_ok=True)
    probe = work / "probe"
    if probe.exists() and all(probe.stat().st_mtime >= source.stat().st_mtime for source in PROBE_SOURCES):
        return probe
    run(
        ["xcrun", "swiftc", "-D", "PACK_PROBE", "-O", "-o", str(probe), *map(str, PROBE_SOURCES)],
        "compiling the probe",
    )
    return probe


def write_app_info(folder: Path, languages: list[str]) -> None:
    """Write the Info.plist that makes `folder` an app's resources: English the development region, as the app's is.

    The probe runs from a copy of itself placed in the folder, so the folder is that run's main bundle; the
    development region decides which table a lookup falls back to.
    """
    info = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleIdentifier": "org.textmouth.packprobe",
        "CFBundleLocalizations": languages,
    }
    (folder / "Info.plist").write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_XML))


def build_engine_pack(catalog: Path, ids: Path, work: Path) -> Path:
    """Build the interface-text pack of `catalog` (its keys given IDs by `ids`) into `work`/engine/Strings.pack.

    Always rebuilt, without a stamp, so that the pack the probe reads is the one this catalog makes.
    """
    folder = work / "engine"
    folder.mkdir(parents=True, exist_ok=True)
    out = folder / "Strings.pack"
    run(
        [sys.executable, "-I", "-B", str(PACK_TOOL), "build", "--catalog", str(catalog), "--ids", str(ids), "--out",
         str(out), "--no-stamp"],
        "building the interface-text pack",
    )
    return out


def verify(catalog: Path = CATALOG, work: Path = WORK, ids: Path | None = None) -> int:
    """Compile `catalog`, compact a copy, and compare every lookup; 0 when all are identical.

    With `ids`, the engine's reading of the pack built from `catalog` is compared too (see the top of this file).
    The files go under `work`, overwriting what an earlier run left.
    """
    languages = catalog_languages(catalog)
    xcode, compact = work / "xcode", work / "compact"
    for folder in (xcode, compact):
        folder.mkdir(parents=True, exist_ok=True)

    # 1. The files as Xcode ships them (xcstringstool warns about ambiguous plurals; the sync tools report those).
    run(["xcrun", "xcstringstool", "compile", "--output-directory", str(xcode), str(catalog)], "xcstringstool compile")

    # 2. A compacted copy, language by language, overwriting what an earlier run left.
    for language in languages:
        source = xcode / f"{language}.lproj"
        if not source.is_dir():
            sys.exit(f"verify_packs: xcstringstool wrote no {language}.lproj for the catalog's language {language}")
        shutil.copytree(source, compact / source.name, dirs_exist_ok=True)
    changed, errors = compact_packs.compact_folder(compact)
    if errors:
        sys.exit("verify_packs: compact_packs refused:\n" + "\n".join(errors))
    for folder in (xcode, compact):
        write_app_info(folder, languages)

    # 3. Every lookup, in both; and, with an ID table, the engine's reading of the pack from the same catalog.
    probe = build_probe(work)
    engine_arguments: list[str] = []
    if ids is not None:
        pack = build_engine_pack(catalog, ids, work)
        engine_arguments = ["--pack", str(pack), "--ids", str(ids)]
    done = subprocess.run(
        [str(probe), str(xcode), str(compact), str(catalog), *engine_arguments, *languages],
        capture_output=True, text=True, check=False,
    )
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        print("verify_packs: FAILED: a lookup differs between Xcode's files and the compact files, or the engine's text "
              "differs from Xcode's (or the engine reported a problem)", file=sys.stderr)
        return 1
    third = " and the engine's text equals Xcode's" if ids is not None else ""
    print(f"verify_packs: ok ({changed} files compacted; every lookup in {', '.join(languages)} is unchanged{third})")
    return 0


def main() -> int:
    """The command line: an optional catalog path (the repository's by default) and, for another catalog, an optional ID table."""
    if len(sys.argv) > 1:
        return verify(Path(sys.argv[1]), ids=Path(sys.argv[2]) if len(sys.argv) > 2 else None)
    return verify(CATALOG, ids=IDS)


if __name__ == "__main__":
    sys.exit(main())
