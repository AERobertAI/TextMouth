"""Tests of ios_ui_tests.py: which of the iPhone's interface test classes a request asks for.

Run with: python3 -I -B -m unittest discover -s Scripts/agents/tests

Each test makes a throwaway folder with a few Swift files, so no test reads the real interface tests but the one that
checks the repository's own folder is found.
"""
import re
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

    def with_shared(self, **shared):
        """A tree whose project.yml lists Mac test files (those given, under TextMouthProductionTests) for the unit target,
        with one unit class of its own."""
        root = self.with_units(One=self.UNIT)
        (root / "TextMouthProductionTests").mkdir()
        for name, source in shared.items():
            (root / "TextMouthProductionTests" / f"{name}.swift").write_text(source)
        listed = "".join(f"      - TextMouthProductionTests/{name}.swift\n" for name in shared)
        (root / "project.yml").write_text(
            "targets:\n  TextMouthiOSTests:\n    sources:\n      - TextMouthiOSTests\n" + listed + "    settings:\n      base:\n        X: y\n")
        return root

    SHARED = "final class FeedParserTests: XCTestCase {\n    func testA() {}\n    func testB() {}\n}\nclass Base: XCTestCase {}\nfinal class ViaBaseTests: Base {\n    func testC() {}\n}\n"

    def test_a_mac_test_file_listed_for_the_unit_target_adds_its_classes_to_the_unit_bundle(self):
        root = self.with_shared(Feeds=self.SHARED)
        self.assertEqual(ui.shared_classes(root), ["Base", "FeedParserTests", "ViaBaseTests"])
        self.assertEqual(ui.unit_classes(root), ["Base", "FeedParserTests", "IOSRuntimeTests", "ViaBaseTests"])
        self.assertEqual(ui.unit_counts(root)["FeedParserTests"], 2)
        self.assertEqual(ui.unit_counts(root)["ViaBaseTests"], 1, "a class inheriting a shared base class is a test class")
        self.assertEqual(ui.bundle_of("FeedParserTests", root), "TextMouthiOSTests")

    def test_a_test_fenced_for_the_mac_is_not_counted_for_the_iphone_and_one_in_the_else_branch_is(self):
        source = ("final class MixedTests: XCTestCase {\n    func testBoth() {}\n    #if os(macOS)\n    func testMacOnly() {}\n"
                  "    #if DEBUG\n    func testNestedMac() {}\n    #endif\n    #else\n    func testPhoneOnly() {}\n    #endif\n"
                  "    #if !os(macOS)\n    func testNotMac() {}\n    #endif\n}\n")
        root = self.with_shared(Mixed=source)
        self.assertEqual(ui.unit_counts(root)["MixedTests"], 3, "testBoth, testPhoneOnly and testNotMac")

    def test_a_file_that_is_listed_but_not_in_the_tree_is_left_out(self):
        root = self.with_shared(Feeds=self.SHARED)
        (root / "TextMouthProductionTests" / "Feeds.swift").unlink()
        self.assertEqual(ui.shared_files(root), [])

    def test_a_request_naming_a_shared_class_keeps_it_for_the_mac_and_adds_it_for_the_iphone(self):
        root = self.with_shared(Feeds=self.SHARED)
        split = ui.split_classes({"classes": ["FeedParserTests", "IOSRuntimeTests", "OtherMacTests"]}, root)
        self.assertEqual(split["classes"], ["FeedParserTests", "OtherMacTests"], "the Mac still runs the shared class")
        self.assertEqual(split["ios_ui_classes"], ["FeedParserTests", "IOSRuntimeTests"])

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
        # The bundle's own folder holds these three; the Mac test files it shares by path add their classes (see
        # the shared-file tests above).
        self.assertTrue({"IOSRuntimeTests", "PhoneControlButtonTests", "PhoneValueRowTests"} <= set(ui.unit_classes(ROOT)))
        # Four in IOSRuntimeTests, two of them inside #if DEBUG, which the Debug build holds.
        self.assertEqual(ui.unit_counts(ROOT)["IOSRuntimeTests"], 4)
        self.assertGreaterEqual(sum(ui.unit_counts(ROOT).values()), 19)


