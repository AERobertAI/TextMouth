"""Tests of merge-chain.sh: the docs lint and the issue check before a merge commits, and the Markdown-only merge.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test makes a throwaway git repository in a temporary folder, with a copy of
the real merge-chain.sh and stand-ins for everything it calls: the build wrapper
(which only records that the suite ran), xcodegen (which does nothing), and
doclib.py (which records how it was called, and fails when the tree holds a file
named LINT-FAILS). The script changes to the repository it is run in, so these
tests never touch this checkout, build anything, or take the heavy-work lock.
"""
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

# The real script under test, beside this tests folder.
CHAIN = Path(__file__).resolve().parent.parent / "merge-chain.sh"

# The real skill in this checkout, which case 6 copies into the throwaway repository.
SKILL = Path(__file__).resolve().parents[3] / ".claude/skills/doc-library"

WRAPPER_PATH = ".claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh"
DOCLIB_PATH = ".claude/skills/doc-library/scripts/doclib.py"
ISSUELIB_PATH = ".claude/skills/issue-library/scripts/issuelib.py"

# The build wrapper: records one line, then prints what a green suite prints.
WRAPPER = """#!/bin/sh
echo "suite ran" >> "$SUITE_RECORD"
echo "Executed 1 tests, with 0 tests skipped and 0 failures"
echo "** TEST SUCCEEDED **"
"""

# The lint stand-in: records its arguments and whether a merge is in progress, fails on LINT-FAILS.
DOCLIB = '''import os, sys
with open(os.environ["LINT_RECORD"], "a") as record:
    record.write(" ".join(sys.argv[1:]) + " merge_head=" + str(os.path.exists(".git/MERGE_HEAD")) + "\\n")
sys.exit(1 if os.path.exists("LINT-FAILS") else 0)
'''

# The issue check stand-in: records its arguments (the snapshot's path as SNAPSHOT) and whether a
# merge is in progress. "check --json" prints main's problem when MAIN-PROBLEM exists; "check
# --new-since" fails on ISSUES-FAIL.
ISSUELIB = '''import json, os, sys
words = ["SNAPSHOT" if word.endswith(".json") else word for word in sys.argv[1:]]
with open(os.environ["ISSUES_RECORD"], "a") as record:
    record.write(" ".join(words) + " merge_head=" + str(os.path.exists(".git/MERGE_HEAD")) + "\\n")
if "--json" in sys.argv:
    if os.path.exists("MAIN-PROBLEM"):
        print(json.dumps({"path": "Issues/B90.md", "line": 1, "message": "main's own problem"}))
    sys.exit(1 if os.path.exists("MAIN-PROBLEM") else 0)
sys.exit(1 if os.path.exists("ISSUES-FAIL") else 0)
'''

# The real issue tracker in this checkout, and the doc-library modules its store reads markers with.
ISSUE_SKILL = Path(__file__).resolve().parents[3] / ".claude/skills/issue-library"
DOCMODEL_FILES = ("docmodel.py", "output.py", "sentences.py")


def issue_file(issue_id, related="", docs=""):
    """A valid open issue file for ``issue_id``, citing ``related`` and ``docs``."""
    return (f"---\nid: {issue_id}\ntitle: A bug\nkind: bug\nstatus: open\npriority: P2\nplatform: mac\n"
            f"assignee:\ncreated: 2026-11-16\nupdated: 2026-11-16\nfound-by: orchestrator\nbranch:\nmerged:\n"
            f"reason:\nrelated: {related}\ndocs: {docs}\nlabels:\n---\n\n## Description\n\nA bug.\n\n## Comments\n")


