#!/usr/bin/env python3
"""translate.py: what the translation commands of l10n.py do to a catalog (TL12). Standard library only; it runs
nothing and builds nothing, and never reads anything but the files it is handed.

What is here:
- `write_plural`: a string's plural forms in one language, English included (the `plural` command);
- `build_batch`: the strings still to translate into a language, each with what a translator needs (the `todo` command);
- `apply_batch`: a translated batch, checked string by string and written (the `apply` command);
- `english_text_for`: the English a translated unit is compared with (also used by `check`).

Every function takes the loaded `catalog.Catalog` and changes it in memory; the commands save it. A refusal of a whole
request is a `Problems` exception whose `problems` are sentences; `apply_batch` instead refuses string by string and
reports each.

A batch is JSON: `{"language", "sourceLanguage", "pluralCategories", "items": [...], "skipped": [...]}`; an item is
`{"key", "english", "comment", "placeholders", "pluralCategories", "context", "glossary", "doNotTranslate", "previous",
"current", "translation"}`, where `english` and `translation` are a string, or an object by plural category when the
English has plural forms. `translation` is empty when `todo` writes it, and the translator fills it. An item may also
carry `"keepEnglish": true`, which says the translation is deliberately the English (a word the language shares).
"""
import difflib
import sys
from pathlib import Path

import catalog

sys.dont_write_bytecode = True

# The states a translation may be written in (the five of Apple's guide; `stale` is the compiler's to set).
WRITABLE_STATES = ("new", "needs_review", "machine_translated", "translated")
# The statuses (see Catalog.status) of a string that still wants a translation.
PENDING_STATUSES = ("missing", "new", "needs_review", "stale")
# How many strings one batch holds unless told otherwise: what one agent can do well in one go.
DEFAULT_LIMIT = 300
# How much of the code around a use a batch shows: this many lines before and after the line, and this many uses.
CONTEXT_RADIUS = 2
CONTEXT_USES = 2
# An earlier translation is offered when its English is at least this like the new one (difflib's ratio, 0 to 1).
SIMILARITY = 0.6
# A translation more than this many times as long as its English is listed as a warning.
LENGTH_WARNING = 3


class Problems(Exception):
    """A request that was refused: `problems` are the sentences that say why."""

    def __init__(self, problems):
        self.problems = [problems] if isinstance(problems, str) else list(problems)
        super().__init__("; ".join(self.problems))


def default_state(language, cat):
    """The state a translation is written in when none is given: English (the source) is `translated`, since it is the
    text itself; any other language is `machine_translated` until a native speaker has reviewed it."""
    return "translated" if language == cat.source_language else "machine_translated"


def check_state(state):
    """Raises Problems unless `state` can be written."""
    if state not in WRITABLE_STATES:
        raise Problems(f"the state {state!r} cannot be written (use {', '.join(WRITABLE_STATES)})")


# ---------------------------------------------------------------------------------------------------------------
# The English of a string, and what a localization holds.
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


def english_shape(cat, key):
    """What the English of string `key` is: ("plain", text) for one text (the key itself when the catalog holds no English
    localization of it), ("plural", {category: text}) for plural forms, or ("other", reason) for a form this module does
    not write (device variations, substitutions)."""
    units = [unit for unit in cat.units(key, cat.source_language)]
    if not units:
        return "plain", key
    if len(units) == 1 and units[0].path == "":
        return "plain", units[0].value or key
    if all(unit.category and unit.path == f"plural.{unit.category}" for unit in units):
        return "plural", {unit.category: unit.value for unit in units}
    return "other", "its English has device variations or substitutions, which the translation tools do not write yet"


def english_form(cat, key, category):
    """The English text a plural form `category` of `key` is compared with: the English form of that category, else its
    `other`, else the key. (The key alone when the catalog has no English plural forms.)"""
    shape, english = english_shape(cat, key)
    if shape == "plural":
        return english.get(category, english.get("other", key))
    return english if shape == "plain" else key


def protected_forms(existing):
    """Whether a localization holds substitutions or device variations, which a plain string or plural forms would drop."""
    return "substitutions" in existing or bool(set(existing.get("variations", {})) - {"plural"})


