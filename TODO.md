# TextMouth Audit TODO

This checklist tracks the issues identified in the July 2026 code audit. Items are ordered by severity. A checked item means the production fix, focused regression coverage, and full verification have been completed.

## Critical

- [ ] Defer original-file deletion until a duplicate import is accepted.
- [ ] Make folder deletion with content relocation transactional so failed moves cannot delete books.
- [ ] Make data-directory migration non-destructive, validated, and recoverable.
- [x] Classify segmented DAISY audio before ordinary multi-file audio. *(Batch 1)*

## High

- [ ] Serialize library persistence and flush pending saves when the app terminates.
- [ ] Include a stable unique identifier in every `.tmb` package name.
- [ ] Move single-file import hashing, parsing, copying, and cache generation off the main thread.
- [ ] Centralize global Now Playing and remote-command ownership across reader windows.
- [ ] Copy and validate externally opened `.tmb` packages before adding them to the library.
- [ ] Replace EPUB files atomically when writing metadata.
- [x] Persist editable audio album, genre, and year metadata. *(Batch 1)*
- [ ] Serialize current- and next-chapter TTS rendering and apply consistent size limits.
- [x] Use a strict, deterministic comparator for descending library sorting. *(Batch 1)*
- [ ] Isolate UI and shared mutable services with actors or serial executors.
- [ ] Route externally configured data-directory changes through the migration workflow.

## Medium

- [ ] Keep Unicode search, substitution, and speech offsets in a consistent coordinate system.
- [ ] Commit book and folder model moves only after their filesystem moves succeed.
- [ ] Rewrite `bookInfo.json` after moving books or folders.
- [ ] Never fall back from Trash to permanent deletion without explicit confirmation.
- [ ] Complete bidirectional config synchronization and rearm the watcher after atomic replacement. *(Batch 1)*
- [ ] Clear short reading-stat sessions correctly and flush an active session at termination.
- [ ] Make duplicate-finder criteria follow the advertised combined-match behavior.
- [x] Remove unsupported legacy `.doc` import advertising or add a real parser. *(Batch 1: removed unsupported advertising)*
- [ ] Report per-file failures after ZIP imports.
- [ ] Serialize ZIP imports or give every import independent progress/dialog state.
- [ ] Stamp cache versions only after successful atomic cache generation.
- [ ] Persist EPUB publisher and publication-date edits independently of file write-back.

## Low

- [ ] Calculate recursive package size for directory-based audiobooks.
- [ ] Clamp adjusted bookmark positions to chapter bounds.
- [ ] Replace the copied standalone test implementations with tests that import production code.

## Verification Baseline

- Production Debug build succeeded before changes.
- Standalone test harness passed 1,184 of 1,184 tests before changes.
- Strict-concurrency diagnostics currently report isolation and sendability warnings; these are tracked by the concurrency item above.
