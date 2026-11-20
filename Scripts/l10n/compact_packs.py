#!/usr/bin/env python3
"""Writes an app's compiled language files compact (TL16, FR34).

Xcode compiles the String Catalog (TextMouth/Localization/Localizable.xcstrings)
into one `<lang>.lproj/Localizable.strings` and one `Localizable.stringsdict`
per language, and writes both as XML property lists: every entry costs about
80 bytes of markup beyond its text. The catalog stays the wordy, editable
source; what ships is rewritten here, in the build, before the app is signed:

  * each `.strings` becomes Apple's text form, UTF-8, `"key"="value";` with no
    whitespace, entries in code-point order of their keys so that the same
    catalog gives the same bytes in every build (`make check` is a
    reproducibility gate);
  * each `.stringsdict` becomes a binary property list (the text form would be
    larger for plurals, and a binary `.strings` larger for any language with
    accents, since a binary list stores such a string as UTF-16).

Nothing may change what a lookup returns, so every file is read back with
Apple's own parser (`plutil`) after it is rendered, and the dictionary that
comes back must equal the dictionary the file started as. On any difference or
any error the original file is left in place, the file and the first
differing key are named on standard error, and the exit status is 1, so the
build fails rather than ship a changed lookup.

Usage (standard library only; the build runs it with the system's Python):

    python3 -I -B compact_packs.py RESOURCES_FOLDER      compact in place
    python3 -I -B compact_packs.py --verify FOLDER...    list each file's size
                                                         and fail on one that
                                                         is not compact

RESOURCES_FOLDER is the folder holding the app's `*.lproj` folders:
Contents/Resources in the Mac app, the bundle's root in the iPhone app.
Files that are not a `.strings` or `.stringsdict` in a `*.lproj` folder
directly inside it are left alone. Running it twice changes nothing the
second time.
"""

from __future__ import annotations

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path
from typing import Any

# Apple's property-list tool, the parser the system's own lookup agrees with.
PLUTIL = "/usr/bin/plutil"

# The two kinds of language file Xcode compiles a catalog into.
STRINGS_SUFFIX = ".strings"
STRINGSDICT_SUFFIX = ".stringsdict"

# How a binary property list begins, and an XML one (possibly after a BOM).
BINARY_MAGIC = b"bplist00"
XML_MARKERS = (b"<?xml", b"<plist")


class CompactError(Exception):
    """A file that cannot be compacted without a risk to a lookup."""


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# The characters the text form must escape inside its quotes. The backslash
# and the quote are escaped for the parser; a line break is written `\n`; every
# other control character (the C0 range, DEL, and the C1 range) becomes a
# `\Uxxxx` escape, so the file holds no raw control character that an editor,
# a diff, or a line-ending conversion could change. A tab is such a character.
_ESCAPES: dict[int, str] = {
    ord("\\"): "\\\\",
    ord('"'): '\\"',
    ord("\n"): "\\n",
}
for _code in [*range(0x00, 0x20), 0x7F, *range(0x80, 0xA0)]:
    _ESCAPES.setdefault(_code, "\\U%04X" % _code)


def escape_strings_text(text: str) -> str:
    """`text` as the inside of a quoted string of the `.strings` text form."""
    return text.translate(_ESCAPES)


def render_strings(table: dict[str, str]) -> bytes:
    """The compact text form of a string table: UTF-8, `"k"="v";`, no whitespace.

    Keys come in code-point order (Python sorts a str that way), so the same
    table always gives the same bytes. Raises CompactError for an entry that
    is not a string pair, or text the text form cannot hold (a lone surrogate).
    """
    parts: list[str] = []
    for key in sorted(table):
        value = table[key]
        if not isinstance(key, str) or not isinstance(value, str):
            raise CompactError(f"entry {key!r} is not a string pair, so it is not a plain .strings table")
        parts.append(f'"{escape_strings_text(key)}"="{escape_strings_text(value)}";')
    try:
        return "".join(parts).encode("utf-8")
    except UnicodeEncodeError as error:
        raise CompactError(f"text that UTF-8 cannot hold: {error}") from error


def render_stringsdict(table: dict[str, Any]) -> bytes:
    """A binary property list of a plural table, keys sorted (plistlib's default)."""
    return plistlib.dumps(table, fmt=plistlib.FMT_BINARY, sort_keys=True)


# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

def apple_parse(data: bytes) -> Any:
    """What Apple's parser (`plutil`) reads from `data`, in whatever form it is.

    It goes through JSON first, which keeps every character exact (an XML
    property list cannot hold a control character, and folds a carriage return
    into a line feed). A table with something JSON lacks, such as a date or a
    data block, falls back to XML read by plistlib. Raises CompactError when
    Apple's parser refuses the bytes.
    """
    for target in ("json", "xml1"):
        done = subprocess.run(
            [PLUTIL, "-convert", target, "-o", "-", "-"], input=data, capture_output=True, check=False
        )
        if done.returncode == 0:
            return json.loads(done.stdout) if target == "json" else plistlib.loads(done.stdout)
    message = done.stderr.decode("utf-8", "replace").strip()
    raise CompactError(f"Apple's parser refuses it: {message}")


def read_original(data: bytes) -> Any:
    """The dictionary a file holds now: plistlib reads an XML or binary list, Apple's parser the rest.

    A text-form `.strings` file (one already compact, or an old-style one) is
    not a property list plistlib knows, and an XML list with a control
    character is one expat refuses: Apple's parser reads both.
    """
    if data.startswith(BINARY_MAGIC) or data.lstrip(b"\xef\xbb\xbf \t\r\n").startswith(XML_MARKERS):
        try:
            return plistlib.loads(data)
        except Exception:  # plistlib is strict about XML's characters; Apple's parser is not.
            pass
    return apple_parse(data)


