#!/usr/bin/env python3
"""rekey.py: the one-off that re-keys TextMouth's String Catalog by ID (FR39, phase 7). Standard library only.

Until now the catalog was keyed by each string's English text, and `ids.json` gave each key its ID. This writes the catalog
keyed by ID, so that the code's `InterfaceText.line("<ID>", "<English>")` calls and the catalog name a string the same way,
and the English is a value (`en`) like every other language's.

    rekey.py [--catalog PATH] [--ids PATH] [--reviews FOLDER] [--dry-run]

What it writes (nothing at all with --dry-run, which only prints the counts):
- **The catalog, keyed by ID.** Each key's entry goes under its ID. A split key (one English text that several uses give
  different IDs) has its entry copied to each of its IDs, every translation, its state, and the comment, so that nothing a
  person hears changes.
- **`en` on every entry.** The English the pack holds today: the `en` text or plural forms the entry has when the pack
  compiles them (every state but `new`, see `pack.compile_localization`), else a string unit holding the old key, in state
  `translated`. So the plurals keep their English forms, and the 383 entries whose `en` Xcode wrote in state `new` with
  positions (`%1$@ %2$@`, which nothing used) get the key's text in its place. Every entry is checked afterwards: the
  English the pack compiles from the new entry is the English it compiled from the old one, or nothing is written.
- **`"extractionState" : "manual"`** on every entry, so that Xcode never marks one stale.
- **The review records** (`reviews/*.json`): each fix gains `"id"` (or `"ids"`, a list, for a split key) beside its `key`;
  `key` and `english` stay as written.
- The catalog's layout is `catalog.py`'s (Xcode's own), so that `git diff` shows only what changed.

A second run refuses, writing nothing: a catalog whose keys are not the ID table's keys is already keyed by ID. Files this
leaves unused (`ids.json`, this script) are removed by the orchestrator at the merge.
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import catalog  # noqa: E402  (imported by path, after sys.path is set)
import pack  # noqa: E402

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
DEFAULT_CATALOG = ROOT / "TextMouth" / "Localization" / "Localizable.xcstrings"
DEFAULT_IDS = HERE / "ids.json"
DEFAULT_REVIEWS = HERE / "reviews"
# The value of every entry's extractionState once re-keyed: Xcode leaves a `manual` entry alone, whatever the code holds.
MANUAL = "manual"


class RekeyError(Exception):
    """A re-key that cannot go on: `problems` are sentences, and nothing was written."""

    def __init__(self, problems):
        super().__init__("; ".join(problems))
        self.problems = list(problems)


def english_unit(text):
    """The `en` localization that holds `text` as one plain string in state `translated`."""
    return {"stringUnit": {"state": "translated", "value": text}}


def rekeyed_entry(key, entry):
    """A copy of the old string `entry` (of English `key`) with its `en` localization and its extractionState set, and
    whether the entry already had English the pack compiles (True: `en` was kept as it was). The comment and every other
    localization are the copy's own."""
    fresh = copy.deepcopy(entry)
    fresh["extractionState"] = MANUAL
    localizations = fresh.setdefault("localizations", {})
    problems = []
    kept = pack.compile_localization(localizations.get("en"), "en", key, problems) is not None
    if problems:
        raise RekeyError(problems)
    if not kept:
        # No English the pack ships (none, or Xcode's positional unit in state `new`): the key is the English.
        localizations["en"] = english_unit(key)
    return fresh, kept


def english_of(entry, key):
    """The English the pack compiles from `entry` (see pack.compile_localization), or None: used to prove nothing changed."""
    problems = []
    found = pack.compile_localization(entry.get("localizations", {}).get("en"), "en", key, problems)
    if problems:
        raise RekeyError(problems)
    return found


class Result:
    """What a re-key made: the new `strings` ({ID: entry}), the counts, and the review records' texts to write."""

    def __init__(self):
        self.strings = {}
        self.kept_english = 0     # entries whose `en` the pack already compiled (the plurals), kept as they were
        self.added_english = 0    # entries that gained an `en` unit holding the key
        self.split_copies = 0     # the extra copies a split key's entry made (an entry given to n IDs adds n - 1)
        self.fixes_with_id = 0    # review fixes that gained "id"
        self.fixes_with_ids = 0   # review fixes that gained "ids" (a split key's)
        self.reviews = {}         # {file name: new text}


