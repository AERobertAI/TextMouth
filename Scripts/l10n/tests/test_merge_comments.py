"""Tests of how merge.py merges the comment of a key that two branches changed (TL13), the way `xcstringstool sync` writes it.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Measured with Xcode's xcstringstool (and pinned below where it is installed): a key extracted by several files with
different comments gets the distinct comments, sorted by code point, joined with a line break, whatever the order of the
--stringsdata arguments; a comment already in the catalog is replaced, never added to. Many waves use one short key
("Cancel", "Done") each with its own comment, so the driver must write that same comment without a conflict.

The git tests work in scratch repositories with a configuration of their own, never the repository's.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import merge  # noqa: E402
from git_case import HAS_GIT, GitCase  # noqa: E402
from test_merge import CATALOG_FILE, L10N, entry, make, unit  # noqa: E402

HAS_TOOL = bool(shutil.which("xcrun")) and subprocess.run(["xcrun", "--find", "xcstringstool"], capture_output=True).returncode == 0


def comment_after_merge(base, ours, theirs):
    """The comment of "Cancel" after the three-way merge of three comments (None for no comment), and the conflicts."""
    def catalog_with(comment):
        """A catalog whose one key has `comment` (none when None)."""
        return make({"Cancel": {} if comment is None else {"comment": comment}})
    result, conflicts = merge.merge_catalogs(catalog_with(base), catalog_with(ours), catalog_with(theirs))
    return result["strings"]["Cancel"].get("comment"), conflicts


class CommentMergeTests(unittest.TestCase):
    """merge_catalogs on one key's comment."""

    def test_both_sides_adding_the_key_with_different_comments_keep_both_sorted(self):
        self.assertEqual(comment_after_merge(None, "The button of B", "The button of A"), ("The button of A\nThe button of B", []))

    def test_the_result_does_not_depend_on_which_side_is_ours(self):
        one = comment_after_merge(None, "Zed", "Alpha")
        other = comment_after_merge(None, "Alpha", "Zed")
        self.assertEqual(one, other)

    def test_both_sides_adding_the_same_comment_keep_it_once(self):
        self.assertEqual(comment_after_merge(None, "The button", "The button"), ("The button", []))

    def test_both_sides_adding_a_line_to_a_comment_main_has_keep_all_three(self):
        self.assertEqual(comment_after_merge("A", "A\nB", "A\nC"), ("A\nB\nC", []))
        self.assertEqual(comment_after_merge("B", "A\nB", "B\nC"), ("A\nB\nC", []))

    def test_a_side_that_cut_a_line_keeps_it_cut_while_the_other_adds_one(self):
        self.assertEqual(comment_after_merge("A\nB", "A", "A\nB\nC"), ("A\nC", []))

    def test_both_sides_cutting_the_same_line_and_adding_one_each(self):
        self.assertEqual(comment_after_merge("A\nB", "A\nD", "A\nC"), ("A\nC\nD", []))

    def test_sorting_is_by_code_point_as_the_sync_sorts(self):
        # Measured: "B second", "a third", "b first" (upper case before lower case; digits as text).
        self.assertEqual(comment_after_merge(None, "a third\nb first", "B second"), ("B second\na third\nb first", []))
        self.assertEqual(comment_after_merge(None, "2 items", "10 items")[0], "10 items\n2 items")

    def test_a_comment_cut_to_nothing_is_no_comment(self):
        self.assertEqual(comment_after_merge("A", None, "A\nB")[0], "B")
        # Both sides dropped their lines and the base's: nothing is left, so the key has no comment.
        result, conflicts = merge.merge_catalogs(make({"K": entry("A")}), make({"K": {}}), make({"K": entry("A\nB")}))
        self.assertEqual(conflicts, [])
        self.assertEqual(result["strings"]["K"], {"comment": "B"})
        result, _ = merge.merge_catalogs(make({"K": entry("A")}), make({"K": {}}), make({"K": entry("B")}))
        self.assertEqual(result["strings"]["K"], {"comment": "B"})
        result, _ = merge.merge_catalogs(make({"K": entry("A\nB")}), make({"K": entry("A")}), make({"K": entry("B")}))
        self.assertEqual(result["strings"]["K"], {}, "both sides cut a different line, so both are gone")

    def test_a_side_with_a_multi_line_comment_keeps_ours_then_theirs_unsorted(self):
        """The catalog cannot tell where one use's comment ends when it holds a line break, and the sync sorts whole
        comments: lines that are not in sorted order show a multi-line comment, so nothing is re-sorted. The next sync
        rewrites the comment."""
        self.assertEqual(comment_after_merge(None, "Zeta line\nAlpha line", "Middle"), ("Zeta line\nAlpha line\nMiddle", []))

    def test_a_comment_that_is_not_a_text_is_a_conflict(self):
        result, conflicts = merge.merge_catalogs(make({"K": entry("A")}), make({"K": {"comment": 1}}), make({"K": entry("B")}))
        self.assertEqual(len(conflicts), 1)
        self.assertEqual(result["strings"]["K"]["comment"], 1, "ours is kept")

    def test_a_translation_both_sides_changed_still_conflicts_beside_a_merged_comment(self):
        base = make({"Cancel": entry("A", es=unit("Cancelar"))})
        ours = make({"Cancel": entry("A\nB", es=unit("Anular"))})
        theirs = make({"Cancel": entry("A\nC", es=unit("Descartar"))})
        result, conflicts = merge.merge_catalogs(base, ours, theirs)
        self.assertEqual([where for where in (merge.where(c.path) for c in conflicts)], ['"Cancel" localizations.es.stringUnit'])
        self.assertEqual(result["strings"]["Cancel"]["comment"], "A\nB\nC")

    def test_a_comment_changed_on_one_side_only_is_taken_as_it_is(self):
        self.assertEqual(comment_after_merge("Old", "Old", "New words"), ("New words", []))
        self.assertEqual(comment_after_merge("Old", "New words", "Old"), ("New words", []))


