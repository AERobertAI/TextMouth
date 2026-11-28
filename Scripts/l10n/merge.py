#!/usr/bin/env python3
"""merge.py: a three-way merge of String Catalogs, by key and, inside a key, by language and form (TL12). It is the
body of the git merge driver `l10n.py merge-driver BASE OURS THEIRS PATH` (`make l10n-merge-driver` defines the driver).

Why: a catalog is one JSON file whose keys sit next to each other, so two branches that each add or translate a string
conflict as text even when they touched different strings. Merged by their parts they never do, unless two branches
changed the very same piece differently.

The model: a catalog is flattened to {path: value}, where a path is the keys from the top (`strings`, the key,
`localizations`, `es`, `variations`, `plural`, `one`, `stringUnit`) and a value is a piece that is merged whole: a text,
a number, a list, an empty object, or a `stringUnit` (its state and value together, so one side's value is never joined
to the other side's state). For each path of the three versions:
- the same on both sides: that value (a path both sides added or removed alike is taken);
- changed on one side only (base equals the other): the changed side's value, so an added or removed piece is taken;
- changed differently on both: a conflict, and ours is kept.
One exception: a key's `comment` that both sides changed is merged by its lines (see merge_comments), since it is the one
piece that several branches legitimately write for the same key (each file that uses "Cancel" adds its own comment).
A key one side deleted and the other changed is a conflict of its own (the key is not merged piece by piece), and
ours is kept as it is. After the merge, a language's
localization that holds both a plain text and plural forms (the sides wrote it two ways) is a conflict of its own, and
ours is kept whole.

Standard library only; it reads and writes only the texts it is given.
"""
import json
import sys

import catalog

sys.dont_write_bytecode = True

# Marks a path a version does not have (None is a JSON value, so it cannot stand for "absent").
ABSENT = object()
# The keys whose object is merged as one piece: a translation's state and its value belong together.
ATOMIC_KEYS = ("stringUnit",)


class Conflict:
    """One piece changed differently on both sides: `path` (the keys from the top), and its values in the base, ours, and
    theirs (ABSENT for a version that lacks it)."""

    def __init__(self, path, base, ours, theirs):
        self.path, self.base, self.ours, self.theirs = path, base, ours, theirs

    def describe(self):
        """The conflict as one sentence for standard error: where it is, and the three values."""
        def shown(value):
            """A value as compact JSON, or "(absent)"."""
            return "(absent)" if value is ABSENT else json.dumps(value, ensure_ascii=False)
        return f"{where(self.path)}: the base has {shown(self.base)}, ours {shown(self.ours)}, theirs {shown(self.theirs)}"


def where(path):
    """A path as words: the key, then its place inside it, as `"%lld books" localizations.es.variations.plural.one`."""
    path = list(path)
    if len(path) >= 2 and path[0] == "strings":
        return json.dumps(path[1], ensure_ascii=False) + (" " + ".".join(path[2:]) if len(path) > 2 else "")
    return ".".join(path) or "the catalog"


def flatten(node, path=()):
    """The pieces of `node` as {path: value}: every nested object is walked, except the objects of ATOMIC_KEYS, which are
    pieces themselves, and an empty object, which is a piece too (so it survives a merge)."""
    if isinstance(node, dict) and node and not (path and path[-1] in ATOMIC_KEYS):
        pieces = {}
        for key, value in node.items():
            pieces.update(flatten(value, path + (key,)))
        return pieces
    return {path: node}


def unflatten(pieces):
    """The nested object that `flatten` made `pieces` from. A piece that is an empty object gives way to pieces below it
    (one side added a translation to a localization the other left empty)."""
    root = {}
    for path in sorted(pieces, key=len):
        if not path:
            # The empty path is the (empty) catalog object itself, which `root` already is. Returning it here once lost
            # every other piece when a side was `{}`.
            continue
        node = root
        for key in path[:-1]:
            node = node.setdefault(key, {})
        if pieces[path] == {} and isinstance(node.get(path[-1]), dict):
            continue
        # An empty object is copied, since pieces below it are put into it.
        node[path[-1]] = {} if pieces[path] == {} else pieces[path]
    return root


