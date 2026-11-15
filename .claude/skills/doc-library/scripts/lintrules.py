"""The lint: the rules of ``docs/agents/writing-docs.md`` as functions over the docs.

``lint(root)`` reads the pages the lint covers (``docmodel.lint_pages``) once, builds
a ``LintContext`` holding what every rule needs, runs each rule of ``RULES`` and
returns the ``Violation`` s, in rule order, then page order, then line order.

A rule is a function from the context to its violations. To add one (``stale`` is the
next), write the function and add one ``(name, function)`` line to ``RULES``.

Page kinds:

* the *lint pages*: the ``docs`` scope plus ``AGENTS.md`` and ``CLAUDE.md``;
* the *log pages* (``docmodel.LOG_PAGES``), where dated history is allowed;
* the *index pages* (``docmodel.INDEX_PAGES``), whose list items are links;
* the *reference pages*: those under ``docs/user``, ``docs/developer``,
  ``docs/architecture`` and ``docs/agents``, less the log pages.

*Prose* is every block but code, front matter, markers, rules, and HTML comments, and
within a block everything but inline code spans, link destinations, and URLs.

The rules read only the files the model hands them, all inside the root; whether a
path in a link or a marker exists is answered by ``RepoFiles``, from git's list of
files, and never by asking the file system about the path written in a page.
"""

from __future__ import annotations

import posixpath
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, Iterator, List, NamedTuple, Optional, Sequence, Tuple
from urllib.parse import unquote

import cmd_stale
import docmodel
import output
import swiftindex
import targets
from citations import KIND_SRC
from docmodel import Block, Page
from reflowblocks import PROSE_KINDS, reflow_pieces
from repofiles import RepoFiles
# The one finder of a link's ``](destination)`` spans, which the sentence splitter
# also protects; the lint reads the destination out of each span.
from sentences import code_spans, link_destinations, protected_spans, split_sentences

# ---------------------------------------------------------------------------
# The limits of docs/agents/writing-docs.md: one constant each.
# ---------------------------------------------------------------------------

LINE_LIMIT = 300            # characters in a line
SECTION_LIMIT = 40          # lines in a section, its heading to its last line
PAGE_LIMIT = 40_000         # bytes in a page; a kB is 1,000 bytes, as the Finder counts
PAGE_LIMITS = {"AGENTS.md": 12_000, "CLAUDE.md": 3_000}   # the pages with limits of their own
KEYS_LIMIT = 8              # search words in one marker
INDEX_LINE_WORDS = 12       # words in an index line's visible text
QUOTE_WORDS = 6             # words from which a double-quoted span is a quotation

# The skill's folder (the scripts' parent) and the file of words that sell.
SKILL_DIR = Path(__file__).resolve().parent.parent
SALES_WORDS_FILE = SKILL_DIR / "sales-words.txt"

# The folders of the reference pages.
REFERENCE_FOLDERS = ("docs/user/", "docs/developer/", "docs/architecture/", "docs/agents/")
# Where the docs live: the pages the index pages must link to.
DOCS_FOLDER = "docs/"

# ---------------------------------------------------------------------------
# What a rule reports and what it is given.
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Violation:
    """One place a page breaks a rule.

    ``start`` and ``end`` are the 1-based lines it covers; ``heading`` is the printed
    heading path of the section it is in; ``detail`` says what is wrong in a few
    words, with the numbers.
    """

    page: str
    rule: str
    start: int
    end: int
    heading: str
    detail: str


class ProseBlock(NamedTuple):
    """One prose block of a page.

    ``text`` is the block's raw lines joined with newlines; ``plain`` is the same
    text with every inline code span, link destination, and URL blanked to spaces
    (newlines kept), so ``plain`` has the length and line breaks of ``text``.
    """

    kind: str
    start: int
    text: str
    plain: str


class Link(NamedTuple):
    """A link, image, or reference definition in prose: its line and destination."""

    line: int
    dest: str


# The block kinds that are not prose.
NON_PROSE = frozenset({"code", "front-matter", "marker", "rule", "html"})
# The block kinds whose lines hold running sentences.
SENTENCE_KINDS = frozenset({"paragraph", "list-item", "list-para", "quote"})


def is_log(path: str) -> bool:
    """Whether ``path`` is a log page, where dates are allowed (``docmodel.is_log_page``)."""
    return docmodel.is_log_page(path)


