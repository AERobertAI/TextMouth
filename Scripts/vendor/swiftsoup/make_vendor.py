#!/usr/bin/env python3
"""make_vendor.py: writes Vendor/SwiftSoup from a SwiftSoup release.

Usage: python3 -I Scripts/vendor/swiftsoup/make_vendor.py [--source DIR] [--output DIR] [--check]

  --source DIR  a checkout of the SwiftSoup release (the folder that holds its
                Sources and LICENSE). Default: the checkout Xcode's package
                resolution made in the main checkout's build/DerivedData,
                whose revision must be the one pinned below.
  --output DIR  where the copy goes. Default: Vendor/SwiftSoup of this checkout.
  --allow, --internal  other lists than the two beside the script (for tests).
  --check       write nothing; exit 1 if the output differs from what the
                script would write (a file differs, is missing, or is extra).

The copy is SwiftSoup's own source with ATTRIBUTES CHANGED AND NOTHING ELSE.
No statement, expression, or declaration of the parser is touched. The edits:

  1. Every `@inline(__always)` is removed. SwiftSoup's source holds hundreds of
     them; each orders the compiler to copy a helper into every caller, which
     made the whole-module build 3 MB.
  2. Every `public` or `open` is removed, so the declaration is internal,
     except for a declaration whose name is in allow-api.txt (what TextMouth
     and its tests call). Compiled as one module, the compiler can then drop
     what nothing reachable uses, the cleaner among it. Declarations listed in
     internal.txt are also made internal: they share a name with an allowed
     one (`html(accum:out:)` beside `html()`), or sit in a public type's
     signature, and the compiler refuses them public. `@inlinable` and
     `@usableFromInline`, which matter only across modules, are removed.
  3. Every class that no class of the module inherits from is marked `final`,
     so its methods need no vtable entries.

Nothing else changes, and no file is left out. test_make_vendor.py proves it:
with those attribute words taken out of both the release and the copy, and
the white space between words ignored, the two are equal.

To upgrade SwiftSoup, run this script on the new release, then SwiftSoupCorpusTests
(and Scripts/test/swiftsoup-corpus/run.py): see Vendor/SwiftSoup/README.md.
The script stops with a message when internal.txt names a line the release no
longer has, or when allow-api.txt names nothing; the compiler then says which
declarations need a change to those lists.
"""
import argparse
import os
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True

# The release this script was written for: SwiftSoup 2.13.9 (the tag's commit).
RELEASE_VERSION = "2.13.9"
RELEASE_REVISION = "18b80329749eca5ea29fc50211dca5c7eff5bfec"

HERE = Path(__file__).resolve().parent
# repo_paths.py is in Scripts/agents (two folders up); python3 -I leaves it out of sys.path.
sys.path.insert(0, str(HERE.parent.parent / "agents"))
import repo_paths  # noqa: E402  (imported by path, after sys.path is set)

# The repository this script is in (Scripts/vendor/swiftsoup/ is three folders down).
REPOSITORY = HERE.parent.parent.parent
# The main checkout, which holds the package checkout Xcode made; a linked
# worktree of the repository sits under its .claude/worktrees.
MAIN_CHECKOUT = repo_paths.main_checkout()
DEFAULT_SOURCE = MAIN_CHECKOUT / "build" / "DerivedData" / "SourcePackages" / "checkouts" / "SwiftSoup"
DEFAULT_OUTPUT = REPOSITORY / "Vendor" / "SwiftSoup"

ALLOW_LIST = HERE / "allow-api.txt"
INTERNAL_LIST = HERE / "internal.txt"

# Everything that may stand before a declaration's keyword.
MODIFIER = (r"(?:@[\w.]+(?:\([^)]*\))?|public|open|final|static|override|convenience|required|mutating|nonmutating"
            r"|nonisolated(?:\(unsafe\))?|indirect|lazy|weak|unowned(?:\(\w+\))?|private\(set\)|internal\(set\)"
            r"|fileprivate\(set\)|internal|dynamic|class(?=\s+(?:func|var|let|subscript)\b))")
