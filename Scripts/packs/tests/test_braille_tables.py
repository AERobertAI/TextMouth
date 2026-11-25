"""Tests of `braille_tables.py`, the builder of the braille-table pack (FR40).

Run with: python3 -I -B -m unittest discover -s Scripts/packs/tests
(and with /usr/bin/python3, the interpreter the Xcode build phase uses).

The first classes use small folders the tests make; `RealTablesTests` builds the packs of the vendored release once and checks
what the apps' reader will rely on: every file in one group, the closures, the bytes, the license list, and the Mac's list.
"""
import contextlib
import hashlib
import io
import json
import re
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import braille_tables as bt  # noqa: E402  (imported by path, after sys.path is set)
import packfile  # noqa: E402

LGPL = (b"#  liblouis is free software: you can redistribute it and/or modify it\n"
        b"#  under the terms of the GNU Lesser General Public License as\n"
        b"#  published by the Free Software Foundation, either version %s of the\n"
        b"#  License, or (at your option) any later version.\n")


def table(version=b"2.1", body=b""):
    """The bytes of a table file with a license head of the Lesser General Public License `version` and `body`."""
    return b"#+type:literary\n#+language:xx\n#-display-name: A table\n" + LGPL % version + body


def folder_of(files):
    """A temporary folder holding `files` ({name: bytes}) and the Mac's list file name, kept alive by the caller."""
    holder = tempfile.TemporaryDirectory()
    for name, data in files.items():
        Path(holder.name, name).write_bytes(data)
    return holder


class HeaderTests(unittest.TestCase):
    """The header fields are read by the rules of BrailleTableCatalog.headerFields."""

    def test_the_fields_of_a_header(self):
        text = "# liblouis: a table\n\n#-name: Old\n#+language: en\n#+TYPE:  literary \n#+contraction:full\n#-display-name:  Unified   English\n include x\n#+grade:2\n"
        self.assertEqual({"name": "Old", "language": "en", "type": "literary", "contraction": "full", "display-name": "Unified English"},
                         bt.header_fields(text))

    def test_the_first_value_of_a_key_wins_and_plain_comments_are_not_fields(self):
        text = "#+language:en\n#+language:fr\n#--language:de\n#+ spaced key: no\n#+nocolon\n#+empty:   \n# plain: comment\n"
        self.assertEqual({"language": "en"}, bt.header_fields(text))

    def test_the_first_line_of_anything_else_ends_the_header(self):
        self.assertEqual({"a": "1"}, bt.header_fields("#+a:1\nsign x\n#+b:2\n"))

    def test_other_line_breaks_end_a_line(self):
        text = "#+a:1" + "\r\n" + "#+b:2" + "\r" + "#+c:3" + "\u2028" + "#+d:4" + "\x85" + "#+e:5"
        self.assertEqual({"a": "1", "b": "2", "c": "3", "d": "4", "e": "5"}, bt.header_fields(text))

    def test_the_catalogs_fields_are_kept_only_for_a_file_with_a_type(self):
        self.assertEqual({}, bt.catalog_fields(b"#+language:en\n#+display-name:x\n"))
        self.assertEqual({"type": "literary", "language": "en"}, bt.catalog_fields(b"#+type:literary\n#+language:en\n#+unknown:1\n"))

    def test_a_table_that_only_includes_others(self):
        self.assertEqual(["en-ueb-g1.ctb"], bt.include_only_targets(b"# comment\n\ninclude en-ueb-g1.ctb\n"))
        self.assertEqual(["a.ctb", "b.ctb"], bt.include_only_targets(b"INCLUDE a.ctb\n\tinclude\tb.ctb  # more\n"))
        self.assertIsNone(bt.include_only_targets(b"include a.ctb\nsign x 1\n"))
        self.assertIsNone(bt.include_only_targets(b"# nothing\n"))
        self.assertIsNone(bt.include_only_targets(b"include\n"))
        self.assertIsNone(bt.include_only_targets(b"include a.ctb\n" + b"#" * bt.MAXIMUM_INCLUDE_ONLY_BYTES))

    def test_the_includes_of_a_file_are_the_second_word_of_each_include_line(self):
        data = b"# include nothing.ctb\ninclude a.ctb\n  include b.ctb extra\nsign include 1\nnoback correct x include\ninclude a.ctb\n"
        self.assertEqual(["a.ctb", "b.ctb"], bt.include_targets(data))


