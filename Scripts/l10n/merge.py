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
            return pieces[path]
        node = root
        for key in path[:-1]:
            node = node.setdefault(key, {})
        if pieces[path] == {} and isinstance(node.get(path[-1]), dict):
            continue
        # An empty object is copied, since pieces below it are put into it.
        node[path[-1]] = {} if pieces[path] == {} else pieces[path]
    return root


def merge_pieces(base, ours, theirs):
    """The three-way merge of flattened versions: (the merged {path: value}, the Conflicts). Paths sort, so conflicts
    come in a stable order."""
    merged, conflicts = {}, []
    for path in sorted(set(base) | set(ours) | set(theirs)):
        was, mine, yours = base.get(path, ABSENT), ours.get(path, ABSENT), theirs.get(path, ABSENT)
        if mine == yours or yours == was:
            chosen = mine
        elif mine == was:
            chosen = yours
        else:
            conflicts.append(Conflict(path, was, mine, yours))
            chosen = mine
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


def load(text):
    """The catalog in `text`, or {} when it is empty (git gives an empty base for a file both branches added). A
    ValueError when it is not a JSON object."""
    if not text.strip():
        return {}
    data = catalog.loads(text)
    if not isinstance(data, dict):
        raise ValueError("a catalog is a JSON object")
    return data


def merge_texts(base_text, ours_text, theirs_text):
    """The three-way merge of three catalog texts: (the merged text in `xcstringstool`'s layout, the Conflicts)."""
    merged, conflicts = merge_catalogs(load(base_text), load(ours_text), load(theirs_text))
    return catalog.dumps(merged), conflicts
