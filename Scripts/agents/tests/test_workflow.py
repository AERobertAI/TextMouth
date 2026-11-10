"""Tests of .github/workflows/test-build.yml: the safety rules the workflow must keep.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The repository is public, so what may start this workflow, what it may read, and what code it
may run matter. Python has no YAML reader in its standard library, so these tests read the file
as text: they check the lines that carry each rule, which the file's layout keeps simple.
"""
import re
import unittest
from pathlib import Path

import remote_case  # noqa: F401  (puts the scripts' folder on the path)
import github_run  # noqa: E402
import test_command  # noqa: E402

WORKFLOW = Path(test_command.AGENTS).parents[1] / ".github" / "workflows" / "test-build.yml"


class WorkflowTests(unittest.TestCase):
    """Reads the workflow once."""

    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        # The file without its comment lines, so that a rule named in a comment does not count as the rule.
        cls.code = "\n".join(line for line in cls.text.splitlines() if not line.lstrip().startswith("#"))

    def test_it_runs_for_a_push_to_testbuild_and_nothing_else(self):
        on = re.search(r"^on:\n((?:[ \t]+.*\n|\n)+)", self.code + "\n", re.M).group(1)
        self.assertEqual(re.findall(r"^  (\w+):", on, re.M), ["push"], on)
        self.assertEqual(re.findall(r"branches: \[(.*?)\]", on), [github_run.BRANCH])

    def test_it_never_runs_for_pull_requests_forks_or_with_pull_request_target(self):
        for forbidden in ("pull_request", "pull_request_target", "workflow_run", "issue_comment", "workflow_dispatch",
                          "schedule"):
            self.assertNotIn(forbidden, self.code)

    def test_the_token_may_only_read_and_no_secret_is_used(self):
        self.assertRegex(self.code, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^\s*permissions:", self.code)), 1, "no job may widen the permissions")
        self.assertNotIn("secrets.", self.code)
        self.assertNotIn("GITHUB_TOKEN", self.code)

    def test_every_action_is_githubs_own_and_pinned_to_a_full_commit_hash(self):
        uses = re.findall(r"uses:\s*(\S+)", self.code)
        self.assertGreaterEqual(len(uses), 3)
        for use in uses:
            with self.subTest(use=use):
                self.assertRegex(use, r"^actions/(checkout|cache/restore|cache/save|upload-artifact|download-artifact)@[0-9a-f]{40}$")

    def test_one_run_at_a_time_a_newer_push_cancels_an_older_run_and_the_job_has_a_time_limit(self):
        self.assertRegex(self.code, r"(?m)^concurrency:\n  group: test-build\n  cancel-in-progress: true\n")
        self.assertRegex(self.code, r"(?m)^    timeout-minutes: \d+\n")

    def test_the_job_runs_on_a_free_hosted_macos_runner_with_xcode_26(self):
        self.assertRegex(self.code, r"runs-on: macos-26\n")
        self.assertRegex(self.code, r'XCODE_VERSION: "26\.')

    def test_the_tests_run_through_the_shared_runner_and_the_project_is_generated_first(self):
        self.assertLess(self.code.index("make generate"), self.code.index("run-on-runner.py"))
        self.assertNotIn("xcodebuild test", self.code, "the test command comes from test_command.py alone")
        self.assertNotIn("run-area.py", self.code, "the test command comes from test_command.py alone")

    def job(self, name):
        """The text of one job of the workflow, from its heading to the next job's."""
        jobs = self.code.split("\njobs:\n")[1]
        parts = re.split(r"(?m)^  ([a-z]+):\n", jobs)
        # parts is ["", name, body, name, body, ...]
        return dict(zip(parts[1::2], parts[2::2]))[name]

    def test_there_are_three_jobs_plan_test_and_collect(self):
        self.assertEqual(re.findall(r"(?m)^  ([a-z]+):\n", self.code.split("\njobs:\n")[1]), ["plan", "test", "collect"])

    def test_only_the_test_job_uses_a_macos_runner_and_the_others_are_cheap_linux_jobs(self):
        self.assertIn("runs-on: macos-26", self.job("test"))
        for name in ("plan", "collect"):
            self.assertRegex(self.job(name), r"runs-on: ubuntu-24\.04\n")
            self.assertRegex(self.job(name), r"timeout-minutes: \d+\n")

    def test_the_shards_run_side_by_side_and_one_failing_does_not_cancel_the_others(self):
        test = self.job("test")
        self.assertIn("fail-fast: false", test)
        self.assertIn("needs: plan", test)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}", test)

    def test_the_join_runs_whether_the_shards_passed_failed_or_were_stopped(self):
        collect = self.job("collect")
        self.assertIn("needs: [plan, test]", collect)
        self.assertRegex(collect, r"if: \$\{\{ always\(\)")

    def test_the_results_are_uploaded_even_when_the_tests_fail(self):
        for name, artifact in (("test", "shard-results-"), ("collect", github_run.ARTIFACT)):
            with self.subTest(job=name):
                job = self.job(name)
                step = job[job.index(f"name: {artifact}") - 150:]
                self.assertIn("if: always()", step.split("path:")[0])
                self.assertRegex(job, r"retention-days: [1-9]\b")

    def test_the_artifact_the_mac_downloads_is_made_by_the_join_alone(self):
        self.assertNotIn(f"name: {github_run.ARTIFACT}\n", self.job("test"))
        self.assertIn(f"name: {github_run.ARTIFACT}\n", self.job("collect"))

    def test_the_result_bundle_is_uploaded_only_on_failure(self):
        job = self.job("test")
        bundle = job[job.index("Upload the result bundle"):]
        self.assertIn("if: failure()", bundle.split("path:")[0])

    def test_only_the_first_shard_saves_the_build_products_and_never_after_a_cancel(self):
        job = self.job("test")
        save = job[job.index("Save the build products"):]
        self.assertIn("if: ${{ !cancelled() && matrix.shard == 1 }}", save.split("uses:")[0])

    def test_the_build_products_are_restored_before_the_files_times_are_set_and_the_build_runs(self):
        job = self.job("test")
        order = [job.index(name) for name in ("Restore the build products", "Generate the Xcode project",
                                              "restore_mtimes.py", "run-on-runner.py")]
        self.assertEqual(order, sorted(order))

    def test_the_gate_workflow_check_yml_does_not_also_run_for_a_push_to_testbuild(self):
        # check.yml (make check) runs for every push to main and every pull request. A push to
        # TestBuild must start this workflow alone: two builds of one commit would waste a runner.
        check = (WORKFLOW.parent / "check.yml").read_text(encoding="utf-8")
        code = "\n".join(line for line in check.splitlines() if not line.lstrip().startswith("#"))
        on = re.search(r"^on:\n((?:[ \t]+.*\n|\n)+)", code + "\n", re.M).group(1)
        self.assertRegex(on, r"push:\n\s+branches: \[main\]", "check.yml must name the branches it runs for")
        self.assertNotIn(github_run.BRANCH, on)

    def test_the_workflow_is_named_as_github_run_looks_for_it(self):
        self.assertRegex(self.code, rf"(?m)^name: {re.escape(github_run.WORKFLOW_NAME)}\n")

    def test_the_request_path_is_the_one_the_mac_pushes(self):
        self.assertIn(github_run.REQUEST_PATH, self.code)


if __name__ == "__main__":
    unittest.main()
