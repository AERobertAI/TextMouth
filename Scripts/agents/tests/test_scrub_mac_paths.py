"""Tests of scrub-mac-paths.py: finding and rewriting the paths that belong to one Mac.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The Mac in these tests is made up (MACHINE), and every repository is a temporary one, so the
real home folder, checkout, and temporary folder are never read. The made-up account, temporary
folder ID, and user ID are joined from pieces, so the policy test (test_no_mac_paths.py), which reads
this file too, sees no real-looking path in it.
"""
import importlib.util
import io
import os
import stat
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

# A made-up Mac. The account is not on the list of fixture accounts, so its paths count as a real one's.
ACCOUNT = "dev" + "-account"
HOME = "/Users/" + ACCOUNT
MAIN = HOME + "/code/work/swift/app"
TMP_ID = "q" * 10 + "0123456789" + "_" * 4 + "z" * 6
TMPDIR = "/var/folders/" + "ab" + "/" + TMP_ID + "/T/"
UID = "7" + "42"
SESSION = "/private/tmp/claude-" + UID + "/" + "-Users-" + ACCOUNT + "-code-work-swift-app" + "/" + "0a1b2c3d-4e5f-6789-abcd-ef0123456789"
MACHINE = scrub.Machine(HOME, MAIN, TMPDIR, int(UID))


def rewritten(text, machine=MACHINE):
    """The text with the machine's paths rewritten."""
    return scrub.scrub_text(text, scrub.rules_for(machine))[0]


class RewriteTests(unittest.TestCase):
    """What each kind of path becomes."""

    def test_the_main_checkout_in_full_with_a_tilde_and_with_home_becomes_one_token(self):
        for form in (MAIN, "~/code/work/swift/app", "$HOME/code/work/swift/app", "${HOME}/code/work/swift/app"):
            with self.subTest(form=form):
                self.assertEqual(rewritten(f"cd {form}/build && ls"), "cd <main checkout>/build && ls")

    def test_a_worktree_under_the_main_checkout_keeps_its_own_part(self):
        self.assertEqual(rewritten(f"{MAIN}/.claude/worktrees/agent-1"), "<main checkout>/.claude/worktrees/agent-1")

    def test_a_session_folder_becomes_a_token_and_its_scratchpad_stays(self):
        self.assertEqual(rewritten(f"Write to `{SESSION}/scratchpad/a.txt`."),
                         "Write to `<session folder>/scratchpad/a.txt`.")

    def test_a_session_folder_without_the_private_prefix_is_found_too(self):
        self.assertEqual(rewritten(SESSION.replace("/private", "") + "/x"), "<session folder>/x")

    def test_the_project_folder_name_becomes_a_token(self):
        self.assertEqual(rewritten("~/.claude/projects/-Users-" + ACCOUNT + "-code-work-swift-app/abc.jsonl"),
                         "~/.claude/projects/<project folder>/abc.jsonl")

    def test_the_temporary_folder_becomes_tmpdir_with_or_without_the_private_prefix(self):
        self.assertEqual(rewritten(TMPDIR + "Build-1/log.txt"), "$TMPDIR/Build-1/log.txt")
        self.assertEqual(rewritten("/private" + TMPDIR.rstrip("/") + "/x"), "$TMPDIR/x")

    def test_any_other_path_under_the_home_folder_becomes_a_tilde_path(self):
        self.assertEqual(rewritten(f"{HOME}/Downloads/book.epub"), "~/Downloads/book.epub")
        self.assertEqual(rewritten(f"in {HOME}."), "in ~.")

    def test_the_folder_of_the_checkouts_neighbours_is_elided(self):
        self.assertEqual(rewritten("~/code/work/scratch/harness/"), "~/…/scratch/harness/")
        self.assertEqual(rewritten(f"{HOME}/code/work/scratch/x"), "~/…/scratch/x")

    def test_a_longer_name_that_starts_like_the_checkout_is_not_the_checkout(self):
        # The checkout's rule needs the whole name; the neighbours' rule still takes the folder it is in.
        self.assertEqual(rewritten(f"{MAIN}-old/x"), "~/…/swift/app-old/x")

    def test_the_standard_macos_paths_and_other_text_are_left_alone(self):
        for text in ("~/.TextMouth/Library", "~/Library/CloudStorage/Drive", "/Volumes/Backup/x",
                     "/Users/reader/Documents", "/Users/runner/work", "/var/folders/zz/T/x", "$TMPDIR/x", "nothing here"):
            with self.subTest(text=text):
                self.assertEqual(rewritten(text), text)

    def test_rewriting_twice_changes_nothing_more(self):
        text = f"{MAIN}/a {SESSION}/b {TMPDIR}c {HOME}/d ~/code/work/swift/app/e"
        once = rewritten(text)
        self.assertEqual(rewritten(once), once)

    def test_each_path_counts_once_under_the_first_rule_that_takes_it(self):
        _, counts = scrub.scrub_text(f"{MAIN}/a {SESSION}/b {TMPDIR}c {HOME}/d", scrub.rules_for(MACHINE))
        self.assertEqual(dict(counts), {scrub.REPOSITORY: 1, scrub.SESSION: 1, scrub.TEMP: 1, scrub.HOME: 1})

    def test_a_made_up_home_folder_gets_no_home_or_checkout_rules(self):
        # GitHub's runner is such a machine: its paths in the repository are fixtures. Its temporary folder still counts.
        runner = scrub.Machine("/Users/runner", "/Users/runner/work/app/app", TMPDIR, 501)
        self.assertEqual(rewritten("/Users/runner/work/app/app/x", runner), "/Users/runner/work/app/app/x")
        self.assertEqual(rewritten(TMPDIR + "x", runner), "$TMPDIR/x")


