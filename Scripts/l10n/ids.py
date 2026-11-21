#!/usr/bin/env python3
"""The permanent short ID of every interface string (FR39, phase 3).

An ID is `owner.member[.case]` in lower camel case, taken once from the Swift declaration that holds the string and
then frozen in `Scripts/l10n/ids.json`; a key that several types use is `common.*`, and a key that serves places needing
different words is split by use. The design is `research/STRINGS-SYSTEM-DESIGN-2026-11-21.md`, section "IDs".

    ids.py propose [--root DIR] [--locations FILE] [--fresh]   write ids.json from the sources and the catalog
    ids.py check   [--root DIR]                                refuse a table that breaks the rules
    ids.py suggest FILE:LINE [--root DIR]                      propose an ID for the call on that line

`propose` keeps every ID already in ids.json (an ID is permanent) and adds the keys that lack one; `--fresh` forms
them all again, for the first run only. The tool reads the sources with `swiftscan`'s lexer and the catalog with
`catalog.py`; it uses the standard library only and runs under Python 3.9.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import catalog  # noqa: E402
from swiftscan import scanner  # noqa: E402

# Where the files live, relative to the repository root.
CATALOG_PATH = "TextMouth/Localization/Localizable.xcstrings"
IDS_PATH = "Scripts/l10n/ids.json"
RETIRED_PATH = "Scripts/l10n/retired-ids.txt"

# The form of an ID (two to four lower camel case segments) and its length limit.
ID_PATTERN = re.compile(r"[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*){1,3}")
MAX_ID_LENGTH = 48
# The version of ids.json's shape.
TABLE_VERSION = 1

# Words a type's name may end with that the owner leaves out (`SleepTimerWording` is `sleepTimer`).
OWNER_SUFFIXES = ("Wording", "Vocabulary", "Words", "Text")
# An error's text members (and an initializer): with a switch case present, the case alone names the string.
GENERIC_MEMBERS = {"errorDescription", "localizedDescription", "failureReason", "recoverySuggestion"}
# Small words a slug skips when it must tell keys apart (a `common` ID keeps them, so it reads as the English).
STOPWORDS = {"a", "an", "the", "of", "to", "in", "on", "at", "for", "with", "and", "or", "is", "are", "be", "this",
             "that", "it", "its", "as", "by", "from", "into", "than", "your", "you", "will", "can", "has", "have",
             "textmouth", "could", "would", "should", "may", "so", "then", "but", "just", "also"}
# Words a member's name may lose when the ID is too long: connectives, never the word that names the thing.
MEMBER_FILLER = {"for", "with", "the", "of", "to", "and", "in", "on", "at", "from", "is", "a", "an", "when", "if"}


# ---------------------------------------------------------------------------------------------- the sources


@dataclass
class Site:
    """One localized call: where it is, the catalog key it holds, and the declaration around it."""

    file: str                  # path relative to the repository root
    line: int                  # 1-based line of the literal
    key: Optional[str]         # the catalog key, None when it could not be tied to one
    owner: str                 # the innermost type that declares the member, as written (`SleepTimerWording`)
    member: str                # the property or function, as written
    case: Optional[str]        # the switch arm's case when the member switches over one

    def selector(self) -> str:
        """`<file>:<owner>.<member>`, the form a split lists its sites in."""
        return f"{self.file}:{self.owner}.{self.member}"

    def selectors(self) -> List[str]:
        """Every selector that covers this site: the member's, and (with a case) the case's."""
        base = self.selector()
        return [base, f"{base}.{self.case}"] if self.case else [base]


# A type declaration, a member declaration, and a switch arm, each recognized at the start of a source line.
_ATTRIBUTES = r"(?:@\w+(?:\([^)]*\))?\s+)*"
_MODIFIERS = r"(?:(?:nonisolated|private|fileprivate|internal|public|open|override|final|mutating|static|class|indirect|lazy|required|convenience)\s+)*"
_TYPE = re.compile(r"^\s*" + _ATTRIBUTES + _MODIFIERS + r"(?:enum|struct|class|extension|actor|protocol)\s+([A-Za-z_][\w.]*)")
_MEMBER = re.compile(r"^\s*" + _ATTRIBUTES + _MODIFIERS + r"(?:var|func|let|init|subscript)\b\s*`?([A-Za-z_]\w*)?")
# The name after `case` (and an optional `let` or `var`); a tuple pattern such as `case let (a, b):` names no case.
_CASE = re.compile(r"^\s*case\s+(?:(?:let|var)\s+)?\.?(?!(?:let|var)\b)([A-Za-z_]\w*)")
_DEFAULT = re.compile(r"^\s*default\s*:")
_NOT_TYPE_NAMES = {"func", "var", "let", "init", "subscript"}


def _indent(row: str) -> int:
    """The number of leading whitespace characters of a source line."""
    return len(row) - len(row.lstrip())


def declarations_at(lines: Sequence[str], line: int) -> Tuple[List[str], Optional[str], Optional[str]]:
    """(the enclosing types innermost first, the member, the switch case) of the 1-based `line`.

    It walks up the file along falling indentation, which is how Swift code in this repository is laid out. The member
    is the outermost member inside the innermost type (so a `let` inside a function body is not taken for the member),
    and the case is the outermost switch arm inside that member."""
    types: List[str] = []
    members: List[str] = []
    cases: List[str] = []
    # The literal's own line counts as an enclosing declaration (`static var x = String(localized: …)`, or an arm
    # written `case .a: return String(localized: …)`), so the walk starts just above its indentation.
    indent = _indent(lines[line - 1]) + 1
    for index in range(line, 0, -1):
        row = lines[index - 1]
        stripped = row.strip()
        if not stripped or stripped.startswith(("//", "*", "/*")):
            continue
        level = _indent(row)
        if level >= indent:
            continue
        indent = level
        type_match = _TYPE.match(row)
        if type_match and type_match.group(1) not in _NOT_TYPE_NAMES:
            # Every type that encloses the line is kept, innermost first, to name the outer type for a generic owner.
            types.append(type_match.group(1))
            continue
        if types:
            # Inside a type already found, the lines above it are the outer types' own members and cases.
            continue
        case_match = _CASE.match(row)
        if case_match:
            cases.append(case_match.group(1))
            continue
        if _DEFAULT.match(row):
            cases.append("other")
            continue
        member_match = _MEMBER.match(row)
        if member_match:
            members.append(member_match.group(1) or "init")
    return types, (members[-1] if members else None), (cases[-1] if cases and members else None)


# ---------------------------------------------------------------------------------------------- finding the keys


def normalize_key(key: str) -> str:
    """The key as the lexer writes a literal: every interpolation `%@`, a percent sign a single `%`."""
    return key.replace("%%", "%").replace("%lld", "%@")


def note_references(note: str) -> Dict[int, str]:
    """The types a translator's note names, as {1-based position: "int64" or "object"}: `%lld`, `%@`, `%1$@`, `%2$lld`.
    A bare specifier takes the next position."""
    found: Dict[int, str] = {}
    next_position = 1
    for placeholder in catalog.placeholders(note):
        if placeholder.type not in ("int64", "object"):
            continue
        position = placeholder.position or next_position
        found[position] = placeholder.type
        next_position = position + 1
    return found


def key_types(key: str) -> Dict[int, str]:
    """The type of each placeholder of a catalog key, by 1-based position."""
    return {i + 1: p.type for i, p in enumerate(catalog.placeholders(key))}


def pick_by_note(candidates: Set[str], note: str) -> Optional[str]:
    """Among the keys a literal could be (`%@ seconds` and `%lld seconds` read alike), the one whose placeholder types the
    note names; None when the note settles nothing or settles two."""
    named = note_references(note)
    if not named:
        return None
    agreeing = [key for key in sorted(candidates)
                if all(key_types(key).get(position) == kind for position, kind in named.items())]
    return agreeing[0] if len(agreeing) == 1 else None


def load_locations(path: Optional[Path]) -> Dict[str, List[dict]]:
    """build/l10n/locations.json (written by `l10n.py sync`): {key: [{file, line}]}, empty when there is no file."""
    if path is None or not path.is_file():
        return {}
    return json.loads(path.read_text(encoding="utf-8")).get("Localizable", {})


def collect_sites(root: Path, strings: Iterable[str], locations: Optional[Dict[str, List[dict]]] = None) -> List[Site]:
    """Every localized call of `root`'s sources, tied to its catalog key and its declaration.

    A literal's key is the one key of that text; where `%@` and `%lld` keys read alike, the translator's note decides,
    then `locations` (when given); a literal still undecided is left without a key."""
    strings = set(strings)
    by_text: Dict[str, Set[str]] = defaultdict(set)
    for key in strings:
        by_text[normalize_key(key)].add(key)
    by_spot = {(spot["file"], spot["line"]): key for key, spots in (locations or {}).items() for spot in spots}
    source: Dict[str, List[str]] = {}
    sites: List[Site] = []
    for lit in scanner.scan_tree(root).literals:
        if lit.rule != "localized-key":
            continue
        if lit.file not in source:
            source[lit.file] = (root / lit.file).read_text(encoding="utf-8", errors="replace").split("\n")
        lines = source[lit.file]
        candidates = by_text.get(lit.text, set())
        if len(candidates) == 1:
            key: Optional[str] = next(iter(candidates))
        else:
            note = lines[lit.line - 2] if lit.line >= 2 else ""
            key = pick_by_note(candidates, note) if candidates else None
            if key is None:
                key = by_spot.get((lit.file, lit.line))
        types, member, case = declarations_at(lines, lit.line)
        owner = owner_type(types, lit.file)
        sites.append(Site(lit.file, lit.line, key, owner, member or "init", case))
    return sites


def owner_type(types: Sequence[str], file: str) -> str:
    """The type that names a site's owner: the innermost, or the type around it when the innermost is only a suffix word
    (the `Wording` of `Book.Wording`, or of `struct Book { enum Wording { … } }`); a file's own name when no type
    encloses it."""
    # Each type's dotted name is read from its last part outward, the innermost type first.
    parts = [part for name in types for part in reversed(name.split("."))]
    for name in parts:
        if strip_suffix(name):
            return name
    return parts[0] if parts else Path(file).stem


# ---------------------------------------------------------------------------------------------- the words of an ID


def strip_suffix(name: str) -> str:
    """The type's name less a final Wording, Vocabulary, Words, or Text (kept whole when nothing would be left)."""
    for suffix in OWNER_SUFFIXES:
        if name.endswith(suffix) and len(name) > len(suffix):
            return name[: -len(suffix)]
    return name if name not in OWNER_SUFFIXES else ""


