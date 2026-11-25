"""Tests of `pack.py`, the builder of the interface-text pack (FR39, phase 2).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests
(and with /usr/bin/python3, the interpreter the Xcode build phase uses; one test below does so itself).

The fixtures in `fixtures/pack/` are for the Swift tests of the engine as well as these: each catalog (keyed by IDs, as
the catalog will be after the migration) has the pack `pack.py` builds from it, and a `.entries.json` that says in plain
JSON what every language holds for every ID. To rewrite them after a change to the builder or a catalog:

    python3 -I -B Scripts/l10n/tests/test_pack.py --regenerate

Tests compare decoded entries, never compressed bytes: the build phase's Python and a newer one may link different
versions of liblzma, which may encode the same input differently.
"""
import bz2
import contextlib
import hashlib
import io
import json
import lzma
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
L10N = HERE.parent
sys.path.insert(0, str(L10N))
sys.path.insert(0, str(L10N.parent / "packs"))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import pack  # noqa: E402
import packfile  # noqa: E402  (the container the pack is written in)

FIXTURES = HERE / "fixtures" / "pack"
REAL_CATALOG = L10N.parent.parent / "TextMouth" / "Localization" / "Localizable.xcstrings"
# The fixture catalogs, and the corrupt pack made from the first.
FIXTURE_NAMES = ("lines", "plurals")
CORRUPT_FIXTURE = FIXTURES / "lines-corrupt-utf8.pack"
# The pack of the first catalog with both compression methods in it (ids, en, and es LZMA; the rest bzip2).
MIXED_FIXTURE = FIXTURES / "lines-mixed-methods.pack"


# ---------------------------------------------------------------------------------------------------------------
# The fixtures' plain-JSON description, and how they are written.
# ---------------------------------------------------------------------------------------------------------------

def entry_json(entry):
    """One entry as plain JSON: null (no translation), {"text": ...}, or {"forms": [...]} in category order."""
    if entry is None:
        return None
    return {"forms": list(entry)} if isinstance(entry, tuple) else {"text": entry}


def description_of(data):
    """The `.entries.json` content of the pack `data`: its catalog hash, its IDs, each ID's note, each language's plural
    categories, and each language's entry for each ID."""
    decoded = pack.read_pack(data)
    languages = [name for name in decoded.blobs if name not in (pack.IDS_BLOB, pack.NOTES_BLOB)]
    return {
        "catalogSHA256": decoded.digest,
        "ids": decoded.ids,
        "notes": dict(zip(decoded.ids, decoded.blobs[pack.NOTES_BLOB].entries)),
        "pluralCategories": {language: list(catalog.plural_categories(language)) for language in languages},
        "languages": {language: {identifier: entry_json(pack.decode_entry(text))
                                 for identifier, text in zip(decoded.ids, decoded.blobs[language].entries)}
                      for language in languages},
    }