class LicenseTests(unittest.TestCase):
    """The license of a file is read from its own head."""

    def test_the_classes(self):
        self.assertEqual((bt.LGPL_21, ["2.1"]), bt.classify_license(table(b"2.1")))
        self.assertEqual((bt.LGPL_3, ["3"]), bt.classify_license(table(b"3")))
        self.assertEqual(bt.NO_LICENSE, bt.classify_license(b"# liblouis: Arabic\n#+language:ar\ninclude ar-ar-g1.utb\n")[0])
        self.assertEqual(bt.AMBIGUOUS, bt.classify_license(
            table(b"2.1", b"# This is free software, placed under the terms of the\n# GNU General Public License, as published by the Free Software\n"))[0])
        self.assertEqual(bt.OTHER, bt.classify_license(b"# Copyright (C) 2020 Someone. All rights reserved.\n")[0])
        self.assertEqual(bt.OTHER, bt.classify_license(b"# Released under the BSD license.\n")[0])
        self.assertEqual(bt.OTHER, bt.classify_license(LGPL % b"2")[0])

    def test_a_reference_to_another_license_does_not_change_the_files_own(self):
        data = table(b"2.1", b"# REFERENCES: the chart, available under a Creative Commons Attribution-Sharealike 3.0 Unported License.\n")
        self.assertEqual(bt.LGPL_21, bt.classify_license(data)[0])


