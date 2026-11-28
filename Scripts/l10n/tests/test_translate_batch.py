"""Tests of `todo` and `apply` (Scripts/l10n/translate.py through Scripts/l10n/l10n.py): the batch of strings to translate
and the translated batch checked and written back.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works in a temporary folder: a catalog with strings in every state, a glossary, a made-up source tree, and a
locations table. Nothing is built, and the repository's own catalog and glossary are never read.
"""
import contextlib
import io
import json
import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import glossary  # noqa: E402
import l10n  # noqa: E402
import translate  # noqa: E402
import test_l10n as base  # noqa: E402  (its helpers: entry, unit, plural)
import test_translate as shared  # noqa: E402  (its CatalogCase and run)

# A small glossary the tests use: two names and two terms with Spanish translations.
GLOSSARY = {
    "doNotTranslate": ["TextMouth", "VoiceOver"],
    "terms": [
        {"term": "Library", "translations": {"es": {"text": "Biblioteca"}}},
        {"term": "Bookmark", "note": "A saved place in a book", "translations": {"es": {"text": "Marcador", "check": True}}},
    ],
}
# The source files the strings are used in, with made-up lines.
PLAY_VIEW = "TextMouth/Views/PlayView.swift"
OTHER_VIEW = "TextMouth/Views/Other.swift"
# The lines that use a string spell its text out, as the code does (a value is interpolated where the key has a placeholder).
USES = {1: 'Text("Add \\(name) to your Library")', 10: 'Button("Play") {', 15: 'Text("Play")'}
SOURCE = {
    PLAY_VIEW: "\n".join(USES.get(number, f"line {number}") for number in range(1, 21)),
    OTHER_VIEW: 'alpha\nText("Play")\ngamma\n',
}
# The message `todo` gives for a string that is not in the batch because there is nothing to do for it.
NOTHING_TO_DO = "nothing to translate (done, stale, or not to be translated)"


class BatchCase(shared.CatalogCase):
    """A catalog with strings in every state, a glossary, a made-up source tree, and a locations table, in a temporary
    folder; `todo` and `apply` are run on them through the command line."""

    def setUp(self):
        super().setUp()
        self.glossary = self.folder / "glossary.json"
        self.glossary.write_text(json.dumps(GLOSSARY), encoding="utf-8")
        self.root = self.folder / "tree"
        for name, text in SOURCE.items():
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            (self.root / name).write_text(text, encoding="utf-8")
        self.locations = self.folder / "locations.json"
        self.locations.write_text(json.dumps({"Localizable": {
            "Play": [{"file": PLAY_VIEW, "line": 10}, {"file": PLAY_VIEW, "line": 15}, {"file": OTHER_VIEW, "line": 2}],
            "Open %@ in TextMouth": [{"file": "TextMouth/Views/Missing.swift", "line": 3}, {"file": "../escape.swift", "line": 1}],
            "Add %@ to your Library": [{"file": PLAY_VIEW, "line": 1}],
        }}), encoding="utf-8")
        self.make({
            "Play": base.entry("The button that plays the book"),
            "Open %@ in TextMouth": base.entry("A menu item"),
            "Add %@ to your Library": base.entry("A button"),
            "Add %@ to the Library": {"comment": "A button", "extractionState": "stale",
                                      "localizations": {"es": base.unit("Añade %@ a la Biblioteca")}},
            "%lld books": base.entry("A count of books", en=base.plural(one=base.unit("%lld book"), other=base.unit("%lld books"))),
            "Done": base.entry("A word", es=base.unit("Hecho")),
            "Reviewed": base.entry("Needs a look", es=base.unit("Revisado", "needs_review")),
            "Tap": base.entry("A hint", en={"variations": {"device": {"mac": base.unit("Click")}}}),
        })

    def todo(self, *extra, language="es"):
        """Runs `todo` on the fixtures; returns (status, the batch loaded from standard output or None, standard error)."""
        with mock.patch.object(l10n, "ROOT", self.root):
            status, out, err = shared.run("todo", "--lang", language, "--catalog", str(self.path), "--glossary", str(self.glossary),
                                          "--locations", str(self.locations), *extra)
        return status, (json.loads(out) if out.strip().startswith("{") else None), err

    def items(self, *extra):
        """The items of the batch `todo` makes, by key."""
        status, batch, err = self.todo(*extra)
        self.assertEqual(status, 0, err)
        return {item["key"]: item for item in batch["items"]}


