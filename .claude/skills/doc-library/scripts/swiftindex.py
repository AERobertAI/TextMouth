"""An index of the Swift declarations in the repository, and the names a section's prose mentions.

``SwiftIndex.load`` scans every Swift file once, with one regular expression, and
remembers each ``class``, ``struct``, ``enum``, ``protocol``, ``actor``, ``typealias``,
``func`` and ``extension`` it finds, by name. It only answers whether a name exists
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

# Where vendored code lives; its Swift (there is none today) is not TextMouth's own.
VENDOR_FOLDER = "Vendor/"

# What follows a declaring keyword: white space and then (in a look-ahead, so that
# ``class func foo`` still finds ``func foo``) the name, dotted for ``extension Book.Storage``.
_AFTER_KEYWORD = rb"\s+(?=([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*))"
# One expression for each declaring keyword, all of the one shape ``KEYWORD\s+NAME``. One
# alternation over all of them reads 30 MB in 0.3 s; each starting on a literal word lets
# the matcher skip ahead, which halves that. The word boundary before the keyword is
# checked by ``_scan``, since a pattern starting on ``\b`` has no literal to skip by.
_DECLARATIONS = tuple(
    (keyword, re.compile(keyword.encode("ascii") + _AFTER_KEYWORD))
    for keyword in ("class", "struct", "enum", "protocol", "actor", "typealias", "func", "extension")
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

# A word shaped like a Swift type: capital first, a lowercase letter, and a second capital.
_WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass(frozen=True)
class Declaration:
    """One declaration: its name, kind, file, line, and the declaration's line as written."""

    name: str
    kind: str          # one of TYPE_KINDS, "func", or "extension"
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
        them; a symbolic link is never followed, so nothing outside the repository is read.
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
        full = os.path.join(repo.root, relative)
        try:
            if os.path.islink(full):
                return
            with open(full, "rb") as handle:
                data = handle.read()
        except OSError:
            return
        # Every match of every keyword that starts a word, in the order written.
        found = []
        for keyword, pattern in _DECLARATIONS:
            for match in pattern.finditer(data):
                start = match.start()
                if start == 0 or data[start - 1] not in _WORD_BYTES:
                    found.append((start, keyword, match.group(1)))
        found.sort()
        line = 1
        last = 0
        for position, keyword, raw in found:
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
        rank = {KIND_EXTENSION: 1, KIND_FUNC: 2}
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
            found = self._first_per_file(key, (lambda d: d.kind == KIND_FUNC) if call
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