class PlanTests(unittest.TestCase):
    """What ships, from folders made here."""

    def test_the_build_systems_files_never_ship(self):
        with folder_of({"a.ctb": table(), "Makefile.am": b"x", "Makefile.in": b"x", "README": b"x", "a.ctb.in": b"x"}) as folder:
            self.assertEqual(["a.ctb"], sorted(bt.plan(folder, "iphone").files))

    def test_a_table_that_includes_a_missing_file_fails_the_build(self):
        with folder_of({"a.ctb": table(body=b"include gone.uti\n")}) as folder:
            with self.assertRaisesRegex(bt.BuildError, "a.ctb includes gone.uti"):
                bt.plan(folder, "iphone")

    def test_a_license_that_is_not_lgpl_2_1_or_later_leaves_the_file_and_its_includers_out(self):
        files = {"bad.uti": table(b"3"), "mid.ctb": table(body=b"include bad.uti\n"), "top.ctb": table(body=b"include mid.ctb\n"),
                 "fine.ctb": table(), "wrap.tbl": b"include fine.ctb\n"}
        with folder_of(files) as folder:
            plan = bt.plan(folder, "iphone")
        self.assertEqual(["fine.ctb", "wrap.tbl"], sorted(plan.files))
        self.assertEqual({"bad.uti", "mid.ctb", "top.ctb"}, set(plan.excluded))
        self.assertIn("includes bad.uti", plan.excluded["mid.ctb"])
        self.assertIn("includes mid.ctb", plan.excluded["top.ctb"])

    def test_a_file_the_user_accepted_ships_with_what_includes_it(self):
        files = {"countries.cti": table(body=b"# GNU General Public License, version nothing\n"), "uses.ctb": table(body=b"include countries.cti\n")}
        with folder_of(files) as folder:
            self.assertEqual(bt.AMBIGUOUS, bt.plan(folder, "iphone").licenses["countries.cti"])
            plan = bt.plan(folder, "iphone")
        self.assertEqual(["countries.cti", "uses.ctb"], sorted(plan.files))
        self.assertEqual({}, plan.excluded)

    def test_a_file_only_left_out_tables_include_is_left_out_too_until_nothing_changes(self):
        files = {
            "bad.ctb": table(b"3", b"include helper.uti\n"),
            "helper.uti": b"include deeper.uti\nletter a 1\n",
            "deeper.uti": b"letter b 12\n",
            "shared.uti": b"letter c 14\n",
            "good.ctb": table(body=b"include shared.uti\n"),
            "alsobad.ctb": table(b"3", b"include shared.uti\n"),
            "loose.dis": b"display a 1\n",
        }
        with folder_of(files) as folder:
            plan = bt.plan(folder, "iphone")
        self.assertEqual(["good.ctb", "loose.dis", "shared.uti"], sorted(plan.files))
        self.assertIn("only bad.ctb", plan.excluded["helper.uti"])
        # deeper.uti is included by helper.uti alone, which goes in the same pass of the rule.
        self.assertIn("only helper.uti", plan.excluded["deeper.uti"])
        self.assertNotIn("shared.uti", plan.excluded, "a good table includes it too")
        self.assertNotIn("loose.dis", plan.excluded, "no table includes it, so no left-out table is its only user")

    def test_a_literary_table_and_a_file_of_the_macs_list_are_never_left_out_for_their_users(self):
        files = {
            "bad.ctb": table(b"3", b"include wrapped.ctb\ninclude listed.uti\n"),
            "wrapped.ctb": table(body=b"letter a 1\n"),
            "listed.uti": b"letter b 12\n",
        }
        with folder_of(files) as folder, tempfile.TemporaryDirectory() as lists:
            listing = Path(lists, "list.txt")
            listing.write_text("listed.uti\n", encoding="utf-8")
            plan = bt.plan(folder, "iphone", listing)
        self.assertEqual(["listed.uti", "wrapped.ctb"], sorted(plan.files))

    def test_the_mac_profile_applies_the_license_rule_and_fails_for_a_listed_file_it_leaves_out(self):
        files = {"a.ctb": table(), "b.ctb": table(b"3")}
        with folder_of(files) as folder, tempfile.TemporaryDirectory() as lists:
            listing = Path(lists, "list.txt")
            listing.write_text("a.ctb\n", encoding="utf-8")
            self.assertEqual(["a.ctb"], sorted(bt.plan(folder, "mac", listing).files))
            listing.write_text("a.ctb\nb.ctb\n", encoding="utf-8")
            with self.assertRaisesRegex(bt.BuildError, "b.ctb, which the license rule leaves out"):
                bt.plan(folder, "mac", listing)

    def test_a_dictionary_ships_only_when_a_shipped_table_includes_it(self):
        files = {"used.dic": b"patterns\n", "unused.dic": b"patterns\n", "t.ctb": table(body=b"include used.dic\n")}
        with folder_of(files) as folder:
            plan = bt.plan(folder, "iphone")
        self.assertEqual(["t.ctb", "used.dic"], sorted(plan.files))
        self.assertIn("unused.dic", plan.excluded)

    def test_a_name_that_is_not_plain_is_refused(self):
        for name in (".hidden.ctb", "sp ace.ctb", "café.ctb"):
            with self.subTest(name), folder_of({name: table()}) as folder, self.assertRaises(bt.BuildError):
                bt.plan(folder, "iphone")

    def test_the_mac_profile_ships_exactly_its_list_and_checks_its_includes(self):
        files = {"a.ctb": table(body=b"include b.uti\n"), "b.uti": table(), "c.ctb": table()}
        with folder_of(files) as folder, tempfile.TemporaryDirectory() as lists:
            listing = Path(lists, "list.txt")
            listing.write_text("# a list\na.ctb\nb.uti\n", encoding="utf-8")
            self.assertEqual(["a.ctb", "b.uti"], sorted(bt.plan(folder, "mac", listing).files))
            listing.write_text("a.ctb\n", encoding="utf-8")
            with self.assertRaisesRegex(bt.BuildError, "which the list lacks"):
                bt.plan(folder, "mac", listing)
            listing.write_text("a.ctb\nb.uti\nmissing.ctb\n", encoding="utf-8")
            with self.assertRaisesRegex(bt.BuildError, "missing.ctb"):
                bt.plan(folder, "mac", listing)
            listing.write_text("a.ctb\na.ctb\n", encoding="utf-8")
            with self.assertRaisesRegex(bt.BuildError, "listed twice"):
                bt.plan(folder, "mac", listing)

    def test_the_closure_of_a_table(self):
        includes = {"a": ["b", "c"], "b": ["c"], "c": [], "d": ["a"]}
        self.assertEqual(["a", "b", "c"], bt.closure(includes, "a"))
        self.assertEqual(["d", "a", "b", "c"], bt.closure(includes, "d"))
        self.assertEqual(["c"], bt.closure(includes, "c"))
        with self.assertRaises(bt.BuildError):
            bt.closure({"a": ["gone"]}, "a")
        with self.assertRaises(bt.BuildError):
            bt.closure(includes, "nothere")
        # A loop is walked once.
        self.assertEqual(["x", "y"], bt.closure({"x": ["y"], "y": ["x"]}, "x"))


