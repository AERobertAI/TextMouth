"""From the interface words of a section to the Swift files that hold them (``suggest-src --strings``).

A user page names no code. It names menus, buttons, settings, and what VoiceOver
speaks ("Search Library…", "Match Case", "Keep This Code"), and the project's rule
is that every one of those strings lives in a ``…Wording`` enum. So the words lead
to the code:

1. ``interface_phrases`` collects the section's phrases: its heading and every quoted
   (``"..."``, curly quotes), bold (``**...**``), or menu-path (``Edit > Find > Search
   Library…``, split at `` > ``) interface name.
2. ``find_in_swift`` reads each app Swift file once, finds its string literals (comments
   skipped), and notes the phrases each literal equals, or holds as whole words.
3. The files are ranked by the phrases they match; a file declaring a ``…Wording`` type
   comes first among equals, with the files that name that type listed as its users
   (the view or view model that shows the words is the likelier ``src``).

Standard library only, read-only, one pass over the files, and no cache on disk.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from typing import Any, Dict, Iterator, List, Optional, Tuple

import citations
import output
import targets
from docmodel import name_inside
from output import Hit
from repofiles import RepoFiles
from swiftindex import read_without_following_links

# ---------------------------------------------------------------------------
# What counts as a phrase.
# ---------------------------------------------------------------------------

# The fewest characters a phrase has, after its ellipsis is dropped.
MIN_PHRASE_LENGTH = 2

# Text in straight quotes (one line), in curly quotes, and in bold.
_STRAIGHT_QUOTED = re.compile(r'"([^"\n]+)"')
_CURLY_QUOTED = re.compile(r"“([^”]+)”")
_BOLD = re.compile(r"\*\*([^*\n]+?)\*\*")

# A menu path written in plain text: Capitalised words joined by " > ". A segment is
# capitalised words (small joining words such as "to" allowed between them), and may
# end in an ellipsis, which also ends the segment: "Edit > Find > Search Library… (Option-Command-F)".
_CAPITAL_WORD = r"[A-Z][\w'’\-]*"
_JOINING_WORD = r"(?:a|an|the|of|to|in|on|and|or|for|with|from|as|at|by)"
_SEGMENT = rf"{_CAPITAL_WORD}(?: (?:{_CAPITAL_WORD}|{_JOINING_WORD}(?= {_CAPITAL_WORD})))*(?:…|\.\.\.)?"
_MENU_PATH = re.compile(rf"{_SEGMENT}(?: > {_SEGMENT})+")

# The separator inside a menu path.
_PATH_SEPARATOR = " > "

# Typographic apostrophes, written as the straight one when matching.
_APOSTROPHES = str.maketrans({"’": "'", "‘": "'"})
_WHITESPACE = re.compile(r"\s+")


def normalise(text: str) -> str:
    """``text`` as phrases and literals are compared: no ellipsis, straight apostrophes, folded case, one space between words."""
    text = text.translate(_APOSTROPHES).replace("…", "")
    text = _WHITESPACE.sub(" ", text).strip()
    if text.endswith("..."):
        text = text[:-3].rstrip()
    return text.casefold()


@dataclass(frozen=True)
class Phrase:
    """One interface name: as written in the doc, and as it is compared."""

    text: str   # as written, with Markdown marks removed and the ellipsis kept
    key: str    # ``normalise(text)``


def _add_phrase(found: Dict[str, Phrase], written: str) -> None:
    """Add ``written`` (and each part of a menu path in it) to ``found`` unless it is too short, has no letter, or is there."""
    for part in written.split(_PATH_SEPARATOR):
        text = targets.strip_markup(part).strip()
        key = normalise(text)
        if len(key) >= MIN_PHRASE_LENGTH and any(char.isalpha() for char in key):
            found.setdefault(key, Phrase(text, key))


# What joins two names in a heading ("Match Case and Regular Expression"): each is a phrase too.
_HEADING_JOINT = re.compile(r" and | or |, ")


def _menu_path_parts(text: str) -> Iterator[str]:
    """The segments of each menu path written in ``text``, and the last word of a path's first segment.

    The first segment of a path in a sentence may carry the sentence's first word
    ("Open Settings > Library"), so its last word is a phrase of its own as well.
    """
    for match in _MENU_PATH.finditer(text):
        segments = match.group().split(_PATH_SEPARATOR)
        yield from segments
        first_words = segments[0].split()
        if len(first_words) > 1:
            yield first_words[-1]


def interface_phrases(title: str, blocks: List[Tuple[int, str]]) -> List[Phrase]:
    """The section's phrases, in the order found, each once: its ``title``, then the names in its prose ``blocks``.

    The title is also split where it joins names with "and", "or", or a comma.
    A name is a quoted or bold text or a menu path (split at `` > ``); each is at
    least ``MIN_PHRASE_LENGTH`` characters with a letter in it. ``Files:`` lists are
    paths, not words, and are skipped.
    """
    found: Dict[str, Phrase] = {}
    _add_phrase(found, title)
    # A heading often joins two interface names; the whole heading is kept as well.
    for part in _HEADING_JOINT.split(targets.strip_markup(title)):
        _add_phrase(found, part)
    for _first_line, text in blocks:
        if citations.FILES_LINE.match(text):
            continue
        for pattern in (_STRAIGHT_QUOTED, _CURLY_QUOTED, _BOLD):
            for match in pattern.finditer(text):
                _add_phrase(found, match.group(1))
        for part in _menu_path_parts(text):
            _add_phrase(found, part)
    return list(found.values())


# ---------------------------------------------------------------------------
# String literals.
# ---------------------------------------------------------------------------

# Swift's lexical pieces that matter here, tried left to right so a quote inside a comment
# or a ``//`` inside a string is read as the first thing that starts it. Group 1 is a
# triple-quoted string's text, group 2 a one-line string's.
_LEXEME = re.compile(
    r"//[^\n]*"                              # a line comment
    r"|/\*.*?\*/"                            # a block comment
    r'|"""(.*?)"""'                          # a multi-line string
    r'|"((?:[^"\\\n]|\\.)*)"',               # a one-line string, escapes allowed
    re.DOTALL,
)
# An interpolation, ``\(count)``, which stands for text unknown here; one object-replacement
# character in its place keeps a phrase from matching across it.
_INTERPOLATION = re.compile(r"\\\([^)\n]*\)")
_UNKNOWN = "\ufffc"
# The escapes a literal may hold that make a character: ``\"``, ``\\``, ``\u{2026}``.
_ESCAPE = re.compile(r"\\(u\{([0-9A-Fa-f]{1,8})\}|.)", re.DOTALL)
_SIMPLE_ESCAPES = {"n": " ", "t": " ", "r": " ", "0": " "}


def _unescape(literal: str) -> str:
    """The text a literal stands for: interpolations marked, escapes made characters."""
    literal = _INTERPOLATION.sub(_UNKNOWN, literal)

    def replace(match: "re.Match[str]") -> str:
        """One escape: a unicode scalar, a line or tab (a space), or the character itself."""
        if match.group(2):
            try:
                return chr(int(match.group(2), 16))
            except (ValueError, OverflowError):
                return ""
        return _SIMPLE_ESCAPES.get(match.group(1), match.group(1))

    return _ESCAPE.sub(replace, literal)


def swift_literals(text: str) -> Iterator[Tuple[int, str]]:
    """The ``(offset, text)`` of each string literal of Swift ``text``, comments skipped.

    A multi-line literal comes as one item for each of its non-blank lines, each at
    its own offset.
    """
    for match in _LEXEME.finditer(text):
        triple, single = match.group(1), match.group(2)
        if single is not None:
            yield match.start(2), _unescape(single)
        elif triple is not None:
            offset = match.start(1)
            for line in triple.split("\n"):
                if line.strip():
                    yield offset, _unescape(line)
                offset += len(line) + 1


# ---------------------------------------------------------------------------
# Which files, and what is in them.
# ---------------------------------------------------------------------------

# Top-level folders whose Swift is not the app's: vendored code, build products, tooling.
_NOT_APP_FOLDERS = frozenset({"Vendor", "build", "DerivedData", "Scripts"})
# A top-level folder ending so holds tests (``TextMouthTests``, ``TextMouthiOSUITests``).
_TEST_FOLDER_SUFFIX = "Tests"

# A type whose name ends in Wording, declared; and any use of such a type, with a member.
_WORDING_DECLARATION = re.compile(r"\b(?:enum|struct|class|actor|extension)\s+(\w*Wording)\b")
_WORDING_USE = re.compile(r"\b(\w+Wording)\b(?:\.(\w+))?")
# The name a source line declares: ``static let closeButton = "Close"``, ``case close = "Close"``.
_DECLARED_NAME = re.compile(r"\b(?:let|var|func|case)\s+([A-Za-z_]\w*)")

# The longest source line shown beside a match.
SOURCE_LIMIT = 100
# The fewest characters a phrase has to be found inside a longer literal: "the" or "Lists" would be in every sentence.
MIN_INSIDE_LENGTH = 5
# The most users listed under a wording file.
MOST_USERS = 3
# The most phrases printed under a file in the text form (``--json`` holds them all).
MOST_PHRASES_SHOWN = 5

EQUAL = "equal"      # a literal that is the phrase
INSIDE = "inside"    # a literal that holds the phrase as whole words


def is_app_swift(path: str) -> bool:
    """True for a Swift file of the app: not under ``Vendor/``, ``build/``, ``Scripts/``, or a tests folder."""
    top = path.split("/", 1)[0]
    return (path.endswith(".swift") and top not in _NOT_APP_FOLDERS
            and not top.endswith(_TEST_FOLDER_SUFFIX))


@dataclass
class Match:
    """Where one phrase was found in one file: the first literal, how it matched, and the name it is declared with."""

    phrase: Phrase
    kind: str                  # EQUAL or INSIDE
    line: int
    source: str                # the line as written, stripped and cut
    member: Optional[str]      # ``closeButton`` in ``static let closeButton = "Close"``, when the line declares one


@dataclass
class FileResult:
    """One file's matches, and (for a wording file) the files that use its types."""

    path: str
    matches: Dict[str, Match] = field(default_factory=dict)      # phrase key -> its best match
    wording_types: List[str] = field(default_factory=list)       # the ``…Wording`` types it declares
    users: List[Tuple[str, int]] = field(default_factory=list)   # (path, references), best first

    @property
    def is_wording(self) -> bool:
        """True when the file declares a type whose name ends in ``Wording``."""
        return bool(self.wording_types)

    @property
    def first_line(self) -> int:
        """The line of the earliest match."""
        return min(match.line for match in self.matches.values())

    def rank(self) -> Tuple[int, int, int, str]:
        """The sort key: most phrases, then a wording file, then most exact matches, then path."""
        exact = sum(1 for match in self.matches.values() if match.kind == EQUAL)
        return (-len(self.matches), 0 if self.is_wording else 1, -exact, self.path)