class OtherAccountsTests(unittest.TestCase):
    """The paths no rule can rewrite by name, which the check reports."""

    def test_a_real_looking_account_is_reported(self):
        stranger = "/Users/" + "somebody-else"
        self.assertEqual(scrub.other_accounts_paths(f"see {stranger}/notes"), [stranger])

    def test_the_fixture_accounts_and_placeholders_are_not(self):
        text = "/Users/reader /Users/x/y /Users/someone /Users/runner/work /Users/Shared /Users/<you> /Users/$USER"
        self.assertEqual(scrub.other_accounts_paths(text), [])

    def test_a_project_folder_name_of_another_account_is_reported(self):
        stranger = "-Users-" + "stranger" + "-"
        self.assertEqual(scrub.other_accounts_paths(f"{stranger}code-app"), [stranger])

    def test_a_session_folder_or_a_long_temporary_folder_is_reported(self):
        self.assertEqual(len(scrub.other_accounts_paths("/tmp/claude-" + "9" + "/abc")), 1)
        self.assertEqual(len(scrub.other_accounts_paths(TMPDIR)), 1)

    def test_the_short_fixture_temporary_folders_are_not(self):
        self.assertEqual(scrub.other_accounts_paths("/var/folders/zz/T/x /var/folders/xy/T /var/folders/zz/xx"), [])


class NamesTests(unittest.TestCase):
    """This Mac's names that are secret wherever they stand."""

    def test_the_account_the_temporary_folders_id_and_the_checkouts_place_are_names(self):
        self.assertEqual(MACHINE.names(), [ACCOUNT, TMP_ID, "code/work/swift/app"])

    def test_a_made_up_home_folder_has_no_names(self):
        self.assertEqual(scrub.Machine("/Users/runner", "/Users/runner/work/app/app", TMPDIR, 501).names(), [])

    def test_a_short_account_name_is_left_out_as_it_would_match_ordinary_words(self):
        short = scrub.Machine("/Users/" + "ann", "/Users/" + "ann/code/work/app", None, 501)
        self.assertEqual(short.names(), ["code/work/app"])

    def test_a_checkout_directly_under_the_home_folder_has_no_place_name(self):
        self.assertEqual(scrub.Machine(HOME, HOME + "/app", None, 501).names(), [ACCOUNT])


class RepositoryCase(unittest.TestCase):
    """A temporary repository whose tracked files hold this made-up Mac's paths."""

    FILES = {
        "notes.md": f"Build in {MAIN}/build, scratch in {SESSION}/scratchpad.\n",
        "dir/script.py": f'TMP = "{TMPDIR}x"  # home {HOME}/Downloads\n',
        "clean.txt": "nothing to see\n",
    }

    def git(self, *args):
        """Runs git in the repository and returns its trimmed output."""
        return subprocess.run(["git", "-C", str(self.root), *args], capture_output=True, text=True, check=True,
                              timeout=60).stdout.strip()

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name) / "repository"
        self.root.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "T")
        self.git("config", "commit.gpgsign", "false")
        for name, text in self.FILES.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        # A file with invalid UTF-8 and Windows line ends, which must come back byte for byte but for its path.
        (self.root / "odd.txt").write_bytes(b"caf\xe9 \r\n" + f"{HOME}/x\r\n".encode() + b"\xff\xfe end\r\n")
        # A binary file that holds the path's bytes, and an executable script.
        (self.root / "blob.bin").write_bytes(b"\0" + HOME.encode() + b"\0")
        (self.root / "run.sh").write_text(f"#!/bin/sh\necho {HOME}\n")
        (self.root / "run.sh").chmod(0o755)
        (self.root / "link.txt").symlink_to("notes.md")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "files")
        # An untracked file with a path in it: not in the repository, so not for the script to touch.
        (self.root / "untracked.txt").write_text(f"{HOME}/private\n")

    def read(self, name):
        """A file's bytes."""
        return (self.root / name).read_bytes()

    def run_main(self, *argv):
        """Runs the script's main on the repository; returns its exit status and what it printed."""
        out = io.StringIO()
        status = scrub.main(list(argv), machine=MACHINE, root=self.root, out=out)
        return status, out.getvalue()


