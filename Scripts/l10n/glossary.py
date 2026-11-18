#!/usr/bin/env python3
"""glossary.py: the translation glossary (Scripts/l10n/glossary.json) and the matching the translation tools do with it.
Standard library only.

The file holds two things:
- `doNotTranslate`: names that stay as written in every language (TextMouth, VoiceOver, EPUB, ...). A translation of an
  English text that has one of them must have it too (`Glossary.missing_names`), and a text with nothing but such
  names, placeholders, numbers, and punctuation may be left as the English (`Glossary.nothing_to_translate`).
- `terms`: the interface's own words with their translation per language, each `{"term": "Library", "note": "...",
  "translations": {"es": {"text": "Biblioteca", "check": true, "note": "..."}}}`. `check` marks a translation a native
  speaker should look at first. `todo` hands the terms found in a string's English to the translator
  (`Glossary.terms_in`), and `check` warns when a translation does not use a term's translation
  (`Glossary.unused_terms`): a warning only, since a language inflects (Spanish "marcador", "marcadores").

A language code is looked up as given, then without its region or script, so `es-419` uses Spanish's terms.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

import catalog

sys.dont_write_bytecode = True

GLOSSARY_PATH = Path(__file__).resolve().parent / "glossary.json"
# What may follow a name or term in a text without making it another word: an optional plural `s`, then a non-word.
_WORD_END = r"(?:s)?(?!\w)"


class GlossaryError(ValueError):
    """The glossary file cannot be read or is malformed; the message says where."""


def _fold(text):
    """`text` lower-cased with its accents removed, so "Biblioteca" and "bibliotecas" and "Índice" and "indice" match."""
    decomposed = unicodedata.normalize("NFD", text.casefold())
    return "".join(character for character in decomposed if not unicodedata.combining(character))


def _word_pattern(text, flags=0):
    """A regular expression for `text` standing as a word of its own (with an optional plural `s` after it)."""
    return re.compile(r"(?<!\w)" + re.escape(text) + _WORD_END, flags)


class Glossary:
    """A glossary: `names` (the do-not-translate list) and `terms` (its entries, as loaded)."""

    def __init__(self, names=(), terms=()):
        self.names = list(names)
        self.terms = list(terms)

    # ---- reading ----

    @classmethod
    def load(cls, path=GLOSSARY_PATH):
        """The glossary in the file `path`; an empty one when the file does not exist. A GlossaryError when it cannot be
        read or does not have the shape described above."""
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except FileNotFoundError:
            return cls()
        except (OSError, ValueError) as error:
            raise GlossaryError(f"cannot read the glossary {path}: {error}")
        glossary = cls(data.get("doNotTranslate", []), data.get("terms", []))
        problems = glossary.problems()
        if problems:
            raise GlossaryError(f"the glossary {path} is malformed: " + "; ".join(problems))
        return glossary

    def problems(self):
        """The sentences that say what is wrong with the glossary's shape: a name that is not text, a term without text, a
        term listed twice, a translation without its text, or a `check` that is not true or false."""
        problems = []
        for name in self.names:
            if not (isinstance(name, str) and name.strip()):
                problems.append(f"doNotTranslate holds {name!r}, which is not a name")
        seen = set()
        for term in self.terms:
            label = term.get("term") if isinstance(term, dict) else term
            if not (isinstance(label, str) and label.strip()):
                problems.append(f"a term has no `term` text: {term!r}")
                continue
            if label in seen:
                problems.append(f"the term {label!r} is listed twice")
            seen.add(label)
            translations = term.get("translations", {})
            if not isinstance(translations, dict):
                problems.append(f"the term {label!r}: `translations` must be an object by language")
                continue
            for language, entry in translations.items():
                if not (isinstance(entry, dict) and isinstance(entry.get("text"), str) and entry["text"].strip()):
                    problems.append(f"the term {label!r} in {language}: needs a `text`")
                elif not isinstance(entry.get("check", False), bool):
                    problems.append(f"the term {label!r} in {language}: `check` must be true or false")
        return problems

    # ---- what a text holds ----

    def names_in(self, text):
        """The do-not-translate names `text` holds, in the glossary's order (case matters: "VoiceOver" is not "voiceover")."""
        return [name for name in self.names if _word_pattern(name).search(text)]

    def missing_names(self, english, translation):
        """The names the English holds that the translation lacks."""
        return [name for name in self.names_in(english) if not _word_pattern(name).search(translation)]

    def nothing_to_translate(self, english):
        """Whether `english` has nothing to put in another language: only do-not-translate names, placeholders, digits,
        and punctuation or symbols remain once those are taken out. Such a text may stay as the English."""
        rest = english
        for name in self.names:
            rest = _word_pattern(name).sub(" ", rest)
        for placeholder in catalog.placeholders(rest):
            rest = rest.replace(placeholder.raw, " ")
        return not any(character.isalpha() for character in rest)

    def translation_of(self, term, language):
        """The entry `{"text", "check", "note"}` of a term in `language` (or the language without its region), or None."""
        translations = term.get("translations", {})
        code = language.replace("_", "-")
        while code:
            if code in translations:
                return translations[code]
            if "-" not in code:
                return None
            code = code.rsplit("-", 1)[0]
        return None

    def terms_in(self, english, language):
        """The terms found in `english` that have a translation in `language`, as dicts for a batch: the term, its
        translation, the note (the term's, then the translation's), and `check` when a native speaker should look first.
        A term is found as a word of its own, in any case, with an optional plural `s`."""
        found = []
        for term in self.terms:
            entry = self.translation_of(term, language)
            if entry and _word_pattern(term["term"], re.IGNORECASE).search(english):
                item = {"term": term["term"], "translation": entry["text"]}
                note = " ".join(part for part in (term.get("note"), entry.get("note")) if part)
                if note:
                    item["note"] = note
                if entry.get("check"):
                    item["check"] = True
                found.append(item)
        return found

    def unused_terms(self, english, translation, language):
        """The terms of `english` whose translation `translation` does not use, as the translated text of each: a
        translation uses a term when it holds the term's text, ignoring case and accents, and as a part of a word too
        (Spanish "marcadores" holds "marcador"). Those are only a warning."""
        folded = _fold(translation)
        return [item["translation"] for item in self.terms_in(english, language) if _fold(item["translation"]) not in folded]
