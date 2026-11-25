#!/usr/bin/env python3
"""braille_tables.py: the builder of TextMouth's braille-table pack, `BrailleTables.pack` (FR40).

liblouis's `tables/` folder (3.39.0, vendored unchanged in Vendor/liblouis/tables) is 14 MB as files, and the iPhone has no
VoiceOver folder to read, so each app carries its tables as one compressed pack and unpacks the ones it needs, with the
files they include, into its caches folder at first use (`BrailleTablePack.swift`, `BrailleTableUnpacker.swift`).
Standard library only, and it runs under Xcode's /usr/bin/python3 (3.9).

    braille_tables.py build    --profile iphone|mac --tables DIR --out PATH [--stamp PATH] [--force] [--remove-old-tables]
    braille_tables.py licenses --tables DIR [--write FILE | --check FILE]
    braille_tables.py measure  --tables DIR          (sizes of the grouping choices, for the report)

The container is Scripts/packs/packfile.py's: magic `TMBT`, version 1, the header's count is the number of table files, and
the SHA-256 is of the shipped files' names and bytes. The blobs:
- `index`: one JSON document (see `build_index`), compressed like the rest;
- `g000`, `g001`, ...: one LZMA blob for each group of files whose names share a prefix (`group_key`); a blob holds its files'
  bytes one after another, in name order, and the index records each file's group, offset, and length in the decoded bytes.
  Tables use LZMA: bzip2 measured 23% larger on them (November 23, 2026).

What ships (`plan`). Every regular file of the tables folder except the build system's own (Makefile.am, Makefile.in, README,
and the `.in` templates), and except:
- a table whose license is not LGPL 2.1 or later, or the release's own (a file with no license line of its own), and every
  table that includes one (`classify_license`, `Vendor/liblouis/TABLES-LICENSES.md`);
- a `.dic` hyphenation dictionary that no shipped table includes (only the ones a table includes are used).
A table that includes a file the folder lacks fails the build. The `mac` profile ships only the files listed in
`braille_tables_mac.txt`, the 20 files the Mac app bundled before the pack, and fails when one of them includes a file that
is not listed, since on the Mac every other language is VoiceOver's own table.

The catalog reads its tables from the index and unpacks nothing, so the index also holds, for each file with a `type` field,
the header fields the catalog reads (`CATALOG_KEYS`), read by the rules `BrailleTableCatalog.headerFields` uses, and, for a
file that only includes other tables, the files it includes (`include_only_targets`, which `includeOnlyTargets(ofTableAt:)`
mirrors). BrailleTableCatalogIndexTests compares both with what Swift reads from the unpacked files.

Determinism. The same folder gives the same bytes with the same Python. A stamp beside the output records the inputs' hashes
and the output's, so a build with nothing changed does nothing.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))

import packfile  # noqa: E402  (imported by path, after sys.path is set)

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
# The vendored tables, and the list of files the Mac app ships.
DEFAULT_TABLES = ROOT / "Vendor" / "liblouis" / "tables"
MAC_LIST = HERE / "braille_tables_mac.txt"
LICENSES_FILE = ROOT / "Vendor" / "liblouis" / "TABLES-LICENSES.md"
CONFIG_H = ROOT / "Vendor" / "liblouis" / "config.h"

MAGIC = b"TMBT"
FORMAT_VERSION = 1
INDEX_VERSION = 1
INDEX_BLOB = "index"
# The group blobs are named by number, since a name is at most 12 ASCII characters of letters, digits, and hyphens.
GROUP_NAME = "g%03d"
# The profiles: what an app's pack holds.
PROFILES = ("iphone", "mac")
# Files of the release's tables folder that are the build system's, never tables.
BUILD_FILES = {"Makefile.am", "Makefile.in", "README"}
BUILD_SUFFIXES = (".in",)
# The header fields the catalog reads (BrailleTableCatalog.table(fields:...)).
CATALOG_KEYS = ("type", "dots", "display-name", "language", "locale", "contraction", "grade", "direction", "index-name", "system", "region")
# The most bytes of a file read for its header, and the most a file may be to be one that only includes others: the
# catalog's `maximumHeaderBytes` and `maximumIncludeOnlyBytes`.
MAXIMUM_HEADER_BYTES = 65_536
MAXIMUM_INCLUDE_ONLY_BYTES = 4_096

# What `classify_license` calls a file's license.
LGPL_21 = "lgpl-2.1+"
LGPL_3 = "lgpl-3+"
NO_LICENSE = "none"
AMBIGUOUS = "ambiguous"
OTHER = "other"
# The classes that ship, and each class's name for the license list.
SHIPPED_LICENSES = (LGPL_21, NO_LICENSE)
LICENSE_TITLES = {
    LGPL_21: "GNU Lesser General Public License, version 2.1 or (at your option) any later version",
    NO_LICENSE: "No license line of its own: the release's, the GNU Lesser General Public License, version 2.1 or later",
    LGPL_3: "GNU Lesser General Public License, version 3 or (at your option) any later version",
    AMBIGUOUS: "The GNU Lesser General Public License 2.1 or later, and also the GNU General Public License, with no version",
    OTHER: "A license this builder does not know",
}
# Files that ship although their own head would leave them out, by a decision of the user, with the reason the license list
# prints. countries.cti: an LGPL 2.1 or later notice, then a GPL sentence with no version that is an old leftover from BRLTTY;
# macOS ships the same file in VoiceOver's own tables (November 23, 2026).
ACCEPTED_BY_DECISION = {
    "countries.cti": "its notice says the GNU Lesser General Public License, version 2.1 or later; the sentence under it, "
                     "which names the GNU General Public License with no version, is an old leftover, and macOS ships "
                     "the same file in VoiceOver's own tables",
}
# A note for a file whose license text mentions another license without being under it, which the license list prints.
LICENSE_NOTES = {
    "IPA.utb": "its references cite the IPA chart, which is under Creative Commons Attribution-Sharealike 3.0; the file's own license is the LGPL's",
    "IPA-unicode-range.uti": "its references cite the IPA chart, which is under Creative Commons Attribution-Sharealike 3.0; the file's own license is the LGPL's",
}


class BuildError(packfile.PackError):
    """A tables folder or a list that cannot be packed, naming what is wrong."""


# ---------------------------------------------------------------------------------------------------------------
# Reading a table file as the catalog does.
# ---------------------------------------------------------------------------------------------------------------

# The line breaks Swift's `Character.isNewline` knows: CR LF is one, and so is each of the others.
NEWLINE = re.compile("\r\n|[\n\r\x0b\x0c\x85  ]")
# Swift's `Character.isWhitespace`: the Unicode White_Space property.
WHITESPACE = "\t\n\x0b\x0c\r \x85\xa0                　"


def decode(data):
    """The text of `data` as the catalog reads it: UTF-8, with invalid bytes replaced."""
    return data.decode("utf-8", "replace")


def trim_blanks(text):
    """`text` without the blanks at its ends: Swift's `CharacterSet.whitespaces`, a tab and the Unicode space separators."""
    def blank(char):
        return char == "\t" or unicodedata.category(char) == "Zs"
    start, end = 0, len(text)
    while start < end and blank(text[start]):
        start += 1
    while end > start and blank(text[end - 1]):
        end -= 1
    return text[start:end]


