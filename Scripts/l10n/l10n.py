#!/usr/bin/env python3
"""l10n.py: TextMouth's localization tools, in the style of the issue and doc libraries (FR34, TL10).

Run from anywhere inside the repository or one of its worktrees:

    python3 -I -B Scripts/l10n/l10n.py COMMAND [OPTIONS]

Commands (`--help` after each says more):
  sync     Type-check both apps with the compiler's string extraction on, then merge what it found into the String
           Catalog (TextMouth/Localization/Localizable.xcstrings) with `xcstringstool sync`, and write
           build/l10n/locations.json (each key's files and lines, for the translators). Takes the heavy-work lock
           through Scripts/ios/typecheck.py, twice, about two minutes each.
  status   Per language: the strings translated, machine translated, new, needing review, stale, and missing, and the
           English bytes.
  size     The English bytes against the budget, and each language's shipped size in each format.
  check    The rules a catalog must keep before a language ships. Fast, builds nothing, and is run by `make check`.
  plural   Write a string's plural forms in one language (English included).

The catalog's layout, placeholders, plural rules, and states are in catalog.py; the shipped languages and the budget are
in config.json.

Exit status: 0 when the command did its work, 1 when a check found problems or a sync was refused (lines on standard
error or output say why), 2 for a command line that names nothing or gives a bad value, or a missing tool or file.

Standard library only.
"""
import argparse
import json
import re
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
# The type-check that extracts the strings.
TYPECHECK = HERE.parent / "ios" / "typecheck.py"
# Both apps must be extracted in one sync: a string only the other app has would be marked stale.
PLATFORMS = ("macos", "ios")
PLATFORM_NAMES = {"macos": "Mac", "ios": "iPhone"}
# The main checkout, which holds the tools' output whichever worktree runs them, and the folder in it they write to
# (gitignored; the type-check's strings folders are there too), and the file that maps each key to its places.
MAIN = repo_paths.main_checkout()
OUTPUT = MAIN / "build" / "l10n"
LOCATIONS_FILE = "locations.json"
# What the last sync left out by `syncPaths`, for `status` and `size` to say.
LEFT_OUT_FILE = "left-out.json"
# The line `typecheck.py --emit-strings` ends with, naming the folder of the strings it wrote, and the file in that folder
# that says what the run found (both defined by typecheck.py; repeated here because that script is run, not imported).
STRINGS_FOLDER_LINE = "Strings folder: "
STRINGS_MANIFEST = "manifest.json"
# The configuration's defaults: no language ships until Spanish is translated; the English budget in bytes (the
# user's 150 KB for the interface text) only reports until the cutting is done.
# `syncPaths` are repository-relative globs of the converted files: the sync keeps only the strings found in them (see
# path_matcher), so the catalog holds exactly the converted areas and `check`'s comment rule can hold from the first commit.
# The conversion waves add their globs, ending with "TextMouth/**".
DEFAULT_CONFIG = {"languages": [], "budgetBytes": 150000, "budgetFails": False, "syncPaths": []}
# How many problems `check` prints unless --limit says otherwise.
DEFAULT_LIMIT = 100
# The longest a key is shown in a line.
KEY_WIDTH = 60


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
    if not (isinstance(config["syncPaths"], list) and all(isinstance(glob, str) and glob for glob in config["syncPaths"])):
        raise Refused(f"{path}: syncPaths must be a list of repository-relative globs", EXIT_USAGE)
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

def run_xcstringstool(arguments):
    """Runs `xcrun xcstringstool` with `arguments`; returns the completed process. A Refused (status 2) when it is not there."""
    try:
        return subprocess.run(["xcrun", "xcstringstool", *arguments], capture_output=True, text=True)
    except OSError as error:
        raise Refused(f"xcstringstool cannot be run ({error}); it comes with Xcode", EXIT_USAGE)


