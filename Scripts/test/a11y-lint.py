#!/usr/bin/env python3
"""a11y-lint: find the SwiftUI lines a branch ADDS that a VoiceOver or braille
user could not use.

The developer is blind. Every control must be keyboard-operable, every value
spoken, nothing conveyed by sight alone, and every wording pinned by a test.
Hosted windows often do not expose accessibility to a test, so "does this new
view have a label" cannot be tested by running it. This script reads the
SwiftUI sources instead, in seconds, and only on lines the branch added (so
old code never complains and no baseline file is needed).

Usage (from anywhere inside the repository):
    python3 Scripts/test/a11y-lint.py                  # lines added since main
    python3 Scripts/test/a11y-lint.py --base team/testkit
    python3 Scripts/test/a11y-lint.py --all --counts   # audit all existing views
    python3 Scripts/test/a11y-lint.py --selftest

Exit status: 0 no ERROR (with --strict: no REVIEW either), 1 findings, 2 a
usage or git problem. A hit may be excused on its own line with a trailing
`// lint-ok: <reason>` comment (the reason is required and counted).

The engine is Scripts/test/difflint.py; this file holds only the rules. The
rules read the comment-and-string-masked code of the whole file, so they can
look at the modifiers around a hit (a SwiftUI view's accessibility modifiers
sit on the lines after it).
"""

import os
import re
import sys

# The engine lives beside this script (and importing it must not leave a
# __pycache__ folder in the repository).
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import difflint  # noqa: E402
from difflint import ERROR, REVIEW, Rule  # noqa: E402

DEFAULT_PATHS = ["TextMouth/Views", "TextMouth/App/MenuCommands.swift"]


# ---------------------------------------------------------------------------
# Reading the shape of SwiftUI code: brackets, modifier chains, statements
# ---------------------------------------------------------------------------

OPENERS = "({["
CLOSERS = ")}]"

# The standard controls: a control that VoiceOver cannot see is unusable.
CONTROL_NAMES = (r"Button|Toggle|TextField|SecureField|Picker|Slider|Stepper|"
                 r"DatePicker|TextEditor")
CONTROL_CALL = re.compile(r"\b(?:" + CONTROL_NAMES + r")\s*[({]")
CONTROL_AT_START = re.compile(r"^\s*(?:" + CONTROL_NAMES + r")\s*[({]")

# A view whose label closure is named by a Text inside it, or that carries its
# own title: an Image inside one of these is described by the text beside it.
SELF_NAMING_OWNERS = re.compile(
    r"^\s*(?:Label|Button|Menu|NavigationLink|Link|Toggle|Picker|DisclosureGroup|Section)\b")


def indent_of(line):
    """The number of leading spaces of a (code-view) line."""
    return len(line) - len(line.lstrip(" "))


def non_blank_after(lines, index, count):
    """The `count` non-blank code lines after line `index`, as one string."""
    found = []
    for line in lines[index + 1:]:
        if line.strip():
            found.append(line)
            if len(found) == count:
                break
    return "\n".join(found)


def non_blank_before(lines, index, count):
    """The `count` non-blank code lines before line `index`, as one string."""
    found = []
    for line in reversed(lines[:index]):
        if line.strip():
            found.append(line)
            if len(found) == count:
                break
    return "\n".join(reversed(found))


def match_open(lines, index):
    """For a line that starts with closing brackets (`}`, `})`, `} label: {`),
    the index of the line holding the opener of the first of them, or None.

    Counts only the leading run of closers on the line itself (anything after
    it, such as the `{` of `} label: {`, opens a new group that does not
    concern the match), then walks back across earlier lines."""
    stripped = lines[index].lstrip()
    depth = 0
    for char in stripped:
        if char in CLOSERS:
            depth += 1
        else:
            break
    if depth == 0:
        return None
    for j in range(index - 1, max(-1, index - 400), -1):
        for char in reversed(lines[j]):
            if char in CLOSERS:
                depth += 1
            elif char in OPENERS:
                depth -= 1
                if depth == 0:
                    return j
    return None


