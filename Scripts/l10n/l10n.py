#!/usr/bin/env python3
"""l10n.py: TextMouth's localization tools, in the style of the issue and doc libraries (FR34, TL10).

Run from anywhere inside the repository or one of its worktrees:

    python3 -I -B Scripts/l10n/l10n.py COMMAND [OPTIONS]

Commands (`--help` after each says more):
  sync     Read the code's `InterfaceText.line("<ID>", "<English>")` calls with the lexer (seconds: no build, no lock)
           and bring the String Catalog (TextMouth/Localization/Localizable.xcstrings, keyed by ID) into step with them: a
           new ID gets its English as `en` and its `// Translators: ...` note as the comment, an ID the code no longer
           has is marked stale, and an ID whose English changed gets the new `en` and every other language
           `needs_review`. It refuses, writing nothing, what the lint's rules and the pattern forbid (see sync.py). It
           writes build/l10n/locations.json (each ID's files and lines, for the translators).
  status   Per language: the strings translated, machine translated, new, needing review, stale, and missing, and the
           English bytes.
  size     The English bytes against the budget, and the bytes of each blob of the pack (the IDs, the notes, English, and
           each language) that the apps ship.
  check    The rules a catalog must keep before a language ships. Fast, builds nothing, and is run by `make check`.
  plural   Write a string's plural forms in one language (English included).
  todo     A JSON batch of the strings to translate into a language, each with its comment, placeholders, code context,
           glossary terms, and an earlier translation of a similar string.
  apply    Check a translated batch, string by string, and write the good translations (machine_translated).
  prune    Delete the stale strings (the code no longer has them) that hold no translation; --all deletes every stale one.
  reach    The hosted test classes a branch's localization could break, for a train request's --classes: the Mac tests
           on one comma-separated line, the iPhone unit tests on a line of their own; --explain gives each reason.
  merge-driver
           Git's merge driver for the String Catalog (`make l10n-merge-driver` defines it): a three-way merge by key,
           language, and plural form.

The catalog's layout, placeholders, plural rules, and states are in catalog.py; the shipped languages and the budget are
in config.json.

Exit status: 0 when the command did its work, 1 when a check found problems or a sync was refused (lines on standard
error or output say why), 2 for a command line that names nothing or gives a bad value, or a missing tool or file.

Standard library only.
"""
import argparse
import json
import plistlib
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
# catalog.py is in this folder, and repo_paths.py (which finds the main checkout) in Scripts/agents: python3 -I leaves
# both out of sys.path.
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "agents"))
import catalog  # noqa: E402  (imported by path, after sys.path is set)
import repo_paths  # noqa: E402
import glossary as glossarylib  # noqa: E402
import merge  # noqa: E402
import pack  # noqa: E402
import reach  # noqa: E402
import sync as syncing  # noqa: E402
import translate  # noqa: E402

EXIT_OK = 0        # the command did its work
EXIT_PROBLEMS = 1  # a check found problems, or a sync was refused
EXIT_USAGE = 2     # a bad command line, a tool or file that is missing

# The checkout this script is in (the main checkout or a worktree): the catalog and the configuration are read here,
# so a branch's own catalog is the one checked.
ROOT = HERE.parents[1]
# Where the catalogs are, relative to the repository, and the table the compiler's strings go to when none is named.
CATALOG_FOLDER = Path("TextMouth/Localization")
TABLE = "Localizable"
CONFIG_PATH = HERE / "config.json"
# The main checkout, which holds the tools' output whichever worktree runs them, and the folder in it they write to
# (gitignored), and the file that maps each ID to its places.
MAIN = repo_paths.main_checkout()
OUTPUT = MAIN / "build" / "l10n"
LOCATIONS_FILE = "locations.json"
# The key of the locations file that holds the stamp of the code it was made from (`{"commit", "treeId"}`), beside the
# table (a table is named like a .strings file, never with a leading underscore).
EXTRACTED_KEY = "_extracted"
# How many of a refused sync's problems are listed.
PROBLEMS_SHOWN = 15
# The configuration's defaults: no language ships until Spanish is translated; the English budget in bytes (the
# user's 150 KB for the interface text) only reports until the cutting is done.
DEFAULT_CONFIG = {"languages": [], "budgetBytes": 150000, "budgetFails": False}
# How many problems `check` prints unless --limit says otherwise.
DEFAULT_LIMIT = 100
# The longest an ID (or any text) is shown in a line.
KEY_WIDTH = 60
# A translator's note in the code (TL15): a line comment that starts with this marker, on the line directly above the line
# that holds the call's English. `sync` writes it into the catalog as the comment; nothing of it is compiled into the apps.
NOTE_MARKER = "// Translators:"


class Refused(Exception):
    """A command that cannot go on: its message says why (exit status 1 for a refused sync, 2 for a missing tool)."""

    def __init__(self, message, status=EXIT_PROBLEMS):
        super().__init__(message)
        self.status = status


# ---------------------------------------------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------------------------------------------

def quote(key):
    """A key as it is shown in a line: quoted, on one line, and cut at KEY_WIDTH characters."""
    shown = json.dumps(key, ensure_ascii=False)
    return shown if len(shown) <= KEY_WIDTH else shown[:KEY_WIDTH - 1] + "…\""


def number(count):
    """A count with thousands separators."""
    return f"{count:,}"


def percent(part, whole):
    """`part` of `whole` as a whole percent, "0%" for an empty whole."""
    return f"{round(100 * part / whole)}%" if whole else "0%"