def description_text(data):
    """The text of the `.entries.json` file for the pack `data`: sorted keys, two-space indents, a final newline."""
    return json.dumps(description_of(data), ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def regenerate():
    """Rewrites every fixture pack, its `.entries.json`, and the corrupt pack from the committed catalogs."""
    for name in FIXTURE_NAMES:
        plan = pack.build_plan(FIXTURES / f"{name}.xcstrings")
        data = pack.build_bytes(plan)
        (FIXTURES / f"{name}.pack").write_bytes(data)
        (FIXTURES / f"{name}.entries.json").write_text(description_text(data), encoding="utf-8")
        if name == "lines":
            CORRUPT_FIXTURE.write_bytes(pack.build_corrupt_utf8_pack_for_tests(plan))
            MIXED_FIXTURE.write_bytes(pack.build_mixed_method_pack_for_tests(plan))
        print("wrote", name)


# ---------------------------------------------------------------------------------------------------------------
# Helpers that build small catalogs in a temporary folder.
# ---------------------------------------------------------------------------------------------------------------

def decompress_blob(data, method):
    """The raw bytes of a blob `data` that `method` (a pack.METHOD_ code) compressed, by the standard library alone, so the
    tests do not lean on pack.py's own reader."""
    if method == pack.METHOD_LZMA:
        return lzma.decompress(data, format=lzma.FORMAT_XZ)
    if method == pack.METHOD_BZIP2:
        return bz2.decompress(data)
    raise AssertionError(f"unknown method {method}")


def plain(text, state="translated"):
    """A plain localization."""
    return {"stringUnit": {"state": state, "value": text}}


def plural(forms, state="translated"):
    """A plural localization from {category: text}."""
    return {"variations": {"plural": {category: plain(text, state) for category, text in forms.items()}}}


class PackCase(unittest.TestCase):
    """A test case with a temporary folder and helpers to write a catalog and build from it."""

    def setUp(self):
        """Makes the temporary folder every test of the case writes into."""
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.folder = Path(self.directory.name)

    def write_catalog(self, strings, name="catalog.xcstrings"):
        """Writes `strings` ({key: entry}) as a catalog and returns its path."""
        path = self.folder / name
        catalog.Catalog({"sourceLanguage": "en", "strings": strings, "version": "1.0"}).save(path)
        return path

    def refusals(self, strings, **options):
        """The problems build_plan refuses a catalog of `strings` with (the test fails if it does not refuse)."""
        with self.assertRaises(pack.PackError) as caught:
            pack.build_plan(self.write_catalog(strings), **options)
        return caught.exception.problems

    def run_main(self, *arguments):
        """Runs `pack.main` with `arguments`, returning (exit code, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pack.main([str(argument) for argument in arguments])
        return code, out.getvalue(), err.getvalue()


def line(en, **translations):
    """A catalog entry of plain lines: English `en` and the translations given by language (`pt_BR` for `pt-BR`)."""
    localizations = {"en": plain(en)}
    localizations.update({code.replace("_", "-"): plain(text) for code, text in translations.items()})
    return {"localizations": localizations}


# ---------------------------------------------------------------------------------------------------------------
# The committed fixtures.
# ---------------------------------------------------------------------------------------------------------------

class FixtureTests(PackCase):
    """Each committed fixture pack and description is what the builder makes from the committed catalog."""

    def test_each_pack_decodes_to_what_the_builder_makes(self):
        # Entries, not bytes: a newer liblzma may encode the same input differently.
        for name in FIXTURE_NAMES:
            with self.subTest(name):
                built = pack.read_pack(pack.build_bytes(pack.build_plan(FIXTURES / f"{name}.xcstrings")))
                committed = pack.read_pack((FIXTURES / f"{name}.pack").read_bytes())
                self.assertEqual(committed.digest, built.digest)
                self.assertEqual(committed.ids, built.ids)
                self.assertEqual(list(committed.blobs), list(built.blobs))
                for blob_name, blob in committed.blobs.items():
                    self.assertEqual(blob.entries, built.blobs[blob_name].entries, blob_name)
                self.assertEqual([], pack.verify(FIXTURES / f"{name}.pack", FIXTURES / f"{name}.xcstrings"))

    def test_each_description_is_the_packs(self):
        for name in FIXTURE_NAMES:
            with self.subTest(name):
                data = (FIXTURES / f"{name}.pack").read_bytes()
                self.assertEqual(description_text(data), (FIXTURES / f"{name}.entries.json").read_text(encoding="utf-8"))

    def test_each_pack_carries_the_hash_of_its_catalog(self):
        for name in FIXTURE_NAMES:
            with self.subTest(name):
                digest = hashlib.sha256((FIXTURES / f"{name}.xcstrings").read_bytes()).hexdigest()
                self.assertEqual(digest, pack.read_pack((FIXTURES / f"{name}.pack").read_bytes()).digest)

    def test_the_lines_fixture_covers_what_the_engine_needs(self):
        described = json.loads((FIXTURES / "lines.entries.json").read_text(encoding="utf-8"))
        languages = described["languages"]
        self.assertEqual({"en", "es", "ru", "ar", "ja"}, set(languages))
        self.assertEqual({"text": "Hola"}, languages["es"]["fixture.plain"])
        # A state-new Spanish line is not compiled: the language falls back to English (an entry of none).
        self.assertIsNone(languages["es"]["fixture.pending"])
        self.assertEqual({"text": "Текст в ожидании"}, languages["ru"]["fixture.pending"])
        # needs_review and machine_translated ship, as Xcode compiles them.
        self.assertEqual({"text": "保留中のテキスト"}, languages["ja"]["fixture.pending"])
        # An ID with no translation in a language.
        self.assertIsNone(languages["ar"]["fixture.partial"])
        self.assertIsNone(languages["ru"]["fixture.englishOnly"])
        self.assertEqual({"text": "Only English"}, languages["en"]["fixture.englishOnly"])
        # Specifiers: positions, a reordering, a literal percent sign, and a line feed and a tab.
        self.assertEqual({"text": "%2$lld páginas leídas por %1$@"}, languages["es"]["fixture.reorder"])
        self.assertEqual({"text": "%lld %% hecho"}, languages["es"]["fixture.percent"])
        self.assertEqual({"text": "First line\nSecond line\tTabbed"}, languages["en"]["fixture.breaks"])
        # Notes, and an ID with none.
        self.assertEqual("A greeting. Plain text in every language.", described["notes"]["fixture.plain"])
        self.assertEqual("", described["notes"]["fixture.noNote"])

    def test_the_plurals_fixture_covers_every_category_shape(self):
        described = json.loads((FIXTURES / "plurals.entries.json").read_text(encoding="utf-8"))
        languages = described["languages"]
        self.assertEqual({"en", "ar", "es", "ja", "pl", "ru"}, set(languages))
        self.assertEqual(["zero", "one", "two", "few", "many", "other"], described["pluralCategories"]["ar"])
        self.assertEqual({"forms": ["%lld book", "%lld books"]}, languages["en"]["fixture.books"])
        self.assertEqual(6, len(languages["ar"]["fixture.books"]["forms"]))
        self.assertEqual(["%lld libro", "%lld de libros", "%lld libros"], languages["es"]["fixture.books"]["forms"])
        self.assertEqual(4, len(languages["pl"]["fixture.books"]["forms"]))
        self.assertEqual(4, len(languages["ru"]["fixture.books"]["forms"]))
        # Japanese has `other` alone, so its forms are all one text and are written as that text.
        self.assertEqual({"text": "%lld冊"}, languages["ja"]["fixture.books"])
        # Spanish forms that are all the same are written as one text.
        self.assertEqual({"text": "%lld elementos"}, languages["es"]["fixture.items"])
        # A `one` form that says the number in words.
        self.assertEqual("Una página", languages["es"]["fixture.pages"]["forms"][0])
        # A plural with all its forms in state new is not compiled; a plain line for a plural English is plain.
        self.assertIsNone(languages["ru"]["fixture.pendingBooks"])
        self.assertEqual({"text": "Półki: %lld"}, languages["pl"]["fixture.pendingBooks"])

    def test_the_mixed_method_pack_holds_both_methods_and_the_same_entries(self):
        mixed = MIXED_FIXTURE.read_bytes()
        decoded = pack.read_pack(mixed)
        methods = {name: blob.method for name, blob in decoded.blobs.items()}
        self.assertEqual({"ids", "en", "es"}, {name for name, method in methods.items() if method == pack.METHOD_LZMA})
        self.assertEqual({"notes", "ar", "ja", "ru"}, {name for name, method in methods.items() if method == pack.METHOD_BZIP2})
        # The same entries as the builder's own pack, compressed differently.
        self.assertEqual(self.raw_blobs_of((FIXTURES / "lines.pack").read_bytes()), self.raw_blobs_of(mixed))
        self.assertEqual(pack.build_mixed_method_pack_for_tests(pack.build_plan(FIXTURES / "lines.xcstrings")), mixed)

    def test_the_corrupt_pack_is_well_formed_except_for_its_english(self):
        data = CORRUPT_FIXTURE.read_bytes()
        with self.assertRaises(pack.PackError) as caught:
            pack.read_pack(data)
        self.assertIn("not UTF-8", str(caught.exception))
        # Rebuilt, it holds the same raw blobs: compare what they decode to, not their compressed bytes.
        rebuilt = pack.build_corrupt_utf8_pack_for_tests(pack.build_plan(FIXTURES / "lines.xcstrings"))
        self.assertEqual(self.raw_blobs_of(rebuilt), self.raw_blobs_of(data))
        # Only the first English entry is broken; the other blobs are the good pack's.
        good = self.raw_blobs_of((FIXTURES / "lines.pack").read_bytes())
        bad = self.raw_blobs_of(data)
        self.assertEqual({name: raw for name, raw in good.items() if name != "en"},
                         {name: raw for name, raw in bad.items() if name != "en"})
        self.assertEqual(b"\xc3\x28\0", bad["en"][:3])
        self.assertEqual(good["en"].split(b"\0")[1:], bad["en"].split(b"\0")[1:])

    @staticmethod
    def raw_blobs_of(data):
        """{blob name: raw bytes} of the pack `data`, without checking its UTF-8 (so a corrupt pack can be read)."""
        _, _, _, _, _, count = pack.HEADER.unpack_from(data)
        found = {}
        for index in range(count):
            name, offset, size, raw_size, _, method = pack.DIRECTORY_RECORD.unpack_from(
                data, pack.HEADER.size + index * pack.DIRECTORY_RECORD.size)
            found[name.rstrip(b"\0").decode("ascii")] = decompress_blob(data[offset:offset + size], method)
            assert len(found[name.rstrip(b"\0").decode("ascii")]) == raw_size
        return found


# ---------------------------------------------------------------------------------------------------------------
# The format.
# ---------------------------------------------------------------------------------------------------------------

class FormatTests(PackCase):
    """The header, the directory, the blobs, and the entries, exactly as the design gives them."""

    def build(self, strings):
        """The pack bytes for `strings` (keyed by IDs)."""
        return pack.build_bytes(pack.build_plan(self.write_catalog(strings)))

    def test_the_header_and_directory_are_laid_out_as_designed(self):
        path = FIXTURES / "lines.xcstrings"
        data = pack.build_bytes(pack.build_plan(path))
        magic, version, flags, digest, id_count, blob_count = struct.unpack_from("<4sHH32sII", data)
        self.assertEqual((b"TMSP", 2, 0), (magic, version, flags))
        self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), digest)
        self.assertEqual(13, id_count)
        self.assertEqual(2 + 5, blob_count)
        self.assertEqual(48, pack.HEADER.size)
        self.assertEqual(32, pack.DIRECTORY_RECORD.size)
        offset = 48 + 32 * blob_count
        names = []
        for index in range(blob_count):
            raw_name, blob_offset, size, raw_size, count, method = struct.unpack_from("<12sIIIII", data, 48 + 32 * index)
            self.assertIn(method, pack.METHOD_NAMES)
            names.append(raw_name.rstrip(b"\0").decode("ascii"))
            self.assertEqual(12, len(raw_name))
            self.assertEqual(offset, blob_offset, "blobs follow the directory with no gap, in order")
            self.assertEqual(13, count)
            raw = decompress_blob(data[blob_offset:blob_offset + size], method)
            self.assertEqual(raw_size, len(raw))
            self.assertEqual(13, raw.count(b"\0"), "every entry ends with a NUL")
            self.assertTrue(raw.endswith(b"\0"), "the last entry too")
            offset += size
        self.assertEqual(["ids", "notes", "en", "ar", "es", "ja", "ru"], names)
        self.assertEqual(len(data), offset)

    def test_languages_follow_english_in_code_order(self):
        data = self.build({"a.one": line("One", ru="Один", de="Eins", pt_BR="Um")})
        self.assertEqual(["ids", "notes", "en", "de", "pt-BR", "ru"], list(pack.read_pack(data).blobs))

    def test_ids_sort_by_code_point_and_every_blob_follows_them(self):
        # A capital (U+0042) sorts before a small letter (U+0062), and a shorter ID before its extension.
        strings = {name: line(name.upper(), es=name + "!") for name in ("a.b", "a.ab", "a.aB", "a.b2", "a.a1")}
        decoded = pack.read_pack(self.build(strings))
        self.assertEqual(["a.a1", "a.aB", "a.ab", "a.b", "a.b2"], decoded.ids)
        self.assertEqual([name + "!" for name in decoded.ids], decoded.blobs["es"].entries)
        self.assertEqual([name.upper() for name in decoded.ids], decoded.blobs["en"].entries)

    def test_plain_plural_and_empty_entries(self):
        strings = {
            "x.plain": line("Plain", es="Llano"),
            "x.plural": {"localizations": {"en": plural({"one": "%lld cat", "other": "%lld cats"}),
                                           "es": plural({"one": "%lld gato", "many": "%lld de gatos", "other": "%lld gatos"})}},
        }
        decoded = pack.read_pack(self.build(strings))
        position = {identifier: index for index, identifier in enumerate(decoded.ids)}
        self.assertEqual("Llano", decoded.blobs["es"].entries[position["x.plain"]])
        self.assertEqual("\x01%lld gato\x01%lld de gatos\x01%lld gatos", decoded.blobs["es"].entries[position["x.plural"]])
        self.assertEqual("\x01%lld cat\x01%lld cats", decoded.blobs["en"].entries[position["x.plural"]])

    def test_a_plural_of_one_text_is_written_as_that_text(self):
        strings = {"x.same": {"localizations": {
            "en": plural({"one": "%lld cat", "other": "%lld cats"}),
            "es": plural({"one": "%lld gatos", "many": "%lld gatos", "other": "%lld gatos"}),
            "ja": plural({"other": "%lld匹"})}}}
        decoded = pack.read_pack(self.build(strings))
        self.assertEqual("%lld gatos", decoded.blobs["es"].entries[0])
        self.assertEqual("%lld匹", decoded.blobs["ja"].entries[0])

    def test_an_english_plural_of_one_text_stays_plural_so_the_pack_tells_plural_lines_from_plain_ones(self):
        # FR39: the person's file reads and writes a line by English's kind, so English keeps its forms even when they are all
        # alike; every other language is squeezed as before. A plain line stays plain in English.
        strings = {
            "x.same": {"localizations": {
                "en": plural({"one": "%lld items", "other": "%lld items"}),
                "es": plural({"one": "%lld elementos", "many": "%lld elementos", "other": "%lld elementos"}),
                "ja": plural({"other": "%lld件"})}},
            "x.plain": line("Page %lld", es="Página %lld"),
        }
        decoded = pack.read_pack(self.build(strings))
        position = {identifier: index for index, identifier in enumerate(decoded.ids)}
        self.assertEqual("\x01%lld items\x01%lld items", decoded.blobs["en"].entries[position["x.same"]])
        self.assertEqual("Page %lld", decoded.blobs["en"].entries[position["x.plain"]])
        self.assertEqual("%lld elementos", decoded.blobs["es"].entries[position["x.same"]])
        self.assertEqual("%lld件", decoded.blobs["ja"].entries[position["x.same"]])

    def test_plural_forms_follow_the_languages_category_order(self):
        arabic = {"zero": "%lld ٠", "one": "%lld ١", "two": "%lld ٢", "few": "%lld ٣", "many": "%lld ١١", "other": "%lld ١٠٠"}
        strings = {"x.count": {"localizations": {"en": plural({"other": "%lld x", "one": "%lld y"}), "ar": plural(arabic)}}}
        decoded = pack.read_pack(self.build(strings))
        self.assertEqual("\x01" + "\x01".join(arabic[c] for c in ("zero", "one", "two", "few", "many", "other")),
                         decoded.blobs["ar"].entries[0])
        # English's forms, given other-first in the catalog, are written one then other.
        self.assertEqual("\x01%lld y\x01%lld x", decoded.blobs["en"].entries[0])

    def test_a_state_new_line_is_not_compiled(self):
        strings = {"x.new": {"localizations": {"en": plain("Hi"), "es": plain("Hola", "new"), "de": plain("Hallo", "needs_review")}}}
        decoded = pack.read_pack(self.build(strings))
        self.assertEqual([""], decoded.blobs["es"].entries)
        self.assertEqual(["Hallo"], decoded.blobs["de"].entries)

    def test_an_empty_value_is_no_entry(self):
        strings = {"x.blank": {"localizations": {"en": plain("Hi"), "es": plain("")}}}
        self.assertEqual([""], pack.read_pack(self.build(strings)).blobs["es"].entries)

    def test_a_note_is_stored_with_its_id(self):
        strings = {"x.noted": {"comment": "A note\nwith two lines", "localizations": {"en": plain("Hi")}},
                   "x.silent": line("Quiet")}
        decoded = pack.read_pack(self.build(strings))
        self.assertEqual(["A note\nwith two lines", ""], decoded.blobs["notes"].entries)



# ---------------------------------------------------------------------------------------------------------------
# Determinism, the window, and the stamp.
# ---------------------------------------------------------------------------------------------------------------

class BuildTests(PackCase):
    """The same input gives the same bytes; the window is the blob's own size; the stamp lets a build skip."""

    def test_the_same_catalog_gives_the_same_bytes(self):
        path = FIXTURES / "plurals.xcstrings"
        self.assertEqual(pack.build_bytes(pack.build_plan(path)), pack.build_bytes(pack.build_plan(path)))

    def test_the_window_is_the_smallest_power_of_two_at_or_above_the_size(self):
        self.assertEqual(4096, pack.window_size(0))
        self.assertEqual(4096, pack.window_size(4096))
        self.assertEqual(8192, pack.window_size(4097))
        self.assertEqual(1 << 20, pack.window_size((1 << 20) - 1))
        self.assertEqual(1 << 20, pack.window_size(1 << 20))
        self.assertEqual(1 << 21, pack.window_size((1 << 20) + 1))

    def test_a_blobs_lzma2_dictionary_is_its_window(self):
        # The LZMA2 filter's property byte (byte 16 of an xz stream: the 12-byte stream header, then the block header's
        # size, flags, filter ID, and property size) holds the dictionary: 0x00 is 4 KiB and each two steps double it.
        raw = ("The same line again. " * 2000).encode("utf-8")
        small, wide = pack.compress(raw, True), pack.compress(raw, False)
        self.assertNotEqual(small[:24], wide[:24])
        self.assertEqual(raw, lzma.decompress(small, format=lzma.FORMAT_XZ))
        self.assertEqual(raw, lzma.decompress(wide, format=lzma.FORMAT_XZ))
        # 42,000 bytes rounds to a 64 KiB window, whose byte is 0x08; the preset's own 64 MiB is 0x1c.
        self.assertEqual(0x08, small[16])
        self.assertEqual(0x1C, wide[16])

    def test_a_build_skips_when_nothing_changed_and_rebuilds_when_something_did(self):
        catalog_path = self.write_catalog({"a.one": line("One", es="Uno")})
        out = self.folder / "Strings.pack"
        code, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertEqual(0, code)
        self.assertIn("wrote", said)
        first = out.read_bytes()
        self.assertTrue(Path(str(out) + ".stamp").is_file())
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("up to date", said)
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, "--force")
        self.assertIn("wrote", said)
        self.assertEqual(first, out.read_bytes())
        # A changed catalog rebuilds.
        self.write_catalog({"a.one": line("One", es="Uno"), "a.two": line("Two")})
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)
        self.assertNotEqual(first, out.read_bytes())
        # So does a changed output.
        out.write_bytes(b"damaged")
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)
        self.assertEqual(2, len(pack.read_pack(out.read_bytes()).ids))

    def test_no_stamp_writes_none_and_never_skips(self):
        catalog_path = self.write_catalog({"a.one": line("One")})
        out = self.folder / "Strings.pack"
        self.run_main("build", "--catalog", catalog_path, "--out", out, "--no-stamp")
        self.assertFalse(Path(str(out) + ".stamp").exists())
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, "--no-stamp")
        self.assertIn("wrote", said)

    def test_a_stamp_may_live_elsewhere(self):
        # The app's build keeps the stamp out of the app: it skips on it all the same.
        catalog_path = self.write_catalog({"a.one": line("One", es="Uno")})
        out = self.folder / "Strings.pack"
        stamp = self.folder / "elsewhere.stamp"
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, "--stamp", stamp)
        self.assertIn("wrote", said)
        self.assertTrue(stamp.is_file())
        self.assertFalse(Path(str(out) + ".stamp").exists())
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, "--stamp", stamp)
        self.assertIn("up to date", said)

    def test_a_rebuild_replaces_the_file_and_leaves_the_old_one_whole_for_whoever_has_it(self):
        # The engine maps the pack; a file rewritten in place under a running process can end it with SIGBUS.
        # A replaced file is a new file: whoever has the old one open or mapped still reads every byte of it. An open
        # handle stands in for the mapping here, because a mapping read after an in-place rewrite would crash the test
        # runner itself.
        out = self.folder / "Strings.pack"
        first = self.write_catalog({"a.one": line("One", es="Uno")})
        self.run_main("build", "--catalog", first, "--out", out)
        before = out.read_bytes()
        inode = out.stat().st_ino
        with open(out, "rb") as handle:
            self.write_catalog({"a.one": line("One", es="Uno"), "a.two": line("Two", es="Dos")})
            self.run_main("build", "--catalog", first, "--out", out)
            self.assertNotEqual(before, out.read_bytes())
            self.assertNotEqual(inode, out.stat().st_ino)
            self.assertEqual(before, handle.read())
        # Nothing but the pack, its stamp, and the languages' folders is left beside it.
        self.assertEqual(["Strings.pack", "Strings.pack.stamp", "catalog.xcstrings", "en.lproj", "es.lproj"],
                         sorted(entry.name for entry in self.folder.iterdir()))

    def test_a_failed_write_leaves_the_old_pack_and_stamp_and_no_temporary_file(self):
        out = self.folder / "Strings.pack"
        catalog_path = self.write_catalog({"a.one": line("One", es="Uno")})
        self.run_main("build", "--catalog", catalog_path, "--out", out)
        pack_before, stamp_before = out.read_bytes(), Path(str(out) + ".stamp").read_bytes()
        self.write_catalog({"a.one": line("One", es="Uno"), "a.two": line("Two")})
        # The write stops at the moment of replacing, as a full disk or a signal would stop it.
        with mock.patch.object(pack.os, "replace", side_effect=OSError("simulated")):
            with self.assertRaises(OSError):
                self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertEqual(pack_before, out.read_bytes())
        self.assertEqual(stamp_before, Path(str(out) + ".stamp").read_bytes())
        self.assertEqual(["Strings.pack", "Strings.pack.stamp", "catalog.xcstrings", "en.lproj", "es.lproj"],
                         sorted(entry.name for entry in self.folder.iterdir()))

    def test_the_stamp_is_written_only_after_the_pack(self):
        # A write that fails on the pack never reaches the stamp, so a stamp never vouches for a pack that is not there.
        out = self.folder / "Strings.pack"
        catalog_path = self.write_catalog({"a.one": line("One")})
        with mock.patch.object(pack.os, "replace", side_effect=OSError("simulated")):
            with self.assertRaises(OSError):
                self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertEqual(["catalog.xcstrings"], sorted(entry.name for entry in self.folder.iterdir()))

    def test_python_3_9_builds_the_same_entries(self):
        # Xcode's build phase runs /usr/bin/python3; the entries must match whatever Python made the committed pack.
        interpreter = Path("/usr/bin/python3")
        if not interpreter.exists():
            self.skipTest("no /usr/bin/python3 here")
        out = self.folder / "lines.pack"
        result = subprocess.run([str(interpreter), "-I", "-B", str(L10N / "pack.py"), "build", "--catalog",
                                 str(FIXTURES / "lines.xcstrings"), "--out", str(out), "--no-stamp"],
                                capture_output=True, text=True, timeout=120)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], pack.compare(FIXTURES / "lines.pack", out))