class CheckTests(RepositoryCase):
    """--check: counts by kind, and no change."""

    def test_check_reports_counts_by_kind_and_exits_one(self):
        before = {name: self.read(name) for name in ("notes.md", "dir/script.py", "odd.txt")}
        status, output = self.run_main("--check")
        self.assertEqual(status, 1)
        self.assertIn("session folder: 1 paths in 1 files", output)
        self.assertIn("repository location: 1 paths in 1 files", output)
        self.assertIn("temporary folder: 1 paths in 1 files", output)
        # The home folder's rule takes the other home paths: script.py's, odd.txt's, and run.sh's.
        self.assertIn("other path under the home folder: 3 paths in 3 files", output)
        self.assertTrue(output.rstrip().endswith("found"))
        for name, data in before.items():
            self.assertEqual(self.read(name), data, f"--check changed {name}")

    def test_check_with_list_names_each_file(self):
        _, output = self.run_main("--check", "--list")
        self.assertIn("    notes.md", output)
        self.assertIn("    dir/script.py", output)
        self.assertNotIn("clean.txt", output)

    def test_check_exits_zero_on_a_clean_repository(self):
        self.run_main()
        status, output = self.run_main("--check")
        self.assertEqual(status, 0)
        self.assertTrue(output.rstrip().endswith("clean"))

    def test_a_pathspec_limits_the_files_looked_at(self):
        status, output = self.run_main("--check", "dir")
        self.assertEqual(status, 1)
        self.assertIn("repository location: 0 paths", output)
        self.assertIn("temporary folder: 1 paths in 1 files", output)

    def test_this_macs_name_outside_a_path_is_reported_without_being_printed(self):
        (self.root / "chat.md").write_text(f"Thanks, {ACCOUNT}, the ID {TMP_ID} is odd.\n")
        self.git("add", "chat.md")
        for argv in (["--check"], []):
            status, output = self.run_main(*argv)
            self.assertEqual(status, 1, f"{argv}: a name no rule can rewrite leaves it for a person")
            self.assertIn("this Mac's names outside a path: 2 in 1 files", output)
            self.assertIn("chat.md: 2 name(s) of this Mac", output)
            self.assertNotIn(ACCOUNT, output)
            self.assertNotIn(TMP_ID, output)
        self.assertIn(ACCOUNT, (self.root / "chat.md").read_text(), "the script does not guess at a name")

    def test_another_accounts_path_is_reported_and_left_in_place(self):
        stranger = "/Users/" + "stranger"
        (self.root / "other.md").write_text(f"in {stranger}/x\n")
        self.git("add", "other.md")
        status, output = self.run_main()
        self.assertEqual(status, 1, "a path the script cannot rewrite leaves it for a person")
        self.assertIn(f"other.md: {stranger}", output)
        self.assertEqual((self.root / "other.md").read_text(), f"in {stranger}/x\n")


class WriteTests(RepositoryCase):
    """The writing mode: tracked text files rewritten in place, and nothing else touched."""

    def setUp(self):
        super().setUp()
        self.tracked_before = self.git("ls-files").splitlines()
        self.run_main()

    def test_tracked_text_files_hold_tokens_afterwards(self):
        self.assertEqual((self.root / "notes.md").read_text(),
                         "Build in <main checkout>/build, scratch in <session folder>/scratchpad.\n")
        self.assertEqual((self.root / "dir/script.py").read_text(), 'TMP = "$TMPDIR/x"  # home ~/Downloads\n')
        self.assertEqual((self.root / "run.sh").read_text(), "#!/bin/sh\necho ~\n")

    def test_a_file_without_a_path_is_not_rewritten(self):
        self.assertEqual((self.root / "clean.txt").read_text(), "nothing to see\n")
        self.assertNotIn("clean.txt", self.git("diff", "--name-only").splitlines())

    def test_bytes_that_are_not_text_come_back_as_they_were(self):
        self.assertEqual(self.read("odd.txt"), b"caf\xe9 \r\n~/x\r\n\xff\xfe end\r\n")

    def test_a_binary_file_untracked_file_and_link_are_left_alone(self):
        self.assertEqual(self.read("blob.bin"), b"\0" + HOME.encode() + b"\0")
        self.assertEqual((self.root / "untracked.txt").read_text(), f"{HOME}/private\n")
        self.assertTrue((self.root / "link.txt").is_symlink())
        self.assertEqual(os.readlink(self.root / "link.txt"), "notes.md")

    def test_a_files_mode_is_kept(self):
        self.assertTrue(stat.S_IMODE((self.root / "run.sh").stat().st_mode) & 0o111, "run.sh lost its execute bit")

    def test_no_file_is_deleted(self):
        for name in self.tracked_before + ["untracked.txt"]:
            self.assertTrue(os.path.lexists(self.root / name), f"{name} is gone")

    def test_a_second_run_changes_nothing(self):
        before = {name: self.read(name) for name in self.tracked_before if not (self.root / name).is_symlink()}
        status, output = self.run_main()
        self.assertEqual(status, 0)
        self.assertEqual({name: self.read(name) for name in before}, before)


if __name__ == "__main__":
    unittest.main()
