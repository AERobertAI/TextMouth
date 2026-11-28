"""Tests of `l10n.py reach`: the test classes a branch's localization could break (TL13).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Each test builds a small repository of its own (an app folder, a Mac test folder, an iPhone test folder) with a branch
that localizes some text, and asks which test classes are reached and why.
"""
import contextlib
import io
import json
import sys
import unittest
import unittest.mock
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import l10n  # noqa: E402  (imported by path, after sys.path is set)
import reach  # noqa: E402
from git_case import HAS_GIT, GitCase  # noqa: E402


def test_class(name, body=""):
    """A Swift test file holding one class `name` with one test, whose body holds `body`."""
    return f"import XCTest\n\nfinal class {name}: XCTestCase {{\n    func testOne() {{\n        {body}\n    }}\n}}\n"


# The app file before a wave and after it: the title is localized, an old localized text is left alone, and a text with an
# interpolation is localized too.
BEFORE = '''import SwiftUI

struct SleepPanel: View {
    var minutes: Int
    let old = String(localized: "An old text that was localized long ago", comment: "Old")
    var title: String { "Sleep timer is running" }
    var left: String { "Time remaining: \\(minutes)" }
    var short: String { "Done" }
    var body: some View { Text(title) }
}
'''
AFTER = '''import SwiftUI

struct SleepPanel: View {
    var minutes: Int
    let old = String(localized: "An old text that was localized long ago", comment: "Old")
    var title: String { String(localized: "Sleep timer is running", comment: "Header") }
    var left: String { String(localized: "Time remaining: \\(minutes)", comment: "Footer") }
    var short: String { String(localized: "Done", comment: "A button") }
    var body: some View { Text(title) }
}
'''