# ---------------------------------------------------------------------------------------------------------------
# The refusals.
# ---------------------------------------------------------------------------------------------------------------

class InfoPlistStringsTests(PackCase):
    """The InfoPlist.strings of each language, which `build` writes beside the pack (FR39 phase 8)."""

    def build(self, strings=None, *extra):
        """Builds a two-language catalog's pack into the case's folder; returns (the pack's path, the catalog's path)."""
        catalog_path = self.write_catalog(strings or {"a.one": line("One", es="Uno")})
        out = self.folder / "Strings.pack"
        code, _, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, *extra)
        self.assertEqual(0, code)
        return out, catalog_path

    def table(self, language):
        """The path of `language`'s InfoPlist.strings beside the pack."""
        return self.folder / f"{language}.lproj" / pack.INFO_PLIST_TABLE

    def test_each_language_gets_its_table_english_included_and_it_holds_no_entry(self):
        self.build()
        for language in ("en", "es"):
            text = self.table(language).read_text(encoding="utf-8")
            self.assertTrue(text.startswith("/* Written by Scripts/l10n/pack.py"), language)
            self.assertIn(f"({language})", text)
            self.assertNotIn('" = "', text, "no entry yet: the Info.plist strings get their IDs in a later batch")
        self.assertEqual(["InfoPlist.strings"], sorted(path.name for path in (self.folder / "es.lproj").iterdir()))

    def test_the_hook_writes_its_entries_escaped_in_key_order(self):
        plan = pack.build_plan(self.write_catalog({"a.one": line("One", es="Uno")}))
        entries = {"NSMicrophoneUsageDescription": 'Say "hi"\nand a back\\slash', "CFBundleDisplayName": "TextMouth"}
        with mock.patch.object(pack, "info_plist_entries", lambda _plan, _language, _display_name="": entries):
            text = pack.info_plist_text(plan, "es")
        self.assertEqual(['"CFBundleDisplayName" = "TextMouth";',
                          '"NSMicrophoneUsageDescription" = "Say \\"hi\\"\\nand a back\\\\slash";'], text.splitlines()[1:])

    def test_a_test_build_is_named_in_every_languages_table(self):
        """--display-name (the Debug configuration's TEXTMOUTH_TEST_DISPLAY_NAME) names the app in every language's
        table, the one place Launch Services, the Dock, and VoiceOver read a bundle's shown name from."""
        self.build(None, "--display-name", "TextMouth Test")
        for language in ("en", "es"):
            self.assertEqual(['"CFBundleDisplayName" = "TextMouth Test";'],
                             self.table(language).read_text(encoding="utf-8").splitlines()[1:], language)

    def test_a_build_without_a_display_name_keeps_the_apps_own_name(self):
        """A Release build passes no name, so no table renames the app: it stays TextMouth, the bundle's own."""
        self.build(None, "--display-name", "")
        for language in ("en", "es"):
            self.assertNotIn("CFBundleDisplayName", self.table(language).read_text(encoding="utf-8"), language)

    def test_a_changed_display_name_writes_the_tables_again(self):
        """The name is part of the stamp, so a build of the other configuration never keeps the last one's tables."""
        out, catalog_path = self.build(None, "--display-name", "TextMouth Test")
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)
        self.assertNotIn("CFBundleDisplayName", self.table("en").read_text(encoding="utf-8"))
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("up to date", said)

    def test_a_rebuild_replaces_each_table_and_never_rewrites_it_in_place(self):
        out, catalog_path = self.build()
        inode = self.table("es").stat().st_ino
        self.run_main("build", "--catalog", catalog_path, "--out", out, "--force")
        self.assertNotEqual(inode, self.table("es").stat().st_ino)

    def test_the_stamp_covers_the_tables(self):
        out, catalog_path = self.build()
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("up to date", said)
        # A table changed by hand, and one that is missing, each make the next build write them again.
        self.table("es").write_text("/* edited */\n", encoding="utf-8")
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)
        self.assertTrue(self.table("es").read_text(encoding="utf-8").startswith("/* Written by"))
        os.replace(self.table("en"), self.folder / "moved-away.strings")
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)
        self.assertTrue(self.table("en").is_file())

    def test_a_stamp_without_the_tables_is_not_trusted(self):
        """The stamp an earlier builder wrote (no `infoPlist` list) makes one build run again and write them."""
        out, catalog_path = self.build()
        stamp = Path(str(out) + ".stamp")
        written = json.loads(stamp.read_text(encoding="utf-8"))
        del written["infoPlist"]
        stamp.write_text(json.dumps(written), encoding="utf-8")
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertIn("wrote", said)

    def plant_tables(self):
        """Writes a Localizable.strings and .stringsdict into es.lproj, as an earlier build of the app left them."""
        for name in ("Localizable.strings", "Localizable.stringsdict"):
            (self.folder / "es.lproj" / name).write_text('"a"="b";', encoding="utf-8")

    def test_a_build_without_the_flag_leaves_every_file_beside_the_pack_alone(self):
        out, catalog_path = self.build()
        self.plant_tables()
        self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.run_main("build", "--catalog", catalog_path, "--out", out, "--force")
        self.assertEqual(["InfoPlist.strings", "Localizable.strings", "Localizable.stringsdict"],
                         sorted(path.name for path in (self.folder / "es.lproj").iterdir()))

    def test_a_table_of_apples_that_an_earlier_build_left_is_removed_with_the_flag_even_when_the_pack_is_up_to_date(self):
        out, catalog_path = self.build()
        self.plant_tables()
        _, said, _ = self.run_main("build", "--catalog", catalog_path, "--out", out, "--remove-apple-tables")
        self.assertIn("up to date", said)
        self.assertEqual(["InfoPlist.strings"], sorted(path.name for path in (self.folder / "es.lproj").iterdir()))

    def test_no_stamp_still_writes_the_tables(self):
        self.build(None, "--no-stamp")
        self.assertTrue(self.table("es").is_file())

    def test_a_catalog_with_a_new_language_gets_its_folder(self):
        out, catalog_path = self.build()
        self.write_catalog({"a.one": line("One", es="Uno", fr="Un")})
        self.run_main("build", "--catalog", catalog_path, "--out", out)
        self.assertTrue(self.table("fr").is_file())


