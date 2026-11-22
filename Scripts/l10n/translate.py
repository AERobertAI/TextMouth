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
import re
import sys
import unicodedata
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
# A text of this many characters or fewer is also compared with the earlier strings too short to have a three-character piece.
SHORT_TEXT = 4
# A translation more than this many times as long as its English is listed as a warning, when the English has at least this
# many characters (a short word grows a lot in any language).
LENGTH_WARNING = 3
LENGTH_MINIMUM = 12


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

def english_values(cat, key):
    """{unit path: value} of string `key`'s English: its `en` units that count as text (Catalog.english_units); empty for an
    entry with no English."""
    return {unit.path: unit.value for unit in cat.english_units(key)}


def reference_of(english):
    """The English text a string's placeholders are measured against, from `english` ({path: value}): the text itself, or a
    plural's `other` form (the form that always shows the number), else the last form by path; "" for no English at all.
    This is what the key was before the catalog was keyed by ID."""
    if "" in english:
        return english[""]
    if "plural.other" in english:
        return english["plural.other"]
    return english[sorted(english)[-1]] if english else ""


def english_text_for(english, reference, unit):
    """The English text a translation unit is compared with: the English unit at the same path; else, for a plural form
    the English lacks (Spanish's `many`), the English `other` of the same variation; else the English as a whole, or
    `reference` (see reference_of) when nothing else fits. `english` is {path: value}."""
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
    return reference


def unit_placeholder_problems(english, reference, unit, language):
    """The sentences about the placeholders of one finished unit of `language` (what `check` tests): a top-level plural form
    is compared with the English's reference text (see reference_of), and a `one` form may drop the number where the language's `one` means exactly 1 (see
    plural_form_problems); any other unit is compared with the English text of the same place (english_text_for).
    `english` is {path: value} of the English units."""
    if unit.category and unit.path == f"plural.{unit.category}":
        return catalog.compare_placeholders(reference, unit.value, unit.category == "one" and catalog.one_is_exactly_one(language))
    return catalog.compare_placeholders(english_text_for(english, reference, unit), unit.value)


def unit_precision_warnings(english, reference, unit):
    """The warnings about the number formats of one finished unit (`%.1f` written `%.3f`): a top-level plural form is
    compared with the reference text, as unit_placeholder_problems does, and any other unit with the English text of its place."""
    text = reference if unit.category and unit.path == f"plural.{unit.category}" else english_text_for(english, reference, unit)
    return catalog.precision_warnings(text, unit.value)


def english_shape(cat, key):
    """What the English of string `key` is: ("plain", text) for one text (the key itself when the catalog holds no English
    localization of it), ("plural", {category: text}) for plural forms, or ("other", reason) for a form this module does
    not write (device variations, substitutions), or ("other", reason) for a string with no English at all."""
    units = cat.english_units(key)
    if not units:
        return "other", "the string has no English text (`en`); run sync after the code has it"
    if len(units) == 1 and units[0].path == "":
        return "plain", units[0].value
    if all(unit.category and unit.path == f"plural.{unit.category}" for unit in units):
        return "plural", {unit.category: unit.value for unit in units}
    return "other", "its English has device variations or substitutions, which the translation tools do not write yet"


def english_form(cat, key, category):
    """The English text a plural form `category` of `key` is compared with: the English form of that category, else its
    `other`, else the reference text (reference_of: the English text of a plain string, "" for none)."""
    shape, english = english_shape(cat, key)
    if shape == "plural":
        return english.get(category, english.get("other", reference_of(english_values(cat, key))))
    return english if shape == "plain" else reference_of(english_values(cat, key))


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


def edge_whitespace(text):
    """(the whitespace `text` starts with, the whitespace it ends with): a space or a newline at the edge of a label is
    part of what the code lays out (a title followed by a value), so a translation keeps it exactly."""
    return text[:len(text) - len(text.lstrip())], text[len(text.rstrip()):]


def line_breaks(text):
    """How many line breaks `text` has inside it (those at its edges are the whitespace edge_whitespace compares)."""
    return text.strip().count("\n")


def control_characters(text):
    """The control characters of `text` other than a newline and a tab (a NUL, a carriage return, an escape, ...): they
    have no place in an interface text, and some end a string early."""
    return sorted({character for character in text if unicodedata.category(character) == "Cc" and character not in "\n\t"})


