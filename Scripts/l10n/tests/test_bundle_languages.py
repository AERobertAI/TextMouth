"""Tests of the bundle's languages (FR39 phase 8): the Mac's Info.plist lists the catalog's languages in CFBundleLocalizations.

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

With no Apple language table in either app, CFBundleLocalizations (and the *.lproj folders) are what offer each language to
the system. `l10n.py check` therefore fails when the Mac's list differs from the catalog's languages, so a language added to
the catalog alone cannot ship unnoticed. Every test works on files it writes in a temporary folder, except the last, which
reads the repository's own plist and catalog.
"""
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(HERE))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402
import test_l10n as base  # noqa: E402  (its helpers: entry, unit, make_catalog)

REPOSITORY = HERE.parents[2]


def fixture_catalog(*languages):
    """A catalog whose one string is translated into `languages` (and English)."""
    return base.make_catalog({"common.cancel": base.entry(en=base.unit("Cancel"),
                                                          **{language: base.unit("x") for language in languages})})


class BundleLanguageTests(unittest.TestCase):
    """`bundle_languages` and `bundle_language_problems`."""

    def setUp(self):
        """A temporary folder for the plists."""
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def plist(self, languages):
        """Writes an Info.plist listing `languages` (None: no key at all); returns its path."""
        path = self.folder / "Info.plist"
        path.write_bytes(plistlib.dumps({} if languages is None else {"CFBundleLocalizations": languages}))
        return path

    def test_english_comes_first_and_the_rest_follow_in_code_point_order(self):
        cat = fixture_catalog("zh-Hans", "pt-BR", "ar", "de")
        self.assertEqual(l10n.bundle_languages(cat), ["en", "ar", "de", "pt-BR", "zh-Hans"])

    def test_a_list_that_matches_the_catalog_is_no_problem(self):
        cat = fixture_catalog("es", "fr")
        self.assertEqual(l10n.bundle_language_problems(cat, self.plist(["en", "es", "fr"])), [])

    def test_a_language_added_to_the_catalog_alone_is_a_problem(self):
        cat = fixture_catalog("es", "fr", "ur")
        problems = l10n.bundle_language_problems(cat, self.plist(["en", "es", "fr"]))
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("CFBundleLocalizations", problems[0])
        self.assertIn("'ur'", problems[0])

    def test_a_language_the_catalog_lacks_is_a_problem(self):
        self.assertEqual(len(l10n.bundle_language_problems(fixture_catalog("es"), self.plist(["en", "es", "fr"]))), 1)

    def test_a_list_out_of_order_or_without_english_first_is_a_problem(self):
        cat = fixture_catalog("es", "fr")
        self.assertEqual(len(l10n.bundle_language_problems(cat, self.plist(["en", "fr", "es"]))), 1)
        self.assertEqual(len(l10n.bundle_language_problems(cat, self.plist(["es", "en", "fr"]))), 1)

    def test_a_plist_with_no_list_or_no_file_is_a_problem(self):
        cat = fixture_catalog("es")
        self.assertEqual(len(l10n.bundle_language_problems(cat, self.plist(None))), 1)
        self.assertEqual(len(l10n.bundle_language_problems(cat, self.folder / "missing.plist")), 1)

    def test_check_fails_for_the_repositorys_own_plist_when_it_differs_from_its_catalog(self):
        """`check` reads the Mac's Info.plist under the code root, so the repository's two files are held to each other."""
        cat = catalog.Catalog.load(REPOSITORY / "TextMouth" / "Localization" / "Localizable.xcstrings")
        problems = l10n.bundle_language_problems(cat, REPOSITORY / l10n.MAC_INFO_PLIST)
        self.assertEqual(problems, [])
        # The same plist against a catalog with one language fewer: the problem a half-finished language change would show.
        strings = {key: {**value, "localizations": {name: node for name, node in value.get("localizations", {}).items()
                                                    if name != "zh-Hant"}} for key, value in cat.strings.items()}
        shorter = catalog.Catalog({**cat.data, "strings": strings})
        self.assertEqual(len(l10n.bundle_language_problems(shorter, REPOSITORY / l10n.MAC_INFO_PLIST)), 1)

    def test_the_iphones_plist_lists_the_same_languages_as_the_macs(self):
        """`sync-info-plist.py` carries the key to the iPhone's plist, so both name the same list."""
        mac = plistlib.loads((REPOSITORY / l10n.MAC_INFO_PLIST).read_bytes())
        phone = plistlib.loads((REPOSITORY / "TextMouth" / "Platform" / "iOS" / "Info.plist").read_bytes())
        self.assertEqual(phone["CFBundleLocalizations"], mac["CFBundleLocalizations"])
        self.assertEqual(len(mac["CFBundleLocalizations"]), 25)


if __name__ == "__main__":
    unittest.main()
