"""The report and show commands, on small trees of their own, and the scanner's speed on the app."""

from __future__ import annotations

import json
import unittest

from scan_case import REPO, TreeCase, run_main

from swiftscan import scanner


class ReportTests(TreeCase):
    """`scan.py report` totals the interface text by area or by file."""

    def setUp(self) -> None:
        super().setUp()
        # A feed file (area feeds): one localized literal, two unlocalized (one with a
        # two-byte letter), one marked, one glued sentence, and a log line that is not counted.
        self.write("Views/Feeds/FeedSnippet.swift", (
            'import SwiftUI\n'
            'struct FeedSnippet: View {\n'
            '    var body: some View {\n'
            '        Text("Add Feed")\n'
            '    }\n'
            '    static let title = "Café feeds"\n'
            '    func note(_ name: String) -> String { "Subscribed to " + name }\n'
            '    let tag = "Feed identifier text" // l10n: no\n'
            '    func trace() { print("Feed trace: starting up") }\n'
            '}\n'))
        # A file of the sleep timer: one wording literal.
        self.write("Models/SleepTimerWording.swift", 'enum SleepTimerWording {\n    static func off() -> String { "Sleep timer is off" }\n}\n')

    def test_the_text_report_by_area(self) -> None:
        status, out, _err = run_main("--root", str(self.root), "report")
        self.assertEqual(status, 0)
        lines = out.splitlines()
        self.assertTrue(lines[0].startswith("Interface text of 2 Swift files"), lines[0])
        rows = {line.split()[0]: line.split() for line in lines if line[:1].isalpha() and line.split()[0] in ("feeds", "sleep-timer", "total")}
        # name files unloc bytes loc bytes marked glued plural static
        self.assertEqual(rows["feeds"][1:], ["1", "2", "25", "1", "8", "1", "1", "0", "1"])
        self.assertEqual(rows["sleep-timer"][1:], ["1", "1", "18", "0", "0", "0", "0", "0", "0"])
        self.assertEqual(rows["total"][1:4], ["2", "3", "43"])

    def test_the_json_report_has_exact_counts(self) -> None:
        status, out, _err = run_main("--root", str(self.root), "report", "--json")
        self.assertEqual(status, 0)
        data = json.loads(out)
        groups = {g["name"]: g for g in data["groups"]}
        feeds = groups["feeds"]
        # "Café feeds" is 11 bytes in UTF-8, "Subscribed to " 14, "%@"-free; Add Feed is localized.
        self.assertEqual(feeds["unlocalized"], {"count": 2, "bytes": 11 + 14})
        self.assertEqual(feeds["files"], 1)
        self.assertEqual(feeds["localized"], {"count": 1, "bytes": 8})
        self.assertEqual(feeds["marked"], {"count": 1, "bytes": len("Feed identifier text")})
        self.assertEqual(feeds["findings"], {"glued": 1, "plural": 0, "static-let": 1})
        self.assertEqual(groups["sleep-timer"]["unlocalized"], {"count": 1, "bytes": len("Sleep timer is off")})
        self.assertEqual(data["files"], 2)
        # The log line is in its own bucket and is not interface text.
        self.assertIn("log", data["buckets"])

    def test_the_json_groups_are_sorted_by_unlocalized_bytes(self) -> None:
        _status, out, _err = run_main("--root", str(self.root), "report", "--json")
        sizes = [g["unlocalized"]["bytes"] for g in json.loads(out)["groups"]]
        self.assertEqual(sizes, sorted(sizes, reverse=True))

    def test_the_report_by_file_and_by_area_filter(self) -> None:
        _status, out, _err = run_main("--root", str(self.root), "report", "--by", "file", "--json")
        names = [g["name"] for g in json.loads(out)["groups"]]
        self.assertEqual(sorted(names), ["TextMouth/Models/SleepTimerWording.swift", "TextMouth/Views/Feeds/FeedSnippet.swift"])
        _status, out, _err = run_main("--root", str(self.root), "report", "--by", "file", "--area", "feeds", "--json")
        self.assertEqual([g["name"] for g in json.loads(out)["groups"]], ["TextMouth/Views/Feeds/FeedSnippet.swift"])

    def test_an_unknown_area_is_a_usage_error(self) -> None:
        status, _out, err = run_main("--root", str(self.root), "report", "--by", "file", "--area", "nonesuch")
        self.assertEqual(status, 2)
        self.assertIn("no area named nonesuch", err)

    def test_a_file_in_no_area_is_named_in_the_report(self) -> None:
        self.write("Models/ZzzNoSuchFeature.swift", 'enum Zzz { static let a = "A sentence of text" }\n')
        _status, out, _err = run_main("--root", str(self.root), "report")
        self.assertIn("unmapped", out)
        self.assertIn("1 files are in no area", out)

    def test_a_missing_source_folder_is_a_usage_error(self) -> None:
        status, _out, err = run_main("--root", str(self.root / "TextMouth"), "report")
        self.assertEqual(status, 2)
        self.assertIn("no TextMouth/ folder", err)

    def test_no_command_and_help_follow_the_exit_codes(self) -> None:
        self.assertEqual(run_main()[0], 2)
        self.assertEqual(run_main("--help")[0], 0)
        self.assertEqual(run_main("report", "--by", "nonsense")[0], 2)