def form_problems(english, text, reference=None, may_drop_numbers=False):
    """The sentences about one form `text` against its `english`: empty text, control characters, whitespace at the edges
    that differs, and placeholders (and `%%`) that differ from those of `reference` (default: `english`; a plural form is
    compared with the key). `may_drop_numbers` lets the form leave out a number placeholder (see plural_form_problems)."""
    if not text.strip():
        return ["empty text"]
    problems = []
    found = control_characters(text)
    if found:
        problems.append("control character " + ", ".join(f"U+{ord(character):04X}" for character in found))
    for edge, wanted, got in zip(("leading", "trailing"), edge_whitespace(english), edge_whitespace(text)):
        if wanted != got:
            problems.append(f"{edge} whitespace is {got!r} where the English has {wanted!r}")
    return problems + catalog.compare_placeholders(english if reference is None else reference, text, may_drop_numbers)


def numberless_problem(reference):
    """The sentence that says a string cannot have plural forms because its English (`reference`, see reference_of) has no
    number placeholder (`%lld`, `%d`, `%f`) for them to vary on, or None."""
    return None if catalog.has_number(reference) else (
        "a plural variation needs a number placeholder (%lld, %d, %f) in the English, and it has none")


def plural_form_problems(language, reference, category, text, english):
    """The sentences about the plural form `category` in `language` (`text`, against `english`, the English form of
    that category): every form is compared with the reference text's placeholders (see reference_of), and a `one` form may leave out the number when the
    language's `one` means exactly 1 ("Un libro"): French's covers 0 and Russian's 21, so theirs must show the number."""
    return form_problems(english, text, reference=reference,
                         may_drop_numbers=category == "one" and catalog.one_is_exactly_one(language))


def plural_problems(cat, key, language, forms):
    """The sentences that say why `forms` ({category: text}) cannot be the plural forms of `key` in `language`: English
    with no number, a form the language does not use, a missing form, an empty form, and a form whose placeholders differ
    from the English's reference text (see reference_of; a `one` form may drop the number where the language allows it, see
    plural_form_problems). The English forms are compared with the reference; another language's with the reference too, and
    its edges with the English form of the same category."""
    reference = reference_of(english_values(cat, key))
    problems = category_problems(language, forms)
    if numberless_problem(reference):
        problems.append(numberless_problem(reference))
    for category, text in forms.items():
        english = reference if language == cat.source_language else english_form(cat, key, category)
        problems += [f"the {category} form: {sentence}"
                     for sentence in plural_form_problems(language, reference, category, text, english)]
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


def english_reference_text(english):
    """The text of an English (a string, or {category: text}) that its placeholders are measured against: itself, or a
    plural's `other` form, else its last form (see reference_of, which does the same for {path: value})."""
    if isinstance(english, str):
        return english
    return english.get("other") or (english[sorted(english)[-1]] if english else "")


def english_texts(english):
    """The texts an English holds: itself, or each of its plural forms."""
    return [english] if isinstance(english, str) else [english[category] for category in sorted(english)]


def slot_signature(text):
    """The placeholders of the English `text` as something comparable: its slots and their types, sorted. Two strings with the same
    signature take the same arguments."""
    return tuple(sorted((str(slot), kind) for slot, kind in catalog.slots(text)[0].items()))


def trigrams(folded):
    """The distinct three-character pieces of the (already case-folded) text, the unit the earlier-translation index
    shares between texts that are nearly the same."""
    return {folded[at:at + 3] for at in range(len(folded) - 2)}


