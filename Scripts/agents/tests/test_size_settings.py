"""Tests of Scripts/size_settings.py: the Release size settings every Release build passes, defined once.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

They pin what the study of November 23, 2026 recommended (and left out), the shell-quoted form the Makefile
reads, the flag the goldens' build leaves out, the profiles (full, light, and auto: full on GitHub Actions and
light on a Mac), and that the iPhone build and the Makefile both use this list.
"""
import contextlib
import importlib.util
import io
import os
import shlex
import unittest
from unittest import mock

from heavy_lock_case import AGENTS  # noqa: F401  (sets sys.path as the other script tests do)

# size_settings.py and app-size.py are in Scripts and Scripts/ios, beside Scripts/agents.
SCRIPTS = AGENTS.parent


def load(name, path):
    """The module at `path`, loaded under `name`."""
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


size_settings = load("size_settings", SCRIPTS / "size_settings.py")
FULL, LIGHT, AUTO = size_settings.FULL, size_settings.LIGHT, size_settings.AUTO


def run(argv):
    """(exit status, standard output, standard error) of size_settings.main(argv)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = size_settings.main(argv)
    return status, out.getvalue(), err.getvalue()


@contextlib.contextmanager
def on_github(yes):
    """The process's environment as on GitHub Actions (GITHUB_ACTIONS=true) when `yes`, else as on a Mac."""
    with mock.patch.dict(os.environ):
        if yes:
            os.environ["GITHUB_ACTIONS"] = "true"
        else:
            os.environ.pop("GITHUB_ACTIONS", None)
        yield