class MergeChainCase(unittest.TestCase):
    """A throwaway repository on main, with the stand-ins, and helpers to branch and run the chain."""

    def setUp(self):
        super().setUp()
        tmp = tempfile.TemporaryDirectory(prefix="merge-chain-test-")
        self.addCleanup(tmp.cleanup)
        # Resolved, since macOS's temporary folder is reached through a symlink.
        self.folder = Path(tmp.name).resolve()
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        self.logs = self.folder / "logs"
        self.suite_record = self.folder / "suite.txt"
        self.lint_record = self.folder / "lint.txt"
        self.issues_record = self.folder / "issues.txt"
        # An xcodegen that does nothing, found before any real one.
        bin_folder = self.folder / "bin"
        bin_folder.mkdir()
        self.write_executable(bin_folder / "xcodegen", "#!/bin/sh\nexit 0\n")
        self.env = dict(os.environ)
        self.env.update({
            "PATH": f"{bin_folder}:{os.environ['PATH']}",
            "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "chain test", "GIT_AUTHOR_EMAIL": "chain-test@example.invalid",
            "GIT_COMMITTER_NAME": "chain test", "GIT_COMMITTER_EMAIL": "chain-test@example.invalid",
            "MERGE_LOG_DIR": str(self.logs), "SUITE_RECORD": str(self.suite_record),
            "LINT_RECORD": str(self.lint_record), "ISSUES_RECORD": str(self.issues_record),
            # The real lint, run in the throwaway repository, must leave no __pycache__ there.
            "PYTHONDONTWRITEBYTECODE": "1",
        })

    @staticmethod
    def write_executable(path, text):
        """Write ``text`` to ``path`` (making folders) and mark the file executable."""
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def git(self, *arguments):
        """Run one git command in the throwaway repository; return its standard output."""
        result = subprocess.run(["git", *arguments], cwd=self.repo, env=self.env,
                                capture_output=True, text=True, check=True)
        return result.stdout

    def write_files(self, files):
        """Write each ``{relative path: text}`` into the repository."""
        for relative, text in files.items():
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)

    def make_repo(self, with_doclib=True, with_issuelib=False, files=None):
        """Make the repository: main with the chain script, the stand-ins, a code file, a page, and ``files``."""
        self.git("init", "-q", "-b", "main")
        self.write_executable(self.repo / "Scripts/agents/merge-chain.sh", CHAIN.read_text())
        self.write_executable(self.repo / WRAPPER_PATH, WRAPPER)
        if with_doclib:
            self.write_files({DOCLIB_PATH: DOCLIB})
        if with_issuelib:
            self.write_files({ISSUELIB_PATH: ISSUELIB})
        self.write_files(files or {})
        self.write_files({"App.swift": "let a = 1\n", "docs/page.md": "# Page\n\nText.\n"})
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")

    def make_branch(self, name, files):
        """Branch ``name`` from main with ``files`` written in one commit, then return to main."""
        self.git("switch", "-q", "-c", name)
        self.write_files(files)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", f"work on {name}")
        self.git("switch", "-q", "main")

    def message_file(self, name):
        """A merge message file for branch ``name``; returns the ``name:file`` spec the chain takes."""
        path = self.folder / f"{name}.msg"
        path.write_text(f"Merge {name}\n\nWhat {name} does.\n\nCo-Authored-By: Chain Test <noreply@example.invalid>\n")
        return f"{name}:{path}"

    def run_chain(self, *names):
        """Run the repository's copy of merge-chain.sh for the branches; returns (status, standard output).

        The copy is run as the orchestrator runs it, by its own path, so its
        first line must name its shell.
        """
        result = subprocess.run(
            ["./Scripts/agents/merge-chain.sh", *[self.message_file(name) for name in names]],
            cwd=self.repo, env=self.env, capture_output=True, text=True, timeout=60)
        return result.returncode, result.stdout + result.stderr

    def log_text(self, name):
        """The log the chain wrote for the merge of branch ``name``."""
        return (self.logs / f"main-after-{name}-merge.log").read_text()

    def lint_calls(self):
        """The lines the doclib stand-in recorded."""
        return self.lint_record.read_text().splitlines() if self.lint_record.exists() else []

    def issue_checks(self):
        """The lines the issuelib stand-in recorded."""
        return self.issues_record.read_text().splitlines() if self.issues_record.exists() else []

    def suite_runs(self):
        """How many times the build wrapper stand-in ran."""
        return len(self.suite_record.read_text().splitlines()) if self.suite_record.exists() else 0

    def tip(self):
        """main's tip commit."""
        return self.git("rev-parse", "main").strip()


