"""Tests of Scripts/ios/check-licenses.py: the iPhone app ships every linked library's licence.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

The checks work on a parsed project.yml and a list of package identities, so
every test builds a small project in memory and none reads the real one except
the last, which holds the committed project to the rule.
"""
import copy
import importlib.util
import unittest

from heavy_lock_case import AGENTS  # noqa: F401  (sets sys.path as the other script tests do)

# check-licenses.py is in Scripts/ios, beside Scripts/agents.
_spec = importlib.util.spec_from_file_location("check_licenses", AGENTS.parent / "ios" / "check-licenses.py")
check_licenses = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_licenses)

# The packages the real iPhone app links, as Package.resolved names them.
IDENTITIES = ["zipfoundation", "swift-cmark"]


def copy_entry(path, folder):
    """A project.yml sources entry that copies `path` into Licenses/`folder`."""
    return {"path": path, "buildPhase": {"copyFiles": {"destination": "resources", "subpath": f"Licenses/{folder}"}}}


def complete_project():
    """A project whose iPhone target links every library and copies every licence."""
    sources = [{"path": "TextMouth"}]
    entries = list(check_licenses.LIBRARY_LICENCES.values()) + list(check_licenses.FOLLOWED_CODE.values())
    for folder, paths in entries:
        sources += [copy_entry(path, folder) for path in paths]
    return {
        "targets": {
            "TextMouthiOS": {
                "sources": sources,
                "dependencies": [
                    {"package": "ZIPFoundation"},
                    {"target": "SwiftSoup_iOS"},
                    {"package": "swift-cmark", "product": "cmark-gfm"},
                    {"target": "LAME_iOS"},
                    {"target": "ObjCExceptionCatcher_iOS"},
                    {"target": "FFmpeg_iOS"},
                    {"target": "liblouis_iOS"},
                    {"target": "TextMouthBrailleLibrary_iOS"},
                ],
            }
        }
    }


class CheckLicensesTests(unittest.TestCase):
    """Each way the iPhone app's licences can fall short is reported, once."""

    def test_a_complete_project_has_no_problems(self):
        self.assertEqual(check_licenses.problems(complete_project(), IDENTITIES), [])

    def test_a_linked_library_without_an_entry_is_reported(self):
        project = complete_project()
        project["targets"]["TextMouthiOS"]["dependencies"].append({"target": "Mystery_iOS"})
        found = check_licenses.problems(project, IDENTITIES)
        self.assertEqual(len(found), 1)
        self.assertIn("Mystery_iOS", found[0])

    def test_a_new_pinned_package_without_an_entry_is_reported(self):
        found = check_licenses.problems(complete_project(), IDENTITIES + ["swift-new"])
        self.assertEqual(len(found), 1)
        self.assertIn("swift-new", found[0])

    def test_a_licence_that_is_not_copied_is_reported(self):
        project = complete_project()
        sources = project["targets"]["TextMouthiOS"]["sources"]
        project["targets"]["TextMouthiOS"]["sources"] = [s for s in sources if s.get("path") != "Vendor/lame/COPYING"]
        found = check_licenses.problems(project, IDENTITIES)
        self.assertEqual(len(found), 1)
        self.assertIn("Vendor/lame/COPYING", found[0])

    def test_a_licence_copied_into_the_wrong_folder_is_reported(self):
        project = complete_project()
        for source in project["targets"]["TextMouthiOS"]["sources"]:
            if source.get("path") == "Vendor/lame/LICENSE":
                source["buildPhase"]["copyFiles"]["subpath"] = "Licenses/Elsewhere"
        found = check_licenses.problems(project, IDENTITIES)
        # Once for the missing copy in LAME, once for the stray one in Elsewhere.
        self.assertEqual(len(found), 2)

    def test_a_licence_of_a_dropped_library_is_reported(self):
        project = copy.deepcopy(complete_project())
        project["targets"]["TextMouthiOS"]["dependencies"] = [
            d for d in project["targets"]["TextMouthiOS"]["dependencies"] if d.get("target") != "LAME_iOS"
        ]
        found = check_licenses.problems(project, IDENTITIES)
        self.assertEqual(len(found), 2)
        self.assertTrue(all("LAME" in line for line in found))

    def test_the_committed_project_is_complete(self):
        project = check_licenses.load_yaml("project.yml")
        identities = check_licenses.package_identities(
            "TextMouth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        self.assertEqual(check_licenses.problems(project, identities), [])


if __name__ == "__main__":
    unittest.main()
