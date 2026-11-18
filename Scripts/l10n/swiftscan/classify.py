"""Sorts each string literal into a bucket, and says whether interface text is localized.

The buckets, with the first rule that puts a literal in each:

- ``ui``: an argument of a call that shows or speaks text (a SwiftUI or AppKit call);
- ``wording``: in a type or file whose name holds Wording or Vocabulary;
- ``error``: the body of errorDescription, failureReason, or recoverySuggestion;
- ``prose``: any other text of two or more words that is not code;
- ``word``: a capitalized single word outside the above (a label returned from code);

and the buckets that are not interface text and are never counted:

- ``log``: the debug log, which stays English for bug reports;
- ``diag``: a parser's damage reason, technical detail seen only inside an import failure;
- ``comment``: a translators' note (the ``comment:`` argument);
- ``token``: an identifier, a key, a one-word tag;
- ``code``: a path, a pattern, a format, a name for the system, text with no letters.

``classify`` returns the bucket and the name of the rule that chose it, so a test can name both.
The counted buckets (``COUNTED``) are the interface text; each is *localized* when it is the
key of a call the compiler extracts (``String(localized:)``, ``Text("...")``, and the others),
*marked* when its line ends with ``// l10n: no``, and otherwise *unlocalized*.
"""

from __future__ import annotations

import re
from typing import Dict, FrozenSet, List, Mapping, Optional, Tuple

from .lexer import Literal

# The buckets that are interface text, certain and probable.
CERTAIN = ("ui", "wording", "error")
PROBABLE = ("prose", "word")
COUNTED = CERTAIN + PROBABLE

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
# one: in `Text(flag ? "a" : "b")` the compiler picks the String overload and the text is shown
# as is. The Foundation initializers take only a literal, so they need no such check.
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

# The marker that leaves a literal out of the lint: `// l10n: no`, alone or with a reason
# in parentheses or after a colon or a dash, at the end of the line.
MARKER = re.compile(r"//\s*l10n:\s*no(?:\s*[(:\u2014\u2013-].*)?\s*$")
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
    if not any(ch.isalpha() for ch in text):
        return "code", "no-letters"
    # Logging, by the call or by the function the literal is in.
    if _is_log_name(lit.call) or lit.call in _LOG_CALLS or (lit.call in _LOG_LEVELS and _is_log_name(lit.receiver)):
        return "log", "log-call"
    if any(_is_log_block(b) for b in lit.blocks[-2:]) or any(_is_log_name(c) for c in lit.calls[1:3]):
        return "log", "log-block"
    # The key of a localizing call is interface text already localized.
    if localizer.is_key(lit):
        return "ui", "localized-key"
    # Text(verbatim:) shows its string as is, so a sentence there is unlocalized interface text.
    if lit.call == "Text" and lit.label == "verbatim" and not lit.in_interp:
        return "ui", "verbatim-text"
    # The words a hand-built plural is made from: CountWording.phrase(n, singular: "book", plural: "books").
    if lit.label in _PLURAL_LABELS and lit.call in _PLURAL_CALLS:
        return "word", "plural-noun"
    if lit.raw_value:
        return "code", "raw-value"
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
    if lit.call in _DIAG_CALLS or "/Parsers/" in lit.file:
        return ("token", "diag-single-word") if one_token else ("diag", "diag-reason")
    if one_token:
        # A capitalized single word outside a known call: a label returned from code, often.
        return ("word", "capitalized-word") if stripped[:1].isupper() else ("token", "lowercase-word")
    return "prose", "sentence"


def status_of(lit: Literal) -> str:
    """"localized", "marked" (left out on purpose), "unlocalized", or "" for text that is not
    interface text, given the literal's bucket and rule."""
    if lit.rule == "localized-key":
        return "localized"
    if lit.bucket not in COUNTED:
        return ""
    return "marked" if is_marked(lit) else "unlocalized"


def is_marked(lit: Literal) -> bool:
    """Whether the line the literal ends on, or starts on, ends with ``// l10n: no``."""
    return bool(MARKER.search(lit.line_text) or MARKER.search(lit.start_line_text))


def findings_of(lit: Literal) -> List[str]:
    """What the conversion has to restructure around a literal: "glued" (a sentence built by
    joining pieces), "plural" (a hand-built plural), and "static-let" (interface text kept in a
    static let, which must become a computed property so it is read in the current language).
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
    return found