def first_difference(want: Any, got: Any, path: str = "") -> str | None:
    """The first place `got` differs from `want`, as a key path, or None when they are equal.

    Keys are visited in sorted order, so the report is the same every run.
    """
    if isinstance(want, dict) and isinstance(got, dict):
        for key in sorted(set(want) | set(got), key=str):
            where = f"{path}/{key}" if path else str(key)
            if key not in got:
                return f"{where}: missing after compacting"
            if key not in want:
                return f"{where}: appeared after compacting"
            found = first_difference(want[key], got[key], where)
            if found:
                return found
        return None
    if type(want) is not type(got) or want != got:
        return f"{path or '(whole file)'}: {want!r} became {got!r}"
    return None


# ---------------------------------------------------------------------------
# Compacting
# ---------------------------------------------------------------------------

def compact_file(path: Path) -> bool:
    """Rewrite one language file compact, if it is not already; True when it changed.

    The new bytes are checked with Apple's parser before anything is written,
    so a failure leaves `path` exactly as it was. Raises CompactError.
    """
    original_bytes = path.read_bytes()
    try:
        original = read_original(original_bytes)
        if not isinstance(original, dict):
            raise CompactError("it is not a dictionary")
        if not original:
            return False  # An empty table has no text form Apple's parser reads, and nothing to save.
        render = render_strings if path.suffix == STRINGS_SUFFIX else render_stringsdict
        compact = render(original)
        if compact == original_bytes:
            return False  # Already compact: left alone, not even touched.
        difference = first_difference(original, apple_parse(compact))
        if difference:
            raise CompactError(f"a lookup would change: {difference}")
    except CompactError as error:
        raise CompactError(f"{path}: {error}") from error
    path.write_bytes(compact)
    return True


def language_files(resources: Path) -> list[Path]:
    """Every `.strings` and `.stringsdict` directly inside a `*.lproj` folder of `resources`, sorted."""
    found: list[Path] = []
    for suffix in (STRINGS_SUFFIX, STRINGSDICT_SUFFIX):
        found.extend(path for path in resources.glob(f"*.lproj/*{suffix}") if path.is_file())
    return sorted(found)


def compact_folder(resources: Path) -> tuple[int, list[str]]:
    """Compact every language file under `resources`; returns (files changed, error messages).

    Every file is tried even after a failure, so one run names every file at fault.
    """
    changed = 0
    errors: list[str] = []
    for path in language_files(resources):
        try:
            changed += compact_file(path)
        except CompactError as error:
            errors.append(str(error))
    return changed, errors


# ---------------------------------------------------------------------------
# Verifying (make check)
# ---------------------------------------------------------------------------

def file_form(path: Path) -> str:
    """How a language file is stored: 'binary', 'xml', or 'text' (the `.strings` text form)."""
    with path.open("rb") as handle:
        head = handle.read(64)
    if head.startswith(BINARY_MAGIC):
        return "binary"
    if head.lstrip(b"\xef\xbb\xbf \t\r\n").startswith(XML_MARKERS):
        return "xml"
    return "text"


def verify_folder(resources: Path) -> tuple[list[str], list[str]]:
    """The report lines for `resources` (one per file: size, form, name) and the problems found.

    A `.strings` that is not the text form, or a `.stringsdict` that is not
    binary, is a problem: the build phase did not run, or did not finish.
    """
    lines: list[str] = []
    problems: list[str] = []
    for path in language_files(resources):
        form = file_form(path)
        name = f"{path.parent.name}/{path.name}"
        lines.append(f"{path.stat().st_size:>9,} bytes  {form:<6} {name}")
        wanted = "text" if path.suffix == STRINGS_SUFFIX else "binary"
        if form != wanted:
            problems.append(f"{name} is {form}, not {wanted}")
    return lines, problems


# ---------------------------------------------------------------------------
# Command line
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    """The command line; the exit status is 0 on success, 1 when a file was refused or is not compact, 2 for usage."""
    parser = argparse.ArgumentParser(description="Write an app's compiled language files compact.")
    parser.add_argument("--verify", action="store_true", help="report each language file's size and fail on one not compact")
    parser.add_argument("folders", nargs="+", metavar="FOLDER", help="a folder holding *.lproj folders (one only when compacting)")
    args = parser.parse_args(argv)
    folders = [Path(name) for name in args.folders]
    for folder in folders:
        if not folder.is_dir():
            print(f"compact_packs: {folder} is not a folder", file=sys.stderr)
            return 2

    if args.verify:
        failed = False
        for folder in folders:
            lines, problems = verify_folder(folder)
            if not lines:
                problems.append("no language files found")
            print(f"{folder}:")
            for line in lines:
                print(f"  {line}")
            for problem in problems:
                print(f"  NOT COMPACT: {problem}", file=sys.stderr)
            failed = failed or bool(problems)
        return 1 if failed else 0

    if len(folders) != 1:
        print("compact_packs: give one folder to compact", file=sys.stderr)
        return 2
    changed, errors = compact_folder(folders[0])
    for error in errors:
        print(f"compact_packs: error: {error}", file=sys.stderr)
    if errors:
        return 1
    print(f"compact_packs: {changed} language file(s) compacted, {len(language_files(folders[0])) - changed} already compact")
    return 0


if __name__ == "__main__":
    sys.exit(main())