# Names written with capitals inside a word that the rule below would split: FFmpeg is one word.
ONE_WORD_NAMES = ("FFmpeg",)


def lower_camel(name: str) -> str:
    """`SleepTimer` gives `sleepTimer`; a leading run of capitals is lowered whole, up to the capital that starts the
    next word (`EPUBExport` gives `epubExport`, `DAISYPackage` gives `daisyPackage`); FFmpeg is one word
    (`ffmpegImport`); characters an ID cannot hold are dropped."""
    name = re.sub(r"[^A-Za-z0-9]+", " ", name).strip()
    name = "".join(part[:1].upper() + part[1:] for part in name.split(" ")) if " " in name else name
    for word in ONE_WORD_NAMES:
        if name.startswith(word):
            return word.lower() + name[len(word):]
    run = re.match(r"[A-Z]+", name)
    length = len(run.group()) if run else 0
    if length >= 2:
        if length == len(name) or not name[length].islower():
            return name[:length].lower() + name[length:]
        if length >= 3:
            return name[: length - 1].lower() + name[length - 1:]
    return name[:1].lower() + name[1:]


def owner_segment(owner: str) -> str:
    """The first segment of an ID: the owner less its suffix, in lower camel case."""
    return lower_camel(strip_suffix(owner) or owner)