class TodoTests(BatchCase):
    """`todo`: the batch of strings to translate."""

    def test_only_the_strings_that_want_a_translation_are_in_the_batch(self):
        self.assertEqual(sorted(self.items()), ["%lld books", "Add %@ to your Library", "Open %@ in TextMouth", "Play", "Reviewed"],
                         "Done is done, the stale string is not offered, and the device string is skipped")

    def test_an_item_holds_what_a_translator_needs(self):
        item = self.items()["Open %@ in TextMouth"]
        self.assertEqual(item["english"], "Open %@ in TextMouth")
        self.assertEqual(item["comment"], "A menu item")
        self.assertEqual(item["placeholders"], ["%@"])
        self.assertEqual(item["doNotTranslate"], ["TextMouth"])
        self.assertEqual(item["translation"], "")
        self.assertNotIn("pluralCategories", item)

    def test_the_context_is_five_lines_around_the_use_and_at_most_two_uses(self):
        item = self.items()["Play"]
        self.assertEqual(len(item["context"]), 2)
        first = item["context"][0]
        self.assertEqual((first["file"], first["line"], first["firstLine"]), (PLAY_VIEW, 10, 8))
        self.assertEqual(first["code"], 'line 8\nline 9\nButton("Play") {\nline 11\nline 12')
        self.assertEqual(item["context"][1]["file"], OTHER_VIEW, "a different file is preferred to a second line of the first")
        self.assertEqual(item["context"][1]["code"], 'alpha\nText("Play")\ngamma')

    def test_a_use_near_the_top_of_a_file_has_fewer_lines_before(self):
        item = self.items()["Add %@ to your Library"]
        self.assertEqual(item["context"][0]["code"], 'Text("Add \\(name) to your Library")\nline 2\nline 3')

    def test_a_file_that_cannot_be_read_or_lies_outside_the_tree_gives_its_place_without_code(self):
        item = self.items()["Open %@ in TextMouth"]
        self.assertEqual(item["context"], [{"file": "TextMouth/Views/Missing.swift", "line": 3}, {"file": "../escape.swift", "line": 1}])

    def test_glossary_terms_found_in_the_english_come_with_their_translations(self):
        self.assertEqual(self.items()["Add %@ to your Library"]["glossary"], [{"term": "Library", "translation": "Biblioteca"}])
        self.assertEqual(self.items()["Reviewed"]["glossary"], [])

    def test_a_term_is_found_in_any_case_and_as_a_plural_and_carries_its_note_and_check(self):
        cat = self.load()
        cat.strings["Your bookmarks"] = base.entry("A heading", en=base.unit("Your bookmarks"))
        cat.save()
        self.assertEqual(self.items()["Your bookmarks"]["glossary"],
                         [{"term": "Bookmark", "translation": "Marcador", "note": "A saved place in a book", "check": True}])

    def test_an_earlier_translation_of_a_similar_stale_string_is_offered(self):
        previous = self.items()["Add %@ to your Library"]["previous"]
        self.assertEqual((previous["key"], previous["english"], previous["translation"]),
                         ("Add %@ to the Library", "Add %@ to the Library", "Añade %@ a la Biblioteca"))
        self.assertGreater(previous["similarity"], 0.8)
        self.assertNotIn("previous", self.items()["Play"], "nothing similar, nothing offered")

    def test_plural_english_gives_the_language_its_categories(self):
        item = self.items()["%lld books"]
        self.assertEqual(item["english"], {"one": "%lld book", "other": "%lld books"})
        self.assertEqual(item["pluralCategories"], ["one", "many", "other"])
        self.assertEqual(item["translation"], {"one": "", "many": "", "other": ""})
        self.assertEqual(item["placeholders"], ["%lld"])

    def test_a_translation_to_review_comes_with_the_current_one(self):
        self.assertEqual(self.items()["Reviewed"]["current"], "Revisado")

    def test_a_form_the_tools_do_not_write_is_skipped_with_its_reason(self):
        _, batch, _ = self.todo()
        self.assertEqual([entry["key"] for entry in batch["skipped"]], ["Tap"])
        self.assertIn("device variations", batch["skipped"][0]["reason"])

    def test_an_entry_with_no_english_text_is_skipped_and_says_why(self):
        # An empty English is no English: the pack refuses it too (a line must say something).
        cat = self.load()
        cat.strings["empty.label"] = base.entry("An empty label", en=base.unit(""))
        cat.save()
        _, batch, _ = self.todo()
        self.assertNotIn("empty.label", [item["key"] for item in batch["items"]])
        self.assertEqual([entry["key"] for entry in batch["skipped"] if entry["key"] == "empty.label"], ["empty.label"])
        self.assertIn("no English", [entry["reason"] for entry in batch["skipped"] if entry["key"] == "empty.label"][0])

    def test_the_limit_cuts_the_batch_and_counts_the_rest(self):
        _, batch, _ = self.todo("--limit", "2")
        self.assertEqual((batch["count"], batch["remaining"]), (2, 4))  # six are pending: Tap is skipped later
        _, whole, _ = self.todo("--limit", "0")
        self.assertEqual((whole["count"], whole["remaining"]), (5, 0))

    def test_keys_from_a_file_of_lines_a_list_or_a_rejected_file(self):
        lines, listing, rejected = (self.folder / name for name in ("lines.txt", "list.json", "r.json"))
        lines.write_text("Play\nDone\nNo such key\n", encoding="utf-8")
        listing.write_text(json.dumps(["Play", "Reviewed"]), encoding="utf-8")
        rejected.write_text(json.dumps({"items": [{"key": "Reviewed"}]}), encoding="utf-8")
        self.assertEqual(sorted(self.items("--keys-from", str(lines))), ["Play"])
        self.assertEqual(sorted(self.items("--keys-from", str(listing))), ["Play", "Reviewed"])
        self.assertEqual(sorted(self.items("--keys-from", str(rejected))), ["Reviewed"])
        _, batch, _ = self.todo("--keys-from", str(lines))
        self.assertEqual({entry["key"]: entry["reason"] for entry in batch["skipped"]},
                         {"Done": NOTHING_TO_DO, "No such key": "not in the catalog"})

    def test_the_strings_of_some_files(self):
        self.assertEqual(sorted(self.items("--file", OTHER_VIEW)), ["Play"])
        self.assertEqual(sorted(self.items("--file", OTHER_VIEW, "TextMouth/Views/Missing.swift")), ["Open %@ in TextMouth", "Play"])

    def test_an_area_the_scanner_does_not_know_is_refused(self):
        status, _, err = self.todo("--area", "no-such-area")
        self.assertEqual(status, 2)
        self.assertRegex(err, "no area 'no-such-area'|does not have yet")

    def test_the_source_language_and_a_language_without_a_rule_are_refused(self):
        self.assertEqual(self.todo(language="en")[0], 2)
        self.assertEqual(self.todo(language="xx")[0], 2)

    def test_the_batch_can_go_to_a_file(self):
        out = self.folder / "batch.json"
        status, _, _ = self.todo("--out", str(out))
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(out.read_text(encoding="utf-8"))["language"], "es")

    def test_a_missing_locations_file_gives_a_batch_without_context(self):
        self.locations.unlink()
        status, batch, err = self.todo()
        self.assertEqual(status, 0)
        self.assertIn("locations.json", err)
        self.assertEqual(batch["items"][0]["context"], [])


