"""An index of the Swift declarations in the repository, and the names a section's prose mentions.

``SwiftIndex.load`` scans every Swift file once, finding each declaring keyword with
``bytes.find``, and remembers each ``class``, ``struct``, ``enum``, ``protocol``, ``actor``, ``typealias``,
``func``, ``extension``, and enum ``case`` it finds, by name. It only answers whether a name exists
and where: it matches inside comments and strings too, which is accepted.

``mentions`` lists the code names a section's prose names, backticked or (for the
types the index declares) written bare, as the architecture pages do.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Tuple

import citations
import docmodel
from repofiles import RepoFiles
from sentences import protected_spans

# The declaration kinds that make a name a type.
TYPE_KINDS = frozenset({"class", "struct", "enum", "protocol", "actor", "typealias"})

# The kind of an ``extension`` declaration, and of a function.
KIND_EXTENSION = "extension"
KIND_FUNC = "func"
# The kind of an enum case: ``case nestedTooDeeply(limit: Int)`` is called like a function.
KIND_CASE = "case"

# Where vendored code lives; its Swift (there is none today) is not TextMouth's own.
VENDOR_FOLDER = "Vendor/"

# What follows a declaring keyword: white space and then (in a look-ahead, so that
# ``class func foo`` still finds ``func foo``) the name, dotted for ``extension Book.Storage``.
_AFTER_KEYWORD = re.compile(rb"\s+(?=([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*))")
# The declaring keywords, as the bytes ``scan_keywords`` looks for. Each is found with
# ``bytes.find``, which skips along at memory speed; a pattern per keyword read 30 MB in
# 0.16 s, and one pattern for all of them in 0.5 s. The word boundary before the keyword,
# and the white space and name after it, are checked by hand and by ``_AFTER_KEYWORD``.
_KEYWORDS = tuple(
    (keyword, keyword.encode("ascii"))
    for keyword in ("class", "struct", "enum", "protocol", "actor", "typealias", "func", "extension", "case")
)
# The bytes that are word characters (letters, digits, underscore, and every non-ASCII byte).
_WORD_BYTES = frozenset(range(48, 58)) | frozenset(range(65, 91)) | frozenset(range(97, 123)) \
    | {95} | frozenset(range(128, 256))

# Words that follow a declaring keyword without being a name: ``class func``,
# ``class var``, ``struct is`` in a comment. Reserved words, never a declared name.
_RESERVED = frozenset({
    "func", "var", "let", "init", "deinit", "subscript", "class", "struct", "enum", "protocol",
    "extension", "typealias", "associatedtype", "static", "case", "default", "where", "is", "as",
    "in", "for", "if", "else", "switch", "while", "repeat", "return", "break", "continue", "throw",
    "throws", "rethrows", "try", "catch", "do", "import", "self", "Self", "super", "nil", "true",
    "false", "inout", "operator",
})
# Modifiers that may sit between ``class`` and what it modifies (``class final func``);
# a type may not be named by one, but a function may (``func open()``).
_MODIFIERS = frozenset({
    "final", "override", "public", "private", "internal", "fileprivate", "open", "mutating",
    "nonmutating", "lazy", "weak", "unowned", "convenience", "required", "dynamic", "nonisolated",
    "optional", "indirect", "prefix", "postfix", "infix", "async", "actor",
})

# The last part of a dotted name that makes it a file name (``Info.plist``), not a code name.
FILE_EXTENSIONS = frozenset({
    "plist", "md", "json", "txt", "yml", "yaml", "xml", "html", "css", "js", "py", "sh", "swift",
    "h", "m", "mm", "c", "strings", "entitlements", "xcconfig", "xcodeproj", "pbxproj", "xcscheme",
    "storyboard", "xib", "xcassets", "xcstrings", "csv", "log", "zip", "epub", "mobi", "azw3",
    "pdf", "rtf", "doc", "docx", "ogg", "mp3", "m4a", "m4b", "wav", "png", "jpg", "jpeg", "gif",
    "svg", "icns", "app", "dmg", "lock", "toml", "ini", "cfg", "conf", "db", "sqlite", "brf",
    "brl", "ctb", "utb", "dis", "cti",
})

# A word shaped like a Swift type: capital first, a lowercase letter, and a second capital.
_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass(frozen=True)
class Declaration:
    """One declaration: its name, kind, file, line, and the declaration's line as written."""

    name: str
    kind: str          # one of TYPE_KINDS, "func", "extension", or "case"
    path: str
    line: int
    text: str          # the declaration's line, stripped


