#!/usr/bin/env python3
"""The permanent short ID of every interface string (FR39, phase 3).

An ID is `owner.member[.case]` in lower camel case, taken once from the Swift declaration that holds the string and
then frozen as the call's literal and the catalog's key; a key that several types use is `common.*`. The design is `research/STRINGS-SYSTEM-DESIGN-2026-11-21.md`, section "IDs".

    ids.py suggest FILE:LINE [--root DIR]    propose an ID for the call on that line, clear of every ID in the catalog, in
                                             the code's calls, and retired

The tool reads the sources with `swiftscan`'s lexer; it uses the standard library only and runs under Python 3.9.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

HERE = Path(__file__).resolve().parent
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import catalog  # noqa: E402
from swiftscan import scanner  # noqa: E402

# Where the files live, relative to the repository root.
CATALOG_PATH = "TextMouth/Localization/Localizable.xcstrings"
RETIRED_PATH = "Scripts/l10n/retired-ids.txt"

# The form of an ID (two to four lower camel case segments) and its length limit.
ID_PATTERN = re.compile(r"[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*){1,3}")
MAX_ID_LENGTH = 48
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


# ---------------------------------------------------------------------------------------------- the table


def retired_ids(root: Path) -> Set[str]:
    """The IDs in retired-ids.txt: one a line, blank lines and `#` lines skipped."""
    path = root / RETIRED_PATH
    if not path.is_file():
        return set()
    lines = (line.strip() for line in path.read_text(encoding="utf-8").split("\n"))
    return {line for line in lines if line and not line.startswith("#")}


# ---------------------------------------------------------------------------------------------- check


# ---------------------------------------------------------------------------------------------- suggest


def used_ids(root: Path) -> Set[str]:
    """The IDs in use under `root`: the keys of its catalog, and the IDs of the `InterfaceText.line` calls of its code (a call
    a sync has not brought into the catalog yet)."""
    import interface_calls  # imported here: interface_calls imports this module
    found: Set[str] = set()
    path = root / CATALOG_PATH
    if path.is_file():
        found |= set(catalog.Catalog.load(path).strings)
    for calls in interface_calls.calls_in_tree(root).values():
        found |= {call.id for call in calls if call.id}
    return found


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
    # An ID is taken when the catalog holds it, a call of the code uses it (not yet synced), or it is retired.
    taken = used_ids(root) | retired_ids(root)
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


def main(argv: Optional[Sequence[str]] = None) -> int:
    """The command line."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    suggested = sub.add_parser("suggest")
    suggested.add_argument("--root", help="the repository to work on (default: this one)")
    suggested.add_argument("spot", metavar="FILE:LINE")
    args = parser.parse_args(argv)
    print(suggest(repo_root(args.root), args.spot))
    return 0


if __name__ == "__main__":
    sys.exit(main())