class ShowTests(TreeCase):
    """`scan.py show FILE` lists one file's unlocalized literals for the agent converting it."""

    def setUp(self) -> None:
        super().setUp()
        self.write("Models/CountSnippetWording.swift", (
            'enum CountSnippetWording {\n'
            '    static let title = "Counted things"\n'            # line 2: unlocalized, static let
            '    static var done: String { "All done here" }\n'    # line 3: unlocalized
            '    static let key = "snippet.key"\n'                 # line 4: a token, not listed
            '    static func few(_ n: Int) -> String { "Found \\(n) " + (n == 1 ? one : many) }\n'  # line 5
            '    static let skip = "Left alone on purpose" // l10n: no\n'  # line 6: marked
            '}\n'))

    def test_show_lists_each_unlocalized_literal_with_its_line_and_bucket(self) -> None:
        status, out, _err = run_main("--root", str(self.root), "show", "Models/CountSnippetWording.swift")
        self.assertEqual(status, 0)
        lines = out.splitlines()
        self.assertTrue(lines[0].startswith("TextMouth/Models/CountSnippetWording.swift (area "), lines[0])
        self.assertTrue(lines[0].endswith("): 3 unlocalized, 0 localized, 1 marked."), lines[0])
        listed = [line.strip() for line in lines if line.startswith("  line")]
        self.assertEqual(listed[0], 'line 2 [wording] "Counted things"')
        self.assertEqual(listed[1], 'line 3 [wording] "All done here"')
        self.assertTrue(listed[2].startswith("line 5 [wording]"), listed)
        self.assertNotIn("Left alone", out)
        # The findings come after: the static let and the glued and plural line 5.
        self.assertIn("line 2: static-let", out)
        self.assertIn("line 5: glued", out)
        self.assertIn("line 5: plural", out)

    def test_show_all_adds_the_localized_and_the_marked(self) -> None:
        _status, out, _err = run_main("--root", str(self.root), "show", "--all", "TextMouth/Models/CountSnippetWording.swift")
        self.assertIn('line 6 [wording] marked "Left alone on purpose"', out)

    def test_show_as_json(self) -> None:
        _status, out, _err = run_main("--root", str(self.root), "show", "Models/CountSnippetWording.swift", "--json")
        data = json.loads(out)
        self.assertEqual((data["unlocalized"], data["marked"]), (3, 1))
        self.assertEqual(data["literals"][0], {"line": 2, "bucket": "wording", "rule": "wording-type",
                                               "status": "unlocalized", "text": "Counted things", "findings": ["static-let"]})

    def test_show_cuts_a_long_literal_to_the_width(self) -> None:
        self.write("Models/LongWording.swift", 'enum LongWording {\n    static var a: String { "' + "word " * 40 + 'end" }\n}\n')
        _status, out, _err = run_main("--root", str(self.root), "show", "Models/LongWording.swift", "--width", "50")
        listed = [line for line in out.splitlines() if line.startswith("  line")]
        self.assertLessEqual(len(listed[0]), 52)
        self.assertTrue(listed[0].endswith("…"))

    def test_show_of_a_file_that_is_not_scanned_is_a_usage_error(self) -> None:
        status, _out, err = run_main("--root", str(self.root), "show", "Models/NoSuchFile.swift")
        self.assertEqual(status, 2)
        self.assertIn("is not a Swift file under TextMouth/", err)


class SpeedTests(unittest.TestCase):
    """The whole of TextMouth/ is scanned in well under 20 seconds."""

    def test_the_app_scans_in_under_twenty_seconds(self) -> None:
        if not (REPO / "TextMouth").is_dir():
            self.skipTest("no TextMouth/ folder beside the scripts")
        result = scanner.scan_tree(REPO)
        self.assertGreater(len(result.literals), 10000)
        self.assertLess(result.seconds, 20)


if __name__ == "__main__":
    unittest.main()
