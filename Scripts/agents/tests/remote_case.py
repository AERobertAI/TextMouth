"""remote_case.py: a base class for tests of the GitHub runs, with a fake `gh` and a fake remote.

Nothing here reaches GitHub. A test gets:

- a throwaway repository (`self.repo`) with a commit on `main`, standing for the
  checkout a train or a suite pushes from;
- a bare throwaway repository (`self.remote`) as github_run.PUSH_REMOTE, so
  `git push` is real but goes to a folder in the temporary directory, where the
  test can read exactly what was pushed. A test that needs a push to fail points
  PUSH_REMOTE at a folder that does not exist;
- a stand-in for `gh` (`self.gh`) as github_run.GH: a small Python program that
  answers `gh run list`, `gh run view` and `gh run download` from a state file
  the test writes, and logs every call it gets;
- github_run's clock and pause replaced, so that no test waits for real: the
  pause advances a pretend clock.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS))
import github_run  # noqa: E402  (imported by path, after sys.path is set)

# The stand-in for `gh`. It reads state.json beside itself:
#   "list":     the answers to `run list`, one per call (the last repeats); "@SHA" in a
#               run's headSha stands for the commit the call asked for
#   "view":     the answers to `run view`, the same way
#   "download": the answers to `run download`, the same way: {"files": {name: text}},
#               or {"fail": true}
#   "fail":     a command word (such as "list") to answer with an error
# and appends each call's arguments to "calls".
FAKE_GH = r'''#!/usr/bin/env python3
import json, sys
from pathlib import Path

here = Path(__file__).resolve().parent
state = json.loads((here / "state.json").read_text())
arguments = sys.argv[1:]
state.setdefault("calls", []).append(arguments)


def next_answer(key):
    """The next queued answer for `key`; the last one is answered again and again."""
    queue = state.get(key, [])
    if not queue:
        return None
    if len(queue) > 1:
        state[key] = queue[1:]
    return queue[0]


def finish(code):
    (here / "state.json").write_text(json.dumps(state))
    sys.exit(code)


word = arguments[1] if len(arguments) > 1 else ""
if state.get("fail") == word:
    print("gh: simulated failure", file=sys.stderr)
    finish(1)
if word == "list":
    sha = arguments[arguments.index("--commit") + 1] if "--commit" in arguments else ""
    runs = next_answer("list") or []
    print(json.dumps([{**run, "headSha": sha if run.get("headSha") == "@SHA" else run.get("headSha")} for run in runs]))
elif word == "view":
    print(json.dumps(next_answer("view") or {}))
elif word == "download":
    answer = next_answer("download") or {"fail": True}
    if answer.get("fail"):
        print("no artifact", file=sys.stderr)
        finish(1)
    folder = Path(arguments[arguments.index("-D") + 1])
    folder.mkdir(parents=True, exist_ok=True)
    for name, text in answer["files"].items():
        (folder / name).write_text(text)
finish(0)
'''

# A run as `gh run list` shows one that has just started, and as it shows it done.
STARTED = {"databaseId": 7001, "status": "in_progress", "conclusion": "", "headSha": "@SHA",
           "url": "https://github.example/runs/7001", "workflowName": "Test build"}
# A result summary and log, as the runner uploads them.
PASSING_SUMMARY = "Executed 12 tests, with 0 failures\nPASSED in 41 seconds\n"
PASSING_LOG = ("Test Suite 'Selected tests' passed at 2026-11-09 10:00:00.000.\n"
               "\t Executed 12 tests, with 0 failures (0 unexpected) in 4.0 (4.5) seconds\n")
FAILING_SUMMARY = ("Executed 12 tests, with 1 failures\n"
                   "FAILED FooTests.testBar at Foo.swift:9: wrong\nFAILED in 41 seconds\n")
FAILING_LOG = ("Test Suite 'Selected tests' failed at 2026-11-09 10:00:00.000.\n"
               "\t Executed 12 tests, with 1 failures (0 unexpected) in 4.0 (4.5) seconds\n** TEST FAILED **\n")


def results(summary, log):
    """A `gh run download` answer holding the runner's two files."""
    return {"files": {"run-summary.txt": summary, "run.log": log}}


class RemoteTestCase(unittest.TestCase):
    """Points github_run at a fake gh, a throwaway repository, and a fake remote."""

    def git(self, *args, cwd=None):
        """Runs git in the throwaway repository (or `cwd`); returns its output."""
        return subprocess.run(["git", *args], cwd=cwd or self.repo, capture_output=True, text=True,
                              check=True).stdout.strip()

    def commit(self, name, text=None):
        """Commits a file `name` holding `text` (by default its name); returns the commit."""
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text((text or name) + "\n")
        self.git("add", "-f", name)
        self.git("commit", "-q", "-m", f"Add {name}")
        return self.git("rev-parse", "HEAD")

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.repo = self.folder / "repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "remote@example.invalid")
        self.git("config", "user.name", "Remote Test")
        self.git("config", "commit.gpgsign", "false")
        self.head = self.commit("base.txt")
        self.remote = self.folder / "remote.git"
        self.git("init", "-q", "--bare", "-b", "main", str(self.remote))
        self.gh = self.folder / "bin" / "gh"
        self.gh.parent.mkdir()
        self.gh.write_text(FAKE_GH)
        self.gh.chmod(0o755)
        self.gh_state({})
        # Pretend time: each pause moves the clock on, and nothing really waits.
        self.now = 0.0
        self.pauses = []
        self.patch_github(PUSH_REMOTE=str(self.remote), GH=str(self.gh), CLOCK=lambda: self.now,
                          SLEEP=self.pause)
        # The real remote and the real gh must be out of reach, whatever a test does.
        self.assertTrue(github_run.PUSH_REMOTE.startswith(str(self.folder)))
        self.assertTrue(github_run.GH.startswith(str(self.folder)))

    def pause(self, seconds):
        """The fake pause: advances the pretend clock and notes the pause."""
        self.pauses.append(seconds)
        self.now += seconds

    def patch_github(self, **values):
        """Sets each of `values` on github_run for this test only."""
        for name, value in values.items():
            self.addCleanup(setattr, github_run, name, getattr(github_run, name))
            setattr(github_run, name, value)

    def gh_state(self, state):
        """Writes the fake gh's state (see FAKE_GH)."""
        (self.gh.parent / "state.json").write_text(json.dumps(state))

    def gh_calls(self):
        """The arguments of every call the fake gh has had, in order."""
        return json.loads((self.gh.parent / "state.json").read_text()).get("calls", [])

    def pushed_refs(self):
        """The refs of the fake remote: {ref name: commit}."""
        lines = self.git("for-each-ref", "--format=%(refname) %(objectname)", cwd=self.remote).splitlines()
        return dict(line.split() for line in lines)

    def pushed_request(self, commit):
        """The request file in the tree of `commit`, as the fake remote holds it."""
        return json.loads(self.git("show", f"{commit}:{github_run.REQUEST_PATH}", cwd=self.remote))