@dataclass(frozen=True)
class Mention:
    """A code name a section's prose names, as written, with its line."""

    name: str          # as written: "Book.Storage", "startLibrary()", "ReaderViewModel"
    line: int
    backticked: bool


def is_capitalised_word(word: str) -> bool:
    """True for a word that starts with a capital letter and holds a lowercase letter (``Book``, not ``EPUB``)."""
    return word[:1].isupper() and any(c.islower() for c in word)


def is_type_shaped(word: str) -> bool:
    """True for a word shaped like a Swift type: ``ReaderViewModel``, ``KF8Layout``, not ``Reader`` or ``EPUB``.

    It is a capitalised word (``is_capitalised_word``) that holds a second capital.
    """
    return is_capitalised_word(word) and any(c.isupper() for c in word[1:])


def is_file_name(written: str) -> bool:
    """True when a backticked name is a file name (``Info.plist``): dotted, not a call, ending in a file extension."""
    parts = written.lstrip(".").split(".")
    return len(parts) > 1 and "(" not in written and parts[-1].lower() in FILE_EXTENSIONS


def name_keys(written: str) -> List[str]:
    """The names to look up for a name as written in a doc, best first.

    A call (``startLibrary()``) is looked up by the name before its parenthesis; a
    dotted name (``Book.Storage``, ``.shared``) by its last part, then its first.
    """
    bare = written.split("(", 1)[0].lstrip(".")
    parts = [part for part in bare.split(".") if part]
    keys: List[str] = []
    for part in (parts[-1:] + parts[:1]):
        if part not in keys:
            keys.append(part)
    return keys


def is_call(written: str) -> bool:
    """True when a name as written is a call, such as ``startLibrary()``."""
    return "(" in written


