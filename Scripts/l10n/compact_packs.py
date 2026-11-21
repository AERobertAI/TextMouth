#!/usr/bin/env python3
"""Writes an app's compiled language files compact (TL16, FR34).

Xcode compiles the String Catalog (TextMouth/Localization/Localizable.xcstrings)
into one `<lang>.lproj/Localizable.strings` and one `Localizable.stringsdict`
per language, and writes both as XML property lists: every entry costs about
80 bytes of markup beyond its text. The catalog stays the wordy, editable
source; what ships is rewritten here, in the build, before the app is signed:

  * each `.strings` becomes whichever of two forms is smaller (TL18): Apple's
    text form, UTF-8, `"key"="value";` with no whitespace, or a binary property
    list, which stores a non-ASCII string in two bytes a character where UTF-8
    needs three for Chinese, Japanese, and Korean, and is larger for any
    language that is mostly ASCII or Latin. Entries are in code-point order of
    their keys so that the same catalog gives the same bytes in every build
    (`make check` is a reproducibility gate), and a tie goes to the text form;
  * each `.stringsdict` becomes a binary property list (the text form would be
    larger for plurals);
  * across the languages of a folder, two entries Foundation can do without are
    left out (TL18, `squeeze_tables`): a plural entry whose forms are all one
    text (always so in a language with only `other`: Chinese, Japanese, Korean)
    is written as a plain `.strings` entry, and a plain entry whose text is its
    key is dropped, since Foundation returns the key for a key it cannot find
    (kept when English's tables hold that key as something else).

Nothing may change what a lookup returns, so every file is read back with
Apple's own parser (`plutil`) after it is rendered, and the dictionary that
comes back must equal the dictionary written (the file's own, less what the
squeeze left out: `make l10n-check` compares every lookup through `Bundle`,
before and after, with the same language files in one bundle). On any difference or
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
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Apple's property-list tool, the parser the system's own lookup agrees with.
PLUTIL = "/usr/bin/plutil"

# The two kinds of language file Xcode compiles a catalog into.
STRINGS_SUFFIX = ".strings"
STRINGSDICT_SUFFIX = ".stringsdict"

# The forms each kind of language file may be written in once compact (TL18).
STRINGS_FORMS = ("text", "binary")
STRINGSDICT_FORMS = ("binary",)

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


def render_strings_binary(table: dict[str, str]) -> bytes:
    """A binary property list of a string table, keys sorted: the other form a `.strings` may take (TL18).

    plistlib writes a string of ASCII as one byte a character and any other as UTF-16 (two bytes for each
    character of Chinese, Japanese, and Korean), and keeps one copy of a string that appears twice.
    Raises CompactError for an entry that is not a string pair, as `render_strings` does.
    """
    for key, value in table.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise CompactError(f"entry {key!r} is not a string pair, so it is not a plain .strings table")
    try:
        return plistlib.dumps(table, fmt=plistlib.FMT_BINARY, sort_keys=True)
    except UnicodeEncodeError as error:
        raise CompactError(f"text that UTF-16 cannot hold: {error}") from error


def render_smaller_strings(table: dict[str, str]) -> bytes:
    """The smaller of a string table's two forms, text or binary; the text form when they are the same size.

    A form that cannot be written (a lone surrogate defeats both, a non-string entry too) raises CompactError
    from `render_strings`, which is tried first, so the error is the text form's.
    """
    text = render_strings(table)
    binary = render_strings_binary(table)
    return binary if len(binary) < len(text) else text


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

# ---------------------------------------------------------------------------
# Squeezing (TL18)
# ---------------------------------------------------------------------------

# The language Foundation falls back to for a key a language's table lacks: the app's development region.
DEVELOPMENT_LANGUAGE = "en"

# Tables whose missing keys are not answered with the key: InfoPlist.strings falls back to the Info.plist's own
# value, so an entry equal to its key is not redundant there (item 2 leaves such a table alone).
TABLES_WITH_OTHER_DEFAULTS = frozenset({"InfoPlist"})

# The keys of a `.stringsdict` entry that Xcode compiles from a plural string, and the plural categories.
FORMAT_KEY = "NSStringLocalizedFormatKey"
SPEC_TYPE_KEY = "NSStringFormatSpecTypeKey"
VALUE_TYPE_KEY = "NSStringFormatValueTypeKey"
PLURAL_RULE = "NSStringPluralRuleType"
PLURAL_CATEGORIES = frozenset({"zero", "one", "two", "few", "many", "other"})

# A format that is nothing but one plural variable: `%#@value@` or `%2$#@value@` (capturing the position and name).
_WHOLE_VARIABLE = re.compile(r"^%(?:(\d+)\$)?#@([A-Za-z0-9_]+)@$")
# A literal percent sign, or the start of a format specifier with its optional position (`%2$`).
_SPECIFIER_START = re.compile(r"%%|%(?:(\d+)\$)?")


def plain_text_of_plural(entry: Any) -> str | None:
    """The one text of a plural entry whose forms are all the same, or None when the entry must stay as it is.

    An entry is merged only when it is exactly: one variable, whose rule is the plural rule, and the format
    nothing but that variable, with every category's text identical and `other` among them (so no count can
    reach a category without a form). Then Foundation reads the same text for every count, and a plain
    `.strings` entry holding it formats the same. Anything else (a second variable, a format with text around
    the variable, an unknown key, a form that is not text) stays a `.stringsdict` entry.

    A variable that is not the first argument (`%2$#@value@`) hands its form that argument, so a form's own
    specifier without a position would read argument 1 as a plain entry: such a form stays too.
    """
    if not isinstance(entry, dict) or len(entry) != 2 or not isinstance(entry.get(FORMAT_KEY), str):
        return None
    whole = _WHOLE_VARIABLE.match(entry[FORMAT_KEY])
    variable = entry.get(whole.group(2)) if whole else None
    if not isinstance(variable, dict) or variable.get(SPEC_TYPE_KEY) != PLURAL_RULE:
        return None
    forms = {name: text for name, text in variable.items() if name not in (SPEC_TYPE_KEY, VALUE_TYPE_KEY)}
    if "other" not in forms or not set(forms) <= PLURAL_CATEGORIES:
        return None
    texts = set(forms.values())
    if len(texts) != 1 or not all(isinstance(text, str) for text in texts):
        return None
    (text,) = texts
    if whole.group(1) not in (None, "1"):
        # Every specifier of the text must say which argument it takes.
        if any(match.group(0) != "%%" and match.group(1) is None for match in _SPECIFIER_START.finditer(text)):
            return None
    return text


@dataclass
class Squeezed:
    """The tables after the squeeze, by file path, and what it did."""

    tables: dict[Path, dict[str, Any]]
    merged: int = 0
    dropped: int = 0


def squeeze_tables(
    resources: Path, tables: dict[Path, dict[str, Any]], merge: bool = True, drop: bool = True
) -> Squeezed:
    """The language files' tables without what a lookup does not need (TL18); `tables` itself is not changed.

    Item 3: a plural entry whose forms are all one text (`plain_text_of_plural`) becomes a plain `.strings` entry
    of the same language, unless that language's `.strings` already holds the key.

    Item 2: a plain entry whose text is exactly its key is left out, since Foundation returns the key for a key
    it cannot find (not in `TABLES_WITH_OTHER_DEFAULTS`, whose missing keys have another answer). Foundation looks in the language's own tables, then in the development language's, so the
    entry stays when the development language holds that key with another text (a plural entry, or a plain one
    that differs), and when its own language also holds the key as a plural entry.

    Every table name (`Localizable`) is squeezed on its own, across the languages. `merge` and `drop` switch
    item 3 and item 2 off, which the size measurements use to count what each saves.
    """
    work = {path: dict(table) for path, table in tables.items()}
    merged = dropped = 0

    def table_at(language: str, name: str, suffix: str) -> dict[str, Any]:
        """The working table of a language's file, created empty (and written only if it gains entries)."""
        return work.setdefault(resources / f"{language}.lproj" / f"{name}{suffix}", {})

    names = sorted({path.stem for path in tables})
    for name in names:
        languages = sorted({path.parent.name.removesuffix(".lproj") for path in tables if path.stem == name})
        # Item 3, language by language.
        for language in languages:
            plurals = table_at(language, name, STRINGSDICT_SUFFIX)
            plain = table_at(language, name, STRINGS_SUFFIX)
            for key in sorted(plurals):
                text = plain_text_of_plural(plurals[key]) if merge else None
                if text is not None and key not in plain:
                    plain[key] = text
                    del plurals[key]
                    merged += 1
        # Item 2, against the development language's tables as they now are.
        english_plurals = table_at(DEVELOPMENT_LANGUAGE, name, STRINGSDICT_SUFFIX) if DEVELOPMENT_LANGUAGE in languages else {}
        english_plain = table_at(DEVELOPMENT_LANGUAGE, name, STRINGS_SUFFIX) if DEVELOPMENT_LANGUAGE in languages else {}
        for language in languages:
            plain = table_at(language, name, STRINGS_SUFFIX)
            plurals = table_at(language, name, STRINGSDICT_SUFFIX)
            for key in sorted(plain if drop and name not in TABLES_WITH_OTHER_DEFAULTS else ()):
                if plain[key] != key or key in plurals:
                    continue
                # Falling back to English must still give the key: English's own copy is dropped (or is the key).
                if language != DEVELOPMENT_LANGUAGE and (key in english_plurals or english_plain.get(key, key) != key):
                    continue
                del plain[key]
                dropped += 1
    return Squeezed(work, merged, dropped)