def collapse_whitespace(text):
    """`text` with each run of white space made one space and the ends dropped."""
    words, current = [], []
    for char in text:
        if char in WHITESPACE:
            if current:
                words.append("".join(current))
                current = []
        else:
            current.append(char)
    if current:
        words.append("".join(current))
    return " ".join(words)


def comment_field(line):
    """(key, value) of a `#+` or `#-` comment line (not `#--`), else None, as `BrailleTableCatalog.field(inCommentLine:)`:
    a key is one word and lowercased, a value is not empty, and the colon needs no space after it."""
    if not (line.startswith("#+") or (line.startswith("#-") and not line.startswith("#--"))):
        return None
    body = line[2:]
    colon = body.find(":")
    if colon < 0:
        return None
    key = body[:colon].lower()
    if not key or any(char in WHITESPACE or unicodedata.category(char) == "Zs" for char in key):
        return None
    value = collapse_whitespace(body[colon + 1:])
    return (key, value) if value else None


def header_fields(text):
    """The fields of `text`'s header, as `BrailleTableCatalog.metadata(fromHeader:)` reads them: lines from the top, a blank
    line skipped, a `#` line a comment or a field, the first line of anything else the end, and the first value of a key
    wins."""
    fields = {}
    for raw in NEWLINE.split(text):
        line = trim_blanks(raw)
        if not line:
            continue
        if not line.startswith("#"):
            break
        found = comment_field(line)
        if found and found[0] not in fields:
            fields[found[0]] = found[1]
    return fields


