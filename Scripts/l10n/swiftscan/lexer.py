"""A small Swift lexer that finds every string literal of a source file and the code around it.

It is not a parser. It knows what the scanner needs: comments (nested block comments
included), plain, multi-line, and raw string literals with their escapes and
interpolations (which may hold strings and closures of their own), extended regex
literals, and the brackets, so that each literal can say which call it is an argument of,
under which argument label and at which position, and inside which declarations.

Interpolations count as the two-byte placeholder ``%@``, as the catalog stores them.
"""

from __future__ import annotations

import bisect
import re
from dataclasses import dataclass
from typing import Dict, List, Optional, Set, Tuple

# The placeholder an interpolation leaves in a literal's text.
PLACEHOLDER = "%@"

# Words that start a declaration, for the declaration a literal sits in.
DECL_WORDS = ("func", "var", "let", "enum", "struct", "class", "extension", "case", "init",
              "subscript", "actor", "protocol")

# Everything the code lexer stops at: comments, the start of a string or an extended regex
# literal, a bracket, a colon (for argument labels), a comma, and the words that matter.
_TOKEN = re.compile(
    r'//|/\*|#+"|#/|"|[(\[{)\]}:,]|\b(?:' + "|".join(DECL_WORDS) + r"|static)\b"
)
# A declaration keyword and the name after it.
_DECL = re.compile(r"\b(" + "|".join(DECL_WORDS) + r")\b\s*([A-Za-z_][A-Za-z0-9_]*)?")
_IDENT_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
_JOINED = re.compile(r"\s*[?!]?\.joined\s*\(")
_WHITESPACE = " \t\r\n"
# Marks a backslash at the end of a multi-line literal's line until the lines are dedented.
_CONTINUATION = "\x01"
# The escapes of a plain string literal and what they stand for.
_ESCAPES = {"n": "\n", "t": "\t", "0": "", "r": "\r", '"': '"', "'": "'", "\\": "\\"}


@dataclass
class Literal:
    """One string literal: its text, where it is, and the code around it."""

    file: str                      # the path the lexer was given
    line: int                      # the line the literal starts on (1-based)
    end_line: int                  # the line it ends on
    start: int                     # offset of its first character (a quote or a hash)
    end: int                       # offset just past its last character
    text: str                      # its value, each interpolation as the placeholder
    has_interp: bool               # whether it holds an interpolation
    multiline: bool                # whether it is a triple-quoted literal
    in_interp: bool                # whether it sits inside another literal's interpolation
    call: Optional[str]            # the innermost call it is inside, such as Text
    receiver: Optional[str]        # what that call is called on, such as log in log.debug
    label: Optional[str]           # the argument label before it, if any
    arg_index: int                 # its position among that call's arguments (0-based)
    calls: List[Optional[str]]     # every call it is inside, innermost first
    decl: Optional[str]            # the declaration named earlier on its own line
    blocks: List[str]              # the declarations of the braces it is inside, outermost first
    raw_value: bool                # whether it is the raw value of an enum case
    whole_arg: bool                # whether it is a whole argument, not part of an expression
    static_let: int                # the line of the static let whose initializer it is in, else 0
    plus_before: Optional[str]     # "literal" or "expr": what a + before it joins to it
    plus_after: Optional[str]      # the same for a + after it
    glue: Optional[str]            # "joined" in an array that is joined, "plus" when a + glues it
    line_text: str                 # the text of its last line, for markers and plural checks
    start_line_text: str           # the text of its first line
    # What the classifier decides, filled in later.
    bucket: str = ""
    rule: str = ""
    status: str = ""
    wording: bool = False          # whether it sits in a Wording or Vocabulary type or file
    findings: Tuple[str, ...] = ()  # what the conversion must restructure, see classify.findings_of
    needs_comment: bool = False    # a SwiftUI literal the compiler extracts with no comment, see classify.needs_comment
    note_problem: str = ""         # what is wrong with the literal's translator's note, see classify.note_problem
    # The literal's pieces in order: each stretch of its own text (escapes resolved) as a str, each interpolation as None;
    # the interpolations' places as (offset of its backslash, offset just past its closing parenthesis). Together they let
    # a tool tell a `%@` the code wrote from the placeholder an interpolation leaves in `text`. Multi-line literals
    # dedent as a whole, so their pieces are not the text's; a tool that needs them refuses a multi-line literal.
    pieces: Tuple[Optional[str], ...] = ()
    interps: Tuple[Tuple[int, int], ...] = ()