def load_config(path=CONFIG_PATH):
    """The configuration (see DEFAULT_CONFIG) read from `path`: its keys over the defaults, checked for type."""
    config = dict(DEFAULT_CONFIG)
    try:
        config.update(json.loads(Path(path).read_text(encoding="utf-8")))
    except FileNotFoundError:
        pass
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read {path}: {error}", EXIT_USAGE)
    if not (isinstance(config["languages"], list) and all(isinstance(code, str) and code for code in config["languages"])):
        raise Refused(f"{path}: languages must be a list of language codes", EXIT_USAGE)
    if not (isinstance(config["budgetBytes"], int) and not isinstance(config["budgetBytes"], bool) and config["budgetBytes"] > 0):
        raise Refused(f"{path}: budgetBytes must be a whole number above zero", EXIT_USAGE)
    if not isinstance(config["budgetFails"], bool):
        raise Refused(f"{path}: budgetFails must be true or false", EXIT_USAGE)
    return config


def catalog_path(args, table=TABLE):
    """The catalog file of `table`: --catalog for the main table, else its place in this checkout."""
    if args.catalog and table == TABLE:
        return Path(args.catalog)
    return ROOT / CATALOG_FOLDER / f"{table}.xcstrings"


def load_catalog(args):
    """The main catalog, or a Refused (status 2) that says it cannot be read."""
    path = catalog_path(args)
    try:
        return catalog.Catalog.load(path)
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read the catalog {path}: {error}", EXIT_USAGE)


def languages_of(cat, config, only=None):
    """The languages to report on: those the configuration ships and those the catalog holds, sorted; `only`, when given,
    is the one language asked for."""
    return [only] if only else sorted(set(config["languages"]) | set(cat.languages()))


def emit(args, data, lines):
    """Prints `data` as JSON with --json, else `lines`, one to a line."""
    if args.json:
        print(json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False))
    else:
        for line in lines:
            print(line)


# ---------------------------------------------------------------------------------------------------------------
# sync
# ---------------------------------------------------------------------------------------------------------------

def describe(keys, limit=10):
    """Up to `limit` keys, quoted and joined, with the count of the rest."""
    shown = ", ".join(quote(key) for key in keys[:limit])
    return shown + (f", and {len(keys) - limit} more" if len(keys) > limit else "")


def stamp_of(root):
    """The stamp of the code a locations file is made from: {"commit", "treeId"} of `root`'s HEAD (both None when git cannot
    say), which `todo` compares with its own checkout's (see locations_note)."""
    commit, tree = head_ids(root)
    return {"commit": commit, "treeId": tree}


def write_locations(path, found, root):
    """Writes the locations file `path`: the stamp of the code under `root`, and each ID's files and lines under the main
    table's name, in the layout `todo` reads."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data = {EXTRACTED_KEY: stamp_of(root), TABLE: syncing.locations_of(found)}
    path.write_text(json.dumps(data, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")


def say_report(report, say, verbose):
    """Says what a sync (or a dry run of one) did to the catalog: the counts, the English bytes, and the IDs by name."""
    say(f"{TABLE}: {number(len(report.added))} added, {number(len(report.stale))} became stale, "
        f"{number(len(report.revived))} no longer stale, {number(len(report.english_changed))} changed their English")
    say(f"{TABLE}: the English text went from {number(report.bytes_before)} to {number(report.bytes_after)} bytes")
    say(f"{TABLE}: {number(len(report.comments))} comments written from the code's \"{NOTE_MARKER}\" lines")
    for label, keys in (("added", report.added), ("became stale", report.stale), ("no longer stale", report.revived),
                        ("changed their English", report.english_changed)):
        if keys:
            say(f"  {label}: {describe(keys, len(keys) if verbose else 10)}")


def cmd_sync(args):
    """`sync [--verbose] [--locations FILE]`: reads the code's `InterfaceText.line` calls (see sync.py) and brings the catalog
    into step with them. A refusal (exit status 1) lists up to PROBLEMS_SHOWN problems and writes nothing: neither the
    catalog nor the locations."""
    started = time.monotonic()
    say = print
    cat = load_catalog(args)
    found, calls, problems = syncing.read_code(ROOT)
    if problems:
        shown = problems[:PROBLEMS_SHOWN]
        raise Refused(f"{number(len(problems))} problems in the InterfaceText.line calls, so nothing was synced:\n" + "\n".join(shown)
                      + (f"\nand {number(len(problems) - len(shown))} more" if len(problems) > len(shown) else ""))
    report = syncing.sync_catalog(cat, found)
    # Only a changed catalog is written: a sync with nothing to do leaves the file alone (a write would change its date for no reason).
    if report.changed():
        cat.save(catalog_path(args))
    say(f"read {number(len(calls))} InterfaceText.line calls with {number(len(found))} IDs")
    say_report(report, say, args.verbose)
    destination = Path(args.locations) if args.locations else OUTPUT / LOCATIONS_FILE
    write_locations(destination, found, ROOT)
    say(f"wrote {destination.name}: the files and lines of {number(len(found))} IDs, in {destination.parent}")
    say(f"synced in {time.monotonic() - started:.1f} seconds")
    return EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# status and size
# ---------------------------------------------------------------------------------------------------------------

def language_counts(cat, language):
    """How many of the strings still to be translated have each status in `language` (see Catalog.status), and how
    many stale strings hold a translation there: {"translated": n, "machine_translated": n, "new": n, "needs_review": n,
    "stale": n, "missing": n}. `stale` is the stale-marked strings, which are not among the others."""
    counts = {status: 0 for status in catalog.STATUS_ORDER}
    for key in cat.translatable():
        counts[cat.status(key, language)] += 1
    # A string whose code is gone but whose translation is kept is stale; one with no translation costs nothing.
    counts["stale"] = sum(1 for key, entry in cat.strings.items() if cat.is_stale(entry) and cat.units(key, language))
    return counts


def cmd_status(args):
    """`status [--lang L]`: the counts of each language and the English bytes."""
    cat, config = load_catalog(args), load_config(args.config)
    bytes_now, budget = cat.english_bytes(), config["budgetBytes"]
    languages = languages_of(cat, config, args.lang)
    total = len(cat.translatable())
    data = {"sourceLanguage": cat.source_language, "strings": total,
            "stale": sum(1 for entry in cat.strings.values() if cat.is_stale(entry)), "englishBytes": bytes_now, "budgetBytes": budget,
            "languages": {language: language_counts(cat, language) for language in languages}}
    lines = [f"{number(total)} strings to translate, {number(data['stale'])} stale. English text: {number(bytes_now)} bytes "
             f"of {number(budget)} ({percent(bytes_now, budget)})."]
    for language in languages:
        counts = data["languages"][language]
        lines.append(f"{language}: {number(counts['translated'])} translated, {number(counts['machine_translated'])} machine translated, "
                     f"{number(counts['new'])} new, {number(counts['needs_review'])} need review, {number(counts['stale'])} stale, "
                     f"{number(counts['missing'])} missing")
    if not languages:
        lines.append("No language is shipped or translated yet.")
    emit(args, data, lines)
    return EXIT_OK


def pack_sizes(path):
    """(the pack's total bytes, {blob name: (compressed bytes, raw bytes, method name)}) of the pack that `pack.py` builds from the catalog at
    `path`: `ids`, `notes`, `en`, and each language's blob, the sizes the apps ship. A Refused (status 1) when the catalog
    cannot be built into a pack (the sentences name why: `check` lists them all)."""
    try:
        data = pack.build_bytes(pack.build_plan(path))
    except pack.PackError as error:
        raise Refused("the pack cannot be built from the catalog, so it has no size (`check` says why): " + "; ".join(error.problems[:3]))
    blobs = pack.read_pack(data).blobs
    return len(data), {name: (blob.compressed, blob.raw, pack.METHOD_NAMES[blob.method]) for name, blob in blobs.items()}


def cmd_size(args):
    """`size`: the English bytes against the budget, the pack's total, and each blob of the pack (the IDs, the notes, English,
    and each language), compressed and raw; the catalog's own size is not shipped."""
    cat, config = load_catalog(args), load_config(args.config)
    bytes_now, budget = cat.english_bytes(), config["budgetBytes"]
    path = catalog_path(args)
    pack_bytes, blobs = pack_sizes(path)
    data = {"englishBytes": bytes_now, "budgetBytes": budget, "overBudget": bytes_now > budget, "catalogBytes": path.stat().st_size,
            "packBytes": pack_bytes, "blobs": {name: {"compressed": packed, "raw": raw, "method": method} for name, (packed, raw, method) in blobs.items()}}
    over = bytes_now - budget
    lines = [f"English text: {number(bytes_now)} bytes of {number(budget)} ({percent(bytes_now, budget)}); "
             + (f"{number(over)} over the budget." if over > 0 else f"{number(-over)} under the budget."),
             f"The catalog file: {number(data['catalogBytes'])} bytes (not shipped).",
             f"The pack, Strings.pack: {number(pack_bytes)} bytes, one compressed blob (the smaller of LZMA and bzip2) for the IDs, the notes, English, and each language."]
    for name, (packed, raw, method) in blobs.items():
        lines.append(f"{name}: {number(packed)} bytes in the pack ({number(raw)} raw, {method})")
    emit(args, data, lines)
    return EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------------------------------------------