def is_reference(path: str) -> bool:
    """Whether ``path`` is a reference page: under the reference folders, and no log."""
    return path.startswith(REFERENCE_FOLDERS) and not is_log(path)


def blank_spans(text: str, spans: Iterable[Tuple[int, int]]) -> str:
    """``text`` with the characters of each ``[start, end)`` span made spaces, newlines kept."""
    chars = list(text)
    for start, end in spans:
        for index in range(start, end):
            if chars[index] != "\n":
                chars[index] = " "
    return "".join(chars)


def load_sales_words(path: Path = SALES_WORDS_FILE) -> List[str]:
    """The words and phrases of ``sales-words.txt``: one for each line, ``#`` lines skipped."""
    words = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            words.append(line)
    return words


def sales_pattern(words: Sequence[str]) -> Optional["re.Pattern[str]"]:
    """One case-insensitive pattern for all of ``words`` at word boundaries (None for no words).

    A space inside a phrase matches any run of white space.
    """
    if not words:
        return None
    alternatives = [r"\s+".join(re.escape(part) for part in word.split()) for word in words]
    # Longest first, so "blazingly" is not reported as "blazing".
    alternatives.sort(key=len, reverse=True)
    return re.compile(r"\b(?:" + "|".join(alternatives) + r")\b", re.IGNORECASE)


# The characters that ``re.IGNORECASE`` takes for an ASCII letter but ``str.lower`` leaves alone.
# (long s, dotless i, dotted capital I, the Kelvin sign.)
_FOLDS_TO_ASCII = str.maketrans({"\u017f": "s", "\u0131": "i", "\u0130": "i", "\u212a": "k"})


def folded(text: str) -> str:
    """``text`` lowered so that every match of an ASCII word under ``re.IGNORECASE`` shows in it.

    A test on the result may let a block through that has no match (it only gates the
    exact search), but never turns away one that has.
    """
    return text.lower() if text.isascii() else text.translate(_FOLDS_TO_ASCII).lower()


def sales_prefilter(words: Sequence[str]) -> Tuple[str, ...]:
    """The lowercase first word of each entry of ``words``: a text with none of them has no sales word.

    Test ``folded`` text with ``holds_any``; the substring searches run in C and are
    much quicker than the pattern, which tries every alternative at every position.
    """
    return tuple(sorted({word.split()[0].lower() for word in words}))


def holds_any(text: str, needles: Iterable[str]) -> bool:
    """True when ``text`` holds at least one of ``needles`` as a substring."""
    return any(needle in text for needle in needles)


@dataclass
class LintContext:
    """What every rule needs, built once for a run.

    ``paths`` and ``pages`` are the lint pages and their parsed forms, in the same
    order; ``repo`` the repository's files; ``sales`` the pattern of the sales words.
    The rest are caches filled as rules ask.
    """

    root: Path
    paths: List[str]
    pages: List[Page]
    repo: RepoFiles
    sales: Optional["re.Pattern[str]"]
    sales_quick: Tuple[str, ...] = ()
    _by_path: Dict[str, Page] = field(default_factory=dict)
    _prose: Dict[str, List[ProseBlock]] = field(default_factory=dict)
    _links: Dict[str, List[Link]] = field(default_factory=dict)
    _slugs: Dict[str, frozenset] = field(default_factory=dict)
    _others: Dict[str, Optional[Page]] = field(default_factory=dict)

    @classmethod
    def build(cls, root: Path) -> "LintContext":
        """Read the lint pages and the repository's file list, once."""
        paths = docmodel.lint_pages(root)
        pages = docmodel.load_pages(root, paths)
        words = load_sales_words()
        context = cls(root=root, paths=paths, pages=pages, repo=RepoFiles.load(root),
                      sales=sales_pattern(words), sales_quick=sales_prefilter(words))
        context._by_path = {page.path: page for page in pages}
        return context

    def order(self) -> Dict[str, int]:
        """Each lint page's place in the run's page order."""
        return {path: index for index, path in enumerate(self.paths)}

    def selected(self, logs: bool = True) -> Iterator[Page]:
        """The lint pages in order; the log pages too when ``logs`` is true."""
        for page in self.pages:
            if logs or not is_log(page.path):
                yield page

    def prose(self, page: Page) -> List[ProseBlock]:
        """The page's prose blocks (cached), each with its protected spans blanked."""
        if page.path not in self._prose:
            blocks = []
            for block in page.blocks:
                if block.kind in NON_PROSE:
                    continue
                text = page.text(block.start, block.end)
                blocks.append(ProseBlock(block.kind, block.start, text,
                                         blank_spans(text, protected_spans(text))))
            self._prose[page.path] = blocks
        return self._prose[page.path]

    def slugs(self, page: Page) -> frozenset:
        """The anchors of the page's headings (cached)."""
        if page.path not in self._slugs:
            self._slugs[page.path] = frozenset(targets.page_slugs(page))
        return self._slugs[page.path]

    def page_at(self, path: str) -> Optional[Page]:
        """The parsed Markdown page at repository path ``path``, or None when it cannot be read.

        A lint page comes from the run's own list; any other page of the repository
        is read once, through the model, which refuses a path that leaves the root.
        """
        if path in self._by_path:
            return self._by_path[path]
        if path not in self._others:
            try:
                self._others[path] = docmodel.load_page(self.root, path) if self.repo.is_file(path) else None
            except output.UsageError:
                self._others[path] = None
        return self._others[path]

    def links(self, page: Page) -> List[Link]:
        """The links and images of the page's prose, and its reference definitions (cached)."""
        if page.path not in self._links:
            found: List[Link] = []
            for block in self.prose(page):
                found += block_links(block)
            self._links[page.path] = found
        return self._links[page.path]