class IssueCheckTests(MergeChainCase):
    """The issue check: run on main and on the uncommitted merge; a problem the branch brings stops it."""

    def test_the_check_notes_mains_problems_then_runs_on_the_uncommitted_merge(self):
        self.make_repo(with_issuelib=True)
        self.make_branch("code", {"App.swift": "let a = 2\n"})
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.issue_checks(), ["check --json merge_head=False", "check --new-since SNAPSHOT merge_head=True"])
        self.assertEqual((self.logs / "main-before-code-issues.json").read_text(), "")
        self.assertIn("ISSUES_CHECK_OK", self.log_text("code"))
        self.assertIn("ISSUES_CHECK_OK", out, "the summary should show the check's line")
        self.assertEqual(self.suite_runs(), 1)

    def test_a_problem_the_branch_brings_aborts_the_merge_and_stops_the_chain(self):
        self.make_repo(with_issuelib=True)
        self.make_branch("bad", {"ISSUES-FAIL": "", "App.swift": "let a = 3\n"})
        before = self.tip()
        status, out = self.run_chain("bad")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after bad", out)
        self.assertEqual(self.tip(), before)
        self.assertFalse((self.repo / ".git/MERGE_HEAD").exists(), "the merge was left in progress")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertIn("ISSUES_CHECK_FAILED", self.log_text("bad"))
        self.assertEqual(self.suite_runs(), 0)

    def test_a_problem_main_had_already_does_not_switch_the_check_off(self):
        self.make_repo(with_issuelib=True, files={"MAIN-PROBLEM": ""})
        self.make_branch("code", {"App.swift": "let a = 4\n"})
        self.make_branch("bad", {"ISSUES-FAIL": "", "Other.swift": "let b = 6\n"})
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertIn("ISSUES_CHECK_OK", self.log_text("code"))
        self.assertIn("main's own problem", (self.logs / "main-before-code-issues.json").read_text())
        status, out = self.run_chain("bad")
        self.assertEqual(status, 1, out)
        self.assertIn("ISSUES_CHECK_FAILED", self.log_text("bad"))

    def test_a_tree_without_the_skill_skips_the_check(self):
        self.make_repo()
        self.make_branch("code", {"App.swift": "let a = 5\n"})
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.issue_checks(), [])
        self.assertIn("ISSUES_CHECK_SKIPPED", self.log_text("code"))


class RealIssueCheckTests(MergeChainCase):
    """The chain with the real issue tracker: the problems a merge brings stop it, and others do not."""

    def make_repo_with_the_real_tracker(self):
        """main with the tracker's scripts, an issue whose related names nothing, and an issue citing a doc section."""
        self.make_repo(files={
            "Issues/README.md": "# Issues\n",
            "Issues/B90.md": issue_file("B90", related="B99"),
            "Issues/B92.md": issue_file("B92", docs="page-top"),
            "docs/page.md": "# Page\n<!-- id: page-top -->\n\nText.\n",
        })
        shutil.copytree(ISSUE_SKILL, self.repo / ".claude/skills/issue-library", ignore=shutil.ignore_patterns(
            "tests", "__pycache__"))
        for name in DOCMODEL_FILES:
            shutil.copy2(SKILL / "scripts" / name, self.repo / ".claude/skills/doc-library/scripts" / name)
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "the tracker")

    def test_mains_own_problem_and_one_in_a_file_the_merge_left_alone_do_not_stop_it(self):
        self.make_repo_with_the_real_tracker()
        # The branch renames the section B92 cites: B92's problem is in a file the merge does not change.
        self.make_branch("docs", {"docs/page.md": "# Page\n<!-- id: page-head -->\n\nText.\n", "App.swift": "let a = 7\n"})
        status, out = self.run_chain("docs")
        self.assertEqual(status, 0, out)
        self.assertIn("ISSUES_CHECK_OK", self.log_text("docs"))
        self.assertIn("related B99 names no issue file", (self.logs / "main-before-docs-issues.json").read_text())

    def test_a_problem_in_a_file_the_merge_changes_stops_it(self):
        self.make_repo_with_the_real_tracker()
        self.make_branch("bad", {"Issues/B91.md": issue_file("B91").replace("found-by: orchestrator\n", ""),
                                 "App.swift": "let a = 8\n"})
        before = self.tip()
        status, out = self.run_chain("bad")
        self.assertEqual(status, 1, out)
        self.assertIn("ISSUES_CHECK_FAILED", self.log_text("bad"))
        self.assertIn("Issues/B91.md:1: missing field found-by", self.log_text("bad"))
        self.assertEqual(self.tip(), before)