def catalog_fields(data):
    """The catalog's header fields of the file `data`: `CATALOG_KEYS` of its header, which is read from the first
    `MAXIMUM_HEADER_BYTES`. Empty for a file with no `type`, which the catalog never lists."""
    fields = header_fields(decode(data[:MAXIMUM_HEADER_BYTES]))
    if "type" not in fields:
        return {}
    return {key: fields[key] for key in CATALOG_KEYS if key in fields}


def include_only_targets(data):
    """The tables a file includes when it does nothing else (`BrailleTableCatalog.includeOnlyTargets(ofTableAt:)`): every
    line that is neither blank nor a comment is `include` and a file name. None for any other file, and for one longer than
    `MAXIMUM_INCLUDE_ONLY_BYTES`."""
    if len(data) > MAXIMUM_INCLUDE_ONLY_BYTES:
        return None
    targets = []
    for raw in NEWLINE.split(decode(data)):
        words = [word for word in re.split("[ \t]+", raw) if word]
        if not words or words[0].startswith("#"):
            continue
        if words[0].lower() != "include" or len(words) < 2:
            return None
        targets.append(words[1])
    return targets or None


def include_targets(data):
    """The files a table file includes, in order, without repeats: the second word of every line whose first word is
    `include` (liblouis reads an opcode first on its line, after any blanks). A comment is not read."""
    targets = []
    for raw in NEWLINE.split(decode(data)):
        words = raw.split()
        if len(words) >= 2 and words[0] == "include" and words[1] not in targets:
            targets.append(words[1])
    return targets


# ---------------------------------------------------------------------------------------------------------------
# Licenses.
# ---------------------------------------------------------------------------------------------------------------

LGPL_NOTICE = re.compile(r"GNU\s+Lesser\s+General\s+Public\s+License")
PLAIN_GPL = re.compile(r"GNU\s+General\s+Public\s+License")
NOTICE_VERSION = re.compile(r"either\s+version\s+([0-9.]+)\s+of\s+the\s+License", re.I)
LICENSE_WORDS = re.compile(r"licen[sc]e|copyright|\bGPL\b|\bBSD\b|\bMIT\b|public domain|creative commons|permission", re.I)


def head_comments(data):
    """The comment lines of the head of a table file (the first 200 lines), without their comment marks and with each run of
    white space made one space, joined into one text."""
    lines = []
    for raw in NEWLINE.split(decode(data))[:200]:
        stripped = raw.strip()
        if stripped.startswith("#") or stripped.startswith("%"):
            lines.append(stripped.lstrip("#%").strip())
    return re.sub(r"\s+", " ", " ".join(lines))


def classify_license(data):
    """(class, versions) of a table file's own license, from the notice in the head of the file:
    - `lgpl-2.1+`: the Lesser General Public License, "either version 2.1 of the License, or (at your option) any later";
    - `lgpl-3+`: the same notice saying version 3, which gives no right to use the file under 2.1;
    - `ambiguous`: the Lesser notice and also the plain General Public License, which cannot both hold for one recipient;
    - `none`: no notice, and no word of copyright or license, as the wrapper tables that only include others;
    - `other`: any other statement, or a notice of a version this builder does not know."""
    head = head_comments(data)
    lesser = bool(LGPL_NOTICE.search(head))
    plain = bool(PLAIN_GPL.search(head))
    versions = sorted(set(NOTICE_VERSION.findall(head)))
    if lesser and plain:
        return AMBIGUOUS, versions
    if lesser and versions == ["2.1"]:
        return LGPL_21, versions
    if lesser and versions == ["3"]:
        return LGPL_3, versions
    if not lesser and not plain and not LICENSE_WORDS.search(head):
        return NO_LICENSE, versions
    return OTHER, versions


# ---------------------------------------------------------------------------------------------------------------
# What ships.
# ---------------------------------------------------------------------------------------------------------------

def is_build_file(name):
    """Whether `name` is the release build system's file, never a table."""
    return name in BUILD_FILES or name.endswith(BUILD_SUFFIXES)


def read_folder(folder):
    """{name: bytes} of the regular files of `folder` that are not the build system's, by name. A name is plain ASCII with no
    slash or leading dot, as the helper requires of a table name."""
    files = {}
    for path in sorted(Path(folder).iterdir()):
        if not path.is_file() or is_build_file(path.name):
            continue
        if path.name.startswith(".") or not re.fullmatch(r"[A-Za-z0-9_.+-]+", path.name):
            raise BuildError(f"{path.name}: a table's name is plain ASCII letters, digits, and _.+-, with no leading dot")
        files[path.name] = path.read_bytes()
    return files