def chain_head(lines, index):
    """The index of the line where the view that line `index` modifies begins.

    SwiftUI writes a view and then its modifiers, one per line:

        Button { ... } label: { ... }
            .accessibilityHidden(true)       <- starts with `.`: go up

    A line that starts with `.` is a modifier, so the view starts higher; a
    line that starts with a closing bracket ends a closure, so the walk jumps
    to the line that opened it and carries on from there."""
    i = index
    for _ in range(400):
        stripped = lines[i].lstrip()
        if stripped[:1] == ".":
            pass                                  # a modifier: the view is above
        elif stripped[:1] in CLOSERS and stripped:
            opener = match_open(lines, i)
            if opener is None or opener >= i:
                return i
            i = opener
            continue                              # judge the opener line itself
        elif i != index or stripped:
            return i                              # a line that starts a view
        # Step up to the previous non-blank line.
        i -= 1
        while i > 0 and not lines[i].strip():
            i -= 1
        if i < 0:
            return index
    return index


def statement_extent(lines, index, start_col=0):
    """The text and last line index of the call that begins at `start_col` of
    line `index`: its parentheses and trailing closures, up to the point the
    next token is not another closure.

    `Button(action: x) { label } ` and `Button { x } label: { label }` each
    return as one piece."""
    depth = 0
    parts = []
    j = index
    col = start_col
    seen_bracket = False
    while j < len(lines) and j < index + 120:
        line = lines[j]
        k = col
        while k < len(line):
            char = line[k]
            if char in OPENERS:
                depth += 1
                seen_bracket = True
            elif char in CLOSERS:
                depth -= 1
                if depth <= 0 and seen_bracket:
                    # The call may go on in a trailing closure: look ahead.
                    rest = line[k + 1:] + "\n" + "\n".join(lines[j + 1:j + 4])
                    following = rest.lstrip()
                    if not (following.startswith("{") or following.startswith("label:")
                            or following.startswith("(")):
                        parts.append(line[col:k + 1])
                        return "\n".join(parts), j
            k += 1
        parts.append(line[col:])
        j += 1
        col = 0
    return "\n".join(parts), min(j, len(lines) - 1)


def modifier_chain_after(lines, end_index, base_indent, limit=40):
    """The text of the modifier lines that follow a statement ending on line
    `end_index` and begin at the statement's own indent (or deeper).

    A modifier at the statement's indent starts with `.`; deeper lines are the
    bodies of those modifiers' closures. The chain ends at the first line that
    is shallower, or at the same indent and not a modifier."""
    found = []
    for line in lines[end_index + 1:end_index + 1 + limit]:
        if not line.strip():
            continue
        indent = indent_of(line)
        if indent < base_indent:
            break
        if indent == base_indent and line.lstrip()[:1] not in (".", "}", ")"):
            break
        found.append(line)
    return "\n".join(found)


def modifier_chain_around(lines, index):
    """The text of the modifiers chained to the modifier on line `index`: the
    lines at its indent that start with `.`, above and below, and the lines
    nested under them."""
    base = indent_of(lines[index])
    above = []
    for j in range(index - 1, max(-1, index - 60), -1):
        line = lines[j]
        if not line.strip():
            continue
        if indent_of(line) < base:
            break
        if indent_of(line) == base and line.lstrip()[:1] not in (".", "}", ")"):
            break
        above.append(line)
    below = modifier_chain_after(lines, index, base)
    return "\n".join(list(reversed(above)) + [lines[index], below])


def enclosing_openers(lines, index, col):
    """The line indexes of the brackets that enclose position `col` of line
    `index`, nearest first (for the Image-inside-a-Button question)."""
    found = []
    depth = 0
    for j in range(index, max(-1, index - 400), -1):
        text = lines[j][:col] if j == index else lines[j]
        for char in reversed(text):
            if char in CLOSERS:
                depth += 1
            elif char in OPENERS:
                if depth == 0:
                    found.append(j)
                else:
                    depth -= 1
        if len(found) >= 6:
            break
    return found


def column_of(line, pattern):
    """The column where regex `pattern` first matches on `line`, or 0."""
    match = re.search(pattern, line)
    return match.start() if match else 0


# ---------------------------------------------------------------------------
# Excuses for the rules: True means "this hit is fine"
# ---------------------------------------------------------------------------