def run_type_check(platform, tree_arguments, say, runner=None):
    """Runs `typecheck.py --emit-strings` for `platform` (it takes the heavy-work lock itself, so this never wraps it in
    run_locked.py) and returns the folder of the strings it wrote. A Refused when it fails or names no folder."""
    say(f"type-checking the {PLATFORM_NAMES[platform]} app with the string extraction on (about two minutes)")
    command = [sys.executable, "-I", "-B", str(TYPECHECK), "--platform", platform, "--emit-strings", "--agent", "l10n",
               "--quiet", *tree_arguments]
    done = (runner or subprocess.run)(command, capture_output=True, text=True)
    last = [line for line in done.stdout.splitlines() if line.startswith(STRINGS_FOLDER_LINE)]
    if done.returncode != 0 or not last:
        tail = "\n".join(done.stdout.splitlines()[:12] + done.stderr.splitlines()[-5:])
        raise Refused(f"the {PLATFORM_NAMES[platform]} type-check did not succeed (exit status {done.returncode}); "
                      f"its strings would be incomplete, so nothing was synced:\n{tail}")
    return Path(last[-1][len(STRINGS_FOLDER_LINE):])


def read_manifest(folder):
    """The manifest of a strings folder (see typecheck.py's collect_strings), with its `folder` added."""
    try:
        manifest = json.loads((Path(folder) / STRINGS_MANIFEST).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read the strings manifest in {folder}: {error}", EXIT_USAGE)
    manifest["folder"] = Path(folder)
    return manifest


def check_manifests(manifests):
    """Raises Refused unless `manifests` are one run of each platform over the same tree, each complete. A sync of one
    platform alone would mark the other app's own strings stale, and two different trees would mix their strings."""
    platforms = sorted(manifest.get("platform", "?") for manifest in manifests)
    if platforms != sorted(PLATFORMS):
        raise Refused(f"a sync needs the strings of both apps, the Mac's and the iPhone's, and got {', '.join(platforms) or 'none'}: "
                      "a string only the other app has would be marked stale")
    first, second = manifests
    for field in ("tree", "treeId"):
        if not first.get(field) or first.get(field) != second.get(field):
            raise Refused(f"the two runs are not of the same tree ({field}: {first.get(field)!r} and {second.get(field)!r}); "
                          "run the sync again so both type-checks read the same files")
    for manifest in manifests:
        found, expected = len(manifest["files"]), manifest["swiftFiles"]
        if found != expected:
            raise Refused(f"the {PLATFORM_NAMES[manifest['platform']]} run wrote {found} .stringsdata files for {expected} Swift files "
                          f"({manifest['folder']}): two files of one name, or a build that stopped early; its strings would be incomplete")


def read_stringsdata(path):
    """One .stringsdata file's content, or a Refused that names the file."""
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise Refused(f"cannot read {path}: {error}", EXIT_USAGE)


def glob_regex(glob):
    """The regular expression of a repository-relative glob: `**` matches anything, slashes included (`**/` also no
    folder at all, so `TextMouth/**/*.swift` matches `TextMouth/A.swift`), `*` and `?` match within one folder's name."""
    pieces, index = [], 0
    while index < len(glob):
        if glob.startswith("**/", index):
            pieces.append("(?:.*/)?")
            index += 3
        elif glob.startswith("**", index):
            pieces.append(".*")
            index += 2
        elif glob[index] == "*":
            pieces.append("[^/]*")
            index += 1
        elif glob[index] == "?":
            pieces.append("[^/]")
            index += 1
        else:
            pieces.append(re.escape(glob[index]))
            index += 1
    return re.compile("".join(pieces) + r"\Z")


def path_matcher(globs):
    """A function from a repository-relative path to whether any of `globs` matches it; with no globs, none does."""
    patterns = [glob_regex(glob) for glob in globs]
    return lambda path: any(pattern.match(path) for pattern in patterns)


def relative_source(data, root):
    """The repository-relative path of the source file a .stringsdata file records, under the type-check's copy `root`."""
    try:
        return Path(data["source"]).relative_to(root).as_posix()
    except ValueError:
        return Path(data["source"]).name


def collect(manifests, keep=lambda path: True):
    """What the runs found in the files whose repository path `keep` accepts: ({table: {key: [{"file": repository path,
    "line": n}, ...]}} with each key's places sorted and without repeats, {platform: {table: set of keys}}, {table: set of
    every key the runs found, kept or not}, the .stringsdata paths that were kept)."""
    places, by_platform, everything, kept_files = {}, {}, {}, []
    for manifest in manifests:
        root = Path(manifest["sourceRoot"])
        found = by_platform.setdefault(manifest["platform"], {})
        for name in manifest["files"]:
            data = read_stringsdata(manifest["folder"] / name)
            relative = relative_source(data, root)
            for table, entries in data.get("tables", {}).items():
                everything.setdefault(table, set()).update(entry["key"] for entry in entries)
            if not keep(relative):
                continue
            kept_files.append(manifest["folder"] / name)
            for table, entries in data.get("tables", {}).items():
                for entry in entries:
                    key = entry["key"]
                    where = {"file": relative, "line": entry.get("location", {}).get("startingLine", 0)}
                    spots = places.setdefault(table, {}).setdefault(key, [])
                    if where not in spots:
                        spots.append(where)
                    found.setdefault(table, set()).add(key)
    for keys in places.values():
        for spots in keys.values():
            spots.sort(key=lambda spot: (spot["file"], spot["line"]))
    return places, by_platform, everything, kept_files


class SyncReport:
    """What a sync did to one catalog: the keys it added, those that became stale, those that are no longer stale, and
    the English bytes before and after."""

    def __init__(self, before, after):
        self.added = sorted(set(after.strings) - set(before.strings))
        self.removed = sorted(set(before.strings) - set(after.strings))
        was = {key for key, entry in before.strings.items() if before.is_stale(entry)}
        now = {key for key, entry in after.strings.items() if after.is_stale(entry)}
        self.stale = sorted(now - was - set(self.added))
        self.revived = sorted(was - now - set(self.removed))
        self.bytes_before, self.bytes_after = before.english_bytes(), after.english_bytes()


def sync_catalog(path, files):
    """Merges the strings of `files` (the .stringsdata paths of both apps) into the catalog at `path` with `xcstringstool
    sync`, then writes it in the tool's layout; returns a SyncReport. A Refused when the tool fails."""
    before = catalog.Catalog.load(path)
    arguments = ["sync", str(path)]
    for file in files:
        arguments += ["--stringsdata", str(file)]
    done = run_xcstringstool(arguments)
    if done.returncode != 0:
        raise Refused(f"xcstringstool sync failed on {path} (exit status {done.returncode}): {(done.stderr or done.stdout).strip()}")
    # The tool writes its own layout when it changes a value; this makes sure of it when it changed nothing.
    catalog.canonicalize(path)
    return SyncReport(before, catalog.Catalog.load(path))


def describe(keys, limit=10):
    """Up to `limit` keys, quoted and joined, with the count of the rest."""
    shown = ", ".join(quote(key) for key in keys[:limit])
    return shown + (f", and {len(keys) - limit} more" if len(keys) > limit else "")


def sync_manifests(args, manifests, say, output=None):
    """The sync itself, from two strings folders' manifests: checks them, merges them into each catalog that has a table in
    them, writes the locations, and prints what changed. Returns the exit status."""
    check_manifests(manifests)
    config = load_config(args.config)
    places, by_platform, everything, files = collect(sorted(manifests, key=lambda m: m["platform"]), path_matcher(config["syncPaths"]))
    # A sync with nothing kept would give xcstringstool no file; an empty one makes it drop every string it can.
    nothing = manifests[0]["folder"] / "filtered" / "none.stringsdata"
    nothing.parent.mkdir(parents=True, exist_ok=True)
    nothing.write_text(json.dumps({"source": "none.swift", "tables": {}, "version": 1}), encoding="utf-8")
    files = [nothing] + files
    # A catalog takes the strings of the table it is named for, and no other: report a table nobody made a catalog for.
    problems = 0
    tables = set(places) | {TABLE}
    reports = {}
    for table in sorted(tables):
        path = catalog_path(args, table)
        if not path.exists():
            if table == TABLE:
                raise Refused(f"the catalog {path} does not exist", EXIT_USAGE)
            say(f"no catalog for the table {table!r} ({number(len(places[table]))} strings, for example "
                f"{describe(sorted(places[table]), 3)}): add {CATALOG_FOLDER / (table + '.xcstrings')} or use the main table")
            problems += 1
            continue
        reports[table] = sync_catalog(path, files)
    found = {table: len(keys) for table, keys in places.items()}
    left_out = {table: sorted(everything[table] - set(places.get(table, {}))) for table in everything}
    say_left_out(say, config, found, left_out)
    per_app = ", ".join(f"{PLATFORM_NAMES[p]} {number(sum(len(k) for k in by_platform[p].values()))}" for p in PLATFORMS)
    say(f"kept {number(sum(found.values()))} strings of {number(len(files) - 1)} converted files ({per_app}; some are in both)")
    for table, report in reports.items():
        say(f"{table}: {number(len(report.added))} added, {number(len(report.stale))} became stale, "
            f"{number(len(report.revived))} no longer stale, {number(len(report.removed))} removed")
        say(f"{table}: the English text went from {number(report.bytes_before)} to {number(report.bytes_after)} bytes")
        for label, keys in (("added", report.added), ("became stale", report.stale), ("removed", report.removed)):
            if keys and args.verbose:
                say(f"  {label}: {describe(keys, len(keys))}")
            elif keys:
                say(f"  {label}: {describe(keys)}")
    destination = output or (OUTPUT / LOCATIONS_FILE)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(places, indent=1, sort_keys=True, ensure_ascii=False) + "\n", encoding="utf-8")
    say(f"wrote {destination.name}: the files and lines of {number(sum(found.values()))} strings, in {destination.parent}")
    write_left_out(destination.parent / LEFT_OUT_FILE, config, found, left_out)
    return EXIT_PROBLEMS if problems else EXIT_OK