class Plan:
    """What a folder's pack holds: `files` shipped ({name: bytes}), `includes` ({name: [names]} for the shipped ones), and
    `excluded` ({name: reason}) for the rest, with `licenses` ({name: class}) for every file read."""

    def __init__(self, files, includes, excluded, licenses, directions=None):
        self.files = files
        self.includes = includes
        self.excluded = excluded
        self.licenses = licenses
        # The names of the release's literary tables that write braille only.
        self.directions = directions or []


def leave_out(includes, licenses, fields, protected):
    """{name: reason} of the files the license rule leaves out, repeated until nothing changes:
    - a file whose license is not LGPL 2.1 or later or the release's own (`SHIPPED_LICENSES`), unless the user accepted it
      (`ACCEPTED_BY_DECISION`);
    - a file that includes one that is left out;
    - a file that is no literary table and not `protected` (a file of the Mac's list) and that only left-out files include:
      nothing that ships uses it.
    `includes` is {name: [names]} and `fields` {name: catalog fields} for every file read."""
    excluded = {}
    for name, kind in licenses.items():
        if kind not in SHIPPED_LICENSES and name not in ACCEPTED_BY_DECISION:
            excluded[name] = f"license: {kind}"
    includers = defaultdict(list)
    for name, targets in includes.items():
        for target in targets:
            includers[target].append(name)
    changed = True
    while changed:
        changed = False
        for name, targets in includes.items():
            if name in excluded:
                continue
            blocking = [target for target in targets if target in excluded]
            if blocking:
                excluded[name] = f"includes {blocking[0]}, which is left out"
                changed = True
        for name in includes:
            if name in excluded or name in protected or fields.get(name, {}).get("type", "").lower() == "literary":
                continue
            users = includers.get(name, [])
            if users and all(user in excluded for user in users):
                excluded[name] = f"only {users[0]}{' and others' if len(users) > 1 else ''}, which {'is' if len(users) == 1 else 'are'} left out, include it"
                changed = True
    return excluded


def release_directions(everything):
    """The sorted names of the release's literary tables whose `direction` is `forward`: they write braille from print and
    cannot read it back, which TextMouth's reading needs. Every file of the release is judged, shipped or not: the Mac, which
    carries only four tables, judges VoiceOver's older copies of a table by the release's mark whenever the release has a table
    of that file name (`BrailleTableCatalog`). The tables that are not marked need no list: nothing reads one."""
    forward = []
    for name, data in everything.items():
        fields = catalog_fields(data)
        if fields.get("type", "").lower() != "literary":
            continue
        if fields.get("direction", "both").lower() == "forward":
            forward.append(name)
    return sorted(forward)


def plan(folder, profile="iphone", mac_list=None):
    """The `Plan` of the tables in `folder` for `profile`.
    Raises BuildError for a file that includes one the folder lacks, and, for the mac profile, for a listed file the folder
    lacks, whose includes are not all listed, or that the license rule leaves out."""
    everything = read_folder(folder)
    includes = {name: include_targets(data) for name, data in everything.items()}
    for name, targets in includes.items():
        for target in targets:
            if target not in everything:
                raise BuildError(f"{name} includes {target}, which the tables folder lacks")
    licenses = {name: classify_license(data)[0] for name, data in everything.items()}
    listed = read_list(mac_list or MAC_LIST)
    if profile == "mac":
        for name in listed:
            if name not in everything:
                raise BuildError(f"the Mac's list names {name}, which the tables folder lacks")
    excluded = leave_out(includes, licenses, {name: catalog_fields(data) for name, data in everything.items()}, set(listed))
    directions = release_directions(everything)
    if profile == "mac":
        for name in listed:
            if name in excluded:
                raise BuildError(f"the Mac's list names {name}, which the license rule leaves out ({excluded[name]})")
            for target in includes[name]:
                if target not in listed:
                    raise BuildError(f"the Mac's list has {name}, which includes {target}, which the list lacks")
        return Plan({name: everything[name] for name in sorted(listed)}, {name: includes[name] for name in sorted(listed)}, {}, licenses, directions)
    if profile != "iphone":
        raise BuildError(f"there is no profile {profile}")
    # A hyphenation dictionary ships only when a shipped file includes it.
    included_by_shipped = {target for name, targets in includes.items() if name not in excluded for target in targets}
    for name in everything:
        if name.endswith(".dic") and name not in excluded and name not in included_by_shipped:
            excluded[name] = "a dictionary no shipped table includes"
    shipped = sorted(name for name in everything if name not in excluded)
    return Plan({name: everything[name] for name in shipped}, {name: includes[name] for name in shipped}, excluded, licenses, directions)


