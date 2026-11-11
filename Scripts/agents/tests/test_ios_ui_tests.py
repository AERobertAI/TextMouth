"""Tests of ios_ui_tests.py: which of the iPhone's interface test classes a request asks for.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test makes a throwaway folder with a few Swift files, so no test reads the real interface tests but the one that
checks the repository's own folder is found.
"""
import tempfile
import unittest
from pathlib import Path

from heavy_lock_case import HeavyLockTestCase  # noqa: F401  (puts the scripts' folder on the path)
import ios_ui_tests as ui  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]


class TreeCase(unittest.TestCase):
    """A throwaway tree with a TextMouthiOSUITests folder holding the classes a test names."""

    def tree(self, **files):
        """Makes the tree (each keyword is a file's name, its value the source) and returns its path."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        root = Path(folder.name)
        (root / ui.UI_FOLDER).mkdir()
        for name, source in files.items():
            (root / ui.UI_FOLDER / f"{name}.swift").write_text(source)
        return root

    def standard(self):
        """A tree like the repository's: a base class, and three test classes in two files."""
        return self.tree(
            TextMouthUITestCase="@MainActor\nclass TextMouthUITestCase: XCTestCase {\n}\n",
            ReaderUITests="final class ReaderUITests: TextMouthUITestCase {\n}\n",
            Two="final class SearchUITests: TextMouthUITestCase {\n}\nclass PlaybackUITests: TextMouthUITestCase {\n}\n",
        )


