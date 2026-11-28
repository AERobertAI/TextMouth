"""Tests of testkit.hosted_test_classes: how the Mac's test classes are found for run-area.py and the trains.

The finder skipped every column-0 line that began with an attribute, so `@MainActor final class SyncCenterTests: XCTestCase {`
was never declared: run-area.py refused the request with "no class named 'SyncCenterTests'", and train 1125-2059 (November 25,
2026) ran no Mac test at all.
"""
import re
import tempfile
import unittest
from pathlib import Path

import testkit_path  # noqa: F401  (puts Scripts/test on the path)
import testkit

# The repository's root: Scripts/agents/tests is three folders below it.
ROOT = Path(__file__).resolve().parents[3]


class HostedTestClassesTests(unittest.TestCase):
    """Classes declared with attributes on their own line or on the class line are found, with their tests."""

    def classes(self, **files):
        """hosted_test_classes of a folder holding `files` ({name: Swift source}), as {class: test count}."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        tests = Path(folder.name) / testkit.TESTS_FOLDER
        tests.mkdir()
        for name, source in files.items():
            (tests / f"{name}.swift").write_text(source, encoding="utf-8")
        return {name: found.test_count for name, found in testkit.hosted_test_classes(Path(folder.name)).items()}

    def test_an_attribute_on_the_class_line_declares_the_class(self):
        found = self.classes(A="@MainActor final class ATests: XCTestCase {\n    func testA() {}\n    func testB() {}\n}\n",
                             B="@available(macOS 26, *) @MainActor final class BTests: XCTestCase {\n    func testC() {}\n}\n")
        self.assertEqual(found, {"ATests": 2, "BTests": 1})

    def test_an_attribute_on_its_own_line_still_declares_the_class_below_it(self):
        found = self.classes(A="@MainActor\nfinal class ATests: XCTestCase {\n    func testA() {}\n}\n")
        self.assertEqual(found, {"ATests": 1})

    def test_an_attribute_line_between_scopes_ends_none(self):
        # A free function's attribute at column 0 neither opens a scope nor closes the extension it follows.
        found = self.classes(A="final class ATests: XCTestCase {\n    func testA() {}\n}\n"
                               "extension ATests {\n@MainActor\n    func testMore() {}\n}\n")
        self.assertEqual(found, {"ATests": 2})

    def test_every_class_declared_in_the_mac_test_folder_is_found(self):
        """A plain search of the folder and the finder agree on the top-level classes: a class the finder misses is
        refused by run-area.py, and a train that names it runs no Mac test."""
        plain = re.compile(r"^(?:@\w+(?:\([^)]*\))?\s+)*(?:\w+\s+)*class\s+([A-Za-z_]\w*)\s*:", re.M)
        folder = ROOT / testkit.TESTS_FOLDER
        declared = {name for path in folder.glob("*.swift")
                    for name in plain.findall(path.read_text(encoding="utf-8", errors="replace"))}
        self.assertGreater(len(declared), 100, "the search found almost no class: it is broken")
        found = set(testkit.hosted_test_classes(ROOT))
        self.assertEqual(sorted(declared - found), [], "classes the finder misses, which run-area.py would refuse")


if __name__ == "__main__":
    unittest.main()