def plain_localization(text, state):
    """The localization that holds `text` as one string in `state`."""
    return {"stringUnit": {"state": state, "value": text}}


def plural_localization(forms, state):
    """The localization that holds `forms` ({category: text}) as plural variations in `state`."""
    return {"variations": {"plural": {category: plain_localization(text, state) for category, text in forms.items()}}}


# ---------------------------------------------------------------------------------------------------------------
# Checks shared by plural and apply.
# ---------------------------------------------------------------------------------------------------------------

def category_problems(language, forms):
    """The sentences about which plural forms `forms` ({category: text}) has: a form the language does not use and a
    form it uses that is missing. A language with no recorded rule is one problem."""
    try:
        required = catalog.plural_categories(language)
    except KeyError as error:
        return [error.args[0]]
    problems = []
    unused = [category for category in forms if category not in required]
    missing = [category for category in required if category not in forms]
    if unused:
        problems.append(f"{language} does not use the plural form{'s' if len(unused) > 1 else ''} {', '.join(unused)} "
                        f"(it uses {', '.join(required)})")
    if missing:
        problems.append(f"{language} needs the plural form{'s' if len(missing) > 1 else ''} {', '.join(missing)} "
                        f"(it uses {', '.join(required)})")
    return problems


def form_problems(english, text):
    """The sentences about one form `text` against its `english`: empty text, or placeholders that differ."""
    if not text.strip():
        return ["empty text"]
    return catalog.compare_placeholders(english, text)


def plural_problems(cat, key, language, forms):
    """The sentences that say why `forms` ({category: text}) cannot be the plural forms of `key` in `language`: a form the
    language does not use, a missing form, an empty form, and a form whose placeholders differ. The English forms are
    compared with the key (its placeholders); another language's with the English form of the same category (so Spanish
    may say "Un libro" where the English `one` says "One book" too), else with the key."""
    problems = category_problems(language, forms)
    for category, text in forms.items():
        english = key if language == cat.source_language else english_form(cat, key, category)
        problems += [f"the {category} form: {sentence}" for sentence in form_problems(english, text)]
    return problems


# ---------------------------------------------------------------------------------------------------------------
# plural
# ---------------------------------------------------------------------------------------------------------------

def write_plural(cat, key, language, forms, state=None):
    """Writes `forms` ({category: text}) as the plural variations of string `key` in `language`, in `state` (default:
    see default_state). Raises Problems when the key is not in the catalog, the state is not writable, the language's
    categories and the forms differ, or a form's placeholders differ (see plural_problems); and when the language's
    localization holds other forms (device variations, substitutions) that this would replace. Returns the state."""
    if key not in cat.strings:
        raise Problems(f"the catalog has no string {key!r}; run sync after the code has it")
    state = state or default_state(language, cat)
    check_state(state)
    problems = plural_problems(cat, key, language, forms)
    if protected_forms(cat.strings[key].get("localizations", {}).get(language, {})):
        problems.append(f"{language}'s localization of the string holds substitutions or device variations, which a plain "
                        "plural would replace; edit it by hand")
    if problems:
        raise Problems(problems)
    cat.strings[key].setdefault("localizations", {})[language] = plural_localization(forms, state)
    return state


# ---------------------------------------------------------------------------------------------------------------
# todo
# ---------------------------------------------------------------------------------------------------------------

def pending_keys(cat, language):
    """The keys still to be translated into `language`, sorted: strings to be translated, not stale, whose status there is
    `missing`, `new`, `needs_review`, or `stale` (the English changed, or nobody has translated it)."""
    return [key for key in cat.translatable() if cat.status(key, language) in PENDING_STATUSES]


def translation_of(cat, key, language):
    """What `key` is translated as in `language`: a string, an object by plural category, or None when it holds none."""
    units = [unit for unit in cat.units(key, language) if unit.value.strip()]
    if not units:
        return None
    if len(units) == 1 and units[0].path == "":
        return units[0].value
    return {unit.category or unit.path: unit.value for unit in units}