def camel_words(name: str) -> List[str]:
    """The words of a camel case name: `levelFilterHint` is level, Filter, Hint."""
    return re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|\d+", name)


# What a text with no word of its own (`%@: %@`) is called: its placeholders and its punctuation, by name.
SHAPE_NAMES = {"%@": "Value", "%lld": "Count", ":": "Colon", ",": "Comma", ".": "Period", ";": "Semicolon",
               "(": "Open", ")": "Close", "-": "Dash", "\u2013": "Dash", "\u2014": "Dash", "/": "Slash", "&": "And",
               " ": "Space", "?": "Question", "!": "Bang", "%%": "Percent", "\u2026": "Ellipsis", "\u201c": "Quote",
               "\u201d": "Quote", "\"": "Quote", "\u00b7": "Dot", "|": "Bar", "+": "Plus", "=": "Equals"}


def shape_words(english: str) -> List[str]:
    """The words that name a text made only of placeholders and punctuation: `%@, %@` is Value, Comma, Value."""
    tokens = re.findall(r"%(?:\d+\$)?lld|%(?:\d+\$)?@|%%|[^%]", english)
    names = []
    for token in tokens:
        token = re.sub(r"%\d+\$", "%", token)
        name = SHAPE_NAMES.get(token)
        if name and not (name == "Space" and names and names[-1] == "Space"):
            names.append(name)
    # A space beside a name is just spacing; a text of nothing else is called Space.
    spaced = [n for n in names if n != "Space"]
    return spaced or ["space"]


