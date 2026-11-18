#!/usr/bin/env python3
"""translate.py: what the translation commands of l10n.py do to a catalog (TL12). Standard library only; it runs
nothing and builds nothing, and never reads anything but the files it is handed.

What is here:
- `write_plural`: a string's plural forms in one language, English included (the `plural` command).

Every function takes the loaded `catalog.Catalog` and changes it in memory; the commands save it. A refusal is a
`Problems` exception whose `problems` are sentences, so a command can print each one.
"""
import sys

import catalog

sys.dont_write_bytecode = True

# The states a translation may be written in (the five of Apple's guide; `stale` is the compiler's to set).
WRITABLE_STATES = ("new", "needs_review", "machine_translated", "translated")


class Problems(Exception):
    """A request that was refused: `problems` are the sentences that say why."""

    def __init__(self, problems):
        self.problems = [problems] if isinstance(problems, str) else list(problems)
        super().__init__("; ".join(self.problems))


def default_state(language, cat):
    """The state a translation is written in when none is given: English (the source) is `translated`, since it is the
    text itself; any other language is `machine_translated` until a native speaker has reviewed it."""
    return "translated" if language == cat.source_language else "machine_translated"


# ---------------------------------------------------------------------------------------------------------------
# plural
# ---------------------------------------------------------------------------------------------------------------

def plural_problems(key, language, forms):
    """The sentences that say why `forms` ({category: text}) cannot be the plural forms of `key` in `language`: a form
    the language does not use, a form it uses that is missing, an empty form, and a form whose placeholders differ from
    the key's. None when they are good."""
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
    for category in required:
        text = forms.get(category)
        if text is None:
            continue
        if not text.strip():
            problems.append(f"the {category} form is empty")
        else:
            problems += [f"the {category} form: {sentence}" for sentence in catalog.compare_placeholders(key, text)]
    return problems


def plural_localization(forms, state):
    """The localization that holds `forms` ({category: text}) as plural variations in `state`."""
    return {"variations": {"plural": {category: {"stringUnit": {"state": state, "value": text}}
                                      for category, text in forms.items()}}}


def write_plural(cat, key, language, forms, state=None):
    """Writes `forms` ({category: text}) as the plural variations of string `key` in `language`, in `state` (default:
    see default_state). Raises Problems when the key is not in the catalog, the state is not writable, the language's
    categories and the forms differ, or a form's placeholders differ from the key's; and when the language's
    localization holds other forms (device variations, substitutions) that this would replace. Returns the state."""
    if key not in cat.strings:
        raise Problems(f"the catalog has no string {key!r}; run sync after the code has it")
    state = state or default_state(language, cat)
    if state not in WRITABLE_STATES:
        raise Problems(f"the state {state!r} cannot be written (use {', '.join(WRITABLE_STATES)})")
    problems = plural_problems(key, language, forms)
    existing = cat.strings[key].get("localizations", {}).get(language, {})
    if "substitutions" in existing or set(existing.get("variations", {})) - {"plural"}:
        problems.append(f"{language}'s localization of the string holds substitutions or device variations, which a plain "
                        "plural would replace; edit it by hand")
    if problems:
        raise Problems(problems)
    cat.strings[key].setdefault("localizations", {})[language] = plural_localization(forms, state)
    return state