@unittest.skipUnless(HAS_GIT, "git is not installed")
class ReachTests(GitCase):
    """A repository whose branch `wave` localizes the file `TextMouth/Views/SleepPanel.swift`."""

    APP = "TextMouth/Views/SleepPanel.swift"

    def setUp(self):
        super().setUp()
        self.put(self.APP, BEFORE)
        self.put("TextMouth/Models/Counter.swift", "struct Counter {}\n")
        self.put("TextMouthProductionTests/UntouchedTests.swift", test_class("UntouchedTests", 'XCTAssertEqual(1, 1)'))
        self.put("TextMouthProductionTests/TitleTests.swift", test_class("TitleTests", 'XCTAssertEqual(x, "Sleep timer is running")'))
        self.put("TextMouthProductionTests/FooterTests.swift", test_class("FooterTests", 'XCTAssertEqual(x, "Time remaining: 5 minutes")'))
        self.put("TextMouthProductionTests/ShortTests.swift", test_class("ShortTests", 'XCTAssertEqual(x, "Done")'))
        self.put("TextMouthProductionTests/OldTests.swift", test_class("OldTests", 'XCTAssertEqual(x, "An old text that was localized long ago")'))
        self.put("TextMouthProductionTests/SourceReaderTests.swift",
                 test_class("SourceReaderTests", 'read("TextMouth/Views/SleepPanel.swift")'))
        self.put("TextMouthProductionTests/CounterTests.swift", test_class("CounterTests", "_ = Counter()"))
        self.put("TextMouthiOSTests/PhoneTitleTests.swift", test_class("PhoneTitleTests", 'XCTAssertEqual(x, "Sleep timer is running")'))
        self.put("TextMouthiOSTests/PhoneUntouchedTests.swift", test_class("PhoneUntouchedTests", "XCTAssertTrue(true)"))
        self.commit_all("base")
        self.branch_from_main("wave")

    def localize(self):
        """Commits the wave: the app file gets its localized texts."""
        self.put(self.APP, AFTER)
        self.git("commit", "-q", "-am", "wave")

    def reached(self):
        """What the branch reaches, as {"mac": {...}, "phone": {...}}."""
        return reach.reach(self.repo, "main")

    def test_a_class_holding_a_localized_english_text_is_reached_with_its_reason(self):
        self.localize()
        mac = self.reached()["mac"]
        self.assertIn('compares the English text "Sleep timer is running"', mac["TitleTests"])

    def test_a_text_is_cut_at_its_first_interpolation(self):
        self.localize()
        self.assertIn('compares the English text "Time remaining: "', self.reached()["mac"]["FooterTests"])

    def test_a_short_text_and_an_old_localized_one_reach_nothing(self):
        self.localize()
        mac = self.reached()["mac"]
        self.assertNotIn("ShortTests", mac, "Done is under 12 characters")
        self.assertNotIn("OldTests", mac, "the branch did not add that text")
        self.assertNotIn("UntouchedTests", mac)

    def test_a_class_that_names_a_converted_file_is_reached_since_it_reads_the_source(self):
        self.localize()
        self.assertIn("reads the source of TextMouth/Views/SleepPanel.swift", self.reached()["mac"]["SourceReaderTests"])

    def test_a_file_that_gained_no_localized_text_is_not_a_converted_file(self):
        self.put(self.APP, BEFORE.replace("var minutes: Int", "var minutes: Int\n    var more = 1"))
        self.git("commit", "-q", "-am", "an edit")
        for reasons in self.reached()["mac"].values():
            self.assertFalse([reason for reason in reasons if reason.startswith("reads the source")], reasons)

    def test_a_class_that_mentions_a_changed_type_is_reached_as_run_area_finds_it(self):
        self.put("TextMouth/Models/Counter.swift", "struct Counter { var step = 1 }\n")
        self.git("commit", "-q", "-am", "an edit")
        self.assertEqual(self.reached()["mac"]["CounterTests"], ["mentions Counter"])

    def test_a_class_in_a_changed_test_file_is_reached(self):
        self.put("TextMouthProductionTests/UntouchedTests.swift", test_class("UntouchedTests", 'XCTAssertEqual(2, 2)'))
        self.git("commit", "-q", "-am", "a test edit")
        self.assertEqual(self.reached()["mac"]["UntouchedTests"], ["declared in a changed test file"])

    def test_an_iphone_class_comes_out_under_the_phone_bundle_and_not_the_mac_one(self):
        self.localize()
        reached = self.reached()
        self.assertIn("PhoneTitleTests", reached["phone"])
        self.assertNotIn("PhoneTitleTests", reached["mac"])
        self.assertNotIn("TitleTests", reached["phone"])
        self.assertNotIn("PhoneUntouchedTests", reached["phone"])

    def test_a_changed_iphone_test_file_is_reached(self):
        self.put("TextMouthiOSTests/PhoneUntouchedTests.swift", test_class("PhoneUntouchedTests", "XCTAssertFalse(false)"))
        self.git("commit", "-q", "-am", "a phone test edit")
        self.assertEqual(self.reached()["phone"]["PhoneUntouchedTests"], ["declared in a changed test file"])

    def test_uncommitted_and_untracked_work_counts_too(self):
        self.put(self.APP, AFTER)
        self.put("TextMouth/Views/New.swift", 'let a = String(localized: "A brand new localized text", comment: "c")\n')
        self.put("TextMouthProductionTests/NewTextTests.swift", test_class("NewTextTests", '"A brand new localized text"'))
        mac = self.reached()["mac"]
        self.assertIn("TitleTests", mac)
        self.assertIn('compares the English text "A brand new localized text"', mac["NewTextTests"])

    def test_a_branch_that_changed_nothing_reaches_nothing(self):
        self.assertEqual(self.reached(), {"mac": {}, "phone": {}})

    def test_the_plain_output_is_one_comma_separated_line_for_the_mac_and_a_headed_line_for_the_iphone(self):
        self.localize()
        lines = reach.format_reach(self.reached())
        self.assertEqual(len(lines), 2)
        self.assertNotIn(" ", lines[0])
        self.assertEqual(lines[0], ",".join(sorted(lines[0].split(","))))
        self.assertIn("FooterTests", lines[0].split(","))
        self.assertTrue(lines[1].startswith("iPhone unit tests"))
        self.assertTrue(lines[1].endswith(": PhoneTitleTests"))

    def test_without_an_iphone_class_there_is_only_the_mac_line(self):
        self.put("TextMouth/Models/Counter.swift", "struct Counter { var step = 1 }\n")
        self.git("commit", "-q", "-am", "an edit")
        self.assertEqual(reach.format_reach(self.reached()), ["CounterTests"])

    def test_explain_gives_each_class_and_reason_on_a_line_under_its_bundle(self):
        self.localize()
        lines = reach.format_reach(self.reached(), explain=True)
        self.assertIn('  TitleTests: compares the English text "Sleep timer is running"', lines)
        self.assertIn("  SourceReaderTests: reads the source of TextMouth/Views/SleepPanel.swift", lines)
        self.assertIn('  PhoneTitleTests: compares the English text "Sleep timer is running"', lines)
        heads = [line for line in lines if not line.startswith(" ")]
        self.assertEqual(len(heads), 2)
        self.assertLess(lines.index('  TitleTests: compares the English text "Sleep timer is running"'), lines.index(heads[1]))
        self.assertGreater(lines.index('  PhoneTitleTests: compares the English text "Sleep timer is running"'), lines.index(heads[1]))

    def test_the_command_prints_the_line_and_json_names_the_reasons(self):
        self.localize()
        # The command reads the checkout it is in; the scratch repository stands in for it.
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            patch_root = unittest.mock.patch.object(l10n, "ROOT", self.repo)
            with patch_root:
                status = l10n.main(["reach", "--json"])
        self.assertEqual(status, 0)
        data = json.loads(out.getvalue())
        self.assertIn("TitleTests", data["mac"])
        self.assertIn("PhoneTitleTests", data["phone"])

    def test_an_unknown_base_is_refused_with_status_2(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), unittest.mock.patch.object(l10n, "ROOT", self.repo):
            status = l10n.main(["reach", "--base", "no-such-branch"])
        self.assertEqual(status, 2)
        self.assertIn("reach:", err.getvalue())