def write_table(path: Path, table: dict[str, Any], original_bytes: bytes | None) -> bool:
    """Write `table` compact at `path`; True when the file changed. Raises CompactError.

    `original_bytes` is what the file holds now (None when it does not exist), so a file that already holds
    these bytes is left alone, not even touched. The new bytes are read back with Apple's parser and must
    equal `table` before anything is written, so a failure leaves `path` exactly as it was.
    """
    try:
        if path.suffix == STRINGS_SUFFIX and table:
            compact = render_smaller_strings(table)
        else:
            # A `.stringsdict`, or an empty `.strings`: an empty text file is not one Apple's parser reads, but an
            # empty binary list is, so a table left with nothing in it is written as one.
            compact = render_stringsdict(table)
        if compact == original_bytes:
            return False
        difference = first_difference(table, apple_parse(compact))
        if difference:
            raise CompactError(f"a lookup would change: {difference}")
    except CompactError as error:
        raise CompactError(f"{path}: {error}") from error
    path.write_bytes(compact)
    return True


def read_table(path: Path) -> dict[str, Any]:
    """The dictionary a language file holds now. Raises CompactError for a file that is not a dictionary."""
    try:
        table = read_original(path.read_bytes())
        if not isinstance(table, dict):
            raise CompactError("it is not a dictionary")
    except CompactError as error:
        raise CompactError(f"{path}: {error}") from error
    return table


