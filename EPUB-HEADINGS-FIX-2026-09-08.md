# EPUB heading recovery and library cleanup

Investigation: September 8, 2026; Release packaging completed September 9.
Branch: `fix/epub-missing-headings`.

## Report and cause

The Science Fiction copy of *The Helliconia Trilogy* contains 122 spine
documents, but only 27 semantic HTML headings in 22 of them. One chapter has
six headings. The other 100 documents contain styled paragraphs instead of
`h1`–`h6` headings.

The EPUB has no NCX. Its declared EPUB 3 navigation is incomplete, while a
conventional visible contents section links to many more chapters. Cache
extraction previously recovered missing labels only from NCX, discarded
fragment destinations, and matched paths without consistently resolving them
relative to the navigation file. Chapters lacking a recoverable label remained
in the chapter count but had no entry in the headings screen.

This is a longstanding extraction gap, not a heading-screen filter defect.
The NCX-only fallback dates to `05305bb` (March 24). Recent fixes resolved
EPUB spine paths (`ed1f073`), heading-panel UTF-16 timing (`06e6bb3`), and
Markdown text/heading coordinates (`f556c1f`), but did not recover these missing
navigation destinations. The latest TODO already listed the underlying work
as [T11](TODO-2026-09-04.md); it is now checked off.

## Implemented plan

1. Reproduce the 122-chapter/27-heading structure with a synthetic EPUB and
   verify a disposable copy of the reported book against its previous cache.
2. Share EPUB extraction between direct parsing and cache generation. Resolve
   EPUB 3 TOCs, the declared NCX, legacy guide contents, and recognized visible
   TOCs against their own documents. Keep nested levels and fragment targets;
   exclude external links, page lists, and unrelated prose links.
3. Preserve semantic headings and add missing chapter-start destinations.
   Prefer available navigation/document labels; use `Chapter N` when no useful
   label exists. Store recovered destinations as encoded comment metadata,
   separate from spoken text, with offsets recorded during text extraction.
4. Repair direct HTML heading offsets with a plain DOM walk, preserving literal
   punctuation, escaped tags, and preformatted whitespace.
5. Bump the cache to `3.0.4`, exercise stale-cache/index replacement and retained
   reading state, and test the actual reader's recovered headings and navigation.
6. Repair the background-release crash exposed by the complete hosted suite,
   then rerun the suite and package Release.

## Result and compatibility

The copied Helliconia package now has **127 headings across 122 chapters**.
Every chapter has a destination, and the five additional original subheadings
are retained. The test compares every chapter's reading text with the old
cache and verifies that all existing heading IDs remain present. No source
book text is included in the committed synthetic fixtures.

The live EPUB and cache were inspected read-only; only disposable copies were
imported. Existing books receive the fix through normal cache regeneration on
startup or opening. An already-open reader must be reopened to load new content.

This text-preservation result is specific to the reported book and the tested
fixtures. Older NCX-derived caches could contain a generated spoken title
prefix; rebuilding those now uses silent navigation metadata and can remove
that prefix. Other earlier extraction corrections can also change coordinates.
The existing migration retains numeric reading positions/bookmarks; general
semantic relocation after changed text remains [T06](TODO-2026-09-04.md).

The heading list's existing native controls and accessibility behavior remain
in use. Tests cover published headings, accessibility descriptions, and actual
reader activation. Manual VoiceOver and braille hardware checks remain A01.

## Crash reported during testing

The supplied September 8 crash is the hosted production-test app. Its utility
thread released the final `LibraryViewModel` reference in
`calculateMissingBookStats()`. The model's destructor unconditionally called
`MainActor.assumeIsolated`, which traps when cleanup runs off the main actor.
That assumption was introduced in `1f6e4cc` (July 12), before this heading fix.

The model now owns its timer through an actor-isolated cancellation handle.
Main-thread release cancels immediately; background release queues cancellation
on the main thread while retaining only the handle, never the dying model.
Three lifecycle tests verify background final release, immediate main-thread
release, and timer replacement/callback behavior. This repairs the concrete
crash without claiming to complete the broader concurrency audit in Q02.

The implementation follows Apple's requirements for
[timer invalidation](https://developer.apple.com/documentation/foundation/timer/invalidate())
on the timer's installation thread and the Swift migration guide's discussion
of [nonisolated deinitialization](https://www.swift.org/migration/documentation/swift-6-concurrency-migration-guide/commonproblems/).
EPUB navigation discovery and TOC hierarchy follow
[EPUB 3.3](https://www.w3.org/TR/epub-33/).

## Validation

The heading tests initially reproduced the failure against the previous
implementation. The final suite includes 15 EPUB/HTML regression tests and
three library lifecycle tests. The optional real-book test is enabled through
`TEXTMOUTH_EPUB_REGRESSION_FIXTURE`, pointing to a copied package containing
the source EPUB and its old `content.md`.

```sh
xcodegen generate
xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  TEXTMOUTH_EPUB_REGRESSION_FIXTURE=/absolute/path/to/copied-package
make build
```

The complete hosted run finished successfully: **836 tests, 1 optional profiling
test skipped, 0 failures**. The copied Helliconia test ran and passed. Result:
`build/DerivedData/Logs/Test/Test-TextMouth-2026.09.08_23-56-04--0400.xcresult`.
The live EPUB/cache SHA-256 hashes matched their pre-investigation values.

Local code commits are `5b18581` (library cleanup) and `534e8f7` (heading recovery).
`make build` succeeded and packaged `build/TextMouth.app`, build
`20260909035900`, carrying code commit `534e8f7`. The complete Release log is
`build/xcodebuild-Release.log`. No compiler warnings were reported in the
changed implementation files during that build.
Existing concurrency/deprecation warnings remain tracked by Q02/Q06.

The three pre-existing modified files (`DAISYParser.swift`,
`AudioZIPClassificationTests.swift`, and `LegacyScenarioHarness.swift`) were
included in verification, preserved, and excluded from these commits.