class MergeChainTests(MergeChainCase):
    """The chain on a code branch, a failing lint, a Markdown-only branch, and no skill."""

    def test_a_code_branch_is_merged_after_the_lint_ran_on_the_uncommitted_merge_and_the_suite_runs(self):
        self.make_repo()
        self.make_branch("code", {"App.swift": "let a = 2\n"})
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertIn("CHAIN_COMPLETE", out)
        # main's tip is the merge commit, with the message file's subject and both parents.
        self.assertEqual(self.git("log", "-1", "--format=%s", "main").strip(), "Merge code")
        self.assertEqual(len(self.git("log", "-1", "--format=%P", "main").split()), 2)
        # The lint saw the merge in progress, called as the hook must call it.
        self.assertEqual(self.lint_calls(), ["lint --against HEAD merge_head=True"])
        self.assertEqual(self.suite_runs(), 1)
        self.assertIn("DOCS_LINT_OK", self.log_text("code"))
        self.assertIn("DOCS_LINT_OK", out, "the summary should show the lint line")

    def test_a_failing_lint_aborts_the_merge_and_stops_the_chain(self):
        self.make_repo()
        self.make_branch("bad", {"LINT-FAILS": "", "App.swift": "let a = 3\n"})
        before = self.tip()
        status, out = self.run_chain("bad")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after bad", out)
        self.assertNotIn("CHAIN_COMPLETE", out)
        self.assertEqual(self.tip(), before)
        self.assertFalse((self.repo / ".git/MERGE_HEAD").exists(), "the merge was left in progress")
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertFalse((self.repo / "LINT-FAILS").exists())
        self.assertEqual(self.suite_runs(), 0)
        self.assertIn("DOCS_LINT_FAILED", self.log_text("bad"))
        self.assertIn("DOCS_LINT_FAILED", out)

    def test_a_markdown_only_branch_is_merged_with_the_lint_and_no_suite(self):
        self.make_repo()
        self.make_branch("docs", {"docs/page.md": "# Page\n\nNew text.\n", "docs/other.md": "# Other\n"})
        status, out = self.run_chain("docs")
        self.assertEqual(status, 0, out)
        self.assertIn("CHAIN_COMPLETE", out)
        self.assertEqual(self.git("log", "-1", "--format=%s", "main").strip(), "Merge docs")
        self.assertEqual(self.lint_calls(), ["lint --against HEAD merge_head=True"])
        self.assertEqual(self.suite_runs(), 0)
        self.assertIn("MARKDOWN_ONLY_NO_SUITE", self.log_text("docs"))
        self.assertIn("MARKDOWN_ONLY_NO_SUITE", out)

    def test_a_branch_changing_markdown_and_code_still_runs_the_suite(self):
        self.make_repo()
        self.make_branch("both", {"docs/page.md": "# Page\n\nNew text.\n", "App.swift": "let a = 4\n"})
        status, out = self.run_chain("both")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.suite_runs(), 1)
        self.assertNotIn("MARKDOWN_ONLY_NO_SUITE", self.log_text("both"))

    def test_a_tree_without_the_skill_skips_the_lint_and_runs_the_suite(self):
        self.make_repo(with_doclib=False)
        self.make_branch("code", {"App.swift": "let a = 2\n"})
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.lint_calls(), [])
        self.assertEqual(self.suite_runs(), 1)
        self.assertIn("DOCS_LINT_SKIPPED", self.log_text("code"))
        self.assertIn("DOCS_LINT_SKIPPED", out)

    def test_the_chain_stops_before_the_second_branch_when_the_first_fails_the_lint(self):
        self.make_repo()
        self.make_branch("first", {"LINT-FAILS": ""})
        self.make_branch("second", {"App.swift": "let a = 5\n"})
        before = self.tip()
        status, out = self.run_chain("first", "second")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after first", out)
        self.assertEqual(self.tip(), before)
        self.assertEqual(len(self.lint_calls()), 1, "the second branch should never reach the lint")
        self.assertFalse((self.logs / "main-after-second-merge.log").exists())

    def test_a_conflict_in_any_other_file_aborts_the_merge_before_the_lint(self):
        self.make_repo()
        self.make_branch("clash", {"App.swift": "let a = 6\n"})
        self.write_files({"App.swift": "let a = 7\n"})
        self.git("commit", "-q", "-am", "main changes the same line")
        before = self.tip()
        status, out = self.run_chain("clash")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after clash", out)
        self.assertEqual(self.tip(), before)
        self.assertFalse((self.repo / ".git/MERGE_HEAD").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.lint_calls(), [])

    def test_a_branch_that_is_already_merged_is_skipped_and_the_chain_goes_on(self):
        self.make_repo()
        self.make_branch("code", {"App.swift": "let a = 2\n"})
        self.assertEqual(self.run_chain("code")[0], 0)
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertIn("CHAIN_COMPLETE", out)
        self.assertEqual(self.suite_runs(), 1, "an already merged branch should not run the suite again")

    def test_an_unknown_branch_stops_the_chain(self):
        self.make_repo()
        before = self.tip()
        status, out = self.run_chain("nosuchbranch")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after nosuchbranch", out)
        self.assertEqual(self.tip(), before)
        self.assertEqual(self.suite_runs(), 0)