class EarlierIndex:
    """The stale strings that still hold a translation, indexed so that a new string finds the one whose English is nearly
    the same without being compared with every one (5,000 new strings against 600 stale ones took 84 seconds that way).
    A string whose English changed a little keeps its translator's words this way.

    A candidate is offered only when its placeholders are the new key's (a stale "Delete %@" is no help to "Delete %lld
    books"), it shares a three-character piece with the new English (or both are very short), and difflib finds the two at
    least SIMILARITY alike. Of the candidates sharing pieces the CANDIDATES most alike by pieces are measured."""

    # How many candidates, the ones sharing the most three-character pieces, get the exact comparison.
    CANDIDATES = 40

    def __init__(self, cat, language, stale):
        """`stale` is {stale key: its English (a string, or {category: text})}; the earlier translation of each is read from
        `cat` in `language`. A stale string with no translation there is left out."""
        self.cat, self.language = cat, language
        self.entries = {}
        self.by_piece = {}
        self.short = []
        for key in sorted(stale):
            if translation_of(cat, key, language) is None:
                continue
            folded = english_as_text(stale[key]).casefold()
            self.entries[key] = (english_as_text(stale[key]), folded, slot_signature(english_reference_text(stale[key])),
                                 english_reference_text(stale[key]))
            pieces = trigrams(folded)
            for piece in pieces:
                self.by_piece.setdefault(piece, []).append(key)
            if not pieces:
                self.short.append(key)

    def best(self, key, english):
        """The earlier translation whose English is most like `english` (the English of `key`), or None: `{"key",
        "english", "placeholders", "translation", "similarity"}`."""
        folded = english_as_text(english).casefold()
        signature = slot_signature(english_reference_text(english))
        pieces = trigrams(folded)
        shared = {}
        for piece in pieces:
            for candidate in self.by_piece.get(piece, ()):
                shared[candidate] = shared.get(candidate, 0) + 1
        if len(folded) <= SHORT_TEXT:
            # A text of under three characters has no piece to share, and two texts at least SIMILARITY alike differ in
            # length by less than half: a short text is compared with the short ones too.
            for candidate in self.short:
                shared.setdefault(candidate, 0)
        ranked = sorted((candidate for candidate in shared if self.entries[candidate][2] == signature),
                        key=lambda candidate: (-shared[candidate], candidate))[:self.CANDIDATES]
        matcher = difflib.SequenceMatcher(autojunk=False)
        matcher.set_seq2(folded)
        best, best_ratio = None, SIMILARITY
        for candidate in ranked:
            matcher.set_seq1(self.entries[candidate][1])
            # The cheap bounds first: the exact ratio only for a candidate that could beat the best.
            if matcher.real_quick_ratio() < best_ratio or matcher.quick_ratio() < best_ratio:
                continue
            ratio = matcher.ratio()
            if ratio >= best_ratio and (best is None or ratio > best_ratio):
                best, best_ratio = candidate, ratio
        if best is None:
            return None
        return {"key": best, "english": self.entries[best][0],
                "placeholders": [placeholder.raw for placeholder in catalog.placeholders(self.entries[best][3])],
                "translation": translation_of(self.cat, best, self.language), "similarity": round(best_ratio, 2)}


def key_fragments(english):
    """The pieces of text an English is made of between its placeholders, a line break, and quotation marks, stripped, as long
    as two characters or more: what a Swift literal of the English still spells out when its values are interpolated."""
    pieces = [part for piece in catalog.literal_pieces(english) for part in re.split(r'[\n"]', piece)]
    return [piece.strip() for piece in pieces if len(piece.strip()) >= 2]


def context_of(places, root, cache, english=None, trusted=True):
    """The uses of a string for a batch: for up to CONTEXT_USES of its `places` ([{"file", "line"}] from locations.json),
    preferring different files, `{"file", "line", "firstLine", "code"}` with the line and CONTEXT_RADIUS lines around it,
    read from `root`. A file that cannot be read, or that lies outside `root`, gives its place without code. The code is
    left out too when `english` (the reference text, see english_reference_text) is given and none of its text (see key_fragments) is within those lines: the line numbers are
    from another version of the code, and a wrong context misleads more than none. An English with no text of its own ("%lld")
    cannot be checked, so its code is shown only when `trusted` (the locations are from this code). `cache` is {file: lines},
    shared between strings so each file is read once."""
    chosen, seen = [], set()
    for place in places:
        if place["file"] not in seen and len(chosen) < CONTEXT_USES:
            chosen.append(place)
            seen.add(place["file"])
    chosen += [place for place in places if place not in chosen][:CONTEXT_USES - len(chosen)]
    fragments = key_fragments(english) if english is not None else []
    uses = []
    for place in chosen:
        use = {"file": place["file"], "line": place["line"]}
        lines = lines_of(root, place["file"], cache)
        if lines and 1 <= place["line"] <= len(lines):
            first = max(1, place["line"] - CONTEXT_RADIUS)
            code = "\n".join(lines[first - 1:place["line"] + CONTEXT_RADIUS])
            if fragments:
                shown = any(fragment in code for fragment in fragments)
            else:
                shown = trusted or english is None
            if shown:
                use["firstLine"] = first
                use["code"] = code
            else:
                use["codeOmitted"] = "the string's text is not near this line, so the locations are from other code"
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