# What makes a tap-only row operable by VoiceOver. A view hidden from
# VoiceOver is included: VoiceOver never sees its tap gesture, so the row's
# parent must offer the actions (as SubstitutionRuleRow does); the hidden
# view is a drawing, not a control.
TAP_ACCESSIBLE = re.compile(
    r"\.accessibilityAddTraits\([^)]*isButton|\.accessibilityActions?\b|\.accessibilityElement\(|"
    r"\.accessibilityHidden\(\s*true\s*\)")
INSIDE_BUTTON = re.compile(r"\bButton\s*[({]")


def tap_has_accessible_route(lines, index):
    """An `.onTapGesture` is excused when the view also declares itself a
    button, offers accessibility actions, or builds its own accessibility
    element: in the modifiers chained to it (the lines at its indent that
    start with `.`, above and below, with the closures nested in them), or
    when it sits inside a Button (the 3 lines above open one). The next-8-lines
    window of the brief is narrowed to the chain: it also caught the NEXT
    sibling's modifiers."""
    if TAP_ACCESSIBLE.search(lines[index] + "\n" + modifier_chain_around(lines, index)):
        return True
    return INSIDE_BUTTON.search(non_blank_before(lines, index, 3)) is not None


def hides_a_control(lines, index):
    """Inverse excuse of `hidden-control`: True when the `.accessibilityHidden`
    on this line hides a standard control, on the same line or at the head of
    the modifier chain it ends."""
    line = lines[index]
    before = line[:column_of(line, r"\.accessibilityHidden")]
    if CONTROL_CALL.search(before):
        return True
    head = chain_head(lines, index) if line.lstrip()[:1] == "." else index
    return CONTROL_AT_START.match(lines[head]) is not None


def field_is_named(lines, index):
    """A control with an empty title is excused when an accessibility label
    follows within 6 code lines."""
    return re.search(
        r"\.accessibilityLabel\(", lines[index] + "\n" + non_blank_after(lines, index, 6)) is not None


# What a modifier chain may say to make an Image or a container harmless:
# hidden from VoiceOver, or its children folded away.
HIDES_OR_FOLDS = re.compile(
    r"\.accessibilityHidden\(\s*true\s*\)|\.accessibilityElement\(\s*children:\s*\.ignore")
LABELLED = re.compile(r"\.accessibilityLabel\(")
# `Button("Title")` or `Button(title)`: the title names the button.
TITLED_BUTTON = re.compile(r"\s*\w+\(\s*(?:\"|\w[\w.]*\s*[,)])")


def call_and_modifiers(lines, index, col):
    """Split the call that begins at `col` of line `index` into its own text
    (brackets and trailing closures) and its modifiers (the rest of the line
    it ends on, and the chain of modifier lines after it). Returns both."""
    extent, end = statement_extent(lines, index, col)
    chain = modifier_chain_after(lines, end, indent_of(lines[index]))
    return extent, lines[end] + "\n" + chain


def image_is_accounted_for(lines, index):
    """An Image is excused when its own modifiers hide or label it, or an
    enclosing view does: a Label (its icon), a titled or Text-bearing Button,
    Menu, or link (the text names it), or a container that is hidden or folds
    its children away."""
    col = column_of(lines[index], r"\bImage\((?:systemName:|\")")
    own, own_modifiers = call_and_modifiers(lines, index, col)
    if HIDES_OR_FOLDS.search(own_modifiers) or LABELLED.search(own_modifiers):
        return True
    for opener in enclosing_openers(lines, index, col):
        if re.search(r"\bicon:\s*\{", lines[opener]):
            return True                         # Label { ... } icon: { Image }
        head = chain_head(lines, opener)
        # The owner's own body, and the modifiers chained after it: hiding or
        # labelling counts only when chained to the owner, not when found
        # inside its body (a hidden sibling in the body hides nothing here).
        body, modifiers = call_and_modifiers(lines, head, indent_of(lines[head]))
        if HIDES_OR_FOLDS.search(modifiers):
            return True
        if re.match(r"\s*Button\b", lines[head]):
            return True                         # `icon-only-button` judges the Button
        if SELF_NAMING_OWNERS.match(lines[head]) and (
                re.search(r"\b(?:Text|Label)\(", body)
                or TITLED_BUTTON.match(lines[head].lstrip())
                or LABELLED.search(modifiers)):
            return True
    return False