# The English a translated unit is compared with lives in translate.py, which `apply` uses too.
english_text_for = translate.english_text_for


def check_language(cat, language):
    """The problems of `language`'s translations: each string to be translated that is missing or unfinished, has an empty
    value, has placeholders that differ from the English's (plural form by plural form), or lacks a plural category the
    language uses, as sentences."""
    problems = []
    try:
        required = catalog.plural_categories(language)
    except KeyError as error:
        return [f"{language}: {error.args[0]}"]
    for key in cat.translatable():
        label = f"{language} {quote(key)}"
        units = cat.units(key, language)
        if not units:
            problems.append(f"{label}: missing translation")
            continue
        english = translate.english_values(cat, key)
        reference = translate.reference_of(english)
        for unit in units:
            where = f" ({unit.path})" if unit.path else ""
            if not unit.value.strip():
                problems.append(f"{label}{where}: empty value")
            elif unit.state not in catalog.DONE_STATES:
                problems.append(f"{label}{where}: not translated (state {unit.state})")
            else:
                problems += [f"{label}{where}: {sentence}"
                             for sentence in translate.unit_placeholder_problems(english, reference, unit, language)]
        problems += [f"{label}: {sentence}" for sentence in plural_problems(units, english, required)]
        problems += [f"{label}: {sentence}" for sentence in substitution_problems(cat, key, language)]
    return problems


def plural_problems(units, english, required):
    """The sentences about plural forms: a variation of the translation lacking a category of `required`, and plural
    forms in the English where the translation has none. `english` is {path: value}."""
    problems = []
    groups = {}
    for unit in units:
        if unit.category:
            groups.setdefault(unit.path[:-len(unit.category)], set()).add(unit.category)
    for prefix, categories in sorted(groups.items()):
        missing = [category for category in required if category not in categories]
        if missing:
            problems.append(f"plural form{'s' if len(missing) > 1 else ''} missing: {', '.join(missing)}")
    # The English's own plural variations, by the path up to and including "plural." (as `groups` keys them).
    english_prefixes = {path.rsplit(".", 1)[0] + "." for path in english if ".plural." in "." + path}
    for prefix in sorted(english_prefixes):
        if prefix not in groups:
            problems.append("the English has plural forms and the translation has none")
    return problems


def substitution_problems(cat, key, language):
    """The sentences about the substitutions of `key`: each of the English's must be in the translation with the same
    argument number and format specifier."""
    entry = cat.strings[key].get("localizations", {})
    wanted = entry.get(cat.source_language, {}).get("substitutions", {})
    got = entry.get(language, {}).get("substitutions", {})
    problems = []
    for name, spec in sorted(wanted.items()):
        if name not in got:
            problems.append(f"missing substitution {name}")
        elif (got[name].get("argNum"), got[name].get("formatSpecifier")) != (spec.get("argNum"), spec.get("formatSpecifier")):
            problems.append(f"substitution {name} takes another argument or format than the English's")
    return problems


