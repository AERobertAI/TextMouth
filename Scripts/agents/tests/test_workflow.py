"""Tests of the workflows that run the suite on GitHub: the safety rules they must keep.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Three files make the run (the first two are workflows):
- .github/workflows/test-build.yml  the caller for a push to the branch TestBuild;
- .github/workflows/tests.yml       the jobs themselves (plan, test shards, iPhone build, join), which
                                    check.yml, the reproducibility gate on main, calls too;
- .github/actions/setup-xcode/action.yml  the Xcode and XcodeGen every macOS job sets up.

The repository is public, so what may start these workflows, what they may read, and what code they
may run matter. Python has no YAML reader in its standard library, so these tests read the files
as text: they check the lines that carry each rule, which the files' layout keeps simple.
"""
import re
import unittest
from pathlib import Path

import remote_case  # noqa: F401  (puts the scripts' folder on the path)
import github_run  # noqa: E402
import test_command  # noqa: E402

REPO = Path(test_command.AGENTS).parents[1]
WORKFLOWS = REPO / ".github" / "workflows"
CALLER = WORKFLOWS / "test-build.yml"
JOBS = WORKFLOWS / "tests.yml"
CHECK = WORKFLOWS / "check.yml"
SETUP_ACTION = REPO / ".github" / "actions" / "setup-xcode" / "action.yml"


def code_of(path):
    """The file without its comment lines, so that a rule named in a comment does not count as the rule."""
    text = path.read_text(encoding="utf-8")
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def job_of(code, name):
    """The text of one job of a workflow, from its heading to the next job's."""
    jobs = code.split("\njobs:\n")[1]
    parts = re.split(r"(?m)^  ([a-z]+):\n", jobs)
    # parts is ["", name, body, name, body, ...]
    return dict(zip(parts[1::2], parts[2::2]))[name]


def trigger_of(code):
    """The text under a workflow's `on:`."""
    return re.search(r"^on:\n((?:[ \t]+.*\n|\n)+)", code + "\n", re.M).group(1)