class OldTablesTests(unittest.TestCase):
    """The raw tables folder an earlier build of the app copied is removed, and nothing else."""

    def test_only_liblouis_tables_goes_and_liblouis_when_it_is_left_empty(self):
        with tempfile.TemporaryDirectory() as resources:
            root = Path(resources)
            (root / "liblouis" / "tables").mkdir(parents=True)
            (root / "liblouis" / "tables" / "en-ueb-g2.ctb").write_bytes(b"x")
            (root / "Strings.pack").write_bytes(b"keep")
            self.assertTrue(bt.remove_old_tables(root))
            self.assertFalse((root / "liblouis").exists())
            self.assertEqual(b"keep", (root / "Strings.pack").read_bytes())
            self.assertFalse(bt.remove_old_tables(root), "nothing is left to remove")

    def test_a_liblouis_folder_with_other_things_stays(self):
        with tempfile.TemporaryDirectory() as resources:
            root = Path(resources)
            (root / "liblouis" / "tables").mkdir(parents=True)
            (root / "liblouis" / "other").mkdir()
            self.assertTrue(bt.remove_old_tables(root))
            self.assertTrue((root / "liblouis" / "other").is_dir())
            self.assertFalse((root / "liblouis" / "tables").exists())

    def test_build_removes_them_when_asked_and_only_then(self):
        with folder_of({"a.ctb": table()}) as folder, tempfile.TemporaryDirectory() as resources, tempfile.TemporaryDirectory() as lists:
            root = Path(resources)
            (root / "liblouis" / "tables").mkdir(parents=True)
            listing = Path(lists, "list.txt")
            listing.write_text("a.ctb\n", encoding="utf-8")
            with mock.patch.object(bt, "MAC_LIST", listing), mock.patch.object(bt, "CONFIG_H", Path(folder, "config.h")):
                Path(folder, "config.h").write_text('#define PACKAGE_VERSION "9.9.9"\n', encoding="utf-8")
                out = root / "BrailleTables.pack"
                args = bt.parser().parse_args(["build", "--profile", "mac", "--tables", folder, "--out", str(out), "--stamp", str(root / "stamp.json")])
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, bt.command_build(args))
                self.assertTrue((root / "liblouis" / "tables").is_dir(), "removed without being asked")
                args = bt.parser().parse_args(["build", "--profile", "mac", "--tables", folder, "--out", str(out), "--stamp", str(root / "stamp.json"), "--remove-old-tables"])
                with contextlib.redirect_stdout(io.StringIO()):
                    self.assertEqual(0, bt.command_build(args))
                self.assertFalse((root / "liblouis").exists())
                self.assertTrue(out.is_file())


class GroupTests(unittest.TestCase):
    """The groups of a pack."""

    def test_a_group_is_the_prefix_of_a_name(self):
        for name, key in (("en-ueb-g2.ctb", "en"), ("en_US.tbl", "en"), ("Es-Es-G0.utb", "es"), ("braille-patterns.cti", "braille"),
                          ("hyph_en_US.dic", "hyph"), ("spaces.uti", "spaces"), ("zh.ctb", "zh")):
            self.assertEqual(key, bt.group_key(name), name)

    def test_small_groups_are_joined_after_the_rest(self):
        names = ["a-1", "a-2", "a-3", "b-1", "c-1", "c-2"]
        self.assertEqual([("a", ["a-1", "a-2", "a-3"]), ("~", ["b-1", "c-1", "c-2"])], bt.make_groups(names, 3))
        self.assertEqual([("a", ["a-1", "a-2", "a-3"]), ("b", ["b-1"]), ("c", ["c-1", "c-2"])], bt.make_groups(names, 0))

    def test_a_small_pack_reads_back_with_every_file_in_one_group(self):
        files = {"a-1.ctb": table(body=b"include a-2.uti\n"), "a-2.uti": table(), "b-1.ctb": table(body=b"include a-2.uti\n"), "c-1.ctb": table()}
        with folder_of(files) as folder:
            plan = bt.plan(folder, "iphone")
        data = bt.build_bytes(plan, "9.9.9")
        read = bt.read_pack(data)
        self.assertEqual(plan.files, read["files"])
        self.assertEqual("9.9.9", read["index"]["liblouis"])
        names = [name for entry in read["index"]["files"] for name in [entry["n"]]]
        self.assertEqual(sorted(files), names)
        self.assertEqual(bt.source_digest(plan.files), read["digest"])