def batch_item(cat, key, language, glossary, places, root, cache, earlier, trusted=True):
    """The item of the batch for string `key`, or (None, reason) when it is a form the tools do not write yet. `places`
    are the key's uses; `earlier` is the EarlierIndex; `trusted` says the uses' lines are from this code (see
    context_of)."""
    shape, english = english_shape(cat, key)
    if shape == "other":
        return None, english
    texts = english_texts(english)
    item = {"key": key, "english": english, "comment": str(cat.strings[key].get("comment", ""))}
    item["placeholders"] = [placeholder.raw for placeholder in catalog.placeholders(english_reference_text(english))]
    if shape == "plural":
        item["pluralCategories"] = list(catalog.plural_categories(language))
    item["context"] = context_of(places, root, cache, english_reference_text(english), trusted)
    seen, terms = set(), []
    for text in texts:
        for term in glossary.terms_in(text, language):
            if term["term"] not in seen:
                seen.add(term["term"])
                terms.append(term)
    item["glossary"] = terms
    item["doNotTranslate"] = sorted({name for text in texts for name in glossary.names_in(text)})
    previous = earlier.best(key, english)
    if previous:
        item["previous"] = previous
    current = translation_of(cat, key, language)
    if current is not None:
        item["current"] = current
    # The slot the translator fills: a string, or an object by the language's plural categories for English plural forms.
    item["translation"] = {category: "" for category in catalog.plural_categories(language)} if shape == "plural" else ""
    return item, None


def build_batch(cat, language, glossary, locations, root, keys=None, limit=DEFAULT_LIMIT, trusted=True):
    """The batch of strings to translate into `language`: the pending strings (see pending_keys), or those of `keys` that
    are pending, the first `limit` in key order (0 means all), each as batch_item makes it. `locations` is the table of
    locations.json for the main catalog ({key: [{"file", "line"}]}); `root` is where the files it names are read.
    `trusted` says `locations` was made from this code (a stamp that does not match is not trusted, and then a
    use's code is shown only where it can be checked: see context_of). `skipped` lists the keys left out and why. Raises Problems for the source language or a language with no plural rule."""
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
    earlier = EarlierIndex(cat, language, {key: english_shape(cat, key)[1] for key, entry in cat.strings.items()
                                           if cat.is_stale(entry) and english_shape(cat, key)[0] != "other"})
    items, cache, remaining = [], {}, 0
    for index, key in enumerate(pending):
        if limit and len(items) >= limit:
            remaining = len(pending) - index
            break
        item, reason = batch_item(cat, key, language, glossary, locations.get(key, []), root, cache, earlier, trusted)
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

def text_problems(glossary, english, text, keep_english, found=None):
    """(the problems, the warnings) of one translated text `text` against its `english`: what form_problems finds (empty,
    control characters, edge whitespace, placeholders; pass `found` when the caller has already compared a plural form with
    the key), the English left as it was (unless `keep_english`, or it has nothing to translate), a do-not-translate name of
    the English that is gone; and, as a warning, a text over LENGTH_WARNING times as long (for a text of at least
    LENGTH_MINIMUM characters in the English: "OK" to "Aceptar" is not news)."""
    problems = list(form_problems(english, text) if found is None else found)
    if not problems:
        if text.strip() == english.strip() and not keep_english and not glossary.nothing_to_translate(english):
            problems.append('the English left as it was (if that is right, set "keepEnglish": true on the item)')
        problems += [f"lost the name {name}, which is never translated" for name in glossary.missing_names(english, text)]
    # A number printed with other digits than the English's is worth a look, never a refusal.
    warnings = catalog.precision_warnings(english, text)
    if len(english.strip()) >= LENGTH_MINIMUM and len(text) > LENGTH_WARNING * len(english):
        warnings.append(f"{len(text) / len(english):.1f} times as long as the English")
    # A line break inside the text lays the text out in lines; a translation may reflow, but the loss of one is worth a look.
    if line_breaks(english) != line_breaks(text):
        warnings.append(f"{line_breaks(text)} line breaks where the English has {line_breaks(english)}")
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
        # Plural forms: only for English that has plural forms and a key with a number to vary on; the language's categories
        # exactly, each form checked against the key's placeholders (a `one` form may drop the number where the language
        # allows it) and against the English form of its category for what the English keeps (edges, names).
        if shape != "plural":
            problems.append("the English has no plural forms, so the translation must be one text (give the English its "
                            "forms with `plural --lang en` first)")
        problems += category_problems(language, translation)
        reference = english_reference_text(english) if shape == "plural" else reference_of(english_values(cat, key))
        if numberless_problem(reference):
            problems.append(numberless_problem(reference))
        for category, text in translation.items():
            if not isinstance(text, str):
                problems.append(f"the {category} form is not text")
                continue
            form_english = english_form(cat, key, category)
            found, warned = text_problems(glossary, form_english, text, keep,
                                          plural_form_problems(language, reference, category, text, form_english))
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