class LimitOptionTests(BatchCase):
    """`--limit` takes a count of zero or more."""

    def test_a_negative_limit_is_refused_by_todo_and_check(self):
        for command in ("todo", "check"):
            extra = ("--lang", "es") if command == "todo" else ()
            err = io.StringIO()
            with contextlib.redirect_stderr(err), self.assertRaises(SystemExit) as raised:
                l10n.main([command, *extra, "--limit", "-1", "--catalog", str(self.path)])
            self.assertEqual(raised.exception.code, 2, command)
            self.assertIn("negative", err.getvalue())

    def test_zero_means_all_and_text_is_refused(self):
        status, batch, _ = self.todo("--limit", "0")
        self.assertEqual((status, batch["remaining"]), (0, 0))
        err = io.StringIO()
        with contextlib.redirect_stderr(err), self.assertRaises(SystemExit):
            l10n.main(["todo", "--lang", "es", "--limit", "many", "--catalog", str(self.path)])
        self.assertIn("not a whole number", err.getvalue())


class TodoContextTests(BatchCase):
    """`todo`'s code context is checked against the code it is read from, and `previous` is offered with care (finding 7)."""

    def write_locations(self, stamp, **places):
        """Writes the locations file (the fixtures' places, `places` over them), with `stamp` as the commit it was made from."""
        table = json.loads(self.locations.read_text(encoding="utf-8"))["Localizable"]
        table.update(places)
        data = {"Localizable": table}
        if stamp is not None:
            data[l10n.EXTRACTED_KEY] = stamp
        self.locations.write_text(json.dumps(data), encoding="utf-8")

    def todo_at(self, head, *extra):
        """Runs `todo` as a checkout whose HEAD and TextMouth folder are `head` ((commit, tree id)); returns (status, batch,
        standard error)."""
        with mock.patch.object(l10n, "head_ids", return_value=head):
            return self.todo(*extra)

    def test_a_stamp_of_this_commit_or_of_these_sources_is_trusted_and_says_nothing(self):
        for head in (("aaa111", "tree1"), ("bbb222", "tree9")):
            self.write_locations({"commit": "aaa111", "treeId": "tree9"})
            status, batch, err = self.todo_at(head)
            self.assertEqual(status, 0)
            self.assertNotIn("warning", err, head)
            play = next(item for item in batch["items"] if item["key"] == "Play")
            self.assertIn("code", play["context"][0])

    def test_a_stamp_of_other_code_warns_and_leaves_out_the_code_that_does_not_hold_the_string(self):
        # `Play` is said to be at line 3 of the view, where the text is not (the code has moved since).
        self.write_locations({"commit": "old1234", "treeId": "oldtree"}, Play=[{"file": PLAY_VIEW, "line": 3}])
        status, batch, err = self.todo_at(("new5678", "newtree"))
        self.assertEqual(status, 0)
        self.assertRegex(err, r"warning: .*made from commit old1234.*this tree is at new5678.*run sync again")
        play = next(item for item in batch["items"] if item["key"] == "Play")
        self.assertEqual(play["context"][0]["line"], 3)
        self.assertNotIn("code", play["context"][0])
        self.assertIn("not near this line", play["context"][0]["codeOmitted"])
        self.assertIn("the code of 1 uses left out", err)

    def test_code_that_holds_the_text_is_kept_even_when_the_stamp_is_old(self):
        """The text of the key is near the line, so a stale stamp does no harm there."""
        self.write_locations({"commit": "old1234", "treeId": "oldtree"})
        _, batch, _ = self.todo_at(("new5678", "newtree"))
        library = next(item for item in batch["items"] if item["key"] == "Add %@ to your Library")
        self.assertIn("Library", library["context"][0]["code"])

    def test_a_key_with_no_text_of_its_own_has_code_only_when_the_locations_are_trusted(self):
        cat = self.load()
        cat.strings["%lld"] = base.entry("A bare number", en=base.unit("%lld"))
        cat.save()
        self.write_locations({"commit": "aaa111", "treeId": "t"}, **{"%lld": [{"file": PLAY_VIEW, "line": 5}]})
        _, batch, _ = self.todo_at(("aaa111", "t"))
        self.assertIn("code", next(item for item in batch["items"] if item["key"] == "%lld")["context"][0])
        _, batch, _ = self.todo_at(("zzz999", "other"))
        self.assertNotIn("code", next(item for item in batch["items"] if item["key"] == "%lld")["context"][0])

    def test_a_locations_file_with_no_stamp_warns(self):
        self.write_locations(None)
        _, _, err = self.todo_at(("aaa111", "tree1"))
        self.assertIn("has no stamp", err)

    def test_the_code_of_a_line_past_the_end_of_the_file_is_not_shown(self):
        self.write_locations({"commit": "aaa111", "treeId": "t"}, Play=[{"file": OTHER_VIEW, "line": 400}])
        _, batch, _ = self.todo_at(("aaa111", "t"))
        play = next(item for item in batch["items"] if item["key"] == "Play")
        self.assertEqual(play["context"], [{"file": OTHER_VIEW, "line": 400}])

    def test_the_previous_translation_shows_its_placeholders(self):
        self.assertEqual(self.items()["Add %@ to your Library"]["previous"]["placeholders"], ["%@"])

    def test_a_previous_translation_with_other_placeholders_is_not_offered(self):
        """A stale "Delete %@" is no help to "Delete %lld books" (the review's case: a ratio of 0.62)."""
        cat = self.load()
        cat.strings["Delete %@"] = {"comment": "c", "extractionState": "stale", "localizations": {"en": base.unit("Delete %@"), "es": base.unit("Eliminar %@")}}
        cat.strings["Delete %lld books"] = base.entry("A confirmation", en=base.unit("Delete %lld books"))
        cat.save()
        self.assertNotIn("previous", self.items()["Delete %lld books"])
        cat = self.load()
        cat.strings["Delete %@ now"] = base.entry("A confirmation", en=base.unit("Delete %@ now"))
        cat.save()
        self.assertEqual(self.items()["Delete %@ now"]["previous"]["key"], "Delete %@", "the same placeholders are offered")

    def test_a_very_short_text_finds_a_very_short_earlier_one(self):
        cat = self.load()
        cat.strings["OK"] = {"comment": "c", "extractionState": "stale", "localizations": {"en": base.unit("OK"), "es": base.unit("Aceptar")}}
        cat.strings["OKs"] = base.entry("A button", en=base.unit("OKs"))
        cat.save()
        self.assertEqual(self.items()["OKs"]["previous"]["key"], "OK")

    def test_a_big_batch_with_many_stale_strings_is_fast(self):
        """5,000 pending strings and 600 stale ones took 84 seconds when each was compared with every other one."""
        import random
        import time
        words = ("open play pause book chapter library import export delete add remove sleep timer bookmark voice speed rate "
                 "settings search index page heading feed episode podcast folder file window close next previous skip rewind "
                 "forward volume language shortcut keyboard braille table contents author title cover recent reading list").split()
        rng = random.Random(7)

        def phrase():
            """A made-up interface string, sometimes with a placeholder."""
            return " ".join(rng.choice(words) for _ in range(rng.randint(1, 6))) + rng.choice(("", "", " %@", " %lld", "..."))

        pending = sorted({phrase() for _ in range(5000)})
        stale = sorted({phrase() for _ in range(900)} - set(pending))[:600]
        strings = {text: {"comment": "c", "localizations": {"en": base.unit(text)}} for text in pending}
        strings.update({text: {"comment": "c", "extractionState": "stale", "localizations": {"en": base.unit(text), "es": base.unit("T " + text)}}
                        for text in stale})
        cat = catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": strings})
        # This process's CPU time, not the clock's: the clock also counts the time other work on a busy Mac holds the
        # cores (on November 20, 2026, with twenty translators' checks running at once, a run of these tests failed
        # once on each Python and passed later), while the CPU time still shows a comparison of each string with
        # every other one, which took 84 seconds of it.
        started = time.process_time()
        batch = translate.build_batch(cat, "es", glossary.Glossary(), {}, self.root, None, 0)
        elapsed = time.process_time() - started
        self.assertEqual(batch["count"], len(pending))
        self.assertLess(elapsed, 10, f"{elapsed:.1f} CPU seconds for {len(pending)} strings and {len(stale)} stale ones")