class _FileReferences:
    """What a file says about wording types: how often it names each, and each member of one."""

    def __init__(self) -> None:
        """Start with nothing counted."""
        self.types: Counter = Counter()      # type name -> times named
        self.members: Counter = Counter()    # (type name, member) -> times named


def _line_at(text: str, offset: int) -> Tuple[int, str]:
    """The 1-based line number of ``offset`` in ``text`` and that line, stripped and cut to ``SOURCE_LIMIT``."""
    number = text.count("\n", 0, offset) + 1
    begin = text.rfind("\n", 0, offset) + 1
    end = text.find("\n", offset)
    line = text[begin: len(text) if end == -1 else end].strip()
    if len(line) > SOURCE_LIMIT:
        line = line[:SOURCE_LIMIT - 1] + output.ELLIPSIS
    return number, line


def _holds_whole(literal: str, phrase: str) -> bool:
    """True when ``phrase`` is in ``literal`` as whole words (no letter or digit touches it)."""
    start = literal.find(phrase)
    while start != -1:
        end = start + len(phrase)
        before_ok = start == 0 or not literal[start - 1].isalnum() or not phrase[0].isalnum()
        after_ok = end == len(literal) or not literal[end].isalnum() or not phrase[-1].isalnum()
        if before_ok and after_ok:
            return True
        start = literal.find(phrase, start + 1)
    return False