def button_is_not_icon_only(lines, index):
    """The excuse of `icon-only-button`: True when the Button on this line has
    no Image, or has Text, a Label, a string title, or an accessibility label
    (in its closure or in the modifiers after it)."""
    col = column_of(lines[index], r"\bButton\s*[({]")
    extent, modifiers = call_and_modifiers(lines, index, col)
    if not re.search(r"\bImage\(", extent):
        return True                             # no icon, so not icon-only
    if re.search(r"\b(?:Text|Label)\(", extent) or TITLED_BUTTON.match(extent):
        return True
    return LABELLED.search(extent + "\n" + modifiers) is not None


def font_size_is_for_an_icon(lines, index):
    """A fixed font size on an Image sizes a symbol, not text: excused."""
    head = chain_head(lines, index) if lines[index].lstrip()[:1] == "." else index
    return "Image(" in lines[head] or "Image(" in lines[index]


# Words and signs that point at something by sight or by a gesture, which
# nothing says to a blind user. The list starts from
# A10AccessibilityTests.testNoneOfTheseHintsNamesAGestureAClickOrASign.
SIGHT_WORDS = [
    "tap", "click", "double-click", "right-click", "swipe", "hover", "context menu", "arrows",
    "see the", "above", "below", "on the (?:left|right)", "to the (?:left|right)",
    "red", "green", "blue", "yellow", "orange", "purple", "pink", "gr[ae]y",
    "Cmd",
]
# Modifier-key signs (command, shift, option, control), which a screen reader
# reads badly or not at all.
SIGHT_SIGNS = "\u2318\u21E7\u2325\u2303"
# A user-visible literal: the first argument of these views and modifiers.
_USER_TEXT_CALL = (r"(?:\bText|\bLabel|\bButton|\.accessibilityLabel|\.accessibilityHint|"
                   r"\.accessibilityValue|\.help|\.navigationTitle)")
_COLOR_WORD_PATTERN = (
    _USER_TEXT_CALL + r'\(\s*"[^"\n]*(?:(?i:\b(?:' + "|".join(SIGHT_WORDS) + r')\b)|['
    + SIGHT_SIGNS + r'])[^"\n]*"')


# ---------------------------------------------------------------------------
# The rules (the names are part of the interface)
# ---------------------------------------------------------------------------

# An empty or blank-only string handed to a label.
_EMPTY_STRING = r'"\s*"'