class ApplyCase(BatchCase):
    """The helpers the tests of `apply` share: a translated batch made from `todo`'s, and `apply` run on a file."""

    # The translations the tests fill in, for the five strings `todo` offers.
    GOOD = {"Play": "Reproducir", "Open %@ in TextMouth": "Abrir %@ en TextMouth", "Add %@ to your Library": "Añade %@ a tu Biblioteca",
            "%lld books": {"one": "%lld libro", "many": "%lld de libros", "other": "%lld libros"}, "Reviewed": "Revisado de nuevo"}

    def translated(self, **changes):
        """The batch `todo` makes, with the GOOD translations filled in, `changes` (key to translation) over them; written
        to batch.json, whose path is returned."""
        _, batch, _ = self.todo()
        translations = {**self.GOOD, **changes}
        for item in batch["items"]:
            item["translation"] = translations[item["key"]]
        path = self.folder / "batch.json"
        self.write_batch(path, batch)
        return path

    @staticmethod
    def write_batch(path, batch):
        """Writes `batch` to `path` as JSON."""
        path.write_text(json.dumps(batch, ensure_ascii=False), encoding="utf-8")

    @staticmethod
    def read_batch(path):
        """The batch in the file `path`."""
        return json.loads(path.read_text(encoding="utf-8"))

    def apply(self, path, *extra):
        """Runs `apply` on the batch file; returns (status, standard output)."""
        status, out, _ = shared.run("apply", str(path), "--catalog", str(self.path), "--glossary", str(self.glossary), *extra)
        return status, out



