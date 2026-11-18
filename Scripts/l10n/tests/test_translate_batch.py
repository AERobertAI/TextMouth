"""Tests of `todo` and `apply` (Scripts/l10n/translate.py through Scripts/l10n/l10n.py): the batch of strings to translate
and the translated batch checked and written back.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works in a temporary folder: a catalog with strings in every state, a glossary, a made-up source tree, and a
locations table. Nothing is built, and the repository's own catalog and glossary are never read.
"""
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
import l10n  # noqa: E402
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
SOURCE = {
    PLAY_VIEW: "\n".join(f"line {number}" for number in range(1, 21)),
    OTHER_VIEW: "alpha\nbeta\ngamma\n",
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
        self.assertEqual(first["code"], "line 8\nline 9\nline 10\nline 11\nline 12")
        self.assertEqual(item["context"][1]["file"], OTHER_VIEW, "a different file is preferred to a second line of the first")
        self.assertEqual(item["context"][1]["code"], "alpha\nbeta\ngamma")

    def test_a_use_near_the_top_of_a_file_has_fewer_lines_before(self):
        item = self.items()["Add %@ to your Library"]
        self.assertEqual(item["context"][0]["code"], "line 1\nline 2\nline 3")

    def test_a_file_that_cannot_be_read_or_lies_outside_the_tree_gives_its_place_without_code(self):
        item = self.items()["Open %@ in TextMouth"]
        self.assertEqual(item["context"], [{"file": "TextMouth/Views/Missing.swift", "line": 3}, {"file": "../escape.swift", "line": 1}])

    def test_glossary_terms_found_in_the_english_come_with_their_translations(self):
        self.assertEqual(self.items()["Add %@ to your Library"]["glossary"], [{"term": "Library", "translation": "Biblioteca"}])
        self.assertEqual(self.items()["Reviewed"]["glossary"], [])

    def test_a_term_is_found_in_any_case_and_as_a_plural_and_carries_its_note_and_check(self):
        cat = self.load()
        cat.strings["Your bookmarks"] = base.entry("A heading")
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

    def test_an_empty_key_is_skipped(self):
        cat = self.load()
        cat.strings[""] = base.entry("An empty label")
        cat.save()
        _, batch, _ = self.todo()
        self.assertNotIn("", [item["key"] for item in batch["items"]])
        self.assertIn({"key": "", "reason": "the text is empty"}, batch["skipped"])

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

    def test_a_missing_plural_form_is_refused(self):
        self.refused("%lld books", {"one": "%lld libro", "other": "%lld libros"}, "needs the plural form many")

    def test_an_extra_plural_form_is_refused(self):
        self.refused("%lld books", {"one": "a %lld", "many": "b %lld", "other": "c %lld", "few": "d %lld"}, "does not use the plural form few")

    def test_plural_forms_are_checked_one_by_one(self):
        self.refused("%lld books", {"one": "un libro", "many": "%lld de libros", "other": "%lld libros"},
                     "the one form: missing placeholder")

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
        cat.strings["TextMouth"] = base.entry("The name")
        cat.strings["%lld"] = base.entry("A bare number")
        cat.save()
        path = self.folder / "names.json"
        self.write_batch(path, {"language": "es", "items": [{"key": "TextMouth", "translation": "TextMouth"},
                                                            {"key": "%lld", "translation": "%lld"}]})
        status, out = self.apply(path)
        self.assertEqual(status, 0, out)

    def test_a_name_that_is_never_translated_must_be_kept(self):
        self.refused("Open %@ in TextMouth", "Abrir %@ en TextoBoca", "lost the name TextMouth")

    def test_a_translation_much_longer_than_the_english_is_a_warning_only(self):
        status, out = self.apply(self.translated(Play="Reproducir ahora mismo todo el libro"))
        self.assertEqual(status, 0, out)
        self.assertRegex(out, r'warning "Play": translation: \d\.\d times as long as the English')
        self.assertEqual(self.values("Play", "es"), {"": ("machine_translated", "Reproducir ahora mismo todo el libro")})

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