@unittest.skipUnless(HAS_TOOL, "xcstringstool is not installed")
class SyncAgreementTests(unittest.TestCase):
    """The merged comment is the one a sync of the merged tree writes (measured with the real xcstringstool)."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def stringsdata(self, name, comment):
        """A .stringsdata file in which the file `name` uses "Cancel" with `comment`."""
        path = self.folder / (name + ".stringsdata")
        entries = [{"key": "Cancel", "location": {"startingColumn": 1, "startingLine": 1}, "comment": comment}]
        path.write_text(json.dumps({"source": f"/work/{name}.swift", "tables": {"Localizable": entries}, "version": 1}))
        return path

    def synced(self, names_and_comments, order=None):
        """The comment `xcstringstool sync` writes for "Cancel" extracted by the files given, in the argument order given."""
        files = [self.stringsdata(name, comment) for name, comment in names_and_comments]
        path = self.folder / "Localizable.xcstrings"
        path.write_text(json.dumps(make({})))
        arguments = ["xcrun", "xcstringstool", "sync", str(path)]
        for file in (files if order is None else [files[index] for index in order]):
            arguments += ["--stringsdata", str(file)]
        done = subprocess.run(arguments, capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(path.read_text())["strings"]["Cancel"]["comment"]

    def test_the_sync_writes_the_distinct_comments_sorted_whatever_the_argument_order(self):
        uses = [("A", "The button of B"), ("B", "The button of A"), ("C", "The button of B")]
        expected = "The button of A\nThe button of B"
        for order in ((0, 1, 2), (2, 1, 0), (1, 0, 2)):
            self.assertEqual(self.synced(uses, order), expected)

    def test_the_merge_writes_what_the_sync_of_the_merged_tree_writes(self):
        scenarios = [
            [("A", "The button of A")],
            [("A", "The button of A"), ("B", "Dismisses the sheet")],
            [("A", "b first"), ("B", "B second"), ("C", "a third")],
            [("A", "2 items"), ("B", "10 items")],
            [("A", "Cancels it"), ("B", "Cancels it")],
        ]
        for uses in scenarios:
            for split in range(len(uses) + 1):
                # Ours adds the first `split` uses, theirs the rest: from nothing, each side is a branch of its own.
                ours, theirs = uses[:split], uses[split:]
                if not ours or not theirs:
                    continue
                mine = make({"Cancel": entry(self.synced(ours))})
                yours = make({"Cancel": entry(self.synced(theirs))})
                result, conflicts = merge.merge_catalogs(make({}), mine, yours)
                self.assertEqual(conflicts, [])
                self.assertEqual(result["strings"]["Cancel"]["comment"], self.synced(uses), (uses, split))


@unittest.skipUnless(HAS_GIT, "git is not installed")
class GitCommentMergeTests(GitCase):
    """Real merges in a scratch repository whose own configuration defines the driver as `make l10n-merge-driver` does."""

    def setUp(self):
        super().setUp()
        self.put(".gitattributes", "*.xcstrings merge=xcstrings\n")
        self.git("config", "merge.xcstrings.name", "a String Catalog")
        self.git("config", "merge.xcstrings.driver", f"{sys.executable} -I -B {L10N} merge-driver %O %A %B %P")
        self.write(make({"Play": entry("The play button"), "Close": entry("Closes it")}))
        self.commit_all("base")

    def write(self, data):
        """Writes the catalog `data` in the working tree."""
        catalog.write_text(self.repo / CATALOG_FILE, catalog.dumps(data))

    def read(self):
        """The catalog in the working tree, as an object."""
        return catalog.loads(catalog.read_text(self.repo / CATALOG_FILE))

    def branch(self, name, strings):
        """Makes the branch `name` from main with `strings` put into the catalog, and commits it."""
        self.branch_from_main(name)
        data = self.read()
        data["strings"].update(strings)
        self.write(data)
        self.git("commit", "-q", "-am", name)

    def merge_b_into_a(self):
        """Merges branch b into branch a; returns the completed process."""
        self.git("switch", "-q", "a")
        return self.git("merge", "--no-edit", "b", check=False)

    def test_both_sides_adding_one_key_with_different_comments_merge_to_the_sorted_comment(self):
        self.branch("a", {"Cancel": entry("The button of B")})
        self.branch("b", {"Cancel": entry("The button of A")})
        done = self.merge_b_into_a()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.read()["strings"]["Cancel"]["comment"], "The button of A\nThe button of B")

    def test_both_sides_adding_one_key_with_the_same_comment_merge_cleanly(self):
        self.branch("a", {"Cancel": entry("Dismisses the sheet")})
        self.branch("b", {"Cancel": entry("Dismisses the sheet")})
        self.assertEqual(self.merge_b_into_a().returncode, 0)
        self.assertEqual(self.read()["strings"]["Cancel"]["comment"], "Dismisses the sheet")

    def test_both_sides_adding_a_line_to_a_key_mains_comment_holds_merge_to_all_three(self):
        self.branch("a", {"Play": entry("The play button\nThe play button of the phone")})
        self.branch("b", {"Play": entry("The play button\nThe play button of the Mac")})
        done = self.merge_b_into_a()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.read()["strings"]["Play"]["comment"],
                         "The play button\nThe play button of the Mac\nThe play button of the phone")

    def test_each_side_translating_a_different_key_merges_cleanly_with_a_shared_key_added_by_both(self):
        self.branch("a", {"Play": entry("The play button", es=unit("Reproducir")), "Cancel": entry("From A")})
        self.branch("b", {"Close": entry("Closes it", es=unit("Cerrar")), "Cancel": entry("From B")})
        done = self.merge_b_into_a()
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        strings = self.read()["strings"]
        self.assertEqual(strings["Play"]["localizations"]["es"], unit("Reproducir"))
        self.assertEqual(strings["Close"]["localizations"]["es"], unit("Cerrar"))
        self.assertEqual(strings["Cancel"]["comment"], "From A\nFrom B")

    def test_one_unit_translated_differently_on_each_side_still_conflicts(self):
        self.branch("a", {"Cancel": entry("From A", es=unit("Cancelar"))})
        self.branch("b", {"Cancel": entry("From B", es=unit("Anular"))})
        done = self.merge_b_into_a()
        self.assertNotEqual(done.returncode, 0)
        self.assertIn(CATALOG_FILE, self.git("ls-files", "-u").stdout)
        self.assertIn("Anular", done.stdout + done.stderr)
        self.assertNotIn("comment", done.stderr, "the comment merged, so only the translation is reported")
        self.assertEqual(self.read()["strings"]["Cancel"]["comment"], "From A\nFrom B")
        self.assertEqual(self.read()["strings"]["Cancel"]["localizations"]["es"], unit("Cancelar"), "ours is kept")


if __name__ == "__main__":
    unittest.main()