class PhraseTests(unittest.TestCase):
    """`phrases_of`: the English a source line localizes."""

    def test_the_text_is_cut_at_the_first_interpolation_and_kept_at_twelve_characters(self):
        self.assertEqual(reach.phrases_of('String(localized: "Time remaining: \\(n) of \\(m)", comment: "c")'), ["Time remaining: "])
        self.assertEqual(reach.phrases_of('String(localized: "Exactly 12 ch", comment: "c")'), ["Exactly 12 ch"])
        self.assertEqual(reach.phrases_of('String(localized: "Eleven char", comment: "c")'), [])

    def test_escaped_quotes_are_undone_and_each_call_on_a_line_counts(self):
        line = 'a(String(localized: "Say \\"hello\\" to everyone", comment: "c"), String(localized: "Another long text", comment: "d"))'
        self.assertEqual(reach.phrases_of(line), ['Say "hello" to everyone', "Another long text"])

    def test_the_english_of_an_interface_text_call_counts_as_much_as_a_string_localized_call(self):
        line = 'x(InterfaceText.line("feed.folderMissing", "The folder of \\(name) is gone."), InterfaceText.line("a.b", "Short"))'
        self.assertEqual(reach.phrases_of(line), ["The folder of "])
        self.assertEqual(reach.phrases_of('InterfaceText.line("a.b", "Exactly 12 ch", language: "es")'), ["Exactly 12 ch"])

    def test_the_id_of_an_interface_text_call_is_never_taken_for_an_english_phrase(self):
        self.assertEqual(reach.phrases_of('InterfaceText.line("a.b", someFormat)'), [])


if __name__ == "__main__":
    unittest.main()
