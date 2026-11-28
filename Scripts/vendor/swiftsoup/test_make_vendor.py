#!/usr/bin/env python3
"""Tests of make_vendor.py: run `python3 -I Scripts/vendor/swiftsoup/test_make_vendor.py`.

The one that matters most is test_the_release_and_its_copy_differ_only_by_attributes:
with the attribute words taken out of both the release and the copy, and the
white space between words ignored, the two are equal for every file, so no
statement of SwiftSoup's parser was touched. It needs the release's checkout
(the one Xcode's package resolution made in the main checkout) and is skipped
without it; the other tests use a small release written to a temporary folder.
"""
import contextlib
import io
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_vendor  # noqa: E402  (imported by path, after sys.path is set)

# The words and attributes the script may add or remove, written afresh here
# (not taken from the script) so the proof does not share the script's mistakes.
ATTRIBUTE_WORDS = re.compile(r"@inline\(__always\)|@inlinable|@usableFromInline|\bpublic\b|\bopen\b|\bfinal\b")


def without_attributes(text):
    """`text` with every attribute word removed and every run of white space
    made one space, so two texts that differ only by those compare equal."""
    return " ".join(ATTRIBUTE_WORDS.sub(" ", text).split())


class OnlyAttributesChange(unittest.TestCase):
    """The copy differs from the release by attribute words alone."""

    def test_the_release_and_its_copy_differ_only_by_attributes(self):
        source = make_vendor.DEFAULT_SOURCE
        if not (source / "Sources").is_dir():
            self.skipTest(f"no SwiftSoup checkout at {source}")
        texts, _license = make_vendor.read_release(source)
        files = make_vendor.planned_files(source)
        copied = {name[len("Sources/"):]: text for name, text in files.items() if name.startswith("Sources/")}
        # No file is left out and none is added.
        self.assertEqual(sorted(texts), sorted(copied))
        self.assertGreater(len(texts), 50)
        for name, text in texts.items():
            self.assertEqual(without_attributes(text), without_attributes(copied[name]), name)
        # The edits happened: something was made internal, something final.
        changed = sum(1 for name in texts if texts[name] != copied[name])
        self.assertGreater(changed, 40)
        self.assertNotIn("@inline(__always)", "".join(copied.values()))

    def test_the_comparison_notices_a_changed_statement(self):
        # The comparison above would pass for any copy if it ignored too
        # much: a one-character change to a body must make it differ.
        release = "public func f() -> Int {\n    return 1\n}\n"
        copy = "func f() -> Int {\n    return 2\n}\n"
        self.assertNotEqual(without_attributes(release), without_attributes(copy))
        self.assertEqual(without_attributes(release), without_attributes("func f() -> Int {\n    return 1\n}\n"))

    def test_the_committed_copy_is_what_the_script_writes(self):
        source = make_vendor.DEFAULT_SOURCE
        if not (source / "Sources").is_dir() or not (make_vendor.DEFAULT_OUTPUT / "Sources").is_dir():
            self.skipTest("no SwiftSoup checkout, or no Vendor/SwiftSoup, to compare")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            status = make_vendor.main(["--check"])
        self.assertEqual(status, 0, output.getvalue())


class Rules(unittest.TestCase):
    """Each edit, on a small release."""

    # A release in miniature: public API that is called and not called, an
    # open class with an override, a class that is inherited from, one that is
    # not, inlining attributes, and a method that shares a called name.
    RELEASE = {
        "A.swift": (
            "import Foundation\n"
            "open class Base {\n"
            "    @inline(__always)\n"
            "    public func called() {}\n"
            "    open func notCalled() {}\n"
            "    @inlinable public var number: Int { 1 }\n"
            "}\n"
            "open class Child: Base {\n"
            "    open override func notCalled() { }\n"
            "}\n"
            "public class Leaf {\n"
            "    @inline(__always) public func html(accum: Internal) {}\n"
            "    public func html() {}\n"
            "}\n"
            "class Plain {}\n"
            "public final class AlreadyFinal {}\n"
            "public struct S { public var x = 0 }\n"
        ),
    }
    ALLOWED = {"called", "html", "Leaf"}
    FORCED = {"A.swift": {"public func html(accum: Internal) {}"}}

    def transformed(self, forced=None):
        return make_vendor.transform(self.RELEASE, self.ALLOWED, self.FORCED if forced is None else forced)["A.swift"]

    def test_inline_attributes_go_whether_on_their_own_line_or_not(self):
        self.assertNotIn("__always", self.transformed())
        self.assertNotIn("@inlinable", self.transformed())

    def test_an_allowed_name_stays_public_and_others_become_internal(self):
        text = self.transformed()
        self.assertIn("public func called() {}", text)
        self.assertIn("public func html() {}", text)
        self.assertIn("\n    func notCalled() {}", text)
        self.assertIn("var number: Int", text)
        self.assertNotIn("public var number", text)

    def test_a_forced_internal_line_loses_public_though_its_name_is_allowed(self):
        self.assertIn("    func html(accum: Internal) {}", self.transformed())
        self.assertNotIn("public func html(accum", self.transformed())

    def test_an_allowed_open_becomes_public_and_a_name_not_allowed_becomes_internal(self):
        text = make_vendor.transform({"B.swift": "open func called() {}\nopen func other() {}\n"}, self.ALLOWED, {})["B.swift"]
        self.assertEqual(text, "public func called() {}\nfunc other() {}\n")

    def test_only_classes_nothing_inherits_from_become_final(self):
        text = self.transformed()
        self.assertIn("class Base {", text)
        self.assertNotIn("final class Base", text)
        self.assertIn("final class Child: Base {", text)
        self.assertIn("final class Plain {}", text)
        self.assertIn("final class AlreadyFinal {}", text)
        self.assertNotIn("final final", text)

    def test_an_entry_the_release_does_not_have_is_reported(self):
        with self.assertRaises(make_vendor.VendorError) as problem:
            self.transformed({"A.swift": {"public func gone() {}"}})
        self.assertIn("public func gone() {}", str(problem.exception))

    def test_a_change_to_a_statement_is_not_an_attribute_change(self):
        # What the script writes differs from the release by attributes alone.
        copy = self.transformed()
        self.assertEqual(without_attributes(self.RELEASE["A.swift"]), without_attributes(copy))


