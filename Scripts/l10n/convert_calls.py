#!/usr/bin/env python3
"""convert_calls: rewrite `String(localized: "…")` calls as `InterfaceText.line("<ID>", "…")` (FR39, phase 5).

    python3 -I -B Scripts/l10n/convert_calls.py [--check] [--root DIR] [--locations FILE] [FILE ...]

Each call of the named files (default: every Swift file under TextMouth/) is tied to its catalog key the way the
scanner and `ids.py` tie it (the key `ids.json` holds for its text; where `%@` and `%lld` keys read alike, the
translator's note, then `build/l10n/locations.json`) and to its ID (the key's own, or, for a split key, the one whose use
names the call's site). The call becomes

    InterfaceText.line("<ID>", "<the literal as written, each interpolation that fills a %lld as \\(number: x)>")

and every other byte of the file stays as it was, the `// Translators:` line above the call included. A call it cannot tie
to exactly one key and one ID, one with arguments besides the literal, a literal that is multi-line or raw, and a form
that is not `String(localized:)` are refused and named with their file and line; the rest of the file still converts.
Each new call is read back by `interface_calls.find_calls` and must hold the key as its English and the ID, or it is
refused too.

    --check   write nothing: report how many calls would convert, in how many files, and every refusal.

Exit status: 0 when every call converted (or would), 1 when any was refused, 2 for a bad command line.
The standard library only; it runs under Python 3.9.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import catalog  # noqa: E402
import ids  # noqa: E402
import interface_calls  # noqa: E402
from swiftscan.classify import is_interface_text_english  # noqa: E402
from swiftscan.lexer import Literal  # noqa: E402

EXIT_OK = 0       # every call converted, or would
EXIT_REFUSED = 1  # a call was refused
EXIT_USAGE = 2    # a bad command line

# The text before a converted literal: `String(`, any `//` comment lines the code puts between it and its label (a note
# can sit there), and `localized:`, ending where the literal starts. Group 1 is `String(`, group 2 what lies between.
_OPENING = re.compile(r"(?<![\w.])(String\s*\()((?:\s*//[^\n]*)*\s*)localized\s*:\s*\Z")
# The text after the literal: the closing parenthesis, and nothing else (no `comment:`, `table:`, `defaultValue:`).
_CLOSING = re.compile(r"\s*\)")
# How far back from a literal the opening can start.
_LOOKBACK = 800
# The two kinds of placeholder a key holds, and what a converted interpolation looks like for each.
_NUMBER_TYPE = "int64"
_TEXT_TYPE = "object"


@dataclass
class Refusal:
    """A call that could not be converted, and why."""

    file: str
    line: int
    reason: str

    def __str__(self) -> str:
        return f"{self.file}:{self.line}: {self.reason}"


@dataclass
class Conversion:
    """A call that was (or would be) rewritten."""

    file: str
    line: int
    key: str
    id: str


@dataclass
class Result:
    """What converting some files did: the conversions, the refusals, and the new text of each file that changed."""

    converted: List[Conversion] = field(default_factory=list)
    refused: List[Refusal] = field(default_factory=list)
    texts: Dict[str, str] = field(default_factory=dict)


def interpolation_code(text: str, hole: Tuple[int, int]) -> str:
    """The code inside the interpolation at `hole` (offset of its backslash, offset past its closing parenthesis)."""
    return text[hole[0] + 2:hole[1] - 1]


def converted_literal(text: str, lit: Literal, key: str) -> Tuple[Optional[str], str]:
    """(the literal's new source, "") for the literal `lit` of `text` whose key is `key`, or (None, why not).

    The source stays as written but for each interpolation that fills a `%lld`, which becomes `\\(number: code)`; the
    key's placeholders, in order, say which those are."""
    if lit.multiline or text[lit.start] != '"':
        return None, "the literal is multi-line or raw, which this tool does not convert"
    source = text[lit.start:lit.end]
    if not lit.interps:
        return source, ""
    kinds = [placeholder.type for placeholder in catalog.placeholders(key)]
    if len(kinds) != len(lit.interps):
        return None, f"the key {key!r} has {len(kinds)} placeholders but the literal {len(lit.interps)} interpolations"
    out: List[str] = []
    cursor = lit.start
    for hole, kind in zip(lit.interps, kinds):
        out.append(text[cursor:hole[0]])
        if kind == _NUMBER_TYPE:
            out.append(f"\\(number: {interpolation_code(text, hole)})")
        elif kind == _TEXT_TYPE:
            out.append(text[hole[0]:hole[1]])
        else:
            return None, f"the key {key!r} holds a placeholder of a kind this tool does not convert ({kind})"
        cursor = hole[1]
    out.append(text[cursor:lit.end])
    return "".join(out), ""


def call_start(text: str, lit: Literal, ident: str) -> Tuple[Optional[Tuple[int, str]], str]:
    """((offset where the `String(localized:` call starts, the text that replaces everything before the literal), "") or
    (None, why not).

    The call must be `String(`, `localized:`, the literal, and a closing parenthesis, with nothing else inside but
    whitespace and `//` comment lines before the label. The replacement is `InterfaceText.line(`, what lay between
    `String(` and `localized:` (so a note there stays directly above the literal's line), and the ID."""
    before = text[max(0, lit.start - _LOOKBACK):lit.start]
    opening = _OPENING.search(before)
    if opening is None:
        return None, "the literal is not the whole of a `String(localized: \"…\")` call (a block comment, another form, or another initializer)"
    if _CLOSING.match(text, lit.end) is None:
        return None, "the call has an argument besides the literal (`comment:`, `table:`, `defaultValue:`, ...)"
    prefix = f'InterfaceText.line({opening.group(2)}"{ident}", '
    return (lit.start - len(before) + opening.start(), prefix), ""


def check_new_call(path: str, snippet: str, key: str, ident: str) -> str:
    """"" when the new call `snippet` reads back as one call holding `ident` and the English `key`, else why not."""
    found = interface_calls.find_calls(snippet, path)
    if len(found) != 1 or found[0].problems:
        return f"the new call does not read back as one call ({'; '.join(p for c in found for p in c.problems) or len(found)})"
    if found[0].id != ident or found[0].english != key:
        return f"the new call reads back as {found[0].id!r} with the English {found[0].english!r}, not {ident!r} and {key!r}"
    return ""


def convert_file(path: str, text: str, sites: Sequence[Tuple[Literal, ids.Site]], table: dict) -> Tuple[str, List[Conversion], List[Refusal]]:
    """(the file's new text, its conversions, its refusals) for the file `path` whose source is `text` and whose localized
    literals, each with its site, are `sites`; `table` is ids.json."""
    converted: List[Conversion] = []
    refused: List[Refusal] = []
    edits: List[Tuple[int, int, str]] = []
    for lit, site in sites:
        def refuse(reason: str, lit: Literal = lit) -> None:
            """Records a refusal of the call at `lit`."""
            refused.append(Refusal(path, lit.line, reason))

        if is_interface_text_english(lit):
            continue  # a call converted already (the scanner counts its English as localized): nothing to do
        if lit.call != "String" or lit.label != "localized":
            refuse(f"a localized literal of a form this tool does not convert ({lit.call or 'no call'}(…))")
            continue
        if site.key is None:
            refuse(f"the text {lit.text!r} ties to no key: none in ids.json, or two it cannot choose between")
            continue
        ident = ids.id_for_site(table, site.key, site)
        if ident is None:
            refuse(f"the key {site.key!r} has no ID at this site ({site.selector()}): a split's uses must name it")
            continue
        start, why = call_start(text, lit, ident)
        literal, why_literal = converted_literal(text, lit, site.key)
        if start is None or literal is None:
            refuse(why or why_literal)
            continue
        # The new call from its start to the end of its English; the closing parenthesis stays as it was.
        replacement = start[1] + literal
        problem = check_new_call(path, replacement + ")", site.key, ident)
        if problem:
            refuse(problem)
            continue
        edits.append((start[0], lit.end, replacement))
        converted.append(Conversion(path, lit.line, site.key, ident))
    # The edits never overlap (each is one call), so applying them from the end keeps the earlier offsets true.
    for start, end, snippet in sorted(edits, reverse=True):
        text = text[:start] + snippet + text[end:]
    return text, converted, refused


def convert_tree(root: Path, files: Optional[Sequence[str]], locations: Optional[Path], write: bool) -> Result:
    """Converts the calls of `files` (paths from `root`; all of TextMouth/ when None), writing the changed files when `write`.

    Every file of the tree is scanned, since which functions take a localized resource depends on the whole tree."""
    table = ids.load_table(ids.table_path(root))
    wanted = None if files is None else set(files)
    result = Result()
    sites_by_file: Dict[str, List[Tuple[Literal, ids.Site]]] = {}
    for lit, site in ids.literal_sites(root, table["ids"], ids.load_locations(locations), wanted):
        sites_by_file.setdefault(lit.file, []).append((lit, site))
    for name in sorted(sites_by_file):
        original = (root / name).read_text(encoding="utf-8")
        text, converted, refused = convert_file(name, original, sites_by_file[name], table)
        result.converted += converted
        result.refused += refused
        if text != original:
            result.texts[name] = text
            if write:
                (root / name).write_text(text, encoding="utf-8")
    return result


def report(result: Result, write: bool) -> List[str]:
    """The lines to print: each refusal, then the totals."""
    lines = [str(refusal) for refusal in sorted(result.refused, key=lambda r: (r.file, r.line))]
    verb = "converted" if write else "would convert"
    files = len({c.file for c in result.converted})
    lines.append(f"convert_calls: {verb} {len(result.converted):,} calls in {files:,} files; refused {len(result.refused):,}.")
    return lines


def build_parser() -> argparse.ArgumentParser:
    """The command line's parser."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("files", nargs="*", help="Swift files, as paths from the repository root (default: all of TextMouth/)")
    parser.add_argument("--check", action="store_true", help="write nothing; report the calls it would convert and every refusal")
    parser.add_argument("--root", help="the repository to work on (default: the one this script is in)")
    parser.add_argument("--locations", help="build/l10n/locations.json, for sites the notes cannot settle "
                                            "(default: the main checkout's)")
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    """Runs the command and returns its exit status."""
    try:
        args = build_parser().parse_args(argv)
    except SystemExit as stop:  # argparse exits with 2 for a bad command line, 0 for --help
        return int(stop.code or 0)
    root = ids.repo_root(args.root)
    if not (root / "TextMouth").is_dir():
        print(f"convert_calls: {root} has no TextMouth/ folder", file=sys.stderr)
        return EXIT_USAGE
    missing = [name for name in args.files if not (root / name).is_file()]
    if missing:
        print(f"convert_calls: no such file under the repository: {', '.join(missing)}", file=sys.stderr)
        return EXIT_USAGE
    locations = Path(args.locations) if args.locations else ids.main_locations(root)
    result = convert_tree(root, args.files or None, locations, write=not args.check)
    print("\n".join(report(result, write=not args.check)))
    return EXIT_REFUSED if result.refused else EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