def batch_language(cat, language, expected=None):
    """The language of a batch to write, or Problems: it must be text, not the catalog's source language (English is
    written with `plural`, never overwritten by a batch), a language `catalog.plural_categories` knows (so a typo such as
    "sp" is not written as a new language), and, when `expected` is given (`apply --lang`), the same as `expected`."""
    if not isinstance(language, str) or not language.strip():
        raise Problems('the batch needs a "language" that is text, such as "es"')
    if language.replace("_", "-").casefold() == cat.source_language.casefold():
        raise Problems(f'the batch is for {language}, the catalog\'s source language; a batch never writes the source text '
                       "(use `plural` for English plural forms)")
    try:
        catalog.plural_categories(language)
    except KeyError as error:
        raise Problems(f'the batch\'s language {language!r} is not one the tools know: {error.args[0]}')
    if expected is not None and expected != language:
        raise Problems(f'the batch is for {language!r}, but --lang says {expected!r}')
    return language


class ApplyResult:
    """What apply_batch did: `written` (keys changed), `unchanged` (keys whose translation was already there), `rejected`
    (the refused items, each with its `problems`), and `warnings` ((key, sentence) pairs)."""

    def __init__(self):
        self.written, self.unchanged, self.rejected, self.warnings = [], [], [], []


def apply_batch(cat, batch, glossary, state=None, expected_language=None):
    """Checks each item of the translated `batch` (see the module's note) and writes the good ones into `cat` in `state`
    (default: default_state). A good translation of a string a person has already marked `translated` is refused when
    the state is a machine's and the text differs, so a review is never overwritten by a machine. Running it again on the
    same batch changes nothing. `expected_language` is the language the caller says the batch is for (`apply --lang`), which
    must be the batch's. Raises Problems when the batch itself is unusable (see batch_language, a bad state). Returns an
    ApplyResult."""
    if not isinstance(batch, dict) or not isinstance(batch.get("items"), list):
        raise Problems('the batch needs a "language" and a list of "items"')
    language = batch_language(cat, batch.get("language"), expected_language)
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
        # A form a person reviewed that the machine's text would have replaced stays as the person wrote it.
        result.warnings += [(key, f"kept the {unit_path.rsplit('.', 1)[-1] if unit_path else 'text'} form a person marked "
                                  "translated, which this machine translation differs from") for unit_path in outcome[2]]
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
    """What to do with a good `translation` of `key`, unit by unit (a plain string is one unit; plural forms are one each):
    `(action, payload, kept)`.
    - A unit whose text is already there, in a state at least as good as `state`, is left as it is (never downgraded).
    - A unit a person marked `translated`, whose text differs from the new text, is kept when `state` is a machine's: a
      machine never replaces a review. The paths of those units are `kept`.
    - Every other unit is written in `state`.
    The action is "unchanged" when nothing changes, "refused" (payload: the reason) when nothing changes only because units
    were kept, or the localization holds forms this module does not write, else "write" (payload: the localization to
    store; the units that were kept are in it as they were)."""
    existing = cat.strings[key].get("localizations", {}).get(language, {})
    if protected_forms(existing):
        return "refused", "its localization holds substitutions or device variations, which would be replaced; edit it by hand", []
    held = {unit.path: unit for unit in cat.units(key, language)}
    order = catalog.STATUS_ORDER.index
    units, kept = {}, []
    for unit_path, text in forms_of(translation).items():
        current = held.get(unit_path)
        if current and current.value == text and order(unit_status(current)) >= order(state):
            units[unit_path] = (current.state, text)
        elif current and current.state == "translated" and current.value != text and state != "translated":
            units[unit_path] = (current.state, current.value)
            kept.append(unit_path)
        else:
            units[unit_path] = (state, text)
    if units == {unit_path: (unit.state, unit.value) for unit_path, unit in held.items()}:
        if kept:
            return "refused", ("already translated by a person; a machine translation does not replace it "
                               "(use --state translated to replace it on purpose)"), kept
        return "unchanged", None, []
    return "write", localization_of(translation, units), kept


def unit_status(unit):
    """The status (see Catalog.status) of one unit: its state, or `missing` when its value is empty (nothing is there)."""
    return unit.state if unit.value.strip() else "missing"


def localization_of(translation, units):
    """The localization that holds `translation`'s forms, each with the state and text `units` gives it ({unit path:
    (state, text)}, the paths of forms_of)."""
    if isinstance(translation, str):
        state, text = units[""]
        return plain_localization(text, state)
    forms = {category: plain_localization(units[f"plural.{category}"][1], units[f"plural.{category}"][0]) for category in translation}
    return {"variations": {"plural": forms}}
