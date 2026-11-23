"""Tests of Scripts/size_settings.py: the Release size settings every Release build passes, defined once.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

They pin what the study of November 23, 2026 recommended (and left out), the shell-quoted form the Makefile
reads, the flag the goldens' build leaves out, and that the iPhone build and the Makefile both use this list.
"""
import importlib.util
import shlex
import unittest

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


class SizeSettingsTests(unittest.TestCase):
    def test_the_recommended_set_and_nothing_the_study_rejected(self):
        found = size_settings.settings()
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
        self.assertFalse(any("REFLECTION" in item for item in size_settings.settings()))

    def test_the_makefile_form_is_shell_quoted_words(self):
        # One word per setting, the spaces of a value kept inside its word.
        words = shlex.split(" ".join(shlex.quote(item) for item in size_settings.settings()))
        self.assertEqual(words, size_settings.settings())

    def test_the_goldens_leave_out_internalize_at_link_alone(self):
        found = size_settings.settings(without=size_settings.LEFT_OUT_FOR_TESTS)
        self.assertEqual(len(found), 4)
        self.assertIn("-Xfrontend -conditional-runtime-records", found[3])
        self.assertNotIn("internalize", found[3])
        self.assertIn("SWIFT_LTO=YES", found)

    def test_leaving_out_every_flag_leaves_no_other_swift_flags(self):
        found = size_settings.settings(without=size_settings.FRONTEND_FLAGS)
        self.assertFalse(any(item.startswith("OTHER_SWIFT_FLAGS") for item in found))

    def test_the_iphone_build_passes_the_same_settings(self):
        app_size = load("app_size", SCRIPTS / "ios" / "app-size.py")
        command = app_size.build_command("/tmp/derived")
        for item in size_settings.settings():
            self.assertIn(item, command)

    def test_the_makefile_passes_them_to_the_build_rule_for_release_only(self):
        makefile = (SCRIPTS.parent / "Makefile").read_text()
        self.assertIn("size_settings.py", makefile)
        self.assertIn("$(if $(filter Release,$(CONFIG)),$(shell python3 -I -B Scripts/size_settings.py))", makefile)
        self.assertIn("$(SIZE_SETTINGS)", makefile)


if __name__ == "__main__":
    unittest.main()
