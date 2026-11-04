#!/usr/bin/env python3
"""mac-projection.py: show what a branch changes in the code the Mac compiles.

The iOS work of phase 0 must leave the Mac app's behavior as it was. Most of
its changes are of three kinds, none of which changes what the Mac compiles:
- a file moved, unchanged, into TextMouth/Platform/macOS/;
- Mac code wrapped in `#if os(macOS)`, with iOS code in an `#else` branch;
- a type renamed to a platform alias that is that very type on the Mac
  (`PlatformWindow` is `NSWindow` there), as TextMouth/Platform/PlatformTypes.swift
  declares.

This script takes each Swift file a branch changes, keeps only what the Mac
compiles of its old and new text (the "Mac projection": every `#if` whose
condition is decided by os(), canImport(), or targetEnvironment() is resolved
as the Mac resolves it, and the platform aliases read as their Mac types), and
compares the two. Lines that leave one file and arrive in another are counted
as moved. What is left is the branch's real change to the Mac's code, for a
reviewer to read line by line.

Usage:
  mac-projection.py BASE [HEAD] [--diff] [--strict]
  mac-projection.py --self-test
  --diff    print the projected diff of every file with a real change
  --strict  exit 1 when any real change is left (for a gate)
BASE and HEAD are git refs (HEAD defaults to HEAD). Run from the checkout or
worktree that holds them.
"""
import argparse
import difflib
import re
import subprocess
import sys

sys.dont_write_bytecode = True

# Where the platform aliases are declared (any shared file directly in
# TextMouth/Platform/, PlatformTypes.swift first among them), and the pattern
# of a Mac alias in its `#if os(macOS)` branch: `typealias PlatformWindow = NSWindow`.
ALIASES_FOLDER = "TextMouth/Platform/"
ALIAS_LINE = re.compile(r"^\s*(?:public\s+|internal\s+)?typealias\s+(Platform\w+)\s*=\s*([\w.]+)\s*$")

# Shared helpers that stand, on the Mac, for exactly one Mac expression
# (TextMouth/Platform/PlatformControlStyles.swift), read as that expression.
# A helper added there gets its line here, so its calls compare as the Mac
# code they replace.
EQUIVALENCES = [
    (re.compile(r"\.checkboxToggleStyle\(\)"), ".toggleStyle(.checkbox)"),
    (re.compile(r"\.radioGroupPickerStyle\(\)"), ".pickerStyle(.radioGroup)"),
]

# The truth of each platform condition on the Mac. Anything else (DEBUG,
# swift(>=6), canImport of other modules) is left undecided, and its block is
# kept as it is.
OS_ON_MAC = {"macOS": True, "iOS": False, "tvOS": False, "watchOS": False, "visionOS": False,
             "Linux": False, "Windows": False, "Android": False, "OpenBSD": False, "FreeBSD": False}
IMPORT_ON_MAC = {"AppKit": True, "Cocoa": True, "UIKit": False, "WatchKit": False}
ENVIRONMENT_ON_MAC = {"macCatalyst": False, "simulator": False}

DIRECTIVE = re.compile(r"^\s*#(if|elseif|else|endif)\b(.*)$")
TOKEN = re.compile(r"\s*(\|\||&&|!|\(|\)|[A-Za-z_][\w.]*\s*\([^()]*\)|[A-Za-z_][\w.]*)")


class Undecided(Exception):
    """Raised when a condition depends on something the Mac does not decide here."""