def english_as_text(english):
    """An English (a string, or {category: text}) as one text, for comparing and for finding terms."""
    return english if isinstance(english, str) else " | ".join(english[category] for category in sorted(english))


def english_texts(english):
    """The texts an English holds: itself, or each of its plural forms."""
    return [english] if isinstance(english, str) else [english[category] for category in sorted(english)]


def similar_earlier(cat, language, english, candidates):
    """The earlier translation of the stale string whose English is most like `english`, or None: `{"key", "english",
    "translation", "similarity"}` for the best of `candidates` ({stale key: its English as one text}) at least SIMILARITY
    alike. A string whose English changed a little keeps its translator's words this way."""
    matcher = difflib.SequenceMatcher(autojunk=False)
    matcher.set_seq2(english_as_text(english).casefold())
    best, best_ratio = None, SIMILARITY
    for key, old in candidates.items():
        matcher.set_seq1(old.casefold())
        # The cheap bounds first: the exact ratio only for a candidate that could beat the best.
        if matcher.real_quick_ratio() < best_ratio or matcher.quick_ratio() < best_ratio:
            continue
        ratio = matcher.ratio()
        if ratio >= best_ratio and (best is None or ratio > best_ratio):
            best, best_ratio = key, ratio
    if best is None:
        return None
    return {"key": best, "english": candidates[best], "translation": translation_of(cat, best, language),
            "similarity": round(best_ratio, 2)}


def context_of(places, root, cache):
    """The uses of a string for a batch: for up to CONTEXT_USES of its `places` ([{"file", "line"}] from locations.json),
    preferring different files, `{"file", "line", "firstLine", "code"}` with the line and CONTEXT_RADIUS lines around it,
    read from `root`. A file that cannot be read, or that lies outside `root`, gives its place without code. `cache` is
    {file: lines}, shared between strings so each file is read once."""
    chosen, seen = [], set()
    for place in places:
        if place["file"] not in seen and len(chosen) < CONTEXT_USES:
            chosen.append(place)
            seen.add(place["file"])
    chosen += [place for place in places if place not in chosen][:CONTEXT_USES - len(chosen)]
    uses = []
    for place in chosen:
        use = {"file": place["file"], "line": place["line"]}
        lines = lines_of(root, place["file"], cache)
        if lines and 1 <= place["line"] <= len(lines):
            first = max(1, place["line"] - CONTEXT_RADIUS)
            use["firstLine"] = first
            use["code"] = "\n".join(lines[first - 1:place["line"] + CONTEXT_RADIUS])
        uses.append(use)
    return uses


def lines_of(root, file, cache):
    """The lines of the repository file `file` (a path relative to `root`), or None when it is missing, unreadable, or
    outside `root`. Remembered in `cache`."""
    if file not in cache:
        try:
            path = (Path(root) / file).resolve()
            cache[file] = path.read_text(encoding="utf-8").splitlines() if path.is_relative_to(Path(root).resolve()) else None
        except (OSError, ValueError):
            cache[file] = None
    return cache[file]


def batch_item(cat, key, language, glossary, places, root, cache, earlier):
    """The item of the batch for string `key`, or (None, reason) when it is a form the tools do not write yet. `places`
    are the key's uses; `earlier` is {stale key: English text} for similar_earlier."""
    shape, english = english_shape(cat, key)
    if shape == "other":
        return None, english
    texts = english_texts(english)
    item = {"key": key, "english": english, "comment": str(cat.strings[key].get("comment", ""))}
    item["placeholders"] = [placeholder.raw for placeholder in catalog.placeholders(texts[0] if shape == "plain" else key)]
    if shape == "plural":
        item["pluralCategories"] = list(catalog.plural_categories(language))
    item["context"] = context_of(places, root, cache)
    seen, terms = set(), []
    for text in texts:
        for term in glossary.terms_in(text, language):
            if term["term"] not in seen:
                seen.add(term["term"])
                terms.append(term)
    item["glossary"] = terms
    item["doNotTranslate"] = sorted({name for text in texts for name in glossary.names_in(text)})
    previous = similar_earlier(cat, language, english, earlier)
    if previous:
        item["previous"] = previous
    current = translation_of(cat, key, language)
    if current is not None:
        item["current"] = current
    # The slot the translator fills: a string, or an object by the language's plural categories for English plural forms.
    item["translation"] = {category: "" for category in catalog.plural_categories(language)} if shape == "plural" else ""
    return item, None


