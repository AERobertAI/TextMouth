"""Tests of regenerate-project.py: xcodegen's project, less the noise of its copy-phase order.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test builds a small repository in a temporary folder, with a stand-in for
xcodegen that writes a chosen project into it, so the real project and the real
xcodegen are never touched. The repositories are made with `git init` and `git add`
inside the temporary folder; nothing is committed.
"""
import contextlib
import importlib.util
import io
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from heavy_lock_case import AGENTS
from pbxproj_fixtures import phase, project

# regenerate-project.py has a hyphen in its name, so it is loaded by path.
_spec = importlib.util.spec_from_file_location("regenerate_project", AGENTS / "regenerate-project.py")
regenerate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(regenerate)

# Identifiers are 24 hexadecimal digits, as xcodegen writes them: the script finds
# a target's references by that shape.
ID_A, ID_B, ID_C = "A1" * 12, "B2" * 12, "C3" * 12
LICENSES = phase(ID_A, "Licenses", ["README"])
TABLES = phase(ID_B, "Tables", ["en.ctb"])
# The same two phases as xcodegen deals them on another run: the identifiers stay
# and trade their contents, so each is listed with the other's destination.
LICENSES_AGAIN = phase(ID_B, "Licenses", ["README"])
TABLES_AGAIN = phase(ID_A, "Tables", ["en.ctb"])


def targets(*identifiers):
    """The part of a project that lists a target's copy phases, in the given order."""
    return "/* Begin PBXNativeTarget section */\n\t\tT1 = {\n\t\t\tbuildPhases = (\n" + "".join(
        f"\t\t\t\t{identifier} /* CopyFiles */,\n" for identifier in identifiers) + "\t\t\t);\n\t\t};\n/* End PBXNativeTarget section */\n"


def text_of(phases, order):
    """A project text holding `phases` and a target that lists `order`."""
    return project(*phases) + targets(*order)


# The project as that other run writes it: the same meaning, another order.
NOISY = text_of([TABLES_AGAIN, LICENSES_AGAIN], [ID_B, ID_A])