def english_words(english: str, keep_stopwords: bool = False, marked: bool = False) -> List[str]:
    """The words of an English text, letters and digits only, in order: placeholders, apostrophes, and punctuation go; the
    small words go too unless asked to stay (but never all of them). A `marked` form names the placeholders in place
    (`Articles (%lld)` is Articles, Count), for keys whose words alone are the same."""
    if not re.search(r"[A-Za-z0-9]", re.sub(r"%(?:\d+\$)?(?:lld|@)", "", english)):
        return shape_words(english)
    if marked:
        text = re.sub(r"%(?:\d+\$)?lld", " Count ", english)
        text = re.sub(r"%(?:\d+\$)?@", " Value ", text)
        text = text.replace("%%", " ")
    else:
        text = re.sub(r"%(?:\d+\$)?(?:lld|@)|%%", " ", english)
    text = re.sub(r"['\u2019]s\b", "", text)
    text = re.sub(r"['\u2019]", "", text)
    words = [w.replace("-", "") for w in re.findall(r"[A-Za-z]+-\d+|\d+-\d+|[A-Za-z0-9]+", text)]
    if not words:
        return shape_words(english)
    if keep_stopwords:
        return words
    kept = [w for w in words if w.lower() not in STOPWORDS]
    return kept or words


def camel_join(words: Sequence[str]) -> str:
    """Words in lower camel case; an ID segment never starts with a number, so such a word gets `n` before it."""
    if not words:
        return "text"
    out = words[0].lower() + "".join(w[:1].upper() + w[1:].lower() for w in words[1:])
    return out if out[0].isalpha() else "n" + out


def slug(english: str, count: int, keep_stopwords: bool = False,
         frequency: Optional[Dict[str, int]] = None, marked: bool = False,
         avoid: Optional[Set[str]] = None) -> str:
    """`count` words of the English in lower camel case. Without `frequency` they are the first words (`Move Book to
    Trash?` gives `moveBookTrash`); with it ({word: how many keys of the group hold it}) they are the rarest words of the
    group, in the English's order, because those are the ones that tell the keys apart."""
    words = english_words(english, keep_stopwords, marked)
    # A word the ID already holds (in the member or the case) adds nothing, so a slug takes the content words the earlier
    # segments lack. When too little is left (a bare `to`), it takes the English's first words, small ones too, from the
    # first word the ID does not hold (`%@ stays in its feed: %@` after feed.stays gives `inItsFeed`).
    held = avoid or set()
    fresh = [w for w in words if w.lower() not in held]
    if sum(len(w) for w in fresh) < 4 and held:
        every = english_words(english, True, marked)
        start = 0
        while start < len(every) and every[start].lower() in held:
            start += 1
        rest = every[start:]
        fresh = rest if sum(len(w) for w in rest) >= 4 else fresh
    words = fresh if fresh else words
    if frequency is not None and not marked and count < len(words):
        ranked = sorted(range(len(words)), key=lambda i: (frequency.get(words[i].lower(), 0), -min(len(words[i]), 9), i))
        words = [words[i] for i in sorted(ranked[:count])]
    else:
        words = words[:count]
    return camel_join(words)


def member_segment(member: str) -> str:
    """The member's name as a segment."""
    return lower_camel(member)


# ---------------------------------------------------------------------------------------------- forming the IDs


def first_forms(by_key: Dict[str, List[Site]]) -> Dict[str, Tuple[List[str], str]]:
    """{key: (the parts of its first ID, how it was formed)} where the how is "declaration", "members", "common", or
    "unplaced". The parts leave the English words for later: a key whose first ID another shares takes a slug."""
    forms: Dict[str, Tuple[List[str], str]] = {}
    for key, found in by_key.items():
        decls = {(s.owner, s.member, s.case) for s in found}
        owners = {s.owner for s in found}
        if not found:
            forms[key] = (["unplaced"], "unplaced")
        elif len(decls) == 1:
            owner, member, case = next(iter(decls))
            if member == "init" and not case:
                # An initializer's name says nothing: the strings of the type take their words, as "members" do.
                forms[key] = ([owner_segment(owner)], "members")
                continue
            if case and member in GENERIC_MEMBERS | {"init"}:
                parts = [owner_segment(owner), lower_camel(case)]
            else:
                parts = [owner_segment(owner), member_segment(member)] + ([lower_camel(case)] if case else [])
            forms[key] = (parts, "declaration")
        elif len(owners) == 1:
            forms[key] = ([owner_segment(next(iter(owners)))], "members")
        else:
            forms[key] = (["common"], "common")
    return forms