def evaluate(condition):
    """The condition's truth on the Mac, or Undecided."""
    tokens, position = [], 0
    text = condition.split("//", 1)[0].strip()
    while position < len(text):
        match = TOKEN.match(text, position)
        if not match:
            raise Undecided(condition)
        tokens.append(match.group(1).replace(" ", ""))
        position = match.end()

    def atom(token):
        """One platform test, decided, or Undecided."""
        call = re.fullmatch(r"(os|canImport|targetEnvironment)\((\w+)(?:,[^)]*)?\)", token)
        if not call:
            raise Undecided(token)
        table = {"os": OS_ON_MAC, "canImport": IMPORT_ON_MAC, "targetEnvironment": ENVIRONMENT_ON_MAC}[call.group(1)]
        if call.group(2) not in table:
            raise Undecided(token)
        return table[call.group(2)]

    # A small recursive-descent parser: or := and ('||' and)*; and := unary ('&&' unary)*;
    # unary := '!' unary | '(' or ')' | atom.
    index = 0

    def parse_or():
        nonlocal index
        value = parse_and()
        while index < len(tokens) and tokens[index] == "||":
            index += 1
            right = parse_and()
            value = value or right
        return value

    def parse_and():
        nonlocal index
        value = parse_unary()
        while index < len(tokens) and tokens[index] == "&&":
            index += 1
            right = parse_unary()
            value = value and right
        return value

    def parse_unary():
        nonlocal index
        if index >= len(tokens):
            raise Undecided(condition)
        token = tokens[index]
        if token == "!":
            index += 1
            return not parse_unary()
        if token == "(":
            index += 1
            value = parse_or()
            if index >= len(tokens) or tokens[index] != ")":
                raise Undecided(condition)
            index += 1
            return value
        index += 1
        return atom(token)

    value = parse_or()
    if index != len(tokens):
        raise Undecided(condition)
    return value


def project(text):
    """The lines of `text` the Mac compiles: decided `#if` blocks resolved,
    undecided ones kept whole, directive lines of decided blocks dropped."""
    out = []
    # A stack of frames, one for each open #if: (decided, taking, taken_before,
    # parent_active). For an undecided block, decided is False and every line
    # is kept, directives included.
    stack = []

    def active():
        return all(frame["active"] for frame in stack)

    for line in text.splitlines():
        match = DIRECTIVE.match(line)
        if not match:
            if active():
                out.append(line)
            continue
        kind, rest = match.group(1), match.group(2).strip()
        if kind == "if":
            parent = active()
            try:
                truth = evaluate(rest)
                stack.append({"decided": True, "active": truth, "taken": truth, "parent": parent})
            except Undecided:
                stack.append({"decided": False, "active": True, "taken": False, "parent": parent})
                if parent:
                    out.append(line)
        elif not stack:
            # A stray directive: keep it, so the comparison shows it.
            out.append(line)
        else:
            frame = stack[-1]
            if not frame["decided"]:
                if all(f["active"] for f in stack[:-1]):
                    out.append(line)
                if kind == "endif":
                    stack.pop()
                continue
            if kind == "elseif":
                try:
                    truth = evaluate(rest)
                except Undecided:
                    truth = None
                if truth is None:
                    # A decided #if followed by an undecided #elseif: keep the
                    # whole chain from here on, undecided.
                    frame.update(decided=False, active=not frame["taken"])
                    if frame["parent"]:
                        out.append(line)
                else:
                    frame["active"] = (not frame["taken"]) and truth
                    frame["taken"] = frame["taken"] or truth
            elif kind == "else":
                frame["active"] = not frame["taken"]
                frame["taken"] = True
            elif kind == "endif":
                stack.pop()
    return out


def without_comment(line):
    """`line` without a trailing `//` comment. A line holding a quotation mark
    is left whole, since its `//` may be inside a string (a URL)."""
    if '"' in line:
        return line
    position = line.find("//")
    return line if position < 0 else line[:position]


def normalize(lines, aliases):
    """The projected lines as compared: comments, trailing space, and blank
    lines dropped (none changes what the Mac runs), and every platform alias
    read as its Mac type."""
    result = []
    for line in lines:
        line = without_comment(line).rstrip()
        if not line.strip():
            continue
        for alias, mac in aliases.items():
            line = re.sub(rf"\b{re.escape(alias)}\b", mac, line)
        for pattern, mac in EQUIVALENCES:
            line = pattern.sub(mac, line)
        result.append(line)
    return result


def git(*args, check=True):
    """Runs git and returns its standard output."""
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check).stdout