def build_batch(cat, language, glossary, locations, root, keys=None, limit=DEFAULT_LIMIT):
    """The batch of strings to translate into `language`: the pending strings (see pending_keys), or those of `keys` that
    are pending, the first `limit` in key order (0 means all), each as batch_item makes it. `locations` is the table of
    locations.json for the main catalog ({key: [{"file", "line"}]}); `root` is where the files it names are read.
    `skipped` lists the keys left out and why. Raises Problems for the source language or a language with no plural rule."""
    if language == cat.source_language:
        raise Problems(f"{language} is the source language; write its plural forms with `plural`")
    try:
        catalog.plural_categories(language)
    except KeyError as error:
        raise Problems(error.args[0])
    pending = pending_keys(cat, language)
    skipped = []
    if keys is not None:
        wanted = list(dict.fromkeys(keys))
        for key in wanted:
            if key not in cat.strings:
                skipped.append({"key": key, "reason": "not in the catalog"})
            elif key not in pending:
                skipped.append({"key": key, "reason": "nothing to translate (done, stale, or not to be translated)"})
        pending = [key for key in pending if key in set(wanted)]
    earlier = {key: english_as_text(english_shape(cat, key)[1]) for key, entry in cat.strings.items()
               if cat.is_stale(entry) and translation_of(cat, key, language) is not None and english_shape(cat, key)[0] != "other"}
    items, cache, remaining = [], {}, 0
    for index, key in enumerate(pending):
        if limit and len(items) >= limit:
            remaining = len(pending) - index
            break
        if not key.strip():
            # An empty key is a literal the compiler found (an empty label, say): there is no text to translate.
            skipped.append({"key": key, "reason": "the text is empty"})
            continue
        item, reason = batch_item(cat, key, language, glossary, locations.get(key, []), root, cache, earlier)
        if item:
            items.append(item)
        else:
            skipped.append({"key": key, "reason": reason})
    return {"language": language, "sourceLanguage": cat.source_language,
            "pluralCategories": list(catalog.plural_categories(language)), "count": len(items), "remaining": remaining,
            "items": items, "skipped": skipped}


# ---------------------------------------------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------------------------------------------

def text_problems(glossary, english, text, keep_english):
    """(the problems, the warnings) of one translated text `text` against its `english`: empty, placeholders that differ,
    the English left as it was (unless `keep_english`, or it has nothing to translate), a do-not-translate name of the
    English that is gone; and, as a warning, a text over LENGTH_WARNING times as long."""
    problems = form_problems(english, text)
    if not problems:
        if text.strip() == english.strip() and not keep_english and not glossary.nothing_to_translate(english):
            problems.append('the English left as it was (if that is right, set "keepEnglish": true on the item)')
        problems += [f"lost the name {name}, which is never translated" for name in glossary.missing_names(english, text)]
    warnings = []
    if english.strip() and len(text) > LENGTH_WARNING * len(english):
        warnings.append(f"{len(text) / len(english):.1f} times as long as the English")
    return problems, warnings