class RefusalTests(PackCase):
    """What the builder refuses: it names the key and the language, and writes nothing."""

    def assert_refused(self, strings, key, language, phrase, **options):
        """Asserts one of the refusals of `strings` names `key` and `language` and contains `phrase`."""
        problems = self.refusals(strings, **options)
        matching = [p for p in problems if f"{key} [{language}]" in p and phrase in p]
        self.assertTrue(matching, f"no refusal naming {key} [{language}] and {phrase!r} in {problems}")

    def test_a_specifier_the_pack_does_not_allow(self):
        for bad in ("%d", "%s", "%f", "%5.2f", "%ld", "%1$s", "%x", "%@%@ %n", "%-5lld", "%#@count@", "%05lld"):
            with self.subTest(bad):
                self.assert_refused({"a.b": line("Fine", es="Mal " + bad)}, "a.b", "es", "not one the pack allows")

    def test_the_allowed_specifiers_pass(self):
        # Unnumbered specifiers and numbered ones (a reordering), a literal percent sign in each.
        strings = {"a.b": line("%@ %lld 100%%", es="%@ %lld 100%%"), "a.c": line("%@ %lld", es="%2$lld de %1$@")}
        self.assertEqual(["a.b", "a.c"], pack.build_plan(self.write_catalog(strings)).ids)

    def test_an_english_specifier_the_pack_does_not_allow(self):
        self.assert_refused({"a.b": line("Bad %s")}, "a.b", "en", "not one the pack allows")

    def test_a_control_character_other_than_a_line_feed_or_a_tab(self):
        for character in ("\0", "\r", "\x1b", "\x01", "\x7f", "\x85"):
            with self.subTest(repr(character)):
                self.assert_refused({"a.b": line("Fine", es="Mal" + character)}, "a.b", "es", "control character")
        pack.build_plan(self.write_catalog({"a.b": line("Fine\t\n", es="Bien\n\t")}))

    def test_a_control_character_in_a_note(self):
        problems = self.refusals({"a.b": {"comment": "bad\x00note", "localizations": {"en": plain("Fine")}}})
        self.assertTrue(any("a.b [notes]" in p and "control character" in p for p in problems), problems)

    def test_a_plural_missing_a_category(self):
        strings = {"a.b": {"localizations": {"en": plural({"one": "%lld a", "other": "%lld as"}),
                                             "ru": plural({"one": "%lld а", "few": "%lld б", "other": "%lld в"})}}}
        self.assert_refused(strings, "a.b", "ru", "lacks the plural form many")

    def test_a_plural_with_an_extra_category(self):
        strings = {"a.b": {"localizations": {"en": plural({"one": "%lld a", "other": "%lld as"}),
                                             "ja": plural({"one": "%lld 個", "other": "%lld 個"})}}}
        self.assert_refused(strings, "a.b", "ja", "does not use")

    def test_a_form_in_state_new_counts_as_missing(self):
        forms = {"one": plain("%lld a"), "other": plain("%lld as", "new")}
        strings = {"a.b": {"localizations": {"en": {"variations": {"plural": forms}}}}}
        self.assert_refused(strings, "a.b", "en", "lacks the plural form other")

    def test_a_device_variation(self):
        strings = {"a.b": {"localizations": {"en": plain("Hi"), "es": {"variations": {"device": {"mac": plain("Hola"), "other": plain("Hola")}}}}}}
        self.assert_refused(strings, "a.b", "es", "device variation")

    def test_a_substitution(self):
        strings = {"a.b": {"localizations": {"en": plain("Hi %#@x@"), "es": {"stringUnit": {"state": "translated", "value": "Hola %#@x@"},
                                                                            "substitutions": {"x": plural({"one": "u", "other": "o"})}}}}}
        problems = self.refusals(strings)
        self.assertTrue(any("a.b [es]" in p and "substitution" in p for p in problems), problems)

    def test_a_device_variation_inside_a_plural_form(self):
        node = {"stringUnit": {"state": "translated", "value": "%lld a"}, "variations": {"device": {"mac": plain("x")}}}
        strings = {"a.b": {"localizations": {"en": {"variations": {"plural": {"one": node, "other": plain("%lld as")}}}}}}
        self.assert_refused(strings, "a.b", "en", "variation or substitution")

    def test_an_id_outside_the_pattern(self):
        bad = ("Upper.case", "nodot", "a.B", "a.b.c.d.e", "1a.b", "a..b", "a.b-c", "a.b_c", "a.é", "a. b", "a.b.")
        for identifier in bad:
            with self.subTest(identifier):
                problems = self.refusals({identifier: line("Hi")})
                self.assertTrue(any("outside the pattern" in p for p in problems), problems)

    def test_ids_inside_the_pattern(self):
        good = ("a.b", "aB.cD", "a1.b2", "menu.open.recent", "a.b.c.d", "a" + "b" * 20 + "." + "c" * 25)
        plan = pack.build_plan(self.write_catalog({identifier: line("Hi") for identifier in good}))
        self.assertEqual(sorted(good), plan.ids)

    def test_an_id_over_48_characters(self):
        forty_nine = "a." + "b" * 47
        self.assertEqual(49, len(forty_nine))
        problems = self.refusals({forty_nine: line("Hi")})
        self.assertTrue(any("49 characters, over 48" in p for p in problems), problems)
        pack.build_plan(self.write_catalog({forty_nine[:-1]: line("Hi")}))

    def test_the_length_limit_can_be_raised_for_a_measurement(self):
        forty_nine = "a." + "b" * 47
        self.assertEqual([forty_nine], pack.build_plan(self.write_catalog({forty_nine: line("Hi")}), max_id_length=60).ids)

    def test_an_id_with_no_english_text(self):
        strings = {"a.b": {"localizations": {"es": plain("Hola")}}}
        self.assert_refused(strings, "a.b", "en", "no English text")

    def test_a_translation_whose_placeholders_differ_from_the_english(self):
        self.assert_refused({"a.b": line("Open %@", es="Abrir")}, "a.b", "es", "missing placeholder")
        self.assert_refused({"a.b": line("Open", es="Abrir %@")}, "a.b", "es", "extra placeholder")
        self.assert_refused({"a.b": line("Page %lld", es="Página %@")}, "a.b", "es", "placeholder")
        self.assert_refused({"a.b": line("%@ %lld", es="%lld %@")}, "a.b", "es", "placeholder")

    def test_a_lone_percent_sign_in_a_format_string(self):
        self.assert_refused({"a.b": line("%lld done", es="%lld % hecho")}, "a.b", "es", "lone %")

    def test_an_empty_plural_form(self):
        forms = {"one": plain("%lld a"), "other": plain("")}
        strings = {"a.b": {"localizations": {"en": {"variations": {"plural": forms}}}}}
        self.assert_refused(strings, "a.b", "en", "empty text")

    def test_a_language_with_no_plural_rule(self):
        strings = {"a.b": {"localizations": {"en": plain("Hi"), "xx": plural({"other": "%lld a"})}}}
        self.assert_refused(strings, "a.b", "xx", "no plural rule")

    def test_every_problem_is_listed_and_nothing_is_written(self):
        strings = {"a.b": line("Fine", es="Mal %s", de="Mal\0"), "Bad": line("Hi")}
        path = self.write_catalog(strings)
        out = self.folder / "out.pack"
        code, _, err = self.run_main("build", "--catalog", path, "--out", out)
        self.assertEqual(1, code)
        self.assertFalse(out.exists())
        self.assertFalse(Path(str(out) + ".stamp").exists())
        self.assertIn("4 problems", err)
        self.assertIn("a.b [es]", err)
        self.assertIn("a.b [de]", err)
        self.assertIn("Bad", err)

    def test_a_long_language_code(self):
        strings = {"a.b": {"localizations": {"en": plain("Hi"), "es-419-extra-long": plain("Hola")}}}
        problems = self.refusals(strings)
        self.assertTrue(any("at most 12 characters" in p for p in problems), problems)