class CountingTheTestsTests(TreeCase):
    """The counter reads Swift the way `project.yml` compiles it: attributes and modifiers, extensions, and subfolders."""

    def folder_with(self, folder=None, **files):
        """A tree whose TextMouthiOSUITests folder (or `folder`, relative to it) holds the given files."""
        root = self.tree()
        for name, source in files.items():
            path = root / ui.UI_FOLDER / (folder or "") / f"{name}.swift"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(source)
        return root

    def test_a_test_with_an_attribute_or_modifier_on_its_line_is_counted(self):
        root = self.folder_with(A="final class A: TextMouthUITestCase {\n    @MainActor func testA() {}\n"
                                  "    @available(iOS 26, *) func testB() throws {}\n    override func testC() {}\n"
                                  "    @MainActor\n    func testD() async {}\n    func testE() {}\n}\n")
        self.assertEqual(ui.test_counts(root), {"A": 5})

    def test_a_class_with_attributes_or_modifiers_before_class_is_found_and_counted(self):
        root = self.folder_with(A="@MainActor final class A: TextMouthUITestCase {\n    func testA() {}\n}\n",
                                B="@MainActor\nfinal class B: TextMouthUITestCase {\n    func testB() {}\n}\n",
                                C="public class C: TextMouthUITestCase {\n    func testC() {}\n}\n")
        self.assertEqual(ui.ui_classes(root), ["A", "B", "C"])
        self.assertEqual(ui.test_counts(root), {"A": 1, "B": 1, "C": 1})

    def test_a_test_in_an_extension_in_another_file_or_after_another_class_is_credited_to_its_class(self):
        root = self.folder_with(
            A="final class A: TextMouthUITestCase {\n    func testA() {}\n}\n",
            B="final class B: TextMouthUITestCase {\n    func testB() {}\n}\nextension A {\n    func testMoreA() {}\n}\n",
            C="extension B {\n    func testMoreB() {}\n    @MainActor func testEvenMoreB() {}\n}\n",
        )
        self.assertEqual(ui.test_counts(root), {"A": 2, "B": 3})

    def test_an_extension_of_another_type_adds_nothing(self):
        root = self.folder_with(A="final class A: TextMouthUITestCase {\n    func testA() {}\n}\n"
                                  "extension XCUIApplication {\n    func testHelper() {}\n}\n")
        self.assertEqual(ui.test_counts(root), {"A": 1})

    def test_a_class_nested_in_a_test_class_hides_none_of_the_tests_after_it(self):
        # A helper nested in a test class (a file presenter, a host stub) holds only its own braces: the tests after it
        # are still its outer class's. Before, they were credited to the helper and lost from the count.
        root = self.folder_with(A="final class A: TextMouthUITestCase {\n    func testA() {}\n"
                                  "    private final class Presenter: NSObject {\n        func helper() {}\n    }\n"
                                  "    func testB() {}\n}\n")
        self.assertEqual(ui.test_counts(root), {"A": 2})
        self.assertEqual(ui.methods_of("A", root), ["testA", "testB"])

    def test_a_brace_or_a_class_in_a_comment_or_a_string_moves_no_scope(self):
        root = self.folder_with(A='final class A: TextMouthUITestCase {\n    // class B: TextMouthUITestCase {\n'
                                  '    let brace = "}"\n    /* } */\n    func testA() {}\n'
                                  '    let fixture = """\n    class C: TextMouthUITestCase {\n    """\n'
                                  '    func testB() {}\n}\n')
        self.assertEqual(ui.ui_classes(root), ["A"])
        self.assertEqual(ui.test_counts(root), {"A": 2})

    def test_a_file_in_a_subfolder_is_read(self):
        root = self.folder_with("Deeper/Still", A="final class A: TextMouthUITestCase {\n    func testA() {}\n}\n")
        self.assertEqual(ui.ui_classes(root), ["A"])
        self.assertEqual(ui.test_counts(root), {"A": 1})

    def test_the_unit_folder_is_read_the_same_way(self):
        root = self.folder_with()
        folder = root / ui.UNIT_FOLDER / "Sub"
        folder.mkdir(parents=True)
        (folder / "U.swift").write_text("@MainActor final class UTests: XCTestCase {\n    @MainActor func testU() {}\n}\n"
                                        "extension UTests {\n    func testV() {}\n}\n")
        self.assertEqual(ui.unit_counts(root), {"UTests": 2})

    def test_every_func_test_in_either_repository_folder_is_counted(self):
        """The counter and a plain search of the sources agree: a `func test...(` left uncounted is a test that could be
        lost without a red run. Comment lines are left out of the search; a false red here is the safe side."""
        plain = re.compile(r"^(?!\s*//).*\bfunc\s+test\w*\s*\(", re.M)
        # The unit bundle compiles its own folder and the Mac test files project.yml lists for it.
        for folder, counts, files in ((ui.UI_FOLDER, ui.test_counts(ROOT), ui.swift_files(ROOT / ui.UI_FOLDER)),
                                      (ui.UNIT_FOLDER, ui.unit_counts(ROOT), ui.unit_source_files(ROOT))):
            # What the iPhone does not compile (`#if os(macOS)` blocks of shared Mac files) is not counted.
            found = sum(len(plain.findall(ui.without_mac_only(path.read_text(encoding="utf-8")))) for path in files)
            self.assertGreater(found, 0, f"No test found in {folder}: the search itself is broken")
            self.assertEqual(sum(counts.values()), found,
                             f"{folder} holds {found} `func test` but the counter credits {sum(counts.values())} "
                             f"({counts}): a test is in a form the counter misses")


