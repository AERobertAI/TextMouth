#!/usr/bin/env python3
"""glossary.py: the translation glossary (Scripts/l10n/glossary.json) and the matching the translation tools do with it.
Standard library only.

The file holds two things:
- `doNotTranslate`: names that stay as written in every language (TextMouth, VoiceOver, EPUB, ...). A translation of an
  English text that has one of them must have it too (`Glossary.missing_names`), and a text with nothing but such
  names, placeholders, numbers, and punctuation may be left as the English (`Glossary.nothing_to_translate`).
- `terms`: the interface's own words with their translation per language, each `{"term": "Library", "note": "...",
  "translations": {"es": {"text": "Biblioteca", "check": true, "note": "...", "match": ["bibliotec"]}}}`. `check` marks a
  translation a native speaker should look at first; `match` (optional) lists the stems that show a translation used
  the term, for a word that inflects (without it, the `text` and its slash-separated alternatives are looked for). `todo` hands the terms found in a string's English to the translator
  (`Glossary.terms_in`), and `check` warns when a translation does not use a term's translation
  (`Glossary.unused_terms`): a warning only, since a language inflects (Spanish "marcador", "marcadores").

A language code is looked up as given, then without its region or script, so `es-419` uses Spanish's terms.

How a term is found in a text:
- never inside a do-not-translate name: "Windows-1252" is the name `Windows`, not the term `Window`;
- a term marked `"ordinary": true` is a command or an adjective that is also an everyday word (Close, Open, Done, Play, Next,
  Add, Delete, ...), so "close to the end" is not a use of Close. It is found only as a whole label ("Close", "Open...") or in
  a title-case phrase ("Close Window", "Open %@ in TextMouth"), which is how a menu item or a button is written. Nouns (Library,
  Bookmark, Chapter) are found anywhere, in any case.
"""
import functools
import json
import re
import sys
import unicodedata
from pathlib import Path

import catalog

sys.dont_write_bytecode = True

GLOSSARY_PATH = Path(__file__).resolve().parent / "glossary.json"
# The scripts that write words without spaces between them: Hangul (jamo, compatibility jamo, and syllables), the kana,
# the CJK ideographs with their extension A and compatibility forms, and the halfwidth and fullwidth forms. Japanese,
# Chinese, and Korean put a particle or the next word straight against a name ("TextMouthは", "TextMouth가", "在Mac上"),
# so a letter of these scripts beside a name never makes it part of another word.
_SPACELESS = "ᄀ-ᇿ぀-ヿ㄰-㆏㐀-䶿一-鿿가-힯豈-﫿＀-￯"
# A word character that would join a name into a longer word: any but those of the scripts above.
_JOINING = r"[^\W" + _SPACELESS + r"]"
# What may follow a name or term in a text without making it another word: an optional plural `s`, then no joining
# word character.
_WORD_END = r"(?:s)?(?!" + _JOINING + r")"


class GlossaryError(ValueError):
    """The glossary file cannot be read or is malformed; the message says where."""


def _fold(text):
    """`text` lower-cased with its accents removed, so "Biblioteca" and "bibliotecas" and "Índice" and "indice" match."""
    decomposed = unicodedata.normalize("NFD", text.casefold())
    return "".join(character for character in decomposed if not unicodedata.combining(character))


@functools.lru_cache(maxsize=None)
def _word_pattern(text, flags=0):
    """A regular expression for `text` standing as a word of its own (with an optional plural `s` after it). Japanese,
    Chinese, or Korean text right beside it counts as a word edge (see _SPACELESS); a Latin or Cyrillic letter does not.
    Kept once made: `check` asks for the same few hundred patterns millions of times, and building each again (the escape
    and re's own cache lookup) was most of its time on an eleven-language catalog."""
    return re.compile(r"(?<!" + _JOINING + r")" + re.escape(text) + _WORD_END, flags)


# The words a title-case phrase leaves in lower case ("Open Without the Index", "Open %@ in TextMouth").
_SMALL_WORDS = frozenset("a an the of to in on for and or with without from by at as into".split())
# What ends a label without being part of it: an ellipsis, a colon, and sentence punctuation.
_LABEL_END = re.compile(r"[\s.…:?!]+\Z")
_WORD = re.compile(r"[^\W\d_][\w'’]*")


def is_title_case(text):
    """Whether the words of `text` (leaving out placeholders and the small words a title keeps in lower case) all start with a
    capital letter, as a menu item or a button is written, and there is at least one: "Close Window" is, "close to the end"
    and "Close to the end" are not."""
    words = [word for word in _WORD.findall(_without_placeholders(text)) if word.casefold() not in _SMALL_WORDS]
    return bool(words) and all(word[0].isupper() for word in words)