def item_problems(cat, item, language, glossary):
    """(the problems, the warnings, the localization to write or None) of one item of a translated batch. The localization
    is built with state `None` and given its state by the caller."""
    key = item.get("key")
    if not isinstance(key, str) or key not in cat.strings:
        return [f"the catalog has no string {key!r}"], [], None
    if cat.is_stale(cat.strings[key]) or not cat.should_translate(cat.strings[key]):
        return ["the string is stale or not to be translated"], [], None
    shape, english = english_shape(cat, key)
    if shape == "other":
        return [english], [], None
    if "english" in item and item["english"] != english:
        return ["the English changed since the batch was made; make the batch again"], [], None
    translation = item.get("translation")
    keep = item.get("keepEnglish") is True
    problems, warnings = [], []
    if isinstance(translation, dict):
        # Plural forms: the language's categories exactly, each form checked against the English form of its category.
        problems += category_problems(language, translation)
        for category, text in translation.items():
            if not isinstance(text, str):
                problems.append(f"the {category} form is not text")
                continue
            form_english = english_form(cat, key, category)
            found, warned = text_problems(glossary, form_english, text, keep)
            problems += [f"the {category} form: {sentence}" for sentence in found]
            warnings += [f"the {category} form: {sentence}" for sentence in warned]
    elif isinstance(translation, str):
        if shape == "plural":
            problems.append("the English has plural forms, so the translation must give one text for each of them")
        else:
            found, warned = text_problems(glossary, english, translation, keep)
            problems += [f"translation: {sentence}" for sentence in found]
            warnings += [f"translation: {sentence}" for sentence in warned]
    else:
        problems.append("no translation")
    return problems, warnings, translation


class ApplyResult:
    """What apply_batch did: `written` (keys changed), `unchanged` (keys whose translation was already there), `rejected`
    (the refused items, each with its `problems`), and `warnings` ((key, sentence) pairs)."""

    def __init__(self):
        self.written, self.unchanged, self.rejected, self.warnings = [], [], [], []


def apply_batch(cat, batch, glossary, state=None):
    """Checks each item of the translated `batch` (see the module's note) and writes the good ones into `cat` in `state`
    (default: default_state). A good translation of a string a person has already marked `translated` is refused when
    the state is a machine's and the text differs, so a review is never overwritten by a machine. Running it again on the
    same batch changes nothing. Raises Problems when the batch itself is unusable (no language, a bad state). Returns an
    ApplyResult."""
    language = batch.get("language") if isinstance(batch, dict) else None
    if not language or not isinstance(batch.get("items"), list):
        raise Problems('the batch needs a "language" and a list of "items"')
    state = state or default_state(language, cat)
    check_state(state)
    result = ApplyResult()
    for item in batch["items"]:
        if not isinstance(item, dict):
            result.rejected.append({"item": item, "problems": ["an item must be an object with a key and a translation"]})
            continue
        problems, warnings, translation = item_problems(cat, item, language, glossary)
        key = item.get("key")
        outcome = None if problems else decide_write(cat, key, language, translation, state)
        if outcome and outcome[0] == "refused":
            problems.append(outcome[1])
        if problems:
            result.rejected.append({**item, "problems": problems})
            continue
        result.warnings += [(key, sentence) for sentence in warnings]
        if outcome[0] == "unchanged":
            result.unchanged.append(key)
        else:
            cat.strings[key].setdefault("localizations", {})[language] = outcome[1]
            result.written.append(key)
    return result


def forms_of(translation):
    """A translation (a string, or {category: text}) as {unit path: text}, the way Catalog.units names them."""
    return {"": translation} if isinstance(translation, str) else {f"plural.{category}": text for category, text in translation.items()}


def decide_write(cat, key, language, translation, state):
    """What to do with a good `translation` of `key`: ("unchanged", None) when the text is already there in a state at
    least as good as `state`; ("refused", reason) when it would replace a person's translation with a machine's or drop
    forms this module does not write; else ("write", the localization to store)."""
    existing = cat.strings[key].get("localizations", {}).get(language, {})
    if protected_forms(existing):
        return "refused", "its localization holds substitutions or device variations, which would be replaced; edit it by hand"
    localization = plural_localization(translation, state) if isinstance(translation, dict) else plain_localization(translation, state)
    held = {unit.path: unit.value for unit in cat.units(key, language)}
    status = cat.status(key, language)
    same = held == forms_of(translation)
    if same and catalog.STATUS_ORDER.index(status) >= catalog.STATUS_ORDER.index(state):
        return "unchanged", None
    if not same and status == "translated" and state != "translated":
        return "refused", ("already translated by a person; a machine translation does not replace it "
                           "(use --state translated to replace it on purpose)")
    return "write", localization