def readable(cat):
    """(the catalog  less its broken strings, the sentences about them: one per problem, each with its key). A string
    whose entry, comment, value, or localizations is not of its type (a number, null, ...) is broken: the other checks would
    fail on it, so they read the rest, and the broken ones are problems of their own."""
    broken = cat.shape_problems()
    sentences = [f"{quote(key)}: {sentence}" for key, found in sorted(broken.items()) for sentence in found]
    return cat.without(broken), sentences


def english_problems(cat, found=None):
    """The sentences about the English of the catalog (FR39 phase 7). Without `found` (the code's calls, see sync.read_code)
    each entry to be translated must hold an English text, and each text of every language that the pack ships must use only
    the five specifiers the pack allows (`%@`, `%n$@`, `%lld`, `%n$lld`, and `%%`, see pack.text_problems); a translation
    with plural forms where the English has none is a problem too (a sync that changed the English dropped its plural forms:
    `plural` writes the new ones). With `found`, the code's English is the catalog's: each ID's `en` (a plural's `other`
    form) equals the code's English exactly, each ID the code calls is in the catalog, and each ID that is not stale has a
    call."""
    problems = []
    for key in cat.translatable():
        label = quote(key)
        english = translate.english_values(cat, key)
        if not english:
            problems.append(f"{label}: no English text (`en`); `sync` writes it from the code")
        for language in [cat.source_language] + cat.languages():
            for unit in cat.units(key, language):
                if catalog.counts_as_text(unit.state) and unit.value:
                    where = f" ({unit.path})" if unit.path else ""
                    problems += [f"{language} {label}{where}: {sentence}" for sentence in pack.text_problems(unit.value)]
            if language != cat.source_language and english and "" in english and any(
                    unit.category and unit.path == f"plural.{unit.category}" for unit in cat.units(key, language)):
                problems.append(f"{language} {label}: the translation has plural forms and the English has none (write the "
                                "English forms with `plural --lang en`)")
    if found is not None:
        for identifier in sorted(found):
            if identifier not in cat.strings:
                problems.append(f"{quote(identifier)}: the code calls this ID and the catalog does not hold it (run sync)")
        for key, entry in sorted(cat.strings.items()):
            if cat.is_stale(entry):
                continue
            if key not in found:
                problems.append(f"{quote(key)}: no call in the code has this ID, and it is not marked stale (run sync)")
                continue
            held = syncing.current_english(cat, key)
            if held is not None and held != found[key].english:
                problems.append(f"{quote(key)}: the English is {quote(held)} and the code's is {quote(found[key].english)} (run sync)")
    return problems


def check_catalog(cat, config, found=None):
    """(the problems, the note about the budget) of a catalog under a configuration. The problems are sentences: each
    string whose parts are not of their type (see readable), each shipped language's (check_language), each string to be
    translated without a comment, each stale string, each English text with unreadable placeholders, the English's own rules
    (english_problems, with `found`: the code's calls), and the budget when the configuration makes it fail."""
    cat, problems = readable(cat)
    for language in sorted(config["languages"]):
        problems += check_language(cat, language)
    problems += english_problems(cat, found)
    for key in cat.translatable():
        if not str(cat.strings[key].get("comment", "")).strip():
            problems.append(f"{quote(key)}: no comment for the translators (write a \"{NOTE_MARKER} ...\" line above its literal in the code, then sync)")
        for text in cat.english_forms(key):
            for sentence in catalog.placeholder_problems(text):
                problems.append(f"{quote(key)}: the English's placeholders cannot be read: {sentence}")
    for key, entry in sorted(cat.strings.items()):
        if cat.is_stale(entry):
            problems.append(f"{quote(key)}: stale (the code no longer has it; `prune` deletes it, `prune --all` even with a translation)")
    used, budget = cat.english_bytes(), config["budgetBytes"]
    note = f"English text: {number(used)} bytes of {number(budget)} ({percent(used, budget)})"
    if used > budget:
        note += f", {number(used - budget)} over the budget"
        if config["budgetFails"]:
            problems.append(f"the English text is {number(used - budget)} bytes over the {number(budget)}-byte budget")
        else:
            note += " (reported only: the configuration does not make the budget fail)"
    return problems, note


# The Mac app's Info.plist, from a checkout's root: it names the bundle's languages (FR39), and `sync-info-plist.py` carries
# the key to the iPhone's.
MAC_INFO_PLIST = Path("TextMouth/Resources/Info.plist")


def bundle_languages(cat):
    """The languages the app bundle must list in CFBundleLocalizations for `cat`: English (the source language) first, then
    the catalog's other languages in code-point order."""
    return [cat.source_language] + cat.languages()


def bundle_language_problems(cat, plist):
    """The sentences about the Mac's Info.plist at `plist` (a path) when its CFBundleLocalizations is not exactly
    `bundle_languages(cat)`: with no Apple language table in the bundle that list is what offers each language to the
    system, so a language added to the catalog alone would never be offered. Empty when the list is right."""
    wanted = bundle_languages(cat)
    try:
        listed = plistlib.loads(Path(plist).read_bytes()).get("CFBundleLocalizations")
    except (OSError, ValueError) as error:
        return [f"{plist} cannot be read to compare its CFBundleLocalizations with the catalog's languages: {error}"]
    if listed == wanted:
        return []
    return [f"the Mac's Info.plist ({plist}) lists the languages {listed} in CFBundleLocalizations, and the catalog's are "
            f"{wanted} (English first, then the rest in code-point order; write the key there, then run "
            f"Scripts/ios/sync-info-plist.py for the iPhone's)"]