def show(ref, path):
    """A file's text at `ref`, or "" when it does not exist there."""
    result = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else ""


def aliases_at(ref):
    """The Mac type of each platform alias declared at `ref`, in the shared
    files directly in TextMouth/Platform/ (not its macOS/ or iOS/ folders)."""
    found = {}
    listing = git("ls-tree", "--name-only", f"{ref}:{ALIASES_FOLDER}", check=False).split()
    for name in listing:
        if not name.endswith(".swift"):
            continue
        for line in project(show(ref, ALIASES_FOLDER + name)):
            match = ALIAS_LINE.match(line)
            if match:
                found[match.group(1)] = match.group(2)
    return found


def changed_swift_files(base, head):
    """(old path, new path) for each Swift file changed between the refs,
    renames followed; a side that does not exist is None."""
    pairs = []
    for line in git("diff", "--name-status", "-M", f"{base}...{head}", "--", "*.swift").splitlines():
        parts = line.split("\t")
        status = parts[0]
        if status.startswith("R") or status.startswith("C"):
            pairs.append((parts[1], parts[2]))
        elif status == "A":
            pairs.append((None, parts[1]))
        elif status == "D":
            pairs.append((parts[1], None))
        else:
            pairs.append((parts[1], parts[1]))
    return pairs


def mac_compiles(path):
    """Whether the Mac app compiles a file at `path` (app sources only)."""
    return path is not None and path.startswith("TextMouth/") and not path.startswith("TextMouth/Platform/iOS/") \
        and not path.startswith("TextMouth/Resources/")


def report(base, head, show_diff):
    """Compares the Mac projections of every changed file; returns the number of real changes left."""
    old_aliases, new_aliases = aliases_at(base), aliases_at(head)
    aliases = {**old_aliases, **new_aliases}
    files = []
    for old, new in changed_swift_files(base, head):
        old_lines = normalize(project(show(base, old)), aliases) if mac_compiles(old) else []
        new_lines = normalize(project(show(head, new)), aliases) if mac_compiles(new) else []
        if not mac_compiles(old) and not mac_compiles(new):
            continue
        matcher = difflib.SequenceMatcher(a=old_lines, b=new_lines, autojunk=False)
        removed, added = [], []
        for tag, i1, i2, j1, j2 in matcher.get_opcodes():
            if tag in ("replace", "delete"):
                removed += old_lines[i1:i2]
            if tag in ("replace", "insert"):
                added += new_lines[j1:j2]
        files.append({"old": old, "new": new, "old_lines": old_lines, "new_lines": new_lines,
                      "removed": removed, "added": added})

    # Lines that left one file and arrived in another (compared without their
    # indentation) are moves, not changes.
    pool = {}
    for f in files:
        for line in f["removed"]:
            pool[line.strip()] = pool.get(line.strip(), 0) + 1
    for f in files:
        kept = []
        for line in f["added"]:
            key = line.strip()
            if pool.get(key, 0) > 0:
                pool[key] -= 1
            else:
                kept.append(line)
        f["added_real"] = kept
    left = dict(pool)
    for f in files:
        kept = []
        for line in f["removed"]:
            key = line.strip()
            if left.get(key, 0) > 0:
                kept.append(line)
                left[key] -= 1
        f["removed_real"] = kept

    identical = [f for f in files if not f["added_real"] and not f["removed_real"]]
    changed = [f for f in files if f["added_real"] or f["removed_real"]]
    print(f"# Mac projection of {head} against {base}")
    print()
    print(f"- Swift files the Mac compiles that the branch changes: {len(files)}")
    print(f"- Unchanged for the Mac (moved, guarded, or aliased only): {len(identical)}")
    print(f"- With a real change to what the Mac compiles: {len(changed)}")
    if aliases:
        print(f"- Platform aliases read as their Mac types: {', '.join(f'{a} = {m}' for a, m in sorted(aliases.items()))}")
    print()
    for f in changed:
        name = f["new"] or f["old"]
        moved_from = f" (from {f['old']})" if f["old"] and f["new"] and f["old"] != f["new"] else ""
        print(f"## {name}{moved_from}: +{len(f['added_real'])} -{len(f['removed_real'])}")
        if show_diff:
            print()
            for line in difflib.unified_diff(f["old_lines"], f["new_lines"], lineterm="", n=2,
                                             fromfile=f["old"] or "/dev/null", tofile=f["new"] or "/dev/null"):
                print(f"    {line}")
        else:
            for line in f["removed_real"][:12]:
                print(f"    - {line.strip()}")
            for line in f["added_real"][:12]:
                print(f"    + {line.strip()}")
            if len(f["removed_real"]) > 12 or len(f["added_real"]) > 12:
                print("    … (run with --diff for all)")
        print()
    return len(changed)