class RealTablesTests(unittest.TestCase):
    """The vendored release's own packs."""

    @classmethod
    def setUpClass(cls):
        cls.tables = bt.DEFAULT_TABLES
        cls.version = bt.liblouis_version()
        cls.phone_plan = bt.plan(cls.tables, "iphone")
        cls.mac_plan = bt.plan(cls.tables, "mac")
        cls.phone_bytes = bt.build_bytes(cls.phone_plan, cls.version)
        cls.mac_bytes = bt.build_bytes(cls.mac_plan, cls.version)
        cls.phone = bt.read_pack(cls.phone_bytes)
        cls.mac = bt.read_pack(cls.mac_bytes)

    def test_every_shipped_file_is_in_exactly_one_group_and_back_as_it_was(self):
        for label, plan, pack in (("iphone", self.phone_plan, self.phone), ("mac", self.mac_plan, self.mac)):
            entries = pack["index"]["files"]
            self.assertEqual(sorted(plan.files), [entry["n"] for entry in entries], label)
            self.assertEqual(len(entries), len({entry["n"] for entry in entries}), label)
            groups = {record.name: record for record in pack["records"] if record.name != bt.INDEX_BLOB}
            counts = {}
            for entry in entries:
                counts[entry["g"]] = counts.get(entry["g"], 0) + 1
            self.assertEqual({int(name[1:]): record.count for name, record in groups.items()}, counts, label)
            for name, data in plan.files.items():
                self.assertEqual(data, pack["files"][name], f"{label}: {name}")
            # The ranges of a group's files do not overlap and fill it.
            for number in counts:
                spans = sorted((entry["o"], entry["o"] + entry["l"]) for entry in entries if entry["g"] == number)
                self.assertEqual(0, spans[0][0], label)
                self.assertTrue(all(first[1] == second[0] for first, second in zip(spans, spans[1:])), label)
                self.assertEqual(groups[bt.GROUP_NAME % number].raw, spans[-1][1], label)

    def test_every_blob_but_the_index_is_lzma_and_the_index_too(self):
        for pack in (self.phone, self.mac):
            self.assertEqual({packfile.METHOD_LZMA}, {record.method for record in pack["records"]})

    def test_the_index_closure_of_every_file_is_what_its_include_lines_reach(self):
        # An independent reading of the include lines, by a regular expression over the bytes.
        pattern = re.compile(rb"^[ \t]*include[ \t]+(\S+)", re.M)
        for label, plan, pack in (("iphone", self.phone_plan, self.phone), ("mac", self.mac_plan, self.mac)):
            direct = {entry["n"]: entry.get("i", []) for entry in pack["index"]["files"]}
            for name, data in plan.files.items():
                reached = {match.group(1).decode() for match in pattern.finditer(data)}
                self.assertEqual(reached, set(direct[name]), f"{label}: {name}")
                expected, pending = set(), [name]
                while pending:
                    current = pending.pop()
                    if current not in expected:
                        expected.add(current)
                        pending += [m.group(1).decode() for m in pattern.finditer(plan.files[current])]
                self.assertEqual(expected, set(bt.closure(direct, name)), f"{label}: {name}")

    def test_every_include_of_a_shipped_file_ships(self):
        shipped = set(self.phone_plan.files)
        for name, targets in self.phone_plan.includes.items():
            for target in targets:
                self.assertIn(target, shipped, f"{name} includes {target}")

    def test_the_macs_pack_is_the_twenty_files_it_bundled_before(self):
        listed = bt.read_list(bt.MAC_LIST)
        self.assertEqual(20, len(listed))
        self.assertEqual(sorted(listed), sorted(self.mac_plan.files))
        for name in ("en-ueb-g1.ctb", "en-ueb-g2.ctb", "en-us-g1.ctb", "en_US.tbl", "en-us-brf.dis", "de-eurobrl6.dis", "de-eurobrl6u.dis"):
            self.assertIn(name, self.mac_plan.files)

    def test_the_iphones_pack_has_the_macs_files_and_more_than_a_hundred_tables(self):
        self.assertTrue(set(self.mac_plan.files) <= set(self.phone_plan.files))
        tables = [entry for entry in self.phone["index"]["files"] if entry.get("m", {}).get("type") == "literary"]
        self.assertGreater(len(tables), 100)

    def test_every_shipped_file_has_a_license_that_ships(self):
        for name in self.phone_plan.files:
            if name not in bt.ACCEPTED_BY_DECISION:
                self.assertIn(self.phone_plan.licenses[name], bt.SHIPPED_LICENSES, name)

    def test_the_license_list_is_what_the_files_say(self):
        self.assertEqual(bt.LICENSES_FILE.read_text(encoding="utf-8"), bt.license_list(self.phone_plan, self.version))

    def test_the_index_names_the_tables_that_write_braille_only(self):
        for pack in (self.phone, self.mac):
            forward = pack["index"]["f"]
            self.assertEqual(sorted(forward), forward)
            for name in ("de-g1.ctb", "cs.tbl", "lv.tbl", "sl.tbl", "zh_CHN.tbl", "zh-tw.ctb", "th-g2.ctb", "ko-g2.ctb"):
                self.assertIn(name, forward, name)
            # A two-way table is in no list: nothing reads one.
            for name in ("en-ueb-g2.ctb", "fr-bfu-g2.ctb", "en_US.tbl", "zh-hk.ctb", "ar.tbl"):
                self.assertNotIn(name, forward, name)
            self.assertNotIn("w", pack["index"])
        # The Mac's pack names the whole release's directions, though it carries 20 of its files.
        self.assertEqual(self.phone["index"]["f"], self.mac["index"]["f"])

    def test_directions_of_a_small_release(self):
        files = {"a.ctb": table(body=b"#+direction:forward\n"), "b.ctb": table(), "c.cti": b"letter a 1\n", "d.ctb": b"#+type:computer\n#+direction:forward\n"}
        files["a.ctb"] = b"#+type:literary\n#+direction:forward\n#-display-name: A\n" + LGPL % b"2.1"
        with folder_of(files) as folder:
            self.assertEqual(["a.ctb"], bt.plan(folder, "iphone").directions)

    def test_every_file_is_recorded_with_its_sha_256(self):
        for pack in (self.phone, self.mac):
            for entry in pack["index"]["files"]:
                self.assertEqual(hashlib.sha256(pack["files"][entry["n"]]).hexdigest(), entry["h"], entry["n"])

    def test_the_stamp_names_the_config_the_list_and_the_builder(self):
        stamp = bt.stamp_of("mac", self.tables)
        for key in ("config", "list", "builder", "container", "tables"):
            self.assertIsNotNone(stamp[key], key)
        self.assertEqual(bt.file_hash(bt.CONFIG_H), stamp["config"])

    def test_countries_ships_by_the_users_decision_with_the_tables_that_include_it(self):
        for name in ("countries.cti", "de-g1.ctb", "de-g2.ctb", "cy-cy-g1.utb", "sl-si-g1.utb", "ar-ar-comp8.utb", "ckb-g1.ctb"):
            self.assertIn(name, self.phone_plan.files, name)
        self.assertEqual(bt.AMBIGUOUS, self.phone_plan.licenses["countries.cti"])
        self.assertIn("November 23, 2026", bt.license_list(self.phone_plan, self.version))

    def test_what_the_lgpl_3_files_leave_out_stays_out(self):
        for name in ("Es-Es-G0.utb", "et-g0.utb", "pt-pt-g2.ctb", "sr-g1.ctb", "is-chardefs6.cti", "grc-international-es.utb"):
            self.assertIn(name, self.phone_plan.excluded, name)

    def test_the_same_files_give_the_same_pack(self):
        self.assertEqual(self.mac_bytes, bt.build_bytes(bt.plan(self.tables, "mac"), self.version))

    def test_the_header_and_the_catalog_fields(self):
        directory = packfile.read_directory(self.phone_bytes, bt.MAGIC, bt.FORMAT_VERSION)
        self.assertEqual(len(self.phone_plan.files), directory.count)
        self.assertEqual(struct.pack("<4s", b"TMBT"), self.phone_bytes[:4])
        english = {entry["n"]: entry for entry in self.phone["index"]["files"]}["en-ueb-g2.ctb"]
        self.assertEqual("Unified English contracted braille", english["m"]["display-name"])
        self.assertEqual("full", english["m"]["contraction"])
        self.assertEqual("ueb", english["m"]["system"])

    def test_a_pack_that_is_a_strings_pack_is_refused(self):
        with self.assertRaises(packfile.PackError):
            bt.read_pack(b"TMSP" + self.phone_bytes[4:])

    def test_the_index_is_json_of_the_shape_the_reader_expects(self):
        index = self.phone["index"]
        self.assertEqual({"v", "liblouis", "files", "f"}, set(index))
        self.assertEqual(bt.INDEX_VERSION, index["v"])
        for entry in index["files"]:
            self.assertTrue({"n", "g", "o", "l"} <= set(entry), entry)
            self.assertTrue(set(entry) <= {"n", "g", "o", "l", "h", "i", "m", "t"}, entry)
            self.assertRegex(entry["h"], "^[0-9a-f]{64}$")
        json.dumps(index)


if __name__ == "__main__":
    unittest.main()