# The last words of a member's name that say only what kind of text it is; dropped when an ID is too long.
MEMBER_ENDINGS = {"sentence", "message", "explanation", "announcement", "text", "description", "phrase", "wording"}


def lighten_member(parts: List[str], endings: Optional[Set[str]] = None) -> List[str]:
    """The parts with the member's filler words dropped (`titleForKind` gives `titleKind`), keeping its first word; with
    `endings`, also its last word when that word is one of them (`notReadSentence` gives `notRead`)."""
    if len(parts) < 2:
        return parts
    words = camel_words(parts[1])
    kept = [words[0]] + [w for w in words[1:] if w.lower() not in MEMBER_FILLER]
    if endings and len(kept) > 1 and kept[-1].lower() in endings:
        kept = kept[:-1]
    member = kept[0].lower() + "".join(w[:1].upper() + w[1:] for w in kept[1:]) if kept else parts[1]
    return [parts[0], member] + parts[2:]


def shorter_forms(parts: List[str]) -> List[List[str]]:
    """The forms of an ID's parts to try, best first, when the first is too long: the member's own name, the member
    without its filler words, and (when a case follows it) the case alone, as an error's `errorDescription` does."""
    forms = [parts, lighten_member(parts), lighten_member(parts, MEMBER_ENDINGS)]
    if len(parts) >= 3:
        forms.append([parts[0]] + parts[2:])
    return forms


def make_id(parts: Sequence[str], english: Optional[str], words: int, common: bool = False,
            frequency: Optional[Dict[str, int]] = None, marked: bool = False) -> str:
    """`parts` plus, when `english` is given, `words` of its words as the last segment."""
    segments = list(parts)
    if english is not None:
        used = {w.lower() for part in parts for w in camel_words(part)} if not common else set()
        segments.append(slug(english, words, keep_stopwords=common, frequency=frequency, marked=marked, avoid=used))
    return ".".join(segments)


def word_frequency(keys: Iterable[str]) -> Dict[str, int]:
    """{word: the number of the keys' English texts that hold it}, for choosing the words that tell keys apart."""
    count: Counter = Counter()
    for key in keys:
        count.update({w.lower() for w in english_words(key)})
    return dict(count)


def acceptable(ident: str) -> bool:
    """Whether an ID is in the pattern and within the length limit."""
    return len(ident) <= MAX_ID_LENGTH and bool(ID_PATTERN.fullmatch(ident))


# How many of the English's first words a `common` ID starts from (`common.sleepTimer`, `common.saveItAsUtf8ThenImport`).
COMMON_WORDS = 6


def fit_group(keys: List[str], parts: List[str], common: bool, taken: Dict[str, str], start: int = 1) -> Dict[str, str]:
    """IDs for keys that share `parts`, each key's English words added until its ID is its own: one word of the group's
    rarest (a type's own strings start from `start` of the first words, and a `common` ID from six of them with the
    small words kept, so that it reads as the English), and more words for
    each key whose ID another key, or an ID already taken, shares. Keys whose words are all the same then name their
    placeholders (`articlesCount`). A key whose ID is too long then tries the member without its filler words and fewer
    words. Where nothing fits, the key keeps its longest unique form for the review."""
    frequency = None if (common or start > 1) else word_frequency(keys)
    marked: Set[str] = set(keys) if common else set()
    count = {key: (COMMON_WORDS if common else start) for key in keys}

    def words_of(key: str) -> int:
        """How many words the key's English has in its current form."""
        return len(english_words(key, common, key in marked))

    def ident(key: str, use: List[str], words: int) -> str:
        """The key's ID with `words` words after `use`."""
        return make_id(use, key, words, common, frequency, key in marked)

    for round_number in range(2):
        for _ in range(max((words_of(k) for k in keys), default=1) + 1):
            ids = {key: ident(key, parts, count[key]) for key in keys}
            tally = Counter(ids.values())
            clash = [k for k, i in ids.items() if tally[i] > 1 or taken.get(i, k) != k
                     or len(i.rsplit(".", 1)[-1]) <= 3]  # a slug of one or two letters says nothing
            grown = [k for k in clash if count[k] < words_of(k)]
            for key in grown:
                count[key] += 1
            if not grown:
                break
        if round_number == 0 and clash:
            # Words alone cannot tell these apart: name the placeholders and start again from the first words.
            for key in clash:
                marked.add(key)
                count[key] = COMMON_WORDS if common else 1
    ids = {key: ident(key, parts, count[key]) for key in keys}
    for key in keys:
        if acceptable(ids[key]):
            continue
        others = {i for k, i in ids.items() if k != key}
        for use in shorter_forms(parts):
            # From the most words that fit down to one: the parts alone would name only one of the strings.
            tries = [ident(key, use, n) for n in range(count[key], 0, -1)]
            fitted = next((t for t in tries if acceptable(t) and t not in others and taken.get(t, key) == key), None)
            if fitted:
                ids[key] = fitted
                break
    return ids


