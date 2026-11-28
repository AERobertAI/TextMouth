"""Sorts each string literal into a bucket, and says whether interface text is localized.

The buckets, with the first rule that puts a literal in each:

- ``ui``: an argument of a call that shows or speaks text (a SwiftUI or AppKit call);
- ``wording``: in a type or file whose name holds Wording or Vocabulary;
- ``error``: the body of errorDescription, failureReason, or recoverySuggestion;
- ``prose``: any other text of two or more words that is not code;
- ``word``: a capitalized single word outside the above (a label returned from code);
- ``rawtitle``: the raw value of an enum case that reads as a title (``case openBook = "Open Book…"``),
  which a ``title`` property returns and a file stores, so the conversion must split it in two;

and the buckets that are not interface text and are never counted:

- ``log``: the debug log, which stays English for bug reports;
- ``diag``: a parser's damage reason, technical detail seen only inside an import failure;
- ``comment``: a translators' note (the ``comment:`` argument);
- ``token``: an identifier, a key, a one-word tag;
- ``code``: a path, a pattern, a format, a name for the system, text with no letters.

``classify`` returns the bucket and the name of the rule that chose it, so a test can name both.
The counted buckets (``COUNTED``) are the interface text; each is *localized* when it is the English of an
``InterfaceText.line("<ID>", "<English>")`` call (FR39), *marked* when its line ends with the comment ``// l10n: no``
(and any reason after it), and otherwise *unlocalized*. The key of any other localizing call (``String(localized:)``,
``Text("...")``, and the others the compiler extracts) keeps its rule, ``localized-key``, so that it can be named, but
its status is ``apple-lookup``: no app ships Apple's tables since FR39 phase 8, so such a key would show itself, and
the lint refuses it (``apple_lookups.py``).
"""

from __future__ import annotations

import re
from typing import Dict, FrozenSet, List, Mapping, Optional, Tuple

from .lexer import Literal

# The buckets that are interface text, certain and probable.
CERTAIN = ("ui", "wording", "error")
PROBABLE = ("prose", "word")
# A raw value that is shown as a title and also stored: interface text with a conversion of its own.
RAW = ("rawtitle",)
COUNTED = CERTAIN + PROBABLE + RAW

