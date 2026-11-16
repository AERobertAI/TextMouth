"""The policy test: no tracked file holds a path that belongs to one Mac.

The repository is public, and the user's rule of November 16, 2026 is that no tracked file names the home
folder, the repository's location under it, Claude Code's session or project folders, or $TMPDIR's folder.
This test runs scrub-mac-paths.py's check over every tracked file of the checkout it is in, and fails with the
files that hold such a path. It runs on every push and pull request through `make check-selftest`, and by hand:

    python3 -I -B -m unittest discover -s Scripts/agents/tests -p test_no_mac_paths.py

To fix a failure, run `python3 -I -B Scripts/agents/scrub-mac-paths.py`, which rewrites this Mac's paths in place,
and make a path in a test or a document up (`/Users/reader/...`, a name on FIXTURE_ACCOUNTS) instead of copying a real one.
"""
import importlib.util
import io
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# scrub-mac-paths.py (a name with hyphens, so it is loaded by path) is beside the folder of the tests.
AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS))
_spec = importlib.util.spec_from_file_location("scrub_mac_paths", AGENTS / "scrub-mac-paths.py")
scrub = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(scrub)

# The checkout this test is in: Scripts/agents/tests is three folders below it.
CHECKOUT = AGENTS.parent.parent


class NoMacPathsTests(unittest.TestCase):
    """What the check finds in the tracked files of this checkout."""

    def test_no_tracked_file_holds_a_path_that_belongs_to_one_mac(self):
        counts, files, others, leaks = scrub.scan(CHECKOUT, scrub.Machine.detect())
        out = io.StringIO()
        total = scrub.report(counts, files, others, leaks, listing=True, out=out)
        self.assertEqual(total, 0, "a tracked file holds a path of one Mac (run Scripts/agents/scrub-mac-paths.py "
                                   "to rewrite it, or make the path up):\n" + out.getvalue())

    def test_the_fixture_accounts_stay_a_short_list(self):
        # Adding a real account to the list would hide its paths from the check above.
        self.assertLessEqual(len(scrub.FIXTURE_ACCOUNTS), 10)
        for name in scrub.FIXTURE_ACCOUNTS:
            self.assertLess(len(name), 10, f"{name} does not look like a made-up account")


class TheCheckHasTeethTests(unittest.TestCase):
    """The check fails on each kind of path it is meant to stop, in a repository made for the test."""

    def check_finds(self, text):
        """Commits a file holding `text` in a temporary repository and returns the check's total for it."""
        with tempfile.TemporaryDirectory() as folder:
            repository = Path(folder) / "repository"
            repository.mkdir()
            for command in (["init", "-q", "-b", "main"], ["config", "user.email", "t@example.invalid"],
                            ["config", "user.name", "T"], ["config", "commit.gpgsign", "false"]):
                subprocess.run(["git", "-C", str(repository), *command], check=True, timeout=60)
            (repository / "file.md").write_text(text)
            subprocess.run(["git", "-C", str(repository), "add", "-A"], check=True, timeout=60)
            subprocess.run(["git", "-C", str(repository), "commit", "-q", "-m", "file"], check=True, timeout=60)
            # A Mac that is not this one, so the check is the generic one, as on GitHub's runner.
            machine = scrub.Machine("/Users/runner", "/Users/runner/work/app/app")
            counts, files, others, leaks = scrub.scan(repository, machine)
            return scrub.report(counts, files, others, leaks, out=io.StringIO())

    def test_a_real_looking_home_folder_fails(self):
        self.assertGreater(self.check_finds("see /Users/" + "jordan" + "/notes\n"), 0)

    def test_a_session_folder_fails(self):
        self.assertGreater(self.check_finds("in /private/tmp/claude-" + "123" + "/-Users-" + "jordan" + "-app/x\n"), 0)

    def test_a_long_temporary_folder_fails(self):
        self.assertGreater(self.check_finds("in /var/folders/" + "ab" + "/" + "q" * 30 + "/T/x\n"), 0)

    def test_a_project_folder_name_fails(self):
        self.assertGreater(self.check_finds("~/.claude/projects/-Users-" + "jordan" + "-app\n"), 0)

    def test_the_fixture_paths_pass(self):
        text = ("/Users/reader/Library/Mobile Documents/com~apple~CloudDocs/x /Users/x /Users/runner/work "
                "/var/folders/zz/T/x ~/.TextMouth ~/Library/CloudStorage /Volumes/Backup\n")
        self.assertEqual(self.check_finds(text), 0)


if __name__ == "__main__":
    unittest.main()