def heading_at(page: Page, line: int) -> str:
    """The printed heading path of the section holding ``line`` ("" for a page with no sections)."""
    try:
        return page.section_at(line).heading
    except LookupError:
        return ""


def violation(page: Page, rule: str, start: int, end: int, detail: str) -> Violation:
    """A violation of ``rule`` on lines ``start..end`` of ``page``, with its section's heading."""
    return Violation(page.path, rule, start, end, heading_at(page, start), detail)


# ---------------------------------------------------------------------------
# Layout rules: lines, sections, pages.
# ---------------------------------------------------------------------------


def unchecked_lines(page: Page) -> set:
    """The lines of code blocks, front matter, and markers, where a long line is allowed."""
    lines = set()
    for block in page.blocks:
        if block.kind in ("code", "front-matter", "marker"):
            lines.update(range(block.start, block.end + 1))
    return lines


def physical_long_lines(page: Page, first: int, last: int, skipped: set) -> List[Violation]:
    """The lines ``first..last`` of ``page`` over ``LINE_LIMIT`` characters, bar the ``skipped`` ones."""
    return [violation(page, "line-length", number, number,
                      f"{len(page.lines[number - 1]):,} characters, limit {LINE_LIMIT}")
            for number in range(first, last + 1)
            if len(page.lines[number - 1]) > LINE_LIMIT and number not in skipped]


def prose_long_lines(page: Page, block: Block) -> List[Violation]:
    """The ``line-length`` violations of one paragraph, list item, or list paragraph.

    The block counts the larger of two numbers: its lines over the limit as written,
    and its lines over the limit as ``reflow`` would write them (``reflowblocks``,
    the code ``reflow`` runs, with the indentation it gives each sentence). So a
    page ``reflow`` has already done counts exactly as before, and ``reflow`` can
    only lower a count: a line of several long sentences counts once for each.
    When the reflowed count is the larger, each violation is at the line where its
    sentence starts, and says how many sentences start on that line.
    """
    old = page.lines[block.start - 1:block.end]
    written = physical_long_lines(page, block.start, block.end, set())
    pieces = reflow_pieces(block, old)
    # A block that reflow leaves alone (a hard line break, say) has only its own lines.
    if pieces is None:
        return written
    long_pieces = [(source, text) for source, text in pieces if len(text) > LINE_LIMIT]
    if len(long_pieces) <= len(written):
        return written
    # The sentences starting on each old line, to say which long ones share their line.
    starts_on = Counter(source for source, _ in pieces)
    found = []
    for source, text in long_pieces:
        sentences = starts_on[source]
        shared = f" on a line of {sentences} sentences" if sentences > 1 else ""
        number = block.start + source
        found.append(violation(page, "line-length", number, number,
                               f"sentence of {len(text):,} characters{shared}, limit {LINE_LIMIT}"))
    return found