RULES = [
    # ---- ERROR: almost certainly a defect --------------------------------
    Rule("empty-label", ERROR,
         r"\.accessibilityLabel\(\s*(?:Text\(\s*)?" + _EMPTY_STRING,
         "an empty accessibility label makes VoiceOver say nothing for this element; "
         "give it a label, or hide a decorative view with .accessibilityHidden(true)",
         view="code_with_strings"),
    Rule("tap-gesture-only", ERROR,
         r"\.onTapGesture\b|\.gesture\(\s*TapGesture\b",
         "a tap gesture alone is invisible to VoiceOver and the keyboard; use a Button, or add "
         ".accessibilityAddTraits(.isButton) with an .accessibilityAction (see TODO A03)",
         unless=tap_has_accessible_route),
    Rule("hidden-control", ERROR,
         r"\.accessibilityHidden\(\s*true\s*\)",
         "this hides a control (Button, Toggle, TextField, Picker, Slider, Stepper) from "
         "VoiceOver; hide only decorative views",
         unless=lambda lines, i: not hides_a_control(lines, i)),
    Rule("unnamed-field", ERROR,
         r"\b(?:TextField|SecureField|Toggle|Picker|Slider|Stepper|DatePicker)\(\s*\"\s*\"\s*[,)]",
         "a control with an empty title has no name for VoiceOver; add .accessibilityLabel",
         view="code_with_strings", unless=field_is_named),

    # ---- REVIEW: suspect; a person decides -------------------------------
    Rule("unlabelled-image", REVIEW, r"\bImage\((?:systemName:|\")",
         "an Image with no label is read as its file name; hide it with "
         ".accessibilityHidden(true) if decorative, or give it an .accessibilityLabel",
         unless=image_is_accounted_for),
    Rule("icon-only-button", REVIEW, r"\bButton\s*[({]",
         "a Button whose label is only an Image has no name for VoiceOver; add "
         ".accessibilityLabel (.help alone does not reach braille reliably)",
         unless=button_is_not_icon_only),
    Rule("drag-without-keyboard", REVIEW,
         r"\.(?:onMove|onDrag|onDrop|draggable|dropDestination)\s*[({]",
         "drag and drop cannot be done by keyboard; confirm there are move up/down "
         "accessibility actions too (see TODO A03)"),
    Rule("hover-only", REVIEW, r"\.onHover\s*[({]",
         "an affordance that appears only on hover is unreachable by keyboard and VoiceOver"),
    Rule("fixed-font-size", REVIEW,
         r"\.font\(\s*(?:Font)?\.system\(\s*size:|\.font\(\s*(?:Font)?\.custom\([^)]*\bsize:",
         "a fixed font size ignores the user's text-size settings; use a text style "
         "(.font(.body)) or Font.custom(..., relativeTo:)",
         unless=lambda lines, i: "relativeTo" in lines[i] or font_size_is_for_an_icon(lines, i)),
    Rule("direct-announcement", REVIEW,
         r"NSAccessibility\.post\s*\(|AccessibilityNotification\.\w+",
         "spoken wording goes through VoiceOverAnnouncer (focus moves through VoiceOverFocus) "
         "so a test can pin it; do not post accessibility notifications directly"),
    Rule("color-word", REVIEW, _COLOR_WORD_PATTERN,
         "user-visible text must not point at something by sight or by gesture (a color, a "
         "position, a click, a tap, a key sign); say what the control does",
         view="code_with_strings"),
]

# VoiceOverAnnouncer.swift and VoiceOverFocus.swift ARE the places that post.
ANNOUNCER_FILES = {"VoiceOverAnnouncer.swift", "VoiceOverFocus.swift"}


# ---------------------------------------------------------------------------
# Self-test: one snippet that must hit and one that must not, per rule
# ---------------------------------------------------------------------------