class ApplyTests(ApplyCase):
    """`apply`: a translated batch checked and written."""

    def refused(self, key, translation, reason):
        """Applies the batch with `key` translated as `translation`: the run exits 1, the output names the key and has
        `reason`, the key is not written, and the rest are. Returns the output."""
        status, out = self.apply(self.translated(**{key: translation}))
        self.assertEqual(status, 1, out)
        self.assertRegex(out, "refused .*" + re.escape(reason))
        self.assertEqual(self.values(key, "es"), {"": ("needs_review", "Revisado")} if key == "Reviewed" else {},
                         "a refused string is not written")
        self.assertEqual(self.load().status("Play" if key != "Play" else "Open %@ in TextMouth", "es"), "machine_translated",
                         "the good ones are written")
        return out

    def test_good_translations_are_written_as_machine_translated(self):
        status, out = self.apply(self.translated())
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Reproducir")})
        self.assertEqual(self.values("%lld books", "es")["plural.many"], ("machine_translated", "%lld de libros"))
        self.assertIn("5 written", out)
        self.assertEqual(self.load().status("Play", "es"), "machine_translated")

    def test_the_state_translated_can_be_asked_for(self):
        self.apply(self.translated(), "--state", "translated")
        self.assertEqual(self.load().status("Play", "es"), "translated")

    def test_a_second_run_changes_nothing(self):
        path = self.translated()
        self.apply(path)
        before = catalog.read_text(self.path)
        status, out = self.apply(path)
        self.assertEqual(status, 0, out)
        self.assertIn("0 written, 5 already there", out)
        self.assertEqual(catalog.read_text(self.path), before)

    def test_a_missing_placeholder_is_refused(self):
        self.refused("Open %@ in TextMouth", "Abrir en TextMouth", "missing placeholder")

    def test_a_placeholder_of_another_type_is_refused(self):
        self.refused("Open %@ in TextMouth", "Abrir %lld en TextMouth", "is a int64")

    def add_strings(self, **strings):
        """Adds strings (key to a comment) to the catalog, to be translated by the next batch."""
        cat = self.load()
        for key, comment in strings.items():
            cat.strings[key] = base.entry(comment, en=base.unit(key))
        cat.save()

    def test_a_percent_sign_after_a_space_is_plain_text(self):
        """Spanish and French put a space before the sign: "50 % de descuento" has no `% d`, and Foundation formats a text with
        no argument as it is."""
        self.add_strings(**{"50% off": "A badge", "Save 10% today": "A banner"})
        status, out = self.apply(self.translated(**{"50% off": "50 % de descuento", "Save 10% today": "Ahorra hoy 10 %"}))
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("50% off", "es"), {"": ("machine_translated", "50 % de descuento")})
        self.assertEqual(self.values("Save 10% today", "es"), {"": ("machine_translated", "Ahorra hoy 10 %")})

    def test_an_unsigned_conversion_is_refused_for_a_hex_one(self):
        self.add_strings(**{"Code %x": "A hex number"})
        self.refused("Code %x", "Código %u", "is a uint32, the English's is a uint32 hex")

    def test_an_exponent_float_is_refused_for_a_plain_one(self):
        self.add_strings(**{"Rate %f": "A number"})
        self.refused("Rate %f", "Tasa %e", "is a double exponent, the English's is a double")

    def test_a_short_integer_is_refused_for_an_int(self):
        self.add_strings(**{"Item %d": "A number"})
        self.refused("Item %d", "Elemento %hd", "is a int16, the English's is a int32")

    def test_a_different_precision_is_written_with_a_warning(self):
        self.add_strings(**{"Wait %.1f seconds": "A duration"})
        status, out = self.apply(self.translated(**{"Wait %.1f seconds": "Espera %.3f segundos"}))
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Wait %.1f seconds", "es"), {"": ("machine_translated", "Espera %.3f segundos")})
        self.assertIn("warning \"Wait %.1f seconds\": translation: placeholder 1 prints 3 digits where the English's prints 1", out)

    def test_a_missing_plural_form_is_refused(self):
        self.refused("%lld books", {"one": "%lld libro", "other": "%lld libros"}, "needs the plural form many")

    def test_an_extra_plural_form_is_refused(self):
        self.refused("%lld books", {"one": "a %lld", "many": "b %lld", "other": "c %lld", "few": "d %lld"}, "does not use the plural form few")

    def test_plural_forms_are_checked_one_by_one(self):
        self.refused("%lld books", {"one": "%lld libro", "many": "de libros", "other": "%lld libros"},
                     "the many form: missing placeholder")

    def test_a_plain_text_for_plural_english_is_refused(self):
        self.refused("%lld books", "%lld libros", "must give one text for each")

    def test_an_empty_translation_is_refused(self):
        self.refused("Play", "  ", "empty text")

    def test_an_empty_plural_form_is_refused(self):
        self.refused("%lld books", {"one": "%lld libro", "many": "", "other": "%lld libros"}, "the many form: empty text")

    def test_the_english_left_as_it_was_is_refused(self):
        self.refused("Play", "Play", "the English left as it was")

    def test_the_english_left_on_purpose_is_written(self):
        path = self.translated(Play="Play")
        batch = self.read_batch(path)
        next(item for item in batch["items"] if item["key"] == "Play")["keepEnglish"] = True
        self.write_batch(path, batch)
        status, out = self.apply(path)
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Play")})

    def test_a_text_with_nothing_to_translate_may_stay(self):
        cat = self.load()
        cat.strings["TextMouth"] = base.entry("The name", en=base.unit("TextMouth"))
        cat.strings["%lld"] = base.entry("A bare number", en=base.unit("%lld"))
        cat.save()
        path = self.folder / "names.json"
        self.write_batch(path, {"language": "es", "items": [{"key": "TextMouth", "translation": "TextMouth"},
                                                            {"key": "%lld", "translation": "%lld"}]})
        status, out = self.apply(path)
        self.assertEqual(status, 0, out)

    def test_a_name_that_is_never_translated_must_be_kept(self):
        self.refused("Open %@ in TextMouth", "Abrir %@ en TextoBoca", "lost the name TextMouth")

    def test_a_translation_much_longer_than_the_english_is_a_warning_only(self):
        long_text = "Añade %@ ahora mismo a tu biblioteca personal de libros y de audiolibros favoritos"
        status, out = self.apply(self.translated(**{"Add %@ to your Library": long_text}))
        self.assertEqual(status, 0, out)
        self.assertRegex(out, r'warning "Add %@ to your Library": translation: \d\.\d times as long as the English')
        self.assertEqual(self.values("Add %@ to your Library", "es"), {"": ("machine_translated", long_text)})

    def test_a_short_english_word_is_not_warned_about_however_long_its_translation_is(self):
        """"OK" to "Aceptar" is three times as long, and it is right."""
        status, out = self.apply(self.translated(Play="Reproducir ahora mismo todo el libro"))
        self.assertEqual(status, 0, out)
        self.assertIn("0 warnings", out)

    def test_the_refused_go_to_a_file_for_a_second_try_and_a_clean_run_empties_it(self):
        path = self.translated(Play="")
        status, _ = self.apply(path)
        self.assertEqual(status, 1)
        rejected = Path(str(path) + ".rejected.json")
        retry = self.read_batch(rejected)
        self.assertEqual([item["key"] for item in retry["items"]], ["Play"])
        self.assertEqual(retry["language"], "es")
        self.assertEqual(retry["items"][0]["problems"], ["translation: empty text"])
        # The second try: fill the refused item and apply the rejected file; the catalog gets it.
        retry["items"][0]["translation"] = "Reproducir"
        self.write_batch(rejected, retry)
        status, out = self.apply(rejected)
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Reproducir")})
        # A clean run of the first file overwrites its rejected file with none, so it never holds an old refusal.
        self.write_batch(path, {**self.read_batch(path), "items": []})
        self.assertEqual(self.apply(path)[0], 0)
        self.assertEqual(self.read_batch(rejected)["items"], [])

    def test_a_string_the_catalog_has_not_a_stale_one_and_a_changed_english_are_refused(self):
        path = self.translated()
        batch = self.read_batch(path)
        batch["items"] += [{"key": "No such string", "translation": "x"}, {"key": "Add %@ to the Library", "translation": "x %@"}]
        next(item for item in batch["items"] if item["key"] == "Play")["english"] = "Play it"
        self.write_batch(path, batch)
        status, out = self.apply(path)
        self.assertEqual(status, 1)
        self.assertIn("has no string 'No such string'", out)
        self.assertIn("stale or not to be translated", out)
        self.assertIn("the English changed since the batch was made", out)

    def test_an_item_that_is_not_an_object_or_has_no_translation_is_refused(self):
        path = self.folder / "odd.json"
        self.write_batch(path, {"language": "es", "items": ["Play", {"key": "Play"}]})
        status, out = self.apply(path)
        self.assertEqual(status, 1)
        self.assertIn("must be an object", Path(str(path) + ".rejected.json").read_text(encoding="utf-8"))
        self.assertIn("no translation", out)

    def test_a_machine_translation_does_not_replace_a_persons(self):
        cat = self.load()
        cat.strings["Done"]["localizations"]["es"] = base.unit("Hecho", "translated")
        cat.save()
        path = self.folder / "done.json"
        self.write_batch(path, {"language": "es", "items": [{"key": "Done", "translation": "Terminado"}]})
        status, out = self.apply(path)
        self.assertEqual(status, 1)
        self.assertIn("already translated by a person", out)
        status, out = self.apply(path, "--state", "translated")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Done", "es"), {"": ("translated", "Terminado")})

    def test_the_same_text_is_not_downgraded_from_translated(self):
        cat = self.load()
        cat.strings["Done"]["localizations"]["es"] = base.unit("Hecho", "translated")
        cat.save()
        path = self.folder / "done.json"
        self.write_batch(path, {"language": "es", "items": [{"key": "Done", "translation": "Hecho"}]})
        status, out = self.apply(path)
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("Done", "es"), {"": ("translated", "Hecho")})

    def test_a_batch_that_is_not_usable_is_refused_whole(self):
        path = self.folder / "bad.json"
        self.write_batch(path, {"items": []})
        self.assertEqual(self.apply(path)[0], 2)
        path.write_text("not json", encoding="utf-8")
        self.assertEqual(self.apply(path)[0], 2)
        self.assertEqual(self.apply(self.folder / "absent.json")[0], 2)

    def test_the_file_stays_in_the_tools_layout(self):
        self.apply(self.translated())
        text = catalog.read_text(self.path)
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))


