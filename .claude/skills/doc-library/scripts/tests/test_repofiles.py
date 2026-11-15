"""Tests of repofiles.py: the repository's files, and how a path written in a doc resolves."""

from __future__ import annotations

import os
from pathlib import Path
from unittest import mock

from doclib_case import DocLibCase

from repofiles import RepoFiles, SOURCE_EXTENSIONS

# A small repository's files, laid out like the real one.
TREE = {
    "README.md": "r\n",
    "project.yml": "p\n",
    "Makefile": "m\n",
    "docs/agents/writing-docs.md": "w\n",
    "Scripts/agents/run_locked.py": "x\n",
    "Scripts/build.sh": "x\n",
    "Vendor/lame/lame.c": "x\n",
    "Vendor/lame/lame.h": "x\n",
    "TextMouth/Models/AudioEdit.swift": "x\n",
    "TextMouth/Services/SpeechExport/Exporter.swift": "x\n",
    "TextMouth/Services/SpeechExport/Helper.swift": "x\n",
    "TextMouth/Parsers/DOCXParser+Numbering.swift": "x\n",
    "TextMouth/Parsers/Helper.swift": "x\n",
    ".claude/skills/doc-library/SKILL.md": "s\n",
}


class IndexTests(DocLibCase):
    """The sets a RepoFiles builds from a list of paths."""

    def setUp(self) -> None:
        """A RepoFiles over TREE's paths, with no disk involved."""
        super().setUp()
        self.repo = RepoFiles(self.root, TREE)

    def test_files_and_root(self) -> None:
        self.assertEqual(self.repo.root, self.root)
        self.assertEqual(self.repo.files, frozenset(TREE))

    def test_dirs_hold_every_ancestor_without_a_trailing_slash(self) -> None:
        self.assertIn("TextMouth/Services/SpeechExport", self.repo.dirs)
        self.assertIn("TextMouth/Services", self.repo.dirs)
        self.assertIn("TextMouth", self.repo.dirs)
        self.assertIn("Vendor/lame", self.repo.dirs)
        self.assertNotIn("TextMouth/Services/", self.repo.dirs)
        self.assertNotIn("README.md", self.repo.dirs)

    def test_tops_are_the_root_names_and_those_under_the_app_folder(self) -> None:
        self.assertEqual(
            self.repo.tops,
            frozenset({"README.md", "project.yml", "Makefile", "docs", "Scripts", "Vendor", "TextMouth",
                       ".claude", "Models", "Services", "Parsers"}),
        )

    def test_is_file_and_is_dir(self) -> None:
        self.assertTrue(self.repo.is_file("Scripts/build.sh"))
        self.assertFalse(self.repo.is_file("Scripts"))
        self.assertTrue(self.repo.is_dir("Scripts"))
        self.assertTrue(self.repo.is_dir("Scripts/"))
        self.assertFalse(self.repo.is_dir("Scripts/build.sh"))
        self.assertFalse(self.repo.is_dir("Nope"))

    def test_by_name_is_sorted_and_empty_when_nothing_matches(self) -> None:
        self.assertEqual(
            self.repo.by_name("Helper.swift"),
            ["TextMouth/Parsers/Helper.swift", "TextMouth/Services/SpeechExport/Helper.swift"],
        )
        self.assertEqual(self.repo.by_name("Nope.swift"), [])
        self.assertEqual(self.repo.by_name("Helper"), [])

    def test_under_lists_a_folders_files_sorted_with_or_without_a_slash(self) -> None:
        expected = ["Vendor/lame/lame.c", "Vendor/lame/lame.h"]
        self.assertEqual(self.repo.under("Vendor/lame"), expected)
        self.assertEqual(self.repo.under("Vendor/lame/"), expected)

    def test_under_does_not_match_a_sibling_with_the_same_prefix(self) -> None:
        repo = RepoFiles(self.root, ["a/b.txt", "ab/c.txt", "a/z.txt"])
        self.assertEqual(repo.under("a"), ["a/b.txt", "a/z.txt"])

    def test_under_an_unknown_folder_is_empty(self) -> None:
        self.assertEqual(self.repo.under("Nope"), [])


