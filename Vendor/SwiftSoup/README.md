# SwiftSoup, vendored

This folder holds SwiftSoup 2.13.9 (commit `18b80329749eca5ea29fc50211dca5c7eff5bfec`
of https://github.com/scinfu/SwiftSoup), the HTML and XML parser every
TextMouth reader of markup uses, under its own MIT licence (`LICENSE`, copied
unchanged). TextMouth compiled it as a Swift package until November 14, 2026,
when it became this folder, a static library target of `project.yml`
(`SwiftSoup` for the Mac app, `SwiftSoup_iOS` for the iPhone app).

Do not edit the files in `Sources/`: `Scripts/vendor/swiftsoup/make_vendor.py`
writes them, and writes them again on every upgrade.

## What the script changes

Attributes, and nothing else. No statement, expression, or declaration of the
tokeniser, the tree builders, the entity table, or the serialiser is touched,
and no file is left out.

- Every `@inline(__always)` is removed: they told the compiler to copy a helper
  into every caller, which made a whole-module build three times the size.
- Every `public` and `open` is removed, except on the declarations whose names
  are in `Scripts/vendor/swiftsoup/allow-api.txt` (what TextMouth and its tests
  call). Compiled as one module, the compiler then drops what nothing reachable
  uses, such as the cleaner. `Scripts/vendor/swiftsoup/internal.txt` lists the
  few lines that share an allowed name but must stay internal.
- `@inlinable` and `@usableFromInline` are removed (they matter only across modules).
- Every class that no class inherits from is marked `final`.

`Scripts/vendor/swiftsoup/test_make_vendor.py` proves it: with those attribute
words taken out of both the release and this copy, and white space ignored,
every file is equal.

## Why

The package was compiled file by file at `-Osize` (smallest) to avoid the
forced inlining, which made parsing slower. A whole-module build of this copy at
`-Osize` is smaller and faster than the package was (the November 14, 2026
research, `research/HTML-PARSER-AND-IMPORT-RESEARCH-2026-11-14.md`, section 1.4). The
trees are the same: `SwiftSoupCorpusTests` (hosted, with every train) and
`Scripts/test/swiftsoup-corpus/run.py` (a Release build over the full corpus)
compare every document of `TestData`, and damaged copies of each, parsed three
ways, against what the released package built.

## How to upgrade

1. Get the new release's checkout (for example, resolve it as a package in a
   scratch project, or clone the tag into a scratch folder).
2. Run `python3 -I Scripts/vendor/swiftsoup/make_vendor.py --source <checkout>`.
   Update `RELEASE_VERSION` and `RELEASE_REVISION` in the script and the
   numbers in this file. If it stops because `internal.txt` names a line the
   release no longer has, update that entry. If a build then says a name is
   inaccessible, add the name to `allow-api.txt`; if it says a public declaration
   uses an internal type, add its line to `internal.txt`.
3. Run `python3 -I Scripts/vendor/swiftsoup/test_make_vendor.py`.
4. Run `Scripts/test/swiftsoup-corpus/run.py` through the heavy-work lock, with
   `--upstream <checkout>`: the new release against the new copy. A release is
   allowed to build different trees than the last one; if it does, the corpus
   test's manifest (`TestData/soup-corpus/manifest.tsv`) must be recorded
   again from the new release's own package (see `SwiftSoupCorpusTests`), and
   the difference reviewed: `MarkupNesting` mirrors the tree builder's rules
   and may need the same change.
5. Run `SwiftSoupCorpusTests`, the golden tests, and the `import`, `readers`,
   and `feeds` areas.