class Lexer:
    """Lexes the string literals of one Swift file.

    Each open bracket is a frame on a stack: a ``(`` remembers its call name, receiver, the
    label of the argument being read, the argument's index, and the literals inside it; a
    ``{`` remembers the declaration it opens.
    """

    def __init__(self, text: str, file: str = "") -> None:
        self.s = text
        self.n = len(text)
        self.file = file
        self.out: List[Literal] = []
        # Offsets where each line starts, so that a line number is a bisect, not a count.
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", text)]
        # `static` seen and not yet followed by the declaration keyword it modifies.
        self._static_pending = False
        # The declaration whose initializer is being read: (depth, is a static let, its line), or None.
        self._decl: Optional[Tuple[int, bool, int]] = None
        self._stop_cache: Dict[Tuple[str, str, bool], "re.Pattern[str]"] = {}
        # The starts of the literals whose innermost bracket is a named call's parenthesis (not
        # a bare one such as `a + (b ? "x" : "y")`), which a ternary's branches must be in.
        self._directly_in_call: Set[int] = set()
        # The comments lexed so far, as {offset just past a comment: its first offset} (a line comment ends at its newline),
        # so that `_back` can step over one: a `// Translators:` line between `String(` and `localized:` must not hide the label.
        self._comment_starts: Dict[int, int] = {}

    # ------------------------------------------------------------------ helpers

    def run(self) -> List[Literal]:
        """Lexes the whole file and returns its literals in order."""
        self._lex_code(0, None, [], False)
        self._resolve_plus_neighbours()
        self._resolve_ternary_branches()
        return self.out

    def _line_of(self, pos: int) -> int:
        """The 1-based line number of an offset."""
        return bisect.bisect_right(self.line_starts, pos)

    def _line_text(self, line: int) -> str:
        """The text of a 1-based line, without its newline."""
        start = self.line_starts[line - 1]
        end = self.line_starts[line] - 1 if line < len(self.line_starts) else self.n
        return self.s[start:end]

    def _back(self, j: int, chars: str = _WHITESPACE) -> int:
        """Moves the offset j back over any of the characters, so that the character before
        the result is the first one that is not among them."""
        s = self.s
        while True:
            while j > 0 and s[j - 1] in chars:
                j -= 1
            # Whitespace is skipped through the comments in it; the characters of an identifier are not.
            if chars is _WHITESPACE and j in self._comment_starts:
                j = self._comment_starts[j]
            else:
                return j

    def _forward(self, j: int, chars: str = _WHITESPACE) -> int:
        """Moves the offset j forward over any of the characters, to the first one that is not."""
        s, n = self.s, self.n
        while j < n and s[j] in chars:
            j += 1
        return j

    def _ident_before(self, i: int) -> Optional[str]:
        """The identifier that ends just before offset i, ignoring spaces in between."""
        end = self._back(i)
        name = self.s[self._back(end, _IDENT_CHARS):end]
        return name if name and not name[0].isdigit() else None

    def _is_label_colon(self, i: int) -> bool:
        """Whether the colon at i follows an argument label: an identifier that starts its
        argument, right after ``(``, ``[``, or ``,``. The colon of a ternary follows something
        else (``cond ? a : "x"``: ``a`` follows a ``?``), so it labels nothing."""
        start = self._back(self._back(i), _IDENT_CHARS)
        before = self._back(start)
        return start < self._back(i) and before > 0 and self.s[before - 1] in "([,"

    def _call_before(self, i: int) -> Tuple[Optional[str], Optional[str]]:
        """The name of the call whose ``(`` is at i and the receiver before its dot, if any."""
        s = self.s
        j = self._back(i)
        if j > 0 and s[j - 1] == ">":
            # A generic argument list, as in Array<String>(: skip back over it.
            k = s.rfind("<", max(0, j - 80), j)
            if k < 0 or "(" in s[k:j] or ")" in s[k:j]:
                return None, None
            j = self._back(k)
        start = self._back(j, _IDENT_CHARS)
        name = s[start:j]
        if not name or name[0].isdigit():
            return None, None
        # The receiver: the identifier before a dot that precedes the name.
        k = self._back(start)
        receiver = None
        if k > 0 and s[k - 1] == ".":
            r_end = self._back(k - 1, _WHITESPACE + "?!")
            receiver = s[self._back(r_end, _IDENT_CHARS):r_end] or None
        return name, receiver

    def _decl_on_line(self, i: int) -> Optional[str]:
        """The last declaration keyword's name on i's line before i, for a brace with no keyword."""
        start = self.s.rfind("\n", 0, i) + 1
        found = None
        for m in _DECL.finditer(self.s, start, i):
            found = m.group(2) or m.group(1)
        return found

    # ------------------------------------------------------------------ code

    def _lex_code(self, i: int, stop: Optional[str], stack: List[dict], in_interp: bool) -> int:
        """Lexes code from offset i. With stop ``)``, returns just past the ``)`` that closes
        the interpolation being read; otherwise it runs to the end of the text."""
        s, n = self.s, self.n
        depth_at_entry = len(stack)
        pending_decl: Optional[str] = None
        search = _TOKEN.search
        while True:
            m = search(s, i)
            if m is None:
                return n
            tok = m.group()
            i = m.start()
            if tok == "//":
                j = s.find("\n", i)
                self._comment_starts[n if j < 0 else j] = i
                i = n if j < 0 else j
            elif tok == "/*":
                started = i
                i = self._skip_block_comment(i)
                self._comment_starts[i] = started
            elif tok == "#/":
                # An extended regex literal: skip to its closing /#.
                j = s.find("/#", i + 2)
                i = n if j < 0 else j + 2
            elif tok[-1] == '"':
                i = self._lex_string(i, stack, in_interp)
            elif tok == "(" or tok == "[":
                name, receiver = self._call_before(i) if tok == "(" else (None, None)
                stack.append({"ch": tok, "name": name, "receiver": receiver, "label": None,
                              "arg": 0, "lits": []})
                i += 1
            elif tok == "{":
                stack.append({"ch": "{", "decl": pending_decl or self._decl_on_line(i)})
                pending_decl = None
                i += 1
            elif tok in (")", "]", "}"):
                if stop == ")" and tok == ")" and len(stack) == depth_at_entry:
                    return i + 1
                if stack:
                    self._close_frame(stack.pop(), i + 1)
                    if self._decl is not None and len(stack) < self._decl[0]:
                        self._decl = None
                i += 1
            elif tok == ":":
                if stack and stack[-1]["ch"] in "([" and self._is_label_colon(i):
                    stack[-1]["label"] = self._ident_before(i)
                i += 1
            elif tok == ",":
                if stack and stack[-1]["ch"] in "([":
                    stack[-1]["label"] = None
                    stack[-1]["arg"] += 1
                i += 1
            elif tok == "static":
                self._static_pending = True
                i = m.end()
            else:
                # A declaration keyword: remember its name for the braces after it, and keep
                # track of the let or var whose initializer the next literals belong to.
                dm = _DECL.match(s, i)
                pending_decl = (dm.group(2) if dm and dm.group(2) else tok)
                depth = len(stack)
                if tok in ("let", "var"):
                    if self._decl is None or depth <= self._decl[0]:
                        self._decl = (depth, self._static_pending and tok == "let", self._line_of(i))
                elif self._decl is not None and depth <= self._decl[0]:
                    self._decl = None
                self._static_pending = False
                i = m.end()

    def _close_frame(self, frame: dict, after: int) -> None:
        """Handles a closed bracket: an array followed by .joined( makes its literals glued."""
        if frame["ch"] == "[" and frame["lits"] and _JOINED.match(self.s, after):
            for lit in frame["lits"]:
                lit.glue = "joined"

    def _skip_block_comment(self, i: int) -> int:
        """Returns the offset past the block comment at i, which may hold nested ones."""
        s, n = self.s, self.n
        depth = 0
        while i < n:
            if s.startswith("/*", i):
                depth += 1
                i += 2
            elif s.startswith("*/", i):
                depth -= 1
                i += 2
                if depth == 0:
                    return i
            else:
                i += 1
        return n

    # ------------------------------------------------------------------ strings

    def _stop_pattern(self, close: str, escape: str, multiline: bool) -> "re.Pattern[str]":
        """The pattern for the next thing that matters inside a literal: its end, an escape,
        and, in a single-line literal, a newline."""
        key = (close, escape, multiline)
        pattern = self._stop_cache.get(key)
        if pattern is None:
            parts = [re.escape(close), re.escape(escape)] + ([] if multiline else ["\n"])
            pattern = self._stop_cache[key] = re.compile("|".join(parts))
        return pattern

    def _lex_string(self, i: int, stack: List[dict], in_interp: bool) -> int:
        """Lexes the literal that starts at i (at a hash or a quote), records it, and returns
        the offset just past it."""
        s, n = self.s, self.n
        start = i
        hashes = 0
        while s[i] == "#":
            hashes += 1
            i += 1
        multiline = s.startswith('"""', i)
        i += 3 if multiline else 1
        close = ('"""' if multiline else '"') + "#" * hashes
        escape = "\\" + "#" * hashes
        stop = self._stop_pattern(close, escape, multiline)
        pieces: List[str] = []
        # Which entries of `pieces` are interpolations, and where each one lies, for `Literal.pieces` and `Literal.interps`.
        holes: Set[int] = set()
        spans: List[Tuple[int, int]] = []
        has_interp = False
        while i < n:
            m = stop.search(s, i)
            if m is None:
                pieces.append(s[i:])
                i = n
                break
            pieces.append(s[i:m.start()])
            i = m.start()
            tok = m.group()
            if tok == close:
                i += len(close)
                break
            if tok == "\n":
                break  # an unterminated single-line literal ends at its line's end
            k = i + len(escape)
            if k >= n:
                i = n
                break
            if s[k] == "(":
                # An interpolation: lex its code, which may hold strings of its own.
                has_interp = True
                holes.add(len(pieces))
                pieces.append(PLACEHOLDER)
                # The frame of its own keeps a colon or comma inside it from changing the label or
                # the argument index of the call the literal is an argument of.
                hole_start = i
                i = self._lex_code(k + 1, ")", list(stack) + [{"ch": "i"}], True)
                spans.append((hole_start, i))
            elif s[k] == "u" and k + 1 < n and s[k + 1] == "{" and s.find("}", k) > 0:
                end = s.find("}", k)
                try:
                    pieces.append(chr(int(s[k + 2:end], 16)))
                except ValueError:
                    pass
                i = end + 1
            elif s[k] == "\n":
                # \<newline> continues a multi-line literal's line: leave a mark, and let the
                # newline be read as text, so the indentation of the next line is stripped
                # with the others before the mark and the newline are removed.
                pieces.append(_CONTINUATION)
                i = k
            else:
                pieces.append(_ESCAPES.get(s[k], s[k]))
                i = k + 1
        text = "".join(pieces)
        if multiline:
            text = dedent_multiline(text).replace(_CONTINUATION + "\n", "")
        self._record(start, i, text, has_interp, multiline, stack, in_interp)
        # The literal just recorded is the last of the list (an interpolation's own literals were recorded before it).
        recorded = self.out[-1]
        recorded.pieces = tuple(None if index in holes else piece for index, piece in enumerate(pieces))
        recorded.interps = tuple(spans)
        return i

    def _record(self, start: int, end: int, text: str, has_interp: bool, multiline: bool,
                stack: List[dict], in_interp: bool) -> None:
        """Builds the Literal for the text lexed between start and end, from the open brackets."""
        s = self.s
        call = receiver = label = None
        arg_index = 0
        calls: List[Optional[str]] = []
        for frame in reversed(stack):
            if frame["ch"] == "(":
                # The call is the innermost parenthesis that follows a name: a bare
                # parenthesis, as in `a + (b ? "x" : "y")`, belongs to the call around it, and
                # its colon (the ternary's) is no argument label.
                if call is None and frame["name"] is not None:
                    call, receiver, label, arg_index = frame["name"], frame["receiver"], frame["label"], frame["arg"]
                calls.append(frame["name"])
        blocks = [f["decl"] for f in stack if f["ch"] == "{" and f.get("decl")]
        if stack and stack[-1]["ch"] == "(" and stack[-1]["name"] is not None:
            self._directly_in_call.add(start)
        line = self._line_of(start)
        end_line = self._line_of(max(start, end - 1))
        line_start = self.line_starts[line - 1]
        before = s[line_start:start]
        raw_value = bool(re.search(r"^\s*case\s+[A-Za-z_][A-Za-z0-9_]*\s*=\s*$", before))
        decl = None
        for dm in _DECL.finditer(before):
            decl = dm.group(2) or dm.group(1)
        lit = Literal(
            file=self.file, line=line, end_line=end_line, start=start, end=end, text=text,
            has_interp=has_interp, multiline=multiline, in_interp=in_interp, call=call,
            receiver=receiver, label=label, arg_index=arg_index, calls=calls, decl=decl,
            blocks=blocks, raw_value=raw_value, whole_arg=self._whole_argument(start, end),
            static_let=self._decl[2] if self._decl and self._decl[1] else 0, plus_before=self._plus_side(start, True),
            plus_after=self._plus_side(end, False), glue=None,
            line_text=self._line_text(end_line), start_line_text=self._line_text(line))
        self.out.append(lit)
        if stack and "lits" in stack[-1]:
            stack[-1]["lits"].append(lit)

    def _whole_argument(self, start: int, end: int) -> bool:
        """Whether the literal is a whole argument: after ``(``, ``[``, ``,``, or a label, and
        before ``,``, ``)``, or ``]``, and so not a piece of a larger expression."""
        s = self.s
        before = self._back(start)
        if before > 0 and s[before - 1] == ":":
            # Skip a label: an identifier and the colon after it.
            before = self._back(before - 1)
            label_start = self._back(before, _IDENT_CHARS)
            if label_start == before:
                return False
            before = self._back(label_start)
        return before > 0 and s[before - 1] in "([," and self._ends_argument(end)

    def _ends_argument(self, end: int) -> bool:
        """Whether the next thing after offset end is a ``,``, ``)``, or ``]``."""
        after = self._forward(end)
        return after < self.n and self.s[after] in ",)]"

    def _resolve_ternary_branches(self) -> None:
        """Marks the literals of ``cond ? "a" : "b"`` as whole arguments when both branches are
        literals and the ternary ends the argument. The compiler reads such a ternary in a
        key position as a LocalizedStringKey and extracts both branches; with a variable as
        the other branch it picks the String overload and extracts neither.

        The ternary has the lowest precedence of the operators, so whatever stands before the
        ``?`` in the argument is its condition and the first literal needs no other check.
        """
        s = self.s
        by_start = {lit.start: lit for lit in self.out}
        for first in self.out:
            before = self._back(first.start)
            # A `?` right before the literal, but not the `??` of a default value.
            if before < 1 or s[before - 1] != "?" or (before >= 2 and s[before - 2] == "?") \
                    or first.start not in self._directly_in_call:
                continue
            colon = self._forward(first.end)
            if colon >= self.n or s[colon] != ":":
                continue
            second = by_start.get(self._forward(colon + 1))
            if second is not None and self._ends_argument(second.end):
                first.whole_arg = second.whole_arg = True

    def _plus_side(self, pos: int, before: bool) -> Optional[str]:
        """What a ``+`` right before (before=True) or after (before=False) the literal joins
        to it: "literal" when the other operand starts with a string, "expr" for any other
        operand, and None when there is no plus."""
        s, n = self.s, self.n
        if before:
            b = self._back(pos)  # the character before b is the last one before the literal
            if b >= 2 and s[b - 1] == "=" and s[b - 2] == "+":
                return "expr"  # `text += "..."` appends to a variable
            if b < 1 or s[b - 1] != "+" or (b >= 2 and s[b - 2] == "+"):
                return None
            b = self._back(b - 1)
            return "literal" if b > 0 and s[b - 1] in '"#' else "expr"
        j = self._forward(pos)
        if j >= n or s[j] != "+" or s.startswith(("++", "+="), j):
            return None
        j = self._forward(j + 1)
        return "literal" if j < n and s[j] in '"#' else "expr"

    def _resolve_plus_neighbours(self) -> None:
        """Sorts the literals into source order and marks those that a + glues to something
        other than a plain literal.

        A + between two literals that hold no interpolation only wraps one long line, so it is
        not gluing; any other + (to a variable, a call, or a literal with an interpolation)
        builds a sentence from pieces.
        """
        self.out.sort(key=lambda lit: lit.start)
        by_start = {lit.start: lit for lit in self.out}
        by_end = {lit.end: lit for lit in self.out}
        for lit in self.out:
            if lit.glue is None and self._glued_by_plus(lit, by_start, by_end):
                lit.glue = "plus"

    def _glued_by_plus(self, lit: Literal, by_start: Dict[int, Literal],
                       by_end: Dict[int, Literal]) -> bool:
        """Whether a + next to the literal glues it to an expression or an interpolating literal."""
        for side, before in ((lit.plus_before, True), (lit.plus_after, False)):
            if side is None:
                continue
            if side == "expr" or lit.has_interp:
                return True
            other = self._neighbour(lit, by_start, by_end, before)
            if other is None or other.has_interp:
                return True
        return False

    def _neighbour(self, lit: Literal, by_start: Dict[int, Literal], by_end: Dict[int, Literal],
                   before: bool) -> Optional[Literal]:
        """The literal on the other side of the + next to lit, or None when there is none."""
        if before:
            # Back over the spaces, the plus, and the spaces before it: the neighbour ends there.
            return by_end.get(self._back(self._back(lit.start) - 1))
        # Forward over the spaces, the plus, and the spaces after it: the neighbour starts there.
        return by_start.get(self._forward(self._forward(lit.end) + 1))


def dedent_multiline(text: str) -> str:
    """Strips a multi-line literal's indentation (that of its closing line) and its first and
    last newline, as Swift does."""
    lines = text.split("\n")
    if len(lines) < 2:
        return text
    indent = len(lines[-1]) - len(lines[-1].lstrip())
    body = lines[1:-1]
    return "\n".join(line[indent:] if line[:indent].strip() == "" else line for line in body)


def lex(text: str, file: str = "") -> List[Literal]:
    """Every string literal of a Swift source text, in order."""
    return Lexer(text, file).run()