# (rule name, snippet that must produce a hit, snippet that must not)
SELFTEST_CASES = [
    ("empty-label", 'Image(x)\n    .accessibilityLabel("")', 'Image(x)\n    .accessibilityLabel("Skipped")'),
    ("empty-label", 'Text("a").accessibilityLabel(Text(""))', 'Text("a").accessibilityLabel(Text("b"))'),
    ("empty-label", 'v.accessibilityLabel("  ")', 'v.accessibilityLabel(label)'),
    ("tap-gesture-only", "Row()\n    .onTapGesture { open() }\n    .opacity(1)",
     "Row()\n    .onTapGesture { open() }\n    .accessibilityAddTraits(.isButton)"),
    ("tap-gesture-only", "Row()\n    .onTapGesture { open() }",
     "Row()\n    .accessibilityAction(named: \"Open\") { open() }\n    .onTapGesture { open() }"),
    ("tap-gesture-only", "Row()\n    .onTapGesture(count: 2) { open() }",
     "Row()\n    .onTapGesture { open() }\n    .accessibilityElement(children: .combine)"),
    ("tap-gesture-only", "Row()\n    .onTapGesture { open() }",
     "Row()\n    .onTapGesture { open() }\n    .accessibilityHidden(true)"),
    ("tap-gesture-only", "Text(x)\n    .gesture(TapGesture().onEnded { open() })",
     "Button {\n    Text(x)\n        .onTapGesture { open() }\n}"),
    ("hidden-control", "Button(\"Go\") { go() }.accessibilityHidden(true)",
     'Image(systemName: "x").accessibilityHidden(true)'),
    ("hidden-control", "Toggle(isOn: $on) { Text(\"x\") }\n    .accessibilityHidden(true)",
     "HStack {\n    Toggle(isOn: $on) { Text(\"x\") }\n}\n.accessibilityHidden(true)"),
    ("hidden-control", "Button {\n    go()\n} label: {\n    Text(\"Go\")\n}\n.buttonStyle(.plain)\n.accessibilityHidden(true)",
     "Text(\"Go\")\n    .accessibilityHidden(true)"),
    ("hidden-control", "Picker(\"Mode\", selection: $m) {\n    Text(\"a\").tag(0)\n}\n.pickerStyle(.menu)\n.accessibilityHidden(true)",
     "Divider()\n    .accessibilityHidden(true)"),
    ("unnamed-field", 'TextField("", text: $name)', 'TextField("Name", text: $name)'),
    ("unnamed-field", 'Toggle("", isOn: $on)\n    .toggleStyle(.switch)',
     'Toggle("", isOn: $on)\n    .toggleStyle(.switch)\n    .accessibilityLabel("Shuffle")'),
    ("unnamed-field", 'Picker("", selection: $m) {', 'Picker(selection: $m) {'),
    ("unlabelled-image", 'Image(systemName: "star")\n    .font(.title)', 'Image(systemName: "star")\n    .accessibilityHidden(true)'),
    ("unlabelled-image", 'HStack {\n    Image(systemName: "star")\n    Text(x)\n}',
     'Image(systemName: "star").accessibilityLabel("Starred")'),
    ("unlabelled-image", 'VStack {\n    Image("logo")\n}', 'Label("Star", systemImage: "star")'),
    ("unlabelled-image", 'Image(systemName: "star")\n    .font(.title)\nText(x)\n    .accessibilityHidden(true)',
     'Button {\n    go()\n} label: {\n    HStack {\n        Image(systemName: "star")\n        Text("Star")\n    }\n}'),
    ("unlabelled-image", 'HStack {\n    Image(systemName: "star")\n}',
     'Label {\n    Text("Star")\n} icon: {\n    Image(systemName: "star")\n}'),
    ("unlabelled-image", 'HStack {\n    Image(systemName: "star")\n}',
     'HStack {\n    Image(systemName: "star")\n}\n.accessibilityHidden(true)'),
    ("icon-only-button", 'Button {\n    go()\n} label: {\n    Image(systemName: "plus")\n}\n.buttonStyle(.plain)',
     'Button {\n    go()\n} label: {\n    Image(systemName: "plus")\n}\n.accessibilityLabel("Add")'),
    ("icon-only-button", 'Button(action: add) {\n    Image(systemName: "plus")\n}',
     'Button(action: add) {\n    Image(systemName: "plus")\n    Text("Add")\n}'),
    ("icon-only-button", 'Button(action: add) { Image(systemName: "plus") }', 'Button("Add") { add() }'),
    ("icon-only-button", 'Button(role: .destructive) {\n    remove()\n} label: {\n    Image(systemName: "trash")\n}',
     'Button {\n    Text("Go")\n}'),
    ("unlabelled-image", 'VStack {\n    Image(systemName: "x")\n    Text(y)\n        .accessibilityHidden(true)\n}', None),
    ("tap-gesture-only", "Row()\n    .onTapGesture { open() }\nText(x)\n    .accessibilityHidden(true)", None),
    ("drag-without-keyboard", "ForEach(items) { row($0) }\n    .onMove { from, to in move(from, to) }", "list.onMoveCommand { }"),
    ("drag-without-keyboard", "row.draggable(item)", "row.draggedItem(item)"),
    ("drag-without-keyboard", "view.onDrop(of: types, isTargeted: nil) { _ in true }", "view.onDropped()"),
    ("hover-only", "row.onHover { over in show = over }", "row.hoverEffect()"),
    ("fixed-font-size", "Text(x)\n    .font(.system(size: 14))", "Text(x)\n    .font(.system(.body, design: .monospaced))"),
    ("fixed-font-size", 'Text(x).font(.custom("Menlo", size: 12))', 'Text(x).font(.custom("Menlo", size: 12, relativeTo: .body))'),
    ("fixed-font-size", "Text(x)\n    .font(.system(size: 14))", 'Image(systemName: "x")\n    .font(.system(size: 44))'),
    ("direct-announcement", "NSAccessibility.post(element: w, notification: .announcementRequested)", "VoiceOverAnnouncer.announce(text)"),
    ("direct-announcement", "AccessibilityNotification.Announcement(text).post()", "let a = AccessibilityTrait.x"),
    ("color-word", 'Text("Press the red button")', 'Text("Press Stop")'),
    ("color-word", 'v.accessibilityHint("Double-click to open")', 'v.accessibilityHint("Opens the book")'),
    ("color-word", 'Text("The list above shows books")', 'Text("Shows the aboveboard books")'),
    ("color-word", 'Text("Press ⌘ + R")', 'Text("Press Command + R")'),
    ("color-word", 'v.help("Tap to play")', 'let tap = 1 // "tap"'),
    ("color-word", 'Text("Add an item on the right")', 'Text(color == .red ? "On" : "Off")'),
]


