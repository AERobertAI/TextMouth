"""Tests of runner_settings.py: the settings are written on a GitHub runner and nowhere else.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests
"""
import subprocess
import unittest

from remote_case import RemoteTestCase  # noqa: F401  (puts the scripts' folder on the path)
import runner_settings  # noqa: E402


class Recorder:
    """A stand-in for subprocess.run that records its commands and answers with a status."""

    def __init__(self, status=0, error=None):
        self.commands = []
        self.status = status
        self.error = error

    def __call__(self, command, **_):
        self.commands.append(command)
        if self.error:
            raise self.error
        return subprocess.CompletedProcess(command, self.status, "", "boom" if self.status else "")


class RunnerSettingsTests(unittest.TestCase):
    def test_nothing_is_written_off_a_github_runner(self):
        # The development Mac's own preferences must never be touched.
        for environment in ({}, {"GITHUB_ACTIONS": "false"}, {"GITHUB_ACTIONS": "1"}, {"CI": "true"}):
            with self.subTest(environment=environment):
                recorder = Recorder()
                self.assertEqual(runner_settings.apply(environment, run=recorder, say=lambda _: None), 0)
                self.assertEqual(recorder.commands, [])

    def test_keyboard_navigation_is_turned_on_for_all_controls_on_a_runner(self):
        recorder = Recorder()
        said = []
        self.assertEqual(runner_settings.apply({"GITHUB_ACTIONS": "true"}, run=recorder, say=said.append), 1)
        self.assertEqual(recorder.commands, [["defaults", "write", "NSGlobalDomain", "AppleKeyboardUIMode", "-int", "2"]])
        self.assertIn("written", said[0])

    def test_a_write_that_fails_is_reported_and_not_counted(self):
        said = []
        self.assertEqual(runner_settings.apply({"GITHUB_ACTIONS": "true"}, run=Recorder(status=1), say=said.append), 0)
        self.assertIn("NOT written", said[0])
        self.assertEqual(runner_settings.apply({"GITHUB_ACTIONS": "true"}, run=Recorder(error=OSError("no defaults")),
                                               say=said.append), 0)
        self.assertIn("no defaults", said[1])


if __name__ == "__main__":
    unittest.main()
