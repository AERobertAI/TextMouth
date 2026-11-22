#!/usr/bin/env python3
"""pack.py: the builder of TextMouth's interface-text pack, `Strings.pack` (FR39, phase 2).

The String Catalog (TextMouth/Localization/Localizable.xcstrings) stays the translators' database. This tool turns it
into the one file the apps read: the IDs, the English, the translators' notes, and one LZMA blob for each language.
Standard library only, and it runs under Xcode's /usr/bin/python3 (3.9): nothing here needs a later Python.

    pack.py build   --catalog PATH --out PATH [--max-id-length N] [--stamp PATH] [--force] [--no-stamp]
    pack.py verify  PACK --catalog PATH [--max-id-length N]
    pack.py compare A B
    pack.py size    PACK [--compare-window]
    pack.py corrupt-fixture --catalog PATH --out PATH    (a test-only pack: see below)

The format, version 1 (little-endian). research/STRINGS-SYSTEM-DESIGN-2026-11-21.md, "The pack", is the specification.
- The header, 48 bytes: the magic `TMSP`, the version (u16), flags (u16, zero), the SHA-256 of the bytes of the catalog
  file the pack was built from (32 bytes: `shasum -a 256` of the file gives it), the number of IDs (u32), and the number of
  blobs (u32).
- The directory, 28 bytes a blob: its name (12 bytes of ASCII padded with NULs), its offset from the start of the file,
  its compressed size, its raw size, and its entry count (u32 each).
- The blobs, each an xz stream (LZMA2), which Apple's COMPRESSION_LZMA decodes. In this order: `ids`, `notes`, `en`, and
  then the other languages by code.
- A blob's raw bytes are its entries in UTF-8, each ending with a NUL, the last one too. `ids` holds the IDs in code-point
  order; every other blob holds one entry for each ID, in that order. `notes` holds each ID's translators' note ("" for
  none). A language entry is "" (no translation: the reader uses English), the text, or U+0001 followed by the plural
  forms in the language's category order (`catalog.PLURAL_CATEGORIES`), joined by U+0001. A plural whose forms are all
  one text is written as that text, by the rule `compact_packs.py` already applies to the compiled tables.

What goes in is exactly what Xcode compiles today: every localization state except `new`.

The LZMA window. A blob's filter is given a dictionary size equal to the smallest power of two that is at least the
blob's raw size (and at least 4 KiB), with preset 9 extreme otherwise. For inputs this small it compresses as the 64 MiB
window does, give or take a few bytes, and it keeps the window a decoder may allocate small (`size --compare-window`
measures the difference).

Determinism. The same catalog gives the same bytes with the same Python. Compare entries, not compressed
bytes, between Pythons: two builds of liblzma may encode the same input differently. A stamp beside the output records
the catalog's hash, this file's, and the output's, so a build skips when none has changed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import lzma
import os
import re
import struct
import sys
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import catalog  # noqa: E402  (imported by path, after sys.path is set)
import compact_packs  # noqa: E402
import translate  # noqa: E402

# ---------------------------------------------------------------------------------------------------------------
# The format's constants.
# ---------------------------------------------------------------------------------------------------------------

MAGIC = b"TMSP"
FORMAT_VERSION = 1
# The magic, the version, the flags, the catalog's SHA-256, the number of IDs, the number of blobs.
HEADER = struct.Struct("<4sHH32sII")
# The name, then the offset, the compressed size, the raw size, and the entry count.
DIRECTORY_RECORD = struct.Struct("<12sIIII")
NAME_BYTES = 12
# The marker that starts a plural entry, and the separator between its forms; every entry ends with the terminator.
PLURAL_MARK = "\x01"
FORM_SEPARATOR = "\x01"
TERMINATOR = "\0"
# The first three blobs, whose names no language uses.
IDS_BLOB, NOTES_BLOB, ENGLISH_BLOB = "ids", "notes", "en"
# An ID: two to four dot-separated segments in lower camel case, at most MAX_ID_LENGTH characters.
ID_PATTERN = re.compile(r"[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*){1,3}")
MAX_ID_LENGTH = 48
# What an entry's format specifiers may be: `%@` and `%lld`, each with an optional position, and nothing else.
ALLOWED_SPECIFIER = re.compile(r"%(?:[1-9][0-9]*\$)?(?:@|lld)")
# LZMA2's smallest dictionary, and the preset every blob is compressed with.
MIN_WINDOW = 4096
PRESET = 9 | lzma.PRESET_EXTREME
# The most refusals a report lists before it says how many more there were.
LISTED_PROBLEMS = 200
# The entries a `compare` lists before it stops.
LISTED_DIFFERENCES = 50


class PackError(Exception):
    """A pack or an input that cannot be used; `problems` are sentences, each naming its key and language."""

    def __init__(self, problems):
        self.problems = [problems] if isinstance(problems, str) else list(problems)
        super().__init__("; ".join(self.problems[:3]))


# ---------------------------------------------------------------------------------------------------------------
# One language's entry for one ID, and how it is written.
#
# An entry is None (no translation), a str (one text), or a tuple of str (plural forms in category order).
# ---------------------------------------------------------------------------------------------------------------

def encode_entry(entry):
    """The text of one entry as the pack writes it, before its terminator: "" for None, the text, or U+0001 and the
    forms joined by U+0001."""
    if entry is None:
        return ""
    if isinstance(entry, tuple):
        return PLURAL_MARK + FORM_SEPARATOR.join(entry)
    return entry


def decode_entry(text):
    """The entry that `text` (as encode_entry writes it) stands for: None, a str, or a tuple of forms. The inverse of
    encode_entry for every entry the builder accepts: no text starts with U+0001, which no text may hold at all."""
    if text == "":
        return None
    if text.startswith(PLURAL_MARK):
        return tuple(text[1:].split(FORM_SEPARATOR))
    return text


def squeeze_forms(categories, forms):
    """The entry for plural `forms` (a tuple in the order of `categories`): the one text when all forms are the same,
    else the tuple. The rule is `compact_packs.plain_text_of_plural`'s, asked of a stringsdict entry made from the forms
    (a plain entry would read the same text for every count, so nothing a person hears changes)."""
    stringsdict_entry = {
        compact_packs.FORMAT_KEY: "%#@value@",
        "value": {compact_packs.SPEC_TYPE_KEY: compact_packs.PLURAL_RULE, compact_packs.VALUE_TYPE_KEY: "lld",
                  **dict(zip(categories, forms))},
    }
    one_text = compact_packs.plain_text_of_plural(stringsdict_entry)
    return forms if one_text is None else one_text


def describe_entry(entry):
    """A phrase for an entry in a report: its text, or its forms with a bar between them."""
    if entry is None:
        return "(none)"
    return " | ".join(entry) if isinstance(entry, tuple) else entry


# ---------------------------------------------------------------------------------------------------------------
# Reading what Xcode compiles from one localization of the catalog.
# ---------------------------------------------------------------------------------------------------------------

def compile_localization(localization, language, where, problems):
    """The entry Xcode compiles from `localization` (a catalog localization, or None): the text of a plain string, the
    forms of a plural, or None when nothing is compiled (no localization, or every part in state `new`).

    A refusal is appended to `problems`, named by `where` ("key [language]"): a device variation or a substitution (the
    catalog has none, and the pack has no place for one), a string that is both plain and plural, a plural form
    that is itself varied, and a plural category missing or extra for the language."""
    if not localization:
        return None
    unsupported = sorted(set(localization.get("variations", {})) - {"plural"})
    if unsupported or "substitutions" in localization:
        kinds = ", ".join(unsupported + (["substitutions"] if "substitutions" in localization else []))
        problems.append(f"{where}: a device variation or substitution ({kinds}), which the pack cannot hold")
        return None
    unit = localization.get("stringUnit")
    plural = localization.get("variations", {}).get("plural")
    if unit is not None and plural is not None:
        problems.append(f"{where}: the localization is both a plain string and plural forms")
        return None
    if unit is not None:
        # An empty value ships as no entry: the reader uses English, as it does for a string with no translation.
        return (unit.get("value", "") or None) if catalog.counts_as_text(unit.get("state", "new")) else None
    if plural is None:
        return None
    return compile_plural(plural, language, where, problems)


def compile_plural(plural, language, where, problems):
    """The entry of the plural forms `plural` ({category: node}) of `language`: the forms in the language's category order
    (squeezed to one text when they are all the same), or None when every form is in state `new`. A category the language
    lacks, or one it needs and the forms lack, is a refusal (a form in state `new` counts as lacking)."""
    try:
        categories = catalog.plural_categories(language)
    except KeyError as error:
        problems.append(f"{where}: {error.args[0]}")
        return None
    forms = {}
    for category, node in plural.items():
        if set(node) - {"stringUnit"}:
            problems.append(f"{where}: the {category} form holds a variation or substitution, which the pack cannot hold")
            return None
        unit = node.get("stringUnit", {})
        if catalog.counts_as_text(unit.get("state", "new")):
            forms[category] = unit.get("value", "")
    if not forms:
        return None
    extra = [category for category in forms if category not in categories]
    missing = [category for category in categories if category not in forms]
    if extra or missing:
        words = []
        if extra:
            words.append(f"has the plural form {', '.join(extra)} that the language does not use")
        if missing:
            words.append(f"lacks the plural form {', '.join(missing)} that the language needs")
        problems.append(f"{where}: " + " and ".join(words) + f" (it uses {', '.join(categories)})")
        return None
    return squeeze_forms(categories, tuple(forms[category] for category in categories))


# ---------------------------------------------------------------------------------------------------------------
# The refusals about an entry's texts.
# ---------------------------------------------------------------------------------------------------------------

def character_problems(text):
    """The sentences about the characters of one text (an interface line or a note): a control character other than a
    line feed or a tab, and text that UTF-8 cannot encode. (`translate.control_characters` is the rule `apply` uses.)"""
    problems = []
    controls = translate.control_characters(text)
    if controls:
        problems.append("control character " + ", ".join(f"U+{ord(character):04X}" for character in controls))
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        problems.append("text that UTF-8 cannot encode (a lone surrogate)")
    return problems


def text_problems(text):
    """The sentences about one interface line on its own: a format specifier other than `%@`, `%n$@`, `%lld`, `%n$lld`, and
    `%%`; a lone `%` in a text that is a format string; and its characters (see character_problems)."""
    problems = []
    for placeholder in catalog.placeholders(text):
        if not ALLOWED_SPECIFIER.fullmatch(placeholder.raw):
            problems.append(f"the specifier {placeholder.raw} is not one the pack allows (%@, %n$@, %lld, %n$lld, %%)")
    literals, lone, found = catalog.percent_signs(text)
    if lone and (literals or found):
        problems.append("a lone % that is no specifier, in a text that has specifiers (write %% for a percent sign)")
    return problems + character_problems(text)


def english_reference(english):
    """The English text the placeholders of other languages are compared with: the text itself, or a plural's `other`
    form (the last of the categories, which always has the number)."""
    return english[-1] if isinstance(english, tuple) else english


def entry_problems(entry, language, reference, check_placeholders):
    """The sentences about every text of `entry` in `language`: each text's own (see text_problems), and, when
    `check_placeholders`, its placeholders against `reference`'s. A `one` form may leave out the number where the
    language's `one` means exactly 1 ("Un libro"), as `translate.py`'s plural check allows. A plural form's sentence names
    its category."""
    if entry is None:
        return []
    problems = []
    if isinstance(entry, tuple):
        parts = list(zip(catalog.plural_categories(language), entry))
    else:
        parts = [(None, entry)]
    for category, text in parts:
        label = f"the {category} form: " if category else ""
        found = text_problems(text)
        if not text and category:
            found.append("empty text")
        if check_placeholders:
            may_drop = category == "one" and catalog.one_is_exactly_one(language)
            found += catalog.compare_placeholders(reference, text, may_drop_numbers=may_drop)
        problems += [label + sentence for sentence in found]
    return problems


# ---------------------------------------------------------------------------------------------------------------
# The plan of what the pack holds.
# ---------------------------------------------------------------------------------------------------------------

@dataclass
class Plan:
    """What a pack holds, decided before any byte is written: the `ids` in code-point order, and `blobs`, a list of
    (name, entries) in pack order, where `entries` has one entry (see encode_entry) for each ID, in that order. `digest`
    is the SHA-256 of the catalog file."""
    ids: list
    blobs: list
    digest: bytes = b""


def id_problems(identifier, max_length):
    """The sentences about one ID: outside the pattern, or longer than `max_length` characters."""
    problems = []
    if not ID_PATTERN.fullmatch(identifier):
        problems.append(f"the ID {identifier!r} is outside the pattern [a-z][A-Za-z0-9]*(\\.[a-z][A-Za-z0-9]*){{1,3}}")
    if len(identifier) > max_length:
        problems.append(f"the ID {identifier!r} is {len(identifier)} characters, over {max_length}")
    return problems


def ids_of_keys(cat, problems, max_length):
    """[(ID, key)] in code-point order of the IDs: the catalog is keyed by ID, so each key is its own ID, and one outside the
    pattern (or too long) is a refusal."""
    for key in cat.strings:
        problems += [f"{key}: {sentence}" for sentence in id_problems(key, max_length)]
    return sorted((key, key) for key in cat.strings)


def english_entry(cat, key, problems):
    """The English entry of `key` (an ID): its `en` localization, which Xcode compiles. An ID with none is a refusal: the key
    is an ID and says nothing of the English."""
    where = f"{key} [en]"
    found = compile_localization(cat.strings[key].get("localizations", {}).get("en"), "en", where, problems)
    if found is None:
        problems.append(f"{where}: the catalog has no English text for this ID (it needs an en localization)")
    return found


def build_plan(catalog_path, max_id_length=MAX_ID_LENGTH):
    """The Plan for the catalog file `catalog_path` (keyed by ID). Raises PackError listing every
    refusal at once, each naming its key and language, so that nothing is written until all can be fixed."""
    catalog_bytes = Path(catalog_path).read_bytes()
    try:
        cat = catalog.Catalog.load(catalog_path)
    except ValueError as error:
        raise PackError(f"{catalog_path}: {error}")
    problems = []
    rows = ids_of_keys(cat, problems, max_id_length)
    languages = [ENGLISH_BLOB] + [language for language in cat.languages() if language != ENGLISH_BLOB]
    for language in languages:
        if not language.isascii() or len(language) > NAME_BYTES:
            problems.append(f"{language}: a language code must be ASCII and at most {NAME_BYTES} characters")
    entries = {language: {} for language in languages}
    keys = sorted({key for _, key in rows})
    for key in keys:
        entries[ENGLISH_BLOB][key] = english_entry(cat, key, problems)
        english = entries[ENGLISH_BLOB][key]
        # English's own plural forms are compared with its `other`; its plain text only has to hold allowed specifiers.
        if english is not None:
            problems += [f"{key} [en]: {sentence}" for sentence in
                         entry_problems(english, "en", english_reference(english), isinstance(english, tuple))]
        for language in languages[1:]:
            where = f"{key} [{language}]"
            localizations = cat.strings[key].get("localizations", {})
            entry = compile_localization(localizations.get(language), language, where, problems)
            entries[language][key] = entry
            # With no English to compare with (already a refusal) a text is still checked on its own.
            reference = None if english is None else english_reference(english)
            problems += [f"{where}: {sentence}"
                         for sentence in entry_problems(entry, language, reference, reference is not None)]
        note = cat.strings[key].get("comment", "")
        entries.setdefault(NOTES_BLOB, {})[key] = note
        problems += [f"{key} [notes]: {sentence}" for sentence in character_problems(note)]
    if problems:
        raise PackError(problems)
    blobs = [(IDS_BLOB, [identifier for identifier, _ in rows]),
             (NOTES_BLOB, [entries[NOTES_BLOB][key] for _, key in rows])]
    blobs += [(language, [entries[language][key] for _, key in rows]) for language in languages]
    return Plan([identifier for identifier, _ in rows], blobs, hashlib.sha256(catalog_bytes).digest())


# ---------------------------------------------------------------------------------------------------------------
# Writing a pack.
# ---------------------------------------------------------------------------------------------------------------

def window_size(raw_size):
    """The LZMA window for a blob of `raw_size` bytes: the smallest power of two at or above it, and at least 4 KiB."""
    size = MIN_WINDOW
    while size < raw_size:
        size *= 2
    return size


def compress(raw, windowed=True):
    """The xz stream of `raw` (LZMA2, preset 9 extreme); with `windowed`, its dictionary is `window_size(len(raw))`,
    otherwise the preset's own (64 MiB)."""
    spec = {"id": lzma.FILTER_LZMA2, "preset": PRESET}
    if windowed:
        spec["dict_size"] = window_size(len(raw))
    return lzma.compress(raw, format=lzma.FORMAT_XZ, filters=[spec])


