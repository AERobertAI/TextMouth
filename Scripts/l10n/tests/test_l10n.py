"""Tests of Scripts/l10n/l10n.py: status, size, and check (sync's are in test_sync.py).

Run with: python3 -I -B -m unittest discover -s Scripts/l10n/tests

Every test works in a temporary folder and never touches the repository's own catalog or build folders. One test also runs
the real `xcstringstool` when it is installed.
"""
import contextlib
import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import l10n  # noqa: E402

HAS_TOOL = bool(shutil.which("xcrun")) and subprocess.run(["xcrun", "--find", "xcstringstool"], capture_output=True).returncode == 0


def unit(value, state="translated"):
    """A stringUnit node."""
    return {"stringUnit": {"state": state, "value": value}}


def plural(**forms):
    """Plural variations: plural(one=unit("a"), other=unit("b")) is a localization."""
    return {"variations": {"plural": forms}}


def with_english(strings):
    """`strings` (key to entry) with an `en` unit added to each entry that has none, holding its key's text. A catalog keyed
    by ID holds its English in `en` (the tools never read it from a key), so a fixture that writes its English as its key,
    for brevity, is given the `en` the re-key would give it: plural forms (both the key) when a translation has plural forms,
    since check holds a plural translation to plural English, else one plain unit. An entry that has `en` is left as it is."""
    found = {}
    for key, value in strings.items():
        if isinstance(value, dict) and isinstance(value.get("localizations", {}), dict) and "en" not in value.get("localizations", {}):
            localizations = value.get("localizations", {})
            has_plural = any(isinstance(node, dict) and isinstance(node.get("variations"), dict) and "plural" in node["variations"]
                             for node in localizations.values())
            english = plural(one=unit(key), other=unit(key)) if has_plural else unit(key)
            value = {**value, "localizations": {**localizations, "en": english}}
        found[key] = value
    return found


def make_catalog(strings):
    """A Catalog holding `strings` (key to entry, see with_english), in English."""
    return catalog.Catalog({"sourceLanguage": "en", "version": "1.0", "strings": with_english(strings)})


def entry(comment="Context", **localizations):
    """A catalog entry with a comment and localizations by language."""
    return {"comment": comment, "localizations": localizations} if localizations else {"comment": comment}


# What `check` says of "Play" when it has no comment: it names the line that gives one.
NO_COMMENT_PLAY = '"Play": no comment for the translators (write a "// Translators: ..." line above its literal in the code, then sync)'


def args_for(command, catalog_file=None, **extra):
    """The parsed arguments of `command` as the command line would give them."""
    argv = [command]
    if catalog_file:
        argv += ["--catalog", str(catalog_file)]
    for name, value in extra.items():
        option = "--" + name.replace("_", "-")
        if value is True:
            argv.append(option)
        elif value is not False:
            argv += [option, str(value)]
    return l10n.build_parser().parse_args(argv)


class TemporaryCase(unittest.TestCase):
    """A temporary folder for each test."""

    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.folder = Path(folder.name)

    def write_catalog(self, strings, name="Localizable.xcstrings"):
        """Writes `strings` as a catalog file in the temporary folder and returns its path."""
        path = self.folder / name
        make_catalog(strings).save(path)
        return path