class RealLintTests(MergeChainCase):
    """The chain with the real doc-library skill, and a baseline the real lint made."""

    def make_repo_with_the_real_lint(self):
        """Make the repository with a copy of the skill, a docs page, and a baseline from ``lint --update-baseline``."""
        self.make_repo(with_doclib=False)
        # The skill's code and word list, not its tests or the real baseline (the lint makes its own).
        shutil.copytree(SKILL, self.repo / ".claude/skills/doc-library", ignore=shutil.ignore_patterns(
            "tests", "__pycache__", "lint-baseline.json"))
        self.write_files({"README.md": "# Index\n\n- [Page](docs/page.md) the page\n"})
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "the skill")
        made = subprocess.run(["python3", "-I", DOCLIB_PATH, "lint", "--update-baseline"],
                              cwd=self.repo, env=self.env, capture_output=True, text=True)
        self.assertEqual(made.returncode, 0, made.stdout + made.stderr)
        self.assertTrue((self.repo / ".claude/skills/doc-library/lint-baseline.json").is_file())
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "the baseline")

    def test_a_branch_that_adds_a_sales_word_is_stopped_by_the_real_lint_and_a_code_branch_is_merged(self):
        self.make_repo_with_the_real_lint()
        self.make_branch("salesy", {"docs/page.md": "# Page\n\nThe seamless reader.\n"})
        self.make_branch("code", {"App.swift": "let a = 2\n"})
        before = self.tip()
        status, out = self.run_chain("salesy")
        self.assertEqual(status, 1, out)
        self.assertIn("CHAIN_STOPPED after salesy", out)
        self.assertIn("sales-word", out, "the failure should show what got worse")
        self.assertIn("DOCS_LINT_FAILED", self.log_text("salesy"))
        self.assertEqual(self.tip(), before)
        self.assertFalse((self.repo / ".git/MERGE_HEAD").exists())
        self.assertEqual(self.git("status", "--porcelain"), "")
        self.assertEqual(self.suite_runs(), 0)
        status, out = self.run_chain("code")
        self.assertEqual(status, 0, out)
        self.assertIn("DOCS_LINT_OK", self.log_text("code"))
        self.assertEqual(self.suite_runs(), 1)

    def test_a_docs_branch_that_breaks_no_rule_is_merged_without_the_suite(self):
        self.make_repo_with_the_real_lint()
        self.make_branch("docs", {"docs/page.md": "# Page\n\nSomething more to say.\n"})
        status, out = self.run_chain("docs")
        self.assertEqual(status, 0, out)
        self.assertIn("DOCS_LINT_OK", self.log_text("docs"))
        self.assertIn("MARKDOWN_ONLY_NO_SUITE", self.log_text("docs"))
        self.assertEqual(self.suite_runs(), 0)


if __name__ == "__main__":
    unittest.main()