def glossary_warnings(cat, glossary, languages):
    """The sentences about translations (finished ones, in each of `languages`) that do not use the translation the glossary
    gives for a term of their English, or that drop a name the glossary says is never translated (`apply` refuses that, but a
    hand edit can still lose one). Only warnings: a language inflects, and a translator may have a better word."""
    warnings = []
    for language in languages:
        for key in cat.translatable():
            english = translate.english_values(cat, key)
            fallback = translate.reference_of(english)
            for unit in cat.units(key, language):
                if not catalog.unit_done(unit):
                    continue
                reference = english_text_for(english, fallback, unit)
                label = f"{language} {quote(key)}" + (f" ({unit.path})" if unit.path else "")
                unused = glossary.unused_terms(reference, unit.value, language)
                if unused:
                    warnings.append(f"{label}: does not use the glossary's "
                                    + ", ".join(json.dumps(text, ensure_ascii=False) for text in unused))
                lost = glossary.missing_names(reference, unit.value)
                if lost:
                    warnings.append(f"{label}: drops the name {', '.join(lost)}, which is never translated")
    return warnings


def precision_warnings(cat, languages):
    """The sentences about finished translations (in each of `languages`) whose number placeholders print other digits than
    the English's (`%.1f` written `%.3f`). Only warnings: a language may well want another precision."""
    warnings = []
    for language in languages:
        for key in cat.translatable():
            english = translate.english_values(cat, key)
            fallback = translate.reference_of(english)
            for unit in cat.units(key, language):
                if catalog.unit_done(unit):
                    label = f"{language} {quote(key)}" + (f" ({unit.path})" if unit.path else "")
                    warnings += [f"{label}: {sentence}" for sentence in translate.unit_precision_warnings(english, fallback, unit)]
    return warnings


def cmd_check(args):
    """`check`: prints the problems (up to --limit), then the glossary's warnings (up to --limit, never a failure) and the
    budget note; exit status 1 when there is a problem. A glossary file that is malformed is a problem."""
    cat, config = load_catalog(args), load_config(args.config)
    # The code's English is the catalog's source: read when the catalog is this checkout's own (or --code-root names one).
    code_root = Path(args.code_root) if args.code_root else (None if args.catalog else ROOT)
    found, code_problems = None, []
    if code_root is not None:
        found, _calls, code_problems = syncing.read_code(code_root)
        # The bundle's languages are the catalog's (FR39), as the code the catalog is checked against says. A checkout named
        # with --code-root that has no Info.plist is a fixture of a test: nothing to compare.
        plist = code_root / MAC_INFO_PLIST
        if plist.exists() or not args.code_root:
            code_problems += bundle_language_problems(cat, plist)
    problems, note = check_catalog(cat, config, found)
    problems = code_problems + problems
    # The rest reads the strings that are whole (check_catalog has reported the others).
    cat = readable(cat)[0]
    warnings = []
    try:
        loaded = glossarylib.Glossary.load(args.glossary)
        # The glossary's own warnings (two terms with one translation) come with those of the translations.
        warnings = (glossary_warnings(cat, loaded, languages_of(cat, config)) + loaded.warnings()
                    + precision_warnings(cat, languages_of(cat, config)))
    except glossarylib.GlossaryError as error:
        problems.append(str(error))
    shown = problems if not args.limit else problems[:args.limit]
    lines = [f"check: {line}" for line in shown]
    if len(shown) < len(problems):
        lines.append(f"check: and {number(len(problems) - len(shown))} more (--limit 0 shows all)")
    shown_warnings = warnings if not args.limit else warnings[:args.limit]
    lines += [f"check: warning: {line}" for line in shown_warnings]
    if len(shown_warnings) < len(warnings):
        lines.append(f"check: and {number(len(warnings) - len(shown_warnings))} more warnings (--limit 0 shows all)")
    lines.append(f"check: {note}")
    shipped = ", ".join(sorted(config["languages"])) or "none yet"
    if warnings:
        lines.append(f"check: {number(len(warnings))} warning{'s' if len(warnings) != 1 else ''} (the glossary's terms and the number formats; not failures)")
    lines.append(f"check: {number(len(problems))} problem{'s' if len(problems) != 1 else ''}; shipped languages: {shipped}")
    emit(args, {"problems": problems, "warnings": warnings, "englishBytes": cat.english_bytes(), "budgetBytes": config["budgetBytes"],
                "languages": config["languages"]}, lines)
    return EXIT_PROBLEMS if problems else EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# plural
# ---------------------------------------------------------------------------------------------------------------

# The plural categories the `plural` command takes as options, in CLDR's order.
PLURAL_OPTIONS = ("zero", "one", "two", "few", "many", "other")


def has_translation(cat, key):
    """Whether string `key` holds a translation: a text in a language other than the source language (the English forms
    of a string, plural ones included, are not a translation, and neither is a localization without a value)."""
    return any(unit.value.strip() for language in cat.strings[key].get("localizations", {})
               if language != cat.source_language for unit in cat.units(key, language))


def stale_to_prune(cat, everything):
    """The stale keys `prune` deletes, sorted: those with no translation, or every stale key when `everything`."""
    return sorted(key for key, entry in cat.strings.items()
                  if cat.is_stale(entry) and (everything or not has_translation(cat, key)))


def cmd_prune(args):
    """`prune [--all] [--dry-run]`: deletes the stale strings that hold no translation (`--all`: every stale string, so
    a stale string with a translation goes too). Prints each key it deletes (with --dry-run, each it would delete, and
    nothing is written), then saves the catalog through catalog.py. Stale strings that were kept because they hold a
    translation are counted, so the report says what is left for `check` to name. The IDs it deletes go to retired-ids.txt of
    this checkout, so that no later sync accepts one again. Running it twice changes nothing."""
    cat = load_catalog(args)
    gone = stale_to_prune(cat, args.all)
    kept = sum(1 for entry in cat.strings.values() if cat.is_stale(entry)) - len(gone)
    verb = "would delete" if args.dry_run else "deleted"
    lines = [f"{verb} stale {quote(key)}" for key in gone]
    lines.append(f"prune: {number(len(gone))} stale strings " + ("would be deleted" if args.dry_run else "deleted")
                 + (f"; {number(kept)} stale with a translation kept (--all deletes them too)" if kept else ""))
    if not args.dry_run:
        for key in gone:
            del cat.strings[key]
        if gone:
            cat.save(catalog_path(args))
            # An ID that leaves the catalog is never used again: `sync` refuses a retired ID (FR39).
            retired = syncing.retire(ROOT, gone)
            if retired:
                lines.append(f"prune: {number(len(retired))} IDs added to retired-ids.txt")
    emit(args, {"deleted": gone, "dryRun": args.dry_run, "keptWithTranslation": kept}, lines)
    return EXIT_OK


