"""Tests of `Scripts/l10n/sync-paths.txt`: how l10n.py reads it, how config.json refuses the old `syncPaths` key, and that git
merges the file by union (TL13).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works in a temporary folder or a scratch git repository of its own.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import l10n  # noqa: E402  (imported by path, after sys.path is set)
from git_case import HAS_GIT, GitCase  # noqa: E402

L10N = HERE.parent / "l10n.py"
GITATTRIBUTES = HERE.parents[2] / ".gitattributes"


class ReadingTests(unittest.TestCase):
    """`load_sync_paths`: one glob per line."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.file = self.folder / l10n.SYNC_PATHS_FILE

    def test_one_glob_a_line_in_file_order(self):
        self.file.write_text("TextMouth/Models/**\nTextMouth/Views/**\n")
        self.assertEqual(l10n.load_sync_paths(self.file), ["TextMouth/Models/**", "TextMouth/Views/**"])

    def test_blank_lines_comments_and_surrounding_spaces_are_skipped(self):
        self.file.write_text("# What this file is\n\n   \nTextMouth/A.swift  \n  # an indented comment\n\tTextMouth/B.swift\n")
        self.assertEqual(l10n.load_sync_paths(self.file), ["TextMouth/A.swift", "TextMouth/B.swift"])

    def test_repeated_lines_are_dropped_keeping_the_first(self):
        self.file.write_text("TextMouth/A.swift\nTextMouth/B.swift\nTextMouth/A.swift\n")
        self.assertEqual(l10n.load_sync_paths(self.file), ["TextMouth/A.swift", "TextMouth/B.swift"])

    def test_a_missing_file_is_no_globs(self):
        self.assertEqual(l10n.load_sync_paths(self.folder / "nothing.txt"), [])

    def test_a_file_with_no_final_newline_is_read_whole(self):
        self.file.write_text("TextMouth/A.swift")
        self.assertEqual(l10n.load_sync_paths(self.file), ["TextMouth/A.swift"])


class UnmatchedGlobsTests(unittest.TestCase):
    """`unmatched_globs`: which globs match no file, and how fast."""

    def test_plain_and_wildcard_globs_are_told_apart_and_order_is_kept(self):
        files = ["TextMouth/A/One.swift", "TextMouth/B/Two.swift"]
        globs = ["TextMouth/Z.swift", "TextMouth/A/**", "TextMouth/B/One.swift", "TextMouth/*/Two.swift", "TextMouth/Q/**",
                 "TextMouth/A/One.swift"]
        self.assertEqual(l10n.unmatched_globs(globs, files), ["TextMouth/Z.swift", "TextMouth/B/One.swift", "TextMouth/Q/**"])

    def test_900_one_file_globs_against_4000_paths_take_under_a_second(self):
        import time
        files = [f"TextMouth/Views/Area{n % 50}/File{n}.swift" for n in range(4000)]
        globs = sorted(files[n * 4] for n in range(900))
        # This process's CPU time, not the clock's, so that a busy Mac (other processes holding the cores) can't fail
        # the test while a matcher that tries every glob on every path still would.
        started = time.process_time()
        self.assertEqual(l10n.unmatched_globs(globs, files), [])
        self.assertLess(time.process_time() - started, 1.0)
        # A few wildcard globs among them stay fast too.
        started = time.process_time()
        self.assertEqual(l10n.unmatched_globs(globs + ["TextMouth/Views/Area7/**"], files), [])
        self.assertLess(time.process_time() - started, 1.0)


@unittest.skipUnless(HAS_GIT, "git is not installed")
class MatchingTests(GitCase):
    """A glob that matches no file of the checkout is refused."""

    def setUp(self):
        super().setUp()
        self.put("TextMouth/Views/A.swift", "// a\n")
        self.commit_all("base")
        self.file = self.put("config/sync-paths.txt", "")

    def test_globs_that_match_files_pass(self):
        self.file.write_text("TextMouth/Views/**\nTextMouth/Views/A.swift\n")
        self.assertEqual(l10n.load_sync_paths(self.file, self.repo), ["TextMouth/Views/**", "TextMouth/Views/A.swift"])

    def test_a_glob_matching_nothing_is_refused_and_named(self):
        self.file.write_text("TextMouth/Views/**\nTextMouth/Veiws/**\nTextMouth/Nothing.swift\n")
        with self.assertRaises(ValueError) as caught:
            l10n.load_sync_paths(self.file, self.repo)
        self.assertIn("TextMouth/Veiws/**", str(caught.exception))
        self.assertIn("TextMouth/Nothing.swift", str(caught.exception))
        self.assertNotIn("TextMouth/Views/**", str(caught.exception))

    def test_a_new_file_not_yet_committed_counts(self):
        self.put("TextMouth/Views/New.swift", "// new\n")
        self.file.write_text("TextMouth/Views/New.swift\n")
        self.assertEqual(l10n.load_sync_paths(self.file, self.repo), ["TextMouth/Views/New.swift"])

    def test_load_config_turns_the_refusal_into_a_refused_that_names_the_file(self):
        self.file.write_text("TextMouth/Nothing/**\n")
        config = self.put("config/config.json", "{}")
        with self.assertRaises(l10n.Refused) as caught:
            l10n.load_config(config, self.repo)
        self.assertEqual(caught.exception.status, l10n.EXIT_USAGE)
        self.assertIn("sync-paths.txt", str(caught.exception))
        self.assertIn("matches no file", str(caught.exception))

    def test_a_checkout_that_is_no_repository_skips_the_check(self):
        """The sync's own tests use a made-up checkout."""
        self.file.write_text("TextMouth/Nothing/**\n")
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.assertEqual(l10n.load_sync_paths(self.file, Path(folder.name) / "made-up"), ["TextMouth/Nothing/**"])


