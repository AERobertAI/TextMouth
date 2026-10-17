#!/usr/bin/env python3
"""difflint: a small engine for linting only the lines a branch ADDS.

The engine knows how to
  * ask git which lines a branch added (`added_lines`),
  * mask Swift string literals and comments so a pattern never matches text
    that is not code (`mask_swift`),
  * run a list of `Rule`s over a file (`lint_file`),
  * print the findings as plain words for VoiceOver and braille (`report`),
  * and provide the shared command line (`main`).

A linter script (for example `trap-lint.py`) supplies the rules and the
default paths and calls `main`. Python 3 standard library only.

Run `python3 Scripts/test/difflint.py --selftest` to check the engine itself.
"""

import argparse
import os
import re
import subprocess
import sys
from collections import namedtuple
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional, Set, Tuple

# The two severities a rule can have. ERROR fails the run; REVIEW fails it
# only with --strict (a person decides whether a REVIEW hit is real).
ERROR = "ERROR"
REVIEW = "REVIEW"


class GitError(Exception):
    """Raised when a git command fails (the command line then exits 2)."""


# ---------------------------------------------------------------------------
# Rules and hits
# ---------------------------------------------------------------------------

@dataclass
class Rule:
    """One lint rule.

    name     -- short kebab-case identifier, printed in every finding.
    level    -- ERROR or REVIEW.
    pattern  -- a regular expression (string); searched once per line.
    message  -- the explanation printed with each hit.
    view     -- which masked view of the line is searched: 'code' (string
                contents and comments blanked) or 'code_with_strings'
                (only comments blanked).
    unless   -- optional function (code_lines, index) -> bool; True excuses a
                hit because of its surroundings. `code_lines` is the 'code'
                view of the WHOLE file, so a rule can look at nearby lines.
    """
    name: str
    level: str
    pattern: str
    message: str
    view: str = "code"
    unless: Optional[Callable[[List[str], int], bool]] = None

    def __post_init__(self):
        # Compile once; a bad pattern or view should fail loudly at startup.
        self.regex = re.compile(self.pattern)
        if self.level not in (ERROR, REVIEW):
            raise ValueError(f"rule {self.name}: unknown level {self.level!r}")
        if self.view not in ("code", "code_with_strings"):
            raise ValueError(f"rule {self.name}: unknown view {self.view!r}")


# One finding. `suppressed` is True when a `// lint-ok: reason` comment on the
# same line excused it (such hits are counted but not printed).
Hit = namedtuple("Hit", "path line level rule message source suppressed")

# The two masked views of a file, one string per source line.
Masked = namedtuple("Masked", "code code_with_strings")


# ---------------------------------------------------------------------------
# Swift lexer: mask strings and comments
# ---------------------------------------------------------------------------

# In code, only these characters can start something we must notice: a
# comment (/), a string (" or a run of # before it), or parentheses (to find
# the end of a string interpolation).
_CODE_SPECIAL = re.compile(r'[/"#()]')
# Inside a string: the closing quote, an escape, or a newline.
_STRING_SPECIAL = re.compile(r'["\\\n]')
_NOT_NEWLINE = re.compile(r"[^\n]")


def _blank(text: str) -> str:
    """Replace every character but newlines with a space (keeps line shape)."""
    return _NOT_NEWLINE.sub(" ", text)