class FindingTheClassesTests(TreeCase):
    """The classes are those that inherit the base class, which is not itself one."""

    def test_the_classes_inheriting_the_base_are_found_sorted_and_the_base_is_not_one(self):
        self.assertEqual(ui.ui_classes(self.standard()), ["PlaybackUITests", "ReaderUITests", "SearchUITests"])

    def test_a_class_that_inherits_something_else_is_not_one(self):
        root = self.tree(Other="final class HelperTests: XCTestCase {\n}\nstruct S: TextMouthUITestCase {}\n")
        self.assertEqual(ui.ui_classes(root), [])

    def test_a_tree_without_the_folder_has_none(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.assertEqual(ui.ui_classes(folder.name), [])

    def test_the_repositorys_own_interface_tests_are_found(self):
        found = ui.ui_classes(ROOT)
        for name in ("ReaderUITests", "LibraryUITests", "SearchUITests", "ScreenOrderUITests", "LargeTextUITests",
                     "PlaybackUITests"):
            self.assertIn(name, found)
        self.assertNotIn("TextMouthUITestCase", found)


class SplittingNamesTests(TreeCase):
    """The interface classes named in a request's "classes" move to "ios_ui_classes"; the Mac's stay."""

    def test_interface_classes_move_out_of_classes_and_mac_classes_stay(self):
        request = {"areas": ["feeds"], "classes": ["FooTests", "SearchUITests", "BarTests"]}
        split = ui.split_classes(request, self.standard())
        self.assertEqual(split["classes"], ["FooTests", "BarTests"])
        self.assertEqual(split["ios_ui_classes"], ["SearchUITests"])
        self.assertEqual(split["areas"], ["feeds"])
        self.assertEqual(request["classes"], ["FooTests", "SearchUITests", "BarTests"], "the request is not changed")

    def test_names_already_in_ios_ui_classes_are_joined_once_each_in_order(self):
        request = {"classes": ["SearchUITests"], "ios_ui_classes": ["ReaderUITests", "SearchUITests"]}
        self.assertEqual(ui.split_classes(request, self.standard())["ios_ui_classes"], ["ReaderUITests", "SearchUITests"])

    def test_a_request_with_no_interface_names_is_left_as_it_was(self):
        request = {"classes": ["FooTests"], "areas": [], "full": False}
        self.assertEqual(ui.split_classes(request, self.standard()), request)


class WhichTestsAreAskedForTests(TreeCase):
    """The rules of the module's comment, one test each."""

    def wanted(self, request):
        """The classes the request asks for in the standard tree."""
        return ui.wanted(request, self.standard())

    EVERY = ["PlaybackUITests", "ReaderUITests", "SearchUITests"]

    def test_a_full_suite_runs_every_class(self):
        self.assertEqual(self.wanted({"full": True, "areas": [], "classes": []}), self.EVERY)

    def test_the_phone_area_and_the_area_all_run_every_class(self):
        self.assertEqual(self.wanted({"areas": ["phone"], "classes": []}), self.EVERY)
        self.assertEqual(self.wanted({"areas": ["feeds", "all"], "classes": []}), self.EVERY)

    def test_another_area_or_a_mac_class_runs_none(self):
        self.assertEqual(self.wanted({"areas": ["feeds", "audio"], "classes": ["FooTests"]}), [])
        self.assertEqual(self.wanted({}), [])

    def test_a_named_interface_class_runs_that_class_alone(self):
        self.assertEqual(self.wanted({"areas": [], "classes": ["SearchUITests", "FooTests"]}), ["SearchUITests"])
        self.assertEqual(self.wanted({"areas": ["feeds"], "ios_ui_classes": ["ReaderUITests"]}), ["ReaderUITests"])

    def test_a_name_the_folder_does_not_hold_asks_for_nothing(self):
        self.assertEqual(self.wanted({"ios_ui_classes": ["NoSuchUITests"]}), [])

    def test_a_request_that_leaves_the_iphone_job_out_runs_none_whatever_else_it_says(self):
        self.assertEqual(self.wanted({"ios": False, "full": True, "areas": ["phone"], "ios_ui": True}), [])

    def test_ios_ui_false_runs_none_and_true_runs_the_named_or_all(self):
        self.assertEqual(self.wanted({"ios_ui": False, "full": True}), [])
        self.assertEqual(self.wanted({"ios_ui": True}), self.EVERY)
        self.assertEqual(self.wanted({"ios_ui": True, "classes": ["ReaderUITests"]}), ["ReaderUITests"])

    def test_a_value_that_is_not_a_truth_value_is_not_an_answer(self):
        self.assertEqual(self.wanted({"ios_ui": "yes"}), [])
        self.assertEqual(self.wanted({"ios_ui": "no", "full": True}), self.EVERY)


class TheUnitTestsTests(TreeCase):
    """The unit bundle (TextMouthiOSTests) is asked for with the interface bundle, and found by its own rule."""

    UNIT = ("final class IOSRuntimeTests: XCTestCase {\n    func testA() {}\n    #if DEBUG\n    func testB() {}\n"
            "    func testC() {}\n    #endif\n    func testD() {}\n}\n")

    def with_units(self, **units):
        """The standard interface tree plus a TextMouthiOSTests folder holding the given files."""
        root = self.standard()
        (root / ui.UNIT_FOLDER).mkdir()
        for name, source in units.items():
            (root / ui.UNIT_FOLDER / f"{name}.swift").write_text(source)
        return root

    def test_the_unit_classes_inherit_xctestcase_and_the_interface_ones_are_not_among_them(self):
        root = self.with_units(One=self.UNIT, Two="class PhoneValueRowTests: XCTestCase {\n}\nstruct NotOne {}\n")
        self.assertEqual(ui.unit_classes(root), ["IOSRuntimeTests", "PhoneValueRowTests"])
        self.assertEqual(ui.ui_classes(root), ["PlaybackUITests", "ReaderUITests", "SearchUITests"])
        self.assertEqual(ui.all_classes(root), ["IOSRuntimeTests", "PhoneValueRowTests",
                                                "PlaybackUITests", "ReaderUITests", "SearchUITests"])

    def test_a_tree_without_the_unit_folder_has_no_unit_classes(self):
        self.assertEqual(ui.unit_classes(self.standard()), [])
        self.assertEqual(ui.unit_counts(self.standard()), {})

    def test_the_methods_inside_if_debug_are_counted_because_the_iphone_job_builds_debug(self):
        root = self.with_units(One=self.UNIT)
        self.assertEqual(ui.unit_counts(root), {"IOSRuntimeTests": 4})

    def test_a_class_names_its_bundle_and_an_unknown_one_none(self):
        root = self.with_units(One=self.UNIT)
        self.assertEqual(ui.bundle_of("IOSRuntimeTests", root), "TextMouthiOSTests")
        self.assertEqual(ui.bundle_of("SearchUITests", root), "TextMouthiOSUITests")
        self.assertEqual(ui.bundle_of("FooTests", root), "")

    def test_the_counts_of_asked_classes_are_kept_apart_by_bundle(self):
        root = self.with_units(One=self.UNIT)
        self.assertEqual(ui.counts_by_bundle(["IOSRuntimeTests", "SearchUITests", "FooTests"], root),
                         {"TextMouthiOSTests": 4, "TextMouthiOSUITests": 0})
        self.assertEqual(ui.counts_by_bundle(["IOSRuntimeTests"], root), {"TextMouthiOSTests": 4})
        self.assertEqual(ui.counts_by_bundle([], root), {})

    def test_a_full_suite_and_the_phone_area_run_both_bundles_the_unit_tests_first(self):
        root = self.with_units(One=self.UNIT)
        every = ["IOSRuntimeTests", "PlaybackUITests", "ReaderUITests", "SearchUITests"]
        self.assertEqual(ui.wanted({"full": True}, root), every)
        self.assertEqual(ui.wanted({"areas": ["phone"]}, root), every)
        self.assertEqual(ui.wanted({"ios_ui": True}, root), every)

    def test_a_request_naming_a_unit_class_runs_that_class_alone_and_its_name_leaves_the_mac_classes(self):
        root = self.with_units(One=self.UNIT)
        request = {"areas": ["feeds"], "classes": ["FooTests", "IOSRuntimeTests"]}
        self.assertEqual(ui.wanted(request, root), ["IOSRuntimeTests"])
        split = ui.split_classes(request, root)
        self.assertEqual((split["classes"], split["ios_ui_classes"]), (["FooTests"], ["IOSRuntimeTests"]))

    def test_a_request_that_leaves_the_phone_job_out_runs_no_unit_test_either(self):
        root = self.with_units(One=self.UNIT)
        self.assertEqual(ui.wanted({"ios": False, "full": True, "classes": ["IOSRuntimeTests"]}, root), [])
        self.assertEqual(ui.wanted({"ios_ui": False, "full": True}, root), [])

    def test_the_repositorys_own_unit_tests_are_found_with_their_methods(self):
        self.assertEqual(ui.unit_classes(ROOT), ["IOSRuntimeTests", "PhoneControlButtonTests", "PhoneValueRowTests"])
        # Four in IOSRuntimeTests, two of them inside #if DEBUG, which the Debug build holds.
        self.assertEqual(ui.unit_counts(ROOT)["IOSRuntimeTests"], 4)
        self.assertGreaterEqual(sum(ui.unit_counts(ROOT).values()), 19)


class TheCountsInASummaryTests(unittest.TestCase):
    """The Executed line travels with each bundle's count to the places that show one line."""

    SUMMARY = ["iOS UI tests: PASSED", "Executed 52 tests, with 0 tests skipped and 0 failures (0 unexpected) in 9.0 (9.0) seconds",
               "Unit tests (TextMouthiOSTests): 19 ran, 0 skipped, 0 failed",
               "Interface tests (TextMouthiOSUITests): 33 ran, 0 skipped, 0 failed", "Classes: every class"]

    def test_the_executed_line_is_joined_with_both_counts(self):
        self.assertEqual(ui.executed_with_counts(self.SUMMARY),
                         "Executed 52 tests, with 0 tests skipped and 0 failures (0 unexpected) in 9.0 (9.0) seconds; "
                         "unit tests (TextMouthiOSTests): 19 ran, 0 skipped, 0 failed; "
                         "interface tests (TextMouthiOSUITests): 33 ran, 0 skipped, 0 failed")

    def test_a_summary_from_before_the_unit_tests_has_only_its_executed_line(self):
        old = [self.SUMMARY[0], self.SUMMARY[1], self.SUMMARY[4]]
        self.assertEqual(ui.executed_with_counts(old), self.SUMMARY[1])

    def test_a_summary_with_no_executed_line_gives_nothing(self):
        self.assertEqual(ui.executed_with_counts(["iOS UI tests: NOT ASKED", "Reason: x"]), "")


if __name__ == "__main__":
    unittest.main()