def is_comment_path(path):
    """Whether `path` is a string's own comment: (`strings`, the key, `comment`)."""
    return len(path) == 3 and path[0] == "strings" and path[2] == "comment"


def comment_lines(comment):
    """The lines of a comment value (ABSENT is none)."""
    return [] if comment is ABSENT else comment.split("\n")


def merge_comments(base, ours, theirs):
    """The comment of a key that both sides changed differently, or ABSENT when no line is left; None when the values are
    not texts (the caller then reports a conflict).

    What `xcstringstool sync` writes (measured, Xcode 26): the key's distinct comments, one for each use that has one,
    sorted by code point and joined with a line break, the same whatever the order of its --stringsdata arguments, and a
    comment already in the catalog is replaced, never added to. So a merged tree's next sync writes the sorted union of
    both sides' comments, less any a side cut. This is that, by lines: a line stays when both sides have it or a side
    added it, and goes when a side dropped it from the base.

    The catalog alone cannot tell where one use's comment ends when a comment has a line break inside it, and the sync sorts
    whole comments. When a side's lines are not in sorted order, some comment must be multi-line, so the lines are not
    sorted: ours' lines come first, then theirs' lines that ours lacks. The next sync rewrites the comment either way."""
    if any(value is not ABSENT and not isinstance(value, str) for value in (base, ours, theirs)):
        return None
    was, mine, yours = comment_lines(base), comment_lines(ours), comment_lines(theirs)
    dropped = (set(was) - set(mine)) | (set(was) - set(yours))
    lines = []
    for line in mine + yours:
        if line not in dropped and line not in lines:
            lines.append(line)
    # A key's comment sorted in the sync's order is the sorted union; any other order is kept (ours, then theirs).
    if all(side == sorted(set(side)) for side in (mine, yours)):
        lines.sort()
    lines = [line for line in lines if line]
    return "\n".join(lines) if lines else ABSENT


def merge_pieces(base, ours, theirs):
    """The three-way merge of flattened versions: (the merged {path: value}, the Conflicts). Paths sort, so conflicts
    come in a stable order. A comment both sides changed is merged (merge_comments), not a conflict."""
    merged, conflicts = {}, []
    for path in sorted(set(base) | set(ours) | set(theirs)):
        was, mine, yours = base.get(path, ABSENT), ours.get(path, ABSENT), theirs.get(path, ABSENT)
        if mine == yours or yours == was:
            chosen = mine
        elif mine == was:
            chosen = yours
        else:
            both = merge_comments(was, mine, yours) if is_comment_path(path) else None
            if both is None:
                conflicts.append(Conflict(path, was, mine, yours))
                chosen = mine
            else:
                chosen = both
                if both is ABSENT:
                    # The key stays, as an entry with nothing in it: its comment was the only piece that held it.
                    merged.setdefault(path[:2], {})
        if chosen is not ABSENT:
            merged[path] = chosen
    return merged, conflicts


def two_ways_conflicts(merged, ours, theirs):
    """The Conflicts of localizations that the merge left with both a plain text and plural forms (or any other pair of
    forms a localization cannot hold together), where the sides wrote a language two ways; each is put back as ours has
    it (as theirs has it when ours has none) in `merged`, so the result is one valid localization. `merged`, `ours`, and
    `theirs` are the nested objects."""
    conflicts = []
    for key, entry in merged.get("strings", {}).items():
        if not isinstance(entry, dict) or not isinstance(entry.get("localizations"), dict):
            continue
        for language, localization in entry["localizations"].items():
            if isinstance(localization, dict) and "stringUnit" in localization and "variations" in localization:
                path = ("strings", key, "localizations", language)
                mine = dig(ours, path)
                yours = dig(theirs, path)
                entry["localizations"][language] = mine if mine is not ABSENT else yours
                conflicts.append(Conflict(path, ABSENT, mine, yours))
    return conflicts