def line_length_violations(page: Page) -> List[Violation]:
    """Every ``line-length`` violation of ``page``, in line order.

    Prose blocks (``reflowblocks.PROSE_KINDS``) follow ``prose_long_lines``. Every
    other line, headings, quotes, tables, and HTML comments among them, counts when
    it is over the limit as written; code, front matter, and markers are exempt.
    """
    skipped = unchecked_lines(page)
    found: List[Violation] = []
    prose_lines: set = set()
    for block in page.blocks:
        if block.kind in PROSE_KINDS:
            prose_lines.update(range(block.start, block.end + 1))
            found += prose_long_lines(page, block)
    # The lines outside the prose blocks, as written.
    found += physical_long_lines(page, 1, len(page.lines), skipped | prose_lines)
    return sorted(found, key=lambda v: (v.start, v.end))


def rule_line_length(context: LintContext) -> Iterator[Violation]:
    """``line-length``: lines over ``LINE_LIMIT`` characters, outside code, front matter, and markers.

    A prose block counts the larger of its long lines as written and as ``reflow`` would
    write them (see ``prose_long_lines``), so ``reflow`` never raises the count.
    """
    for page in context.selected():
        yield from line_length_violations(page)


def rule_section_length(context: LintContext) -> Iterator[Violation]:
    """``section-length``: sections over ``SECTION_LIMIT`` lines, on pages but logs."""
    for page in context.selected(logs=False):
        for section in page.sections:
            lines = section.end - section.start + 1
            if lines > SECTION_LIMIT:
                yield Violation(page.path, "section-length", section.start, section.end,
                                section.heading, f"{lines} lines, limit {SECTION_LIMIT}")


def rule_page_size(context: LintContext) -> Iterator[Violation]:
    """``page-size``: one violation for a page whose bytes pass its limit, on pages but logs."""
    for page in context.selected(logs=False):
        limit = PAGE_LIMITS.get(page.path, PAGE_LIMIT)
        if page.size > limit:
            yield Violation(page.path, "page-size", 1, 1, "", f"{page.size:,} bytes, limit {limit:,}")


# ---------------------------------------------------------------------------
# Prose rules: dates, quotes, sales words, emoji.
# ---------------------------------------------------------------------------

# Month names, capitalized: whole names first, so "March" is not read as "Mar".
_MONTH = (r"(?:January|February|March|April|May|June|July|August|September|October|November|December"
          r"|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sept|Sep|Oct|Nov|Dec)")
_DAY = r"(?:[12]\d|3[01]|0?[1-9])(?:st|nd|rd|th)?"
_YEAR = r"(?:19|20)\d{2}"
# ``October 12``, ``Oct. 12, 2026``, ``October 2026``.
_MONTH_FIRST = rf"\b{_MONTH}\b\.?[ \t]+(?:{_DAY}\b(?:,?[ \t]+{_YEAR}\b)?|{_YEAR}\b)"
# ``12 October``, ``12 October 2026``.
_DAY_FIRST = rf"\b{_DAY}[ \t]+{_MONTH}\b(?:\.?[ \t]+{_YEAR}\b)?"
_NAMED_DATE = re.compile(f"{_MONTH_FIRST}|{_DAY_FIRST}")
# What every ISO date holds, and every month-name date: a hyphen, month digits, a hyphen, and
# day digits; or the first three letters of a month name (``Sept`` and the long names start
# with them), whose capital lets the matcher skip along. Each is a looser pattern than the
# date's own (``might_hold_date``), found cheaply, so that the dates' own patterns, which
# are slow, run on the few blocks that might hold a date.
_ISO_QUICK = re.compile(r"-[01]\d-[0-3]\d")
_MONTH_QUICK = re.compile(r"Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec")
# ``2026-10-12`` with a real month and day, not part of a longer word or number.
_ISO_DATE = re.compile(r"(?<!\w)(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])(?!\w)")
# The characters beside a date that make it part of a name: ``TODO-2026-09-04.md``.
_NAME_BEFORE = "-_/."
_NAME_AFTER = "-_/"