def mask_swift(text: str) -> Masked:
    """Return the file's lines in two masked views.

    `code`              string-literal contents and comments become spaces,
                        so a `!` inside "Finished!" or in a comment never
                        matches a pattern. The quote characters stay.
    `code_with_strings` only comments become spaces.

    Both views keep every line's length and the file's line numbers. State is
    tracked across the WHOLE text, so a multi-line string or block comment that
    starts before an added line is understood. Handled: "..." with escapes,
    triple-quoted multi-line strings, raw strings (#"..."#, any number of #),
    string interpolation \\( ... ) (its contents are code), // comments, and
    nested /* */ comments.
    """
    code: List[str] = []   # pieces of the 'code' view
    keep: List[str] = []   # pieces of the 'code_with_strings' view
    n = len(text)

    def both(s):            # real code: visible in both views
        code.append(s)
        keep.append(s)

    def mask_both(s):       # a comment: blank in both views
        blank = _blank(s)
        code.append(blank)
        keep.append(blank)

    def mask_code_only(s):  # string content: blank only in the 'code' view
        code.append(_blank(s))
        keep.append(s)

    # state is None while in code, or (hash_count, is_multiline) in a string.
    state = None
    # Open interpolations: (string state to return to, outer paren depth).
    stack = []
    paren = 0  # paren depth inside the current interpolation's code
    i = 0
    while i < n:
        if state is None:
            m = _CODE_SPECIAL.search(text, i)
            if not m:
                both(text[i:])
                break
            j = m.start()
            if j > i:
                both(text[i:j])
            c = text[j]
            if c == "/":
                nxt = text[j + 1:j + 2]
                if nxt == "/":                       # line comment
                    k = text.find("\n", j)
                    k = n if k < 0 else k
                    mask_both(text[j:k])
                    i = k
                elif nxt == "*":                     # nested block comment
                    k, depth = j + 2, 1
                    while k < n and depth > 0:
                        if text.startswith("/*", k):
                            depth += 1
                            k += 2
                        elif text.startswith("*/", k):
                            depth -= 1
                            k += 2
                        else:
                            k += 1
                    mask_both(text[j:k])
                    i = k
                else:                                # plain slash (division)
                    both("/")
                    i = j + 1
            elif c in ('"', "#"):
                # Possibly the start of a string: #...#"..." or "...".
                k = j
                while k < n and text[k] == "#":
                    k += 1
                if k < n and text[k] == '"':
                    multi = text.startswith('"""', k)
                    opener_end = k + (3 if multi else 1)
                    both(text[j:opener_end])
                    state = (k - j, multi)
                    i = opener_end
                else:                                # e.g. #if, #selector
                    both(text[j:k])
                    i = k
            elif c == "(":
                paren += 1
                both("(")
                i = j + 1
            else:  # c == ")"
                if paren == 0 and stack:
                    # The end of a \( ... ) interpolation: back into the string.
                    state, paren = stack.pop()
                    code.append(" ")
                    keep.append(")")
                else:
                    paren = max(0, paren - 1)
                    both(")")
                i = j + 1
        else:
            hashes, multi = state
            m = _STRING_SPECIAL.search(text, i)
            if not m:
                mask_code_only(text[i:])
                break
            j = m.start()
            if j > i:
                mask_code_only(text[i:j])
            c = text[j]
            if c == "\n":
                if multi:
                    both("\n")
                else:                                # unterminated: recover
                    both("\n")
                    state = None
                i = j + 1
            elif c == "\\":
                # In a raw string an escape is a backslash plus the same
                # number of # characters; otherwise the backslash is plain.
                k = j + 1
                if text.startswith("#" * hashes, k):
                    k += hashes
                    if text.startswith("(", k):      # interpolation begins
                        mask_code_only(text[j:k + 1])
                        stack.append((state, paren))
                        state, paren = None, 0
                        i = k + 1
                    else:                            # ordinary escape
                        mask_code_only(text[j:k + 1])
                        i = k + 1
                else:
                    mask_code_only("\\")
                    i = j + 1
            else:  # a double quote
                closer = ('"""' if multi else '"') + "#" * hashes
                if text.startswith(closer, j):
                    both(closer)
                    state = None
                    i = j + len(closer)
                else:                                # a quote inside the string
                    mask_code_only('"')
                    i = j + 1

    return Masked("".join(code).split("\n"), "".join(keep).split("\n"))


# ---------------------------------------------------------------------------
# Git: which lines did the branch add?
# ---------------------------------------------------------------------------

def run_git(args: List[str], cwd: Optional[str] = None) -> str:
    """Run git and return stdout; raise GitError on a non-zero exit."""
    try:
        done = subprocess.run(
            ["git", "-c", "core.quotepath=off"] + args,
            cwd=cwd, capture_output=True, text=True,
            encoding="utf-8", errors="replace")
    except OSError as error:
        raise GitError(f"cannot run git: {error}")
    if done.returncode != 0:
        raise GitError(f"git {' '.join(args)} failed: {done.stderr.strip()}")
    return done.stdout