# Calls whose string arguments the user sees or hears.
UI_CALLS = frozenset({
    "Text", "Button", "Label", "Toggle", "Picker", "Menu", "TextField", "SecureField", "Stepper",
    "Section", "LabeledContent", "Link", "GroupBox", "DisclosureGroup", "ProgressView", "Gauge",
    "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "help",
    "alert", "confirmationDialog", "ContentUnavailableView", "accessibilityAction",
    "accessibilityCustomContent", "accessibilityRotor", "setAccessibilityLabel", "setAccessibilityHelp",
    "setAccessibilityTitle", "setAccessibilityValue", "setAccessibilityRoleDescription", "NSMenuItem",
    "NSMenu", "addItem", "insertItem", "NSButton", "NSTextField", "announce", "Announcement", "post",
    "CommandMenu", "CommandGroup", "Tab", "TabView", "Window", "WindowGroup", "Settings",
    "searchable", "prompt", "keyboardShortcut", "badge", "toolbar", "UIAlertController", "UIAction",
    "UIAlertAction", "UIBarButtonItem", "UIMenu", "accessibilityInputLabels", "speak",
})
# Argument labels whose string is a key, a name, or a path, never interface text.
CODE_LABELS = frozenset({
    "systemImage", "systemName", "systemSymbolName", "named", "forKey", "key", "keyPath", "identifier",
    "accessibilityIdentifier", "withExtension", "ofType", "forResource", "pathExtension", "mimeType",
    "contentType", "filenameExtension", "attribute", "tag", "tagName", "selector", "path", "atPath",
    "withPath", "string", "table", "bundle", "of", "with", "separator", "separatedBy", "prefix",
    "suffix", "charactersIn", "pattern", "options", "forHTTPHeaderField", "value", "name", "id",
    "suiteName", "label", "subsystem", "category", "queue", "domain", "forName", "uniqueKey",
    "fileExtension", "filename", "fileName", "extensions", "type", "kind", "scheme", "host", "format",
})
# Calls whose string arguments are code (paths, patterns, keys), never interface text.
CODE_CALLS = frozenset({
    "URL", "URLComponents", "URLQueryItem", "NSPredicate", "NSRegularExpression", "Regex", "range",
    "replacingOccurrences", "hasPrefix", "hasSuffix", "contains", "components", "split", "firstIndex",
    "lastIndex", "NSImage", "Image", "UIImage", "Name", "UTType", "Selector", "object", "set", "bool",
    "integer", "double", "string", "array", "dictionary", "data", "removeObject", "appendingPathComponent",
    "appendingPathExtension", "appending", "deletingPathExtension", "fileURLWithPath", "CharacterSet",
    "NSAttributedString.Key", "Key", "Logger", "OSLog", "DispatchQueue", "Notification", "NSNotification",
    "Bundle", "path", "url", "UserDefaults", "NSUserActivity", "XMLParser", "attribute", "select",
    "selectFirst", "getElementsByTag", "attr", "hasAttr", "removeAttr", "addClass", "Process",
    "setenv", "getenv", "dlsym", "decode", "encode", "CodingKeys", "trimmingCharacters", "starts",
    "StaticString", "Character", "UnicodeScalar", "localizedStandardContains", "ExpressibleByStringLiteral",
})
# A call or function is a log when its name says so, but not catalog, dialog, and the like.
_LOG_NAME = re.compile(r"log|Log|print|NSLog|fatalError|precondition|assert|debugDescription|dump")
_NOT_LOG_NAME = re.compile(r"[Cc]atalog|[Dd]ialog|[Pp]rolog|[Ll]ogical|[Ll]ogin|[Ll]ogo|[Aa]nalog|[Bb]acklog")
_LOG_LEVELS = frozenset({"debug", "info", "notice", "error", "warning", "fault", "trace", "critical", "log"})
# DiagnosticLog.event(...) and friends write the debug log, never the interface.
_LOG_CALLS = frozenset({"event", "diagnostic", "transitionLog", "timerLog", "routingLog"})
# Parser damage reasons: technical detail that reaches the user only inside an import failure.
_DIAG_CALLS = frozenset({"damaged", "OLEDamage", "invalid", "invalidPackage", "missingContent", "uint32",
                         "uint16", "uint8", "slice", "require", "field", "record", "malformed", "corrupt",
                         "truncated", "unsupported"})
# Declarations whose literals are error text shown to the user.
ERROR_DECLS = frozenset({"errorDescription", "failureReason", "recoverySuggestion", "helpAnchor",
                         "localizedDescription"})
_WORDING_NAME = re.compile(r"Wording|Vocabulary")
# Type names that make interface text even when they name the log (LogsSettingsWording).
_INTERFACE_TYPE_NAME = re.compile(r"Wording|Vocabulary|Settings|View|Section|Sheet|Finder")
# An event tag at the start of a diagnostic line built outside a logging call: DATA_DIRECTORY_FOUND: ...
_LOG_TAG = re.compile(r"[A-Z][A-Z0-9]*_[A-Z0-9_]+(?::? )")
# A capitalized phrase of two or more words, such as "Skip URLs" or "Jumped to %.1f percent."
_PHRASE = re.compile(r"[A-Z][a-z]+(?: [A-Za-z'’-]+)+")
# One lowercase word, or words joined by hyphens, with its placeholders already removed.
_LOWERCASE_WORDS = re.compile(r"[a-z]+(?:-[a-z]+)*")
# A date format such as yyyy-MM-dd HH:mm, which has a doubled format letter and no real word.
_DATE_FORMAT = re.compile(r"(?=.*(?:yy|MM|dd|HH|hh|mm|ss))[yMdHhmsSEaZzGQwWDFu.:/ ,'\-]+")