class SizeSettingsTests(unittest.TestCase):
    def test_the_recommended_set_and_nothing_the_study_rejected(self):
        found = size_settings.settings(profile=FULL)
        self.assertEqual(found[:3], ["SWIFT_LTO=YES", "LLVM_LTO=YES", "GCC_OPTIMIZATION_LEVEL=z"])
        flags = found[3]
        self.assertTrue(flags.startswith("OTHER_SWIFT_FLAGS=$(inherited) "))
        self.assertIn("-Xfrontend -conditional-runtime-records", flags)
        self.assertIn("-Xfrontend -internalize-at-link", flags)
        # Saved nothing in the study, and "none" was left for a person to check in the app.
        for rejected in ("-enable-llvm-vfe", "-enable-llvm-wme", "=none"):
            self.assertNotIn(rejected, " ".join(found))

    def test_reflection_metadata_keeps_its_names(self):
        # The debug log prints errors and enum cases through reflection; without-names would show only the type.
        for profile in (FULL, LIGHT):
            self.assertFalse(any("REFLECTION" in item for item in size_settings.settings(profile=profile)), profile)

    def test_the_makefile_form_is_shell_quoted_words(self):
        # One word per setting, the spaces of a value kept inside its word.
        for profile in (FULL, LIGHT):
            found = size_settings.settings(profile=profile)
            self.assertEqual(shlex.split(" ".join(shlex.quote(item) for item in found)), found, profile)

    def test_the_goldens_leave_out_internalize_at_link_alone(self):
        found = size_settings.settings(without=size_settings.LEFT_OUT_FOR_TESTS, profile=FULL)
        self.assertEqual(len(found), 4)
        self.assertIn("-Xfrontend -conditional-runtime-records", found[3])
        self.assertNotIn("internalize", found[3])
        self.assertIn("SWIFT_LTO=YES", found)

    def test_leaving_out_every_flag_leaves_no_other_swift_flags(self):
        found = size_settings.settings(without=size_settings.FRONTEND_FLAGS, profile=FULL)
        self.assertFalse(any(item.startswith("OTHER_SWIFT_FLAGS") for item in found))

    def test_auto_is_full_on_github_actions_and_light_anywhere_else(self):
        self.assertEqual(size_settings.resolved(AUTO, {"GITHUB_ACTIONS": "true"}), FULL)
        for environ in ({}, {"GITHUB_ACTIONS": "false"}, {"GITHUB_ACTIONS": ""}, {"CI": "true"}):
            self.assertEqual(size_settings.resolved(AUTO, environ), LIGHT, environ)
        # A profile named outright is that profile, wherever the build runs.
        for environ in ({}, {"GITHUB_ACTIONS": "true"}):
            self.assertEqual(size_settings.resolved(FULL, environ), FULL, environ)
            self.assertEqual(size_settings.resolved(LIGHT, environ), LIGHT, environ)

    def test_a_light_build_keeps_only_what_costs_no_memory_at_link_time(self):
        # Full link-time optimization's link takes several GB, and the frontend flags were tested only with it.
        self.assertEqual(size_settings.settings(profile=LIGHT), ["GCC_OPTIMIZATION_LEVEL=z"])
        self.assertEqual(size_settings.settings(profile=AUTO, environ={}), ["GCC_OPTIMIZATION_LEVEL=z"])
        self.assertEqual(size_settings.settings(profile=AUTO, environ={"GITHUB_ACTIONS": "true"}),
                         size_settings.settings(profile=FULL))

    def test_an_unknown_profile_is_refused(self):
        with self.assertRaises(size_settings.UsageError):
            size_settings.resolved("fulll", {})
        for argv in (["--profile", "fulll"], ["--profile=Full"], ["--profile"], ["--profile="], ["--which", "extra"]):
            status, out, err = run(argv)
            self.assertEqual((status, out), (2, ""), argv)
            self.assertIn("usage: size_settings.py", err, argv)

    def test_which_prints_the_profile_the_build_would_take(self):
        with on_github(False):
            self.assertEqual(run(["--which"]), (0, "light\n", ""))
            self.assertEqual(run(["--profile", "full", "--which"]), (0, "full\n", ""))
        with on_github(True):
            self.assertEqual(run(["--which"]), (0, "full\n", ""))
            self.assertEqual(run(["--profile=light", "--which"]), (0, "light\n", ""))

    def test_no_argument_prints_the_makefile_form(self):
        for github in (False, True):
            with on_github(github):
                expected = " ".join(shlex.quote(item) for item in size_settings.settings()) + "\n"
                self.assertEqual(run([]), (0, expected, ""), github)

    def test_help_prints_the_usage_and_no_settings(self):
        for argv in (["--help"], ["-h"], ["--list", "--help"]):
            status, out, err = run(argv)
            self.assertEqual((status, err), (0, ""), argv)
            self.assertIn("usage: size_settings.py", out, argv)
            self.assertNotIn("SWIFT_LTO=YES", out, argv)

    def test_without_takes_its_value_after_a_space_or_an_equals_sign(self):
        # The goldens' build passes the flag as the next argument; the equals form was ignored before.
        expected = "\n".join(size_settings.settings(without=size_settings.LEFT_OUT_FOR_TESTS, profile=FULL)) + "\n"
        for argv in (
            ["--profile", "full", "--list", "--without", "-internalize-at-link"],
            ["--profile=full", "--list", "--without=-internalize-at-link"],
            ["--without=-internalize-at-link", "--list", "--profile", "full"],
        ):
            self.assertEqual(run(argv), (0, expected, ""), argv)
        # Several names, in one value or in two.
        both = "\n".join(size_settings.settings(without=("SWIFT_LTO", "-internalize-at-link"), profile=FULL)) + "\n"
        self.assertEqual(run(["--profile", "full", "--list", "--without", "SWIFT_LTO,-internalize-at-link"]),
                         (0, both, ""))
        self.assertEqual(run(["--profile", "full", "--list", "--without=SWIFT_LTO", "--without",
                              "-internalize-at-link"]), (0, both, ""))

    def test_a_command_line_it_does_not_know_is_refused(self):
        # A misspelled name used to leave its setting in without a word: the goldens' build could then not link.
        for argv in (
            ["--without", "-internalise-at-link"],
            ["--list", "--without=SWIFT_LTO,LTO"],
            ["--without"],
            ["--without="],
            ["--without", ","],
            ["--lst"],
            ["extra"],
        ):
            status, out, err = run(argv)
            self.assertEqual((status, out), (2, ""), argv)
            self.assertIn("usage: size_settings.py", err, argv)
        status, _, err = run(["--without", "-internalise-at-link,SWIFT_LTO"])
        self.assertIn("names no setting or flag: -internalise-at-link", err)
        self.assertNotIn("SWIFT_LTO\n", err.split("usage:")[0])

    def test_the_iphone_build_passes_the_same_settings(self):
        # The iPhone's size build takes the profile "auto", as the Makefile's development builds do.
        app_size = load("app_size", SCRIPTS / "ios" / "app-size.py")
        for github in (False, True):
            with on_github(github):
                command = app_size.build_command("/tmp/derived")
                for item in size_settings.settings():
                    self.assertIn(item, command, github)
                self.assertEqual("SWIFT_LTO=YES" in command, github)

    def test_the_makefile_passes_them_to_the_build_rule_for_release_only(self):
        makefile = (SCRIPTS.parent / "Makefile").read_text()
        self.assertIn("SIZE_PROFILE = auto", makefile)
        self.assertIn(
            '$(if $(filter Release,$(CONFIG)),$(or $(shell python3 -I -B Scripts/size_settings.py --profile '
            '"$(SIZE_PROFILE)"),$(error ', makefile)
        self.assertIn("$(SIZE_SETTINGS)", makefile)

    def test_install_and_release_build_the_app_that_ships_with_every_setting(self):
        makefile = (SCRIPTS.parent / "Makefile").read_text()
        for target in ("install", "release"):
            self.assertIn(f"{target}: SIZE_PROFILE = full", makefile)
            self.assertIn(f"{target}: full-build-note build", makefile)


if __name__ == "__main__":
    unittest.main()