def _record(result: FileResult, phrase: Phrase, kind: str, text: str, offset: int) -> None:
    """Note a match of ``phrase`` in ``result`` unless a better one (equal beats inside; earlier beats later) is there."""
    held = result.matches.get(phrase.key)
    if held is not None and (held.kind == EQUAL or kind == INSIDE):
        return
    number, source = _line_at(text, offset)
    declared = _DECLARED_NAME.search(source)
    result.matches[phrase.key] = Match(phrase, kind, number, source, declared.group(1) if declared else None)


def _scan_file(text: str, path: str, phrases: List[Phrase]) -> Tuple[FileResult, _FileReferences]:
    """The matches of ``phrases`` among the literals of one file, and the wording types it declares and names."""
    result = FileResult(path)
    by_key = {phrase.key: phrase for phrase in phrases}
    for offset, literal in swift_literals(text):
        key = normalise(literal)
        if len(key) < MIN_PHRASE_LENGTH:
            continue
        if key in by_key:
            _record(result, by_key[key], EQUAL, text, offset)
        # A literal holds a phrase when the phrase is in it at all, and then as whole words.
        for phrase in phrases:
            if (len(phrase.key) >= MIN_INSIDE_LENGTH and phrase.key != key and phrase.key in key
                    and _holds_whole(key, phrase.key)):
                _record(result, phrase, INSIDE, text, offset)
    references = _FileReferences()
    # The substring test skips the two regexes for the files that never say it.
    if "Wording" in text:
        for declared in _WORDING_DECLARATION.finditer(text):
            if declared.group(1) not in result.wording_types:
                result.wording_types.append(declared.group(1))
        for used in _WORDING_USE.finditer(text):
            references.types[used.group(1)] += 1
            if used.group(2):
                references.members[(used.group(1), used.group(2))] += 1
    return result, references