def read_list(path):
    """The file names a list file holds: one a line, blank lines and `#` comments skipped. Each name appears once."""
    names = []
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            if line in names:
                raise BuildError(f"{path}: {line} is listed twice")
            names.append(line)
    return names


def closure(includes, name):
    """The names `name` reaches by includes, itself first, then in the order they are first reached. Raises BuildError for a
    name `includes` lacks (a table missing an include) and loops harmlessly: liblouis itself stops a table that includes
    itself, which the builder leaves to the check."""
    if name not in includes:
        raise BuildError(f"{name} is not in the pack")
    order, seen, pending = [], set(), [name]
    while pending:
        current = pending.pop(0)
        if current in seen:
            continue
        seen.add(current)
        order.append(current)
        for target in includes.get(current) or ():
            if target not in includes:
                raise BuildError(f"{current} includes {target}, which the pack lacks")
            pending.append(target)
    return order


# ---------------------------------------------------------------------------------------------------------------
# Groups, the index, and the pack.
# ---------------------------------------------------------------------------------------------------------------

def group_key(name):
    """The group a file name belongs to: the name up to its first `-`, `_`, or `.`, in lower case ("en-ueb-g2.ctb" and
    "en_US.tbl" are "en"), so the files of a language lie together, where they compress best."""
    return re.split(r"[-_.]", name, maxsplit=1)[0].lower()


def make_groups(names, merge_below=0):
    """[(key, [names])] in key order: the names grouped by `group_key`, each group's names in name order. A group of fewer
    than `merge_below` files joins one group named "~" (the rest), which comes last; 0 merges nothing."""
    keyed = defaultdict(list)
    for name in sorted(names):
        keyed[group_key(name)].append(name)
    groups, small = [], []
    for key in sorted(keyed):
        if merge_below and len(keyed[key]) < merge_below:
            small.extend(keyed[key])
        else:
            groups.append((key, keyed[key]))
    if small:
        groups.append(("~", sorted(small)))
    return groups


# How the shipped packs are grouped, found by `measure` on November 23, 2026 on the iPhone's 432 files (12.0 MB): a group for
# each prefix is 1,985,944 bytes in 167 groups; joining the groups of fewer than 2 files is 1,921,680 (86 groups), fewer
# than 3 is 1,856,196 (38 groups, the joined one 1.4 MB raw, smaller than the biggest prefix group, 3.0 MB), fewer than 4 is
# 1,832,332 (the joined one 4.7 MB), fewer than 10 is 1,778,380 in 6 groups (one of 10 MB), and one solid blob is 1,744,920.
# A table's unpacking decodes each group it reaches whole, so the choice is the largest group this keeps at 3.0 MB.
MERGE_BELOW = 3


def raw_groups(files, groups):
    """[(blob name, raw bytes, file count)] for `groups`, and the place of each file: {name: (group index, offset, length)}."""
    blobs, places = [], {}
    for number, (_, names) in enumerate(groups):
        raw = b""
        for name in names:
            places[name] = (number, len(raw), len(files[name]))
            raw += files[name]
        blobs.append((GROUP_NAME % number, raw, len(names)))
    return blobs, places


def build_index(the_plan, groups, places, liblouis_version):
    """The index document of a pack, as JSON-ready data:
    {"v": 1, "liblouis": "3.39.0", "files": [...]}, each file {"n": name, "g": group, "o": offset, "l": length,
    "h": the SHA-256 of its bytes in lowercase hexadecimal, "i": [included files] when it includes any, "m": {catalog fields}
    when it is a table, "t": [targets] when it only includes others}. Files are in name order. Beside "files" is "f", the names
    of the release's literary tables that write braille only (`release_directions`), which the Mac judges VoiceOver's older
    tables by."""
    entries = []
    for name in sorted(the_plan.files):
        group, offset, length = places[name]
        entry = {"n": name, "g": group, "o": offset, "l": length, "h": hashlib.sha256(the_plan.files[name]).hexdigest()}
        if the_plan.includes[name]:
            entry["i"] = the_plan.includes[name]
        fields = catalog_fields(the_plan.files[name])
        if fields:
            entry["m"] = fields
        only = include_only_targets(the_plan.files[name])
        if only:
            entry["t"] = only
        entries.append(entry)
    return {"v": INDEX_VERSION, "liblouis": liblouis_version, "files": entries, "f": the_plan.directions}