# The Mac's test folders: the classes in them are the ones a request's "classes" keeps for run-area.py.
MAC_TEST_FOLDERS = ("TextMouthTests", "TextMouthProductionTests")
# A class that inherits something (`final class A: XCTestCase`, `@MainActor class B: Base`), whatever stands before `class`.
# The search runs line by line and stops at a comment, so it cannot backtrack across the file.
INHERITING_CLASS = re.compile(r"^[ \t]*[^\n/]*?\bclass\s+([A-Za-z0-9_]+)\s*:", re.M)


def mac_class_names(root):
    """Every class that inherits something in the Mac's test folders of `root`, as a set of names."""
    names = set()
    for folder in MAC_TEST_FOLDERS:
        for path in ui.swift_files(Path(root) / folder):
            names.update(INHERITING_CLASS.findall(path.read_text(encoding="utf-8", errors="replace")))
    return names


class TheNamesStayApartTests(TreeCase):
    """`split_classes` moves any name an iPhone folder holds out of a request's Mac classes, so a Mac test class with an
    iPhone class's name would quietly stop running when asked for."""

    def test_no_iphone_test_class_shares_a_mac_test_class_name_unless_it_is_the_same_file(self):
        iphone = set(ui.all_classes(ROOT))
        self.assertTrue(iphone, "no iPhone test class found: the search itself is broken")
        self.assertGreater(len(mac_class_names(ROOT)), 100, "the Mac's test classes were not found")
        # A shared class is the Mac's own file listed in project.yml, so its name is on both sides on purpose; any other
        # name on both sides is a different class, which split_classes would confuse with the Mac's.
        self.assertEqual(sorted((iphone & mac_class_names(ROOT)) - set(ui.shared_classes(ROOT))), [],
                         "an iPhone test class shares its name with a Mac test class: rename the iPhone one")

    def test_the_check_sees_a_shared_name(self):
        """The break: a scratch tree whose Mac folder holds a class named like an iPhone one."""
        root = self.tree(A="final class PhoneValueRowTests: TextMouthUITestCase {\n    func testA() {}\n}\n")
        (root / "TextMouthProductionTests").mkdir()
        (root / "TextMouthProductionTests" / "Mac.swift").write_text(
            "@MainActor final class PhoneValueRowTests: XCTestCase {\n    func testB() {}\n}\n"
            "final class OtherTests: XCTestCase {}\n")
        self.assertEqual(sorted(set(ui.all_classes(root)) & mac_class_names(root)), ["PhoneValueRowTests"])


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