class HelpTests(unittest.TestCase):
    """`--help` of the tool and of each command prints and exits 0 (a `%O` in a help text once crashed it)."""

    def exits_with(self, argv):
        """The exit status of parsing `argv`, and what it printed."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(SystemExit) as raised:
            l10n.build_parser().parse_args(argv)
        return raised.exception.code, out.getvalue()

    def test_the_tools_help_exits_0_and_names_the_merge_drivers_arguments(self):
        status, text = self.exits_with(["--help"])
        self.assertEqual(status, 0)
        # The merge driver's placeholders are shown literally, as git writes them.
        self.assertIn("%O %A %B %P", text)

    def test_every_commands_help_exits_0(self):
        # Every command the parser has, so a command added later is covered without a change here.
        subparsers = next(action for action in l10n.build_parser()._actions if getattr(action, "choices", None))
        for command in subparsers.choices:
            with self.subTest(command=command):
                self.assertEqual(self.exits_with([command, "--help"])[0], 0)


class StatusTests(TemporaryCase):
    """`status`: the counts of each language."""

    def catalog_file(self):
        """A catalog with one string in each state in Spanish, a missing one, and a stale one with a translation."""
        return self.write_catalog({
            "done": entry(es=unit("hecho")),
            "machine": entry(es=unit("máquina", "machine_translated")),
            "fresh": entry(es=unit("nuevo", "new")),
            "review": entry(es=unit("revisar", "needs_review")),
            "empty": entry(es=unit("", "translated")),
            "absent": entry(),
            "plural": entry(es=plural(one=unit("uno"), other=unit("otros", "needs_review"))),
            "old": {"extractionState": "stale", "localizations": {"es": unit("viejo")}},
        })

    def test_each_status_is_counted_once_and_stale_strings_apart(self):
        counts = l10n.language_counts(catalog.Catalog.load(self.catalog_file()), "es")
        self.assertEqual(counts, {"translated": 1, "machine_translated": 1, "new": 2, "needs_review": 2, "stale": 1, "missing": 1})

    def test_the_command_prints_a_line_for_each_language_and_the_english_bytes(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), config=self.folder / "none.json"))
        lines = out.getvalue().splitlines()
        self.assertEqual(lines[0], "7 strings to translate, 1 stale. English text: 39 bytes of 150,000 (0%).")
        self.assertEqual(lines[1], "es: 1 translated, 1 machine translated, 2 new, 2 need review, 1 stale, 1 missing")

    def test_a_language_asked_for_that_the_catalog_lacks_is_all_missing(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), lang="fr", config=self.folder / "none.json"))
        self.assertIn("fr: 0 translated, 0 machine translated, 0 new, 0 need review, 0 stale, 7 missing", out.getvalue())

    def test_the_shipped_languages_are_listed_though_the_catalog_has_none_of_them(self):
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["fr"]}))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), config=config))
        self.assertIn("fr: 0 translated", out.getvalue())

    def test_json_output_has_the_same_numbers(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_status(args_for("status", self.catalog_file(), json=True, config=self.folder / "none.json"))
        self.assertEqual(json.loads(out.getvalue())["languages"]["es"]["missing"], 1)


class SizeTests(TemporaryCase):
    """`size`: the budget and the pack's blobs."""

    def run_size(self, path, config=None, **extra):
        """Runs `size` on the catalog at `path`; returns what it printed."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            l10n.cmd_size(args_for("size", path, config=config or self.folder / "none.json", **extra))
        return out.getvalue()

    def test_an_empty_catalog_has_a_pack_of_no_ids(self):
        printed = self.run_size(self.write_catalog({}))
        self.assertIn("English text: 0 bytes of 150,000 (0%); 150,000 under the budget.", printed)
        self.assertIn("The pack, Strings.pack:", printed)
        self.assertIn("ids: ", printed)

    def test_each_language_has_a_blob_in_the_pack_and_the_pack_is_reported(self):
        path = self.write_catalog({"x.play": entry(en=unit("Play"), es=unit("Reproducir")),
                                   "x.books": entry(en=plural(one=unit("%lld book"), other=unit("%lld books")),
                                                    es=plural(one=unit("%lld libro"), many=unit("%lld de libros"),
                                                              other=unit("%lld libros")))})
        printed = self.run_size(path)
        self.assertRegex(printed, r"es: [\d,]+ bytes in the pack \([\d,]+ raw, (lzma|bzip2)\)")
        self.assertRegex(printed, r"en: [\d,]+ bytes in the pack")
        self.assertRegex(printed, r"The pack, Strings.pack: [\d,]+ bytes")
        self.assertIn("catalog file", printed)
        self.assertNotIn("stringsdict", printed, "the apps ship no Apple table")

    def test_the_json_names_each_blob_and_the_pack_total(self):
        path = self.write_catalog({"x.play": entry(en=unit("Play"), es=unit("Reproducir"))})
        data = json.loads(self.run_size(path, json=True))
        self.assertEqual(sorted(data["blobs"]), ["en", "es", "ids", "notes"])
        self.assertGreater(data["packBytes"], sum(blob["compressed"] for blob in data["blobs"].values()), "the header and directory too")
        self.assertEqual(data["blobs"]["ids"]["raw"], len("x.play") + 1)

    def test_over_the_budget_is_said(self):
        path = self.write_catalog({"x.long": entry(en=unit("x" * 200))})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"budgetBytes": 100}))
        self.assertIn("100 over the budget", self.run_size(path, config))

    def test_a_catalog_the_pack_refuses_is_a_refusal_not_a_size(self):
        # An ID outside the pattern is a refusal of the pack.
        path = self.write_catalog({"Play": entry(es=unit("Reproducir"))})
        with self.assertRaises(l10n.Refused) as refused:
            self.run_size(path)
        self.assertIn("the pack cannot be built from the catalog", str(refused.exception))


class CheckTests(TemporaryCase):
    """`check`: one test for each rule, with a catalog that breaks it."""

    CONFIG = {"languages": ["es"], "budgetBytes": 150000, "budgetFails": False}

    def problems(self, strings, **config):
        """The problems `check` finds in a catalog of `strings` under the configuration, with `config` changed."""
        problems, _note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, **config})
        return problems

    def good(self):
        """A catalog every rule passes."""
        return {"Play": entry(es=unit("Reproducir")),
                "%lld books": entry(es=plural(one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("%lld libros")))}

    def test_a_clean_catalog_has_no_problem(self):
        self.assertEqual(self.problems(self.good()), [])

    def test_the_empty_catalog_passes_with_no_language_shipped(self):
        self.assertEqual(self.problems({}, languages=[]), [])
        self.assertEqual(self.problems({}), [])

    def test_the_repositorys_catalog_and_configuration_pass(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(l10n.main(["check"]), 0)
        self.assertIn("0 problems", out.getvalue())

    def test_a_string_with_no_translation_in_a_shipped_language_is_a_problem(self):
        self.assertEqual(self.problems({"Play": entry()}), ['es "Play": missing translation'])

    def test_a_language_that_is_not_shipped_needs_no_translation(self):
        self.assertEqual(self.problems({"Play": entry()}, languages=[]), [])

    def test_an_unfinished_state_is_a_problem(self):
        for state in ("new", "needs_review", "stale"):
            self.assertEqual(self.problems({"Play": entry(es=unit("Reproducir", state))}),
                             [f'es "Play": not translated (state {state})'], state)

    def broken(self, entry_value, sentence, key="Play"):
        """The catalog with `entry_value` for a string `key` and a good one beside it: `check` gives exactly one problem, which
        names the key and says `sentence`, and the good string is still checked (and passes)."""
        problems = self.problems({"Open": entry(es=unit("Abrir")), key: entry_value})
        self.assertEqual(problems, [f'{l10n.quote(key)}: {sentence}'], entry_value)

    def test_a_value_that_is_not_text_is_a_problem_and_not_a_crash_or_a_pass(self):
        """The review's finding 7: `"value": 5` and `"value": null` ended in an AttributeError traceback."""
        for value, kind in ((5, "a number"), (None, "null"), (["x"], "a list"), (True, "true or false")):
            self.broken({"comment": "c", "localizations": {"es": {"stringUnit": {"state": "translated", "value": value}}}},
                        f"es value is {kind}, not text")

    def test_a_state_that_is_not_text_is_a_problem(self):
        self.broken({"comment": "c", "localizations": {"es": {"stringUnit": {"state": 3, "value": "Reproducir"}}}},
                    "es state is a number, not text")

    def test_a_comment_that_is_not_text_is_a_problem_and_not_a_pass(self):
        """`"comment": null` and `"comment": 5` passed the comment rule, since `str(None)` is "None"."""
        for value, kind in ((None, "null"), (5, "a number"), (["a"], "a list")):
            self.broken({"comment": value, "localizations": {"es": unit("Reproducir")}}, f"the comment is {kind}, not text")

    def test_localizations_that_are_not_an_object_are_a_problem(self):
        for value, kind in ((None, "null"), (5, "a number"), ([], "a list")):
            self.broken({"comment": "c", "localizations": value}, f"localizations is {kind}, not an object")

    def test_a_localization_that_is_not_an_object_is_a_problem(self):
        self.broken({"comment": "c", "localizations": {"es": None}}, "es is null, not an object")

    def test_an_entry_that_is_not_an_object_is_a_problem(self):
        for value, kind in ((None, "null"), (7, "a number"), ("text", "text")):
            self.broken(value, f"the entry is {kind}, not an object")

    def test_a_string_unit_variations_and_substitutions_that_are_not_of_their_type_are_found_where_they_are(self):
        self.broken({"comment": "c", "localizations": {"es": {"stringUnit": ["x"]}}}, "es stringUnit is a list, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": None}}}, "es variations is null, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": {"plural": 5}}}},
                    "es plural variations are a number, not an object")
        self.broken({"comment": "c", "localizations": {"es": {"variations": {"plural": {"one": {"stringUnit": {"value": None}}}}}}},
                    "es plural.one value is null, not text")
        self.broken({"comment": "c", "localizations": {"es": {"substitutions": {"n": 3}}}}, "es substitution n is a number, not an object")

    def test_every_broken_part_of_a_string_is_listed_and_the_other_checks_go_on_without_it(self):
        problems = self.problems({"Open": entry(), "Play": {"comment": None, "localizations": {"es": {"stringUnit": {"value": 5}}}}})
        self.assertEqual(problems, ['"Play": the comment is null, not text', '"Play": es value is a number, not text',
                                    'es "Open": missing translation'])

    def test_a_broken_catalog_makes_the_command_exit_with_problems_and_no_traceback(self):
        """What the review ran: the command ended in a traceback, whose exit status 1 looks like a check that found problems."""
        path = self.write_catalog({"Play": {"comment": "c", "localizations": {"es": {"stringUnit": {"state": "translated", "value": 5}}}},
                                   "Open": {"comment": None}})
        config = self.folder / "config.json"
        config.write_text(json.dumps(self.CONFIG))
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = l10n.main(["check", "--catalog", str(path), "--config", str(config)])
        self.assertEqual(status, 1, err.getvalue())
        self.assertEqual(err.getvalue(), "")
        self.assertIn('check: "Play": es value is a number, not text', out.getvalue())
        self.assertIn('check: "Open": the comment is null, not text', out.getvalue())
        self.assertIn("check: 2 problems", out.getvalue())

    def test_a_file_that_is_not_a_catalog_is_refused_with_a_sentence(self):
        for text in ("[]", "5", "null", '{"strings": []}'):
            path = self.folder / "Bad.xcstrings"
            path.write_text(text, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = l10n.main(["check", "--catalog", str(path)])
            self.assertEqual(status, l10n.EXIT_USAGE, text)
            self.assertIn("cannot read the catalog", err.getvalue())

    def test_machine_translated_counts_as_done(self):
        self.assertEqual(self.problems({"Play": entry(es=unit("Reproducir", "machine_translated"))}), [])

    def test_an_empty_value_is_a_problem_whatever_its_state(self):
        for state in ("translated", "new"):
            self.assertIn('es "Play": empty value', self.problems({"Play": entry(es=unit("", state))}), state)

    def test_a_placeholder_the_translation_lacks_or_adds_or_changes_is_a_problem(self):
        problems = self.problems({"%lld of %@": entry(es=unit("%lld de")), "Hi %@": entry(es=unit("Hola %lld")),
                                  "Plain": entry(es=unit("Simple %@"))})
        self.assertEqual(len(problems), 3, problems)
        self.assertTrue(any("missing placeholder number 2 (object)" in p for p in problems), problems)
        self.assertTrue(any("extra placeholder number 1 (int64)" in p or "placeholder 1 is a int64" in p for p in problems), problems)

    def test_a_reordering_with_positions_is_fine_and_without_them_is_not(self):
        self.assertEqual(self.problems({"%@ has %lld": entry(es=unit("%2$lld tiene %1$@"))}), [])
        self.assertNotEqual(self.problems({"%@ has %lld": entry(es=unit("%lld tiene %@"))}), [])

    def test_placeholders_are_compared_plural_form_by_plural_form(self):
        # The `many` form forgets its number; the English is the key, which holds one.
        problems = self.problems({"%lld books": entry(es=plural(one=unit("%lld libro"), many=unit("de libros"), other=unit("%lld libros")))})
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("(plural.many)", problems[0])
        self.assertIn("missing placeholder number 1", problems[0])

    def test_the_one_form_may_say_one_in_words_only_where_one_means_exactly_1(self):
        forms = {"%lld books": entry(es=plural(one=unit("un libro"), many=unit("%lld de libros"), other=unit("%lld libros")),
                                     fr=plural(one=unit("un livre"), many=unit("%lld de livres"), other=unit("%lld livres")))}
        self.assertEqual(self.problems(forms), [], "Spanish: one means 1")
        problems = self.problems(forms, languages=["fr"])
        self.assertEqual(len(problems), 1, "French: one covers 0, so the number stays")
        self.assertIn("(plural.one)", problems[0])

    def test_a_plural_form_the_english_has_is_the_one_compared(self):
        strings = {"%lld books": entry(en=plural(one=unit("%lld book"), other=unit("%lld books")),
                                       es=plural(one=unit("%lld libro"), many=unit("%lld de libros"), other=unit("libros")))}
        problems = self.problems(strings)
        self.assertEqual(len(problems), 1, problems)
        self.assertIn("(plural.other)", problems[0])

    def test_a_plural_category_of_the_language_that_is_missing_is_a_problem(self):
        problems = self.problems({"%lld books": entry(es=plural(one=unit("%lld libro"), other=unit("%lld libros")))})
        self.assertEqual(problems, ['es "%lld books": plural form missing: many'])

    def test_each_languages_own_categories_are_required(self):
        one_other = {"%lld books": entry(ru=plural(one=unit("%lld книга"), other=unit("%lld книг")), ja=plural(other=unit("%lld 冊")))}
        problems = self.problems(one_other, languages=["ru", "ja"])
        self.assertEqual(problems, ['ru "%lld books": plural forms missing: few, many'])

    def test_a_translation_with_no_plural_where_the_english_has_one_is_a_problem(self):
        strings = {"%lld books": entry(en=plural(one=unit("%lld book"), other=unit("%lld books")), es=unit("%lld libros"))}
        self.assertEqual(self.problems(strings), ['es "%lld books": the English has plural forms and the translation has none'])

    def test_a_language_with_no_recorded_plural_rule_is_a_problem(self):
        problems = self.problems({"Play": entry(xx=unit("Play"))}, languages=["xx"])
        self.assertEqual(len(problems), 1)
        self.assertIn("no plural rule", problems[0])

    def test_a_substitution_the_translation_lacks_or_changes_is_a_problem(self):
        english = {**unit("%#@books@"), "substitutions": {"books": {"argNum": 1, "formatSpecifier": "lld",
                                                                  **plural(one=unit("%arg book"), other=unit("%arg books"))}}}
        good = {**unit("%#@books@"), "substitutions": {"books": {"argNum": 1, "formatSpecifier": "lld",
                                                                "variations": {"plural": {"one": unit("%arg libro"), "many": unit("%arg de libros"), "other": unit("%arg libros")}}}}}
        # The substitution rules are the ones under test; the pack refuses a substitution's `%#@books@` as a specifier, so check
        # also says that (once English, once the translation), which these tests leave out.
        def rules(strings):
            """The problems about substitutions among those of `strings`."""
            return [p for p in self.problems(strings) if "specifier" not in p]
        self.assertEqual(rules({"%lld books": entry(en=english, es=good)}), [])
        self.assertTrue(any("not one the pack allows" in p for p in self.problems({"%lld books": entry(en=english, es=good)})))
        changed = json.loads(json.dumps(good))
        changed["substitutions"]["books"]["formatSpecifier"] = "@"
        self.assertIn("another argument or format", rules({"%lld books": entry(en=english, es=changed)})[0])
        missing = {**unit("%#@books@")}
        self.assertTrue(any("missing substitution books" in p for p in self.problems({"%lld books": entry(en=english, es=missing)})))

    def test_a_string_without_a_comment_is_a_problem(self):
        self.assertEqual(self.problems({"Play": {"localizations": {"es": unit("Reproducir")}}}), [NO_COMMENT_PLAY])
        self.assertEqual(self.problems({"Play": {"comment": "  ", "localizations": {"es": unit("Reproducir")}}}), [NO_COMMENT_PLAY])
        self.assertIn("// Translators:", NO_COMMENT_PLAY, "the problem says how to fix it")

    def test_a_string_that_is_not_translated_needs_no_comment(self):
        self.assertEqual(self.problems({"Pop": {"shouldTranslate": False}}), [])

    def test_a_stale_string_is_a_problem(self):
        problems = self.problems({"Old": {"extractionState": "stale", "comment": "c", "localizations": {"es": unit("Viejo")}}})
        self.assertEqual(len(problems), 1)
        self.assertIn('"Old": stale', problems[0])

    def test_the_budget_only_reports_unless_the_configuration_makes_it_fail(self):
        strings = {"x" * 200: entry(es=unit("y"))}
        problems, note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, "budgetBytes": 100})
        self.assertEqual(problems, [])
        self.assertIn("100 over the budget (reported only", note)
        problems, _note = l10n.check_catalog(make_catalog(strings), {**self.CONFIG, "budgetBytes": 100, "budgetFails": True})
        self.assertEqual(len(problems), 1)
        self.assertIn("100 bytes over the 100-byte budget", problems[0])

    def test_a_key_whose_own_placeholders_cannot_be_read_is_a_problem(self):
        problems = self.problems({"%1$@ and %lld": entry(es=unit("%1$@ y %2$lld"))})
        self.assertTrue(any("cannot be read" in p for p in problems), problems)

    def test_long_keys_are_cut_in_the_lines(self):
        self.assertLessEqual(len(l10n.quote("k" * 500)), l10n.KEY_WIDTH + 1)
        self.assertEqual(l10n.quote("a\nb"), '"a\\nb"')