def in_a_path_name(line: str, start: int, end: int) -> bool:
    """Whether the date at ``line[start:end]`` is part of a path-like token.

    That is so when the white-space-delimited token around it holds a ``/``, or the
    date is joined to its neighbours by ``-``, ``_``, ``/``, or ``.`` (a file's
    extension), as in ``TODO-2026-09-04.md`` or ``briefs/2026-11-14/``.
    """
    token_start = start
    while token_start > 0 and not line[token_start - 1].isspace():
        token_start -= 1
    token_end = end
    while token_end < len(line) and not line[token_end].isspace():
        token_end += 1
    if "/" in line[token_start:token_end]:
        return True
    if start > 0 and line[start - 1] in _NAME_BEFORE:
        return True
    after = line[end:end + 2]
    return bool(after) and (after[0] in _NAME_AFTER or (after[0] == "." and after[1:].isalnum()))


def prose_lines(context: LintContext, page: Page,
                might_match: Optional[Callable[[str], bool]] = None) -> Iterator[Tuple[int, str]]:
    """Each line of the page's prose as ``(line number, plain text)``.

    A rule that looks for something rare passes ``might_match``, a quick test on a
    block's whole plain text that is false only when no line of the block can hold what
    the rule seeks; the lines of such a block are not split out. This is what makes a
    rule cost one search for a block, not one for each of its lines.
    """
    for block in context.prose(page):
        if might_match is not None and not might_match(block.plain):
            continue
        for offset, text in enumerate(block.plain.split("\n")):
            yield block.start + offset, text


def might_hold_date(plain: str) -> bool:
    """False only when ``plain`` holds no date that ``rule_date`` reports."""
    return bool(_ISO_QUICK.search(plain) or _MONTH_QUICK.search(plain))


def rule_date(context: LintContext) -> Iterator[Violation]:
    """``date``: ISO and month-name dates in prose, on pages but logs."""
    for page in context.selected(logs=False):
        for number, text in prose_lines(context, page, might_hold_date):
            for match in _ISO_DATE.finditer(text):
                if not in_a_path_name(text, match.start(), match.end()):
                    yield violation(page, "date", number, number, f"date {match.group()}")
            for match in _NAMED_DATE.finditer(text):
                yield violation(page, "date", number, number, f"date {match.group()}")


# A double-quoted span, straight or curly, within one line.
_QUOTED = re.compile(r'"([^"\n]*)"|“([^”\n]*)”')
_USER_WORD = re.compile(r"\buser\b", re.IGNORECASE)


def word_count(text: str) -> int:
    """The words of ``text``: its white-space-separated pieces that hold a letter or digit."""
    return sum(1 for piece in text.split() if any(char.isalnum() for char in piece))


def rule_user_quote(context: LintContext) -> Iterator[Violation]:
    """``user-quote``: long double-quoted spans on a line that mentions the user, on pages but logs."""
    for page in context.selected(logs=False):
        for number, text in prose_lines(context, page, lambda plain: "user" in folded(plain)):
            if not _USER_WORD.search(text):
                continue
            for match in _QUOTED.finditer(text):
                words = word_count(match.group(1) if match.group(1) is not None else match.group(2))
                if words >= QUOTE_WORDS:
                    yield violation(page, "user-quote", number, number,
                                    f"quotation of {words} words beside the word user")


def rule_sales_word(context: LintContext) -> Iterator[Violation]:
    """``sales-word``: the words of ``sales-words.txt`` in prose."""
    if context.sales is None:
        return
    for page in context.selected():
        for number, text in prose_lines(context, page, lambda plain: holds_any(folded(plain), context.sales_quick)):
            for match in context.sales.finditer(text):
                yield violation(page, "sales-word", number, number, f"sales word {match.group().lower()}")


# The characters that are emoji (not braille cells or arrows).
_EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿⬅-⬇⬛⬜⭐⭕️]")


def rule_emoji(context: LintContext) -> Iterator[Violation]:
    """``emoji``: each emoji character outside code (code blocks and inline code spans)."""
    for page in context.selected():
        # Most pages have no emoji at all, in code or out: one search of the page settles that.
        if not _EMOJI.search("\n".join(page.lines)):
            continue
        for block in page.blocks:
            if block.kind == "code":
                continue
            text = page.text(block.start, block.end)
            plain = blank_spans(text, [(start, end) for start, end, _ in code_spans(text)])
            for offset, line in enumerate(plain.split("\n")):
                for match in _EMOJI.finditer(line):
                    character = match.group()
                    yield violation(page, "emoji", block.start + offset, block.start + offset,
                                    f"emoji U+{ord(character):04X}")