def left_out_summary(config, found, left_out):
    """What a sync kept and left out, as a dict: the globs, how many strings it kept and left out (each key of each table
    counted once), and the left-out keys by table, so that nothing falls through the cracks."""
    return {"syncPaths": config["syncPaths"], "kept": sum(found.values()),
            "leftOut": sum(len(keys) for keys in left_out.values()),
            "leftOutKeys": {table: keys for table, keys in sorted(left_out.items()) if keys}}


def say_left_out(say, config, found, left_out):
    """Says how many of the strings the compiler found `syncPaths` left out of the catalog."""
    count = sum(len(keys) for keys in left_out.values())
    shown = ", ".join(config["syncPaths"]) or "none"
    say(f"left out by syncPaths ({shown}): {number(count)} strings, found only in files not yet converted")


def write_left_out(path, config, found, left_out):
    """Writes the record of what the sync left out, which `status` and `size` read."""
    path.write_text(json.dumps(left_out_summary(config, found, left_out), indent=1, sort_keys=True, ensure_ascii=False) + "\n",
                    encoding="utf-8")


def read_left_out(folder=None):
    """The record of the last sync's left-out strings ({"leftOut": n, ...}), or None when none was written here."""
    try:
        return json.loads(((folder or OUTPUT) / LEFT_OUT_FILE).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def left_out_line(record):
    """The sentence `status` and `size` say about the strings syncPaths left out, from the last sync's record."""
    if record is None:
        return "Strings left out by syncPaths: unknown here, since no sync has been recorded (run make l10n-sync)."
    return (f"Strings left out by syncPaths: {number(record['leftOut'])} found by the compiler in files not yet converted "
            f"(the last sync kept {number(record['kept'])}; syncPaths: {', '.join(record['syncPaths']) or 'none'}).")


def cmd_sync(args):
    """`sync`: type-checks both apps (unless --mac-strings and --ios-strings name folders of an earlier run) and merges."""
    say = print
    if bool(args.mac_strings) != bool(args.ios_strings):
        raise Refused("--mac-strings and --ios-strings go together: a sync never takes one app alone", EXIT_USAGE)
    started = time.monotonic()
    if args.mac_strings:
        folders = [Path(args.mac_strings), Path(args.ios_strings)]
    else:
        tree_arguments = ["--worktree"] if args.worktree else ["--ref", args.ref]
        folders = [run_type_check(platform, tree_arguments, say) for platform in PLATFORMS]
    status = sync_manifests(args, [read_manifest(folder) for folder in folders], say)
    say(f"synced in {time.monotonic() - started:.0f} seconds")
    return status


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
    record = read_left_out()
    data["leftOutBySyncPaths"] = record["leftOut"] if record else None
    lines.append(left_out_line(record))
    emit(args, data, lines)
    return EXIT_OK


def encoding_setting():
    """The value of STRINGS_FILE_OUTPUT_ENCODING in this checkout's project.yml, or None."""
    try:
        match = re.search(r"^\s*STRINGS_FILE_OUTPUT_ENCODING:\s*(\S+)", (ROOT / "project.yml").read_text(encoding="utf-8"), re.MULTILINE)
    except OSError:
        return None
    return match.group(1) if match else None


def compile_sizes(path, languages, root):
    """Compiles the catalog at `path` for `languages` with `xcstringstool compile` in each serialization format, into the
    folders text/ and binary/ of `root` (fixed folders: files are overwritten, never deleted), and returns {language:
    {format: bytes}} counting each language's Localizable.strings and Localizable.stringsdict. Only files this run
    wrote are counted, so a leftover of an earlier run is not."""
    sizes = {language: {} for language in languages}
    for form in ("text", "binary"):
        folder = root / form
        folder.mkdir(parents=True, exist_ok=True)
        started = time.time() - 1
        arguments = ["compile", str(path), "--output-directory", str(folder), "--serialization-format", form]
        for language in languages:
            arguments += ["--language", language]
        done = run_xcstringstool(arguments)
        if done.returncode != 0:
            raise Refused(f"xcstringstool compile failed ({form}): {(done.stderr or done.stdout).strip()}")
        for language in languages:
            total, found = 0, False
            for name in ("Localizable.strings", "Localizable.stringsdict"):
                file = folder / f"{language}.lproj" / name
                if file.exists() and file.stat().st_mtime >= started:
                    total, found = total + file.stat().st_size, True
            sizes[language][form] = total if found else None
    return sizes


def cmd_size(args):
    """`size`: the English bytes against the budget, each language's shipped size in each format, and the catalog's own."""
    cat, config = load_catalog(args), load_config(args.config)
    bytes_now, budget = cat.english_bytes(), config["budgetBytes"]
    path = catalog_path(args)
    languages = [language for language in languages_of(cat, config) if language in cat.languages()]
    sizes = compile_sizes(path, languages, OUTPUT / "size") if languages else {}
    data = {"englishBytes": bytes_now, "budgetBytes": budget, "overBudget": bytes_now > budget, "catalogBytes": path.stat().st_size,
            "encodingSetting": encoding_setting(), "languages": sizes}
    over = bytes_now - budget
    lines = [f"English text: {number(bytes_now)} bytes of {number(budget)} ({percent(bytes_now, budget)}); "
             + (f"{number(over)} over the budget." if over > 0 else f"{number(-over)} under the budget."),
             f"The catalog file: {number(data['catalogBytes'])} bytes (not shipped).",
             f"Each language ships one Localizable.strings (and a .stringsdict for plurals); the Xcode build writes it with "
             f"STRINGS_FILE_OUTPUT_ENCODING {data['encodingSetting'] or 'unset'}."]
    for language, forms in sizes.items():
        shown = ", ".join(f"{form} {number(size)} bytes" if size is not None else f"{form} none" for form, size in forms.items())
        lines.append(f"{language}: {shown}")
    if not sizes:
        lines.append("No language is in the catalog yet, so nothing is compiled.")
    record = read_left_out()
    data["leftOutBySyncPaths"] = record["leftOut"] if record else None
    lines.append(left_out_line(record))
    emit(args, data, lines)
    return EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------------------------------------------

def english_text_for(english, key, unit):
    """The English text a translation unit is compared with: the English unit at the same path; else, for a plural form
    the English lacks (Spanish's `many`), the English `other` of the same variation; else the English as a whole, or the
    key when the catalog holds no English localization (the key is the English text). `english` is {path: value}."""
    if unit.path in english:
        return english[unit.path]
    if unit.category:
        other = unit.path[:-len(unit.category)] + "other"
        if other in english:
            return english[other]
    if "" in english:
        return english[""]
    if english:
        return english[sorted(english)[0]]
    return key


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
        english = {unit.path: unit.value for unit in cat.units(key, cat.source_language)}
        for unit in units:
            where = f" ({unit.path})" if unit.path else ""
            if not unit.value.strip():
                problems.append(f"{label}{where}: empty value")
            elif unit.state not in catalog.DONE_STATES:
                problems.append(f"{label}{where}: not translated (state {unit.state})")
            else:
                problems += [f"{label}{where}: {sentence}"
                             for sentence in catalog.compare_placeholders(english_text_for(english, key, unit), unit.value)]
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


def check_catalog(cat, config):
    """(the problems, the note about the budget) of a catalog under a configuration. The problems are sentences: each
    shipped language's (check_language), each string to be translated without a comment, each stale string, each English
    text with unreadable placeholders, and the budget when the configuration makes it fail."""
    problems = []
    for language in sorted(config["languages"]):
        problems += check_language(cat, language)
    for key in cat.translatable():
        if not str(cat.strings[key].get("comment", "")).strip():
            problems.append(f"{quote(key)}: no comment for the translators")
        for sentence in catalog.placeholder_problems(key):
            problems.append(f"{quote(key)}: the English key's placeholders cannot be read: {sentence}")
    for key, entry in sorted(cat.strings.items()):
        if cat.is_stale(entry):
            problems.append(f"{quote(key)}: stale (the code no longer has it; sync, or delete it by hand)")
    used, budget = cat.english_bytes(), config["budgetBytes"]
    note = f"English text: {number(used)} bytes of {number(budget)} ({percent(used, budget)})"
    if used > budget:
        note += f", {number(used - budget)} over the budget"
        if config["budgetFails"]:
            problems.append(f"the English text is {number(used - budget)} bytes over the {number(budget)}-byte budget")
        else:
            note += " (reported only: the configuration does not make the budget fail)"
    return problems, note


def cmd_check(args):
    """`check`: prints the problems (up to --limit) and the budget note; exit status 1 when there is a problem."""
    cat, config = load_catalog(args), load_config(args.config)
    problems, note = check_catalog(cat, config)
    shown = problems if not args.limit else problems[:args.limit]
    lines = [f"check: {line}" for line in shown]
    if len(shown) < len(problems):
        lines.append(f"check: and {number(len(problems) - len(shown))} more (--limit 0 shows all)")
    lines.append(f"check: {note}")
    shipped = ", ".join(sorted(config["languages"])) or "none yet"
    lines.append(f"check: {number(len(problems))} problem{'s' if len(problems) != 1 else ''}; shipped languages: {shipped}")
    emit(args, {"problems": problems, "englishBytes": cat.english_bytes(), "budgetBytes": config["budgetBytes"],
                "languages": config["languages"]}, lines)
    return EXIT_PROBLEMS if problems else EXIT_OK


# ---------------------------------------------------------------------------------------------------------------
# plural
# ---------------------------------------------------------------------------------------------------------------

# The plural categories the `plural` command takes as options, in CLDR's order.
PLURAL_OPTIONS = ("zero", "one", "two", "few", "many", "other")


def cmd_plural(args):
    """`plural KEY --lang L --one TEXT --other TEXT ...`: writes the plural forms of one string in one language. Refuses
    (exit status 1, nothing written) a form the language does not use, a missing form, an empty form, or a form whose
    placeholders differ from the key's."""
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
# The command line.
# ---------------------------------------------------------------------------------------------------------------

def build_parser():
    """The command line's parser: one subcommand each for sync, status, size, check, and plural."""
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

    sync = add("sync", "type-check both apps with the string extraction and merge what it finds into the catalog", cmd_sync)
    tree = sync.add_mutually_exclusive_group()
    tree.add_argument("--ref", default="HEAD", help="the commit to extract the strings from (default HEAD)")
    tree.add_argument("--worktree", action="store_true", help="extract from the working tree's tracked and new files instead of a commit")
    sync.add_argument("--mac-strings", help="the strings folder of an earlier Mac run (with --ios-strings: skips the type-checks)")
    sync.add_argument("--ios-strings", help="the strings folder of an earlier iPhone run (with --mac-strings)")
    sync.add_argument("--verbose", action="store_true", help="list every key that was added, became stale, or was removed")
    status = add("status", "per language: the strings translated, machine translated, new, needing review, stale, and missing", cmd_status)
    status.add_argument("--lang", help="only this language")
    add("size", "the English bytes against the budget, and each language's shipped size in each format", cmd_size)
    check = add("check", "the rules a catalog keeps: translations, placeholders, plurals, comments, stale strings, the budget", cmd_check)
    check.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help=f"print at most this many problems, 0 for all (default {DEFAULT_LIMIT})")
    plural = add("plural", "write a string's plural forms in one language, English included", cmd_plural)
    plural.add_argument("key", help="the string's key, such as '%%lld books'")
    plural.add_argument("--lang", required=True, help="the language, such as en or es")
    for category in PLURAL_OPTIONS:
        plural.add_argument(f"--{category}", help=f"the text of the {category} form (give exactly the forms the language uses)")
    plural.add_argument("--state", help="the state to write (default translated for English, else machine_translated)")
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