def resolve(forms: Dict[str, Tuple[List[str], str]], taken: Optional[Dict[str, str]] = None) -> Dict[str, str]:
    """{key: ID} for every key in `forms`.

    A key that is alone with its declaration's ID takes it (the member's name only, no English). Keys that share one
    take English words to tell them apart; a key of "members" takes its type's name and its words; a "common" key takes
    `common` and its first words."""
    taken = dict(taken or {})
    result: Dict[str, str] = {}
    groups: Dict[Tuple[str, str], List[str]] = defaultdict(list)
    for key in sorted(forms):
        parts, how = forms[key]
        groups[(how, ".".join(parts))].append(key)
    # Keys alone with a usable declaration ID take it first, so that no slug takes it from them.
    crowded: List[Tuple[str, str]] = []
    for (how, first), keys in sorted(groups.items()):
        # A key alone with its declaration takes the declaration's name, shortened when it is too long.
        bare = next((".".join(use) for use in shorter_forms(forms[keys[0]][0])
                     if acceptable(".".join(use)) and ".".join(use) not in taken), None) \
            if how == "declaration" and len(keys) == 1 else None
        if bare:
            result[keys[0]] = bare
            taken[bare] = keys[0]
        else:
            crowded.append((how, first))
    for how, first in crowded:
        keys = groups[(how, first)]
        # A type's strings have no member to carry their meaning, so they start from three words, as the design says.
        ids = fit_group(keys, forms[keys[0]][0], how == "common", taken, 3 if how == "members" else 1)
        for key, ident in ids.items():
            taken[ident] = key
            result[key] = ident
    return result


# ---------------------------------------------------------------------------------------------- the table


def table_path(root: Path) -> Path:
    """ids.json under `root`."""
    return root / IDS_PATH


def load_table(path: Path) -> dict:
    """The table at `path`, or an empty one."""
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"version": TABLE_VERSION, "ids": {}, "splits": {}}


def dump_table(table: dict) -> str:
    """The table as text: one key to a line so that a diff reads, keys in sorted order, UTF-8 as written."""
    out = ['{', f'"version": {table["version"]},', '"ids": {']
    ids = sorted(table["ids"].items())
    out += [f'{json.dumps(k, ensure_ascii=False)}: {json.dumps(v)}' + ("," if i < len(ids) - 1 else "")
            for i, (k, v) in enumerate(ids)]
    out += ['},', '"splits": {']
    splits = sorted(table["splits"].items())
    for i, (key, uses) in enumerate(splits):
        out.append(f'{json.dumps(key, ensure_ascii=False)}: [')
        for j, use in enumerate(uses):
            out.append("  " + json.dumps(use, ensure_ascii=False) + ("," if j < len(uses) - 1 else ""))
        out.append("]" + ("," if i < len(splits) - 1 else ""))
    out += ['}', '}']
    return "\n".join(out) + "\n"


def retired_ids(root: Path) -> Set[str]:
    """The IDs in retired-ids.txt: one a line, blank lines and `#` lines skipped."""
    path = root / RETIRED_PATH
    if not path.is_file():
        return set()
    lines = (line.strip() for line in path.read_text(encoding="utf-8").split("\n"))
    return {line for line in lines if line and not line.startswith("#")}


def main_checkout() -> Optional[Path]:
    """The main checkout's folder, found through git (a worktree shares its repository), or None."""
    try:
        common = subprocess.run(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True,
                                text=True, check=True, timeout=20).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return Path(common).parent if common else None


