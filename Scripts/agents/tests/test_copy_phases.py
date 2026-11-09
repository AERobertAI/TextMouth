"""Tests of copy_phases.py: two projects' copy-files phases compared by meaning.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The projects are small made-up pbxproj texts written in a temporary folder; the
real project is never read.
"""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from heavy_lock_case import AGENTS
from pbxproj_fixtures import phase, project
import copy_phases  # noqa: E402  (imported by path, after sys.path is set by heavy_lock_case)

SCRIPT = AGENTS / "copy_phases.py"


class CopyPhasesTests(unittest.TestCase):
    """The phases() reading, and the command line around it."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def write_project(self, name, text):
        """Writes a project text under the temporary folder; returns its path as a string."""
        path = self.folder / name
        # Guard: only files under the temporary folder are written.
        self.assertTrue(str(path).startswith(str(self.folder)))
        path.write_text(text, encoding="utf-8")
        return str(path)

    def run_script(self, *paths):
        """Runs the script on project paths; returns the finished process."""
        return subprocess.run([sys.executable, "-I", "-B", str(SCRIPT), *paths],
                              capture_output=True, text=True, timeout=30)

    def compare(self, first, second):
        """Runs the script on two project texts; returns (exit status, output)."""
        result = self.run_script(self.write_project("first.pbxproj", first),
                                 self.write_project("second.pbxproj", second))
        return result.returncode, result.stdout

    def test_projects_that_differ_only_in_phase_order_and_identifiers_are_the_same(self):
        licenses = ("Licenses/liblouis", ["README", "COPYING.LESSER"])
        tables = ("Tables", ["en.ctb", "de.ctb"])
        one = project(phase("AAAA1111", licenses[0], licenses[1]), phase("BBBB2222", tables[0], tables[1]))
        # The other writes the phases in the opposite order, with other identifiers and the files shuffled.
        two = project(phase("CCCC3333", tables[0], tables[1][::-1]), phase("DDDD4444", licenses[0], licenses[1][::-1]))
        status, output = self.compare(one, two)
        self.assertEqual(status, 0, output)
        self.assertEqual(output.strip(), "same by meaning")

    def test_a_phase_whose_files_changed_is_different(self):
        one = project(phase("AAAA1111", "Tables", ["en.ctb", "de.ctb"]))
        two = project(phase("AAAA1111", "Tables", ["en.ctb", "fr.ctb"]))
        status, output = self.compare(one, two)
        self.assertEqual(status, 1, output)
        self.assertIn("DIFFERENT", output)
        self.assertIn("only in first:", output)
        self.assertIn("only in second:", output)

    def test_a_phase_whose_destination_changed_is_different(self):
        one = project(phase("AAAA1111", "Tables", ["en.ctb"]))
        two = project(phase("AAAA1111", "Licenses", ["en.ctb"]))
        status, output = self.compare(one, two)
        self.assertEqual(status, 1, output)
        self.assertIn("DIFFERENT", output)

    def test_a_phase_whose_destination_folder_kind_changed_is_different(self):
        one = project(phase("AAAA1111", "Tables", ["en.ctb"], spec=7))
        two = project(phase("AAAA1111", "Tables", ["en.ctb"], spec=1))
        self.assertEqual(self.compare(one, two)[0], 1)

    def test_two_phases_that_swapped_their_files_are_different(self):
        # The failure that once broke a build: one phase's destination paired with another's files.
        one = project(phase("AAAA1111", "Tables", ["en.ctb"]), phase("BBBB2222", "Licenses", ["README"]))
        two = project(phase("AAAA1111", "Tables", ["README"]), phase("BBBB2222", "Licenses", ["en.ctb"]))
        self.assertEqual(self.compare(one, two)[0], 1)

    def test_a_phase_gained_or_lost_is_different(self):
        one = project(phase("AAAA1111", "Tables", ["en.ctb"]))
        two = project(phase("AAAA1111", "Tables", ["en.ctb"]), phase("BBBB2222", "Licenses", ["README"]))
        status, output = self.compare(one, two)
        self.assertEqual(status, 1)
        self.assertIn("only in second:", output)

    def test_one_project_prints_its_phases_sorted(self):
        text = project(phase("BBBB2222", "Tables", ["b", "a"]), phase("AAAA1111", "Licenses", ["README"]))
        result = self.run_script(self.write_project("one.pbxproj", text))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(),
                         ["('7', 'Licenses', 'CopyFiles', ('README',))", "('7', 'Tables', 'CopyFiles', ('a', 'b'))"])

    def test_phases_reads_the_destination_files_and_kind(self):
        found = copy_phases.phases(project(phase("AAAA1111", '"Licenses/x y"', ["README"], spec=16)))
        self.assertEqual(found, {("16", "Licenses/x y", "CopyFiles", ("README",))})

    def test_no_arguments_is_refused(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage: copy_phases.py", result.stderr)


if __name__ == "__main__":
    unittest.main()
