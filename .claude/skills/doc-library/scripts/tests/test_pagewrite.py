"""Tests of pagewrite.py: reading a page for a rewrite, and writing it back only when its words are kept."""

from __future__ import annotations

import os
import stat
from unittest import mock

from doclib_case import DocLibCase

import pagewrite
from output import UsageError

PAGE = "docs/user/page.md"
TEXT = "# Page\n\nOne sentence. Two sentences.\n"


class ReadTests(DocLibCase):
    """read_page_text(): UTF-8 without carriage returns, inside the root."""

    def test_a_plain_page_is_read_as_written(self) -> None:
        self.write_tree({PAGE: TEXT})
        self.assertEqual(pagewrite.read_page_text(self.root, PAGE), TEXT)

    def test_carriage_returns_and_bad_bytes_are_refused(self) -> None:
        self.write_tree({PAGE: TEXT})
        (self.root / "docs/user/crlf.md").write_bytes(b"# A\r\n\r\nText.\r\n")
        (self.root / "docs/user/bad.md").write_bytes(b"# A\n\nT\xffext.\n")
        for path in ("docs/user/crlf.md", "docs/user/bad.md"):
            with self.subTest(path=path), self.assertRaises(UsageError):
                pagewrite.read_page_text(self.root, path)

    def test_a_page_outside_the_root_is_refused(self) -> None:
        with self.assertRaises(UsageError):
            pagewrite.read_page_text(self.root, "../outside.md")


class RewriteTests(DocLibCase):
    """rewrite() and write_page(): the words' check, the one-step write, and its refusals."""

    def test_a_reflow_that_keeps_the_words_is_written(self) -> None:
        self.write_tree({PAGE: TEXT})
        new = "# Page\n\nOne sentence.\nTwo sentences.\n"
        self.assertEqual(pagewrite.rewrite(self.root, PAGE, TEXT, new), [])
        self.assertEqual((self.root / PAGE).read_text(encoding="utf-8"), new)

    def test_a_lost_word_writes_nothing_and_says_where(self) -> None:
        self.write_tree({PAGE: TEXT})
        problems = pagewrite.rewrite(self.root, PAGE, TEXT, "# Page\n\nOne sentence. Two.\n")
        self.assertTrue(problems)
        self.assertIn("differ", problems[0])
        self.assertEqual((self.root / PAGE).read_text(encoding="utf-8"), TEXT)

    def test_an_added_marker_keeps_the_words(self) -> None:
        self.write_tree({PAGE: TEXT})
        new = "# Page\n<!-- id: page; keys: ; src: -->\n\nOne sentence. Two sentences.\n"
        self.assertEqual(pagewrite.rewrite(self.root, PAGE, TEXT, new), [])
        self.assertEqual((self.root / PAGE).read_text(encoding="utf-8"), new)

    def test_the_same_text_writes_nothing(self) -> None:
        self.write_tree({PAGE: TEXT})
        with mock.patch.object(pagewrite, "write_page") as write:
            self.assertEqual(pagewrite.rewrite(self.root, PAGE, TEXT, TEXT), [])
        write.assert_not_called()

    def test_the_write_keeps_the_mode_and_leaves_no_temporary_file(self) -> None:
        self.write_tree({PAGE: TEXT})
        page = self.root / PAGE
        page.chmod(0o640)
        pagewrite.write_page(self.root, PAGE, "# Page\n\nNew.\n")
        self.assertEqual(stat.S_IMODE(page.stat().st_mode), 0o640)
        self.assertEqual(sorted(os.listdir(page.parent)), ["page.md"])

    def test_the_write_goes_through_one_replace(self) -> None:
        # The page is never opened for writing: a temporary file is moved over it.
        self.write_tree({PAGE: TEXT})
        with mock.patch("os.replace", wraps=os.replace) as replace:
            pagewrite.write_page(self.root, PAGE, "# Page\n\nNew.\n")
        replace.assert_called_once()
        self.assertEqual(os.path.realpath(replace.call_args.args[1]), os.path.realpath(self.root / PAGE))

    def test_writing_outside_the_root_or_a_missing_page_is_refused(self) -> None:
        self.write_tree({PAGE: TEXT})
        for path in ("../outside.md", "/Users/nobody/.TextMouth/x.md", "docs/user/missing.md"):
            with self.subTest(path=path), self.assertRaises(UsageError):
                pagewrite.write_page(self.root, path, "x\n")