# ---------------------------------------------------------------------------------------------------------------
# verify, compare, size.
# ---------------------------------------------------------------------------------------------------------------

class CheckTests(PackCase):
    """`verify` finds what differs from the catalog, `compare` what differs between packs, `size` reports the blobs."""

    def build(self, strings, name="a.pack"):
        """Builds a pack of `strings` into the temporary folder and returns (catalog path, pack path)."""
        path = self.write_catalog(strings)
        out = self.folder / name
        out.write_bytes(pack.build_bytes(pack.build_plan(path)))
        return path, out

    def test_a_good_pack_verifies(self):
        path, out = self.build({"a.one": line("One", es="Uno")})
        self.assertEqual([], pack.verify(out, path))
        self.assertEqual(0, self.run_main("verify", out, "--catalog", path)[0])

    def test_a_pack_of_another_catalog_is_found(self):
        path, out = self.build({"a.one": line("One", es="Uno")})
        self.write_catalog({"a.one": line("One", es="Uno"), "a.two": line("Two")})
        found = pack.verify(out, path)
        self.assertTrue(any("hash" in sentence for sentence in found), found)
        self.assertTrue(any("a.two" in sentence for sentence in found), found)
        self.assertEqual(1, self.run_main("verify", out, "--catalog", path)[0])

    def test_a_changed_entry_is_found_by_id_and_language(self):
        path, out = self.build({"a.one": line("One", es="Uno")})
        # The same catalog with a different Spanish line, built into another pack, differs from the first.
        changed = self.write_catalog({"a.one": line("One", es="Un")}, "changed.xcstrings")
        other = self.folder / "b.pack"
        other.write_bytes(pack.build_bytes(pack.build_plan(changed)))
        found = pack.compare(out, other)
        self.assertEqual(["a.one [es]: 'Uno' against 'Un'"], found)

    def test_compare_ignores_the_compressed_bytes(self):
        path = FIXTURES / "plurals.xcstrings"
        plan = pack.build_plan(path)
        narrow, wide = self.folder / "narrow.pack", self.folder / "wide.pack"
        narrow.write_bytes(pack.build_bytes(plan, windowed=True))
        wide.write_bytes(pack.build_bytes(plan, windowed=False))
        self.assertEqual([], pack.compare(narrow, wide))
        self.assertEqual(0, self.run_main("compare", narrow, wide)[0])

    def test_compare_reports_ids_and_blobs_only_one_pack_has(self):
        _, first = self.build({"a.one": line("One", es="Uno")}, "first.pack")
        _, second = self.build({"a.one": line("One"), "a.two": line("Two")}, "second.pack")
        found = pack.compare(first, second)
        self.assertIn("the blob es is missing", found)
        self.assertIn("ID a.two: extra", found)

    def test_a_plural_difference_is_found(self):
        def plural_catalog(one):
            return {"a.n": {"localizations": {"en": plural({"one": one, "other": "%lld as"})}}}
        _, first = self.build(plural_catalog("%lld a"), "first.pack")
        _, second = self.build(plural_catalog("%lld A"), "second.pack")
        self.assertEqual(["a.n [en]: '%lld a | %lld as' against '%lld A | %lld as'"], pack.compare(first, second))

    def test_a_damaged_pack_is_refused_with_a_reason(self):
        _, out = self.build({"a.one": line("One", es="Uno")})
        data = bytearray(out.read_bytes())
        for label, damaged, phrase in (
            ("magic", b"XXXX" + bytes(data[4:]), "magic"),
            ("version", bytes(data[:4]) + struct.pack("<H", 1) + bytes(data[6:]), "version"),
            ("cut", bytes(data[:-5]), "past the end"),
            ("short", bytes(data[:10]), "shorter"),
        ):
            with self.subTest(label):
                with self.assertRaises(pack.PackError) as caught:
                    pack.read_pack(damaged)
                self.assertIn(phrase, str(caught.exception))

    def test_a_blob_with_the_wrong_raw_size_or_count_is_refused(self):
        raw = b"one\0two\0"
        data = lzma.compress(raw, format=lzma.FORMAT_XZ)
        self.assertEqual(["one", "two"], pack.decode_blob("x", data, len(raw), 2).entries)
        with self.assertRaises(pack.PackError):
            pack.decode_blob("x", data, len(raw) - 1, 2)
        with self.assertRaises(pack.PackError):
            pack.decode_blob("x", data, len(raw) + 1, 2)
        with self.assertRaises(pack.PackError):
            pack.decode_blob("x", data, len(raw), 3)
        with self.assertRaises(pack.PackError):
            pack.decode_blob("x", lzma.compress(b"one\0two", format=lzma.FORMAT_XZ), 7, 1)

    def test_each_method_round_trips_through_the_reader(self):
        raw = b"one\0two\0"
        for method, data in ((pack.METHOD_LZMA, pack.compress(raw)), (pack.METHOD_BZIP2, pack.compress_bzip2(raw))):
            with self.subTest(pack.METHOD_NAMES[method]):
                blob = pack.decode_blob("x", data, len(raw), 2, method)
                self.assertEqual(["one", "two"], blob.entries)
                self.assertEqual(method, blob.method)

    def test_a_bzip2_blob_that_is_cut_short_or_the_wrong_size_or_damaged_is_refused(self):
        raw = b"one\0two\0" * 50
        data = pack.compress_bzip2(raw)
        for label, damaged, size in (
            ("cut short", data[:-8], len(raw)),
            ("a size too small", data, len(raw) - 1),
            ("a size too large", data, len(raw) + 1),
            # A byte flipped inside the block fails bzip2's own CRC.
            ("a wrong checksum", data[:20] + bytes([data[20] ^ 0xFF]) + data[21:], len(raw)),
        ):
            with self.subTest(label), self.assertRaises(pack.PackError):
                pack.decode_blob("x", damaged, size, 100, pack.METHOD_BZIP2)

    def test_an_unknown_method_is_refused(self):
        with self.assertRaisesRegex(pack.PackError, "method 7"):
            pack.decode_blob("x", pack.compress(b"one\0"), 4, 1, 7)

    def test_a_pack_that_names_an_unknown_method_is_refused(self):
        _, out = self.build({"a.one": line("One", es="Uno")})
        data = bytearray(out.read_bytes())
        # The ids blob's record is the first; its method is the record's last field.
        struct.pack_into("<I", data, pack.HEADER.size + pack.DIRECTORY_RECORD.size - 4, 9)
        with self.assertRaisesRegex(pack.PackError, "method 9"):
            pack.read_pack(bytes(data))

    def test_the_smaller_method_is_chosen_and_a_tie_chooses_lzma(self):
        tiny = b"x\0"
        for raw in (tiny, ("A line of text, then another. " * 400).encode(), bytes(range(256)) * 20):
            with self.subTest(len(raw)):
                method, data = pack.compress_smallest(raw)
                other = {pack.METHOD_LZMA: pack.compress_bzip2, pack.METHOD_BZIP2: pack.compress}[method](raw)
                self.assertLessEqual(len(data), len(other))
                self.assertEqual(raw, decompress_blob(data, method))
        # A tie: both compressors replaced by ones that return equal-sized bytes.
        with mock.patch.object(packfile, "compress", return_value=b"aaaa"), mock.patch.object(packfile, "compress_bzip2", return_value=b"bbbb"):
            self.assertEqual((pack.METHOD_LZMA, b"aaaa"), pack.compress_smallest(b"x"))
        with mock.patch.object(packfile, "compress", return_value=b"aaaaa"), mock.patch.object(packfile, "compress_bzip2", return_value=b"bbbb"):
            self.assertEqual((pack.METHOD_BZIP2, b"bbbb"), pack.compress_smallest(b"x"))

    def test_a_pack_uses_both_methods_and_is_the_same_bytes_twice(self):
        strings = {f"a.line{index}": line("A line of English text, number %d." % index, es="Una línea de texto %d." % index)
                   for index in range(60)}
        plan = pack.build_plan(self.write_catalog(strings))
        first, second = pack.build_bytes(plan), pack.build_bytes(plan)
        self.assertEqual(first, second)
        methods = {name: blob.method for name, blob in pack.read_pack(first).blobs.items()}
        # The measure of the real pack: bzip2 is smaller for these blobs. The pack still reads whichever way each went.
        self.assertIn(pack.METHOD_BZIP2, methods.values())
        # A mixed pack: the ids blob forced to LZMA and the notes blob to bzip2, and both read back.
        def by_name(raw, windowed=True):
            if raw.startswith(b"a."):
                return pack.METHOD_LZMA, pack.compress(raw, windowed)
            return pack.METHOD_BZIP2, pack.compress_bzip2(raw)
        with mock.patch.object(packfile, "compress_smallest", side_effect=by_name):
            decoded = pack.read_pack(pack.assemble(b"\0" * 32, 1, [("ids", b"a.one\0", 1), ("notes", b"note\0", 1)]))
        self.assertEqual({"ids": pack.METHOD_LZMA, "notes": pack.METHOD_BZIP2}, {n: b.method for n, b in decoded.blobs.items()})

    def test_the_stamp_names_the_format_version(self):
        catalog_path = self.write_catalog({"a.one": line("One", es="Uno")})
        self.assertEqual(pack.FORMAT_VERSION, pack.stamp_of(catalog_path, pack.MAX_ID_LENGTH)["formatVersion"])

    def test_size_reports_each_blob_and_the_window_comparison(self):
        _, out = self.build({"a.one": line("One", es="Uno")})
        code, said, _ = self.run_main("size", out, "--compare-window")
        self.assertEqual(0, code)
        for name in ("ids", "notes", "en", "es"):
            self.assertIn(name, said)
        self.assertIn("64 MiB window", said)
        self.assertIn("the pack", said)
        # Each blob's method is shown.
        self.assertRegex(said, r"es +\d+ +\d+ +\d+ +(lzma|bzip2)")


