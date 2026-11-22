"""Tests of Scripts/l10n/translate.py and the commands of l10n.py that use it: plural (and, below it, todo and apply).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works in a temporary folder on a catalog it makes, and builds nothing.
"""
import contextlib
import io
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402
import test_l10n as base  # noqa: E402  (its helpers: TemporaryCase, entry, unit, plural)


def run(*argv):
    """Runs the l10n command line `argv`; returns (exit status, standard output, standard error)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = l10n.main(list(argv))
    return status, out.getvalue(), err.getvalue()


class CatalogCase(base.TemporaryCase):
    """A temporary catalog the commands are run on with --catalog."""

    def make(self, strings):
        """Writes `strings` as the catalog and returns its path."""
        self.path = self.write_catalog(strings)
        return self.path

    def load(self):
        """The catalog as it is on disk now."""
        return catalog.Catalog.load(self.path)

    def values(self, key, language):
        """{unit path: (state, value)} of `key` in `language`, as it is on disk now."""
        return {unit.path: (unit.state, unit.value) for unit in self.load().units(key, language)}


class PluralTests(CatalogCase):
    """`plural`: a key's plural forms in one language."""

    def setUp(self):
        super().setUp()
        self.make({"%lld books": base.entry("A count of books"), "Play": base.entry("The play button")})

    def test_english_forms_are_written_translated_and_read_back(self):
        status, out, _ = run("plural", "%lld books", "--lang", "en", "--one", "%lld book", "--other", "%lld books",
                             "--catalog", str(self.path))
        self.assertEqual(status, 0)
        self.assertIn("translated", out)
        self.assertEqual(self.values("%lld books", "en"), {"plural.one": ("translated", "%lld book"),
                                                           "plural.other": ("translated", "%lld books")})
        self.assertEqual(self.load().english_forms("%lld books"), ["%lld book", "%lld books"])

    def test_spanish_forms_are_machine_translated_by_default(self):
        status, _, _ = run("plural", "%lld books", "--lang", "es", "--one", "%lld libro", "--many", "%lld de libros",
                           "--other", "%lld libros", "--catalog", str(self.path))
        self.assertEqual(status, 0)
        self.assertEqual(self.values("%lld books", "es"), {"plural.many": ("machine_translated", "%lld de libros"),
                                                           "plural.one": ("machine_translated", "%lld libro"),
                                                           "plural.other": ("machine_translated", "%lld libros")})
        self.assertEqual(self.load().status("%lld books", "es"), "machine_translated")

    def test_a_state_can_be_given(self):
        run("plural", "%lld books", "--lang", "es", "--one", "%lld libro", "--many", "%lld de libros", "--other", "%lld libros",
            "--state", "translated", "--catalog", str(self.path))
        self.assertEqual(self.load().status("%lld books", "es"), "translated")

    def test_the_file_stays_in_the_tools_layout(self):
        run("plural", "%lld books", "--lang", "en", "--one", "%lld book", "--other", "%lld books", "--catalog", str(self.path))
        text = catalog.read_text(self.path)
        self.assertEqual(text, catalog.dumps(catalog.loads(text)))

    def test_writing_again_replaces_the_forms(self):
        for one in ("%lld libro", "%lld un libro"):
            run("plural", "%lld books", "--lang", "es", "--one", one, "--many", "%lld de libros", "--other", "%lld libros",
                "--catalog", str(self.path))
        self.assertEqual(self.values("%lld books", "es")["plural.one"], ("machine_translated", "%lld un libro"))

    def assertRefused(self, *argv, reason):
        """The command is refused, with `reason` in what it says, and the catalog is left as it was."""
        before = catalog.read_text(self.path)
        status, _, err = run("plural", *argv, "--catalog", str(self.path))
        self.assertEqual(status, 1, err)
        self.assertIn(reason, err)
        self.assertEqual(catalog.read_text(self.path), before, "a refused command writes nothing")

    def test_a_form_the_language_does_not_use_is_refused(self):
        # English has no `many`, nor `few`.
        self.assertRefused("%lld books", "--lang", "en", "--one", "%lld book", "--many", "%lld books", "--other", "%lld books",
                           reason="does not use the plural form many")

    def test_a_missing_form_is_refused(self):
        # Spanish needs `many` too.
        self.assertRefused("%lld books", "--lang", "es", "--one", "%lld libro", "--other", "%lld libros",
                           reason="needs the plural form many")

    def test_an_empty_form_is_refused(self):
        self.assertRefused("%lld books", "--lang", "en", "--one", " ", "--other", "%lld books", reason="the one form: empty text")

    def test_a_plural_form_with_another_conversion_class_is_refused(self):
        self.assertRefused("%lld books", "--lang", "en", "--one", "%llx book", "--other", "%lld books",
                           reason="the one form: placeholder 1 is a uint64 hex, the English's is a int64")

    def test_a_plural_form_with_a_lone_percent_is_refused_as_before(self):
        # A plural key has a placeholder, so it is a format string, where a lone % must be written %%.
        self.assertRefused("%lld books", "--lang", "en", "--one", "%lld book, 5 % off", "--other", "%lld books, 5 % off",
                           reason="a lone %")

    def test_placeholders_that_differ_from_the_key_are_refused(self):
        self.assertRefused("%lld books", "--lang", "en", "--one", "%@ book", "--other", "%lld books",
                           reason="the one form: ")
        # Only a `one` form may drop the number (see the tests of the one rule below); `other` may not.
        self.assertRefused("%lld books", "--lang", "en", "--one", "%lld book", "--other", "many books",
                           reason="the other form: missing placeholder number 1")

    def test_a_key_with_no_number_placeholder_cannot_have_plural_forms(self):
        """A plural variation varies on a number: `Open %@` has none, in English or any other language."""
        for language, forms in (("en", ("--one", "Open %@", "--other", "Open %@")), ("es", ("--one", "Abrir %@", "--many", "Abrir %@",
                                                                                                "--other", "Abrir %@"))):
            cat = self.load()
            cat.strings["Open %@"] = base.entry("A menu item")
            cat.save()
            self.assertRefused("Open %@", "--lang", language, *forms, reason="needs a number placeholder")

    def test_a_float_placeholder_is_a_number_to_vary_on(self):
        cat = self.load()
        cat.strings["%.1f hours"] = base.entry("A length of time", en=base.unit("%.1f hours"))
        cat.save()
        status, _, err = run("plural", "%.1f hours", "--lang", "en", "--one", "%.1f hour", "--other", "%.1f hours", "--catalog", str(self.path))
        self.assertEqual(status, 0, err)

    def test_one_may_leave_out_the_number_where_one_means_exactly_1(self):
        for language, forms in (("en", ("--one", "One book", "--other", "%lld books")),
                                ("es", ("--one", "Un libro", "--many", "%lld de libros", "--other", "%lld libros"))):
            status, _, err = run("plural", "%lld books", "--lang", language, *forms, "--catalog", str(self.path))
            self.assertEqual(status, 0, f"{language}: {err}")

    def test_one_must_show_the_number_where_one_covers_more_than_1(self):
        # French's `one` covers 0 and Russian's 21: "Un livre" would be said of 0 books, "Одна книга" of 21.
        self.assertRefused("%lld books", "--lang", "fr", "--one", "Un livre", "--many", "%lld de livres", "--other", "%lld livres",
                           reason="the one form: missing placeholder number 1")
        self.assertRefused("%lld books", "--lang", "ru", "--one", "Одна книга", "--few", "%lld книги", "--many", "%lld книг",
                           "--other", "%lld книги", reason="the one form: missing placeholder number 1")
        status, _, err = run("plural", "%lld books", "--lang", "fr", "--one", "%lld livre", "--many", "%lld de livres", "--other",
                             "%lld livres", "--catalog", str(self.path))
        self.assertEqual(status, 0, err)

    def test_a_form_other_than_one_may_not_drop_the_number_and_a_one_may_not_drop_another_placeholder(self):
        self.assertRefused("%lld books", "--lang", "es", "--one", "Un libro", "--many", "de libros", "--other", "%lld libros",
                           reason="the many form: missing placeholder number 1")
        cat = self.load()
        cat.strings["%lld books in %@"] = base.entry("A count and a shelf", en=base.unit("%lld books in %@"))
        cat.save()
        self.assertRefused("%lld books in %@", "--lang", "es", "--one", "Un libro", "--many", "%lld de libros en %@",
                           "--other", "%lld libros en %@", reason="the one form: missing placeholder number 2 (object)")

    def test_a_key_not_in_the_catalog_is_refused(self):
        self.assertRefused("%lld pages", "--lang", "en", "--one", "%lld page", "--other", "%lld pages", reason="has no string")

    def test_a_language_without_a_recorded_rule_is_refused(self):
        self.assertRefused("%lld books", "--lang", "xx", "--other", "%lld books", reason="no plural rule is recorded")

    def test_a_state_that_cannot_be_written_is_refused(self):
        self.assertRefused("%lld books", "--lang", "en", "--one", "%lld book", "--other", "%lld books", "--state", "stale",
                           reason="cannot be written")

    def test_other_forms_in_the_localization_are_not_replaced(self):
        cat = self.load()
        cat.strings["Play"]["localizations"] = {"es": {"variations": {"device": {"mac": base.unit("Reproducir")}}}}
        cat.save()
        self.assertRefused("Play", "--lang", "es", "--one", "Reproducir", "--many", "Reproducir", "--other", "Reproducir",
                           reason="device variations")

    def test_a_language_with_only_other_takes_only_other(self):
        run("plural", "%lld books", "--lang", "ja", "--other", "%lld 冊", "--catalog", str(self.path))
        self.assertEqual(self.values("%lld books", "ja"), {"plural.other": ("machine_translated", "%lld 冊")})


if __name__ == "__main__":
    unittest.main()