def propose(root: Path, locations_path: Optional[Path], fresh: bool) -> Tuple[dict, Dict[str, Tuple[List[str], str]]]:
    """The table for `root`: its existing IDs kept (unless `fresh`), every other key given one. Also returns how each new
    key was formed."""
    cat = catalog.Catalog.load(root / CATALOG_PATH)
    keys = sorted(cat.strings)
    table = {"version": TABLE_VERSION, "ids": {}, "splits": {}} if fresh else load_table(table_path(root))
    sites = collect_sites(root, keys, load_locations(locations_path))
    by_key: Dict[str, List[Site]] = {key: [] for key in keys}
    for site in sites:
        if site.key:
            by_key[site.key].append(site)
    forms = first_forms({k: v for k, v in by_key.items() if k not in table["ids"]})
    # An existing or retired ID is not offered again to a new key.
    taken = {ident: key for key, ident in table["ids"].items()}
    taken.update({ident: "(retired)" for ident in retired_ids(root)})
    taken.update({use["id"]: key for key, uses in table["splits"].items() for use in uses})
    for key, ident in resolve(forms, taken).items():
        table["ids"][key] = ident
    table["ids"] = {k: v for k, v in table["ids"].items() if k in cat.strings}
    return table, forms


# ---------------------------------------------------------------------------------------------- check


def check(root: Path) -> List[str]:
    """The problems of ids.json under `root`, as sentences; none when it is clean."""
    problems: List[str] = []
    table = load_table(table_path(root))
    cat = catalog.Catalog.load(root / CATALOG_PATH)
    keys = set(cat.strings)
    ids: Dict[str, str] = table.get("ids", {})
    splits: Dict[str, list] = table.get("splits", {})
    retired = retired_ids(root)
    for key in sorted(keys - set(ids)):
        problems.append(f"key without an ID: {key!r}")
    for key in sorted(set(ids) - keys):
        problems.append(f"ID without a key: {ids[key]!r} for {key!r}")
    owners: Dict[str, List[str]] = defaultdict(list)
    for key, ident in ids.items():
        owners[ident].append(key)
    # A split key's ID is also the first of its splits: the key's own ID, listed once.
    split_ids: Dict[str, str] = {}
    for key, uses in splits.items():
        for use in uses:
            if use["id"] in split_ids and split_ids[use["id"]] != key:
                problems.append(f"ID {use['id']!r} is given to two keys: {split_ids[use['id']]!r} and {key!r}")
            split_ids[use["id"]] = key
    for ident, holders in sorted(owners.items()):
        if len(holders) > 1:
            problems.append(f"ID {ident!r} is given to {len(holders)} keys: " + ", ".join(repr(h) for h in sorted(holders)))
        other = split_ids.get(ident)
        if other is not None and other not in holders:
            problems.append(f"ID {ident!r} is given to {holders[0]!r} and to a split of {other!r}")
    everything = set(ids.values()) | set(split_ids)
    for ident in sorted(everything):
        if not ID_PATTERN.fullmatch(ident):
            problems.append(f"ID outside the pattern: {ident!r}")
        if len(ident) > MAX_ID_LENGTH:
            problems.append(f"ID over {MAX_ID_LENGTH} characters ({len(ident)}): {ident!r}")
        if ident in retired:
            problems.append(f"retired ID given again: {ident!r}")
    if splits:
        problems += split_problems(root, cat, ids, splits)
    return problems


def split_problems(root: Path, cat: "catalog.Catalog", ids: Dict[str, str], splits: Dict[str, list]) -> List[str]:
    """What is wrong with the splits: a key not in the catalog, one ID that is not the key's own, a use naming no site, a
    site no use covers, and a site two uses cover."""
    problems: List[str] = []
    # The translators' notes settle every site, so the check needs nothing outside the repository it is given.
    sites = collect_sites(root, cat.strings)
    by_key: Dict[str, List[Site]] = defaultdict(list)
    for site in sites:
        if site.key:
            by_key[site.key].append(site)
    for key, uses in sorted(splits.items()):
        if key not in cat.strings:
            problems.append(f"split of a key not in the catalog: {key!r}")
            continue
        if len(uses) < 2:
            problems.append(f"split of {key!r} has {len(uses)} use; a split has two or more")
        if ids.get(key) not in [u["id"] for u in uses]:
            problems.append(f"the ID of split key {key!r} ({ids.get(key)!r}) is not one of its split IDs")
        found = by_key.get(key, [])
        for site in found:
            covering = [u["id"] for u in uses if set(u["sites"]) & set(site.selectors())]
            if not covering:
                problems.append(f"split of {key!r}: no use covers {site.file}:{site.line} ({site.selector()})")
            elif len(covering) > 1:
                problems.append(f"split of {key!r}: {site.file}:{site.line} is covered by {len(covering)} uses ({', '.join(covering)})")
        known = {s for site in found for s in site.selectors()}
        for use in uses:
            for selector in use["sites"]:
                if selector not in known:
                    problems.append(f"split of {key!r}: use {use['id']!r} names {selector!r}, which holds no site of the key")
    return problems