def repo_root() -> str:
    """The top folder of the current git worktree."""
    return run_git(["rev-parse", "--show-toplevel"]).strip()


# `@@ -a,b +c,d @@`: groups are a (old start), b (old count), c (new start) and
# d (new count); an omitted count means 1.
_HUNK_HEADER = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def parse_added_lines(diff_text: str) -> Dict[str, Set[int]]:
    """Parse `git diff -U0` output into {path: set of added line numbers}.

    A hunk header reads `@@ -a,b +c,d @@`: d lines were added starting at line
    c (d omitted means 1; d == 0 means nothing was added). The hunk's body is
    counted line by line, so a body line that merely looks like a file header
    (an added line whose text starts with "++ ") is never mistaken for one.
    """
    result: Dict[str, Set[int]] = {}
    current: Optional[str] = None
    old_left = new_left = 0  # lines still to read in the current hunk body
    for line in diff_text.split("\n"):
        if old_left > 0 or new_left > 0:
            if line.startswith("-"):
                old_left -= 1
            elif line.startswith("+"):
                new_left -= 1
            # Anything else ("\ No newline at end of file") is not counted.
            continue
        if line.startswith("+++ "):
            target = line[4:].split("\t")[0]
            if target == "/dev/null":
                current = None
            else:
                current = target[2:] if target.startswith("b/") else target
                result.setdefault(current, set())
            continue
        m = _HUNK_HEADER.match(line)
        if m and current is not None:
            old_count = 1 if m.group(2) is None else int(m.group(2))
            start = int(m.group(3))
            new_count = 1 if m.group(4) is None else int(m.group(4))
            if new_count > 0:
                result[current].update(range(start, start + new_count))
            old_left, new_left = old_count, new_count
    return result


def added_lines(base: str, paths: List[str], root: Optional[str] = None) -> Dict[str, Set[int]]:
    """The lines added since the merge-base of `base` and HEAD, in `paths`.

    The diff runs against the working tree, so staged and unstaged edits count.
    Untracked files (not ignored) count in full. Paths are relative to the
    repository root. Returns {path: set of line numbers}.
    """
    root = root or repo_root()
    merge_base = run_git(["merge-base", base, "HEAD"], cwd=root).strip()
    diff = run_git(["diff", "-U0", "--no-color", merge_base, "--"] + paths, cwd=root)
    result = parse_added_lines(diff)
    untracked = run_git(["ls-files", "--others", "--exclude-standard", "--"] + paths, cwd=root)
    for path in filter(None, untracked.split("\n")):
        full = os.path.join(root, path)
        try:
            with open(full, encoding="utf-8", errors="replace") as handle:
                count = len(handle.read().split("\n"))
        except OSError:
            continue
        result[path] = set(range(1, count + 1))
    return result


# ---------------------------------------------------------------------------
# Git: what did the branch remove or change? (hunks with both sides)
# ---------------------------------------------------------------------------

@dataclass
class Hunk:
    """One `-U0` hunk: the lines it removed and the lines it added.

    `removed` holds (line number in the OLD file, text) pairs and `added`
    holds (line number in the NEW file, text) pairs; the text has no leading
    -/+ and no newline. `old_start`/`new_start` are the header's starting
    lines (for a hunk with nothing on one side, git gives the line BEFORE the
    change, so use the pairs, not these, to locate text).
    """
    old_start: int
    new_start: int
    removed: List[Tuple[int, str]] = field(default_factory=list)
    added: List[Tuple[int, str]] = field(default_factory=list)


@dataclass
class FileDiff:
    """What a diff did to one file.

    status    -- 'modified', 'added', 'deleted' or 'renamed'.
    path      -- the file's path AFTER the change (for a deleted file, the
                 path it had).
    old_path  -- the path before a rename (None otherwise).
    hunks     -- the file's hunks in order (none for a pure rename).
    """
    path: str
    status: str = "modified"
    old_path: Optional[str] = None
    hunks: List[Hunk] = field(default_factory=list)


_DIFF_HEADER = re.compile(r"^diff --git a/(.*) b/(.*)$")


