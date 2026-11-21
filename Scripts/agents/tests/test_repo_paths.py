"""Tests of repo_paths.py, and of the root every tool takes from it.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Every repository here is a temporary one made with `git init`, and every home folder is
a temporary folder named by HOME, so nothing of the real checkout, the real lock, or the
real home folder is read or written. The tools are run in subprocesses, once from a copy
of Scripts/ in a repository's main checkout and once from the same copy in a linked
worktree of it, to prove each reaches the main checkout from both.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# repo_paths.py is beside this folder; python3 -I leaves both out of sys.path.
AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS))
import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

# The Scripts folder of the real repository, copied into the temporary ones.
SCRIPTS = AGENTS.parent

# Each tool, as its path under Scripts/, and what its roots must be: a function from the main
# checkout and the home folder to {the module's name for it: the path it must hold}.
TOOLS = {
    "agents/heavy_lock.py": lambda main, home: {
        "ROOT": main,
        "LOCK": main / "build" / "orchestrator" / "heavy-lock",
        "FIRST": main / "build" / "orchestrator" / "heavy-lock-first.json"},
    "agents/build-train.py": lambda main, home: {
        "ROOT": main,
        "TRAIN_DIR": main / "build" / "orchestrator" / "train",
        "WORKTREE": main / ".claude" / "worktrees" / "train"},
    "agents/wait-for-result.py": lambda main, home: {
        "RESULTS": main / "build" / "orchestrator" / "train" / "results"},
    "agents/agent-cost.py": lambda main, home: {
        "PROJECT": home / ".claude" / "projects" / repo_paths.claude_project_folder_name(main)},
    "agents/usage-watch-unscoped.py": lambda main, home: {
        "SCRIPT": home / ".claude" / "skills" / "claude-usage-left" / "scripts" / "claude_usage.py"},
    "agents/wait-for-usage-reset.py": lambda main, home: {
        "SCRIPT": home / ".claude" / "skills" / "claude-usage-left" / "scripts" / "claude_usage.py"},
    "ios/typecheck.py": lambda main, home: {
        "MAIN": main,
        "WORK_ROOT": main / "build" / "typecheck",
        "CHECKOUTS": main / "build" / "DerivedData" / "SourcePackages" / "checkouts"},
    "l10n/l10n.py": lambda main, home: {
        "MAIN": main,
        "OUTPUT": main / "build" / "l10n"},
    "test/markup-stack-proof.py": lambda main, home: {
        "MAIN": main,
        "OUT": main / "build" / "markup-stack"},
    "test/swiftsoup-corpus/run.py": lambda main, home: {
        "MAIN_CHECKOUT": main},
    "vendor/swiftsoup/make_vendor.py": lambda main, home: {
        "MAIN_CHECKOUT": main,
        "DEFAULT_SOURCE": main / "build" / "DerivedData" / "SourcePackages" / "checkouts" / "SwiftSoup"},
    "vendor/ffmpeg/build.py": lambda main, home: {
        "SHARED_ROOT": main / "build" / "ffmpeg",
        "SHARED_DOWNLOADS": main / "build" / "ffmpeg" / "download",
        "SHARED_SOURCES": main / "build" / "ffmpeg" / "source"},
}

# The program a subprocess runs to load a tool by its path and print the named module attributes as JSON.
LOADER = """
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("tool_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(json.dumps({name: str(getattr(module, name)) for name in sys.argv[2:]}))
"""


class RepositoryCase(unittest.TestCase):
    """A temporary repository with one commit, in a temporary folder that the test owns."""

    def git(self, *args, cwd=None):
        """Runs git in the repository (or `cwd`) and returns its trimmed output."""
        return subprocess.run(["git", "-C", str(cwd or self.main), *args], capture_output=True, text=True,
                              check=True, timeout=60).stdout.strip()

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        # git prints real paths (/private/var/... for /var/...), so the tests compare real paths.
        self.folder = Path(folder.name).resolve()
        self.main = self.folder / "main-checkout"
        self.main.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.invalid")
        self.git("config", "user.name", "T")
        self.git("config", "commit.gpgsign", "false")
        (self.main / "README.txt").write_text("a file\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "first")

    def add_worktree(self, name="linked-worktree"):
        """Adds a linked worktree of the repository on a new branch; returns its folder."""
        worktree = self.folder / name
        self.git("worktree", "add", "-q", "-b", name, str(worktree))
        return worktree


class MainCheckoutTests(RepositoryCase):
    """Finding the main checkout through git's common directory."""

    def test_the_main_checkout_is_found_from_its_top_folder_and_from_a_folder_inside_it(self):
        inside = self.main / "one" / "two"
        inside.mkdir(parents=True)
        self.assertEqual(repo_paths.main_checkout(self.main), self.main)
        self.assertEqual(repo_paths.main_checkout(inside), self.main)

    def test_a_file_stands_for_its_folder(self):
        self.assertEqual(repo_paths.main_checkout(self.main / "README.txt"), self.main)

    def test_a_linked_worktree_finds_the_main_checkout_not_itself(self):
        worktree = self.add_worktree()
        (worktree / "deep").mkdir()
        self.assertEqual(repo_paths.main_checkout(worktree), self.main)
        self.assertEqual(repo_paths.main_checkout(worktree / "deep"), self.main)

    def test_a_worktree_nested_inside_the_main_checkout_still_finds_it(self):
        # Agents' worktrees sit under the main checkout's .claude/worktrees.
        nested = self.main / ".claude" / "worktrees" / "agent"
        self.git("worktree", "add", "-q", "-b", "agent", str(nested))
        self.assertEqual(repo_paths.main_checkout(nested), self.main)

    def test_a_folder_outside_any_repository_raises_a_clear_error(self):
        outside = self.folder / "plain-folder"
        outside.mkdir()
        # A stray GIT_CEILING_DIRECTORIES keeps git from looking in the folders above the temporary one.
        with mock.patch.dict(os.environ, {"GIT_CEILING_DIRECTORIES": str(self.folder)}):
            with self.assertRaises(repo_paths.MainCheckoutNotFound) as caught:
                repo_paths.main_checkout(outside)
        self.assertIn("not inside a git repository", str(caught.exception))

    def test_variables_that_redirect_git_do_not_hide_the_answer(self):
        # A tool run inside a git hook inherits GIT_DIR; it must not send the answer elsewhere.
        other = self.folder / "other-repository"
        other.mkdir()
        with mock.patch.dict(os.environ, {"GIT_DIR": str(other / ".git"), "GIT_WORK_TREE": str(other)}):
            self.assertEqual(repo_paths.main_checkout(self.main), self.main)

    def test_the_default_start_is_the_folder_of_this_module(self):
        # The module is in Scripts/agents of a checkout or a worktree; both name the same main checkout.
        self.assertEqual(repo_paths.main_checkout(), repo_paths.main_checkout(repo_paths.HERE))


class ClaudeFoldersTests(unittest.TestCase):
    """Claude Code's folders, computed from the home folder and the main checkout's path."""

    def test_the_project_folder_name_changes_every_non_alphanumeric_character_to_a_hyphen(self):
        self.assertEqual(repo_paths.claude_project_folder_name(Path("/Users/reader/code/Text.Mouth_app")),
                         "-Users-reader-code-Text-Mouth-app")

    def test_a_hidden_folder_in_the_path_gives_a_double_hyphen(self):
        self.assertEqual(repo_paths.claude_project_folder_name(Path("/Users/reader/code/app/.claude/worktrees/x")),
                         "-Users-reader-code-app--claude-worktrees-x")

    def test_the_project_folder_is_under_the_home_folders_claude_projects(self):
        with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {"HOME": home}):
            self.assertEqual(repo_paths.claude_home(), Path(home) / ".claude")
            self.assertEqual(repo_paths.claude_project_dir(Path("/Users/reader/code/app")),
                             Path(home) / ".claude" / "projects" / "-Users-reader-code-app")
            self.assertEqual(repo_paths.claude_usage_script(),
                             Path(home) / ".claude" / "skills" / "claude-usage-left" / "scripts" / "claude_usage.py")

    def test_the_default_is_the_main_checkout(self):
        self.assertEqual(repo_paths.claude_project_folder_name(), repo_paths.claude_project_folder_name(repo_paths.main_checkout()))