def cmd_reach(args):
    """`reach [--base REF] [--explain]`: prints the hosted test classes this branch's localization could break (see
    reach.py): the Mac classes as one comma-separated line for `build-train.py request --classes`, then the iPhone unit
    test classes under a heading of their own. With --explain, a line for each class and reason. Writes nothing."""
    try:
        reached = reach.reach(ROOT, args.base)
    except Exception as error:  # git failed (an unknown --base) or a test folder is unreadable
        raise Refused(f"reach: {error}", EXIT_USAGE)
    emit(args, {bundle: {name: reasons for name, reasons in sorted(classes.items())} for bundle, classes in reached.items()},
         reach.format_reach(reached, args.explain))
    return EXIT_OK


def cmd_plural(args):
    """`plural ID --lang L --one TEXT --other TEXT ...`: writes the plural forms of one string (by its ID) in one language.
    Refuses (exit status 1, nothing written) a form the language does not use, a missing form, an empty form, or a form whose
    placeholders differ from the English's."""
    cat = load_catalog(args)
    forms = {category: getattr(args, category) for category in PLURAL_OPTIONS if getattr(args, category) is not None}
    try:
        state = translate.write_plural(cat, args.key, args.lang, forms, args.state)
    except translate.Problems as refusal:
        raise Refused("\n".join(["plural refused:"] + [f"  {problem}" for problem in refusal.problems]))
    cat.save(catalog_path(args))
    print(f"wrote {args.lang} {quote(args.key)}: {', '.join(forms)} ({state})")
    return EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# todo and apply
# ---------------------------------------------------------------------------------------------------------------

def load_glossary(args):
    """The glossary named by --glossary (default glossary.json beside this script), or a Refused (status 2) that says it
    cannot be read or is malformed."""
    try:
        return glossarylib.Glossary.load(args.glossary)
    except glossarylib.GlossaryError as error:
        raise Refused(str(error), EXIT_USAGE)


def load_locations(args):
    """The table of the main catalog in the locations file `sync` wrote ({key: [{"file", "line"}]}), from --locations or
    the main checkout's build/l10n/locations.json; (the table, whether the file was there, the stamp of the code it was made
    from, {"commit", "treeId"}, or None when the file has none)."""
    path = Path(args.locations) if args.locations else OUTPUT / LOCATIONS_FILE
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data.get(TABLE, {}), True, data.get(EXTRACTED_KEY)
    except (OSError, ValueError, AttributeError):
        return {}, False, None


def head_ids(root):
    """(the commit this checkout is at, the id of its TextMouth folder at that commit), or (None, None) when git cannot say
    (not a repository)."""
    ids = []
    for revision in ("HEAD", "HEAD:TextMouth"):
        done = subprocess.run(["git", "-C", str(root), "rev-parse", revision], capture_output=True, text=True)
        ids.append(done.stdout.strip() if done.returncode == 0 and done.stdout.strip() else None)
    return tuple(ids)


def locations_note(stamp, root):
    """(whether the locations can be trusted to be from this code, a sentence that says why not or None). They are when the
    stamp's commit is this checkout's, or its sources' id is (another commit that left TextMouth/ as it was). A file
    with no stamp (made by an older sync) cannot be trusted. Where git cannot say, nothing is doubted."""
    commit, tree = head_ids(root)
    if commit is None:
        return True, None
    if not stamp:
        return False, "build/l10n/locations.json has no stamp of the commit it was made from (run sync again)"
    if stamp.get("commit") == commit or (tree and stamp.get("treeId") == tree):
        return True, None
    return False, (f"build/l10n/locations.json was made from commit {str(stamp.get('commit'))[:9]}, and this tree is at "
                   f"{commit[:9]} with other sources, so the lines may have moved: run sync again")


def keys_from_file(path):
    """The keys listed in `path`: a JSON list of keys, a JSON object with `items` (a batch or its .rejected.json: the keys
    of its items), or else one key to a line."""
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise Refused(f"cannot read {path}: {error}", EXIT_USAGE)
    if text.lstrip().startswith(("[", "{")):
        try:
            data = json.loads(text)
        except ValueError as error:
            raise Refused(f"{path} is not valid JSON: {error}", EXIT_USAGE)
        if isinstance(data, dict):
            data = [item.get("key") for item in data.get("items", []) if isinstance(item, dict)]
        return [key for key in data if isinstance(key, str)]
    return [line for line in text.splitlines() if line.strip()]


def repository_path(name):
    """`name` (a path given on the command line) as the repository-relative, slash-separated path the locations file uses."""
    path = Path(name)
    if path.is_absolute():
        try:
            path = path.relative_to(ROOT)
        except ValueError:
            pass
    return path.as_posix()


def selected_keys(args, locations, have_locations):
    """The keys the options select, or None for every pending string: --keys-from lists them, --file names source files,
    --area names one of the scanner's areas (Scripts/l10n/swiftscan/areas.py, when this branch has the scanner)."""
    if args.keys_from:
        return keys_from_file(args.keys_from)
    if not (args.file or args.area):
        return None
    if not have_locations:
        raise Refused("--file and --area read build/l10n/locations.json, which `sync` writes; run it first (or name --locations)", EXIT_USAGE)
    if args.file:
        wanted = {repository_path(name) for name in args.file}
        return sorted(key for key, places in locations.items() if any(place["file"] in wanted for place in places))
    try:
        from swiftscan import areas
    except ImportError:
        raise Refused("--area needs the scanner's areas (Scripts/l10n/swiftscan/areas.py), which this branch does not have yet; "
                      "use --file or --keys-from", EXIT_USAGE)
    if args.area not in areas.area_names():
        raise Refused(f"no area {args.area!r}; the areas are {', '.join(areas.area_names())}", EXIT_USAGE)
    return sorted(key for key, places in locations.items() if any(areas.area_of(place["file"]) == args.area for place in places))