class ApplyLanguageTests(ApplyCase):
    """`apply` checks the batch's language: text, never the source language, one the tools know, and `--lang` when given."""

    def batch_in(self, language):
        """A batch file for `language` with one good-looking item for Play."""
        path = self.folder / "language.json"
        self.write_batch(path, {"language": language, "items": [{"key": "Play", "translation": "Lanzar"}]})
        return path

    def refused_whole(self, language, words):
        """Applies a batch for `language`: exit 2, `words` in the message, and the catalog is not changed."""
        before = catalog.read_text(self.path)
        status, _, err = shared.run("apply", str(self.batch_in(language)), "--catalog", str(self.path), "--glossary", str(self.glossary))
        self.assertEqual(status, 2, err)
        self.assertIn(words, err)
        self.assertEqual(catalog.read_text(self.path), before)

    def test_the_source_language_is_refused_and_no_english_is_overwritten(self):
        self.refused_whole("en", "source language")
        self.refused_whole("EN", "source language")

    def test_a_language_the_tools_do_not_know_is_refused_not_written_as_a_new_language(self):
        self.refused_whole("sp", "not one the tools know")

    def test_a_language_that_is_not_text_is_refused_not_a_traceback(self):
        for language in (["es"], None, "", 7, {"es": 1}):
            with self.subTest(language=language):
                self.refused_whole(language, "needs a \"language\" that is text")

    def test_lang_must_match_the_batch(self):
        path = self.batch_in("es")
        before = catalog.read_text(self.path)
        status, _, err = shared.run("apply", str(path), "--lang", "fr", "--catalog", str(self.path), "--glossary", str(self.glossary))
        self.assertEqual(status, 2, err)
        self.assertIn("--lang says 'fr'", err)
        self.assertEqual(catalog.read_text(self.path), before)
        status, out, err = shared.run("apply", str(path), "--lang", "es", "--catalog", str(self.path), "--glossary", str(self.glossary))
        self.assertEqual(status, 0, err)
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Lanzar")})

    def test_a_region_of_a_known_language_is_a_language(self):
        status, _, err = shared.run("apply", str(self.batch_in("es-419")), "--catalog", str(self.path), "--glossary", str(self.glossary))
        self.assertEqual(status, 0, err)
        self.assertEqual(self.values("Play", "es-419"), {"": ("machine_translated", "Lanzar")})