def _users_of(result: FileResult, results: Dict[str, FileResult],
              references: Dict[str, _FileReferences]) -> List[Tuple[str, int]]:
    """The files that name a type ``result`` declares, best first: ``(path, references)``, at most ``MOST_USERS``.

    A file ranks higher for naming a member that a phrase matched (``LibrarySearchWording.closeButton``),
    then for naming the type more often; a file that declares a wording type itself comes last.
    """
    types = set(result.wording_types)
    members = {(kind, match.member) for match in result.matches.values() if match.member
               for kind in types}
    ranked: List[Tuple[Tuple[int, int, int, str], str, int]] = []
    for path, found in references.items():
        if path == result.path:
            continue
        named = sum(count for type_name, count in found.types.items() if type_name in types)
        if not named:
            continue
        # A file that declares one of the same types (an extension) is part of the wording, not a user.
        other = results.get(path)
        if other is not None and types & set(other.wording_types):
            continue
        member_hits = sum(1 for key in members if found.members.get(key))
        declares = 1 if other is not None and other.is_wording else 0
        ranked.append(((declares, -member_hits, -named, path), path, named))
    ranked.sort()
    return [(path, named) for _key, path, named in ranked[:MOST_USERS]]


def find_in_swift(repo: RepoFiles, phrases: List[Phrase]) -> List[FileResult]:
    """The app's Swift files holding any of ``phrases`` in a string literal, ranked (see ``FileResult.rank``).

    Each file is read once, as bytes (a symbolic link is never followed). A wording
    file carries its users. Files that match nothing are not returned.
    """
    if not phrases:
        return []
    matched: Dict[str, FileResult] = {}
    declaring: Dict[str, FileResult] = {}     # every file that declares a wording type, matched or not
    references: Dict[str, _FileReferences] = {}
    for path in sorted(repo.files):
        if not is_app_swift(path):
            continue
        relative = name_inside(repo.root, path)
        data = read_without_following_links(os.path.join(repo.root, relative)) if relative else None
        if data is None:
            continue
        result, found = _scan_file(data.decode("utf-8", errors="replace"), path, phrases)
        if found.types:
            references[path] = found
        if result.is_wording:
            declaring[path] = result
        if result.matches:
            matched[path] = result
    for result in matched.values():
        if result.is_wording:
            result.users = _users_of(result, declaring, references)
    return sorted(matched.values(), key=FileResult.rank)


# ---------------------------------------------------------------------------
# Output.
# ---------------------------------------------------------------------------

def _file_hit(result: FileResult, heading: str) -> Hit:
    """The hit for one file: its first match's line, how many phrases, and (for ``--json``) every match and user."""
    count = len(result.matches)
    text = f"{count} phrase{'' if count == 1 else 's'}" + (", wording" if result.is_wording else "")
    extra: Dict[str, Any] = {
        "wording": result.wording_types,
        "phrases": [{"phrase": match.phrase.text, "match": match.kind, "line": match.line, "source": match.source}
                    for match in result.matches.values()],
        "users": [{"path": path, "references": named} for path, named in result.users],
    }
    return Hit(result.path, result.first_line, result.first_line, heading, text, extra=extra)


def _detail_lines(result: FileResult) -> List[str]:
    """The indented lines under a file in the text form: each phrase's first match, then its users."""
    lines: List[str] = []
    shown = list(result.matches.values())[:MOST_PHRASES_SHOWN]
    for match in shown:
        lines.append(f"  \"{match.phrase.text}\" ({match.kind}) line {match.line}: {match.source}")
    if len(result.matches) > len(shown):
        lines.append(f"  and {len(result.matches) - len(shown)} more phrases")
    for path, named in result.users:
        lines.append(f"  used by {path} ({named} reference{'' if named == 1 else 's'})")
    return lines


def emit_files(results: List[FileResult], heading: str, args: Any) -> int:
    """Print the files up to the cap (``--max``, counting files), and return how many there were in all.

    Text form: one ``path:line-line  heading  text`` line per file, as every command
    prints, then the file's matches and users on indented lines. ``--json`` prints one
    object per file. A line on standard error says when the cap left files out.
    """
    limit = output.cap(args)
    as_json = getattr(args, "json", False)
    for number, result in enumerate(results, start=1):
        if limit and number > limit:
            break
        hit = _file_hit(result, heading)
        if as_json:
            print(json.dumps(output.hit_object(hit), ensure_ascii=False))
        else:
            print(output.format_hit(hit))
            for line in _detail_lines(result):
                print(line)
    if limit and len(results) > limit:
        print(f"doclib: {limit} of {len(results)} files shown; --max 0 shows all", file=sys.stderr)
    return len(results)