def _without_placeholders(text):
    """`text` with its placeholders replaced by spaces."""
    return " ".join(catalog.literal_pieces(text))


def is_whole_label(text, term):
    """Whether `text` is `term` alone, in any case, with at most an ellipsis, a colon, or a sentence mark after it."""
    return _LABEL_END.sub("", text.strip()).casefold() == term.casefold()


class Glossary:
    """A glossary: `names` (the do-not-translate list) and `terms` (its entries, as loaded)."""

    def __init__(self, names=(), terms=()):
        self.names = list(names)
        self.terms = list(terms)
        # mask_names' answers by text: `check` masks the same English once for every term it looks for (4.8 million
        # times for 46,715 strings on November 20, 2026), and the names never change once a glossary is made.
        self._masked = {}

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
                elif not (isinstance(entry.get("match", []), list)
                          and all(isinstance(piece, str) and piece.strip() for piece in entry.get("match", []))):
                    problems.append(f"the term {label!r} in {language}: `match` must be a list of text")
            if not isinstance(term.get("ordinary", False), bool):
                problems.append(f"the term {label!r}: `ordinary` must be true or false")
        return problems

    def warnings(self):
        """The sentences about the glossary that are worth a look but do not make it unusable: two terms that share one
        translation in a language (a translator cannot tell them apart, as Index and Table of Contents were both Índice),
        compared in lower case and without accents."""
        warnings = []
        for language in sorted({language for term in self.terms for language in term.get("translations", {})}):
            by_text = {}
            for term in self.terms:
                entry = term.get("translations", {}).get(language)
                if entry:
                    by_text.setdefault(_fold(entry["text"]), []).append((term["term"], entry["text"]))
            for terms in by_text.values():
                if len(terms) > 1:
                    names = " and ".join(repr(name) for name, _ in terms)
                    warnings.append(f"in {language} the terms {names} share the translation {terms[0][1]!r}")
        return warnings

    # ---- what a text holds ----

    def mask_names(self, text):
        """`text` with each do-not-translate name replaced by a space, so that a term is never found inside one. A name
        whose letters the text doesn't hold can't match (the pattern is case-sensitive), so it is passed over unread."""
        if text in self._masked:
            return self._masked[text]
        masked = text
        for name in self.names:
            if name in masked:
                masked = _word_pattern(name).sub(" ", masked)
        self._masked[text] = masked
        return masked

    def term_in(self, term, english):
        """Whether `term` (a glossary entry) is found in `english`: as a word of its own, in any case, with an optional plural
        `s`, outside the do-not-translate names; and, for an `ordinary` term, only as a whole label or in a title-case phrase
        (see the module's note)."""
        text = self.mask_names(english)
        if not term.get("ordinary"):
            return bool(_word_pattern(term["term"], re.IGNORECASE).search(text))
        return is_whole_label(text, term["term"]) or (is_title_case(text) and bool(_word_pattern(term["term"]).search(text)))

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

    def found_in(self, english, language):
        """The (term, entry) pairs for the terms found in `english` that have a translation in `language` (see term_in)."""
        found = []
        for term in self.terms:
            entry = self.translation_of(term, language)
            if entry and self.term_in(term, english):
                found.append((term, entry))
        return found

    def terms_in(self, english, language):
        """The terms found in `english` that have a translation in `language`, as dicts for a batch: the term, its
        translation, the note (the term's, then the translation's), and `check` when a native speaker should look first."""
        found = []
        for term, entry in self.found_in(english, language):
            item = {"term": term["term"], "translation": entry["text"]}
            note = " ".join(part for part in (term.get("note"), entry.get("note")) if part)
            if note:
                item["note"] = note
            if entry.get("check"):
                item["check"] = True
            found.append(item)
        return found

    @staticmethod
    def fragments(entry):
        """The pieces of text any one of which shows a translation used the term: the entry's `match` list when it has one
        (stems, for a verb that inflects: "reproduc" for Reproducir), else its `text` and each alternative of it that is
        separated by a slash."""
        return entry.get("match") or [part.strip() for part in entry["text"].split("/")]

    def unused_terms(self, english, translation, language):
        """The terms of `english` whose translation `translation` does not use, as the translated text of each: a
        translation uses a term when it holds one of the entry's fragments (see `fragments`), ignoring case and accents,
        and as a part of a word too (Spanish "marcadores" holds "marcador"). Those are only a warning."""
        folded = _fold(translation)
        return [entry["text"] for _, entry in self.found_in(english, language)
                if not any(_fold(fragment) in folded for fragment in self.fragments(entry))]
