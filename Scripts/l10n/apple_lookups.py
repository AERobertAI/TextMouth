"""Finds the lookups into Apple's string tables in the app's Swift code, for the lint (FR39 phase 8).

Neither app ships a table of Apple's any more: the catalog is no resource, and the build compiles none. A `String(localized:)`,
`AttributedString(localized:)`, `LocalizedStringResource`, `String.LocalizationValue`, `LocalizedStringKey`,
`NSLocalizedString`, or SwiftUI literal key (`Text("...")`, `Button("...")`, `.accessibilityLabel("...")`, and the other calls
of `swiftscan/classify.py`'s table) would find nothing and show its key. Every interface line is an
`InterfaceText.line("<ID>", "<English>")` call, which TextMouth's own engine serves.

Two readings find them, and a line is named once:
- the scanner's: a literal that is the key of a localizing call has the status `apple-lookup` (see `classify.status_of`);
- this module's: the names themselves, in code (not in a comment or in the text of a string), which find a use with no literal
  (`String(localized: value)`, a parameter typed `LocalizedStringResource`) and the types.

Standard library only; it runs under Xcode's Python 3.9.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import interface_calls  # noqa: E402
from swiftscan import classify, scanner  # noqa: E402
from swiftscan.lexer import Literal, lex  # noqa: E402

# The forms that name a lookup into Apple's tables, each with the name the problem gives it.
FORMS: Tuple[Tuple["re.Pattern[str]", str], ...] = (
    (re.compile(r"\b(?:Attributed)?String\s*\(\s*localized\s*:"), "String(localized:)"),
    (re.compile(r"\bNSLocalizedString\b"), "NSLocalizedString"),
    (re.compile(r"\bLocalizedStringResource\b"), "LocalizedStringResource"),
    (re.compile(r"\bLocalizedStringKey\b"), "LocalizedStringKey"),
    (re.compile(r"\b(?:String\s*\.\s*)?LocalizationValue\b"), "String.LocalizationValue"),
)

# What every problem says to do.
REMEDY = ("no table of Apple's ships, so it would show its key: write InterfaceText.line(\"<ID>\", \"<English>\") with a "
          "`// Translators: ...` line directly above it (`python3 -I -B Scripts/l10n/ids.py suggest FILE:LINE` proposes the ID)")


@dataclass(frozen=True)
class Lookup:
    """One lookup into Apple's tables: where, and which form."""

    file: str   # the path from the repository root
    line: int   # the 1-based line
    form: str   # what it is: `String(localized:)`, `Text("...")`, ...

    def sentence(self) -> str:
        """The problem, as the lint prints it."""
        return f"{self.file}:{self.line}: {self.form} reads Apple's tables; {REMEDY}"


def from_literals(literals: Iterable[Literal]) -> List[Lookup]:
    """The lookups the scanner found: each literal that is the key of a localizing call other than InterfaceText.line, named by
    its call (`Text("...")`, `String(localized: "...")`)."""
    found = []
    for lit in literals:
        if lit.status != classify.APPLE_LOOKUP:
            continue
        call = lit.call or "a call"
        found.append(Lookup(lit.file, lit.line, f"{call}(\"...\")" if lit.label is None else f"{call}({lit.label}: \"...\")"))
    return found


def from_text(text: str, path: str) -> List[Lookup]:
    """The lookups that name one of FORMS in the code of the source `text` of `path`: not in a comment (a `//` before it on its
    line) and not in the text of a string literal."""
    if not any(word in text for word in ("Localiz", "localized")):
        return []
    literals = lex(text, path)
    found = []
    for pattern, form in FORMS:
        for match in pattern.finditer(text):
            if interface_calls.inside_comment_or_string(text, match.start(), literals):
                continue
            found.append(Lookup(path, text.count("\n", 0, match.start()) + 1, form))
    return found


def in_tree(root: Path, literals: Sequence[Literal]) -> List[Lookup]:
    """Every lookup into Apple's tables of `root`'s TextMouth/, in file and line order, a line named once: those the scanner
    found in `literals`, then those of the names, on the lines the first did not name."""
    found: Dict[Tuple[str, int], Lookup] = {(lookup.file, lookup.line): lookup for lookup in from_literals(literals)}
    for path in scanner.swift_files(root):
        name = path.as_posix()
        for lookup in from_text((root / path).read_text(encoding="utf-8", errors="replace"), name):
            found.setdefault((lookup.file, lookup.line), lookup)
    return [found[key] for key in sorted(found)]


def problems_of(lookups: Iterable[Lookup]) -> List[str]:
    """The sentences for `lookups`, one each."""
    return [lookup.sentence() for lookup in lookups]