# ---------------------------------------------------------------------------
# Links and indexes.
# ---------------------------------------------------------------------------

# A destination with a scheme (``https:``, ``mailto:``), or a protocol-relative one.
_SCHEME = re.compile(r"^(?:[A-Za-z][A-Za-z0-9+.\-]*:|//)")
# A reference definition: ``[ref]: destination "title"`` (a footnote ``[^1]:`` is not one).
_REFERENCE_DEFINITION = re.compile(r"^ {0,3}\[(?!\^)[^\]]+\]:[ \t]*(\S+)")


def destination_of(raw: str) -> str:
    """The destination in the text between a link's parentheses: ``<dest>``, or ``dest "title"``."""
    raw = raw.strip()
    if raw.startswith("<"):
        end = raw.find(">")
        return raw[1:end] if end != -1 else raw[1:]
    return raw.split(None, 1)[0] if raw else ""


def block_links(block: ProseBlock) -> List[Link]:
    """The links and images of one prose block, and its reference definitions."""
    found: List[Link] = []
    text = block.text
    for start, end in link_destinations(text):
        # The span runs from the ``](`` to the closing parenthesis.
        dest = destination_of(text[start + 2:end - 1])
        found.append(Link(block.start + text.count("\n", 0, start), dest))
    if block.kind == "paragraph":
        for offset, line in enumerate(text.split("\n")):
            match = _REFERENCE_DEFINITION.match(line)
            if match:
                found.append(Link(block.start + offset, destination_of(match.group(1))))
    return found


def split_destination(dest: str) -> Tuple[str, str]:
    """A destination's path and its ``#fragment``, each percent-decoded, query dropped."""
    before, _, fragment = dest.partition("#")
    path = before.partition("?")[0]
    return unquote(path), unquote(fragment)


def target_path(page_path: str, path: str) -> Optional[str]:
    """The repository path that ``path`` names from the page at ``page_path``.

    A leading ``/`` is the repository's root, as on GitHub. None when the path climbs
    out of the repository; ``.`` names the root itself.
    """
    if path.startswith("/"):
        joined = path.lstrip("/")
    else:
        joined = posixpath.join(posixpath.dirname(page_path), path)
    normal = posixpath.normpath(joined)
    if normal == ".." or normal.startswith("../"):
        return None
    return normal


def link_problem(context: LintContext, page: Page, dest: str) -> Optional[str]:
    """What is wrong with the link destination ``dest`` on ``page``, or None when it resolves.

    A destination with a scheme is not checked. An ``#anchor`` alone must be a heading
    of the page, and one after a Markdown page a heading of that page (GitHub matches
    anchors without regard to case). A path must name a file or folder of the
    repository, found from the page's own folder.
    """
    if not dest or _SCHEME.match(dest):
        return None
    path, fragment = split_destination(dest)
    if not path:
        if fragment and fragment.lower() not in context.slugs(page):
            return f"no heading for #{fragment}"
        return None
    resolved = target_path(page.path, path)
    if resolved is None:
        return f"{path} leaves the repository"
    if resolved != "." and not (context.repo.is_file(resolved) or context.repo.is_dir(resolved)):
        return f"{resolved} does not exist"
    if fragment and resolved.endswith(".md") and context.repo.is_file(resolved):
        target = context.page_at(resolved)
        if target is not None and fragment.lower() not in context.slugs(target):
            return f"no heading for #{fragment} in {resolved}"
    return None


def rule_broken_link(context: LintContext) -> Iterator[Violation]:
    """``broken-link``: links, images, and reference definitions whose destination resolves to nothing."""
    for page in context.selected():
        for link in context.links(page):
            problem = link_problem(context, page, link.dest)
            if problem:
                yield violation(page, "broken-link", link.line, link.line, problem)


def rule_index_link(context: LintContext) -> Iterator[Violation]:
    """``index-link``: each page under ``docs/`` that the index pages do not link to exactly once."""
    # Where each docs page is linked from: page -> ["README.md:12", ...].
    linked: Dict[str, List[str]] = {}
    for index in context.selected():
        if index.path not in docmodel.INDEX_PAGES:
            continue
        for link in context.links(index):
            if not link.dest or _SCHEME.match(link.dest):
                continue
            path = split_destination(link.dest)[0]
            resolved = target_path(index.path, path) if path else None
            if resolved and resolved.startswith(DOCS_FOLDER):
                linked.setdefault(resolved, []).append(f"{index.path}:{link.line}")
    for page in context.selected():
        if not page.path.startswith(DOCS_FOLDER):
            continue
        places = linked.get(page.path, [])
        if len(places) != 1:
            where = f": {', '.join(places)}" if places else ""
            yield Violation(page.path, "index-link", 1, 1, "",
                            f"linked from the index pages {len(places)} times, not once{where}")