# Where a literal is the key the compiler extracts, as a table of call -> (labels, first
# argument too, and whether the literal must be the whole argument).
# A SwiftUI call takes its first argument as a LocalizedStringKey, but only a bare literal is
# one: in `Text(flag ? name : "b")` the compiler picks the String overload and the text is shown
# as is, while a ternary of two literals (`Button(isNew ? "Add" : "Save")`) is read as a key and
# both branches are extracted. The Foundation initializers take only a literal, so they need
# no such check.
KeySpec = Tuple[FrozenSet[str], bool, bool]
_SWIFTUI_TITLE_CALLS = (
    "Text", "Button", "Label", "Toggle", "Picker", "Menu", "TextField", "SecureField", "Stepper",
    "Section", "LabeledContent", "Link", "GroupBox", "DisclosureGroup", "ProgressView", "Gauge",
    "NavigationLink", "ContentUnavailableView", "Tab", "Window", "WindowGroup", "CommandMenu",
    "DatePicker", "ShareLink", "ControlGroup", "navigationTitle", "navigationSubtitle",
    "accessibilityLabel", "accessibilityHint", "accessibilityValue", "help", "alert",
    "confirmationDialog", "badge", "accessibilityRotor", "accessibilityCustomContent",
    "accessibilityInputLabels",
)
KEY_CALLS: Dict[str, KeySpec] = {
    **{name: (frozenset(), True, True) for name in _SWIFTUI_TITLE_CALLS},
    "accessibilityAction": (frozenset({"named"}), False, True),
    "searchable": (frozenset({"prompt"}), False, True),
    "String": (frozenset({"localized", "defaultValue"}), False, False),
    "AttributedString": (frozenset({"localized"}), False, False),
    "LocalizedStringResource": (frozenset({"defaultValue"}), True, False),
    "LocalizedStringKey": (frozenset({"stringLiteral"}), True, False),
    "LocalizationValue": (frozenset({"stringLiteral"}), True, False),
}

# The SwiftUI calls whose first literal is a key the compiler extracts but that can carry no comment of their own (only
# `Text` takes `comment:`): the calls of the table above that take no label.
SWIFTUI_KEY_CALLS = frozenset(name for name, (labels, positional, _whole) in KEY_CALLS.items() if positional and not labels
                              and name in _SWIFTUI_TITLE_CALLS)
# What `show` tells the converter about such a literal.
NEEDS_COMMENT_HELP = ("a SwiftUI literal key, which reads Apple's tables that no app ships: move it into a wording static "
                      "as `InterfaceText.line(\"<ID>\", \"<English>\")` with a `// Translators: ...` line above it")
# How far past a literal `call_has_comment` reads for the call's closing parenthesis.
_COMMENT_SCAN_LIMIT = 800

# The marker that leaves a literal out of the lint: `// l10n: no`, alone or followed by anything
# (a reason in parentheses, after a comma, a colon, a dash, or in plain words), to the end of the
# line. The word boundary keeps `// l10n: nothing` from marking.
MARKER = re.compile(r"//\s*l10n:\s*no\b.*$")
# A raw value that reads as a title: it starts with a capital and holds a lowercase letter, so
# "Open Book…", "Title", and "Audio Editor: Undo" count, but "MP3", "h", and "webvtt" do not.
_RAW_TITLE = re.compile(r"[A-Z].*[a-z]", re.S)
# What each finding means for the conversion, for the report and for `show`.
FINDING_HELP = {
    "glued": "a sentence built from pieces: make it one localized string with placeholders",
    "plural": "a hand-built plural: use a plural variation of one localized string",
    "static-let": "interface text kept in a static let: make it a computed static var, so it is read in the current language",
    "raw-title": "keep the raw value as the stored identifier, mark it `// l10n: no (stored id)`, "
                 "and add a localized title that the title property returns",
}
# A count compared with one before a ?, the start of a hand-built plural.
_PLURAL_TERNARY = re.compile(r"(?:[=!]=|>)\s*1\s*\?|>=\s*2\s*\?|<=\s*1\s*\?|<\s*2\s*\?")
_PLURAL_LABELS = frozenset({"singular", "plural"})
_PLURAL_CALLS = frozenset({"phrase", "Noun"})