class RegenerateProjectTests(unittest.TestCase):
    """main() on a temporary repository whose xcodegen is a stand-in."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)
        self.root = self.folder / "checkout"
        (self.root / "TextMouth.xcodeproj").mkdir(parents=True)
        self.project = self.root / regenerate.PROJECT
        # Guard: everything this test writes or runs is under the temporary folder.
        self.assertTrue(str(self.project).startswith(str(self.folder)))

    def make_repository(self, committed):
        """Starts a repository in the checkout with `committed` as its indexed project."""
        self.project.write_text(committed)
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True, timeout=30)
        subprocess.run(["git", "add", regenerate.PROJECT], cwd=self.root, check=True, timeout=30)

    def make_xcodegen(self, writes):
        """Makes a stand-in xcodegen that writes `writes` as the project; returns its path."""
        (self.folder / "fresh.pbxproj").write_text(writes)
        stand_in = self.folder / "xcodegen"
        stand_in.write_text(f"#!{sys.executable}\nimport shutil\n"
                            f"shutil.copyfile({str(self.folder / 'fresh.pbxproj')!r}, {regenerate.PROJECT!r})\n")
        stand_in.chmod(stand_in.stat().st_mode | stat.S_IXUSR)
        return str(stand_in)

    def regenerate(self, xcodegen):
        """Runs main() on the checkout; returns what it printed."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            regenerate.main(self.root, xcodegen)
        return out.getvalue()

    def test_only_a_reordering_is_put_back_so_the_project_is_unchanged(self):
        committed = text_of([LICENSES, TABLES], [ID_A, ID_B])
        self.make_repository(committed)
        output = self.regenerate(self.make_xcodegen(NOISY))
        self.assertEqual(self.project.read_text(), committed, "the copy-phase noise was left in the project")
        self.assertIn("the project is unchanged", output)

    def test_a_reordering_with_a_real_change_keeps_the_change_and_puts_the_order_back(self):
        committed = text_of([LICENSES, TABLES], [ID_A, ID_B])
        self.make_repository(committed)
        fresh = NOISY.replace(
            "/* End PBXBuildFile section */", "\t\tNEW /* y */ = {isa = PBXBuildFile;};\n/* End PBXBuildFile section */")
        output = self.regenerate(self.make_xcodegen(fresh))
        self.assertEqual(self.project.read_text(), committed.replace(
            "/* End PBXBuildFile section */", "\t\tNEW /* y */ = {isa = PBXBuildFile;};\n/* End PBXBuildFile section */"))
        self.assertIn("with its copy-files phases as they were", output)

    def test_a_change_in_what_is_copied_keeps_xcodegens_whole_project(self):
        self.make_repository(text_of([LICENSES, TABLES], [ID_A, ID_B]))
        fresh = text_of([phase(ID_C, "Licenses", ["README", "NOTICE"]), TABLES_AGAIN], [ID_C, ID_A])
        output = self.regenerate(self.make_xcodegen(fresh))
        self.assertEqual(self.project.read_text(), fresh, "part of the old project was put back over a real change")
        self.assertIn("changed in meaning", output)

    def test_without_an_index_copy_xcodegens_whole_project_is_kept_and_the_console_says_so(self):
        # A source archive: no repository at all. The checkout is inside the temporary
        # folder, which is not inside any repository.
        self.project.write_text("old")
        fresh = text_of([LICENSES], ["AAAA1111AAAA1111AAAA1111"])
        output = self.regenerate(self.make_xcodegen(fresh))
        self.assertEqual(self.project.read_text(), fresh)
        self.assertIn("git has no copy of the project to compare with", output)

    def test_an_untracked_project_in_a_repository_is_treated_the_same(self):
        self.project.write_text("old")
        subprocess.run(["git", "init", "-q"], cwd=self.root, check=True, timeout=30)
        fresh = text_of([LICENSES], ["AAAA1111AAAA1111AAAA1111"])
        output = self.regenerate(self.make_xcodegen(fresh))
        self.assertEqual(self.project.read_text(), fresh)
        self.assertIn("git has no copy of the project", output)

    def test_a_source_archive_inside_another_repository_is_not_mistaken_for_part_of_it(self):
        # The outer repository tracks a project file at its own top level; the archive
        # is a folder below it, with the same file, untracked there.
        self.make_repository(text_of([LICENSES, TABLES], [ID_A, ID_B]))
        archive = self.root / "unpacked"
        (archive / "TextMouth.xcodeproj").mkdir(parents=True)
        self.assertTrue(str(archive).startswith(str(self.folder)))
        (archive / regenerate.PROJECT).write_text("old")
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            regenerate.main(archive, self.make_xcodegen(NOISY))
        self.assertEqual((archive / regenerate.PROJECT).read_text(), NOISY)
        self.assertIn("git has no copy of the project", out.getvalue())

    def test_the_index_copy_is_the_one_compared_not_the_working_file(self):
        # A project already regenerated and left unstaged must not hide the noise the index lacks.
        committed = text_of([LICENSES, TABLES], [ID_A, ID_B])
        self.make_repository(committed)
        self.project.write_text(NOISY)
        self.regenerate(self.make_xcodegen(NOISY))
        self.assertEqual(self.project.read_text(), committed)

    def test_a_failing_xcodegen_stops_with_its_output(self):
        self.make_repository(text_of([LICENSES], ["AAAA1111AAAA1111AAAA1111"]))
        failing = self.folder / "failing-xcodegen"
        failing.write_text(f"#!{sys.executable}\nimport sys\nprint('boom')\nsys.exit(3)\n")
        failing.chmod(failing.stat().st_mode | stat.S_IXUSR)
        with self.assertRaises(SystemExit) as stopped:
            self.regenerate(str(failing))
        self.assertIn("boom", str(stopped.exception))

    def test_index_copy_reads_from_the_checkouts_own_folder(self):
        self.make_repository("indexed text")
        self.assertEqual(regenerate.index_copy(self.root), "indexed text")

    def test_the_script_works_on_the_checkout_it_is_in(self):
        self.assertEqual(regenerate.ROOT, AGENTS.parents[1])

    def test_the_makefile_runs_this_script_for_generate(self):
        # A dry run (make -n) prints the commands and runs none of them.
        result = subprocess.run(["make", "-n", "generate"], cwd=AGENTS.parents[1], capture_output=True, text=True,
                                timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("python3 -I -B Scripts/agents/regenerate-project.py", result.stdout)
        self.assertNotIn("xcodegen generate", result.stdout, "make generate bypasses the script")


if __name__ == "__main__":
    unittest.main()