def link_text_words(text: str) -> int:
    """The words of a Markdown line as read aloud: link text and code content, no syntax."""
    # Images and links keep their text; their destinations go.
    text = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", text)
    return word_count(text.replace("`", " ").replace("*", " "))


def rule_index_line(context: LintContext) -> Iterator[Violation]:
    """``index-line``: index list items that do not start with a link or run over ``INDEX_LINE_WORDS`` words."""
    for page in context.selected():
        if page.path not in docmodel.INDEX_PAGES:
            continue
        for block in page.blocks:
            if block.kind != "list-item":
                continue
            lines = page.lines[block.start - 1:block.end]
            lines[0] = lines[0].expandtabs(4)[block.content_col:]
            text = " ".join(line.strip() for line in lines)
            problems = []
            if not re.match(r"\[[^\]]*\]\([^)]*\)", text):
                problems.append("does not start with a link")
            words = link_text_words(text)
            if words > INDEX_LINE_WORDS:
                problems.append(f"{words} words, limit {INDEX_LINE_WORDS}")
            if problems:
                yield violation(page, "index-line", block.start, block.end, "; ".join(problems))


# ---------------------------------------------------------------------------
# Section markers.
# ---------------------------------------------------------------------------


def rule_marker_missing(context: LintContext) -> Iterator[Violation]:
    """``marker-missing``: sections without a marker, on reference pages."""
    for page in context.selected():
        if not is_reference(page.path):
            continue
        for section in page.sections:
            if section.level >= 1 and section.marker is None:
                yield Violation(page.path, "marker-missing", section.start, section.start,
                                section.heading, "no marker under the heading")


def rule_marker_invalid(context: LintContext) -> Iterator[Violation]:
    """``marker-invalid``: markers with errors or too many keys, and stray markers."""
    for page in context.selected():
        for section in page.sections:
            markers = [section.marker] if section.marker else []
            # A marker above the page's first heading names no section.
            stray = list(section.stray_markers)
            if section.level == 0:
                stray = markers + stray
                markers = []
            for marker in markers:
                if marker.errors:
                    yield Violation(page.path, "marker-invalid", marker.line, marker.line,
                                    section.heading, "; ".join(marker.errors))
                if len(marker.keys) > KEYS_LIMIT:
                    yield Violation(page.path, "marker-invalid", marker.line, marker.line, section.heading,
                                    f"{len(marker.keys)} keys, limit {KEYS_LIMIT}")
            for marker in stray:
                yield Violation(page.path, "marker-invalid", marker.line, marker.line, section.heading,
                                "stray marker: not the first line under a heading")


def rule_marker_duplicate_id(context: LintContext) -> Iterator[Violation]:
    """``marker-duplicate-id``: sections whose marker id another section of the lint pages has."""
    places: Dict[str, List[Tuple[Page, "docmodel.Section"]]] = {}
    for page in context.selected():
        for section in page.sections:
            if section.marker and section.marker.id:
                places.setdefault(section.marker.id, []).append((page, section))
    for ident, sections in places.items():
        if len(sections) < 2:
            continue
        for page, section in sections:
            others = ", ".join(f"{p.path}:{s.marker.line}" for p, s in sections if s is not section)
            yield Violation(page.path, "marker-duplicate-id", section.marker.line, section.marker.line,
                            section.heading, f"id {ident} is also at {others}")


def rule_marker_src(context: LintContext) -> Iterator[Violation]:
    """``marker-src``: marker ``src`` entries that name nothing in the repository."""
    for page in context.selected():
        for section in page.sections:
            if not section.marker:
                continue
            for entry in section.marker.src:
                if not context.repo.resolve(entry):
                    yield Violation(page.path, "marker-src", section.marker.line, section.marker.line,
                                    section.heading, f"src {entry} does not exist")