def cmd_todo(args):
    """`todo --lang L [--keys-from FILE | --area A | --file PATH...] [--limit N] [--out FILE]`: the batch of strings to
    translate into L, as JSON on standard output or in FILE."""
    cat, glossary = load_catalog(args), load_glossary(args)
    locations, have_locations, stamp = load_locations(args)
    keys = selected_keys(args, locations, have_locations)
    trusted, doubt = locations_note(stamp, ROOT) if have_locations else (False, None)
    if not have_locations:
        print("l10n: no build/l10n/locations.json (run sync): the batch has no code context", file=sys.stderr)
    elif doubt:
        print(f"l10n: warning: {doubt}", file=sys.stderr)
    try:
        batch = translate.build_batch(cat, args.lang, glossary, locations, ROOT, keys, args.limit, trusted)
    except translate.Problems as refusal:
        raise Refused("; ".join(refusal.problems), EXIT_USAGE)
    text = json.dumps(batch, indent=1, ensure_ascii=False) + "\n"
    omitted = sum(1 for item in batch["items"] for use in item["context"] if "codeOmitted" in use)
    summary = (f"todo: {number(batch['count'])} strings for {args.lang}, {number(batch['remaining'])} more not in this batch, "
               f"{number(len(batch['skipped']))} skipped"
               + (f", the code of {number(omitted)} uses left out (it does not hold the string)" if omitted else ""))
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"{summary}; wrote {args.out}")
    else:
        print(text, end="")
        print(summary, file=sys.stderr)
    return EXIT_OK


# The ending of the file `apply` writes the refused items to.
REJECTED_SUFFIX = ".rejected.json"


def rejected_target(file):
    """(the file the refused items of `apply FILE` are written to, whether it may already hold a translator's work): a
    batch X.json writes to X.json.rejected.json, and a file that is already a `.rejected.json` is rewritten itself with
    what is still refused, so the loop (apply, fix the refused, apply the rejected file) never makes
    X.json.rejected.json.rejected.json. Only the first case may overwrite a file the translator has already fixed."""
    file = Path(file)
    if file.name.endswith(REJECTED_SUFFIX):
        return file, False
    return Path(str(file) + REJECTED_SUFFIX), True


def newer_than(path, other):
    """Whether the file `path` was modified after the file `other`."""
    return path.stat().st_mtime_ns > other.stat().st_mtime_ns