# ---------------------------------------------------------------------------------------------------------------
# The whole catalog, with IDs these tests make themselves.
# ---------------------------------------------------------------------------------------------------------------

class RealCatalogTests(PackCase):
    """The real catalog (keyed by ID) builds, verifies, and rebuilds to the same bytes."""

    def test_the_whole_catalog_builds_verifies_and_rebuilds_identically(self):
        if not REAL_CATALOG.exists():
            self.skipTest("the catalog is not in this tree")
        keys = sorted(catalog.Catalog.load(REAL_CATALOG).strings)
        out = self.folder / "Strings.pack"
        code, _, err = self.run_main("build", "--catalog", REAL_CATALOG, "--out", out, "--no-stamp")
        self.assertEqual(0, code, err)
        data = out.read_bytes()
        decoded = pack.read_pack(data)
        self.assertEqual(len(keys), len(decoded.ids))
        self.assertEqual(sorted(decoded.ids), decoded.ids)
        self.assertEqual(["ids", "notes", "en"], list(decoded.blobs)[:3])
        self.assertGreater(len(decoded.blobs), 20, "the catalog's languages")
        self.assertLess(len(data), 1_500_000, "the budget `make check` will hold the pack to")
        self.assertEqual([], pack.verify(out, REAL_CATALOG))
        # The same bytes twice, from a second plan.
        self.assertEqual(data, pack.build_bytes(pack.build_plan(REAL_CATALOG)))


if __name__ == "__main__":
    if "--regenerate" in sys.argv:
        regenerate()
    else:
        unittest.main()