def _header_path(text: str, prefix: str) -> Optional[str]:
    """The path in a `--- a/x` or `+++ b/x` header (None for /dev/null)."""
    target = text[4:].split("\t")[0]
    if target == "/dev/null":
        return None
    return target[2:] if target.startswith(prefix) else target


def parse_hunks(diff_text: str) -> List[FileDiff]:
    """Parse `git diff -U0 -M` output into one FileDiff per file.

    Unlike `parse_added_lines` this keeps the removed lines too, with their
    numbers in the old file, and records how each file changed (added,
    deleted, renamed, modified) from git's extended header lines. A hunk body
    is counted line by line (as in `parse_added_lines`), so body text that
    merely looks like a header is never mistaken for one.
    """
    files: List[FileDiff] = []
    current: Optional[FileDiff] = None
    hunk: Optional[Hunk] = None
    old_left = new_left = 0     # lines still to read in the current hunk body
    old_no = new_no = 0         # the next old / new line number to assign
    for line in diff_text.split("\n"):
        if old_left > 0 or new_left > 0:
            if line.startswith("-"):
                hunk.removed.append((old_no, line[1:]))
                old_no += 1
                old_left -= 1
            elif line.startswith("+"):
                hunk.added.append((new_no, line[1:]))
                new_no += 1
                new_left -= 1
            # Anything else ("\ No newline at end of file") is not counted.
            continue
        m = _DIFF_HEADER.match(line)
        if m:
            current = FileDiff(path=m.group(2))
            files.append(current)
            continue
        if current is None:
            continue
        if line.startswith("new file mode"):
            current.status = "added"
        elif line.startswith("deleted file mode"):
            current.status = "deleted"
        elif line.startswith("rename from "):
            current.status = "renamed"
            current.old_path = line[len("rename from "):]
        elif line.startswith("rename to "):
            current.path = line[len("rename to "):]
        elif line.startswith("--- "):
            # A deleted file has no "+++" path, so take the old one here.
            old = _header_path(line, "a/")
            if old is not None and current.status == "deleted":
                current.path = old
        elif line.startswith("+++ "):
            new = _header_path(line, "b/")
            if new is not None:
                current.path = new
        else:
            h = _HUNK_HEADER.match(line)
            if h:
                old_count = 1 if h.group(2) is None else int(h.group(2))
                new_count = 1 if h.group(4) is None else int(h.group(4))
                hunk = Hunk(int(h.group(1)), int(h.group(3)))
                current.hunks.append(hunk)
                # Numbering of the real lines starts at the header's number
                # (a side with a zero count has no lines to number).
                old_no = int(h.group(1))
                new_no = int(h.group(3))
                old_left, new_left = old_count, new_count
    return files


def diff_files(base: str, paths: List[str], root: Optional[str] = None):
    """What the working tree did to `paths` since the merge-base of `base`.

    Returns (merge_base, [FileDiff]). Renames are detected (-M). Untracked
    files that are not ignored count as added files with all their lines.
    Paths are relative to the repository root.
    """
    root = root or repo_root()
    merge_base = run_git(["merge-base", base, "HEAD"], cwd=root).strip()
    diff = run_git(["diff", "-U0", "--no-color", "-M", merge_base, "--"] + paths, cwd=root)
    files = parse_hunks(diff)
    untracked = run_git(["ls-files", "--others", "--exclude-standard", "--"] + paths, cwd=root)
    for path in filter(None, untracked.split("\n")):
        try:
            with open(os.path.join(root, path), encoding="utf-8", errors="replace") as handle:
                lines = handle.read().split("\n")
        except OSError:
            continue
        if lines and lines[-1] == "":
            lines.pop()                  # the file's final newline is not a line
        new_file = FileDiff(path=path, status="added")
        if lines:
            new_file.hunks.append(Hunk(0, 1, [], list(enumerate(lines, 1))))
        files.append(new_file)
    return merge_base, files


# ---------------------------------------------------------------------------
# Linting a file
# ---------------------------------------------------------------------------

# `// lint-ok: reason` at the end of a line. The reason is required.
_LINT_OK = re.compile(r"//\s*lint-ok:(.*)$")