def read_without_following_links(full: str) -> Optional[bytes]:
    """The bytes of the file at ``full``, or None when it cannot be read or is a symbolic link.

    One ``open`` that refuses a link (``O_NOFOLLOW``) and one ``read`` of the file's size,
    which is quicker than a link test and Python's buffered reader; a link is never
    followed, so nothing outside the repository is read.
    """
    try:
        descriptor = os.open(full, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        return None
    try:
        size = os.fstat(descriptor).st_size
        # A file comes back whole in one read of one byte more than its size; read on in case it did not.
        data = os.read(descriptor, size + 1)
        if len(data) <= size:
            chunks = [data]
            while True:
                chunk = os.read(descriptor, 1 << 20)
                if not chunk:
                    break
                chunks.append(chunk)
            data = b"".join(chunks)
        return data
    except OSError:
        return None
    finally:
        os.close(descriptor)


def scan_keywords(data: bytes) -> List[Tuple[int, str, bytes]]:
    """Every declaring keyword of ``data`` that starts a word and is followed by a name.

    The result is ``(offset, keyword, name as written)``, in the order written (and for
    one offset in keyword order). A keyword is found where it starts a word: the byte
    before it, if any, is no letter, digit, underscore, or non-ASCII byte.
    """
    found: List[Tuple[int, str, bytes]] = []
    word_bytes = _WORD_BYTES
    for keyword, literal in _KEYWORDS:
        position = data.find(literal)
        while position != -1:
            if position == 0 or data[position - 1] not in word_bytes:
                match = _AFTER_KEYWORD.match(data, position + len(literal))
                if match:
                    found.append((position, keyword, match.group(1)))
                    if keyword == KIND_CASE:
                        # ``case a, b(x: Int), c`` declares three cases; each later one is
                        # placed at its own offset.
                        found.extend((offset, keyword, name)
                                     for offset, name in more_case_names(data, match.start(1) + len(match.group(1))))
            position = data.find(literal, position + 1)
    found.sort()
    return found


# What may follow an enum case's name before the next one in a list: its associated
# values (one level of parentheses) or a raw value, then a comma and the next name.
_NEXT_CASE = re.compile(rb"(?:\([^()\n]*\))?(?:[ \t]*=[ \t]*[^,\n]+?)?[ \t]*,[ \t]*([A-Za-z_]\w*)")


def more_case_names(data: bytes, position: int) -> List[Tuple[int, bytes]]:
    """The names after the first in ``case a, b(x: Int), c = 3``, with their offsets.

    ``position`` is just past the first name. The list ends at the line's end or at
    anything that is not a comma and a name, so a pattern of a ``switch`` (``case .a,
    .b:``) adds nothing.
    """
    found: List[Tuple[int, bytes]] = []
    match = _NEXT_CASE.match(data, position)
    while match:
        found.append((match.start(1), match.group(1)))
        match = _NEXT_CASE.match(data, match.end())
    return found


class SwiftIndex:
    """Where each name is declared in the repository's Swift files."""

    def __init__(self, declarations: Iterable[Declaration] = ()) -> None:
        """Index ``declarations`` by name, in the order given."""
        self._by_name: Dict[str, List[Declaration]] = {}
        for declaration in declarations:
            self._by_name.setdefault(declaration.name, []).append(declaration)

    @classmethod
    def load(cls, repo: RepoFiles) -> "SwiftIndex":
        """Scan every ``*.swift`` file of ``repo`` outside ``Vendor/``, once.

        Files are read as bytes and matched as bytes, which is quicker than decoding
        them; a symbolic link is never followed (``read_without_following_links``), so
        nothing outside the repository is read.
        """
        index = cls()
        for path in sorted(repo.files):
            if path.endswith(".swift") and not path.startswith(VENDOR_FOLDER):
                index._scan(repo, path)
        return index

    def _scan(self, repo: RepoFiles, path: str) -> None:
        """Add the declarations of one file."""
        relative = docmodel.name_inside(repo.root, path)
        if relative is None:
            return
        data = read_without_following_links(os.path.join(repo.root, relative))
        if data is None:
            return
        line = 1
        last = 0
        for position, keyword, raw in scan_keywords(data):
            written = raw.decode("ascii")
            # For ``extension Book.Storage`` the extended type is the last part.
            name = written.rpartition(".")[2] if keyword == KIND_EXTENSION else written.split(".")[0]
            if name in _RESERVED or (keyword != KIND_FUNC and name in _MODIFIERS):
                continue
            # Count lines from the previous declaration, not from the start of the file.
            line += data.count(b"\n", last, position)
            last = position
            begin = data.rfind(b"\n", 0, position) + 1
            end = data.find(b"\n", position)
            text = data[begin: len(data) if end == -1 else end].decode("utf-8", errors="replace").strip()
            self._by_name.setdefault(name, []).append(Declaration(name, keyword, path, line, text))

    def declarations(self, name: str) -> List[Declaration]:
        """Every declaration of ``name``, in file and line order (empty when there is none)."""
        return list(self._by_name.get(name, ()))

    def is_type(self, name: str) -> bool:
        """True when ``name`` is declared with a type keyword or is extended."""
        return any(d.kind in TYPE_KINDS or d.kind == KIND_EXTENSION for d in self._by_name.get(name, ()))

    def is_func(self, name: str) -> bool:
        """True when a function is declared with this name."""
        return any(d.kind == KIND_FUNC for d in self._by_name.get(name, ()))

    def is_callable(self, name: str) -> bool:
        """True when a call of ``name`` can be written: a function, or an enum case (``nestedTooDeeply(limit:)``)."""
        return any(d.kind in (KIND_FUNC, KIND_CASE) for d in self._by_name.get(name, ()))

    def type_files(self, name: str) -> List[str]:
        """The files with a type declaration of ``name`` (extensions left out), in order, once each."""
        return [d.path for d in self._first_per_file(name, lambda d: d.kind in TYPE_KINDS)]

    def func_files(self, name: str) -> List[str]:
        """The files declaring a function ``name``, in order, once each."""
        return [d.path for d in self._first_per_file(name, lambda d: d.kind == KIND_FUNC)]

    def _first_per_file(self, name: str, wanted: Callable[[Declaration], bool]) -> List[Declaration]:
        """The first declaration of ``name`` that ``wanted`` accepts in each file, in file order."""
        first: Dict[str, Declaration] = {}
        for declaration in self._by_name.get(name, ()):
            if wanted(declaration):
                first.setdefault(declaration.path, declaration)
        return list(first.values())

    def lookup(self, written: str) -> List[Declaration]:
        """The declarations a name as written leads to: types, then extensions, then functions.

        Each group keeps file and line order. The name's keys (``name_keys``) are tried
        in turn and the first with a declaration decides.
        """
        rank = {KIND_EXTENSION: 1, KIND_FUNC: 2, KIND_CASE: 2}
        for key in name_keys(written):
            found = self.declarations(key)
            if found:
                # sorted is stable, so each rank keeps its file and line order.
                return sorted(found, key=lambda d: rank.get(d.kind, 0))
        return []

    def defining_declarations(self, written: str) -> List[Declaration]:
        """The first declaration in each file that defines a name as written, in file order.

        A call is defined by its functions, any other name by its type declarations
        (an extension adds nothing). The name's keys (``name_keys``) are tried in turn
        and the first with any declaration decides.
        """
        call = is_call(written)
        for key in name_keys(written):
            found = self._first_per_file(key, (lambda d: d.kind in (KIND_FUNC, KIND_CASE)) if call
                                         else (lambda d: d.kind in TYPE_KINDS))
            if found:
                return found
        return []


def _bare_type_words(text: str) -> List[Tuple[int, str]]:
    """The ``(offset, word)`` of each type-shaped word of ``text`` outside code spans and links."""
    protected = protected_spans(text)
    found: List[Tuple[int, str]] = []
    # Protected spans are sorted and disjoint, so one pointer walks them with the words.
    pointer = 0
    for match in _WORD.finditer(text):
        word = match.group()
        if not is_type_shaped(word):
            continue
        while pointer < len(protected) and protected[pointer][1] <= match.start():
            pointer += 1
        if pointer < len(protected) and protected[pointer][0] <= match.start():
            continue
        found.append((match.start(), word))
    return found


def mentions(blocks: Iterable[Tuple[int, str]], index: Optional[SwiftIndex] = None) -> List[Mention]:
    """The code names a section's prose blocks name, in the order written.

    Each backticked name (``citations.identifier_positions``) is a mention. With an
    ``index``, so is each unbackticked word that is shaped like a Swift type and that
    the index declares as a type. ``Files:`` blocks are not prose to read.
    """
    blocks = list(blocks)
    # (block, offset, Mention) so the two kinds merge in written order.
    found: List[Tuple[int, int, Mention]] = []
    for number, offset, line, content in citations.identifier_positions(blocks):
        found.append((number, offset, Mention(content, line, True)))
    if index is not None:
        for number, (first_line, text) in enumerate(blocks):
            if citations.FILES_LINE.match(text):
                continue
            for offset, word in _bare_type_words(text):
                if index.is_type(word):
                    found.append((number, offset, Mention(word, citations.line_of(first_line, text, offset), False)))
    found.sort(key=lambda item: (item[0], item[1]))
    return [mention for _, _, mention in found]