class ApplyTextChecksTests(ApplyCase):
    """What `apply` refuses in a text itself: edges, `%%`, control characters, plural forms with no meaning, a `one` form
    without its number, and a machine write over a reviewed form (review findings 4, 5, and 6)."""

    def add(self, **strings):
        """Adds strings (key to entry) to the fixtures' catalog."""
        cat = self.load()
        cat.strings.update(base.with_english(strings))
        cat.save()

    def try_item(self, key, translation, language="es", state=None, **extra):
        """Applies a batch of one item; returns (status, standard output)."""
        path = self.folder / "one.json"
        self.write_batch(path, {"language": language, "items": [{"key": key, "translation": translation, **extra}]})
        return self.apply(path, *(("--state", state) if state else ()))

    def assert_refused(self, key, translation, reason, language="es"):
        """The item is refused with `reason` and nothing is written."""
        before = catalog.read_text(self.path)
        status, out = self.try_item(key, translation, language)
        self.assertEqual(status, 1, out)
        self.assertRegex(out, "refused .*" + re.escape(reason))
        self.assertEqual(catalog.read_text(self.path), before)

    def assert_written(self, key, translation, language="es"):
        """The item is written."""
        status, out = self.try_item(key, translation, language)
        self.assertEqual(status, 0, out)
        self.assertEqual(self.load().status(key, language), "machine_translated")

    # ---- whitespace at the edges ----

    def test_whitespace_at_the_edges_must_be_the_englishs(self):
        self.add(**{"Page ": base.entry("A label before a number"), " of %lld": base.entry("After a number"),
                    "Open %@\n": base.entry("A line"), "Plain": base.entry("No edges")})
        self.assert_refused("Page ", "Página", "trailing whitespace is '' where the English has ' '")
        self.assert_refused(" of %lld", "de %lld", "leading whitespace is '' where the English has ' '")
        self.assert_refused("Open %@\n", "Abrir %@", "trailing whitespace is '' where the English has '\\n'")
        self.assert_refused("Plain", " Simple ", "leading whitespace is ' ' where the English has ''")
        self.assert_written("Page ", "Página ")
        self.assert_written(" of %lld", " de %lld")
        self.assert_written("Open %@\n", "Abrir %@\n")

    def test_whitespace_at_the_edges_is_checked_form_by_form(self):
        self.add(**{"%lld books ": base.entry("A count", en=base.plural(one=base.unit("%lld book "), other=base.unit("%lld books ")))})
        self.assert_refused("%lld books ", {"one": "%lld libro ", "many": "%lld de libros", "other": "%lld libros "},
                            "the many form: trailing whitespace")

    def test_a_lost_line_break_inside_a_text_is_a_warning(self):
        self.add(**{"Line one\nLine two": base.entry("Two lines")})
        status, out = self.try_item("Line one\nLine two", "Línea uno y línea dos")
        self.assertEqual(status, 0, out)
        self.assertIn("0 line breaks where the English has 1", out)

    # ---- percent signs ----

    def test_literal_percent_signs_must_agree_and_a_lone_percent_is_refused(self):
        self.add(**{"Rate: %lld%%": base.entry("A speed in percent")})
        self.assert_refused("Rate: %lld%%", "Tasa: %lld", "0 literal percent signs (%%) where the English has 1")
        self.assert_refused("Rate: %lld%%", "Tasa: %lld %", "a lone %")
        self.assert_written("Rate: %lld%%", "Tasa: %lld%%")

    # ---- control characters ----

    def test_control_characters_other_than_a_line_break_and_a_tab_are_refused(self):
        self.add(**{"Open %@ now": base.entry("A menu item"), "Two\nlines\there": base.entry("Layout")})
        for character, name in (("\x00", "U+0000"), ("\x07", "U+0007"), ("\x1b", "U+001B"), ("\r", "U+000D")):
            self.assert_refused("Open %@ now", f"Abrir{character} %@ ahora", f"control character {name}")
        self.assert_written("Two\nlines\there", "Dos\nlíneas\taquí")

    # ---- plural forms that make no sense ----

    def test_a_plural_object_for_english_with_no_plural_forms_is_refused(self):
        self.assert_refused("Open %@ in TextMouth", {"one": "Abrir %@ en TextMouth", "many": "Abrir %@ en TextMouth",
                                                     "other": "Abrir %@ en TextMouth"}, "the English has no plural forms")

    def test_plural_forms_for_a_key_with_no_number_are_refused_in_apply(self):
        self.add(**{"Open %@": base.entry("A menu item", en=base.plural(one=base.unit("Open %@"), other=base.unit("Open %@")))})
        self.assert_refused("Open %@", {"one": "Abrir %@", "many": "Abrir %@", "other": "Abrir %@"}, "needs a number placeholder")

    # ---- a `one` form without its number ----

    def test_one_may_say_one_in_words_in_spanish_and_must_show_the_number_in_french(self):
        spanish = {"one": "Un libro", "many": "%lld de libros", "other": "%lld libros"}
        french = {"one": "Un livre", "many": "%lld de livres", "other": "%lld livres"}
        self.assert_written("%lld books", spanish)
        self.assert_refused("%lld books", french, "the one form: missing placeholder number 1", language="fr")
        self.assert_written("%lld books", {**french, "one": "%lld livre"}, language="fr")

    # ---- a machine write over a reviewed form ----

    def reviewed_plural(self):
        """%lld books in Spanish with a reviewed `one` and machine `many` and `other`."""
        cat = self.load()
        forms = {"one": base.unit("%lld libro", "translated"), "many": base.unit("%lld de libros", "machine_translated"),
                 "other": base.unit("%lld libros", "machine_translated")}
        cat.strings["%lld books"]["localizations"]["es"] = base.plural(**forms)
        cat.save()

    def test_a_machine_write_keeps_a_reviewed_plural_form_and_updates_the_others(self):
        self.reviewed_plural()
        status, out = self.try_item("%lld books", {"one": "%lld ejemplar", "many": "%lld de libros nuevos", "other": "%lld libros nuevos"})
        self.assertEqual(status, 0, out)
        forms = self.values("%lld books", "es")
        self.assertEqual(forms["plural.one"], ("translated", "%lld libro"), "the reviewed form is as the person wrote it")
        self.assertEqual(forms["plural.many"], ("machine_translated", "%lld de libros nuevos"))
        self.assertEqual(forms["plural.other"], ("machine_translated", "%lld libros nuevos"))
        self.assertRegex(out, r'warning "%lld books": kept the one form a person marked translated')

    def test_a_machine_write_that_could_change_only_reviewed_forms_is_refused(self):
        self.reviewed_plural()
        cat = self.load()
        for category in ("many", "other"):
            cat.strings["%lld books"]["localizations"]["es"]["variations"]["plural"][category]["stringUnit"]["state"] = "translated"
        cat.save()
        status, out = self.try_item("%lld books", {"one": "%lld ejemplar", "many": "%lld de libros x", "other": "%lld libros x"})
        self.assertEqual(status, 1, out)
        self.assertIn("already translated by a person", out)
        self.assertEqual(self.values("%lld books", "es")["plural.one"], ("translated", "%lld libro"))

    def test_a_person_can_replace_a_reviewed_form_on_purpose(self):
        self.reviewed_plural()
        status, out = self.try_item("%lld books", {"one": "%lld ejemplar", "many": "%lld de libros", "other": "%lld libros"},
                                    state="translated")
        self.assertEqual(status, 0, out)
        self.assertEqual(self.values("%lld books", "es")["plural.one"], ("translated", "%lld ejemplar"))