class IsRepoPathTests(DocLibCase):
    """is_repo_path(): the syntactic test of what a doc means as a repository path."""

    def setUp(self) -> None:
        """A RepoFiles over TREE's paths."""
        super().setUp()
        self.repo = RepoFiles(self.root, TREE)

    def test_paths_under_a_known_first_folder(self) -> None:
        for token in ("Services/Old.swift", "Scripts/agents/run_locked.py", "TextMouth/Models/AudioEdit.swift",
                      "docs/agents/", "Vendor/lame", ".claude/skills/doc-library/SKILL.md"):
            with self.subTest(token=token):
                self.assertTrue(self.repo.is_repo_path(token))

    def test_a_data_directory_path_is_not_one(self) -> None:
        self.assertFalse(self.repo.is_repo_path("Logs/textmouth.log"))

    def test_bare_source_file_names(self) -> None:
        self.assertTrue(self.repo.is_repo_path("DOCXParser+Numbering.swift"))
        for extension in sorted(SOURCE_EXTENSIONS):
            with self.subTest(extension=extension):
                self.assertTrue(self.repo.is_repo_path(f"Thing.{extension}"))

    def test_bare_names_of_root_files(self) -> None:
        # The architecture pages' Files: lists name project.yml among the paths.
        for token in ("README.md", "project.yml", "Makefile"):
            with self.subTest(token=token):
                self.assertTrue(self.repo.is_repo_path(token))

    def test_bare_names_that_are_neither_root_files_nor_source_files(self) -> None:
        for token in ("CHANGELOG.md", "config.json", "writing-docs.md", ".swift", "swift", "Thing.swift.bak",
                      "Services"):
            with self.subTest(token=token):
                self.assertFalse(self.repo.is_repo_path(token))

    def test_white_space_globs_and_placeholders_are_not_paths(self) -> None:
        for token in ("Services/My File.swift", "Services/*.swift", "Services/<name>.swift", "Services/?.swift",
                      "Services/$X.swift", "Services/[a].swift", "Services/{a,b}.swift", "Services/a|b.swift",
                      "Services/a\\b.swift", "", "Services/a\tb"):
            with self.subTest(token=token):
                self.assertFalse(self.repo.is_repo_path(token))

    def test_absolute_home_and_parent_paths_are_not_paths(self) -> None:
        for token in ("/Library/Caches/x", "/Services/Old.swift", "~/.TextMouth/library.json",
                      "../Services/Old.swift", "Services/../Old.swift", "Services//Old.swift",
                      "https://example.com/Services/Old.swift", "Services/..", "Services/a..b/c.swift"):
            with self.subTest(token=token):
                # "a..b" is a name, not a ".." component, so only the others are refused.
                expected = token == "Services/a..b/c.swift"
                self.assertEqual(self.repo.is_repo_path(token), expected)


class ResolveTests(DocLibCase):
    """resolve() and covers(): from the root, then under TextMouth/, folders and bare names."""

    def setUp(self) -> None:
        """A RepoFiles over TREE's paths."""
        super().setUp()
        self.repo = RepoFiles(self.root, TREE)

    def test_a_path_from_the_root(self) -> None:
        self.assertEqual(self.repo.resolve("Scripts/build.sh"), ["Scripts/build.sh"])
        self.assertEqual(self.repo.resolve("TextMouth/Models/AudioEdit.swift"), ["TextMouth/Models/AudioEdit.swift"])

    def test_a_path_under_the_app_folder(self) -> None:
        self.assertEqual(self.repo.resolve("Models/AudioEdit.swift"), ["TextMouth/Models/AudioEdit.swift"])

    def test_the_root_wins_over_the_app_folder(self) -> None:
        repo = RepoFiles(self.root, ["Models/A.swift", "TextMouth/Models/A.swift", "TextMouth/Services/S.swift"])
        self.assertEqual(repo.resolve("Models/A.swift"), ["Models/A.swift"])

    def test_a_folder_resolves_with_a_trailing_slash(self) -> None:
        self.assertEqual(self.repo.resolve("Vendor/lame"), ["Vendor/lame/"])
        self.assertEqual(self.repo.resolve("Vendor/lame/"), ["Vendor/lame/"])
        self.assertEqual(self.repo.resolve("Services/SpeechExport/"), ["TextMouth/Services/SpeechExport/"])

    def test_a_trailing_slash_never_names_a_file(self) -> None:
        self.assertEqual(self.repo.resolve("Scripts/build.sh/"), [])

    def test_a_bare_name_resolves_to_every_file_with_that_name(self) -> None:
        self.assertEqual(self.repo.resolve("DOCXParser+Numbering.swift"), ["TextMouth/Parsers/DOCXParser+Numbering.swift"])
        self.assertEqual(
            self.repo.resolve("Helper.swift"),
            ["TextMouth/Parsers/Helper.swift", "TextMouth/Services/SpeechExport/Helper.swift"],
        )

    def test_a_bare_root_file_resolves_to_itself_alone(self) -> None:
        repo = RepoFiles(self.root, ["project.yml", "Package.swift", "Vendor/kit/Package.swift"])
        self.assertEqual(repo.resolve("project.yml"), ["project.yml"])
        self.assertEqual(repo.resolve("Package.swift"), ["Package.swift"])

    def test_a_missing_path_resolves_to_nothing(self) -> None:
        self.assertEqual(self.repo.resolve("Services/Old.swift"), [])
        self.assertEqual(self.repo.resolve("Missing.swift"), [])
        self.assertEqual(self.repo.resolve("Vendor/nothing"), [])

    def test_a_token_that_is_not_a_path_resolves_to_nothing(self) -> None:
        self.assertEqual(self.repo.resolve("Scripts/*.sh"), [])
        self.assertEqual(self.repo.resolve("Logs/textmouth.log"), [])

    def test_covers(self) -> None:
        self.assertTrue(self.repo.covers("a/b.swift", "a/b.swift"))
        self.assertTrue(self.repo.covers("a/", "a/b.swift"))
        self.assertTrue(self.repo.covers("a/", "a/b/c.swift"))
        self.assertFalse(self.repo.covers("a", "a/b.swift"))
        self.assertFalse(self.repo.covers("a/", "ab/c.swift"))
        self.assertFalse(self.repo.covers("a/b.swift", "a/c.swift"))