class OneTestMethodTests(TreeCase):
    """A name may be `Class/testMethod`: one test of an iPhone class, which follows its class everywhere."""

    def tree_with_methods(self):
        """An interface class of three tests, a unit class of two, and a Mac-only class name."""
        root = self.tree(
            TextMouthUITestCase="class TextMouthUITestCase: XCTestCase {\n}\n",
            Reader=("final class ReaderUITests: TextMouthUITestCase {\n    func testOpen() {}\n    @MainActor\n"
                    "    func testPlay() {}\n    func testStop() {}\n}\nextension ReaderUITests {\n    func testMore() {}\n}\n"),
            Search="final class SearchUITests: TextMouthUITestCase {\n    func testFind() {}\n}\n")
        (root / ui.UNIT_FOLDER).mkdir()
        (root / ui.UNIT_FOLDER / "Units.swift").write_text(
            "final class UnitsTests: XCTestCase {\n    func testX() {}\n    func testY() {}\n}\n")
        return root

    def test_a_method_moves_to_the_iphone_names_with_its_class(self):
        split = ui.split_classes({"classes": ["FooTests", "ReaderUITests/testPlay", "FooTests/testA"]}, self.tree_with_methods())
        self.assertEqual(split["ios_ui_classes"], ["ReaderUITests/testPlay"])
        self.assertEqual(split["classes"], ["FooTests", "FooTests/testA"], "a Mac method stays for run-area")

    def test_a_method_of_a_class_the_two_bundles_share_stays_for_the_mac_too(self):
        root = self.tree_with_methods()
        (root / "TextMouthProductionTests").mkdir()
        (root / "TextMouthProductionTests" / "Shared.swift").write_text("final class SharedTests: XCTestCase {\n    func testS() {}\n}\n")
        (root / "project.yml").write_text(
            f"targets:\n  {ui.UNIT_BUNDLE}:\n    sources:\n      - TextMouthProductionTests/Shared.swift\n    settings:\n      x: y\n")
        split = ui.split_classes({"classes": ["SharedTests/testS"]}, root)
        self.assertEqual((split["classes"], split["ios_ui_classes"]), (["SharedTests/testS"], ["SharedTests/testS"]))

    def test_the_methods_of_a_class_are_listed_with_its_extensions_in_file_order(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.methods_of("ReaderUITests", root), ["testOpen", "testPlay", "testStop", "testMore"])
        self.assertEqual(ui.methods_of("UnitsTests", root), ["testX", "testY"])
        self.assertEqual(ui.methods_of("Nowhere", root), [])

    def test_a_method_names_its_classs_bundle(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.bundle_of("ReaderUITests/testPlay", root), ui.UI_BUNDLE)
        self.assertEqual(ui.bundle_of("UnitsTests/testX", root), ui.UNIT_BUNDLE)
        self.assertEqual(ui.bundle_of("Nowhere/testX", root), "")

    def test_a_request_for_a_method_asks_for_that_method_alone(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.wanted({"classes": ["ReaderUITests/testPlay"]}, root), ["ReaderUITests/testPlay"])
        self.assertEqual(ui.wanted({"classes": ["UnitsTests/testY", "ReaderUITests/testStop", "ReaderUITests/testOpen"]}, root),
                         ["UnitsTests/testY", "ReaderUITests/testStop", "ReaderUITests/testOpen"])

    def test_a_method_whose_class_is_also_named_runs_with_its_class(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.wanted({"classes": ["ReaderUITests/testPlay", "ReaderUITests", "SearchUITests/testFind"]}, root),
                         ["ReaderUITests", "SearchUITests/testFind"])

    def test_the_area_phone_still_runs_every_class_whole(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.wanted({"areas": ["phone"], "classes": ["ReaderUITests/testPlay"]}, root), ui.all_classes(root))

    def test_a_method_counts_as_one_test_and_a_class_with_its_method_as_the_class(self):
        root = self.tree_with_methods()
        self.assertEqual(ui.counts_by_bundle(["ReaderUITests/testPlay", "UnitsTests/testX", "UnitsTests/testY"], root),
                         {ui.UI_BUNDLE: 1, ui.UNIT_BUNDLE: 2})
        self.assertEqual(ui.counts_by_bundle(["ReaderUITests", "ReaderUITests/testPlay"], root), {ui.UI_BUNDLE: 4})

    def test_a_method_is_estimated_as_one_test_of_its_bundle(self):
        seconds = ui.estimated_seconds(["ReaderUITests/testPlay", "UnitsTests/testX", "Nowhere/testQ"], self.tree_with_methods(), times={})
        self.assertEqual(seconds["ReaderUITests/testPlay"], ui.SECONDS_PER_TEST[ui.UI_BUNDLE])
        self.assertEqual(seconds["UnitsTests/testX"], ui.SECONDS_PER_TEST[ui.UNIT_BUNDLE])
        self.assertEqual(seconds["Nowhere/testQ"], 1.0)

    def test_a_methods_slice_is_dealt_like_a_class(self):
        root = self.tree_with_methods()
        names = ["ReaderUITests/testPlay", "ReaderUITests/testOpen"]
        slices = [ui.slice_for(names, number, 2, root, times={}) for number in (1, 2)]
        self.assertEqual(sorted(name for one in slices for name in one), sorted(names))