class RefusalLoopTests(ApplyCase):
    """The loop the guide's translator follows: apply the batch, fix what is refused in the `.rejected.json` file, apply that
    file, until nothing is refused; and the original batch never overwrites the translator's fixes."""

    # Two translations that are refused (the first is empty, the second drops the placeholder), the rest are good.
    BAD = {"Play": "", "Open %@ in TextMouth": "Abrir en TextMouth"}

    def stamp(self, path, seconds):
        """Sets the modification time of `path` to `seconds` after a fixed start (a clock the test controls)."""
        os.utime(path, (1_700_000_000 + seconds, 1_700_000_000 + seconds))

    def rejected_of(self, path):
        """The rejected file of the batch `path`, and its items by key."""
        rejected = Path(str(path) + ".rejected.json")
        return rejected, {item["key"]: item for item in self.read_batch(rejected)["items"]}

    def fix(self, rejected, **fixes):
        """Fills in translations (key to text) in the rejected file, as a translator does."""
        batch = self.read_batch(rejected)
        for item in batch["items"]:
            if item["key"] in fixes:
                item["translation"] = fixes[item["key"]]
        self.write_batch(rejected, batch)

    def test_the_loop_ends_with_every_string_written_and_never_makes_a_second_rejected_file(self):
        path = self.translated(**self.BAD)
        status, out = self.apply(path)
        self.assertEqual(status, 1, out)
        rejected, items = self.rejected_of(path)
        self.assertEqual(sorted(items), ["Open %@ in TextMouth", "Play"])
        # The translator fixes one and gets the other wrong again.
        self.fix(rejected, Play="Reproducir", **{"Open %@ in TextMouth": "Abrir"})
        status, out = self.apply(rejected)
        self.assertEqual(status, 1, out)
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Reproducir")})
        self.assertEqual(self.values("Open %@ in TextMouth", "es"), {}, "the refused one is not written")
        # The same file now holds only what is still refused; no file named .rejected.json.rejected.json exists.
        self.assertEqual([item["key"] for item in self.read_batch(rejected)["items"]], ["Open %@ in TextMouth"])
        self.assertEqual(sorted(p.name for p in self.folder.glob("*.rejected*")), [rejected.name])
        # The last fix: everything goes through and the rejected file is left with no items.
        self.fix(rejected, **{"Open %@ in TextMouth": "Abrir %@ en TextMouth"})
        status, out = self.apply(rejected)
        self.assertEqual(status, 0, out)
        self.assertEqual(self.read_batch(rejected)["items"], [])
        self.assertEqual(self.values("Open %@ in TextMouth", "es"), {"": ("machine_translated", "Abrir %@ en TextMouth")})
        self.assertEqual(sorted(p.name for p in self.folder.glob("*.rejected*")), [rejected.name])

    def test_applying_the_original_batch_again_does_not_overwrite_a_rejected_file_the_translator_fixed(self):
        path = self.translated(**self.BAD)
        self.stamp(path, 0)
        self.apply(path)
        rejected, _ = self.rejected_of(path)
        self.fix(rejected, Play="Reproducir", **{"Open %@ in TextMouth": "Abrir %@ en TextMouth"})
        self.stamp(rejected, 100)
        fixed = rejected.read_text(encoding="utf-8")
        status, out = self.apply(path)
        self.assertEqual(status, 1, "the original batch still has its two bad items")
        self.assertEqual(rejected.read_text(encoding="utf-8"), fixed, "the fixes are still there, byte for byte")
        self.assertIn("is newer than", out)
        self.assertIn("apply that file", out)

    def test_an_edited_original_batch_newer_than_its_rejected_file_rewrites_it(self):
        path = self.translated(**self.BAD)
        self.stamp(path, 0)
        self.apply(path)
        rejected, _ = self.rejected_of(path)
        self.stamp(rejected, 50)
        # The batch is fixed and saved again afterwards: it is newer, and a clean run empties the rejected file.
        self.write_batch(path, {**self.read_batch(path), "items": []})
        self.stamp(path, 100)
        self.assertEqual(self.apply(path)[0], 0)
        self.assertEqual(self.read_batch(rejected)["items"], [])

    def test_a_rejected_file_applied_with_nothing_left_refused_stays_with_no_items_and_applies_cleanly_again(self):
        path = self.translated(Play="")
        self.apply(path)
        rejected, _ = self.rejected_of(path)
        self.fix(rejected, Play="Reproducir")
        self.assertEqual(self.apply(rejected)[0], 0)
        self.assertEqual(self.apply(rejected)[0], 0, "an empty rejected file is a clean no-op")
        self.assertEqual(self.read_batch(rejected)["items"], [])


if __name__ == "__main__":
    unittest.main()