def main_locations(root: Path) -> Optional[Path]:
    """The main checkout's build/l10n/locations.json, which ties the few ambiguous sites to their keys."""
    base = main_checkout()
    return (base / "build" / "l10n" / "locations.json") if base else None


# ---------------------------------------------------------------------------------------------- suggest


def suggest(root: Path, spot: str) -> str:
    """An ID for the localized call on `FILE:LINE`, by the rules `propose` follows and clear of every ID in use."""
    file, _, line_text = spot.rpartition(":")
    if not file or not line_text.isdigit():
        raise SystemExit("error: give the call as FILE:LINE")
    line = int(line_text)
    path = root / file
    if not path.is_file():
        raise SystemExit(f"error: no such file: {file}")
    lines = path.read_text(encoding="utf-8", errors="replace").split("\n")
    if not 1 <= line <= len(lines):
        raise SystemExit(f"error: {file} has {len(lines)} lines")
    texts = {file: "\n".join(lines)}
    literals = [lit for lit in scanner.scan_texts(texts) if lit.line <= line <= lit.end_line]
    # The English is the call's text: the localized literal, else the literal that is not itself an ID.
    english = None
    for lit in literals:
        if lit.rule == "localized-key":
            english = lit.text
            break
    if english is None:
        for lit in literals:
            if not ID_PATTERN.fullmatch(lit.text):
                english = lit.text
                break
    if english is None:
        raise SystemExit(f"error: no localized call on {file}:{line}")
    types, member, case = declarations_at(lines, line)
    owner = owner_type(types, file)
    parts, _how = first_forms({english: [Site(file, line, english, owner, member or "init", case)]})[english]
    table = load_table(table_path(root))
    taken = set(table["ids"].values()) | {u["id"] for uses in table["splits"].values() for u in uses} | retired_ids(root)
    first = ".".join(parts)
    # The bare declaration first, then the English's words (the small words kept only when nothing else is free).
    candidates = [first]
    for common in (False, True):
        for use in shorter_forms(parts):
            candidates += [make_id(use, english, n, common) for n in (3, 5, 8, 99)]
    for ident in candidates:
        if ID_PATTERN.fullmatch(ident) and len(ident) <= MAX_ID_LENGTH and ident not in taken:
            return ident
    raise SystemExit("error: every form is taken or too long; write the ID by hand")


# ---------------------------------------------------------------------------------------------- command line


def repo_root(argument: Optional[str]) -> Path:
    """The repository to work on: the one named, else the one that holds this script."""
    return Path(argument).resolve() if argument else HERE.parent.parent


def summarize(forms: Dict[str, Tuple[List[str], str]], table: dict) -> str:
    """A few lines on what `propose` formed, for the person running it."""
    how = Counter(h for _p, h in forms.values())
    lengths = sorted(len(v) for v in table["ids"].values())
    over = sum(1 for n in lengths if n > MAX_ID_LENGTH)
    digit = sum(1 for v in table["ids"].values() if v[-1].isdigit())
    return (f"{len(table['ids'])} IDs; formed from {dict(how)}; median {lengths[len(lengths) // 2]} characters, "
            f"longest {lengths[-1]}; over {MAX_ID_LENGTH}: {over}; ending in a digit: {digit}")


def main(argv: Optional[Sequence[str]] = None) -> int:
    """The command line."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("propose", "check", "suggest"):
        p = sub.add_parser(name)
        p.add_argument("--root", help="the repository to work on (default: this one)")
        if name == "propose":
            p.add_argument("--locations", help="build/l10n/locations.json, for sites the notes cannot settle")
            p.add_argument("--fresh", action="store_true", help="form every ID again instead of keeping the existing ones")
            p.add_argument("--out", help="write here instead of ids.json")
        if name == "suggest":
            p.add_argument("spot", metavar="FILE:LINE")
    args = parser.parse_args(argv)
    root = repo_root(args.root)
    if args.command == "propose":
        locations = Path(args.locations) if args.locations else main_locations(root)
        table, forms = propose(root, locations, args.fresh)
        out = Path(args.out) if args.out else table_path(root)
        out.write_text(dump_table(table), encoding="utf-8")
        print(summarize(forms, table))
        return 0
    if args.command == "suggest":
        print(suggest(root, args.spot))
        return 0
    problems = check(root)
    for problem in problems:
        print(problem)
    print(f"ids.py check: {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