def raw_blob(entries):
    """The raw bytes of a blob: each entry as encode_entry writes it (an ID or a note is its own text), then a NUL."""
    return "".join(encode_entry(entry) + TERMINATOR for entry in entries).encode("utf-8")


def raw_blobs(plan):
    """[(name, raw bytes, entry count)] for the plan's blobs, in pack order."""
    return [(name, raw_blob(entries), len(entries)) for name, entries in plan.blobs]


def assemble(digest, id_count, blobs, windowed=True):
    """The bytes of a pack: the header, the directory, and the blobs, each compressed. `blobs` is [(name, raw, count)]."""
    packed = [compress(raw, windowed) for _, raw, _ in blobs]
    offset = HEADER.size + DIRECTORY_RECORD.size * len(blobs)
    directory = b""
    for (name, raw, count), data in zip(blobs, packed):
        directory += DIRECTORY_RECORD.pack(name.encode("ascii"), offset, len(data), len(raw), count)
        offset += len(data)
    return HEADER.pack(MAGIC, FORMAT_VERSION, 0, digest, id_count, len(blobs)) + directory + b"".join(packed)


def build_bytes(plan, windowed=True):
    """The pack's bytes for `plan`."""
    return assemble(plan.digest, len(plan.ids), raw_blobs(plan), windowed)