class Localizer:
    """Says whether a literal is the key of a call whose literals the compiler extracts.

    ``resource_params`` maps the name of a function declared with a parameter typed
    ``LocalizedStringResource`` or ``String.LocalizationValue`` to those parameters, each as
    (external label or None, position), so that a literal passed to one counts as localized.
    """

    def __init__(self, resource_params: Optional[Mapping[str, List[Tuple[Optional[str], int]]]] = None) -> None:
        self.resource_params = resource_params or {}

    def is_key(self, lit: Literal) -> bool:
        """Whether the literal is localized by the call it is an argument of."""
        if lit.in_interp or lit.call is None or lit.label == "comment":
            return False
        if is_interface_text_english(lit):
            return True
        spec = KEY_CALLS.get(lit.call)
        if spec is not None:
            labels, positional, whole = spec
            # A labelled key, or the first argument when it takes one unlabelled.
            if lit.label in labels or (positional and lit.label is None and lit.arg_index == 0):
                return not whole or lit.whole_arg
        for label, index in self.resource_params.get(lit.call, ()):
            if (label is None and lit.label is None and lit.arg_index == index) or \
                    (label is not None and lit.label == label):
                return True
        return False


def is_interface_text_english(lit: Literal) -> bool:
    """Whether the literal is the English of an `InterfaceText.line(id, english)` call (FR39): the call's second argument,
    unlabelled. TextMouth's own lookup localizes it, so it counts as localized as the key of `String(localized:)` does."""
    return lit.call == "line" and lit.receiver == "InterfaceText" and lit.label is None and lit.arg_index == 1


def _is_log_name(name: Optional[str]) -> bool:
    """Whether a call or declaration name says it logs."""
    return bool(name) and bool(_LOG_NAME.search(name)) and not _NOT_LOG_NAME.search(name)


def _is_log_block(name: Optional[str]) -> bool:
    """Whether a declaration around a literal says it makes log text. A wording type, a view,
    or a settings type about logs (LogsSettingsWording) makes interface text, not log text."""
    return _is_log_name(name) and not _INTERFACE_TYPE_NAME.search(name or "")


def is_wording_name(name: str) -> bool:
    """Whether a file or type name marks a wording or vocabulary type."""
    return bool(_WORDING_NAME.search(name))


def in_wording_type(lit: Literal, wording_file: bool) -> bool:
    """Whether the literal is in a Wording or Vocabulary file or type."""
    return wording_file or any(b and _WORDING_NAME.search(b) for b in lit.blocks)


def classify(lit: Literal, wording_file: bool, localizer: Localizer) -> Tuple[str, str]:
    """Returns the literal's bucket and the name of the rule that chose it."""
    text = lit.text
    # The key of a localizing call is interface text already localized, whatever it holds:
    # the compiler extracts `Text("\(a): \(b)")` and `Stepper("")` too.
    if localizer.is_key(lit):
        return "ui", "localized-key"
    # The other literals of an InterfaceText.line call (its ID, and the language of a title set) are code, never text to translate.
    if lit.call == "line" and lit.receiver == "InterfaceText":
        return "code", "interface-text-argument"
    if not any(ch.isalpha() for ch in text):
        return "code", "no-letters"
    # Logging, by the call or by the function the literal is in.
    if _is_log_name(lit.call) or lit.call in _LOG_CALLS or (lit.call in _LOG_LEVELS and _is_log_name(lit.receiver)):
        return "log", "log-call"
    if any(_is_log_block(b) for b in lit.blocks[-2:]) or any(_is_log_name(c) for c in lit.calls[1:3]):
        return "log", "log-block"
    # Text(verbatim:) shows its string as is, so a sentence there is unlocalized interface text.
    if lit.call == "Text" and lit.label == "verbatim" and not lit.in_interp:
        return "ui", "verbatim-text"
    # The words a hand-built plural is made from: CountWording.phrase(n, singular: "book", plural: "books").
    if lit.label in _PLURAL_LABELS and lit.call in _PLURAL_CALLS:
        return "word", "plural-noun"
    if lit.raw_value:
        # A raw value is a stored identifier, but one that reads as a title is also shown (the
        # shortcut table's `title` returns its rawValue), so it is interface text.
        return ("rawtitle", "raw-value-title") if _RAW_TITLE.match(text) else ("code", "raw-value")
    if lit.label == "comment":
        return "comment", "comment-label"
    # A label that usually names a key can hold a title, as in SubstitutionRule(name: "Skip URLs"):
    # a capitalized phrase is text, and goes on through the rules below.
    if lit.label in CODE_LABELS and not _PHRASE.match(text):
        return "code", "code-label"
    if lit.call in CODE_CALLS:
        return "code", "code-call"
    stripped = text.replace("%@", "").strip()
    if "://" in text or text.startswith(("/", "~/", "./", "..")) or re.fullmatch(r"[\w.+-]+@[\w.-]+", text):
        return "code", "path-or-url"
    if _DATE_FORMAT.fullmatch(text):
        return "code", "date-format"
    if re.search(r"[{}<>;=]|\\[a-z]|\$\d|\[\^", text) and not re.search(r"[A-Za-z]{3,} [A-Za-z]{3,}", text):
        return "code", "code-punctuation"
    words = [w for w in re.split(r"\s+", stripped) if any(ch.isalpha() for ch in w)]
    one_token = len(words) <= 1
    identifier_like = bool(re.fullmatch(r"[A-Za-z_][\w.\-/]*", stripped)) and (
        not stripped[:1].isupper() or "." in stripped or "_" in stripped or re.search(r"[a-z][A-Z]", stripped)
        or (stripped.isupper() and len(stripped) > 1) or len(stripped) == 1)
    if identifier_like:
        # In a wording type a lowercase word or two is a piece of a sentence ("it", "seconds",
        # "%@ and %@"), which the conversion must rebuild as whole sentences; elsewhere it is a key.
        if _LOWERCASE_WORDS.fullmatch(stripped) and in_wording_type(lit, wording_file):
            return "wording", "wording-fragment"
        return "token", "identifier"
    if _LOG_TAG.match(text):
        return "log", "log-tag"
    if lit.call in UI_CALLS:
        return "ui", "ui-call"
    if lit.decl in ERROR_DECLS or any(b in ERROR_DECLS for b in lit.blocks):
        return "error", "error-decl"
    if in_wording_type(lit, wording_file):
        return "wording", "wording-type"
    if lit.call in _DIAG_CALLS:
        return ("token", "diag-single-word") if one_token else ("diag", "diag-reason")
    if one_token:
        # A capitalized single word outside a known call: a label returned from code, often.
        return ("word", "capitalized-word") if stripped[:1].isupper() else ("token", "lowercase-word")
    return "prose", "sentence"


