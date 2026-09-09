# Faster automatic cache updates

September 9, 2026. Branch: `perf/incremental-cache-updates`.

## Findings

The sampled library contains 633 books, including 625 EPUBs. The update used
one utility worker, regenerated each cache, and immediately reopened and parsed
the generated Markdown to build its index. EPUB extraction had already parsed
the same reading chapters to recover heading coordinates.

Each package's index was saved immediately, but library versions and totals
were held until the entire batch finished. An interrupted run could therefore
repeat books whose packages had already been updated. Repeated extraction
actions could also start overlapping batches on the same library model.

A read-only sample of the running app confirmed work in EPUB extraction,
HTML conversion, and Markdown parsing. A later sample showed playback rather
than cache migration. The running application was left in place throughout.

## Changes

- Reuse EPUB's prepared chapters when generating the cache and index. Readers,
  imports, and automatic/manual updates share that result. Other formats parse
  their generated Markdown once before writing it atomically.
- Avoid looking up fragment attributes on every HTML node when the chapter has
  no fragment destinations.
- Run at most two ordinary EPUB updates at utility priority. EPUB source files
  over 16 MiB, other formats, and repeated package paths run behind barriers.
  File-size checks and package-path resolution also run off the main thread.
- Publish and save each successfully committed book before advancing progress.
  If package metadata is newer than the library snapshot, resume from its current
  cache/index without reading or rewriting the source. Missing caches and old
  indexes remain eligible for work.
- Reject a second automatic/manual rebuild while this model already has an
  active batch. Manual Redo Text Extraction still forces new source extraction
  when started normally.

The queue's ownership, completion, and worker limit follow Apple's
[OperationQueue documentation](https://developer.apple.com/documentation/foundation/operationqueue).
The 16 MiB source cutoff is a conservative scheduling heuristic, not a guarantee
about decompressed memory. The worker count prevents library-sized fan-out;
actual memory still depends on each document.

## Measured results

The existing optional Helliconia corpus test now profiles a single regenerated
cache/index and four independent disposable copies. Timing is diagnostic and
never an XCTest pass/fail threshold.

| Measurement on this Mac | Time |
| --- | --- |
| Previous single-book generation/index, median of three | 2.039 s |
| Updated single-book generation/index, median of three | 1.840 s |
| Updated four-book batch, one worker | 7.367 s |
| Updated four-book batch, two workers | 3.886 s |

The measured single-book work decreased about 10%; the two-worker batch took
about **47% less time** than the updated serial batch. These are hosted Debug
measurements using one representative EPUB, not a promised whole-library time.
Earlier focused runs produced similar batch timings (7.53 s versus 4.03 s).

All 122 Helliconia chapters and 127 headings remain present. Existing heading
IDs and every chapter's reading text match the previous regression fixture.

## Versioning and future processing changes

This optimization changes neither stored text nor the cache/index schemas.
Their versions remain **3.0.4** and **1.0.0**, respectively. Books already updated
by the preceding build do not require another extraction for this optimization.

Use the revision appropriate to future work:

- Source-to-Markdown changes or a new stored representation: update
  `MarkdownCacheService.currentCacheVersion` and regenerate affected caches.
- Changes confined to derived reading text, heading coordinates, metrics, or
  index structure: update `BookContentIndex.currentVersion`. The existing
  analysis path rebuilds from cached Markdown without source conversion.

A regression verifies that an index-only update works even when the source is
unavailable. Extraction versions are still shared across text formats;
format-specific invalidation could be a further improvement, although it would
save little for this particular update because nearly the whole library is EPUB.
General cache/index fingerprinting and coordination with reader loads or storage
moves remain T07/S04 in the broader TODO.

## Validation and delivery

The complete hosted suite passed: **848 tests, 1 optional playback profiling test
skipped, 0 failures**. The real-book corpus regression ran. Twelve new tests cover
per-book progress, interrupted-run recovery, manual forcing, missing/obsolete
checkpoints, failed extraction, cross-format output equality, index-only work,
worker overlap/caps, large-file barriers, and repeated packages.

```sh
xcodegen generate
xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO \
  SWIFT_STRICT_CONCURRENCY=complete \
  TEXTMOUTH_EPUB_REGRESSION_FIXTURE=/absolute/path/to/copied-package
make build APP_BUNDLE=build/TextMouth-CacheUpdate.app
```

Code commits: `0e8ee84` and `9283914`. Test log:
`/tmp/textmouth-cache-updates-final.log`. Release packaging succeeded:
`build/TextMouth-CacheUpdate.app`, build `20260909043607`, code commit `9283914`.
The existing `build/TextMouth.app` remained at build `20260909040532` for the
running process. Quit that app before launching the new copy when convenient.

Existing unrelated strict-concurrency/deprecation warnings remain. The changed
implementation/tests emitted no new warnings in focused verification, and the
changed implementation files emitted no warnings in the Release build.

The three pre-existing modified files were preserved and excluded from these
commits. No live library files were written by this investigation or its tests.