def build_corrupt_utf8_pack_for_tests(plan):
    """A pack for the Swift tests, CORRUPT ON PURPOSE: it is the plan's pack except that the first entry of the English
    blob is the two bytes C3 28, which are not UTF-8. The blob is otherwise well formed (right entry count and raw size),
    so a reader reaches the UTF-8 check. Never ship it; it exists so a test can prove the reader falls back to English."""
    blobs = []
    for name, raw, count in raw_blobs(plan):
        if name == ENGLISH_BLOB:
            first_end = raw.index(b"\0")
            raw = b"\xc3\x28" + raw[first_end:]
        blobs.append((name, raw, count))
    return assemble(plan.digest, len(plan.ids), blobs)


# ---------------------------------------------------------------------------------------------------------------
# Reading a pack.
# ---------------------------------------------------------------------------------------------------------------

@dataclass
class Blob:
    """One decoded blob of a pack: its `name`, the compressed and raw sizes the directory gave, and its `entries`, the
    texts as written (see decode_entry)."""
    name: str
    compressed: int
    raw: int
    entries: list


@dataclass
class Pack:
    """A decoded pack: the catalog's `digest` (hex), its IDs, and `blobs` by name, in file order."""
    digest: str
    ids: list
    blobs: dict


def read_pack(data):
    """Decodes the pack `data` (bytes), checking the magic, the version, every blob's bounds, its raw size, its entry
    count, its terminators, and its UTF-8, as the apps' reader does. Raises PackError on the first thing wrong."""
    if len(data) < HEADER.size:
        raise PackError("the pack is shorter than its header")
    magic, version, flags, digest, id_count, blob_count = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise PackError(f"the magic is {magic!r}, not {MAGIC!r}")
    if version != FORMAT_VERSION or flags != 0:
        raise PackError(f"the version is {version} with flags {flags}, not {FORMAT_VERSION} with none")
    if len(data) < HEADER.size + blob_count * DIRECTORY_RECORD.size:
        raise PackError("the directory is cut short")
    blobs = {}
    for index in range(blob_count):
        raw_name, offset, size, raw_size, count = DIRECTORY_RECORD.unpack_from(data, HEADER.size + index * DIRECTORY_RECORD.size)
        name = raw_name.rstrip(b"\0").decode("ascii", "replace")
        if offset + size > len(data):
            raise PackError(f"blob {name} runs past the end of the file")
        blobs[name] = decode_blob(name, data[offset:offset + size], raw_size, count)
    if IDS_BLOB not in blobs:
        raise PackError("there is no ids blob")
    ids = blobs[IDS_BLOB].entries
    if len(ids) != id_count:
        raise PackError(f"the header says {id_count} IDs and the ids blob holds {len(ids)}")
    return Pack(digest.hex(), ids, blobs)