def index_bytes(index):
    """The index as compact, key-sorted JSON in UTF-8: the same document gives the same bytes."""
    return json.dumps(index, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def source_digest(files):
    """The SHA-256 of the shipped files' names and bytes, which the pack's header records."""
    digest = hashlib.sha256()
    for name in sorted(files):
        digest.update(name.encode("ascii") + b"\0" + str(len(files[name])).encode("ascii") + b"\0" + files[name])
    return digest.digest()


def liblouis_version(config_h=CONFIG_H):
    """The liblouis version of the vendored release: `PACKAGE_VERSION` in its config.h."""
    match = re.search(r'#define\s+PACKAGE_VERSION\s+"([^"]+)"', Path(config_h).read_text(encoding="utf-8"))
    if not match:
        raise BuildError(f"{config_h} has no PACKAGE_VERSION")
    return match.group(1)


def build_bytes(the_plan, version, merge_below=None, windowed=True):
    """The pack's bytes for `the_plan`: the index and one LZMA blob for each group."""
    groups = make_groups(the_plan.files, MERGE_BELOW if merge_below is None else merge_below)
    blobs, places = raw_groups(the_plan.files, groups)
    index = index_bytes(build_index(the_plan, groups, places, version))
    methods = {name: packfile.METHOD_LZMA for name, _, _ in blobs}
    methods[INDEX_BLOB] = packfile.METHOD_LZMA
    return packfile.assemble(
        MAGIC, FORMAT_VERSION, source_digest(the_plan.files), len(the_plan.files),
        [(INDEX_BLOB, index, 1)] + blobs, windowed, methods,
    )


# ---------------------------------------------------------------------------------------------------------------
# Reading a pack back (the tests, and the check of what was built).
# ---------------------------------------------------------------------------------------------------------------

def read_pack(data):
    """{"index": the index document, "files": {name: bytes}} of the pack `data`, checking everything the apps' reader does
    that a builder can: the container, each file's place in its group, and that the index and groups agree."""
    directory = packfile.read_directory(data, MAGIC, FORMAT_VERSION)
    raw = {}
    for record in directory.records:
        raw[record.name] = packfile.decode_raw(
            record.name, data[record.offset:record.offset + record.compressed], record.raw, record.method)
    if INDEX_BLOB not in raw:
        raise packfile.PackError("there is no index blob")
    index = json.loads(raw[INDEX_BLOB].decode("utf-8"))
    files = {}
    for entry in index["files"]:
        blob = raw.get(GROUP_NAME % entry["g"])
        if blob is None or entry["o"] + entry["l"] > len(blob):
            raise packfile.PackError(f"{entry['n']} lies outside its group")
        files[entry["n"]] = blob[entry["o"]:entry["o"] + entry["l"]]
    if len(files) != directory.count:
        raise packfile.PackError(f"the header says {directory.count} files and the index lists {len(files)}")
    return {"index": index, "files": files, "records": directory.records, "digest": directory.digest}


# ---------------------------------------------------------------------------------------------------------------
# The license list.
# ---------------------------------------------------------------------------------------------------------------

def license_list(the_plan, version):
    """The text of Vendor/liblouis/TABLES-LICENSES.md for `the_plan` (the iPhone's: every file of the release): the files by
    license, and what is left out and why."""
    by_license = defaultdict(list)
    for name, kind in the_plan.licenses.items():
        by_license[kind].append(name)
    lines = [
        "# The licenses of liblouis's tables",
        "",
        f"Each file of `tables/` in liblouis {version} (vendored here unchanged) by the license its own head states.",
        "This list is written by `Scripts/packs/braille_tables.py licenses --write`; a test keeps it equal to the files.",
        "TextMouth ships a table when its license is the GNU Lesser General Public License 2.1 or later (the release's own, "
        "`COPYING.LESSER`), or the file states none, and then the release's holds, or the user decided it ships; it leaves out "
        "the others, every table that includes one, and every file that only left-out tables use.",
        "",
        "## Totals",
        "",
    ]
    names_all = sorted(the_plan.licenses)
    lines.append(f"- Files of the release's `tables/` that are tables or what they include: {len(names_all)}.")
    for kind in (LGPL_21, NO_LICENSE, LGPL_3, AMBIGUOUS, OTHER):
        lines.append(f"- {LICENSE_TITLES[kind]}: {len(by_license.get(kind, []))}.")
    shipped = sum(1 for name in names_all if name not in the_plan.excluded)
    lines.append(f"- Shipped by the user's decision of November 23, 2026, although their own heads would leave them out: {len(ACCEPTED_BY_DECISION)}.")
    lines.append(f"- Shipped in the iPhone's pack: {shipped}. Left out: {len(the_plan.excluded)}.")
    lines.append("")
    for kind in (LGPL_21, NO_LICENSE, LGPL_3, AMBIGUOUS, OTHER):
        names = sorted(name for name in by_license.get(kind, []) if name not in ACCEPTED_BY_DECISION)
        if not names:
            continue
        lines += [f"## {LICENSE_TITLES[kind]}", "", f"{len(names)} files.", ""]
        if kind == LGPL_21:
            lines += ["Every file of this license is shipped unless it includes one that is left out (below).", ""]
        for name in names:
            note = f" ({LICENSE_NOTES[name]})" if name in LICENSE_NOTES else ""
            lines.append(f"- `{name}`{note}")
        lines.append("")
    if ACCEPTED_BY_DECISION:
        lines += ["## Shipped by the user's decision of November 23, 2026", ""]
        for name in sorted(ACCEPTED_BY_DECISION):
            lines.append(f"- `{name}`: {ACCEPTED_BY_DECISION[name]}.")
        lines.append("")
    left_out = sorted(name for name in the_plan.excluded if the_plan.excluded[name].startswith("includes"))
    if left_out:
        lines += ["## Left out because they include a file that is left out", "", f"{len(left_out)} files.", ""]
        lines += [f"- `{name}`: {the_plan.excluded[name]}" for name in left_out]
        lines.append("")
    only_users = sorted(name for name in the_plan.excluded if the_plan.excluded[name].startswith("only "))
    if only_users:
        lines += ["## Left out because only left-out tables use them", "", f"{len(only_users)} files.", ""]
        lines += [f"- `{name}`: {the_plan.excluded[name]}" for name in only_users]
        lines.append("")
    dictionaries = sorted(name for name in the_plan.excluded if the_plan.excluded[name].startswith("a dictionary"))
    if dictionaries:
        lines += ["## Left out because no table uses them", "", f"{len(dictionaries)} hyphenation dictionaries that no table includes.", ""]
        lines += [f"- `{name}`" for name in dictionaries]
        lines.append("")
    return "\n".join(lines).rstrip("\n") + "\n"


# ---------------------------------------------------------------------------------------------------------------
# The stamp that lets a build skip.
# ---------------------------------------------------------------------------------------------------------------

def file_hash(path):
    """The SHA-256 (hex) of the file `path`, or None when there is none."""
    path = Path(path)
    return hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None


def stamp_of(profile, tables_folder, mac_list=MAC_LIST):
    """What decides the output: the profile, the hashes of this builder, the container's writer, the list, liblouis's config.h
    (which gives the version the index states), and the tables (each file's name and bytes), and the formats' versions."""
    return {
        "formatVersion": FORMAT_VERSION, "profile": profile, "builder": file_hash(__file__), "container": file_hash(packfile.__file__),
        "list": file_hash(mac_list), "config": file_hash(CONFIG_H),
        "tables": hashlib.sha256(source_digest(read_folder_all(tables_folder))).hexdigest(),
    }


def read_folder_all(folder):
    """{name: bytes} of every regular file of `folder`, build files too: what a change to the vendored release is."""
    return {path.name: path.read_bytes() for path in sorted(Path(folder).iterdir()) if path.is_file()}


def write_atomically(path, data):
    """Writes `data` to `path` by writing a file beside it and renaming it over it, so a reader that has the old file mapped
    is never given a changed one."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def remove_old_tables(resources):
    """Removes `liblouis/tables` of the resources folder `resources`, and `liblouis` when that leaves it empty: the folder the
    apps copied the raw tables into before the pack, which Xcode never cleans from a product an earlier build made (as
    pack.py's --remove-apple-tables removes the tables of Apple's). Returns whether it removed anything. Only that one path."""
    old = Path(resources) / "liblouis" / "tables"
    if not old.is_dir() or old.is_symlink():
        return False
    shutil.rmtree(old)
    try:
        old.parent.rmdir()
    except OSError:
        pass
    return True


def command_build(args):
    """`build`: writes the pack for the profile unless the stamp says it is up to date."""
    stamp = stamp_of(args.profile, args.tables)
    out = Path(args.out)
    if args.remove_old_tables and remove_old_tables(out.parent):
        print(f"removed {out.parent / 'liblouis' / 'tables'}, which an earlier build copied")
    stamp_file = Path(args.stamp) if args.stamp else Path(str(out) + ".stamp")
    if not args.force and out.is_file() and stamp_file.is_file():
        try:
            written = json.loads(stamp_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            written = None
        if written == {**stamp, "pack": file_hash(out)}:
            print(f"{out}: up to date")
            return 0
    the_plan = plan(args.tables, args.profile)
    data = build_bytes(the_plan, liblouis_version())
    write_atomically(out, data)
    write_atomically(stamp_file, json.dumps({**stamp, "pack": file_hash(out)}, indent=1, sort_keys=True).encode("utf-8"))
    print(f"wrote {out}: {len(data):,} bytes, {len(the_plan.files)} files ({args.profile}), {len(the_plan.excluded)} left out")
    return 0


def command_licenses(args):
    """`licenses`: prints the license list, or writes it to a file, or checks that a file is the list."""
    text = license_list(plan(args.tables, "iphone"), liblouis_version())
    if args.write:
        write_atomically(args.write, text.encode("utf-8"))
        print(f"wrote {args.write}")
    elif args.check:
        if Path(args.check).read_text(encoding="utf-8") != text:
            print(f"{args.check} is not what `licenses` writes now", file=sys.stderr)
            return 1
        print(f"{args.check} is current")
    else:
        sys.stdout.write(text)
    return 0


def command_measure(args):
    """`measure`: the size of the iPhone's pack for each grouping choice, and each group's size, for the report."""
    the_plan = plan(args.tables, "iphone")
    raw = sum(len(data) for data in the_plan.files.values())
    print(f"{len(the_plan.files)} files, {raw:,} bytes raw, {len(the_plan.excluded)} left out")
    for merge_below in (0, 2, 3, 4, 6, 10):
        print(f"merge groups under {merge_below} files: {len(build_bytes(the_plan, liblouis_version(), merge_below)):,} bytes")
    groups = make_groups(the_plan.files, MERGE_BELOW)
    blobs, _ = raw_groups(the_plan.files, groups)
    print(f"{len(groups)} groups; the five biggest raw:")
    for (key, names), (_, blob, _) in sorted(zip(groups, blobs), key=lambda pair: -len(pair[1][1]))[:5]:
        print(f"  {key}: {len(names)} files, {len(blob):,} bytes raw, {len(packfile.compress(blob)):,} compressed")
    return 0


def parser():
    """The command line's parser."""
    main = argparse.ArgumentParser(description="Build TextMouth's braille-table pack from liblouis's tables.")
    sub = main.add_subparsers(dest="command", required=True)
    build = sub.add_parser("build", help="write BrailleTables.pack for a profile")
    build.add_argument("--profile", choices=PROFILES, required=True)
    build.add_argument("--tables", default=str(DEFAULT_TABLES))
    build.add_argument("--out", required=True)
    build.add_argument("--stamp")
    build.add_argument("--force", action="store_true")
    build.add_argument("--remove-old-tables", action="store_true",
                       help="remove liblouis/tables beside the output, which an earlier build of the app copied")
    licenses = sub.add_parser("licenses", help="print, write, or check the license list")
    licenses.add_argument("--tables", default=str(DEFAULT_TABLES))
    group = licenses.add_mutually_exclusive_group()
    group.add_argument("--write")
    group.add_argument("--check")
    measure = sub.add_parser("measure", help="the sizes of the grouping choices")
    measure.add_argument("--tables", default=str(DEFAULT_TABLES))
    return main


def main(argv=None):
    """Runs the command line; the exit status is 0 on success, 1 for a refusal."""
    args = parser().parse_args(argv)
    try:
        return {"build": command_build, "licenses": command_licenses, "measure": command_measure}[args.command](args)
    except packfile.PackError as error:
        print(f"braille_tables.py: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