def _suppression(source: str, kept_view: str):
    """Look for a real `// lint-ok:` comment on one line.

    Returns None when there is none, otherwise the (possibly empty) reason.
    The `//` must be a genuine comment: in the comment-masked view everything
    from it onward is blank (a `//` inside a string would still show there).
    """
    m = _LINT_OK.search(source)
    if not m or kept_view[m.start():].strip():
        return None
    return m.group(1).strip()


def lint_file(path: str, text: str, rules: List[Rule],
              only_lines: Optional[Set[int]] = None) -> List[Hit]:
    """Run `rules` over one file's text and return the hits.

    Only 1-based line numbers in `only_lines` are checked (None means all).
    At most one hit per rule per line. A hit whose line ends with
    `// lint-ok: <reason>` is returned with suppressed=True.
    """
    masked = mask_swift(text)
    source_lines = text.split("\n")
    hits: List[Hit] = []
    for index, source in enumerate(source_lines):
        line_number = index + 1
        if only_lines is not None and line_number not in only_lines:
            continue
        for rule in rules:
            view = masked.code if rule.view == "code" else masked.code_with_strings
            if not rule.regex.search(view[index]):
                continue
            if rule.unless and rule.unless(masked.code, index):
                continue
            reason = _suppression(source, masked.code_with_strings[index])
            message = rule.message
            if reason == "":
                message += " (a lint-ok comment needs a reason after the colon)"
            hits.append(Hit(path, line_number, rule.level, rule.name, message,
                            source.strip(), bool(reason)))
    return hits


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

def summarize(hits: List[Hit]):
    """Return (errors, to_review, suppressed) counts for a list of hits."""
    errors = sum(1 for h in hits if not h.suppressed and h.level == ERROR)
    review = sum(1 for h in hits if not h.suppressed and h.level == REVIEW)
    suppressed = sum(1 for h in hits if h.suppressed)
    return errors, review, suppressed


def report(hits: List[Hit], out=None, show_hits: bool = True):
    """Print the findings and the summary line; return the three counts.

    Each hit prints as `path:line: ERROR rule-name: message` followed by the
    source line indented by 4 spaces. Plain words only: no color, no emoji.
    The last line is `N errors, M to review, K suppressed`.
    """
    out = out or sys.stdout
    if show_hits:
        for h in hits:
            if h.suppressed:
                continue
            print(f"{h.path}:{h.line}: {h.level} {h.rule}: {h.message}", file=out)
            print(f"    {h.source}", file=out)
    errors, review, suppressed = summarize(hits)
    print(f"{errors} errors, {review} to review, {suppressed} suppressed", file=out)
    return errors, review, suppressed


def print_rule_counts(hits: List[Hit], rules: List[Rule], out=None):
    """Print one `rule-name: N` line per rule (an audit's per-rule counts)."""
    out = out or sys.stdout
    seen = []
    for rule in rules:
        if rule.name not in seen:
            seen.append(rule.name)
    for name in seen:
        live = sum(1 for h in hits if h.rule == name and not h.suppressed)
        quiet = sum(1 for h in hits if h.rule == name and h.suppressed)
        extra = f" ({quiet} suppressed)" if quiet else ""
        print(f"{name}: {live}{extra}", file=out)


# ---------------------------------------------------------------------------
# The shared command line
# ---------------------------------------------------------------------------

def _files_under(root: str, paths: List[str], extensions) -> List[str]:
    """Every file with one of `extensions` under `paths` (relative to root)."""
    found = []
    for path in paths:
        top = os.path.join(root, path)
        if os.path.isfile(top):
            found.append(path)
            continue
        for folder, _dirs, names in os.walk(top):
            for name in names:
                if name.endswith(tuple(extensions)):
                    found.append(os.path.relpath(os.path.join(folder, name), root))
    return sorted(found)


