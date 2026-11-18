"""Shared helpers for the unlocalized-text scanner's tests.

Run every test from the repository root with:

    python3 -I -B -m unittest discover -s Scripts/l10n/tests

Each test works on a small Swift snippet held in a string, or builds a small tree of its own in
a temporary folder, so none reads the real library or depends on the files of the app (one test
walks the app's folder only to count its files). Importing this module puts the scanner's
folder on sys.path, so a test can import any module of the package by name.
"""

from __future__ import annotations

import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict, List, Optional, Tuple

# No bytecode beside the scripts when the tests run without -B.
sys.dont_write_bytecode = True
L10N = Path(__file__).resolve().parent.parent
REPO = L10N.parent.parent
if str(L10N) not in sys.path:
    sys.path.insert(0, str(L10N))

from swiftscan import lexer, scanner  # noqa: E402
from swiftscan.lexer import Literal  # noqa: E402

# The path a snippet is given unless a test names another: a view, so that no Parsers rule
# or wording-file rule applies by accident.
VIEW = "TextMouth/Views/Snippet.swift"
WORDING = "TextMouth/Models/SnippetWording.swift"
PARSER = "TextMouth/Parsers/SnippetParser.swift"


def lex(code: str) -> List[Literal]:
    """The literals of a snippet, unclassified."""
    return lexer.lex(code, VIEW)


def scan_snippet(code: str, path: str = VIEW, extra: Optional[Dict[str, str]] = None) -> List[Literal]:
    """The literals of a snippet (as the file at `path`, with any other files), classified."""
    texts = {path: code}
    texts.update(extra or {})
    return [lit for lit in scanner.scan_texts(texts) if lit.file == path]


def only(code: str, path: str = VIEW, extra: Optional[Dict[str, str]] = None) -> Literal:
    """The one literal of a snippet, classified; fails when there is not exactly one."""
    found = scan_snippet(code, path, extra)
    assert len(found) == 1, [lit.text for lit in found]
    return found[0]


def texts_of(literals: List[Literal]) -> List[str]:
    """The texts of literals, for comparing."""
    return [lit.text for lit in literals]


class ScanCase(unittest.TestCase):
    """A test case with assertions about a literal's bucket, rule, and status."""

    def assertClass(self, code: str, bucket: str, rule: str, status: Optional[str] = None,
                    path: str = VIEW, extra: Optional[Dict[str, str]] = None) -> Literal:
        """The snippet's one literal has this bucket and rule (and status, if given)."""
        lit = only(code, path, extra)
        self.assertEqual((lit.bucket, lit.rule), (bucket, rule), lit.text)
        if status is not None:
            self.assertEqual(lit.status, status, lit.text)
        return lit


def run_main(*argv: str) -> Tuple[int, str, str]:
    """Runs scan.main in-process and returns its exit status, standard output, and standard error."""
    import scan  # the command line, imported when first needed
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = scan.main(list(argv))
    return status, out.getvalue(), err.getvalue()


class TreeCase(unittest.TestCase):
    """A test case with a temporary repository of its own: a TextMouth/ folder of Swift files."""

    def setUp(self) -> None:
        self._temp = tempfile.TemporaryDirectory()
        self.addCleanup(self._temp.cleanup)
        self.root = Path(self._temp.name)
        (self.root / "TextMouth").mkdir()
        self.baseline = self.root / "baseline.json"

    def write(self, name: str, code: str) -> None:
        """Writes TextMouth/<name> with the code."""
        path = self.root / "TextMouth" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(code, encoding="utf-8")

    def lint(self, *extra: str) -> Tuple[int, str, str]:
        """Runs the lint on this tree against this test's baseline file."""
        return run_main("--root", str(self.root), "lint", "--baseline", str(self.baseline), *extra)