def decode_blob(name, data, raw_size, count):
    """The Blob `name` from its xz bytes `data`, which must decode to exactly `raw_size` bytes of `count` NUL-terminated
    UTF-8 entries. (The output is capped at one byte more than `raw_size`, so a hostile blob cannot grow without limit.)"""
    decoder = lzma.LZMADecompressor(format=lzma.FORMAT_XZ)
    try:
        raw = decoder.decompress(data, max_length=raw_size + 1)
    except lzma.LZMAError as error:
        raise PackError(f"blob {name} does not decode: {error}")
    if len(raw) != raw_size or not decoder.eof:
        raise PackError(f"blob {name} decodes to a different size than the {raw_size} bytes its directory gives")
    if not raw.endswith(b"\0") and raw_size:
        raise PackError(f"blob {name} does not end with a terminator")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PackError(f"blob {name} is not UTF-8: {error}")
    entries = text.split(TERMINATOR)[:-1]
    if len(entries) != count:
        raise PackError(f"blob {name} holds {len(entries)} entries and its directory says {count}")
    return Blob(name, len(data), raw_size, entries)


# ---------------------------------------------------------------------------------------------------------------
# The stamp that lets a build skip.
# ---------------------------------------------------------------------------------------------------------------

def file_hash(path):
    """The SHA-256 (hex) of the file `path`, or None when there is none."""
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def stamp_of(catalog_path, max_id_length):
    """What decides the output: the hashes of the catalog and this builder, and the ID length limit."""
    return {"builder": file_hash(__file__), "catalog": file_hash(catalog_path), "maxIdLength": max_id_length}


