# TextMouth test compatibility runner

Run `swift run` in this directory to execute `TextMouthProductionTests`, the
hosted XCTest target that imports the real `TextMouth` module.

The old standalone harness and disposed reference files have been removed.
The few scenario files still under `Sources/Tests/` are explicitly included by
`project.yml`; they import the production `TextMouth` module and run as grouped
XCTest activities. No copied application implementation is compiled.

New and migrated regression tests belong in `TextMouthProductionTests/` and
must use `@testable import TextMouth`.

The completed migration and final retirement decisions are recorded in
`../TODO-2026-07-12.md`. The historical runner executed 1,184 runtime cases;
every remaining reference registration now has either production-backed hosted
coverage or an explicit disposition.

## Production playback profiling

From the repository root, run the opt-in harness against a copied cache from
the live library:

```sh
TEXTMOUTH_PROFILE_SELECTION=random zsh Scripts/profile-production-playback.sh
```

The default run loads a random cached text book, repeats document derivations,
renders at most 5,000 UTF-16 code units through the production TTS engine, then
plays silently for 15 seconds and rewinds toward the start. It prints one
anonymous `PERF_PROFILE` JSON record with timings, RSS checkpoints, rendered PCM
size, and the extra scheduled PCM size after rewinding. It never updates the live
book, cache, or saved reading position. The script uses an optimized Release
build by default; set `TEXTMOUTH_PROFILE_CONFIGURATION=Debug` when debugging.

Set `TEXTMOUTH_PROFILE_SELECTION` to `smallest`, `median`, `p95`, or `largest`
for repeatable corpus points. `TEXTMOUTH_PROFILE_PLAY_SECONDS` controls playback,
and `TEXTMOUTH_PROFILE_RENDER_CHARACTERS` controls the safety cap. The test skips
during ordinary suites because the library-root build setting is otherwise empty.

## Persisted content indexes

Cache format `3.0.2` rebuilds every text-format cache once. During that background
rebuild, TextMouth writes a versioned `contentIndex` into each package's
`bookInfo.json`. The index stores chapter starts and lengths, per-chapter word
counts, normalized heading IDs and local/global offsets, total counts, and—for
audio books—layout, relative media paths, segment timing, and duration. Mutable
reading position remains in `state` and is not duplicated in the index.

`library.json` stores only totals and `contentIndexVersion`, keeping application
startup compact. Reader loading injects the package index on its background
queue; repeated totals, headings, chapter offsets, and global-position lookups do
not rescan the whole book. Package state writes are serialized and debounced, and
cache regeneration atomically replaces the prior cache only after extraction
succeeds.

The production profiler reports both `loadMilliseconds` for a cold index build
and `indexedLoadMilliseconds` for the persisted-index path, plus
`contentIndexBytes`, JSON encode/decode timing, and repeated derivation timing.