def cmd_apply(args):
    """`apply FILE [--lang L] [--state S]`: checks each translation of the batch FILE and writes the good ones. Prints each refusal with
    its reason and writes the refused items to FILE.rejected.json for a second try (FILE itself when it is a .rejected.json,
    rewritten with what is still refused); exit status 1 if any was refused."""
    cat, glossary = load_catalog(args), load_glossary(args)
    try:
        batch = json.loads(Path(args.file).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read the batch {args.file}: {error}", EXIT_USAGE)
    try:
        result = translate.apply_batch(cat, batch, glossary, args.state, args.lang)
    except translate.Problems as refusal:
        raise Refused("; ".join(refusal.problems), EXIT_USAGE)
    if result.written:
        cat.save(catalog_path(args))
    for item in result.rejected:
        for problem in item["problems"]:
            print(f"refused {quote(str(item.get('key', '?')))}: {problem}")
    for key, sentence in result.warnings:
        print(f"warning {quote(key)}: {sentence}")
    # The refused items go to a file of their own for a second try (see rejected_target). Applying the rejected file
    # rewrites it with what is still refused (none when all went through); applying the original batch writes it too, unless
    # the rejected file is newer than the batch, which means a translator has been fixing it: that work is never overwritten.
    target, from_batch = rejected_target(args.file)
    protected = from_batch and target.exists() and newer_than(target, Path(args.file))
    if protected:
        print(f"apply: {target} is newer than {args.file}, so it was left as it is; apply that file to try the refused ones again")
    elif result.rejected or target.exists():
        retry = {key: batch[key] for key in ("language", "sourceLanguage", "pluralCategories") if key in batch}
        target.write_text(json.dumps({**retry, "items": result.rejected}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"apply: {number(len(result.written))} written, {number(len(result.unchanged))} already there, "
          f"{number(len(result.rejected))} refused, {number(len(result.warnings))} warnings"
          + (f"; the refused ones are in {target}" if result.rejected and not protected else ""))
    return EXIT_PROBLEMS if result.rejected else EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# merge-driver
# ---------------------------------------------------------------------------------------------------------------

def cmd_merge_driver(args):
    """`merge-driver BASE OURS THEIRS [PATH]`, in the form git calls a driver (`%O %A %B %P`): merges the three versions of a
    catalog by key, language, and plural form (see merge.py) and writes the result over OURS in the tools' layout. With a
    conflict (a piece both sides changed differently) the result keeps ours, each conflict is printed on standard error with
    the three values, and the exit status is 1, so git reports the file conflicted."""
    try:
        merged, conflicts = merge.merge_texts(*(catalog.read_text(path) for path in (args.base, args.ours, args.theirs)))
        # Through a temporary file and a rename: an interrupted write never leaves OURS half written.
        catalog.write_text_atomic(args.ours, merged)
    except (OSError, ValueError) as error:
        # Exit 2, and OURS is as it was: the checks all come before the write.
        raise Refused(f"merge-driver: cannot merge {args.path or args.ours}: {error}", EXIT_USAGE)
    for conflict in conflicts:
        print(f"l10n merge-driver: conflict in {args.path or 'the catalog'}, {conflict.describe()}", file=sys.stderr)
    return EXIT_PROBLEMS if conflicts else EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# The command line.
# ---------------------------------------------------------------------------------------------------------------

def count_option(text):
    """An argparse type for `--limit`: a whole number of zero or more (a negative count has no meaning, and `--limit -1`
    used to give an empty batch that said every string remained)."""
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{text!r} is not a whole number")
    if value < 0:
        raise argparse.ArgumentTypeError(f"{value} is negative; give 0 for all or a count above 0")
    return value


def build_parser():
    """The command line's parser: one subcommand each for sync, status, size, check, prune, reach, plural, todo, apply, and merge-driver."""
    parser = argparse.ArgumentParser(prog="l10n.py", description=__doc__.split("\n\n")[0],
                                     formatter_class=argparse.RawDescriptionHelpFormatter,
                                     epilog="Exit status: 0 done, 1 a check found problems or a sync was refused, 2 a bad command line.")
    commands = parser.add_subparsers(dest="command", metavar="COMMAND", required=True)

    def add(name, summary, handler):
        """A subcommand with the options every one takes."""
        sub = commands.add_parser(name, help=summary, description=summary)
        sub.set_defaults(handler=handler)
        sub.add_argument("--catalog", help="the catalog file to use instead of this checkout's (the main table only)")
        sub.add_argument("--config", default=CONFIG_PATH, help="the configuration file (default: config.json beside this script)")
        sub.add_argument("--json", action="store_true", help="print the result as JSON")
        return sub

    sync = add("sync", "read the code's InterfaceText.line calls and bring the catalog into step with them", cmd_sync)
    sync.add_argument("--verbose", action="store_true", help="list every ID that was added, became stale, or changed its English")
    sync.add_argument("--locations", help="write the locations file here (default: build/l10n/locations.json of the main checkout)")
    status = add("status", "per language: the strings translated, machine translated, new, needing review, stale, and missing", cmd_status)
    status.add_argument("--lang", help="only this language")
    add("size", "the English bytes against the budget, the pack's total, and each blob of the pack (each language's bytes)", cmd_size)
    check = add("check", "the rules a catalog keeps: translations, placeholders, plurals, comments, stale strings, the budget", cmd_check)
    check.add_argument("--code-root", help="the checkout whose code holds the English (default: this checkout's, unless --catalog "
                                           "names another catalog, which is then checked on its own)")
    check.add_argument("--limit", type=count_option, default=DEFAULT_LIMIT, help=f"print at most this many problems, 0 for all (default {DEFAULT_LIMIT})")
    prune = add("prune", "delete the stale strings that hold no translation (--all: every stale string)", cmd_prune)
    prune.add_argument("--all", action="store_true", help="delete every stale string, translated or not")
    prune.add_argument("--dry-run", action="store_true", help="list what would be deleted and write nothing")
    reach_command = add("reach", "the Mac and iPhone test classes this branch's localization could break, for a train request",
                        cmd_reach)
    reach_command.add_argument("--base", default="main", help="the branch to compare with (default main)")
    reach_command.add_argument("--explain", action="store_true", help="a line for each class and the reason it is reached")
    plural = add("plural", "write a string's plural forms in one language, English included", cmd_plural)
    plural.add_argument("key", help="the string's ID, such as common.countMinutes")
    plural.add_argument("--lang", required=True, help="the language, such as en or es")
    for category in PLURAL_OPTIONS:
        plural.add_argument(f"--{category}", help=f"the text of the {category} form (give exactly the forms the language uses)")
    plural.add_argument("--state", help="the state to write (default translated for English, else machine_translated)")
    glossary_option = lambda sub: sub.add_argument(  # noqa: E731  (one line, used three times)
        "--glossary", default=glossarylib.GLOSSARY_PATH, help="the glossary file (default: glossary.json beside this script)")
    todo = add("todo", "a JSON batch of the strings to translate into a language, with their context", cmd_todo)
    todo.add_argument("--lang", required=True, help="the language to translate into, such as es")
    chosen = todo.add_mutually_exclusive_group()
    chosen.add_argument("--keys-from", help="only these keys: a JSON list, a batch or .rejected.json file, or one key to a line")
    chosen.add_argument("--area", help="only the strings the scanner's area of this name uses")
    chosen.add_argument("--file", nargs="+", help="only the strings these source files use (paths from the repository's root)")
    todo.add_argument("--limit", type=count_option, default=translate.DEFAULT_LIMIT,
                      help=f"at most this many strings, 0 for all (default {translate.DEFAULT_LIMIT})")
    todo.add_argument("--out", help="write the batch to this file instead of standard output")
    todo.add_argument("--locations", help="the locations file (default: build/l10n/locations.json of the main checkout)")
    glossary_option(todo)
    apply = add("apply", "check a translated batch and write the good translations into the catalog", cmd_apply)
    apply.add_argument("file", help="the batch file, translated")
    apply.add_argument("--lang", help="the language the batch is for; it must match the batch's own (a guard against the wrong file)")
    apply.add_argument("--state", choices=("machine_translated", "translated"),
                       help="the state to write (default machine_translated; translated once a person reviewed them)")
    glossary_option(apply)
    glossary_option(check)
    driver = add("merge-driver", "git's merge driver for the catalog: BASE OURS THEIRS [PATH] (git's %%O %%A %%B %%P)", cmd_merge_driver)
    for name, what in (("base", "the common ancestor's file"), ("ours", "our file, which the result is written over"),
                       ("theirs", "the other branch's file")):
        driver.add_argument(name, help=what)
    driver.add_argument("path", nargs="?", help="the catalog's path in the repository, for messages")
    return parser


def main(argv=None):
    """Parses the command line, runs the command, and returns its exit status."""
    args = build_parser().parse_args(argv)
    try:
        return args.handler(args)
    except Refused as refusal:
        print(f"l10n: {refusal}", file=sys.stderr)
        return refusal.status
    except BrokenPipeError:
        # The reader of a pipe went away.
        return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