def dig(node, path):
    """The value at `path` in the nested object `node`, or ABSENT."""
    for key in path:
        if not (isinstance(node, dict) and key in node):
            return ABSENT
        node = node[key]
    return node


def strings_of(catalog_data):
    """The `strings` object of a loaded catalog, or {} when it has none."""
    strings = catalog_data.get("strings") if isinstance(catalog_data, dict) else None
    return strings if isinstance(strings, dict) else {}


def deleted_and_changed(base, ours, theirs):
    """The keys one side deleted that the other side changed: a deletion and an edit do not merge, whatever pieces the
    edit touched, so the pieces of such a key are not merged (see merge_catalogs)."""
    before, mine, yours = strings_of(base), strings_of(ours), strings_of(theirs)
    return sorted(key for key in before
                  if (key not in mine and key in yours and yours[key] != before[key])
                  or (key not in yours and key in mine and mine[key] != before[key]))


def without_keys(catalog_data, keys):
    """A copy of the loaded catalog with the strings `keys` left out (the rest is shared, not copied)."""
    if not keys:
        return catalog_data
    return {**catalog_data, "strings": {key: value for key, value in strings_of(catalog_data).items() if key not in keys}}


def merge_catalogs(base, ours, theirs):
    """The three-way merge of three loaded catalogs (JSON objects; {} for a missing base): (the merged catalog, the
    Conflicts). Ours is kept in each conflict. A missing `strings` is an empty one."""
    # A key one side deleted and the other changed is a conflict of its own, and ours is kept as it is.
    clashes = deleted_and_changed(base, ours, theirs)
    merged_pieces, conflicts = merge_pieces(flatten(without_keys(base, clashes)), flatten(without_keys(ours, clashes)),
                                            flatten(without_keys(theirs, clashes)))
    merged = unflatten(merged_pieces)
    if not isinstance(merged, dict):
        merged = {}
    merged.setdefault("strings", {})
    for key in clashes:
        mine = strings_of(ours).get(key, ABSENT)
        conflicts.append(Conflict(("strings", key), strings_of(base)[key], mine, strings_of(theirs).get(key, ABSENT)))
        if mine is not ABSENT:
            merged["strings"][key] = mine
    conflicts += two_ways_conflicts(merged, ours, theirs)
    return merged, conflicts


# What a catalog must have for the merge to be safe: the top-level keys the tools read, and nothing else is required.
REQUIRED_KEYS = ("sourceLanguage", "version", "strings")


def check_shape(data, name):
    """Raises a ValueError naming `name` unless `data` is a catalog's shape: an object whose `strings` is an object of
    objects. A `{}` or a `{"hello": 1}` merged against a real catalog used to drop its strings without a conflict."""
    if not isinstance(data, dict):
        raise ValueError(f"{name} is not a JSON object")
    strings = data.get("strings")
    if not isinstance(strings, dict):
        raise ValueError(f"{name} has no `strings` object")
    for key, entry in strings.items():
        if not isinstance(entry, dict):
            raise ValueError(f"{name}'s string {json.dumps(key, ensure_ascii=False)} is not an object")


def load(text, name="the catalog"):
    """The catalog in `text`, or {} when it is empty (git gives an empty base for a file both branches added). A
    ValueError (naming `name`) when a non-empty text is not a JSON object of the catalog's shape."""
    if not text.strip():
        return {}
    data = catalog.loads(text)
    check_shape(data, name)
    return data


def merge_texts(base_text, ours_text, theirs_text):
    """The three-way merge of three catalog texts: (the merged text in `xcstringstool`'s layout, the Conflicts). A
    ValueError when an input is not a catalog or the result would lack a required top-level key (the caller then leaves
    ours as it is)."""
    merged, conflicts = merge_catalogs(load(base_text, "the base"), load(ours_text, "ours"), load(theirs_text, "theirs"))
    missing = [key for key in REQUIRED_KEYS if key not in merged]
    if missing:
        raise ValueError("the merged catalog would lack " + ", ".join(f"`{key}`" for key in missing))
    return catalog.dumps(merged), conflicts