def lint(path, text, only_lines=None):
    """Lint one snippet or file with this linter's rules.

    The engine's rule hook does not know the file's path, so the one rule that
    depends on it (`direct-announcement`, allowed inside the announcer and the
    focus helper) is filtered here, for the selftest and for the command line
    alike (see the patch of difflint.lint_file below)."""
    hits = _engine_lint_file(path, text, RULES, only_lines)
    return [h for h in hits
            if not (h.rule == "direct-announcement"
                    and os.path.basename(path) in ANNOUNCER_FILES)]


# The engine calls its own lint_file for every file; route that call through
# `lint` so the per-file allowance applies on the command line too.
_engine_lint_file = difflint.lint_file


def _lint_for_engine(path, text, rules, only_lines=None):
    """Adapter with the engine's signature (it passes our RULES back)."""
    return lint(path, text, only_lines)


difflint.lint_file = _lint_for_engine


def selftest():
    """Run every canned case; print failures; return True when all pass."""
    failures = []

    def rules_hit(snippet):
        return {h.rule for h in lint("snippet.swift", snippet) if not h.suppressed}

    for rule, must_hit, must_not in SELFTEST_CASES:
        if rule not in rules_hit(must_hit):
            failures.append(f"{rule} should hit: {must_hit!r}")
        if must_not is not None and rule in rules_hit(must_not):
            failures.append(f"{rule} should not hit: {must_not!r}")

    # Every rule has at least one case.
    covered = {case[0] for case in SELFTEST_CASES}
    for rule in RULES:
        if rule.name not in covered:
            failures.append(f"{rule.name} has no selftest case")

    # lint-ok suppresses, is counted, and needs a reason.
    hits = lint("s.swift", 'v.accessibilityLabel("") // lint-ok: spoken by the parent row')
    if not (len(hits) == 1 and hits[0].suppressed):
        failures.append("lint-ok with a reason should suppress")
    hits = lint("s.swift", 'v.accessibilityLabel("") // lint-ok:')
    if not (len(hits) == 1 and not hits[0].suppressed):
        failures.append("lint-ok without a reason must not suppress")

    # A comment and a multi-line string hide their contents.
    hits = lint("s.swift", '// .accessibilityLabel("")\n/* Toggle("", isOn: x) */\nlet ok = 1')
    if hits:
        failures.append(f"a comment should hide hits: {hits}")

    # The announcer and the focus helper are the places that post.
    post = "NSAccessibility.post(element: w, notification: .announcementRequested)"
    if lint("TextMouth/Services/VoiceOverAnnouncer.swift", post):
        failures.append("direct-announcement should allow VoiceOverAnnouncer.swift")
    if not lint("TextMouth/Views/ContentView.swift", post):
        failures.append("direct-announcement should flag other files")

    # only_lines limits the check to the added lines.
    hits = lint("s.swift", 'a.accessibilityLabel("")\nb.accessibilityLabel("")', only_lines={2})
    if [h.line for h in hits] != [2]:
        failures.append("only_lines should limit the check")

    for failure in failures:
        print(f"selftest FAILED: {failure}")
    if not failures:
        print(f"a11y-lint selftest: all {len(SELFTEST_CASES)} rule cases passed")
    return not failures


if __name__ == "__main__":
    sys.exit(difflint.main(
        RULES, DEFAULT_PATHS, sys.argv[1:], selftest=selftest,
        description="Find SwiftUI code a branch adds that VoiceOver or the keyboard "
                    "cannot use."))