def rule_stale(context: LintContext) -> Iterator[Violation]:
    """``stale``: cited paths and backticked Swift names that no longer exist, on pages but logs.

    ``cmd_stale.stale_items`` finds them, with the Swift index and the allowlist. A
    marker's ``src`` entries are ``marker-src``'s, so a missing one is not counted
    twice; and a log page may name what was removed, since it is history.
    """
    pages = list(context.selected(logs=False))
    index = swiftindex.SwiftIndex.load(context.repo)
    allow = cmd_stale.load_allowlist(context.root)
    for item in cmd_stale.stale_items(pages, context.repo, index, allow):
        if item.citation_kind != KIND_SRC:
            yield Violation(item.page, "stale", item.line, item.line, item.heading, item.detail)


# ---------------------------------------------------------------------------
# Headings and sentences.
# ---------------------------------------------------------------------------


def rule_duplicate_heading(context: LintContext) -> Iterator[Violation]:
    """``duplicate-heading``: headings that repeat an earlier heading of the page, on pages but logs."""
    for page in context.selected(logs=False):
        first: Dict[str, int] = {}
        for section in page.sections:
            if section.level == 0:
                continue
            title = targets.plain_title(section.title)
            if title in first:
                yield Violation(page.path, "duplicate-heading", section.start, section.start, section.heading,
                                f"same heading as line {first[title]}")
            else:
                first[title] = section.start


_QUOTE_LEAD = re.compile(r"^\s*(?:>\s?)+")


def sentence_text(page: Page, block: Block, number: int) -> str:
    """The text of line ``number`` of ``block`` without its list marker or ``>``."""
    line = page.lines[number - 1]
    if block.kind == "list-item" and number == block.start:
        return line.expandtabs(4)[block.content_col:]
    if block.kind == "quote":
        return _QUOTE_LEAD.sub("", line)
    return line


def rule_sentences_per_line(context: LintContext) -> Iterator[Violation]:
    """``sentences-per-line``: prose lines holding more than one sentence, on pages but logs."""
    for page in context.selected(logs=False):
        for block in page.blocks:
            if block.kind not in SENTENCE_KINDS:
                continue
            for number in range(block.start, block.end + 1):
                sentences = len(split_sentences(sentence_text(page, block, number)))
                if sentences > 1:
                    yield violation(page, "sentences-per-line", number, number, f"{sentences} sentences on one line")


# ---------------------------------------------------------------------------
# The list of rules, and running them.
# ---------------------------------------------------------------------------

# Every rule, in the order the lint reports them. To add one, add a line here.
RULES: List[Tuple[str, Callable[[LintContext], Iterable[Violation]]]] = [
    ("line-length", rule_line_length),
    ("section-length", rule_section_length),
    ("page-size", rule_page_size),
    ("date", rule_date),
    ("user-quote", rule_user_quote),
    ("sales-word", rule_sales_word),
    ("broken-link", rule_broken_link),
    ("index-link", rule_index_link),
    ("index-line", rule_index_line),
    ("marker-missing", rule_marker_missing),
    ("marker-invalid", rule_marker_invalid),
    ("marker-duplicate-id", rule_marker_duplicate_id),
    ("marker-src", rule_marker_src),
    ("stale", rule_stale),
    ("duplicate-heading", rule_duplicate_heading),
    ("sentences-per-line", rule_sentences_per_line),
    ("emoji", rule_emoji),
]


def rule_names() -> List[str]:
    """The names of the rules, in report order."""
    return [name for name, _ in RULES]


def check_rule_names(names: Iterable[str]) -> List[str]:
    """``names`` as a list, or a UsageError that names the rules when one is not a rule."""
    known = rule_names()
    wanted = list(names)
    for name in wanted:
        if name not in known:
            raise output.UsageError(f"unknown rule {name!r}; the rules are: {', '.join(known)}")
    return wanted


def lint(root: Path, rules: Optional[Iterable[str]] = None) -> List[Violation]:
    """Every violation of the named rules (all rules by default) in the pages under ``root``.

    The result is in rule order, then page order, then line order.
    """
    wanted = None if rules is None else set(check_rule_names(rules))
    context = LintContext.build(root)
    order = context.order()
    found: List[Violation] = []
    for name, rule in RULES:
        if wanted is not None and name not in wanted:
            continue
        found += sorted(rule(context), key=lambda v: (order.get(v.page, len(order)), v.start, v.end))
    return found