class Files(unittest.TestCase):
    """Writing, checking, and the lists."""

    def make_release(self, folder):
        """Writes the miniature release under `folder` and returns it."""
        (folder / "Sources").mkdir(parents=True)
        for name, text in Rules.RELEASE.items():
            (folder / "Sources" / name).write_text(text, encoding="utf-8")
        (folder / "LICENSE").write_text("The MIT License\r\nline two\r\n", encoding="utf-8", newline="")
        return folder

    def lists(self, folder):
        """Writes lists for the miniature release and returns their options."""
        allow, internal = folder / "allow.txt", folder / "internal.txt"
        allow.write_text("# a comment\ncalled\nhtml  # trailing comment\nLeaf\n", encoding="utf-8")
        internal.write_text("A.swift: public func html(accum: Internal) {}\n", encoding="utf-8")
        return ["--allow", str(allow), "--internal", str(internal)]

    def test_write_then_check_agree_and_a_change_is_found(self):
        with tempfile.TemporaryDirectory() as scratch:
            folder = Path(scratch)
            release = self.make_release(folder / "release")
            options = self.lists(folder)
            output = folder / "out"
            arguments = ["--source", str(release), "--output", str(output)] + options
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(make_vendor.main(arguments), 0)
                self.assertEqual(make_vendor.main(arguments + ["--check"]), 0, "a fresh write checks clean")
            self.assertTrue((output / "Sources" / "A.swift").exists())
            self.assertEqual(
                (output / "LICENSE").read_bytes(), b"The MIT License\r\nline two\r\n", "the licence is copied exactly"
            )
            # A hand edit, and a stray file, are both found.
            (output / "Sources" / "A.swift").write_text("// edited\n", encoding="utf-8")
            (output / "Sources" / "Old.swift").write_text("", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as report:
                self.assertEqual(make_vendor.main(arguments + ["--check"]), 1)
            self.assertIn("differs: Sources/A.swift", report.getvalue())
            self.assertIn("extra: Sources/Old.swift", report.getvalue())

    def test_a_list_entry_the_release_lacks_stops_the_script(self):
        with tempfile.TemporaryDirectory() as scratch:
            folder = Path(scratch)
            release = self.make_release(folder / "release")
            options = self.lists(folder)
            (folder / "internal.txt").write_text("A.swift: public func gone() {}\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()) as errors:
                status = make_vendor.main(["--source", str(release), "--output", str(folder / "out")] + options)
            self.assertEqual(status, 2)
            self.assertIn("public func gone() {}", errors.getvalue())
            self.assertFalse((folder / "out").exists(), "nothing is written when a list is stale")

    def test_line_endings_are_kept(self):
        with tempfile.TemporaryDirectory() as scratch:
            release = self.make_release(Path(scratch) / "release")
            self.assertEqual(make_vendor.read_release(release)[1], "The MIT License\r\nline two\r\n")

    def test_the_lists_hold_no_duplicates_and_the_names_are_plain(self):
        names = [line.split("#")[0].strip() for line in make_vendor.ALLOW_LIST.read_text(encoding="utf-8").splitlines()]
        names = [name for name in names if name]
        self.assertEqual(len(names), len(set(names)), "a name twice in allow-api.txt")
        self.assertTrue(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*|[-+*/=<>!&|^~%?.]+", name) for name in names))
        entries = make_vendor.read_internal_list(make_vendor.INTERNAL_LIST)
        self.assertGreater(sum(len(lines) for lines in entries.values()), 5)

    def test_the_lists_are_in_version_control(self):
        """Both name lists are tracked by git. The repository's .gitignore ignores
        every *.txt file, so a list added without -f stays on one disk, and no
        other checkout can run the script or these tests."""
        for path in (make_vendor.ALLOW_LIST, make_vendor.INTERNAL_LIST):
            result = subprocess.run(["git", "ls-files", "--error-unmatch", path.name],
                                    cwd=path.parent, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, f"{path.name} is not tracked by git: add it with git add -f")


if __name__ == "__main__":
    unittest.main()