def compact_file(path: Path) -> bool:
    """Rewrite one language file compact, if it is not already; True when it changed.

    Only this file is read, so nothing is squeezed (TL18's items 2 and 3 compare languages: `compact_folder`).
    The new bytes are checked with Apple's parser before anything is written,
    so a failure leaves `path` exactly as it was. Raises CompactError.
    """
    original = read_table(path)
    if not original:
        return False  # An empty table has no text form Apple's parser reads, and nothing to save.
    return write_table(path, original, path.read_bytes())


def language_files(resources: Path) -> list[Path]:
    """Every `.strings` and `.stringsdict` directly inside a `*.lproj` folder of `resources`, sorted."""
    found: list[Path] = []
    for suffix in (STRINGS_SUFFIX, STRINGSDICT_SUFFIX):
        found.extend(path for path in resources.glob(f"*.lproj/*{suffix}") if path.is_file())
    return sorted(found)


def compact_folder(resources: Path) -> tuple[int, list[str]]:
    """Compact every language file under `resources`; returns (files changed, error messages).

    The languages are squeezed first (`squeeze_tables`, TL18), so each table is written without what Foundation
    can do without. Every file is tried even after a failure, so one run names every file at fault; when a file
    cannot be read nothing is squeezed, since a table not seen could hold what a squeeze relies on, and each
    readable file is only compacted.
    """
    result = compact_folder_counting(resources)
    return result.changed, result.errors


@dataclass
class FolderResult:
    """What compacting a folder did: files written, errors, and what the squeeze left out."""

    changed: int = 0
    errors: list[str] = field(default_factory=list)
    # Plural entries rewritten as plain entries (item 3), and entries left out for equalling their key (item 2).
    merged: int = 0
    dropped: int = 0


def compact_folder_counting(resources: Path) -> FolderResult:
    """`compact_folder`, with the squeeze's counts as well."""
    result = FolderResult()
    files = language_files(resources)
    # Every file is read before any is written, since a squeeze looks across languages.
    tables: dict[Path, dict[str, Any]] = {}
    for path in files:
        try:
            tables[path] = read_table(path)
        except CompactError as error:
            result.errors.append(str(error))
    if result.errors:
        # A table that could not be read might hold what a squeeze relies on: compact the readable ones as they are.
        for path in files:
            try:
                result.changed += compact_file(path)
            except CompactError as error:
                if str(error) not in result.errors:
                    result.errors.append(str(error))
        return result

    squeezed = squeeze_tables(resources, tables)
    result.merged, result.dropped = squeezed.merged, squeezed.dropped
    for path, table in squeezed.tables.items():
        try:
            if not table and path not in tables:
                continue  # A table that was never there and holds nothing is not created.
            if not table and path in tables and not tables[path]:
                continue  # An empty table that came empty has nothing to save.
            result.changed += write_table(path, table, path.read_bytes() if path in tables else None)
        except CompactError as error:
            result.errors.append(str(error))
    return result


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

    A `.strings` that is XML, or a `.stringsdict` that is not binary, is a
    problem: the build phase did not run, or did not finish. A `.strings` in
    either compact form, text or binary, is accepted: the build phase writes
    whichever is smaller for the language (TL18).
    """
    lines: list[str] = []
    problems: list[str] = []
    for path in language_files(resources):
        form = file_form(path)
        name = f"{path.parent.name}/{path.name}"
        lines.append(f"{path.stat().st_size:>9,} bytes  {form:<6} {name}")
        accepted = STRINGS_FORMS if path.suffix == STRINGS_SUFFIX else STRINGSDICT_FORMS
        if form not in accepted:
            problems.append(f"{name} is {form}, not {' or '.join(accepted)}")
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
    result = compact_folder_counting(folders[0])
    for error in result.errors:
        print(f"compact_packs: error: {error}", file=sys.stderr)
    if result.errors:
        return 1
    total = len(language_files(folders[0]))
    print(
        f"compact_packs: {result.changed} language file(s) compacted, {total - result.changed} already compact; "
        f"{result.merged} plural entr(ies) written plain, {result.dropped} entr(ies) equal to their key left out"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