def main(rules: List[Rule], default_paths: List[str], argv: Optional[List[str]] = None,
         selftest: Optional[Callable[[], bool]] = None,
         extensions=(".swift",), description: str = "") -> int:
    """The command line shared by every linter built on this engine.

    Options: --base REF (default main), --paths P ... (override the default
    paths), --all (audit every line, always exit 0), --counts (with --all:
    only the per-rule counts), --rule NAME (show only that rule; repeatable),
    --strict (REVIEW hits fail too), --selftest. Returns the exit status:
    0 clean, 1 findings, 2 usage or git problem.
    """
    parser = argparse.ArgumentParser(
        description=description or "Lint the lines this branch adds.")
    parser.add_argument("--base", default="main",
                        help="compare against the merge-base of this ref and HEAD (default: main)")
    parser.add_argument("--paths", nargs="+", default=list(default_paths), metavar="P",
                        help="folders or files to lint, relative to the repository root "
                             f"(default: {' '.join(default_paths)})")
    parser.add_argument("--all", action="store_true",
                        help="audit every line of every file under the paths; prints counts, exits 0")
    parser.add_argument("--counts", action="store_true",
                        help="with --all: print only the per-rule counts, not each hit")
    parser.add_argument("--rule", action="append", default=[], metavar="NAME",
                        help="show only hits of this rule (repeatable)")
    parser.add_argument("--strict", action="store_true",
                        help="REVIEW hits also make the run fail")
    parser.add_argument("--selftest", action="store_true",
                        help="check the rules against canned snippets and exit")
    args = parser.parse_args(argv)  # argparse exits 2 on a usage error

    if args.selftest:
        if selftest is None:
            print("this linter has no self-test", file=sys.stderr)
            return 2
        return 0 if selftest() else 1

    known = {rule.name for rule in rules}
    for name in args.rule:
        if name not in known:
            print(f"unknown rule {name!r}; rules: {', '.join(sorted(known))}", file=sys.stderr)
            return 2

    try:
        root = repo_root()
        if args.all:
            only = {path: None for path in _files_under(root, args.paths, extensions)}
        else:
            changed = added_lines(args.base, args.paths, root)
            only = {path: lines for path, lines in changed.items()
                    if path.endswith(tuple(extensions)) and os.path.isfile(os.path.join(root, path))}
    except GitError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    hits: List[Hit] = []
    for path in sorted(only):
        with open(os.path.join(root, path), encoding="utf-8", errors="replace") as handle:
            text = handle.read()
        hits.extend(lint_file(path, text, rules, only[path]))
    if args.rule:
        hits = [h for h in hits if h.rule in args.rule]

    errors, review, _ = report(hits, show_hits=not (args.all and args.counts))
    if args.all:
        print_rule_counts(hits, rules)
        return 0
    if errors or (args.strict and review):
        return 1
    return 0


# ---------------------------------------------------------------------------
# Self-test of the engine
# ---------------------------------------------------------------------------