def status_of(lit: Literal) -> str:
    """"localized", "marked" (left out on purpose), "unlocalized", or "" for text that is not
    interface text, given the literal's bucket and rule."""
    if lit.rule == "localized-key":
        # The English of an InterfaceText.line call is localized. The key of any other localizing call (String(localized:),
        # LocalizedStringResource, a SwiftUI literal such as Text("...")) reads Apple's tables, which no app ships since the
        # switch (FR39 phase 8): it would show its key, so it is no localized text but an "apple-lookup" the lint refuses.
        return "localized" if is_interface_text_english(lit) else APPLE_LOOKUP
    if lit.bucket not in COUNTED:
        return ""
    return "marked" if is_marked(lit) else "unlocalized"


def call_has_comment(source: str, start: int) -> bool:
    """Whether the call whose argument ends at `start` in `source` has a `comment:` argument: reads on to the call's
    closing parenthesis, skipping string literals (an interpolation inside one is part of the string), and looks for
    the label `comment:` at the call's own level."""
    depth, i, end = 0, start, min(len(source), start + _COMMENT_SCAN_LIMIT)
    while i < end:
        ch = source[i]
        if ch == '"':
            # Skip a string literal, with its escapes (and its interpolations, which sit inside the escape `\(`).
            i += 1
            while i < end and source[i] != '"':
                i += 2 if source[i] == "\\" else 1
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            if depth == 0:
                return False
            depth -= 1
        elif depth == 0 and source.startswith("comment", i) and not (source[i - 1].isalnum() or source[i - 1] == "_"):
            after = source[i + len("comment"):].lstrip()
            if after.startswith(":"):
                return True
        i += 1
    return False