class CallerTests(unittest.TestCase):
    """test-build.yml: what starts a run on TestBuild, and what keeps runs from touching each other's."""

    @classmethod
    def setUpClass(cls):
        cls.code = code_of(CALLER)

    def test_it_runs_for_a_push_to_testbuild_and_nothing_else(self):
        on = trigger_of(self.code)
        self.assertEqual(re.findall(r"^  (\w+):", on, re.M), ["push"], on)
        self.assertEqual(re.findall(r"branches: \[(.*?)\]", on), [github_run.BRANCH])

    def test_it_never_runs_for_pull_requests_forks_or_with_pull_request_target(self):
        for forbidden in ("pull_request", "pull_request_target", "workflow_run", "issue_comment", "workflow_dispatch",
                          "schedule"):
            self.assertNotIn(forbidden, self.code)

    def test_the_token_may_only_read_and_no_secret_is_used(self):
        self.assertRegex(self.code, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^\s*permissions:", self.code)), 1, "no job may widen the permissions")
        self.assertNotIn("secrets", self.code)
        self.assertNotIn("GITHUB_TOKEN", self.code)

    def test_one_run_at_a_time_a_newer_push_cancels_an_older_run(self):
        self.assertRegex(self.code, r"(?m)^concurrency:\n  group: test-build\n  cancel-in-progress: true\n")

    def test_its_one_job_calls_the_shared_jobs_and_nothing_else(self):
        self.assertEqual(re.findall(r"(?m)^  ([a-z]+):\n", self.code.split("\njobs:\n")[1]), ["run"])
        self.assertEqual(re.findall(r"uses:\s*(\S+)", self.code), ["./.github/workflows/tests.yml"])
        self.assertNotIn("with:", self.code, "a push to TestBuild takes its request from the pushed commit")

    def test_the_workflow_is_named_as_github_run_looks_for_it(self):
        self.assertRegex(self.code, rf"(?m)^name: {re.escape(github_run.WORKFLOW_NAME)}\n")

    def test_the_gate_workflow_check_yml_does_not_also_run_for_a_push_to_testbuild(self):
        # check.yml (make check) runs for every push to main and every pull request. A push to
        # TestBuild must start this workflow alone: two builds of one commit would waste a runner.
        on = trigger_of(code_of(CHECK))
        self.assertRegex(on, r"push:\n\s+branches: \[main\]", "check.yml must name the branches it runs for")
        self.assertNotIn(github_run.BRANCH, on)

    def test_a_check_run_can_never_cancel_a_run_on_testbuild(self):
        # A concurrency group cancels the runs of its own name only: check.yml's must differ from this one's.
        groups = re.findall(r"(?m)^\s+group: (.*)$", code_of(CHECK))
        self.assertTrue(groups)
        for group in groups:
            self.assertNotIn("test-build", group)


class JobsTests(unittest.TestCase):
    """tests.yml: the jobs the suite runs as, for a push to TestBuild and for the gate."""

    @classmethod
    def setUpClass(cls):
        cls.code = code_of(JOBS)

    def job(self, name):
        return job_of(self.code, name)

    def test_it_is_called_by_other_workflows_and_starts_by_nothing_else(self):
        on = trigger_of(self.code)
        self.assertEqual(re.findall(r"^  (\w+):", on, re.M), ["workflow_call"], on)
        for forbidden in ("pull_request", "push:", "workflow_dispatch", "schedule", "workflow_run"):
            self.assertNotIn(forbidden, self.code)

    def test_it_has_no_concurrency_group_of_its_own(self):
        # A group in a called workflow can cancel the runs of whichever workflow calls it.
        self.assertNotIn("concurrency", self.code)

    def test_the_token_may_only_read_and_no_secret_is_used(self):
        self.assertRegex(self.code, r"(?m)^permissions:\n  contents: read\n")
        self.assertEqual(len(re.findall(r"(?m)^\s*permissions:", self.code)), 1, "no job may widen the permissions")
        self.assertNotIn("secrets", self.code)
        self.assertNotIn("GITHUB_TOKEN", self.code)

    def test_every_action_is_githubs_own_and_pinned_to_a_full_commit_hash_or_the_repositorys_own_setup(self):
        uses = re.findall(r"uses:\s*(\S+)", self.code)
        self.assertGreaterEqual(len(uses), 5)
        for use in uses:
            with self.subTest(use=use):
                self.assertRegex(use, r"^(actions/(checkout|cache/restore|cache/save|upload-artifact|download-artifact)"
                                      r"@[0-9a-f]{40}|\./\.github/actions/setup-xcode)$")

    def test_the_request_given_as_an_input_or_planned_reaches_a_job_only_through_the_environment(self):
        # Text of the request must never be part of a script, where a quote or a $( ) in it would be code.
        for place in re.finditer(r"\$\{\{\s*(inputs\.request-json|needs\.plan\.outputs\.request)\s*\}\}", self.code):
            line = self.code[self.code.rfind("\n", 0, place.start()) + 1:self.code.index("\n", place.end())]
            with self.subTest(line=line.strip()):
                self.assertRegex(line, r"^\s+REQUEST_JSON: \$\{\{", "the request may only be set as an environment value")

    def test_there_are_four_jobs_plan_test_ios_and_collect(self):
        self.assertEqual(re.findall(r"(?m)^  ([a-z]+):\n", self.code.split("\njobs:\n")[1]),
                         ["plan", "test", "ios", "collect"])

    def test_only_the_test_and_iphone_jobs_use_a_macos_runner_and_the_others_are_cheap_linux_jobs(self):
        for name in ("test", "ios"):
            self.assertIn("runs-on: macos-26", self.job(name))
        for name in ("plan", "collect"):
            self.assertRegex(self.job(name), r"runs-on: ubuntu-24\.04\n")
        for name in ("plan", "test", "ios", "collect"):
            self.assertRegex(self.job(name), r"timeout-minutes: \d+\n")

    def test_the_macos_jobs_set_up_the_pinned_xcode_through_the_one_local_action(self):
        for name in ("test", "ios"):
            self.assertIn("uses: ./.github/actions/setup-xcode", self.job(name))
        self.assertNotIn("xcodegen.zip", self.code, "the toolchain is pinned in the local action alone")
        self.assertNotIn("XCODE_VERSION", self.code)

    def test_the_tests_run_through_the_shared_runner_and_the_project_is_generated_first(self):
        self.assertLess(self.code.index("make generate"), self.code.index("run-on-runner.py"))
        self.assertNotIn("xcodebuild test", self.code, "the test command comes from test_command.py alone")
        self.assertNotIn("run-area.py", self.code, "the test command comes from test_command.py alone")

    def test_the_shards_run_side_by_side_and_one_failing_does_not_cancel_the_others(self):
        test = self.job("test")
        self.assertIn("fail-fast: false", test)
        self.assertIn("needs: plan", test)
        self.assertIn("matrix: ${{ fromJSON(needs.plan.outputs.matrix) }}", test)

    def test_the_join_waits_for_the_shards_and_the_iphone_build_and_runs_whether_they_passed_failed_or_were_stopped(self):
        collect = self.job("collect")
        self.assertIn("needs: [plan, test, ios]", collect)
        self.assertRegex(collect, r"if: \$\{\{ always\(\)")

    def test_the_results_are_uploaded_even_when_the_tests_fail(self):
        for name, artifact in (("test", "shard-results-"), ("ios", "ios-results"), ("collect", github_run.ARTIFACT)):
            with self.subTest(job=name):
                job = self.job(name)
                step = job[job.index(f"name: {artifact}") - 300:]
                self.assertIn("if: always()", step.split("path:")[0])
                self.assertRegex(job, r"retention-days: [1-9]\b")

    def test_the_iphone_builds_upload_is_tried_again_once_and_neither_try_can_fail_the_job(self):
        # Run 42932008427: "Failed to CreateArtifact ... ETIMEDOUT" from GitHub left the iPhone build NOT RUN.
        ios = self.job("ios")
        first = ios[ios.index("name: Upload the iPhone build's results\n"):ios.index("name: Upload the iPhone build's results again")]
        again = ios[ios.index("name: Upload the iPhone build's results again"):]
        self.assertIn("id: upload", first)
        self.assertIn("continue-on-error: true", first.split("uses:")[0])
        self.assertIn("continue-on-error: true", again.split("uses:")[0])
        self.assertIn("steps.upload.outcome == 'failure'", again.split("uses:")[0])
        for attempt in (first, again):
            self.assertIn("name: ios-results", attempt)

    def test_the_artifact_the_mac_downloads_is_made_by_the_join_alone(self):
        self.assertNotIn(f"name: {github_run.ARTIFACT}\n", self.job("test"))
        self.assertNotIn(f"name: {github_run.ARTIFACT}\n", self.job("ios"))
        self.assertIn(f"name: {github_run.ARTIFACT}\n", self.job("collect"))

    def test_the_join_passes_the_iphone_builds_files_on_to_the_mac(self):
        collect = self.job("collect")
        for name in ("ios-summary.txt", "ios-errors.txt"):
            self.assertIn(f"build/remote/{name}", collect)

    def test_the_join_passes_the_interface_tests_files_on_to_the_mac(self):
        collect = self.job("collect")
        for name in ("ios-ui-summary.txt", "ios-ui.log"):
            self.assertIn(f"build/remote/{name}", collect)
        ios = self.job("ios")
        for name in ("ios-ui-summary.txt", "ios-ui.log"):
            self.assertEqual(ios.count(f"build/remote-ios/{name}"), 2, f"both tries of the upload carry {name}")

    def test_the_iphone_job_writes_the_request_then_builds_then_runs_the_interface_tests_after_the_build(self):
        ios = self.job("ios")
        order = [ios.index(text) for text in ("Write the request", "Download the iOS platform", "run-ios-build.py",
                                               "Restart the audio service", "run-ios-ui-tests.py", "Did the build finish?")]
        self.assertEqual(order, sorted(order), "the steps are out of order")

    def test_the_interface_tests_step_runs_unless_cancelled_and_sets_nothing_itself(self):
        ios = self.job("ios")
        step = ios[ios.index("name: Run the iPhone interface tests"):]
        step = step[:step.index("\n\n")]
        self.assertIn("if: ${{ !cancelled() }}", step)
        self.assertNotIn("env:", step, "the step sets no variable; the script alone lets a test make sound")
        self.assertNotIn("TEXTMOUTH_UI_SOUND", ios, "the workflow does not name the sound variable in code")

    def test_the_request_reaches_the_iphone_job_only_through_the_environment(self):
        ios = self.job("ios")
        step = ios[ios.index("name: Write the request"):]
        step = step[:step.index("\n\n")]
        self.assertIn("REQUEST_JSON: ${{ needs.plan.outputs.request }}", step)
        self.assertIn("""printf '%s\\n' "$REQUEST_JSON" > .github/test-request.json""", step)

    def test_a_failed_interface_test_fails_only_the_iphone_job_and_the_join_still_runs(self):
        # The script exits 1 for a failed test; the later steps are not skipped, and the join runs whatever its needs did.
        ios = self.job("ios")
        for name in ("Did the build finish?", "Save the build products", "Upload the iPhone build's results"):
            step = ios[ios.index(f"name: {name}"):]
            self.assertRegex(step.split("uses:")[0].split("run:")[0], r"if: (\$\{\{ )?(!cancelled\(\)|always\(\))", name)
        self.assertIn("needs: [plan, test, ios]", self.job("collect"))
        between = ios[ios.index("name: Run the iPhone interface tests"):ios.index("name: Did the build finish?")]
        self.assertNotIn("continue-on-error", between, "a failed interface test must fail the job")

    def test_the_interface_tests_result_bundle_is_uploaded_only_on_failure(self):
        ios = self.job("ios")
        bundle = ios[ios.index("name: Upload the interface tests' result bundle"):]
        self.assertIn("if: ${{ failure() }}", bundle.split("uses:")[0])
        self.assertIn("path: build/remote-ios/ios-ui-result.xcresult", bundle)

    def scripts_constants(self):
        """The limits the two iPhone scripts hold, as {script: module}."""
        import importlib.util
        modules = {}
        for name in ("run-ios-build.py", "run-ios-ui-tests.py"):
            spec = importlib.util.spec_from_file_location("limits_" + name[:-3].replace("-", "_"), test_command.AGENTS / name)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            modules[name] = module
        return modules

    def step_limit(self, ios, step_name):
        """The `timeout-minutes` of the step called `step_name`, or None when it has none."""
        step = ios[ios.index(f"name: {step_name}"):]
        step = step.split("\n      - name:")[0]
        found = re.search(r"timeout-minutes: (\d+)", step)
        return int(found.group(1)) if found else None

    def test_the_interface_tests_step_has_a_limit_that_holds_the_scripts_whole_run(self):
        # The script cuts its tests' limit by the set-up's time (STEP_BUDGET_MINUTES), so that it can write its results
        # before the runner stops the step; that budget and the kill's grace must fit in the step's limit.
        ui = self.scripts_constants()["run-ios-ui-tests.py"]
        step = self.step_limit(self.job("ios"), "Run the iPhone interface tests")
        self.assertEqual(step, 45)
        self.assertLessEqual(ui.STEP_BUDGET_MINUTES + 1, step, "the budget and a minute's margin fit the step")
        self.assertEqual(ui.DEFAULT_LIMIT_MINUTES, 35)
        # The set-up's worst case: every simctl call at its limit and the boot's wait; the tests keep a useful time after it.
        setup = (ui.SETUP_SIMCTL_CALLS * ui.SIMCTL_SECONDS + ui.BOOT_SECONDS) / 60
        left = ui.STEP_BUDGET_MINUTES - setup - ui.KILL_GRACE_SECONDS / 60
        self.assertGreaterEqual(left, ui.LEAST_TEST_MINUTES, "a set-up in which every call used its whole limit leaves no time for tests")

    def test_the_iphone_job_has_room_for_every_steps_limit_added_up(self):
        # The platform download, the build and its grace, and the interface tests' step (set-up, tests, and the kill's grace),
        # each at its limit, must fit in the job's.
        modules = self.scripts_constants()
        ios = self.job("ios")
        job = int(re.search(r"timeout-minutes: (\d+)", ios).group(1))
        download = self.step_limit(ios, "Download the iOS platform")
        build = modules["run-ios-build.py"].DEFAULT_LIMIT_MINUTES + 1
        tests = self.step_limit(ios, "Run the iPhone interface tests")
        self.assertGreaterEqual(job, download + build + tests, "the job's limit is under the sum of its steps' limits")

    def test_the_result_bundle_is_uploaded_only_on_failure(self):
        job = self.job("test")
        bundle = job[job.index("Upload the result bundle"):]
        self.assertIn("if: failure()", bundle.split("path:")[0])

    def test_only_the_first_shard_saves_the_build_products_and_never_after_a_cancel(self):
        job = self.job("test")
        save = job[job.index("Save the build products"):]
        self.assertIn("!cancelled() && matrix.shard == 1 &&", save.split("uses:")[0])

    def test_each_cache_is_one_a_day_saved_only_on_a_miss_and_without_the_logs_folder(self):
        for name, derived in (("test", "build/remote-DerivedData"), ("ios", "build/remote-DerivedData-ios")):
            with self.subTest(job=name):
                job = self.job(name)
                keys = [line.strip() for line in job.splitlines() if line.strip().startswith("key:")]
                self.assertEqual(len(keys), 2, "a restore and a save")
                for key in keys:
                    self.assertIn("steps.day.outputs.day", key)
                    self.assertNotIn("github.sha", key, "a key that changes with every push fills the cache")
                for step in ("Restore the build products", "Save the build products"):
                    part = job[job.index(step):]
                    part = part[:part.index("key:")]
                    self.assertIn(f"!{derived}/Logs", part, f"{step} must leave the Logs folder out")
                save = job[job.index("Save the build products"):]
                self.assertIn("steps.cache.outputs.cache-hit != 'true'", save.split("uses:")[0])

    def test_a_days_cache_is_saved_only_from_a_build_that_finished(self):
        # The cache is one a day and never saved again once it exists: the first probe run of November 10 lacked the
        # iOS platform, stopped after 20 seconds, saved that, and kept the day's real build from being saved.
        for name in ("test", "ios"):
            with self.subTest(job=name):
                job = self.job(name)
                finished = job[job.index("Did the build finish?"):]
                self.assertIn("if: ${{ !cancelled() }}", finished.split("run:")[0], "it must run after a failed step too")
                save = job[job.index("Save the build products"):]
                self.assertIn("steps.built.outputs.finished == 'true'", save.split("uses:")[0])
                self.assertLess(job.index("Did the build finish?"), job.index("Save the build products"))

    def test_the_two_jobs_caches_have_names_of_their_own(self):
        keys = re.findall(r"key: (build-[a-z]+(?:-[a-z]+)?)-", self.code)
        self.assertEqual(sorted(set(keys)), ["build-ios", "build-test-build"])

    def test_a_cold_request_uses_no_cache_in_either_job(self):
        for name in ("test", "ios"):
            job = self.job(name)
            for step in ("Restore the build products", "Save the build products", "Keep unchanged files looking unchanged"):
                part = job[job.index(step):]
                self.assertIn("needs.plan.outputs.cold != 'true'", part.split("uses:")[0].split("run:")[0], f"{name}: {step}")

    def test_the_build_products_are_restored_before_the_files_times_are_set_and_the_build_runs(self):
        job = self.job("test")
        order = [job.index(name) for name in ("Restore the build products", "Generate the Xcode project",
                                              "restore_mtimes.py", "run-on-runner.py")]
        self.assertEqual(order, sorted(order))

    def test_the_iphone_build_is_the_shared_script_and_a_request_can_leave_it_out(self):
        ios = self.job("ios")
        self.assertIn("run-ios-build.py", ios)
        self.assertIn("if: ${{ needs.plan.outputs.ios == 'true' }}", ios.split("runs-on:")[0])
        self.assertNotIn("xcodebuild", ios.replace("xcodebuild -showsdks", "").replace("xcodebuild -downloadPlatform iOS", ""),
                         "the build command lives in run-ios-build.py")
        self.assertIn("xcodebuild -downloadPlatform iOS", ios.split("run-ios-build.py")[0], "the platform comes before the build")

    def test_the_request_path_is_the_one_the_mac_pushes(self):
        self.assertIn(github_run.REQUEST_PATH, self.code)


class GateTests(unittest.TestCase):
    """check.yml: the reproducibility gate keeps every check it made, through the shared jobs."""

    @classmethod
    def setUpClass(cls):
        cls.code = code_of(CHECK)

    def test_the_gate_still_regenerates_resolves_and_builds_release_and_leaves_the_suite_to_the_shards(self):
        gate = job_of(self.code, "gate")
        self.assertIn("run: make check CHECK_ARGS=--without-tests", gate)
        self.assertIn("run: make check-selftest", gate)
        self.assertIn("timeout-minutes: 60", gate)

    def test_the_suite_is_the_shared_jobs_asked_for_the_full_suite_cold_strict_and_without_warnings(self):
        import json
        suite = job_of(self.code, "suite")
        self.assertIn("uses: ./.github/workflows/tests.yml", suite)
        request = json.loads(re.search(r"request-json: '(.*)'", suite).group(1))
        self.assertEqual(request["areas"], ["all"], "every test of the scheme, dealt out among the shards")
        self.assertTrue(request["full"])
        self.assertTrue(request["cold"], "xcodebuild reports a file's warnings only when it compiles that file")
        self.assertTrue(request["no_warnings"])
        self.assertTrue(request["strict_performance"])
        self.assertFalse(request["ios"], "the gate's checks are the project, the pins, Release, and the suite")
        self.assertGreaterEqual(request["shards"], 2)

    def test_the_suite_runs_for_pushes_and_for_pull_requests_of_this_repository_but_not_for_forks(self):
        # The call starts 5 macOS jobs, which GitHub runs at once; a fork's pull request could keep TestBuild waiting.
        suite = job_of(self.code, "suite")
        self.assertIn(
            "if: ${{ github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository }}",
            suite.split("uses:")[0])

    def test_the_gate_job_still_runs_for_every_pull_request(self):
        self.assertNotIn("if:", job_of(self.code, "gate").split("steps:")[0])

    def test_the_comments_say_what_is_true_of_forks_and_of_the_baselines(self):
        # A comment is the only place these are said, so they are pinned as text (code_of drops comments).
        check = CHECK.read_text(encoding="utf-8")
        jobs = JOBS.read_text(encoding="utf-8")
        self.assertNotIn("Nothing runs for a pull request's fork here", jobs)
        self.assertIn("not for one from a fork", jobs)
        self.assertIn("not from a fork", check)
        self.assertIn("no baseline is checked here", check, "strict baselines run only on the Mac model that recorded them")
        self.assertNotIn("a busy machine does not skip them", check)
        for weaker in ("runner-skips.conf", "KF8HostileFileTests", "-onlyUsePackageVersionsFromResolvedFile"):
            self.assertIn(weaker, check, f"the ways the suite is weaker than make check's must be said: {weaker}")

    def test_the_gate_workflow_repeats_neither_the_toolchain_nor_the_suites_jobs(self):
        self.assertNotIn("xcodegen.zip", self.code)
        self.assertNotIn("run-on-runner.py", self.code)
        self.assertEqual(self.code.count("uses: ./.github/actions/setup-xcode"), 1)

    def test_the_token_may_only_read(self):
        self.assertRegex(self.code, r"(?m)^permissions:\n  contents: read\n")
        self.assertNotIn("secrets", self.code)


class SetupActionTests(unittest.TestCase):
    """The local action every macOS job sets up its toolchain with."""

    @classmethod
    def setUpClass(cls):
        cls.code = code_of(SETUP_ACTION)

    def test_it_pins_xcode_and_checks_the_xcodegen_download_against_its_digest(self):
        self.assertRegex(self.code, r'XCODE_VERSION: "26\.')
        self.assertRegex(self.code, r"XCODEGEN_SHA256: [0-9a-f]{64}")
        self.assertIn("shasum -a 256 --check", self.code)

    def test_it_uses_no_other_action_and_no_secret(self):
        self.assertEqual(re.findall(r"uses:\s*(\S+)", self.code), [])
        self.assertNotIn("secrets", self.code)

    def test_it_is_a_composite_action_whose_every_run_step_names_its_shell(self):
        self.assertIn("using: composite", self.code)
        self.assertEqual(self.code.count("run: |"), self.code.count("shell: bash"))


if __name__ == "__main__":
    unittest.main()