class SafetyTests(DocLibCase):
    """A RepoFiles never touches the file system once it is built."""

    def test_a_home_or_absolute_path_is_refused_without_a_file_system_call(self) -> None:
        repo = RepoFiles(self.root, TREE)

        def forbidden(*args: object, **kwargs: object) -> None:
            raise AssertionError("the file system was touched")

        with mock.patch.object(os, "stat", forbidden), mock.patch.object(os, "lstat", forbidden), \
                mock.patch.object(Path, "exists", forbidden):
            for token in ("~/.TextMouth/library.json", "/Library/Caches/x", "../x/y.swift"):
                self.assertFalse(repo.is_repo_path(token))
                self.assertEqual(repo.resolve(token), [])
            # Lookups of real and missing paths are answered from the list as well.
            self.assertEqual(repo.resolve("Scripts/build.sh"), ["Scripts/build.sh"])
            self.assertEqual(repo.resolve("Missing.swift"), [])


class LoadTests(DocLibCase):
    """load(): git's list for a repository, a walk for a plain folder."""

    def test_a_plain_folder_is_walked_skipping_hidden_build_and_derived_data(self) -> None:
        self.write_tree({
            "a.txt": "x", "docs/b.md": "x", "Scripts/c.sh": "x", ".hidden/d.txt": "x", "build/e.txt": "x",
            "DerivedData/f.txt": "x", "docs/build/g.txt": "x", "docs/.git/h": "x",
        })
        repo = RepoFiles.load(self.root)
        self.assertEqual(repo.files, frozenset({"a.txt", "docs/b.md", "Scripts/c.sh"}))

    def test_a_plain_walk_does_not_follow_a_symlinked_folder(self) -> None:
        outside = self.root / "outside"
        self.write_tree({"inner.txt": "x"}, root=outside)
        self.write_tree({"a.txt": "x"}, root=self.root / "repo")
        (self.root / "repo" / "link").symlink_to(outside, target_is_directory=True)
        repo = RepoFiles.load(self.root / "repo")
        self.assertEqual(repo.files, frozenset({"a.txt"}))

    def test_a_git_repository_lists_tracked_and_untracked_but_not_ignored_files(self) -> None:
        self.git_repo({".gitignore": "ignored.txt\nbuild/\n", "tracked.txt": "t", "Scripts/x.sh": "x"})
        self.write_tree({"untracked.txt": "u", "ignored.txt": "i", "build/out.txt": "o"})
        repo = RepoFiles.load(self.root)
        self.assertEqual(repo.files, frozenset({".gitignore", "tracked.txt", "Scripts/x.sh", "untracked.txt"}))

    def test_a_file_deleted_from_the_working_tree_is_not_listed(self) -> None:
        self.git_repo({"keep.txt": "k", "gone.txt": "g"})
        (self.root / "gone.txt").unlink()
        repo = RepoFiles.load(self.root)
        self.assertEqual(repo.files, frozenset({"keep.txt"}))

    def test_a_worktrees_git_file_counts_as_a_repository(self) -> None:
        self.git_repo({"a.txt": "a"})
        self.git("worktree", "add", "-q", "-b", "other", str(self.root / "wt"))
        # The worktree's .git is a file; its list comes from git, not a walk (the
        # walk would skip nothing here, so check a hidden tracked folder is listed).
        self.write_tree({".claude/x.md": "x"}, root=self.root / "wt")
        repo = RepoFiles.load(self.root / "wt")
        self.assertEqual(repo.files, frozenset({"a.txt", ".claude/x.md"}))

    def test_names_with_unusual_characters_survive(self) -> None:
        self.git_repo({"docs/naïve file.md": "x", "docs/tab\tname.md": "y"})
        repo = RepoFiles.load(self.root)
        self.assertEqual(repo.files, frozenset({"docs/naïve file.md", "docs/tab\tname.md"}))