def _selftest() -> bool:
    """Check masking, hunk parsing, and suppression; True when all pass."""
    failures = []

    def check(name, condition):
        if not condition:
            failures.append(name)

    # --- masking -----------------------------------------------------------
    m = mask_swift('let a = "Finished!" // done!\nlet b = c!')
    check("string content blanked in code view", "!" not in m.code[0])
    check("comment blanked in code view", "done" not in m.code[0])
    check("string kept in strings view", "Finished!" in m.code_with_strings[0])
    check("comment blanked in strings view", "done" not in m.code_with_strings[0])
    check("real code survives", "c!" in m.code[1])
    check("line count kept", len(m.code) == 2 and len(m.code_with_strings) == 2)
    check("line length kept", len(m.code[0]) == len('let a = "Finished!" // done!'))

    m = mask_swift('let s = """\n  line one!\n  line "two"!\n  """\nlet x = y!')
    check("multiline string masked", "!" not in m.code[1] and "!" not in m.code[2])
    check("code after multiline string seen", "y!" in m.code[4])
    check("multiline line count", len(m.code) == 5)

    m = mask_swift('let r = #"raw "quoted"! \\#(x)"#; let z = w!')
    check("raw string quote inside stays inside", "quoted" not in m.code[0])
    check("code after raw string seen", "w!" in m.code[0])

    m = mask_swift('let t = "a \\(foo!) b!"')
    check("interpolation is code", "foo!" in m.code[0])
    check("text around interpolation is masked", "b!" not in m.code[0])
    m = mask_swift('let t = "a \\(f(1, "in!")) b"; let u = v!')
    check("nested string in interpolation masked", "in!" not in m.code[0])
    check("code after nested interpolation seen", "v!" in m.code[0])

    m = mask_swift('let e = "quote \\" still! inside"; let q = r!')
    check("escaped quote does not end the string", "still" not in m.code[0])
    check("code after escaped quote seen", "r!" in m.code[0])

    m = mask_swift("a /* one /* nested! */ still comment! */ b!\nc!")
    check("nested block comment masked", "nested" not in m.code[0] and "still" not in m.code[0])
    check("code after block comment seen", "b!" in m.code[0] and "c!" in m.code[1])
    m = mask_swift("/* spans\nlines! */ x!")
    check("block comment across lines", "!" not in m.code[0] and "x!" in m.code[1])

    m = mask_swift("#if DEBUG\nlet n = x!\n#endif")
    check("# directives are not strings", "x!" in m.code[1])

    # --- hunk parsing ------------------------------------------------------
    diff = "\n".join([
        "diff --git a/Foo/A.swift b/Foo/A.swift",
        "--- a/Foo/A.swift",
        "+++ b/Foo/A.swift",
        "@@ -3,0 +4,2 @@ func x() {",
        "+let one = 1",
        "+++ looks like a header but is content",
        "@@ -10 +12 @@",
        "-old",
        "+new",
        "@@ -20,2 +21,0 @@",
        "-gone",
        "-gone too",
        "diff --git a/Foo/Dead.swift b/Foo/Dead.swift",
        "--- a/Foo/Dead.swift",
        "+++ /dev/null",
        "@@ -1,2 +0,0 @@",
        "-a",
        "-b",
        "diff --git a/Foo/B.swift b/Foo/B.swift",
        "--- /dev/null",
        "+++ b/Foo/B.swift",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second",
        "\\ No newline at end of file",
        "",
    ])
    parsed = parse_added_lines(diff)
    check("hunk with count", parsed.get("Foo/A.swift") == {4, 5, 12})
    check("pure deletion adds nothing", 21 not in parsed.get("Foo/A.swift", set()))
    check("deleted file not listed", "Foo/Dead.swift" not in parsed)
    check("new file", parsed.get("Foo/B.swift") == {1, 2})

    # --- hunks with both sides (parse_hunks) ---------------------------------
    diff = "\n".join([
        "diff --git a/Foo/A.swift b/Foo/A.swift",
        "--- a/Foo/A.swift",
        "+++ b/Foo/A.swift",
        "@@ -3,0 +4,2 @@ func x() {",
        "+let one = 1",
        "+++ looks like a header but is content",
        "@@ -10,2 +12 @@",
        "-old one",
        "--- looks like a header but is content",
        "+new",
        "\\ No newline at end of file",
        "@@ -20,2 +21,0 @@",
        "-gone",
        "-gone too",
        "diff --git a/Foo/Dead.swift b/Foo/Dead.swift",
        "deleted file mode 100644",
        "--- a/Foo/Dead.swift",
        "+++ /dev/null",
        "@@ -1,2 +0,0 @@",
        "-a",
        "-b",
        "diff --git a/Foo/B.swift b/Foo/B.swift",
        "new file mode 100644",
        "--- /dev/null",
        "+++ b/Foo/B.swift",
        "@@ -0,0 +1,2 @@",
        "+first",
        "+second",
        "diff --git a/Foo/Old.swift b/Foo/New.swift",
        "similarity index 100%",
        "rename from Foo/Old.swift",
        "rename to Foo/New.swift",
        "diff --git a/Foo/R.swift b/Foo/Q.swift",
        "similarity index 90%",
        "rename from Foo/R.swift",
        "rename to Foo/Q.swift",
        "--- a/Foo/R.swift",
        "+++ b/Foo/Q.swift",
        "@@ -5 +5 @@",
        "-before",
        "+after",
        "",
    ])
    files = {f.path: f for f in parse_hunks(diff)}
    check("hunk files found", sorted(files) == ["Foo/A.swift", "Foo/B.swift", "Foo/Dead.swift",
                                                "Foo/New.swift", "Foo/Q.swift"])
    a = files["Foo/A.swift"]
    check("modified status", a.status == "modified" and a.old_path is None)
    check("three hunks", len(a.hunks) == 3)
    check("pure addition", a.hunks[0].removed == []
          and a.hunks[0].added == [(4, "let one = 1"), (5, "++ looks like a header but is content")])
    check("replacement numbers", a.hunks[1].removed == [(10, "old one"), (11, "-- looks like a header but is content")]
          and a.hunks[1].added == [(12, "new")])
    check("pure removal numbers", a.hunks[2].removed == [(20, "gone"), (21, "gone too")]
          and a.hunks[2].added == [])
    check("hunk header starts", (a.hunks[1].old_start, a.hunks[1].new_start) == (10, 12))
    check("deleted file", files["Foo/Dead.swift"].status == "deleted"
          and files["Foo/Dead.swift"].hunks[0].removed == [(1, "a"), (2, "b")])
    check("added file", files["Foo/B.swift"].status == "added"
          and files["Foo/B.swift"].hunks[0].added == [(1, "first"), (2, "second")])
    check("pure rename", files["Foo/New.swift"].status == "renamed"
          and files["Foo/New.swift"].old_path == "Foo/Old.swift" and files["Foo/New.swift"].hunks == [])
    check("rename with edits", files["Foo/Q.swift"].status == "renamed"
          and files["Foo/Q.swift"].old_path == "Foo/R.swift"
          and files["Foo/Q.swift"].hunks[0].removed == [(5, "before")]
          and files["Foo/Q.swift"].hunks[0].added == [(5, "after")])

    # --- rules, only_lines, suppression ------------------------------------
    rules = [
        Rule("bang", ERROR, r"\w!", "a force unwrap"),
        Rule("zero", REVIEW, r"\[0\]", "a literal subscript"),
        Rule("path", ERROR, r"\.Mouth\"", "a live path", view="code_with_strings"),
        Rule("guarded", ERROR, r"danger", "danger", unless=lambda lines, i: "safe" in lines[i - 1]),
    ]
    text = "\n".join([
        'let a = x!',                                      # 1 hit bang
        'let b = y! // lint-ok: the fixture guarantees y',  # 2 suppressed
        'let c = z! // lint-ok:',                          # 3 reason missing: not suppressed
        'let d = "Done!" // w!',                           # 4 no hit
        'let e = list[0]',                                 # 5 zero
        'let f = "~/.Mouth"',                              # 6 path (strings view)
        'let safe = 1',                                    # 7
        'danger()',                                        # 8 excused by line 7
        'danger()',                                        # 9 hit
        'let g = "http://x" + k!',                         # 10 // inside a string, hit not suppressed
    ])
    hits = lint_file("t.swift", text, rules)
    by_line = {(h.line, h.rule): h for h in hits}
    check("plain hit", (1, "bang") in by_line and not by_line[(1, "bang")].suppressed)
    check("suppressed hit counted", (2, "bang") in by_line and by_line[(2, "bang")].suppressed)
    check("lint-ok without reason does not suppress",
          (3, "bang") in by_line and not by_line[(3, "bang")].suppressed)
    check("string and comment never match", not any(h.line == 4 for h in hits))
    check("review level kept", by_line[(5, "zero")].level == REVIEW)
    check("strings view finds literal", (6, "path") in by_line)
    check("unless excuses", not any(h.line == 8 for h in hits))
    check("unless leaves other hits", (9, "guarded") in by_line)
    check("// in a string is not a suppression", (10, "bang") in by_line and not by_line[(10, "bang")].suppressed)
    only = lint_file("t.swift", text, rules, only_lines={1, 5})
    check("only_lines filters", {h.line for h in only} == {1, 5})

    # --- report ------------------------------------------------------------
    import io
    buffer = io.StringIO()
    counts = report(hits, out=buffer)
    printed = buffer.getvalue().split("\n")
    check("report first line", printed[0].startswith("t.swift:1: ERROR bang: a force unwrap"))
    check("report indents source", printed[1] == "    let a = x!")
    check("report summary", printed[-2] == "%d errors, %d to review, %d suppressed" % counts)

    for name in failures:
        print(f"selftest FAILED: {name}")
    if not failures:
        print("difflint selftest: all checks passed")
    return not failures


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(0 if _selftest() else 1)
    print("difflint is an engine; run a linter such as Scripts/test/trap-lint.py "
          "(or `difflint.py --selftest`).", file=sys.stderr)
    sys.exit(2)