def self_test():
    """Checks the projection on small cases; returns 0 when every case passes."""
    cases = [
        ("plain", "a\nb\n", ["a", "b"]),
        ("mac branch kept", "#if os(macOS)\nmac\n#else\nios\n#endif\n", ["mac"]),
        ("ios branch dropped", "#if os(iOS)\nios\n#endif\nafter\n", ["after"]),
        ("negation", "#if !os(macOS)\nios\n#else\nmac\n#endif\n", ["mac"]),
        ("canImport", "#if canImport(AppKit)\nimport AppKit\n#elseif canImport(UIKit)\nimport UIKit\n#endif\n",
         ["import AppKit"]),
        ("undecided kept whole", "#if DEBUG\nd\n#else\nr\n#endif\n", ["#if DEBUG", "d", "#else", "r", "#endif"]),
        ("nested", "#if os(macOS)\n#if DEBUG\nd\n#endif\nm\n#else\n#if DEBUG\nx\n#endif\n#endif\n",
         ["#if DEBUG", "d", "#endif", "m"]),
        ("postfix modifier", "Toggle(x)\n    #if os(macOS)\n    .toggleStyle(.checkbox)\n    #else\n    .toggleStyle(.switch)\n    #endif\n",
         ["Toggle(x)", "    .toggleStyle(.checkbox)"]),
        ("and/or", "#if os(macOS) && !targetEnvironment(macCatalyst)\nm\n#endif\n#if os(iOS) || os(visionOS)\ni\n#endif\n", ["m"]),
        ("elseif chain", "#if os(iOS)\ni\n#elseif os(macOS)\nm\n#else\no\n#endif\n", ["m"]),
    ]
    failures = 0
    for name, text, expected in cases:
        got = project(text)
        if got != expected:
            failures += 1
            print(f"FAIL {name}: expected {expected}, got {got}")
    aliases = {"PlatformWindow": "NSWindow"}
    if normalize(["  func f(_ w: PlatformWindow?) {", "", "  }  "], aliases) != ["  func f(_ w: NSWindow?) {", "  }"]:
        failures += 1
        print("FAIL alias normalization")
    if normalize(["/// A doc comment.", "  // A comment.", "  let a = 1 // why", '  let u = "https://x"'], {}) != \
            ["  let a = 1", '  let u = "https://x"']:
        failures += 1
        print("FAIL comment removal")
    if normalize(["  .checkboxToggleStyle()", "  .radioGroupPickerStyle()"], {}) != \
            ["  .toggleStyle(.checkbox)", "  .pickerStyle(.radioGroup)"]:
        failures += 1
        print("FAIL helper equivalences")
    print("self-test: " + ("PASSED" if not failures else f"{failures} FAILED"))
    return 1 if failures else 0


def main(argv):
    """Parses the command line and prints the report."""
    parser = argparse.ArgumentParser(prog="mac-projection.py", description=__doc__.splitlines()[0])
    parser.add_argument("base", nargs="?")
    parser.add_argument("head", nargs="?", default="HEAD")
    parser.add_argument("--diff", action="store_true")
    parser.add_argument("--strict", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.base:
        parser.error("BASE is required")
    changed = report(args.base, args.head, args.diff)
    return 1 if (args.strict and changed) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
