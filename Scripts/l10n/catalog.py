#!/usr/bin/env python3
"""catalog.py: the model of TextMouth's String Catalog (TextMouth/Localization/Localizable.xcstrings), which the
other tools of Scripts/l10n import. Standard library only; it runs nothing and builds nothing.

What it holds:
- loading and saving a catalog in the exact layout `xcstringstool` writes (`dumps`, `Catalog.save`, `canonicalize`);
- the format specifiers of a value, read as Foundation reads them, and whether a translation's agree with the English
  (`placeholders`, `slots`, `placeholder_problems`, `compare_placeholders`);
- the plural categories of each language, from CLDR (`plural_categories`);
- the English text of the catalog, counted once per unique text in UTF-8 bytes (`Catalog.english_texts`,
  `Catalog.english_bytes`);
- the states of a translation (`unit_done`, `Catalog.status`).

Why the layout is written here and not left to `xcstringstool`: Xcode is particular about it (`"key" : value`,
two-space indents, its own key order), and a file another tool rewrote in its own layout once gave an 18,000-line
diff on the next Xcode save (Apple's developer forums). `xcstringstool sync` would be the natural owner of the
layout, but tested with Xcode 26.0.1, it writes a catalog only when it changes a value: a sync given a stringsdata
with no strings, or with strings the catalog already holds, leaves the file as it found it, in whatever layout. So
`dumps` matches `xcstringstool`'s layout byte for byte, and test_catalog.py proves it by round trip: catalogs that
`xcstringstool` wrote must come back from `dumps(loads(text))` unchanged. What the layout is (all measured):
- two-space indents and `"key" : value` (a space on both sides of the colon);
- every object's keys sorted by Unicode code point (so `Beta` comes before `apple`), at every level;
- an empty object as `{`, a blank line, and its closing brace at the object's indent;
- strings escaped as JSON requires and nothing else: `\\"`, `\\\\`, `\\b`, `\\f`, `\\n`, `\\r`, `\\t`, any other
  control character below U+0020 as `\\u00xx` in lowercase, while `/`, U+007F, U+2028, and all non-ASCII characters
  stay as they are;
- no newline after the last brace.
One thing `xcstringstool` does that this does not: two keys that are equal as Swift strings (canonically
equivalent, such as a precomposed é and e followed by U+0301) are merged into one; no key of ours is written so.
"""
import json
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# ---------------------------------------------------------------------------------------------------------------
# The layout of the file.
# ---------------------------------------------------------------------------------------------------------------

