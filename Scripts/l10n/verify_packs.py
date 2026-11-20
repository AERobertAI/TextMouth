#!/usr/bin/env python3
"""Proves that compacting the language files leaves every lookup unchanged (TL16, FR34).

Run by `make l10n-check` (and so by `make check`), against the String Catalog in the
repository, without building the app:

  1. `xcrun xcstringstool compile` writes the language files as Xcode ships them
     (the same compiler Xcode's build step runs), into build/l10n-packs/xcode;
  2. a copy of those files is compacted by `compact_packs.py`, into build/l10n-packs/compact;
  3. a small Swift program (Scripts/l10n/pack-probe/main.swift, compiled with the lookups of
     TextMouthProductionTests/LanguagePackTests.swift) reads both folders through `Bundle`, the way the
     app does, and compares every key in every language: each string's text, and each plural string's
     text at the counts 0, 1, 2, 5, 21, 100, and 1,000,000. Any difference fails.

The folders under build/ are overwritten on every run and never deleted by this script; only the
languages the catalog names are copied and compared, so a leftover folder of a removed language
changes nothing.

Usage: python3 -I -B Scripts/l10n/verify_packs.py        exit 0 when every lookup is identical
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import compact_packs  # noqa: E402  (imported by path, after sys.path is set)

ROOT = HERE.parent.parent
CATALOG = ROOT / "TextMouth" / "Localization" / "Localizable.xcstrings"
# The Swift sources of the probe: its own main file, and the lookups it shares with the hosted test.
PROBE_SOURCES = [HERE / "pack-probe" / "main.swift", ROOT / "TextMouthProductionTests" / "LanguagePackTests.swift"]
WORK = ROOT / "build" / "l10n-packs"


def run(command: list[str], what: str) -> subprocess.CompletedProcess:
    """Run a command, capturing its output; stop with its output when it fails."""
    done = subprocess.run(command, capture_output=True, text=True, check=False)
    if done.returncode != 0:
        sys.exit(f"verify_packs: {what} failed ({done.returncode}):\n{done.stdout}{done.stderr}")
    return done


def catalog_languages() -> list[str]:
    """The languages the catalog holds a localization for, sorted."""
    strings = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    return sorted({language for entry in strings.values() for language in entry.get("localizations", {})})


def build_probe() -> Path:
    """Compile the probe into build/l10n-packs/probe, unless it is newer than every source."""
    probe = WORK / "probe"
    if probe.exists() and all(probe.stat().st_mtime >= source.stat().st_mtime for source in PROBE_SOURCES):
        return probe
    run(
        ["xcrun", "swiftc", "-D", "PACK_PROBE", "-O", "-o", str(probe), *map(str, PROBE_SOURCES)],
        "compiling the probe",
    )
    return probe


def main() -> int:
    """Compile the catalog, compact a copy, and compare every lookup; 0 when all are identical."""
    languages = catalog_languages()
    xcode, compact = WORK / "xcode", WORK / "compact"
    for folder in (xcode, compact):
        folder.mkdir(parents=True, exist_ok=True)

    # 1. The files as Xcode ships them (xcstringstool warns about ambiguous plurals; the sync tools report those).
    run(["xcrun", "xcstringstool", "compile", "--output-directory", str(xcode), str(CATALOG)], "xcstringstool compile")

    # 2. A compacted copy, language by language, overwriting what an earlier run left.
    for language in languages:
        source = xcode / f"{language}.lproj"
        if not source.is_dir():
            sys.exit(f"verify_packs: xcstringstool wrote no {language}.lproj for the catalog's language {language}")
        shutil.copytree(source, compact / source.name, dirs_exist_ok=True)
    changed, errors = compact_packs.compact_folder(compact)
    if errors:
        sys.exit("verify_packs: compact_packs refused:\n" + "\n".join(errors))

    # 3. Every lookup, in both.
    probe = build_probe()
    done = subprocess.run([str(probe), str(xcode), str(compact), str(CATALOG), *languages], capture_output=True, text=True, check=False)
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    if done.returncode != 0:
        print("verify_packs: FAILED: a lookup differs between Xcode's files and the compact files", file=sys.stderr)
        return 1
    print(f"verify_packs: ok ({changed} files compacted; every lookup in {', '.join(languages)} is unchanged)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