def rekey_strings(strings, table):
    """The Result of re-keying `strings` ({English key: entry}) by `table` ({key: [IDs]}, see pack.load_ids). Raises
    RekeyError, listing every problem, when a key has no ID, an ID would be given twice, or the catalog is already keyed by
    ID (none of its keys is in the table)."""
    known = [key for key in strings if key in table]
    if strings and not known:
        raise RekeyError(["the catalog is already keyed by ID (none of its keys is a key of the ID table); nothing was written"])
    problems = [f"{key!r}: the ID table has no ID for this key" for key in sorted(strings) if key not in table]
    owners = {}
    for key in sorted(known):
        for identifier in table[key]:
            if identifier in owners:
                problems.append(f"{identifier}: the ID is given to two keys, {owners[identifier]!r} and {key!r}")
            owners[identifier] = key
    if problems:
        raise RekeyError(problems)
    result = Result()
    for key in sorted(strings):
        identifiers = table[key]
        old_english = english_of(strings[key], key)
        for identifier in identifiers:
            fresh, kept = rekeyed_entry(key, strings[key])
            # The proof for this entry: the pack compiles the English it compiled before (the key, when there was none).
            if (english_of(fresh, identifier) or None) != (old_english if old_english is not None else key):
                raise RekeyError([f"{key!r}: the English the pack ships would change"])
            result.strings[identifier] = fresh
            result.kept_english += kept
            result.added_english += not kept
        result.split_copies += len(identifiers) - 1
    return result


def rekey_review(text, table, result):
    """The text of a review record file `text` with `"id"` (`"ids"` for a split key) added to each fix beside its `key`, which
    stays as written, and the file's layout as `json.dumps(indent=1)` writes it. Raises RekeyError for a fix whose key is
    not in the table. The counts go to `result`."""
    data = json.loads(text)
    for review in data.get("reviews", []):
        for fix in review.get("fixes", []):
            key = fix["key"]
            if key not in table:
                raise RekeyError([f"review fix for {key!r}: the ID table has no ID for this key"])
            identifiers = table[key]
            # Rebuilt so that the new field sits right after `key`, as a reader of the record expects.
            fields = {}
            for name, value in fix.items():
                fields[name] = value
                if name == "key":
                    fields["ids" if len(identifiers) > 1 else "id"] = identifiers if len(identifiers) > 1 else identifiers[0]
            fix.clear()
            fix.update(fields)
            if len(identifiers) > 1:
                result.fixes_with_ids += 1
            else:
                result.fixes_with_id += 1
    return json.dumps(data, indent=1, ensure_ascii=False) + "\n"


def run(catalog_path, ids_path, reviews_folder, dry_run=False):
    """Re-keys the catalog and the review records in place (nothing with `dry_run`); returns the Result. Raises RekeyError
    (nothing written) for what rekey_strings and rekey_review refuse. The review records are read and rewritten before
    any file is written, so a refusal leaves everything as it was."""
    cat = catalog.Catalog.load(catalog_path)
    table = pack.load_ids(ids_path)
    result = rekey_strings(cat.strings, table)
    review_files = sorted(Path(reviews_folder).glob("*.json")) if reviews_folder else []
    for file in review_files:
        result.reviews[file] = rekey_review(file.read_text(encoding="utf-8"), table, result)
    if not dry_run:
        cat.data["strings"] = result.strings
        cat.save(catalog_path)
        for file, text in result.reviews.items():
            file.write_text(text, encoding="utf-8")
    return result


def report(result, dry_run):
    """The lines that say what a run did (or, with `dry_run`, would do)."""
    verb = "would write" if dry_run else "wrote"
    return [f"rekey: {verb} {len(result.strings):,} IDs ({result.kept_english:,} `en` kept, {result.added_english:,} added, "
            f"{result.split_copies:,} copies made for split keys)",
            f"rekey: {verb} {result.fixes_with_id:,} review fixes with an id and {result.fixes_with_ids:,} with ids, "
            f"in {len(result.reviews)} files"]


def main(argv=None):
    """The command line: see the module's note. Exit status 0 when done, 1 when it refused."""
    parser = argparse.ArgumentParser(description="Re-key the String Catalog by ID (FR39 phase 7).")
    parser.add_argument("--catalog", default=str(DEFAULT_CATALOG))
    parser.add_argument("--ids", default=str(DEFAULT_IDS))
    parser.add_argument("--reviews", default=str(DEFAULT_REVIEWS))
    parser.add_argument("--dry-run", action="store_true", help="print the counts and write nothing")
    args = parser.parse_args(argv)
    try:
        result = run(args.catalog, args.ids, args.reviews, args.dry_run)
    except (RekeyError, pack.PackError) as error:
        for problem in (error.problems if isinstance(error, RekeyError) else [str(error)]):
            print(f"rekey: {problem}", file=sys.stderr)
        return 1
    for line in report(result, args.dry_run):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