# The escapes a JSON writer has short forms for; every other control character is written as \u00xx.
_SHORT_ESCAPES = {'"': '\\"', "\\": "\\\\", "\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}
# What a string must have escaped: the quote, the backslash, and every control character below U+0020.
_NEEDS_ESCAPE = re.compile(r'["\\\x00-\x1f]')


def _escape(match):
    """The escaped form of one character `_NEEDS_ESCAPE` found."""
    character = match.group(0)
    return _SHORT_ESCAPES.get(character) or f"\\u{ord(character):04x}"


def _string(text):
    """`text` as a JSON string literal, escaped the way `xcstringstool` escapes it."""
    return '"' + _NEEDS_ESCAPE.sub(_escape, text) + '"'


def _value(value, indent):
    """`value` (the result of json.load) written at the nesting depth `indent` (a string of spaces)."""
    if isinstance(value, dict):
        inner = indent + "  "
        if not value:
            # An empty object has a blank line inside, as Foundation's pretty printer writes it.
            return "{\n\n" + indent + "}"
        members = [f"{inner}{_string(key)} : {_value(value[key], inner)}" for key in sorted(value)]
        return "{\n" + ",\n".join(members) + "\n" + indent + "}"
    if isinstance(value, list):
        inner = indent + "  "
        if not value:
            return "[\n\n" + indent + "]"
        return "[\n" + ",\n".join(inner + _value(item, inner) for item in value) + "\n" + indent + "]"
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return json.dumps(value)
    return _string(value)


def dumps(data):
    """The text of a catalog (the loaded JSON `data`) in `xcstringstool`'s layout."""
    return _value(data, "")


def loads(text):
    """The loaded JSON of a catalog's `text`."""
    return json.loads(text)


def read_text(path):
    """The text of the file `path`, exactly as written (no line ending is translated)."""
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def write_text(path, text):
    """Writes `text` to the file `path` exactly as given (no line ending is translated)."""
    with open(path, "w", encoding="utf-8", newline="") as handle:
        handle.write(text)


def write_text_atomic(path, text):
    """Writes `text` to the file `path` through a temporary file in the same folder and a rename, so a reader (or an
    interrupted run) sees the old file or the new one, never half of it. The temporary has a fixed name beside the file,
    overwritten by the next call, so no call leaves a growing pile behind."""
    target = Path(path)
    temporary = target.with_name(f".{target.name}.l10n-tmp")
    write_text(temporary, text)
    os.replace(temporary, target)


# ---------------------------------------------------------------------------------------------------------------
# Format specifiers.
# ---------------------------------------------------------------------------------------------------------------

# One format specifier as Foundation reads it, in the alternatives' order:
#   %%                     a literal percent sign;
#   %#@name@               a substitution (a stringsdict variable the catalog's plural or device forms fill);
#   %arg                   the argument of a substitution's own forms (in a variation of `substitutions`);
#   %(name)lld             Xcode 26's named form;
#   %[n$][flags][width][.precision][length]conversion   the printf form, with `n$` its position (1-based).
# The flags are `- + 0 # '`: a space is NOT one here, so "50% off" and "50 % de descuento" hold no `% o` or `% d`
# (Foundation formats only text that has an argument, and the compiler writes `%%` for a literal percent sign in a key that
# does). The width and the precision may be `*` (the next argument, an int) or `*n$` (the argument at position n); the
# precision may be empty (`%.f` and `%.d` mean `%.0f` and `%.0d`).
_STAR = r"\*(?:[1-9]\d*\$)?"
_SPECIFIER = re.compile(r"""
    %(?:
        (?P<percent>%)
      | \#@(?P<substitution>[A-Za-z_]\w*)@
      | (?P<arg>arg)(?![A-Za-z0-9_])
      | (?:\((?P<name>[A-Za-z_]\w*)\))?
        (?:(?P<position>[1-9]\d*)\$)?
        (?P<flags>[-+0\#']*)
        (?P<width>\d+|""" + _STAR + r""")?
        (?:\.(?P<precision>""" + _STAR + r"""|\d*))?
        (?P<length>hh|h|ll|l|L|q|z|t|j)?
        (?P<conversion>[@dDiuUoOxXeEfFgGaAcCsSpn])
    )""", re.VERBOSE)

# The lengths that make an integer 64 bits wide in a C vararg on Apple's 64-bit platforms (`l`, `ll`, `q`, `z`, `t`, `j`),
# and the legacy upper-case conversions that mean a `long` (`%D`, `%U`, `%O`).
_WIDE = {"l", "ll", "q", "z", "t", "j"}
_LEGACY_LONG = {"D": "d", "U": "u", "O": "o"}

# The width in bits of an integer argument by its length modifier: `h` is a short and `hh` a char (Foundation formats
# `%hd` of 40000 as -25536); no modifier is an int, and a wide one (_WIDE) is 64 bits.
_NARROW_BITS = {"hh": 8, "h": 16}

# The conversions that print an integer, with the text their type token takes: `d` and `i` are one signed integer; `u`,
# `o`, `x`, and `X` are unsigned integers that print differently (255 is `255`, `377`, `ff`, `FF`), so a translation may
# not swap them.
_INTEGER_CLASSES = {"d": "int{bits}", "i": "int{bits}", "u": "uint{bits}", "o": "uint{bits} octal",
                    "x": "uint{bits} hex", "X": "uint{bits} HEX"}

# The conversions that print a floating-point number: `f` and `F` (1.500000), `e` and `E` (1.500000e+00), `g` and `G`
# (1.5), and `a` and `A` (0x1.8p+0) are four different looks; a letter's case only changes the case of its output.
_FLOAT_CLASSES = {"f": "", "F": "", "e": " exponent", "E": " exponent", "g": " general", "G": " general",
                  "a": " hex", "A": " hex"}

# The conversions that take something other than a number, with their type token.
_OTHER_TYPES = {"@": "object", "c": "char", "C": "unichar", "s": "cstring", "S": "unistring", "p": "pointer", "n": "count"}

# The type token of the extra int argument a `*` width or precision takes.
STAR_TYPE = "int32"


def _type_of(length, conversion):
    """The type token of a printf conversion with its length modifier, which holds what Foundation does with the argument:
    an integer by its width and how it prints (`int32`, `int64`, `uint32`, `uint32 octal`, `uint32 hex`, `int16` for `%hd`,
    `int8` for `%hhd`), a floating-point number by how it prints (`double`, `double exponent`, `double general`,
    `double hex`, and the `long double` forms for `%Lf`), and the rest by their conversion letter. A legacy `%D`, `%U`, or
    `%O` is a long integer, as `%ld`, `%lu`, `%lo`."""
    if conversion in _LEGACY_LONG:
        conversion, length = _LEGACY_LONG[conversion], "l"
    if conversion in _INTEGER_CLASSES:
        bits = 64 if length in _WIDE else _NARROW_BITS.get(length, 32)
        return _INTEGER_CLASSES[conversion].format(bits=bits)
    if conversion in _FLOAT_CLASSES:
        return ("long double" if length == "L" else "double") + _FLOAT_CLASSES[conversion]
    return _OTHER_TYPES[conversion]


# The types of a number argument: the ones a plural variation can vary on (an integer or a floating-point number).
NUMBER_TYPES = frozenset(
    [_type_of(length, conversion) for length in (None, "h", "hh", "l") for conversion in _INTEGER_CLASSES]
    + [_type_of(length, conversion) for length in (None, "L") for conversion in _FLOAT_CLASSES])

# What Foundation prints when a conversion has no precision: a floating-point number (not `a`) six digits, an integer at
# least one. Used to compare a precision with a missing one (see precision_warnings).
_DEFAULT_PRECISION = {**{conversion: "6" for conversion in "fFeEgG"}, **{conversion: "1" for conversion in "diuoxX"}}


class Placeholder:
    """One format specifier of a value: `raw` as written; `position`, its explicit 1-based position or None;
    `name`, its name (a named form, or a substitution's), or None; `type`, a token such as "int64" or "object" that
    says what argument it takes (and how it prints it); `extras`, the positions (an int, or None for the next argument) of
    the extra int arguments a `*` width or precision takes, width first; `precision`, the precision as written (a bare `.`
    is "0"; a star is "*") or None; `conversion`, the conversion letter (after the legacy ones are mapped), or None for a
    substitution. Two specifiers agree when their types are equal; width, flags, and precision are formatting and do not
    count (a different precision is only a warning: see precision_warnings)."""

    def __init__(self, raw, position, name, kind, extras=(), precision=None, conversion=None):
        self.raw, self.position, self.name, self.type = raw, position, name, kind
        self.extras, self.precision, self.conversion = tuple(extras), precision, conversion

    def __repr__(self):
        return f"Placeholder({self.raw!r}, position={self.position}, name={self.name!r}, type={self.type!r})"

    def __eq__(self, other):
        return isinstance(other, Placeholder) and (self.raw, self.position, self.name, self.type) == (
            other.raw, other.position, other.name, other.type)


def _star_position(field):
    """(whether `field`, the text of a width or precision, is a star, its explicit position or None): `*` is (True, None)
    and `*2$` is (True, 2); a number or nothing is (False, None)."""
    if not field or not field.startswith("*"):
        return False, None
    return True, int(field[1:-1]) if len(field) > 1 else None


def _printf_placeholder(match):
    """The Placeholder of the printf-form specifier that the regular expression `match` found."""
    position = int(match.group("position")) if match.group("position") else None
    # The width's argument comes before the precision's, and both before the value.
    extras = []
    for field in (match.group("width"), match.group("precision")):
        is_star, star_position = _star_position(field)
        if is_star:
            extras.append(star_position)
    precision = match.group("precision")
    if precision is not None and not precision.startswith("*"):
        precision = precision or "0"
    conversion = _LEGACY_LONG.get(match.group("conversion"), match.group("conversion"))
    return Placeholder(match.group(0), position, match.group("name"), _type_of(match.group("length"), match.group("conversion")),
                       extras, precision, conversion)


def placeholders(text):
    """Every format specifier in `text`, in order, as Placeholders; `%%` is a literal percent sign and is not one,
    and a `%` that starts no specifier is plain text."""
    found = []
    for match in _SPECIFIER.finditer(text):
        if match.group("percent"):
            continue
        raw = match.group(0)
        if match.group("substitution"):
            found.append(Placeholder(raw, None, match.group("substitution"), "substitution"))
        elif match.group("arg"):
            found.append(Placeholder(raw, None, None, "substitution argument"))
        else:
            found.append(_printf_placeholder(match))
    return found


def _references(text):
    """The argument references of `text` in the order Foundation reads them, as (position, name, type, specifier) tuples:
    a `*` width or precision takes an int argument before the value it belongs to. A substitution's own `%arg` is not one."""
    references = []
    for placeholder in placeholders(text):
        if placeholder.type == "substitution argument":
            continue
        references += [(position, None, STAR_TYPE, placeholder.raw) for position in placeholder.extras]
        references.append((placeholder.position, placeholder.name, placeholder.type, placeholder.raw))
    return references


def slots(text):
    """(the slots of `text`, its problems): the slots map each argument's slot to its type, where a slot is a
    1-based argument position (an int: explicit, or counted from the unnumbered specifiers in order), or a name (a
    str: a named form or a substitution). A `*` width or precision is a slot of its own, an int taken before the value.
    The problems are sentences about specifiers that cannot be read: numbered and unnumbered ones mixed, or one position
    used for two different types. A substitution's own `%arg` is not a slot."""
    problems, result = [], {}
    references = _references(text)
    numbered = [r for r in references if r[0] is not None]
    plain = [r for r in references if r[0] is None and r[1] is None and r[2] != "substitution"]
    if numbered and plain:
        problems.append("numbered (%1$@) and unnumbered (%@) placeholders are mixed")
    counter = 0
    for position, name, kind, raw in references:
        if name is not None:
            slot = name
        elif position is not None:
            slot = position
        else:
            counter += 1
            slot = counter
        if slot in result and result[slot] != kind:
            problems.append(f"{raw} takes a {kind} where slot {slot} takes a {result[slot]}")
        result.setdefault(slot, kind)
    return result, problems


def placeholder_problems(text):
    """The sentences that say what is wrong with the placeholders of one value, none when they can be read."""
    return slots(text)[1]


def literal_pieces(text):
    """The pieces of `text` between its placeholders (and `%%`), as a list: "Open %@ in %@" is ["Open ", " in ", ""]."""
    return _SPECIFIER.sub("\0", text).split("\0")


def percent_signs(text):
    """(how many `%%` literal percent signs `text` has, how many lone `%` it has, how many placeholders it has): a lone `%`
    starts no placeholder and is not part of `%%`. In a text that is a format string (it has a placeholder or `%%`) a lone
    `%` is invalid and prints as garbage or nothing."""
    literals = other = 0
    for match in _SPECIFIER.finditer(text):
        if match.group("percent"):
            literals += 1
        else:
            other += 1
    return literals, text.count("%") - 2 * literals - other, other


def percent_problems(english, translation):
    """The sentences about the `%%` of `translation` against `english`: a different number of literal percent signs, and a
    lone `%` in a translation that is a format string (see percent_signs). A translation that has neither a placeholder nor
    a `%%` is plain text, where `%` is only a percent sign."""
    wanted, _, _ = percent_signs(english)
    got, lone, placeholders_found = percent_signs(translation)
    problems = []
    if got != wanted:
        problems.append(f"{got} literal percent sign{'s' if got != 1 else ''} (%%) where the English has {wanted}")
    if lone and (got or placeholders_found):
        problems.append("a lone % that is no placeholder: write %% for a percent sign")
    return problems


def has_number(text):
    """Whether `text` has a number placeholder (`%lld`, `%d`, `%f`, ...), which a plural variation needs."""
    return any(placeholder.type in NUMBER_TYPES for placeholder in placeholders(text))


def compare_placeholders(english, translation, may_drop_numbers=False):
    """The sentences that say how the placeholders of `translation` differ from those of `english`, none when they
    agree: the same slots with the same types. A translation may put them in another order only with positions
    (`%2$@ ... %1$@`), since unnumbered ones are taken in order. With `may_drop_numbers`, a number placeholder the
    translation leaves out is not a problem (the `one` form of a language whose `one` means exactly 1 may say "one" in
    words); one it has that the English lacks still is."""
    wanted, _ = slots(english)
    got, problems = slots(translation)
    problems = list(problems) + percent_problems(english, translation)
    for slot in sorted(set(wanted) | set(got), key=lambda s: (isinstance(s, str), s)):
        if slot not in got:
            if not (may_drop_numbers and wanted[slot] in NUMBER_TYPES):
                problems.append(f"missing placeholder {_describe(slot, wanted[slot])}")
        elif slot not in wanted:
            problems.append(f"extra placeholder {_describe(slot, got[slot])}")
        elif wanted[slot] != got[slot]:
            problems.append(f"placeholder {slot} is a {got[slot]}, the English's is a {wanted[slot]}")
    return problems


def _precisions(text):
    """{slot: the precision of the specifier at that slot} for the numeric specifiers of `text` whose precision is known: the
    one written, else the conversion's default (six digits for a float, one for an integer). A specifier whose slot cannot
    be told (mixed numbering) or whose precision is a `*` (an argument) is left out. Slots are numbered as in `slots`."""
    result, counter = {}, 0
    for placeholder in placeholders(text):
        if placeholder.type == "substitution argument":
            continue
        # A star's own int argument takes a slot before the value's.
        counter += sum(1 for position in placeholder.extras if position is None)
        if placeholder.name is not None:
            slot = placeholder.name
        elif placeholder.position is not None:
            slot = placeholder.position
        else:
            counter += 1
            slot = counter
        precision = placeholder.precision or _DEFAULT_PRECISION.get(placeholder.conversion)
        if precision is not None and precision != "*":
            result.setdefault(slot, precision)
    return result


def precision_warnings(english, translation):
    """The sentences about a number placeholder of `translation` that prints a different number of digits than the
    English's (`%.1f` against `%.3f`, or `%f` against `%.1f`), as warnings: a language may well want another precision, so
    it is never a refusal, only worth a look. The slots compared are those both texts have with the same type."""
    wanted, got = _precisions(english), _precisions(translation)
    wanted_types, got_types = slots(english)[0], slots(translation)[0]
    return [f"placeholder {slot} prints {got[slot]} digits where the English's prints {wanted[slot]}"
            for slot in sorted(set(wanted) & set(got), key=lambda s: (isinstance(s, str), s))
            if wanted[slot] != got[slot] and wanted_types.get(slot) == got_types.get(slot)]


def _describe(slot, kind):
    """A slot and its type, for a sentence."""
    return f"{slot} ({kind})" if isinstance(slot, str) else f"number {slot} ({kind})"


# ---------------------------------------------------------------------------------------------------------------
# Plural categories.
# ---------------------------------------------------------------------------------------------------------------

# The plural categories each language uses, from CLDR's cardinal plural rules: the file
# common/supplemental/plurals.xml of github.com/unicode-org/cldr at the tag `release-49` (published October 21, 2026;
# the file's own header names no release), whose chart is
# https://www.unicode.org/cldr/charts/49/supplemental/language_plural_rules.html. Every language below was checked against
# that file on November 18, 2026 (Galician has `many`, as Catalan and Italian do; Vietnamese has `one`, which covers 0 and 1,
# since release 49). Each family below shares one rule. A test (test_catalog.PluralTableTests) keeps the table.
_ONE_OTHER = ("one", "other")
_ONE_MANY_OTHER = ("one", "many", "other")
_ONLY_OTHER = ("other",)
_SLAVIC = ("one", "few", "many", "other")
PLURAL_CATEGORIES = {
    # One and other: the Germanic languages, Turkish (and its group), Finnish, Hungarian, Greek, Hindi, Bengali, Danish,
    # Urdu, Persian, ...
    **{code: _ONE_OTHER for code in ("en", "de", "nl", "sv", "da", "nb", "nn", "no", "fi", "et", "tr", "hu", "el", "hi",
                                     "bn", "af", "ur", "fa")},
    # One, many (exact millions), and other: Spanish, French, Italian, Portuguese (Brazil and Portugal), Catalan.
    **{code: _ONE_MANY_OTHER for code in ("es", "fr", "it", "pt", "pt-PT", "ca", "gl")},
    # Other alone: Chinese, Japanese, Korean, and the languages with no plural. Vietnamese too: CLDR 49 gives it a `one`
    # for 0 and 1, but Apple's Foundation (macOS 26.3, November 20, 2026) still picks `other` for every count, and
    # Foundation is what picks the form, so the table follows it (`PluralRules`, TextMouth/Localization/InterfaceText/PluralRules.swift, which InterfaceTextTests checks against Apple's rule).
    **{code: _ONLY_OTHER for code in ("ja", "zh", "zh-Hans", "zh-Hant", "ko", "id", "ms", "th", "vi")},
    # One, few, many, and other: the Slavic languages that decline by count.
    **{code: _SLAVIC for code in ("ru", "uk", "pl", "cs", "sk")},
    "ro": ("one", "few", "other"),
    "ar": ("zero", "one", "two", "few", "many", "other"),
    # Hebrew lost `many` in CLDR 42.
    "he": ("one", "two", "other"),
}


def by_language(table, language):
    """The entry of `table` ({language code: value}) for `language`: its own code first (`pt-BR`), then the code without
    its region or script (`pt`), so `pt-BR` and `es-419` use Portuguese's and Spanish's entries. Raises KeyError when the
    table has neither."""
    code = language.replace("_", "-")
    while code:
        if code in table:
            return table[code]
        if "-" not in code:
            break
        code = code.rsplit("-", 1)[0]
    raise KeyError(language)


def plural_categories(language):
    """The plural categories of `language` (a code such as "es", "pt-BR", or "zh-Hans"), in CLDR's order, as a
    tuple. A language this table lacks raises KeyError: add it with its CLDR rule."""
    try:
        return by_language(PLURAL_CATEGORIES, language)
    except KeyError:
        raise KeyError(f"no plural rule is recorded for {language!r}; add it to PLURAL_CATEGORIES from CLDR")


# CLDR's rule for the `one` category of each language that has it, as the file writes it (release 49), grouped by rule.
# They say what `one` means: "n = 1" and "i = 1 and v = 0" mean exactly the number 1; French and Portuguese's "i = 0..1"
# covers 0, Hindi's, Bengali's, and Persian's "i = 0 or n = 1" covers 0, and Russian's and Ukrainian's covers 21, 31,
# 101, and so on.
_ONE_RULE_GROUPS = {
    "n = 1": ("af", "ar", "el", "es", "hu", "nb", "nn", "no", "tr"),
    "i = 1 and v = 0": ("ca", "cs", "de", "en", "et", "fi", "gl", "it", "nl", "pl", "pt-PT", "ro", "sk", "sv", "ur"),
    "n = 1 or t != 0 and i = 0,1": ("da",),
    "i = 0..1": ("fr", "pt"),
    "i = 1 and v = 0 or i = 0 and v != 0": ("he",),
    "i = 0 or n = 1": ("hi", "bn", "fa"),
    "v = 0 and i % 10 = 1 and i % 100 != 11": ("ru", "uk"),
}
ONE_RULES = {code: rule for rule, codes in _ONE_RULE_GROUPS.items() for code in codes}


def _relation_holds(relation, value):
    """Whether one CLDR relation (`i % 10 = 1`, `n != 2..4`, `i = 0,1`) holds when every operand is `value` that is an
    integer (so `v`, `w`, `f`, `t`, `c`, and `e` are 0, and `n` and `i` are the number). Only the relations of the `one`
    rules above are read: an operand, an optional `% modulus`, `=` or `!=`, and a list of numbers and `a..b` ranges."""
    match = re.fullmatch(r"([a-z]) (?:% (\d+) )?(!?=) (.+)", relation)
    operand, modulus, sign, ranges = match.groups()
    number = value if operand in "ni" else 0
    if modulus:
        number %= int(modulus)
    inside = False
    for part in ranges.split(","):
        low, _, high = part.partition("..")
        inside = inside or int(low) <= number <= int(high or low)
    return inside if sign == "=" else not inside


def one_selects(language, number):
    """Whether CLDR's rule for `one` in `language` selects the integer `number`. Raises KeyError when the language has no
    `one` rule (it has no `one` category, or is not in the table)."""
    rule = by_language(ONE_RULES, language)
    return any(all(_relation_holds(relation, number) for relation in alternative.split(" and "))
               for alternative in rule.split(" or "))


def one_is_exactly_one(language):
    """Whether `language`'s `one` form is for the number 1 and nothing else, so that its text may say "one" in words ("Un
    libro") instead of showing the number. False for French (`one` covers 0 too), Russian (21, 31, ...), Hindi, and a
    language with no `one` category. Decided from CLDR's rule on the integers up to 1000 (the rules repeat by 10, 100, ...)."""
    try:
        return [number for number in range(1001) if one_selects(language, number)] == [1]
    except KeyError:
        return False


# ---------------------------------------------------------------------------------------------------------------
# The catalog, its strings, and their states.
# ---------------------------------------------------------------------------------------------------------------

# The states in which a translation counts as done (Apple's guide to translating with agents adds machine_translated).
DONE_STATES = ("translated", "machine_translated")
# How a string's status is picked from its parts: the worst part wins. `missing` has no localization at all.
STATUS_ORDER = ("missing", "new", "needs_review", "stale", "machine_translated", "translated")
# The keys of a localization that hold forms, in the order the forms are walked.
_FORM_KEYS = ("variations", "substitutions")


class Unit:
    """One translated piece of a string: `path`, where it is inside the localization ("" for the string itself,
    "plural.one", "device.mac.plural.other", "substitutions.books.plural.one"); `category`, the plural category the
    path ends in (None when it does not end in one); `state` and `value` of its stringUnit."""

    def __init__(self, path, category, state, value):
        self.path, self.category, self.state, self.value = path, category, state, value

    def __repr__(self):
        return f"Unit({self.path!r}, {self.state!r}, {self.value!r})"

    def __eq__(self, other):
        return isinstance(other, Unit) and (self.path, self.category, self.state, self.value) == (
            other.path, other.category, other.state, other.value)


def counts_as_text(state):
    """Whether a unit in `state` is text the apps ship: every state but `new`, which Xcode (and the pack) leave out."""
    return state != "new"


def unit_done(unit):
    """Whether `unit` is a finished translation: its state is `translated` or `machine_translated`, and its value is
    not empty (an empty value ships as empty text)."""
    return unit.state in DONE_STATES and bool(unit.value.strip())


def _walk(node, path):
    """The Units under `node` (a localization, or a part of one), each with its path from the localization."""
    units = []
    if "stringUnit" in node:
        unit = node["stringUnit"]
        last = path.rsplit(".", 2)
        category = last[-1] if len(last) >= 2 and last[-2] == "plural" else None
        units.append(Unit(path, category, unit.get("state", "new"), unit.get("value", "")))
    for key in sorted(node):
        if key == "variations":
            for kind in sorted(node[key]):
                for name in sorted(node[key][kind]):
                    units += _walk(node[key][kind][name], f"{path}.{kind}.{name}" if path else f"{kind}.{name}")
        elif key == "substitutions":
            for name in sorted(node[key]):
                units += _walk(node[key][name], f"{path}.substitutions.{name}" if path else f"substitutions.{name}")
    return units


def _kind(value):
    """What JSON `value` is, as a phrase for a sentence ("null", "a number", "a list", "text", ...)."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true or false"
    if isinstance(value, (int, float)):
        return "a number"
    return {str: "text", list: "a list", dict: "an object"}.get(type(value), type(value).__name__)


def _shape_of_localization(node, where):
    """The sentences about what is not of its type in `node`, a localization (or a variation's or substitution's, which
    have the same shape), `where` being how the sentences name it: it must be an object; its `stringUnit` an object of text
    `state` and text `value`; its `variations` an object of kinds, each an object of names; its `substitutions` an
    object. The nodes below are read the same way."""
    if not isinstance(node, dict):
        return [f"{where} is {_kind(node)}, not an object"]
    problems = []
    if "stringUnit" in node:
        unit = node["stringUnit"]
        if not isinstance(unit, dict):
            problems.append(f"{where} stringUnit is {_kind(unit)}, not an object")
        else:
            problems += [f"{where} {field} is {_kind(unit[field])}, not text"
                         for field in ("state", "value") if field in unit and not isinstance(unit[field], str)]
    variations = node.get("variations", {})
    if not isinstance(variations, dict):
        problems.append(f"{where} variations is {_kind(variations)}, not an object")
        variations = {}
    for kind, names in variations.items():
        if not isinstance(names, dict):
            problems.append(f"{where} {kind} variations are {_kind(names)}, not an object")
            continue
        for name, child in names.items():
            problems += _shape_of_localization(child, f"{where} {kind}.{name}")
    substitutions = node.get("substitutions", {})
    if not isinstance(substitutions, dict):
        problems.append(f"{where} substitutions is {_kind(substitutions)}, not an object")
        substitutions = {}
    for name, child in substitutions.items():
        problems += _shape_of_localization(child, f"{where} substitution {name}")
    return problems


def _shape_of_entry(entry):
    """The sentences about what is not of its type in one string's `entry` (see Catalog.shape_problems): the entry itself,
    its `comment` (text), and its `localizations` (an object of localizations by language)."""
    if not isinstance(entry, dict):
        return [f"the entry is {_kind(entry)}, not an object"]
    problems = []
    if "comment" in entry and not isinstance(entry["comment"], str):
        problems.append(f"the comment is {_kind(entry['comment'])}, not text")
    localizations = entry.get("localizations", {})
    if not isinstance(localizations, dict):
        return problems + [f"localizations is {_kind(localizations)}, not an object"]
    for language, node in localizations.items():
        problems += _shape_of_localization(node, language)
    return problems


class Catalog:
    """A String Catalog:`data` is its loaded JSON (`sourceLanguage`, `strings`, `version`), `path` the file it came
    from or will be saved to (None for one made in memory)."""

    def __init__(self, data, path=None):
        self.data = data
        self.path = Path(path) if path else None

    @classmethod
    def load(cls, path):
        """The catalog in the file `path`. Raises ValueError when the file is not a catalog at all (not JSON, or JSON that is
        not an object with an object of `strings`): nothing below can read it. Strings that are broken inside are loaded, for
        shape_problems to report."""
        data = loads(read_text(path))
        if not isinstance(data, dict) or not isinstance(data.get("strings", {}), dict):
            raise ValueError("it is not a String Catalog (it needs an object with an object of strings)")
        return cls(data, path)

    def shape_problems(self):
        """{key: the sentences about what is not of its type in that string's entry}, for the keys that have any: an entry,
        a comment, a value, a state, `localizations`, or a variation or substitution that is a number, `null`, a list, or
        anything but what a catalog holds there. A hand edit makes these; the other methods would fail on them, so
        `check` reports them and reads the catalog `without` them."""
        found = {}
        for key, entry in self.strings.items():
            problems = _shape_of_entry(entry)
            if problems:
                found[key] = problems
        return found

    def without(self, keys):
        """A catalog like this one with the strings `keys` left out (the same file, nothing written)."""
        data = {**self.data, "strings": {key: entry for key, entry in self.strings.items() if key not in keys}}
        return Catalog(data, self.path)

    @classmethod
    def empty(cls, source_language="en"):
        """A catalog with no strings."""
        return cls({"sourceLanguage": source_language, "strings": {}, "version": "1.0"})

    def dumps(self):
        """The catalog's text in `xcstringstool`'s layout."""
        return dumps(self.data)

    def save(self, path=None):
        """Writes the catalog, in `xcstringstool`'s layout, to `path` (default: where it was loaded from). The file is
        rewritten only when its text changes, so a catalog that was already canonical keeps its modification time.
        Returns whether it wrote."""
        target = Path(path) if path else self.path
        text = self.dumps()
        if target.exists() and read_text(target) == text:
            return False
        write_text(target, text)
        return True

    @property
    def source_language(self):
        """The language the keys are written in."""
        return self.data.get("sourceLanguage", "en")

    @property
    def strings(self):
        """The catalog's strings: {key: entry}."""
        return self.data.setdefault("strings", {})

    # ---- what a string is ----

    @staticmethod
    def is_stale(entry):
        """Whether the compiler no longer finds the string in the code."""
        return entry.get("extractionState") == "stale"

    @staticmethod
    def should_translate(entry):
        """Whether the string is to be translated (an entry says `shouldTranslate: false` to opt out)."""
        return entry.get("shouldTranslate", True) is not False

    def translatable(self):
        """The keys that are to be translated and are not stale, sorted."""
        return sorted(key for key, entry in self.strings.items()
                      if not self.is_stale(entry) and self.should_translate(entry))

    def languages(self):
        """Every language any string has a localization in, other than the source language, sorted."""
        found = {language for entry in self.strings.values() for language in entry.get("localizations", {})}
        return sorted(found - {self.source_language})

    # ---- the English text ----

    def units(self, key, language):
        """The Units of string `key` in `language` (empty when it has no localization there)."""
        localization = self.strings[key].get("localizations", {}).get(language)
        return _walk(localization, "") if localization else []

    def english_units(self, key):
        """The Units of string `key`'s English that count as text: those of its source-language localization that are not
        in state `new` (Xcode compiles none of those, and neither does the pack) and hold a value. This is the one place
        the rule is written; `pack.compile_localization` asks `counts_as_text` of each state the same way."""
        return [unit for unit in self.units(key, self.source_language) if counts_as_text(unit.state) and unit.value]

    def english_forms(self, key):
        """The English values of string `key`, one for each plural, device, or substitution form its source-language
        localization holds (see english_units); none for an
        entry with no English, which `check` reports (the key is an ID, never the English)."""
        return [unit.value for unit in self.english_units(key)]

    def english_texts(self):
        """The English text of the catalog: the set of `english_forms` of every string that is to be translated and is
        not stale, so a text that two strings share counts once."""
        texts = set()
        for key in self.translatable():
            texts.update(self.english_forms(key))
        return texts

    def english_bytes(self):
        """The size of the English text in UTF-8 bytes, each unique text once (see english_texts)."""
        return sum(len(text.encode("utf-8")) for text in self.english_texts())

    # ---- states ----

    def status(self, key, language):
        """The status of string `key` in `language`: the worst of its units' (see STATUS_ORDER). It is `missing` with no
        localization, `new` when a unit is new or holds no value, `needs_review` or `stale` when one is, and
        `machine_translated` when every unit is done and one was made by machine; `translated` when all are done by
        hand. A stale string keeps the status its translation had: whether it is stale is `is_stale`'s."""
        units = self.units(key, language)
        if not units:
            return "missing"
        worst = len(STATUS_ORDER)
        for unit in units:
            state = unit.state if unit.state in STATUS_ORDER else "new"
            if not unit.value.strip():
                state = "new"
            worst = min(worst, STATUS_ORDER.index(state))
        return STATUS_ORDER[worst]

    def done(self, key, language):
        """Whether string `key` is translated into `language`: every unit finished (see unit_done)."""
        units = self.units(key, language)
        return bool(units) and all(unit_done(unit) for unit in units)


def canonicalize(path):
    """Rewrites the catalog file `path` in `xcstringstool`'s layout without changing a value; returns whether the file
    changed. (`xcstringstool sync` cannot do it: it writes only when it changes a value. See the module's note.)"""
    return Catalog.load(path).save()