class CommandTests(TemporaryCase):
    """The command line: output, limits, exit statuses."""

    def run_main(self, *argv):
        """Runs main(); returns (status, standard output, standard error)."""
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = l10n.main(list(argv))
        return status, out.getvalue(), err.getvalue()

    def test_check_exits_1_with_the_problems_and_0_without(self):
        bad = self.write_catalog({"Play": entry()})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["es"]}))
        status, out, _err = self.run_main("check", "--catalog", str(bad), "--config", str(config))
        self.assertEqual(status, 1)
        self.assertIn('check: es "Play": missing translation', out)
        self.assertIn("check: 1 problem; shipped languages: es", out)
        status, out, _err = self.run_main("check", "--catalog", str(self.write_catalog({})), "--config", str(config))
        self.assertEqual(status, 0)

    def test_the_limit_cuts_the_list_and_says_how_many_are_left(self):
        many = self.write_catalog({f"k{n:02d}": entry() for n in range(5)})
        config = self.folder / "config.json"
        config.write_text(json.dumps({"languages": ["es"]}))
        _status, out, _err = self.run_main("check", "--catalog", str(many), "--config", str(config), "--limit", "2")
        self.assertEqual(out.count("missing translation"), 2)
        self.assertIn("and 3 more", out)
        _status, out, _err = self.run_main("check", "--catalog", str(many), "--config", str(config), "--limit", "0")
        self.assertEqual(out.count("missing translation"), 5)

    def test_a_bad_configuration_exits_2_and_says_which_file(self):
        config = self.folder / "config.json"
        for text in ('{"languages": "es"}', '{"budgetBytes": 0}', '{"budgetFails": "yes"}', "not json"):
            config.write_text(text)
            status, _out, err = self.run_main("check", "--config", str(config))
            self.assertEqual(status, 2, text)
            self.assertIn(str(config), err)

    def test_a_missing_catalog_exits_2(self):
        status, _out, err = self.run_main("check", "--catalog", str(self.folder / "nothing.xcstrings"))
        self.assertEqual(status, 2)
        self.assertIn("cannot read the catalog", err)

    def test_a_command_line_that_names_nothing_exits_2_and_every_command_has_help(self):
        with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stderr(io.StringIO()):
            l10n.main([])
        self.assertEqual(stopped.exception.code, 2)
        for command in ("sync", "status", "size", "check"):
            with self.assertRaises(SystemExit) as stopped, contextlib.redirect_stdout(io.StringIO()) as printed:
                l10n.main([command, "--help"])
            self.assertEqual(stopped.exception.code, 0)
            self.assertIn(command, printed.getvalue())

    def test_the_repositorys_configuration_ships_no_language_and_reports_the_budget(self):
        """Only what must hold is pinned: no language ships until the orchestrator ships one (change `languages` here then),
        the budget, and that it only reports. The sync reads every file of TextMouth/, so there are no `syncPaths`."""
        config = l10n.load_config()
        self.assertEqual(config["languages"], [])
        self.assertEqual(config["budgetBytes"], 150000)
        self.assertIs(config["budgetFails"], False)
        self.assertNotIn("syncPaths", config)


if __name__ == "__main__":
    unittest.main()