# A declaration line: indentation, its modifiers, its keyword, and the rest.
DECLARATION = re.compile(
    rf"^(\s*)((?:{MODIFIER}\s+)+)(func|var|let|class|struct|enum|protocol|typealias|init|subscript|extension)\b(.*)$")
# The name a declaration declares: an identifier, or an operator.
NAME = re.compile(r"^\s*(`?[A-Za-z_][A-Za-z0-9_]*`?|[-+*/=<>!&|^~%?.]+)")
# A class declaration, to find what it inherits from.
CLASS = re.compile(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?:<[^>{]*>)?\s*(?::\s*([^{]*))?\{")
# The access words, and the attributes that only matter across modules.
ACCESS = re.compile(r"\b(?:public|open)\s+")
CROSS_MODULE = re.compile(r"@(?:inlinable|usableFromInline)\s*")
FORCED_INLINE = re.compile(r"@inline\(__always\)\s*")
# A class declared with no modifier at all.
BARE_CLASS = re.compile(r"^(\s*)class\s+([A-Za-z_][A-Za-z0-9_]*)\b(?!\s*(?:func|var|let))(.*)$")


class VendorError(Exception):
    """A problem the person upgrading must fix; the message says what."""


def read_names(path):
    """The names in a list file: one a line, `#` starting a comment."""
    names = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        name = line.split("#")[0].strip()
        if name:
            names.add(name)
    return names


def read_internal_list(path):
    """internal.txt as {file name: set of exact lines (stripped) to make internal}.

    Each entry is `File.swift: <the declaration's line as the release has it,
    without its indentation>`; `#` starts a comment line."""
    entries = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        file, _, text = line.partition(": ")
        entries.setdefault(file.strip(), set()).add(text.strip())
    return entries


def declared_name(keyword, rest):
    """The name a declaration line declares: init and subscript name themselves."""
    if keyword in ("init", "subscript"):
        return keyword
    match = NAME.match(rest)
    name = match.group(1).strip("`") if match else ""
    # `func ==<T>(...)`: the "<" opens the generic clause; it is not part of the operator.
    if len(name) > 1 and name.endswith("<") and not name[0].isalpha():
        name = name[:-1]
    return name


def internalize(line, allowed, forced_internal):
    """`line` with its `public` or `open` removed (the declaration becomes
    internal), unless its name is allowed: then `open` becomes `public`, and
    `public` stays. `forced_internal` is the set of exact stripped lines that
    lose the word whatever their name."""
    match = DECLARATION.match(line)
    if not match or not ACCESS.search(match.group(2)):
        return line
    indent, modifiers, keyword, rest = match.groups()
    keep_public = declared_name(keyword, rest) in allowed and line.strip() not in forced_internal
    replacement = "public " if keep_public else ""
    return f"{indent}{ACCESS.sub(replacement, modifiers, count=1)}{keyword}{rest}\n"


def inherited_names(texts):
    """Every simple name some class in the module inherits from or conforms to."""
    names = set()
    for text in texts.values():
        for match in CLASS.finditer(text):
            for parent in (match.group(2) or "").split(","):
                parent = parent.strip().split("<")[0].split(".")[-1].strip()
                if parent:
                    names.add(parent)
    return names


def finalize(line, parents):
    """`line` with `final` put before a class declaration nothing inherits from."""
    match = DECLARATION.match(line)
    if not match or match.group(3) != "class" or "final" in match.group(2).split():
        # A class with no modifier at all does not match DECLARATION.
        bare = BARE_CLASS.match(line)
        if bare and bare.group(2) not in parents:
            return f"{bare.group(1)}final class {bare.group(2)}{bare.group(3)}\n"
        return line
    indent, modifiers, keyword, rest = match.groups()
    if declared_name(keyword, rest) in parents or "open" in modifiers.split():
        return line
    return f"{indent}{modifiers}final {keyword}{rest}\n"


def transform(texts, allowed, internal_entries):
    """The changed copy of `texts` ({file name: text}) as {file name: text}.

    Raises VendorError when an internal.txt entry matches no line of its file."""
    parents = inherited_names(texts)
    changed = {}
    matched = {(file, entry) for file, entries in internal_entries.items() for entry in entries}
    for name, text in texts.items():
        forced = internal_entries.get(name, set())
        text = FORCED_INLINE.sub("", text)
        text = CROSS_MODULE.sub("", text)
        lines = text.splitlines(keepends=True)
        # An entry is used up when a line of its file equals it.
        for line in lines:
            matched.discard((name, line.strip()))
        lines = [internalize(line, allowed, forced) for line in lines]
        lines = [finalize(line, parents) for line in lines]
        changed[name] = "".join(lines)
    if matched:
        raise VendorError(
            "internal.txt names lines the release does not have (update the list):\n"
            + "\n".join(f"  {file}: {entry}" for file, entry in sorted(matched))
        )
    return changed


def read_exact(path):
    """The text of `path` with its line endings exactly as stored (Python's
    own reading would turn every CRLF into LF)."""
    with open(path, encoding="utf-8", newline="") as handle:
        return handle.read()


def read_release(source):
    """The release's Swift sources as {file name: text}, and its LICENSE text."""
    sources = source / "Sources"
    if not sources.is_dir():
        raise VendorError(f"{source} has no Sources folder: give --source the SwiftSoup checkout")
    texts = {path.name: read_exact(path) for path in sorted(sources.glob("*.swift"))}
    if not texts:
        raise VendorError(f"{sources} holds no Swift files")
    return texts, read_exact(source / "LICENSE")


def planned_files(source, allow_list=ALLOW_LIST, internal_list=INTERNAL_LIST):
    """The files the script writes, as {path relative to the output: text}."""
    texts, license_text = read_release(source)
    allowed = read_names(allow_list)
    changed = transform(texts, allowed, read_internal_list(internal_list))
    files = {f"Sources/{name}": text for name, text in changed.items()}
    files["LICENSE"] = license_text
    return files


def main(argv=None):
    """Writes the copy, or with --check compares it; returns the exit status."""
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--allow", type=Path, default=ALLOW_LIST, help="the allow-api list (for tests)")
    parser.add_argument("--internal", type=Path, default=INTERNAL_LIST, help="the internal list (for tests)")
    options = parser.parse_args(argv)
    try:
        files = planned_files(options.source, options.allow, options.internal)
    except VendorError as problem:
        print(f"make_vendor: {problem}", file=sys.stderr)
        return 2

    # Files already in the output that the script would not write (a file the
    # release dropped): reported, never deleted.
    existing = set()
    if options.output.is_dir():
        existing = {str(path.relative_to(options.output)) for path in options.output.glob("Sources/*.swift")}
        if (options.output / "LICENSE").exists():
            existing.add("LICENSE")
    stale = sorted(existing - set(files))
    differing = [name for name, text in sorted(files.items())
                 if not (options.output / name).exists()
                 or read_exact(options.output / name) != text]
    if options.check:
        for name in differing:
            print(f"differs: {name}")
        for name in stale:
            print(f"extra: {name}")
        print(f"{len(files)} files planned, {len(differing)} differ, {len(stale)} extra")
        return 1 if differing or stale else 0

    for name, text in files.items():
        target = options.output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        # newline="" keeps the release's line endings exactly.
        with open(target, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
    print(f"wrote {len(files)} files to {options.output} (SwiftSoup {RELEASE_VERSION}); {len(differing)} changed")
    for name in stale:
        print(f"stale (not in the release any more, delete by hand): {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