class ShardingTests(TreeCase):
    """Dealing the iPhone test classes over several jobs."""

    def sized(self):
        """A tree with a big interface class (4 tests), a small one (1), and a unit class (6 tests)."""
        root = self.tree(
            TextMouthUITestCase="class TextMouthUITestCase: XCTestCase {\n}\n",
            Big="final class BigUITests: TextMouthUITestCase {\n    func testA() {}\n    func testB() {}\n    func testC() {}\n    func testD() {}\n}\n",
            Small="final class SmallUITests: TextMouthUITestCase {\n    func testA() {}\n}\n")
        (root / ui.UNIT_FOLDER).mkdir()
        (root / ui.UNIT_FOLDER / "Units.swift").write_text("final class UnitsTests: XCTestCase {\n" + "    func testX() {}\n" * 6 + "}\n")
        return root

    def test_a_class_with_no_recorded_time_is_counted_by_its_tests_and_its_bundle(self):
        seconds = ui.estimated_seconds(["BigUITests", "SmallUITests", "UnitsTests", "Nowhere"], self.sized(), times={})
        # Each test of a bundle counts as that bundle's SECONDS_PER_TEST: an interface test 25 seconds, a unit test a
        # small fraction of one; a class in neither bundle counts as the shard default.
        per_unit_test = ui.SECONDS_PER_TEST[ui.UNIT_BUNDLE]
        self.assertEqual(seconds["BigUITests"], 4 * ui.SECONDS_PER_TEST[ui.UI_BUNDLE])
        self.assertEqual(seconds["SmallUITests"], ui.SECONDS_PER_TEST[ui.UI_BUNDLE])
        self.assertAlmostEqual(seconds["UnitsTests"], 6 * per_unit_test)
        self.assertEqual(seconds["Nowhere"], 1.0)
        # An interface test costs far more than a unit test, so a big unit class never outweighs an interface test.
        self.assertLess(per_unit_test, ui.SECONDS_PER_TEST[ui.UI_BUNDLE] / 100)

    def test_a_recorded_time_wins_over_the_estimate(self):
        seconds = ui.estimated_seconds(["BigUITests"], self.sized(), times={"BigUITests": 7.5})
        self.assertEqual(seconds, {"BigUITests": 7.5})

    def test_the_slices_cover_every_class_once_and_do_not_depend_on_the_order(self):
        root = self.sized()
        classes = ui.all_classes(root)
        for count in (2, 3):
            with self.subTest(count=count):
                slices = [ui.slice_for(classes, number, count, root, times={}) for number in range(1, count + 1)]
                self.assertEqual(sorted(name for one in slices for name in one), sorted(classes))
                self.assertEqual(slices, [ui.slice_for(list(reversed(classes)), n, count, root, times={}) for n in range(1, count + 1)])

    def test_one_job_gets_every_class_in_the_order_given(self):
        root = self.sized()
        self.assertEqual(ui.slice_for(["UnitsTests", "BigUITests"], 1, 1, root, times={}), ["UnitsTests", "BigUITests"])

    def test_the_count_grows_with_the_seconds_and_stops_at_the_most(self):
        root = self.sized()
        classes = ui.all_classes(root)
        self.assertEqual(ui.shard_count(["SmallUITests"], root, times={}), 1)
        self.assertEqual(ui.shard_count(classes, root, times={}), 1, "131 seconds is within one job's share")
        self.assertEqual(ui.shard_count(classes, root, times={"BigUITests": 900}), 2)
        self.assertEqual(ui.shard_count(classes, root, times={"BigUITests": 99999}), ui.MAX_SHARDS)
        self.assertEqual(ui.shard_count([], root, times={}), 1)

    def test_the_real_tree_needs_more_than_one_job_and_its_times_file_reads(self):
        self.assertGreater(ui.shard_count(ui.all_classes(ROOT), ROOT), 1)
        self.assertIsInstance(ui.load_times(), dict)

    def test_the_full_suite_is_dealt_into_jobs_that_end_within_ten_percent_of_each_other(self):
        """The real tree's measured times (ios-class-times.json) are more than one job's share, and the jobs they are dealt
        into end within 10 percent of each other, each class in exactly one. How many jobs is not pinned here, since every
        branch that adds an iPhone test moves the total; the plan's tests pin counts on figures of their own
        (test_plan_shards.py)."""
        classes = ui.all_classes(ROOT)
        count = ui.shard_count(classes, ROOT)
        self.assertGreaterEqual(count, 2, "the full suite's iPhone tests are more than one job's share")
        self.assertLessEqual(count, ui.MAX_SHARDS)
        seconds = ui.estimated_seconds(classes, ROOT)
        jobs = range(1, count + 1)
        shares = [sum(seconds[name] for name in ui.slice_for(classes, number, count, ROOT)) for number in jobs]
        self.assertLess(max(shares) - min(shares), 0.10 * max(shares), shares)
        # Every class is in exactly one job.
        dealt = [name for number in jobs for name in ui.slice_for(classes, number, count, ROOT)]
        self.assertEqual(sorted(dealt), sorted(classes))


if __name__ == "__main__":
    unittest.main()