def stamp_path(out):
    """Where the stamp of the pack `out` lives, beside it."""
    return Path(str(out) + ".stamp")


def is_up_to_date(out, stamp, stamp_file=None):
    """Whether `out` exists and its stamp equals `stamp` and names the output's own hash (so a changed output rebuilds).

    The stamp is read from `stamp_file`, or from beside `out` when none is given."""
    try:
        written = json.loads((Path(stamp_file) if stamp_file else stamp_path(out)).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    return written == {**stamp, "pack": file_hash(out)} and file_hash(out) is not None


# ---------------------------------------------------------------------------------------------------------------
# verify, compare, size.
# ---------------------------------------------------------------------------------------------------------------

def entry_of(blob_name, text):
    """The entry the pack's `text` stands for in blob `blob_name` (ids and notes are plain text, never plural)."""
    return text if blob_name in (IDS_BLOB, NOTES_BLOB) else decode_entry(text)


def differences(want, got, label="", limit=LISTED_DIFFERENCES):
    """The sentences about where Pack `got` differs from Pack `want`, ID by ID and language by language (at most `limit`,
    then a count). Blobs and IDs that only one has are reported too."""
    found, more = [], 0

    def note(sentence):
        nonlocal more
        if len(found) < limit:
            found.append(sentence)
        else:
            more += 1

    for name in want.blobs:
        if name not in got.blobs:
            note(f"{label}the blob {name} is missing")
    for name in got.blobs:
        if name not in want.blobs:
            note(f"{label}the blob {name} is extra")
    index = {identifier: position for position, identifier in enumerate(got.ids)}
    for identifier in sorted(set(want.ids) - set(index)):
        note(f"{label}ID {identifier}: missing")
    for identifier in sorted(set(index) - set(want.ids)):
        note(f"{label}ID {identifier}: extra")
    for name, blob in want.blobs.items():
        if name == IDS_BLOB or name not in got.blobs:
            continue
        for position, identifier in enumerate(want.ids):
            if identifier not in index:
                continue
            wanted = entry_of(name, blob.entries[position])
            actual = entry_of(name, got.blobs[name].entries[index[identifier]])
            if wanted != actual:
                note(f"{label}{identifier} [{name}]: {describe_entry(wanted)!r} against {describe_entry(actual)!r}")
    if more:
        found.append(f"... and {more} more")
    return found


def verify(pack_path, catalog_path, max_id_length=MAX_ID_LENGTH):
    """The sentences about where the pack at `pack_path` differs from what `build_plan` decides for the catalog: the hash in
    the header, the IDs, and every entry of every blob. Empty when the pack is exactly the catalog's."""
    plan = build_plan(catalog_path, max_id_length)
    pack = read_pack(Path(pack_path).read_bytes())
    expected = Pack(plan.digest.hex(), plan.ids,
                    {name: Blob(name, 0, 0, [encode_entry(entry) for entry in entries]) for name, entries in plan.blobs})
    found = []
    if pack.digest != expected.digest:
        found.append(f"the pack's catalog hash {pack.digest} is not the catalog's {expected.digest}")
    if pack.ids != expected.ids:
        found.append("the pack's IDs are not the catalog's IDs in code-point order")
    return found + differences(expected, pack)


def compare(path_a, path_b):
    """The sentences about where pack B differs from pack A, ID by ID (empty when every entry of every language is equal,
    whatever the compressed bytes are)."""
    return differences(read_pack(Path(path_a).read_bytes()), read_pack(Path(path_b).read_bytes()))


def size_report(pack_path, compare_window=False):
    """Lines that report each blob of the pack (entries, compressed and raw bytes) and the totals; with `compare_window`,
    each blob is recompressed with the preset's own 64 MiB window and both sizes are shown, with the saving."""
    data = Path(pack_path).read_bytes()
    pack = read_pack(data)
    lines = [f"{'blob':8} {'entries':>8} {'raw':>10} {'compressed':>11}" + (f" {'64 MiB window':>14} {'difference':>11}" if compare_window else "")]
    total = unwindowed_total = 0
    for name, blob in pack.blobs.items():
        line = f"{name:8} {len(blob.entries):>8,} {blob.raw:>10,} {blob.compressed:>11,}"
        if compare_window:
            raw = (TERMINATOR.join(blob.entries) + TERMINATOR).encode("utf-8")
            wide = len(compress(raw, windowed=False))
            unwindowed_total += wide
            line += f" {wide:>14,} {blob.compressed - wide:>+11,}"
        total += blob.compressed
        lines.append(line)
    overhead = len(data) - total
    lines.append(f"blobs {total:,} bytes; header and directory {overhead:,}; the pack {len(data):,}")
    if compare_window:
        lines.append(f"with the 64 MiB window the blobs would be {unwindowed_total:,} bytes ({total - unwindowed_total:+,} with the sized window)")
    return lines


# ---------------------------------------------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------------------------------------------

def refuse(error):
    """Prints a PackError's problems (the first LISTED_PROBLEMS, then a count) to standard error; returns the exit code."""
    print(f"pack.py: refused, nothing written: {len(error.problems)} problem{'s' if len(error.problems) != 1 else ''}",
          file=sys.stderr)
    for sentence in error.problems[:LISTED_PROBLEMS]:
        print(f"  {sentence}", file=sys.stderr)
    if len(error.problems) > LISTED_PROBLEMS:
        print(f"  ... and {len(error.problems) - LISTED_PROBLEMS} more", file=sys.stderr)
    return 1


def write_atomically(path, data):
    """Writes `data` to `path` so that nobody ever sees, or holds a mapping of, a half-written file.

    The bytes go to a temporary file beside `path` and `os.replace` puts it in place in one step. The engine
    memory-maps the pack, and a file rewritten in place under a running process can end that process with SIGBUS;
    a replaced file leaves the old one whole for whoever has it mapped. The temporary file is removed on any failure
    (and only then: on success it is `path`).
    """
    path = Path(path)
    # A build's derived-files folder may not exist yet on a first build.
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.replace(temporary, path)
    except BaseException:
        # Whatever stopped the write (a full disk, a signal), leave nothing behind and let the failure through.
        try:
            temporary.unlink()
        except OSError:
            pass
        raise


def command_build(args):
    """`build`: refuses or writes the pack and its stamp, or skips when the stamp says nothing changed."""
    stamp = stamp_of(args.catalog, args.max_id_length)
    # The stamp lives beside the pack unless --stamp says elsewhere (the app's build keeps it out of the app).
    stamp_file = Path(args.stamp) if args.stamp else stamp_path(args.out)
    if not args.force and not args.no_stamp and is_up_to_date(args.out, stamp, stamp_file):
        print(f"{args.out} is up to date (the catalog and the builder are unchanged)")
        return 0
    plan = build_plan(args.catalog, args.max_id_length)
    data = build_bytes(plan)
    write_atomically(args.out, data)
    # The stamp comes only after the pack is in place, so a stamp never vouches for a pack that is not there.
    if not args.no_stamp:
        write_atomically(stamp_file,
                         json.dumps({**stamp, "pack": hashlib.sha256(data).hexdigest()}, sort_keys=True) + "\n")
    print(f"wrote {args.out}: {len(data):,} bytes, {len(plan.ids):,} IDs, {len(plan.blobs) - 2} languages")
    return 0


def command_corrupt_fixture(args):
    """`corrupt-fixture`: writes the test-only pack whose English blob is not UTF-8."""
    plan = build_plan(args.catalog, args.max_id_length)
    write_atomically(args.out, build_corrupt_utf8_pack_for_tests(plan))
    print(f"wrote {args.out}: A CORRUPT PACK, for tests only")
    return 0


def command_report(sentences, ok_message):
    """Prints `sentences` (the differences a verify or compare found) and returns 1, or prints `ok_message` and returns 0."""
    if sentences:
        for sentence in sentences:
            print(sentence)
        return 1
    print(ok_message)
    return 0


def parser():
    """The argument parser of the five commands."""
    root = argparse.ArgumentParser(description="Builds and checks TextMouth's interface-text pack.")
    commands = root.add_subparsers(dest="command", required=True)

    def inputs(command):
        command.add_argument("--catalog", required=True, help="the String Catalog")
        command.add_argument("--max-id-length", type=int, default=MAX_ID_LENGTH,
                             help="the longest ID allowed (default %(default)s; a measurement may raise it)")

    build = commands.add_parser("build", help="write the pack")
    inputs(build)
    build.add_argument("--out", required=True)
    build.add_argument("--force", action="store_true", help="rebuild even when the stamp says nothing changed")
    build.add_argument("--no-stamp", action="store_true", help="write no stamp and never skip")
    build.add_argument("--stamp", help="where the stamp lives (default: beside the pack, as PACK.stamp)")
    check = commands.add_parser("verify", help="decode a pack and compare every entry with the catalog")
    check.add_argument("pack")
    inputs(check)
    both = commands.add_parser("compare", help="compare two packs ID by ID")
    both.add_argument("a")
    both.add_argument("b")
    sizes = commands.add_parser("size", help="report each blob, compressed and raw")
    sizes.add_argument("pack")
    sizes.add_argument("--compare-window", action="store_true", help="also recompress with the 64 MiB window")
    corrupt = commands.add_parser("corrupt-fixture", help="write the test-only pack whose English is not UTF-8")
    inputs(corrupt)
    corrupt.add_argument("--out", required=True)
    return root


def main(argv=None):
    """Runs the command in `argv`; returns the exit code (0 on success, 1 on a refusal or a difference)."""
    args = parser().parse_args(argv)
    try:
        if args.command == "build":
            return command_build(args)
        if args.command == "corrupt-fixture":
            return command_corrupt_fixture(args)
        if args.command == "verify":
            return command_report(verify(args.pack, args.catalog, args.max_id_length),
                                  f"{args.pack} matches the catalog")
        if args.command == "compare":
            return command_report(compare(args.a, args.b), "the packs hold the same entries")
        print("\n".join(size_report(args.pack, args.compare_window)))
        return 0
    except PackError as error:
        return refuse(error)


if __name__ == "__main__":
    sys.exit(main())
