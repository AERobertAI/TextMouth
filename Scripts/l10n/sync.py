"""sync.py: what `l10n.py sync` does, without the compiler (FR39, phase 7). Standard library only.

The code is the English's one source (research/STRINGS-SYSTEM-DESIGN-2026-11-21.md, "Where the English lives, and the sync
tool"). Every interface string is an `InterfaceText.line("<ID>", "<English>")` call under a `// Translators: <note>` line.
This reads those calls with the lexer (`interface_calls.py`, a couple of seconds for the whole of `TextMouth/`, no build and
no heavy-work lock) and brings the catalog, which is keyed by ID, into step with them:

- **A new ID** gets its English as `en` (state `translated`), its notes as the comment, and `extractionState` `manual`.
- **An ID the code no longer has** is marked stale, for `prune` (which also retires its ID); one that comes back is revived.
- **An ID whose English changed** gets the new English as `en` (its English plural forms are dropped: the engine shows the
  pack's English forms whenever they fit, so an old form would be heard; `check` fails until `plural` writes new ones), and
  every other language's finished translation becomes `needs_review`, so that it keeps shipping, as Xcode does.
- **A comment** follows the notes above the calls of its ID.

It refuses, and writes nothing, an ID outside the pattern or retired, one ID with two English texts, a call without a note,
two calls on one line, and an ID or English that is not one plain literal (see `read_code`). The places of each ID go to
`build/l10n/locations.json`, which `todo` reads.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Set

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import catalog  # noqa: E402  (imported by path, after sys.path is set)
import ids  # noqa: E402
import interface_calls  # noqa: E402
import translate  # noqa: E402

# The state an entry's units take when the English they translate has changed.
NEEDS_REVIEW = "needs_review"
# The value of `extractionState` of an entry the code holds (Xcode never marks a `manual` entry stale) and of one it does not.
MANUAL, STALE = "manual", "stale"


@dataclass
class Found:
    """What the code holds for one ID: its English (as the catalog holds it: `%` doubled in a literal with interpolations,
    `\\(number: n)` as `%lld`, any other interpolation as `%@`), the distinct notes above its calls, and their places."""

    english: str
    notes: Set[str] = field(default_factory=set)
    places: List[dict] = field(default_factory=list)   # [{"file", "line"}], sorted and without repeats


def read_code(root: Path):
    """({ID: Found}, [calls read], the sentences that refuse the sync) for the `InterfaceText.line` calls under `root`'s
    `TextMouth/`. A refusal is a sentence that starts with the place of the call: a call that is not one plain ID literal and one
    plain English literal; an ID outside the pattern or retired; a call without a note directly above it, or sharing its line
    with another; and one ID given two English texts (and so two sets of placeholders), each named with its place."""
    root = Path(root)
    by_file = interface_calls.calls_in_tree(root)
    problems = interface_calls.problems_of(root, by_file, ids.retired_ids(root))
    found: Dict[str, Found] = {}
    first_place: Dict[str, str] = {}
    calls = [call for name in sorted(by_file) for call in by_file[name]]
    for call in calls:
        if call.id is None or call.english is None:
            continue
        entry = found.get(call.id)
        if entry is None:
            entry = found[call.id] = Found(call.english)
            first_place[call.id] = call.where()
        elif entry.english != call.english:
            problems.append(f"{call.where()}: the ID {call.id!r} has the English {call.english!r} here, but "
                            f"{entry.english!r} at {first_place[call.id]} (one ID is one English text: give this call its own ID)")
        if call.note:
            entry.notes.add(call.note)
        place = {"file": call.file, "line": call.line}
        if place not in entry.places:
            entry.places.append(place)
    for entry in found.values():
        entry.places.sort(key=lambda place: (place["file"], place["line"]))
    return found, calls, sorted(set(problems))


def joined_notes(notes) -> str:
    """An ID's comment from its calls' notes: the distinct notes in code-point order, one to a line (the order a comment of
    several notes has always been written in, so that merges agree)."""
    return "\n".join(sorted(notes))


def english_unit(text: str) -> dict:
    """The `en` localization that holds `text` as one plain string in state `translated`."""
    return translate.plain_localization(text, "translated")


def mark_needs_review(node) -> None:
    """Sets every finished unit under `node` (a localization, or a part of one) to `needs_review`, in place: a unit in any
    other state (`new`, `needs_review`) is left as it is. Plural forms, variations, and substitutions are walked."""
    if not isinstance(node, dict):
        return
    unit = node.get("stringUnit")
    if isinstance(unit, dict) and unit.get("state") in catalog.DONE_STATES:
        unit["state"] = NEEDS_REVIEW
    for kind in node.get("variations", {}).values():
        for child in kind.values():
            mark_needs_review(child)
    for child in node.get("substitutions", {}).values():
        mark_needs_review(child)


class Report:
    """What a sync did to the catalog: the IDs it added, those that became stale, those no longer stale, those whose English
    changed, those whose comment changed, and the English bytes before and after."""

    def __init__(self):
        self.added: List[str] = []
        self.stale: List[str] = []
        self.revived: List[str] = []
        self.english_changed: List[str] = []
        self.comments: List[str] = []
        self.bytes_before = self.bytes_after = 0

    def changed(self) -> bool:
        """Whether the sync changed the catalog at all."""
        return bool(self.added or self.stale or self.revived or self.english_changed or self.comments)


def current_english(cat: catalog.Catalog, identifier: str):
    """The English the catalog holds for `identifier` as the code writes it: its plain text, or a plural's `other` form
    (the form the code's English is); None when it holds none."""
    english = translate.english_values(cat, identifier)
    return translate.reference_of(english) if english else None


def sync_catalog(cat: catalog.Catalog, found: Dict[str, Found]) -> Report:
    """Brings `cat` (keyed by ID) into step with `found` (see read_code), in place, and returns the Report. Nothing is
    written to disk. IDs are visited in code-point order, so that a report and a run twice are the same."""
    report = Report()
    report.bytes_before = cat.english_bytes()
    for identifier in sorted(found):
        wanted, entry = found[identifier], cat.strings.get(identifier)
        comment = joined_notes(wanted.notes)
        if entry is None:
            cat.strings[identifier] = {"comment": comment, "extractionState": MANUAL,
                                       "localizations": {cat.source_language: english_unit(wanted.english)}}
            report.added.append(identifier)
            continue
        if entry.get("extractionState") != MANUAL:
            if entry.get("extractionState") == STALE:
                report.revived.append(identifier)
            entry["extractionState"] = MANUAL
        if current_english(cat, identifier) != wanted.english:
            report.english_changed.append(identifier)
            localizations = entry.setdefault("localizations", {})
            localizations[cat.source_language] = english_unit(wanted.english)
            for language, node in localizations.items():
                if language != cat.source_language:
                    mark_needs_review(node)
        if comment and entry.get("comment") != comment:
            entry["comment"] = comment
            report.comments.append(identifier)
    for identifier in sorted(set(cat.strings) - set(found)):
        entry = cat.strings[identifier]
        if entry.get("extractionState") != STALE:
            entry["extractionState"] = STALE
            report.stale.append(identifier)
    report.bytes_after = cat.english_bytes()
    return report


def locations_of(found: Dict[str, Found]) -> Dict[str, List[dict]]:
    """{ID: its places}, for build/l10n/locations.json (`todo` reads the files and lines of each string)."""
    return {identifier: found[identifier].places for identifier in sorted(found)}


def retire(root: Path, identifiers) -> List[str]:
    """Appends to `retired-ids.txt` each of `identifiers` it does not hold yet (the file keeps its header and order; the new
    IDs go at the end, one a line, sorted), so that no later sync accepts the ID again; returns those it appended."""
    already = ids.retired_ids(root)
    fresh = sorted(set(identifiers) - already)
    if fresh:
        path = Path(root) / ids.RETIRED_PATH
        text = path.read_text(encoding="utf-8") if path.is_file() else ""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text + ("" if not text or text.endswith("\n") else "\n") + "".join(f"{ident}\n" for ident in fresh),
                        encoding="utf-8")
    return fresh