class ConfigTests(unittest.TestCase):
    """config.json no longer holds `syncPaths`."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.config = self.folder / "config.json"

    def test_the_globs_come_from_the_file_beside_the_configuration(self):
        self.config.write_text("{}")
        (self.folder / l10n.SYNC_PATHS_FILE).write_text("# c\nTextMouth/B/**\nTextMouth/A/**\n")
        self.assertEqual(l10n.load_config(self.config)["syncPaths"], ["TextMouth/B/**", "TextMouth/A/**"])

    def test_no_file_is_no_globs(self):
        self.config.write_text("{}")
        self.assertEqual(l10n.load_config(self.config)["syncPaths"], [])

    def test_an_old_syncpaths_key_is_refused_with_a_sentence_naming_the_new_file(self):
        for value in ([], ["TextMouth/**"], "TextMouth/**"):
            self.config.write_text(json.dumps({"syncPaths": value}))
            with self.assertRaises(l10n.Refused) as caught:
                l10n.load_config(self.config)
            self.assertEqual(caught.exception.status, l10n.EXIT_USAGE)
            self.assertIn("sync-paths.txt", str(caught.exception))
            self.assertIn("syncPaths", str(caught.exception))

    def test_the_repositorys_configuration_has_no_syncpaths_key(self):
        self.assertNotIn("syncPaths", json.loads(l10n.CONFIG_PATH.read_text(encoding="utf-8")))

    def test_the_repositorys_file_is_sorted_and_says_what_it_is(self):
        text = (l10n.CONFIG_PATH.parent / l10n.SYNC_PATHS_FILE).read_text(encoding="utf-8")
        self.assertTrue(text.startswith("#"), "a comment at the top says what the file is")
        self.assertIn("conversion wave", text)
        globs = l10n.load_sync_paths(l10n.CONFIG_PATH.parent / l10n.SYNC_PATHS_FILE)
        self.assertEqual(globs, sorted(globs), "the file is kept sorted")


@unittest.skipUnless(HAS_GIT, "git is not installed")
class UnionMergeTests(GitCase):
    """Real merges: the file is marked `merge=union` in the repository's .gitattributes, so two waves never conflict."""

    PATH = "Scripts/l10n/sync-paths.txt"

    def setUp(self):
        super().setUp()
        # The repository's own .gitattributes, so that what is tested is the rule that is committed.
        self.put(".gitattributes", GITATTRIBUTES.read_text(encoding="utf-8"))
        self.put("TextMouth/A/One.swift", "//\n")
        self.put("TextMouth/B/Two.swift", "//\n")
        self.put("TextMouth/C/Three.swift", "//\n")
        self.put("TextMouth/D/Four.swift", "//\n")
        self.put(self.PATH, "# header\nTextMouth/A/**\nTextMouth/D/**\n")
        self.commit_all("base")

    def add_line_on_branch(self, name, after, line):
        """Makes the branch `name` and adds `line` after the line `after` of the file."""
        self.branch_from_main(name)
        path = self.repo / self.PATH
        text = path.read_text(encoding="utf-8").replace(after + "\n", after + "\n" + line + "\n")
        path.write_text(text, encoding="utf-8")
        self.git("commit", "-q", "-am", name)

    def test_the_repositorys_gitattributes_marks_the_file_for_union(self):
        text = GITATTRIBUTES.read_text(encoding="utf-8")
        self.assertIn("/Scripts/l10n/sync-paths.txt merge=union", text)

    def test_two_branches_adding_neighbouring_lines_merge_without_a_conflict(self):
        self.add_line_on_branch("wave-b", "TextMouth/A/**", "TextMouth/B/**")
        self.add_line_on_branch("wave-c", "TextMouth/A/**", "TextMouth/C/**")
        self.git("switch", "-q", "wave-b")
        done = self.git("merge", "--no-edit", "wave-c", check=False)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual(self.git("ls-files", "-u").stdout, "")
        globs = l10n.load_sync_paths(self.repo / self.PATH, self.repo)
        self.assertEqual(sorted(globs), ["TextMouth/A/**", "TextMouth/B/**", "TextMouth/C/**", "TextMouth/D/**"])
        self.assertNotIn("<<<<<<<", (self.repo / self.PATH).read_text(encoding="utf-8"))

    def test_without_the_attribute_the_same_merge_conflicts(self):
        """The control: it is the attribute, and not luck, that merges the test above."""
        self.git("rm", "-q", "-f", ".gitattributes")
        self.git("commit", "-q", "-m", "no attributes")
        self.add_line_on_branch("wave-b", "TextMouth/A/**", "TextMouth/B/**")
        self.add_line_on_branch("wave-c", "TextMouth/A/**", "TextMouth/C/**")
        self.git("switch", "-q", "wave-b")
        self.assertNotEqual(self.git("merge", "--no-edit", "wave-c", check=False).returncode, 0)

    def test_two_branches_adding_the_same_line_keep_it_once(self):
        self.add_line_on_branch("wave-b", "TextMouth/A/**", "TextMouth/B/**")
        self.add_line_on_branch("wave-c", "TextMouth/A/**", "TextMouth/B/**")
        self.git("switch", "-q", "wave-b")
        self.assertEqual(self.git("merge", "--no-edit", "wave-c", check=False).returncode, 0)
        self.assertEqual(l10n.load_sync_paths(self.repo / self.PATH).count("TextMouth/B/**"), 1)


if __name__ == "__main__":
    unittest.main()
