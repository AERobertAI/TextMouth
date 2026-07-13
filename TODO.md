# TextMouth Audit TODO

This checklist tracks the issues identified in the July 2026 code audit. Items are ordered by severity. A checked item means the production fix, focused regression coverage, and full verification have been completed. Difficulty estimates implementation effort, regression risk, and blast radius on a 1–10 scale (1 = very small/localized, 10 = architectural/high-risk); it is independent of severity and feature usage.

## Critical

- [ ] Defer original-file deletion until a duplicate import is accepted. **Difficulty: 3/10**
- [ ] Make folder deletion with content relocation transactional so failed moves cannot delete books. **Difficulty: 8/10**
- [ ] Make data-directory migration non-destructive, validated, and recoverable. **Difficulty: 9/10**
- [x] Classify segmented DAISY audio before ordinary multi-file audio. **Difficulty: 2/10** *(Batch 1)*

## High

- [ ] Serialize library persistence and flush pending saves when the app terminates. **Difficulty: 6/10**
- [x] Include a stable unique identifier in every `.tmb` package name. **Difficulty: 2/10** *(Batch 1)*
- [ ] Move single-file import hashing, parsing, copying, and cache generation off the main thread. **Difficulty: 7/10**
- [ ] Centralize global Now Playing and remote-command ownership across reader windows. **Difficulty: 8/10**
- [ ] Copy and validate externally opened `.tmb` packages before adding them to the library. **Difficulty: 6/10**
- [ ] Replace EPUB files atomically when writing metadata. **Difficulty: 5/10**
- [x] Persist editable audio album, genre, and year metadata. **Difficulty: 2/10** *(Batch 1)*
- [ ] Serialize current- and next-chapter TTS rendering and apply consistent size limits. **Difficulty: 7/10**
- [x] Use a strict, deterministic comparator for descending library sorting. **Difficulty: 2/10** *(Batch 1)*
- [ ] Isolate UI and shared mutable services with actors or serial executors. **Difficulty: 10/10**
- [ ] Route externally configured data-directory changes through the migration workflow. **Difficulty: 8/10**

## Medium

- [ ] Keep Unicode search, substitution, and speech offsets in a consistent coordinate system. **Difficulty: 8/10**
- [ ] Commit book and folder model moves only after their filesystem moves succeed. **Difficulty: 8/10**
- [ ] Rewrite `bookInfo.json` after moving books or folders. **Difficulty: 4/10**
- [ ] Never fall back from Trash to permanent deletion without explicit confirmation. **Difficulty: 5/10**
- [ ] Complete bidirectional config synchronization and rearm the watcher after atomic replacement. **Difficulty: 4/10**
- [ ] Clear short reading-stat sessions correctly and flush an active session at termination. **Difficulty: 4/10**
- [ ] Make duplicate-finder criteria follow the advertised combined-match behavior. **Difficulty: 4/10**
- [x] Remove unsupported legacy `.doc` import advertising or add a real parser. **Difficulty: 1/10** *(Batch 1: removed unsupported advertising)*
- [ ] Report per-file failures after ZIP imports. **Difficulty: 5/10**
- [ ] Serialize ZIP imports or give every import independent progress/dialog state. **Difficulty: 7/10**
- [ ] Stamp cache versions only after successful atomic cache generation. **Difficulty: 4/10**
- [ ] Persist EPUB publisher and publication-date edits independently of file write-back. **Difficulty: 6/10**

## Low

- [ ] Calculate recursive package size for directory-based audiobooks. **Difficulty: 3/10**
- [ ] Clamp adjusted bookmark positions to chapter bounds. **Difficulty: 2/10**
- [ ] Replace the copied standalone test implementations with tests that import production code. **Difficulty: 9/10** *(A production XCTest target now covers new regressions, but the legacy harness still uses copies.)*

## Verification Baseline

- Production Debug build succeeded before changes.
- Standalone test harness passed 1,184 of 1,184 tests before changes.
- Strict-concurrency diagnostics currently report isolation and sendability warnings; these are tracked by the concurrency item above.