def needs_comment(lit: Literal, source: str, lines: Optional[List[str]] = None) -> bool:
    """Whether the literal is a SwiftUI key that the compiler extracts with no comment, which `l10n.py check` refuses
    once the file is synced: a first argument of `Text`, `Button`, `Label`, `Toggle`, `.accessibilityLabel`,
    `.accessibilityHint`, `.accessibilityValue`, `.help`, `.navigationTitle`, and the other calls of SWIFTUI_KEY_CALLS.
    Only `Text` can carry a comment (`Text("...", comment: "...")`, which is not listed); the others must move
    into a wording static. A literal marked `// l10n: no` is not listed, and neither is one with a `// Translators:` line
    above it (given the file's `lines`), which gives the catalog its comment. It is not counted unlocalized: the lint and
    the baseline do not see it."""
    if lit.rule != "localized-key" or lit.call not in SWIFTUI_KEY_CALLS or lit.label is not None or is_marked(lit):
        return False
    if lines is not None and has_note(lines, lit.line):
        return False
    return not (lit.call == "Text" and call_has_comment(source, lit.end))


# The marker of a translator's note: a line comment on the line directly above the line of the key's literal (TL15).
# `l10n.py sync` reads it into the catalog; a `comment:` argument would be compiled into the app.
NOTE_MARKER = "// Translators:"
# The status of a literal that is the key of an Apple lookup (see `status_of`).
APPLE_LOOKUP = "apple-lookup"
# What `note_problem` says, and what each asks of the code.
NOTE_PROBLEM_HELP = {
    "comment-argument": "a `comment:` argument is compiled into the app: write the note as a `// Translators: ...` line directly "
                        "above the line of the key's literal, and drop the argument",
    "missing-note": "no `// Translators: ...` line directly above the key's literal: say where the text appears and what each "
                    "placeholder holds, in one line",
    "shared-line": "another key's literal is on this line, and a note belongs to one key: start each key on a line of its own",
}


def note_text(lines: List[str], line: int) -> str:
    """The translator's note directly above the 1-based `line`: the line before it, less its indentation, must start with
    NOTE_MARKER; the note is the text after the marker, stripped. "" when there is no such line or it holds no note."""
    if not 2 <= line <= len(lines) + 1:
        return ""
    above = lines[line - 2].strip()
    return above[len(NOTE_MARKER):].strip() if above.startswith(NOTE_MARKER) else ""


def has_note(lines: List[str], line: int) -> bool:
    """Whether the 1-based `line` has a translator's note directly above it (see `note_text`)."""
    return bool(note_text(lines, line))


def note_problem(lit: Literal, lines: List[str]) -> str:
    """What is wrong with a localized call's note, or "" when nothing is: "comment-argument" for the `comment:` argument of
    a localized call (Foundation compiles it into the app); "missing-note" for a key with no `// Translators:` line
    directly above its literal. ("shared-line" is found across literals, see `shared_lines`.)"""
    if lit.label == "comment" and not lit.in_interp and lit.call in KEY_CALLS:
        return "comment-argument"
    if lit.rule == "localized-key" and not has_note(lines, lit.line):
        return "missing-note"
    return ""


def shared_lines(literals: List[Literal]) -> List[Literal]:
    """The localized keys whose line holds another key's literal (a different text): one note above the line cannot say
    which of them it is for."""
    by_line: Dict[Tuple[str, int], List[Literal]] = {}
    for lit in literals:
        if lit.rule == "localized-key":
            by_line.setdefault((lit.file, lit.line), []).append(lit)
    return [lit for group in by_line.values() if len({other.text for other in group}) > 1 for lit in group]


def is_marked(lit: Literal) -> bool:
    """Whether the line the literal ends on, or starts on, ends with ``// l10n: no``."""
    return bool(MARKER.search(lit.line_text) or MARKER.search(lit.start_line_text))


def findings_of(lit: Literal) -> List[str]:
    """What the conversion has to restructure around a literal: "glued" (a sentence built by
    joining pieces), "plural" (a hand-built plural), "static-let" (interface text kept in a
    static let, which must become a computed property so it is read in the current language),
    and "raw-title" (a raw value shown as a title, which must keep its raw value as the stored id).
    Only interface text that is localized or unlocalized has findings: a marked line has none."""
    if lit.status not in ("localized", "unlocalized"):
        return []
    found = []
    if lit.glue:
        found.append("glued")
    if lit.rule == "plural-noun" or _PLURAL_TERNARY.search(lit.start_line_text):
        found.append("plural")
    if lit.static_let:
        found.append("static-let")
    if lit.rule == "raw-value-title":
        found.append("raw-title")
    return found