class ToolRootTests(RepositoryCase):
    """Each tool takes its roots from the main checkout, whichever worktree it is run from."""

    def setUp(self):
        super().setUp()
        # A copy of Scripts/ without the briefs, the tests, and caches, committed in the main checkout.
        shutil.copytree(SCRIPTS, self.main / "Scripts",
                        ignore=shutil.ignore_patterns("briefs", "tests", "__pycache__"))
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "scripts")
        self.worktree = self.add_worktree()
        # A home folder of its own, so no tool reads the real one.
        self.home = self.folder / "home"
        self.home.mkdir()

    def roots_of(self, checkout, tool):
        """The roots the tool prints when run by its path in `checkout` (a main checkout or a worktree)."""
        script = checkout / "Scripts" / tool
        names = list(TOOLS[tool](self.main, self.home))
        environment = {"PATH": os.environ["PATH"], "HOME": str(self.home)}
        result = subprocess.run([sys.executable, "-I", "-B", "-c", LOADER, str(script), *names],
                                cwd=script.parent, env=environment, capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, f"{tool} did not load in {checkout}: {result.stderr}")
        return {name: Path(value) for name, value in json.loads(result.stdout).items()}

    def check_every_tool_from(self, checkout):
        """Asserts each tool's roots, run from `checkout`, are the main checkout's."""
        for tool, expected in TOOLS.items():
            with self.subTest(tool=tool, run_from=checkout.name):
                self.assertEqual(self.roots_of(checkout, tool), expected(self.main, self.home))

    def test_every_tool_reaches_the_main_checkout_from_the_main_checkout(self):
        self.check_every_tool_from(self.main)

    def test_every_tool_reaches_the_main_checkout_from_a_linked_worktree(self):
        # The heavy-work lock, the train's results, and the other shared state live in the main checkout only.
        self.check_every_tool_from(self.worktree)

    def test_every_tool_of_the_repository_is_in_the_table(self):
        # A new tool that took a root from git would need a row here: the scripts that import repo_paths are listed.
        importers = set()
        for path in SCRIPTS.rglob("*.py"):
            relative = path.relative_to(SCRIPTS)
            if relative.parts[0] == "agents" and relative.parts[1:2] in (("tests",), ("briefs",)):
                continue
            if "import repo_paths" in path.read_text(errors="replace") and path.name != "repo_paths.py":
                importers.add(relative.as_posix())
        # scrub-mac-paths.py takes the main checkout at run time, as a value (its tests are in test_scrub_mac_paths.py).
        importers -= {"agents/scrub-mac-paths.py"}
        self.assertEqual(importers - set(TOOLS), set(), "a tool that imports repo_paths is not in TOOLS")


if __name__ == "__main__":
    unittest.main()
