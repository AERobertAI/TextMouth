"""Tests of output.py (printing hits) and of doclib.py's own work (the root, the options)."""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import random
import re
from types import SimpleNamespace

from doclib_case import DocLibCase

import doclib
import output
from output import ELLIPSIS, Hit, clip, emit, format_hit


class ClipTests(DocLibCase):
    """clip(): white space collapsed, the cut at 200 characters, the focus kept in view."""

    def test_short_text_is_collapsed_and_kept_whole(self) -> None:
        self.assertEqual(clip("  one\n  two\tthree  "), "one two three")

    def test_long_text_without_a_focus_keeps_the_start(self) -> None:
        text = "word " * 100
        clipped = clip(text)
        self.assertEqual(len(clipped), output.TEXT_LIMIT)
        self.assertTrue(clipped.endswith(ELLIPSIS))
        self.assertTrue(clipped.startswith("word word"))

    def test_a_focus_near_the_end_keeps_the_end(self) -> None:
        text = "a" * 300 + " needle"
        match = re.search("needle", text)
        clipped = clip(text, match.span())
        self.assertTrue(clipped.startswith(ELLIPSIS))
        self.assertTrue(clipped.endswith("needle"))
        self.assertEqual(len(clipped), output.TEXT_LIMIT)

    def test_a_focus_in_the_middle_sits_between_two_cuts(self) -> None:
        text = "x" * 400 + " needle " + "y" * 400
        clipped = clip(text, re.search("needle", text).span())
        self.assertTrue(clipped.startswith(ELLIPSIS) and clipped.endswith(ELLIPSIS))
        self.assertIn("needle", clipped)
        self.assertEqual(len(clipped), output.TEXT_LIMIT)

    def test_a_focus_inside_a_word_is_carried_through_the_collapse(self) -> None:
        # Runs of white space before the match shift its offsets once collapsed.
        text = "pad\n\n     " * 60 + "the EPUBParser reads it"
        clipped = clip(text, re.search("Parser", text).span())
        self.assertIn("EPUBParser", clipped)

    def test_the_result_never_passes_the_limit(self) -> None:
        # Random texts and focus spans, with a fixed seed so a failure repeats.
        rng = random.Random(14)
        for _ in range(400):
            words = [rng.choice(["a", "bb", "ccc", "\n", "  ", "dddddddd"]) for _ in range(rng.randint(1, 300))]
            text = " ".join(words)
            start = rng.randint(0, len(text))
            end = rng.randint(start, len(text))
            for focus in (None, (start, end)):
                self.assertLessEqual(len(clip(text, focus)), output.TEXT_LIMIT)


class FormatAndEmitTests(DocLibCase):
    """format_hit() and emit(): the line format, the cap, and JSON lines."""

    def test_a_hit_prints_path_lines_heading_and_text(self) -> None:
        hit = Hit("docs/user/feeds.md", 3, 5, "Feeds > Subscribing", "Choose  Subscribe.")
        self.assertEqual(format_hit(hit), "docs/user/feeds.md:3-5  Feeds > Subscribing  Choose Subscribe.")

    def test_a_hit_without_a_heading_prints_a_dash(self) -> None:
        self.assertEqual(format_hit(Hit("README.md", 1, 1, "", "x")), "README.md:1-1  -  x")

    def capture(self, hits, **options):
        """emit() the hits with the given options; return (total, stdout, stderr)."""
        args = SimpleNamespace(json=False, max=None, default_max=output.DEFAULT_MAX)
        for name, value in options.items():
            setattr(args, name, value)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            total = emit(iter(hits), args)
        return total, out.getvalue(), err.getvalue()

    def test_the_cap_prints_some_and_says_how_many_were_left_out(self) -> None:
        hits = [Hit("a.md", n, n, "", f"hit {n}") for n in range(1, 4)]
        total, out, err = self.capture(hits, max=2)
        self.assertEqual(total, 3)
        self.assertEqual(out.splitlines(), ["a.md:1-1  -  hit 1", "a.md:2-2  -  hit 2"])
        self.assertIn("2 of 3 hits shown", err)

    def test_max_zero_prints_every_hit_and_nothing_on_stderr(self) -> None:
        hits = [Hit("a.md", n, n, "", "x") for n in range(1, 31)]
        total, out, err = self.capture(hits, max=0)
        self.assertEqual((total, len(out.splitlines()), err), (30, 30, ""))

    def test_the_command_default_applies_when_max_is_not_given(self) -> None:
        hits = [Hit("a.md", n, n, "", "x") for n in range(1, 31)]
        _, out, _ = self.capture(hits, default_max=0)
        self.assertEqual(len(out.splitlines()), 30)

    def test_json_lines_carry_the_same_fields_and_the_extra_ones(self) -> None:
        hit = Hit("a.md", 2, 4, "H", "text", extra={"id": "some-id"})
        _, out, _ = self.capture([hit], json=True)
        self.assertEqual(
            json.loads(out),
            {"path": "a.md", "start": 2, "end": 4, "heading": "H", "text": "text", "id": "some-id"},
        )


class EntryPointTests(DocLibCase):
    """doclib.py itself: finding the repository, the --max type, usage errors."""

    def test_the_root_is_the_nearest_folder_with_a_git_entry(self) -> None:
        # A worktree's .git is a file; the search takes it as readily as a folder.
        self.write_tree({"repo/.git": "gitdir: elsewhere\n", "repo/docs/user/x.md": "# X\n"})
        found = doclib.find_root(self.root / "repo" / "docs" / "user")
        self.assertEqual(found, self.root / "repo")

    def test_no_repository_is_a_usage_error(self) -> None:
        with self.assertRaises(output.UsageError):
            doclib.find_root(self.root)

    def test_max_takes_zero_and_refuses_a_negative_number(self) -> None:
        self.assertEqual(doclib.nonnegative_int("0"), 0)
        with self.assertRaises(argparse.ArgumentTypeError):
            doclib.nonnegative_int("-1")
        with self.assertRaises(argparse.ArgumentTypeError):
            doclib.nonnegative_int("many")

    def test_an_unknown_command_is_a_usage_error(self) -> None:
        status, _, err = self.run_cli("no-such-command")
        self.assertEqual(status, output.EXIT_USAGE)
        self.assertIn("invalid choice", err)
