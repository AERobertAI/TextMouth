# Agent notes, September 28 to October 4, 2026

What each task agent of the orchestrated campaign left unverified or undone, in its own words as the orchestrator recorded it at merge time, with pointers to the documentation wording that was still to be applied. The TODO holds the records; this file holds the loose ends. The task transcript identifiers it names (tasks/<id>.output) belong to the orchestrator's session and are gone with it; the wording they held was applied by the documentation passes of October 3 and 4, except where this file says otherwise.

# Follow-ups discovered during the 2026-09-28 session

## From the audio speed agent (fix/audio-speed-granularity, merged 2a21a18)
- Command-F / Search in Book opens the search sheet for audio books even though the toolbar hides Search for them (`ReaderView.swift` `.searchInBook` handler has no audio check; the sheet's time estimates are WPM based).
- Global Settings "Default speed for new books…" help text could say "text books" since audio speed is per book only.
- Heading navigator audio timings use the 10-characters-per-second placeholder rather than the real media duration (pre-existing).
- Jump-to-time for audio at speeds other than 1x mixes adjusted/unadjusted time (already P08).
- Relative coarse steps: from the 0.25 floor one step up lands on 0.35, so the buttons cannot return to exactly 1.0 from there (sheet or Reset can).

## From the headings wording agent (refactor/headings-wording, merged 2abd88f)
- `HeadingNavigatorView.currentHeadingID(in:)` (private) repeats the containing-heading rule; switch it to `ReaderViewModel.currentHeading(in:...)` / `HeadingPosition` so panel and header share one function.
- `Book.estimatedTimeRemaining` and `Book.percentComplete` both repeat the `globalCharacterOffset ?? characterOffset` fallback; share a helper.
- Generated fallback titles "Chapter N" (EPUBParser+Navigation) and "Chapter" (m4b markers) remain as heading text by design (heading IDs derive from text).
- Flaky `EPUBHeadingRecoveryTests.testHeadingAnnotationsAreOptInAndDoNotConsumeOrdinaryComments`: JSONEncoder key order; sent to the EPUB agent to fix with `.sortedKeys`.
- Agent commits carry `Co-Authored-By: Claude Opus 5.5 (1M context)` trailers (the subagent's own attribution rule); merge commits carry the Fable line.

## From the EPUB page-list agent (fix/epub-page-list-headings)
- `TextMouthPaths.appendLog` crashes the app whenever a log write fails (seen when the disk filled). This is TODO Q07 and matters now: the user's data volume is at 99%. High priority small fix.
- Docs to update: `TextMouthTests/README.md` still says cache 3.0.4; the September 8/9 docs should mention 3.0.5 and the generalized opt-in EPUB test (`TEXTMOUTH_EPUB_REGRESSION_FIXTURE` accepts any package or .epub).
- Reading positions in chapters that regain dropped paragraphs may shift back by up to the restored length (Echo of Worlds chapter 25: at most 646 characters). Relocation is T06.
- Live-library scan (read-only): 86 of 623 cached EPUBs had lines starting with an annotation (7,944 lines of hidden words); 64 had annotations inside heading lines. The 3.0.5 rebuild restores them.
- Scratch copies for reruns: scratchpad/epub-nav/echo-package and helliconia-package.

## From the folder-safety agent (fix/folder-equivalence-and-reparenting)
- `moveZipBooksToFolder` in `LibraryViewModel+Duplicates.swift` still fails silently when the folder name is refused.
- `LibraryView`'s rename handler moves the current view to the new path even when the rename was refused.
- Orphan adoption and package reconcile (`LibraryViewModel+Import.swift`) take folder spelling from disk; `moveBooks` could use `storedSpelling(of:)`. Startup repair corrects these on the next launch.
- Delete-everything still matches folder contents by exact spelling (deliberately conservative).
- The rename sheet disables Rename for a normalization-only change, so such a rename cannot be started from the UI though model and disk support it.
- Not verified on a real case-sensitive volume or HFS+; case-sensitive policy exercised only through the test override.

## From the search agent (fix/search-responsiveness)
- The Search in Book menu item stays enabled for audio books (MenuCommands.swift was outside the agent's area); the reader now ignores the command for audio books.
- The Command-F guard has no unit test (lives in a SwiftUI notification handler).
- Real VoiceOver/braille behaviour of the status line and announcement still needs the manual A01 pass.

## From the DAISY agent (fix/daisy-text-fidelity)
- Cache version bump needed so DAISY 2.02 caches regain the truncated fragment text (assigned to the T02 task: 3.0.6).
- `MarkdownCacheService.generateCacheContent` swallows extraction errors at import, so a damaged DAISY text book imports "successfully" and only errors when opened (relates to S02/I06).
- `FileImportService.importDAISYAudioZip` creates the .tmb and audio folders before converting; a failed conversion leaves them behind (never adopted, but clutter).
- Optional tolerance: retry structure files that fail on encoding as Latin-1/Windows-1252; strip whitespace before an XML declaration.
- Consecutive inline fragments from one paragraph still become separate paragraphs (adds pauses, loses no words).
- `DAISYAudioTests.swift` has a dead `#if !canImport(TextMouth)` block.
- No warning channel exists for partial content; diagnostics go to the debug log as `DAISY_INCOMPLETE_CONTENT`.

## From the settings validation agent (fix/settings-validation-boundary)
- Ranges are still written out separately in `SettingsView`, `MiscellaneousSettingsView`, `SleepTimerView`, the `ReaderView` sliders, and SpeechService's own min/max helpers; they could reference `SettingsPolicy`.
- library.json still loads empty when a book fails to decode for other reasons (e.g. unknown format string); S01 adds the quarantine/recovery state.
- `@AppStorage` copies read outside SwiftUI views may only refresh after relaunch when `defaults write` happens while the app runs.
- Behavior change: a saved audio speed of 0 now plays at 1.0x (was 0.25x).

## From the library index recovery agent (fix/library-index-recovery)
- Live app with VoiceOver not run: sheet appearance at launch, initial focus on its heading, announcement timing unchecked (A01 manual pass).
- Change Location and Reset to Default share one guard with Rebuild Directory; only Rebuild was driven end to end.
- Copy fallback on volumes without hard links and "Rebuild refuses when it cannot save a copy first" were not simulated.
- Edits made while recovering (bookmarks, per-book settings, removals) do not carry into an index restored by Try Again (same as a relaunch today).
- Hosted tests now keep the legacy Application Support location inside the test root (partial Q01).

## From the plain-text agent (fix/plain-text-literal-cache)
- Direct-path TXT text is now normalized like the cache (trimmed lines, paragraphs joined by spaces); saved positions and skipped-heading IDs in .txt books shift after the 3.0.6 rebuild (T06).
- CRLF files still read each line as its own paragraph (left for T08).
- Chapter title differs between paths (file name direct, first heading cached).
- `#hashtag` becomes a heading and `C#` trims to `C` under the unchanged ATX rule.
- `HeadingSweepTests` keeps a private `SeededGenerator` copy that could use the shared one.
- Gutenberg `_emphasis_` and `--` now reach the voice as written; substitutions can tune this.

## From the P06 agent (fix/empty-speakable-advance)
- A pre-rendered next chapter can still play stale audio if a section inside it is skipped, or substitutions change, after it was rendered (only the chapter index is compared, not the text) — relates to P03.
- With Loop, navigating while playing into a silent ending restarts the book and then announces the navigated heading after "Restarting".
- `stop()` does not cancel a pre-render already running.
- Offset mapping does not clamp positions inside removed sections; the branch clamps where it reads positions.
- `SpeechService` still has no defined result for empty text (the reader never sends any now).
- Hosted runs print five macOS `[crashhandler] AUCrashHandler.mm ... CrashHandler proxy error:` lines from speech synthesizer teardown; they match `grep error:` but are not failures.

## From the substitution keyboard agent (fix/substitution-keyboard-access), Sept 30
- Editor Test button can show results from a stale regex: `runTest()` borrows `TextSubstitutionService.shared`, whose compiled-regex cache is keyed by rule ID and not cleared until save. Likely fix: `TextSubstitutionService(rules: [rule]).transform(testInput)`.
- Other hosted suites (reader navigation tests) still post real announcements that can reach VoiceOver during test runs; a silent default poster under XCTest would stop that.
- Footer says "1 rules" for a single rule; Delete and Reset to Defaults have no confirmation or undo.
- Not verified live: row-group reading, actions menu (VO-Command-Space), focus following a moved rule, announcement timing after delete, Tab order under Full Keyboard Access (A01).
- SwiftUI builds its accessibility tree lazily (only with an assistive client attached), so in-process label checks of SwiftUI controls are not possible; the rendered tests check the AppKit-drawn buttons instead and skip if a future macOS stops drawing them as AppKit buttons.

## From the migration safety agent (fix/migration-source-safety), Sept 30
- Full-startup tests that expect an error after their own failing operation could now pass on the migration alert instead: `FolderSafetyTests` (~lines 17, 77), `LibraryMoveTransactionTests`, `DeletionSafetyTests.testFailedPackageDeletionKeepsBookInLibrary`. Inert models or `LibraryIndexSandbox` would fix them (Q01).
- `Book.saveBookInfo()` (error-swallowing) has no app callers left; only `EPUBMetadataTests` uses it — candidate for removal.
- Pre-existing: books are stored under their original file name, so a Markdown book named `content.md` collides with the text cache file (affects import and migration).
- A book that keeps failing migration is reported at every launch (by design).
- Not verified: real Trash path end to end; Rebuild Directory / Reset to Default alerts checked by review only; no real legacy library exists to test against.

## From the config agent (fix/config-atomic-apply-watcher), Sept 30
- No VoiceOver announcement for an unreadable config.json (TextMouth is usually in the background while the file is edited); show or announce the problem when TextMouth next becomes active.
- A file missing longer than ~1.5 s is picked up only at the next TextMouth save (merged) or next launch.
- `.revoke` (volume unmounted) path has no test; not tried with real editors.
- Invalid JSON is preserved on disk until the next in-app settings change overwrites it (logged).

## From the HTML literal-text agent (fix/html-block-boundaries-literal-text), Sept 30
- DAISY 2.02 inline fragments (`DAISYParser.inlineWords`), and the DOCX, DAISY 3, and PDF converters still write raw text into Markdown (same literal-text defect); for DAISY 2.02 the fix is one line with `MarkdownLiteral.escaped`.
- DAISY's `normalizeMarkdownWhitespace` trims trailing spaces, turning line breaks into spaces (whitespace only).
- Heading IDs change where a label now keeps characters it used to lose (T06).
- The Helliconia-specific opt-in test still fails on its `previous.allHeadings.count == 27` precondition because the scratch copy holds a newer cache (fails on main too).
- Conversion is about 8% slower than before on Helliconia (2.25 s vs 2.09 s for 122 chapters).

## From the DOCX malformed-XML agent (fix/docx-malformed-xml), Sept 30
- Intact DOCX bold/italic runs with a leading or trailing space already produce `**text **` whose asterisks may be read aloud; fixing it changes cached text (needs a cache bump).
- ZIP-level damage (bad checksum on a present part) fails with ZIPFoundation's raw error for DOCX and DAISY; a friendly named error would help.
- `DOCXParser.parse(url:)` uses an empty `dc:title` as the title.
- Truncation inside a tag yields a generic "parser error N" reason; reported position is just past the last markup read.
- `AudioZIPClassificationTests` keeps a private copy of the new ZIP test helper.
- Import layer still has no warning channel: partial content and damaged metadata reach only the debug log (I06/S02).

## From the index validation agent (fix/content-index-validation), Sept 30
- `AudioBookParser.audioFiles(in:)` calls `skipDescendants()` on a symlinked file, which makes the enumerator skip the next folder's contents (a link at `02.wav` made `Disc 2/03.wav` vanish). Fix: `skipDescendants()` only for `__MACOSX`, `continue` for links.
- `MarkdownDocParser.parseChapter` does not clamp ordinary heading offsets to the chapter length (navigation headings are clamped); the index builder now clamps, but the parser should too.
- After installing, check the debug log for `CONTENT_INDEX_REJECTED`: one line per book is expected once; the same book repeatedly means a parser output the validation rules don't expect.
- Behavior change: a multi-file audiobook whose folder is missing now fails at open rather than at play; one with a deleted track reopens with one fewer chapter (positions after it shift by a chapter).

## From the audio failures agent (fix/audio-playback-failures), Sept 30
- Not verified in the real UI: Return picks Retry, Escape cancels, what VoiceOver reads, a failed Retry shows a fresh alert (A01).
- Real stalls and a failing AVPlayer cannot be produced in tests; the stall path is tested through a hook and posted notifications.
- `AudioDirectoryImportTests` may still keep a private WAV writer; `AudioTestFixtures` (P04) and `AudioFixtureSupport` (T01) both provide audio fixtures now and should be unified.
- Test hooks added on the audio service: `_playerItemForTesting`, `_pausePlayerForTesting()`, settable `stallRecoveryTimeout`.

## From the library-only removal agent (fix/library-only-removal-tombstone), Sept 30
- NEEDED (import path, S02 agent): `FileImportService.importTMBPackage` must call `try RemovedFromLibraryMarker.remove(from: staging)` before publishing; otherwise importing a retained package with a readable bookInfo.json copies the marker and the book is dropped again at next launch.
- Re-importing the same file should find the retained package by content hash and call `LibraryPersistenceService.reinstatePackage(of:)` (exists, tested); the Book must be rebuilt from marker + content file, so position/bookmarks are lost unless the marker stores them.
- Existing bug: "Remove & Delete" has the stale-dialog problem too: a book moved while the confirmation is open is deleted at the old (empty) location, "succeeds", and the moved package is adopted back at next launch.
- Not verified: alert with VoiceOver; real read-only volume; older TextMouth builds' treatment of a retained package.

## From the listening checkpoints agent (fix/listening-time-checkpoints), Sept 30
- Mac sleep while a session is open is credited as listening (as before); nothing observes system sleep.
- All Time reads the saved total, so it lags by up to one uncredited minute during playback.
- `pruneOldEntries()` is never called; daily entries grow without limit.
- The timer firing during an open menu or modal panel is not tested.

## From the partial extraction agent (fix/partial-extraction-reporting), Sept 30
- DAISY and DOCX should return an `ExtractionReport` via `ExtractedCache.report` (then logging and import gating apply) and drop their own default log lines; their "partial text kept" case needs a new reason.
- `PackageDamage` could expose its advice sentence (duplicated as a string); its log comment about imports having no warning channel is out of date for EPUB.
- EPUB member lookup is case-sensitive (DAISY falls back to case-insensitive), so a case-mismatched member is now reported missing rather than silently skipped.
- A ZIP import can raise its summary alert and the Create Folder dialog at once (pre-existing).
- No cache bump: omissions in already-cached books are logged only when their caches regenerate.
- The report lives in `MarkdownCacheService.GeneratedCache` (returned by `generateReportedCacheContent`/`generateReportedCacheAnalyzeAndStamp`); showing it in the reader needs `DocumentContent` or the analysis result to carry it.

## From the encodings agent (fix/text-encodings-line-endings), Oct 2
- No cache bump: existing caches of CR LF / CR plain-text books keep one paragraph per line until re-extraction (moot for the user: the installed app is on 3.0.4 and rebuilds everything at install).
- Encoding errors reach the user only when the reader opens the book for non-EPUB formats (S02 is making all cache failures fail the import).
- BOM-less UTF-16 in non-Latin scripts and BOM-less UTF-32 are not detected; HTML in a 7-bit encoding (ISO-2022-JP) never has its declaration read; a binary renamed .txt imports as Windows-1252 text (logged).
- `TextInputView`'s reload from an external editor still reads UTF-8 only.
- EUC-JP oddity in Foundation: bytes 0x8E 0x20 decode to U+FEE0.

## From the autoplay agent (fix/continue-next-autoplay), Oct 2
- Sleep-timer handoff: a running timer could carry its remaining time into the next book (SleepTimerService) instead of stopping at the boundary.
- `.openBookWindow` (Finder opens) has the same no-Library-window gap; the router's reader-window registry could cover it.
- Two "book-reader" window-id literals remain in ContentView (could use `BookReaderWindowView.windowID`).
- A book that takes more than 30 s to load opens without starting; if the finished reader's window closes during the 0.5 s delay with no Library window, nothing opens (logged).
- The AppDelegate fallback opens through an `openWindow` action lent by reader windows (SwiftUI gives no usable `openWindow` to the App/AppDelegate, FB11965330); untested live.

## From the import staging agent (fix/import-staging-commit), Oct 2
- The library alert in ContentView is titled "Error" for every library error; "Import Failed" for import errors would be clearer.
- Startup only ignores leftover hidden staging packages; removing them at startup needs a call from LibraryViewModel+Migration.
- Re-importing a removed book's original file still creates a new package rather than taking back the retained one.
- Deprecated `Archive(url:accessMode:)` warnings remain in LibraryViewModel+Import.
- `LibraryPersistenceService.reinstatePackage(of:)` is now called by the package import; S05 must keep its signature.
- A random binary `.txt` now imports as Windows-1252 text (T08), so the "unreadable text" fixture is a corrupted UTF-16 file.

## From the analysis merge agent (fix/analysis-merge-latest-state), Oct 2
- Writers that drop the revision: the data-directory move (TextMouthPaths) and FileImportService's .tmb import and shared-package repair build records without a revision; they could use `Book.bookInfo(replacing:)`, and `FileImportService.bookFromPackageInfo` duplicates the new `Book(record:)`.
- `updateContentIndex` receives only a book ID, so the reader's analysis cannot be identity-checked without changing the reader call site.
- A book whose row and record disagree on hash (crash between the two half-second saves) has its analysis dropped and logged each launch until the next save fixes the record.
- A statistics pass reading an old cache that a rebuild replaces before commit still writes the stale index (repaired by the index check at next load).
- `updateWordCounts` and `updateAudioDuration` have no production callers.

## From the outcomes agent (fix/operation-outcomes-removal-wording), Oct 2
- ContentView's Remove Book dialog still says "Remove & Delete" (patch at scratchpad/outcomes-logs/contentview-removal-dialog.patch); MenuCommands' "Remove from Library" title should follow the preferences (`LibraryRemoveCommandWording`) — follow-up requested from the same agent.
- The import "Replace Existing" choice deletes the old copy without saying where; the "Delete Original File?" dialog always deletes permanently, ignores the Trash preference, and does not say "permanently".
- Not verified live: announcements, focus staying in a sheet after failure, the "running" status line drawing before the operation starts; Reset to Default and successful rebuild/move not run in tests (real destinations).

## From the pre-render agent (fix/prerender-input-signature), Oct 2
- Cancelling a render does not stop AVSpeechSynthesizer.write(); an abandoned render still occupies the shared render queue until it finishes (measured: 18,000 chars → 514 s of audio either way).
- `render` records its synthesizer on a background thread, so a cancel arriving first is missed (harmless now because of the signature checks, but the race remains).
- Settings changes reach the current chapter only at its next natural break or chapter end (UX decision, unchanged).
- SettingsViewModel posts no notice for the punctuation level; the reader observes the settings model's change notices instead.
- Speed and pitch are applied at play time, not render time, so they are deliberately not in the signature.

## From the A08 follow-up (fix/removal-wording-dialog-menu), Oct 2
- The keyboard-shortcut action is still named "Remove from Library" in Keyboard Shortcuts settings; that name is the saved key, so it needs a separate display name rather than a rename.
- Not watched live: the dialog updating after a preference change while open; VoiceOver reading of the dialog and menu.

## From the isolation agent (fix/hosted-test-isolation), Oct 3
- USER ACTION (needs confirmation before deleting): about 10,900 empty plists left by past test runs in the real ~/Library/Preferences (mostly `com.textmouth.tests.*`, plus ~400 named only by a UUID); clean up after this merge, checking the UUID-only ones first.
- `SpeechService.convenience init()` still uses `.standard`; until changed, `PlaybackSettingsAuditTests.withGlobalSpeechSpeed` writes the real `wordsPerMinute` and restores it.
- `ContentView.announceFolderChange` posts announcements directly instead of through `VoiceOverAnnouncer`.
- `StorageOperationOutcomeTests` can now safely drive Reset to Default (sandboxed root).
- Each hosted run leaves a `TextMouthTests-<pid>` folder in $TMPDIR (pre-existing).
- A preferences store named by an absolute path inside a folder named `Library/Preferences` is silently kept in the real ~/Library/Preferences; the sandbox uses `SandboxedPreferences/` for that reason.

## From the media validation agent (fix/media-duration-validation), Oct 2
- `AudioPlaybackService.getDuration(of:)` is now unused; remove it.
- `.invalidSegment` (missing file or impossible times) still does not name the heading and file.
- The import tests duplicate helpers from `StagedImportTests`; share them.
- A clamped end equal to the file length means the clip-end tick and end-of-file notice can both fire; could double-advance only when the next section reuses the same file (pre-existing).
- MP3 behaviour verified outside the suite only (AVFoundation cannot encode MP3); DRM-protected audio untested.

## From the persistence failures agent (fix/persistence-failure-surfacing), Oct 3
- Orphan adoption in FileImportService (~line 1598) still saves silently with `try?`.
- `Book.saveBookInfo()` swallows errors; only a test calls it (remove).
- The reader still says "Settings saved to global defaults" and "Metadata saved to file" without checking the outcome (A09).
- Quit alert and banner not driven with real VoiceOver; full disks simulated.

## From the DAISY package import agent (fix/daisy-package-import), Oct 3
- DECISION TAKEN: keep the standard Open panel file-only (Return on a folder must keep opening it for keyboard users); add a dedicated "Import DAISY Folder…" command instead (follow-up requested from the same agent).
- DECISION TAKEN: do not register `public.folder` in Info.plist for Dock-icon folder drops (TextMouth would appear under Open With for every folder).
- Opening a retired DAISY package from Finder fails with "more than one file that could be the book" (`retainedContentURL` in FileImportService+Packages.swift).
- A loose DAISY book with audio imports as a text book, while a DAISY audio ZIP becomes an audio book.
- Choosing a `.tmb` in the Open panel still fails as unsupported (pre-existing).
- Checksum rule for packages hashes the OPF/NCC content plus paths and sizes only (a same-size content change is not detected).

## From the DAISY folder command follow-up (fix/daisy-folder-import-command), Oct 3
- "Import DAISY Folder…" sits first in the Library menu (Command-Shift-O); the other import commands live in the File menu (TextMouthApp.swift) and it could move beside "Open Book..."; its title uses the "…" character while the others use three dots.
- The Library menu is hidden while a reader window is active, so the command works only from a Library window.
- No window-level drop target exists for folders (never did); adding one needs a ContentView drop handler.
- Panel presentation, VoiceOver reading, and the shortcut on a real keyboard are untested live.

## From the day attribution agent (fix/stats-day-attribution), Oct 3
- The streak's VoiceOver label always says "days" ("1 days"); Books Finished This Year still uses the system calendar's year.
- Streak threshold kept as strictly more than 60 seconds (comment said "at least one minute").
- First launch migrates an existing statistics file once and saves it with `dayKeyVersion: 1`; a clock set before 2025 postpones the migration.
- Foundation defect: the Ethiopian Amete Alem calendar behaves as Gregorian by identifier on this macOS; the migration selects it through the locale keyword.
- Real time-zone/calendar changes while the app runs were not exercised live.

## From the bookmark focus agent (fix/bookmark-keyboard-focus), Oct 3
- "Bookmark N added" counts bookmarks rather than using the new bookmark's number (wrong with numbering gaps) and announces even when nothing was added.
- Row hint "Double-tap to navigate to this bookmark" is iOS wording.
- A bookmark removed while the panel is open (Toggle Bookmark command) does not move focus off its row.
- The 1.2 s VoiceOver delay on opening can pull VoiceOver back if the user moves within that time (pre-existing).
- Not verified live: speech, the actions menu, the rotor, possible double announcement when keyboard focus and the VoiceOver request land together (A01).

## From the metadata writeback agent (fix/metadata-writeback-clarity), Oct 3
- An open reader does not pick up library-side metadata edits, so a later save from that reader resubmits stale values (P10).
- The plain-text info sheet opened from the reader updates the library but not the reader.
- Unreadable EPUB metadata silently falls back to the plain sheet with no explanation.
- `writeMetadata` reports a missing file as "could not be opened as a ZIP archive"; for a read-only package the reason names the hidden temporary copy.
- The editor allows saving an empty title; the EPUB write runs on the main thread.
- Not verified live: the notice in the open editor, the success announcement being cut off as the sheet closes, the sheet's layout.

## From the sort restoration agent (fix/sort-restoration-consistency), Oct 3
- Move Book Up/Down still do nothing silently when they cannot act (not manual order, All Items/Recent, multiple selection, at an edge); a spoken reason would help.
- Whether the "Manual order has no direction" hint (`.help` + `.accessibilityHint`) reaches a toolbar menu item is unverified; checkmarks and announcements not heard live.
- A saved manual + descending setting now shows in arranged order (flips for anyone who had reversed manual order) until the user changes the sort.
- Two pre-existing `onChange(of:perform:)` deprecation warnings remain in LibraryView.

## From the config mirroring agent (fix/config-mirroring-complete), Oct 3
- `SpeechService()` still reads the standard defaults store (Q01 follow-up); `SpeechService.selectVoice` writes the voice key directly and has no callers.
- `SoundEffectService.availableSounds()` re-reads the sounds folder on every call.
- Older config fields still reset to defaults when missing, while the new switches keep the current value (inconsistent on purpose, left as before).
- Not verified: real editors, `defaults write` from another process, VoiceOver.

## From the live statistics agent (fix/live-stats-refresh), Oct 3
- The service's no-argument getters (`todayListeningTime`, `thisWeekListeningTime`, `currentStreak`, `booksFinishedThisYear`) have no callers outside the service.
- "Recently Finished" keys rows by book ID, so a book finished twice gets duplicate IDs.
- About 20 other places pluralize inline and could share the new count helper.
- The streak counts only saved time, so today joins it after the first checkpoint past a minute.
- Cursor stability across a tick and VoiceOver's reading of the custom labels are inferred, not observed.

## From the archive bounds agent (fix/archive-import-bounds), Oct 3
- Cancel button in the import overlay: `ProgressOverlay` needs an optional `onCancel` (Cancel Import, Escape), `.accessibilityElement(children: .contain)`, the message in the spoken label when indeterminate, and the call site passing `cancelImports` (follow-up requested from the same agent).
- Single-book audio ZIPs and DAISY audio ZIPs are bounded but cannot be cancelled.
- DAISY audio files over 256 MB are refused because the converter reads each whole into memory; copying in pieces would lift that.
- Symlinks to book files inside a batch may leave a dangling link once the extraction folder is removed (pre-existing).
- Extraction now happens in an "Archive Extraction" folder inside the data directory (same disk as the library); leftover `extract-<pid>-<uuid>` folders are swept at startup.

## From the routing agent (fix/global-action-routing), Oct 3
- A cold launch with a Finder open was not verified in the real app (relies on AppKit's documented event order); panels replayed into a newly opened window were not shown in tests.
- "Only readers open, book already in the library" always shows a Library window first because SwiftUI re-shows one before the delegate hears of the file; the reader route is used only when no Library window registers.
- `ContentView.onOpenBook` still uses the "book-reader" literal; a Library window with a sheet up cannot present a second panel (prefer one without a sheet); with no key Library window the first registered is chosen rather than the frontmost.

## From the fingerprint agent (fix/cache-index-fingerprint, T07), Oct 3
- EPUB metadata write-back rewrites the source file, so that book's cache is rebuilt once afterwards with the same text; the write-back could re-fingerprint the file after writing.
- `separateSharedTMBPackages` leaves the fingerprint in place when it resets the other analysis fields (harmless: the cache is deleted and rebuilt).
- Audio indexes are not fingerprinted; `md5Hash` and the library title are not updated when a replaced source is detected (content title and headings do follow the new source).
- A text book whose source exists but cannot be read is loaded by the statistics pass once per startup because it cannot be fingerprinted.
- Not verified: the first-launch background pass over ~627 old books (estimated from measured speeds: one normal open per book plus word counting and two MD5s, once); whether copying the data directory keeps file dates (if not, each book is hashed and re-stamped on its next open; nothing is regenerated).

## From the locking agent (fix/dependency-locking-gate, Q03), Oct 3
- The GitHub Actions workflow has never run on GitHub; untested on the `macos-26` runner: hosted app tests (GUI session, permission prompts, voices, 7 GB), and whether Xcode 26.0.1 stays on that image.
- Merging replaces the main checkout's ignored `Package.resolved` (0.7.3 / 2.13.2 / 0.7.1) with the committed pins (swift-markdown 0.9.0, SwiftSoup 2.13.9, ZIPFoundation 0.9.20); the next build there, and the installed app, move to those versions. Every agent worktree has been testing on them already.
- `Scripts/check.sh` locates the build-slot wrapper through `CLAUDE_CODE_SESSION_ID` and the Claude scratchpad root; a later cleanup could reduce that to `TEXTMOUTH_BUILD_SLOT` only.
- The gate runs `make test` into Xcode's default build folder rather than the scratchpad; a fresh-resolution comparison (without `Package.resolved`) is a manual check, not a gate step, so a new upstream swift-cmark release does not fail every run.

## From the cancel-button agent (fix/import-cancel-button, I05 follow-up), Oct 3
- No live VoiceOver session: without an assistive client SwiftUI built no accessibility elements for the overlay, so the two structure tests skip (8 skipped on the branch).
- Escape works on the offscreen test window; in the real window a focused text field such as the search field may take Escape first.
- The button shows for every import but only stops ZIP batches (its hint says so); a single-file import, and an audio or DAISY audio ZIP already under way, still cannot be interrupted. Showing the button only during a ZIP batch, or making those imports cancellable, is a further follow-up.

## From the log-policy agent (fix/log-content-policy, Q07 remaining half), Oct 3
- Five files still write around `DiagnosticLog`, each a one-line migration: `ArchiveExtraction.swift` (two absolute-path lines and two direct helpers), `LibraryWindowRouter.swift` ("app-wide action:"), `AppDelegate` (`BUILD_IDENTITY`, continue-to-next-book), `ConfigService` (`CONFIG_FILE`), `BookContentAnalysisService` (`CONTENT_INDEX_REJECTED`); after migrating, remove each from both lists in `LogContentPolicyTests`.
- The 20-lines-per-second trace limit comes from counting the lines one focus request writes; tracing was not run live and real VoiceOver focus sequences were not watched.
- The branch deletes `ReaderViewModel.debugLog()`; any branch adding a `debugLog` call in the reader will not compile after merge (multiclip confirmed it adds none).
- Departure from the brief: sleep-timer and speech-transition events keep their own two log files (same writer, two generations each) rather than moving into the debug log.

## From the integration agent (test/integration-boundaries, Q04), Oct 3
- `ContinueToNextBookTests`, `ReaderAudioFailureTests`, `StagedImportTests`, and `EPUBPartialExtractionTests` keep private copies of fixtures now in `IntegrationTestSupport.swift` (silent audio books, folder cleanup, sleep-timer reset); worth a dedup ticket.
- The persistence test presses Retry through the banner's model because SwiftUI exposes the button to accessibility only with an assistive client; the sleep-timer test uses two readers because the single-reader expiry (P01) has no repaired fix behind it yet.
- Nothing was run with live VoiceOver.

## From the DOCX-structure agent (fix/docx-structural-fidelity, T05), Oct 3
- Decision taken by the orchestrator: keep the literal-text commit (283aae3) for consistency with plain text and HTML; no cache-format bump because the live library holds no DOCX books (new imports get the new conversion). Design question for the user: a separator line of asterisks is now spoken as asterisks in every format; a cross-format rule could speak it once as a section break.
- Shared Markdown reader reads tables as fused words: no break between cells, between rows, or between a table and the paragraph before it (test_book.docx's table reads "Reading (hPa)TrendExpected Conditions1013-1023Steady…"); finding posted on `MarkdownParser.swift`.
- Still open in the DOCX converter (seen by reading the code): lists set by style come from the style's name rather than its numbering properties; `numStyleLink` is not resolved; a text box (`w:txbxContent`) inside a run resets the paragraph around it; a hyperlink address containing spaces breaks the link; bold or italic text with a space at its edge still has its asterisks read aloud; tracked moves (`w:moveFrom`) may be read twice.
- The shared-count rule for lists that share an abstract definition rests on the spec's example, a Microsoft Q&A report, and two open-source implementations, not on Word itself; two commit messages cite standard sections that may be wrong (the code comments were corrected).

## From the architecture agent (docs/architecture-and-dedup, Q08), Oct 3
- `FileImportService` builds a book from its record by hand in two places, copying `Book(record:)` but without the cache fingerprint (finding posted on the board); worth a small fix so imported books do not need a first-open hash.
- Two ARCHITECTURE.md sentences describe an audiobook chapter as "a file or one time range" and will date once the DAISY multi-clip branch merges (that agent was told).
- No live VoiceOver check of the "1 second" disconnect-delay fix; duplication left in place is listed in ARCHITECTURE.md (reader and import-service bridges, ~15 plural choices in six files, `VoiceOverFocus` tree-search helpers, the two PDF page loops and JSON encoders because merging them changes behavior, `TimeRemainingBar`'s unused duplicate of `totalTimeRemaining`, `ContentView`'s hard-coded window ID and direct folder announcement, unused `cachedAudioDir`).

## From the multi-clip agent (fix/daisy-multiclip-sections, I03), Oct 3
- Already-imported DAISY books keep one clip per heading (packages do not keep the SMIL files); re-importing gains multi-file headings.
- A heading that jumps between non-adjacent parts of one file is switched by the existing quarter-second position check, so up to 0.25 s of the skipped stretch can play first; switches at a file's end are exact.
- The padding log line still says "sections' ends" though it now counts clips (left for the log owner); ARCHITECTURE.md still describes a chapter as one file or one time range; no real DAISY audio fixture exists in TestData (tested with in-memory packages and silent WAVs); nothing listened to live.
- Headings with no audio of their own are left out, now including a heading that starts exactly where the next one starts (a part title followed by its first chapter); the 50 ms join threshold for consecutive clips is a judgment call.

## From the import-decisions agent (fix/import-decision-queue, I01), Oct 3
- `ARCHITECTURE.md`'s Imports entry needs the queue and the presenter; the overlay's Cancel hint does not say it withdraws waiting questions; a question sheet blocks that button in its window, so a "Cancel Import" choice on the sheet may be worth adding.
- Quitting with duplicates still waiting leaves their packages on disk to be adopted at the next launch without asking (pre-existing).
- Four test files keep private copies of the import-preference helper now in `ImportDecisionTestSupport.swift`; an error alert and the question sheet arriving on one window at once is untested; not verified with live VoiceOver or in a running multi-window app.

## From the reader-refresh agent (fix/reader-refresh-after-edits, P10), Oct 3
- `ARCHITECTURE.md`: the library-index "How others observe it" entry and the reader-state entry should say a reader's copy stays current through `LibraryViewModel.bookUpdates` (rows published with a per-book revision whenever `Book.LibraryFields` change; package moves bracketed with `packagesWillMove`/`packagesDidMove`); add `ViewModels/LibraryBookUpdates.swift` and `ViewModels/ReaderViewModel+LibraryUpdates.swift` to the file lists.
- Out of scope: removing a book while its reader is open; Rebuild Directory relocations are not bracketed (readers re-target right after the update; same-volume renames).
- Possible flake: `ContinueToNextBookTests.testFinishingABookStartsItsAlreadyOpenNextBookOnce` counted 2 starts once (its counter also counts the `true` a pause re-asserts; an AirPlay-route error was logged at that moment); passed 6 isolated repeats and the full rerun; finding posted on the board.
- Not verified: live VoiceOver; the Now Playing refresh is unobservable from tests; the data-directory move test drives `TextMouthPaths.moveDataDirectory(to:library:)`, not the full Change Location command.

## From the symbols agent (feature/repeated-symbol-speech, FR01), Oct 3
- Docs to add (orchestrator): README "Settings, in tabs" Text entry and config.json Text line; ARCHITECTURE.md lines ~103 (TextSubstitutionService owns the repeated-symbol settings), ~136 (refreshLookAhead triggers), ~241 (speech pipeline: skipped sections removed, repeated symbols rewritten, punctuation pauses, substitution rules). Exact text is in the agent's report (tasks/a00dabe963cd08745).
- Finding: the steppers at `SettingsView.swift:241` and `:326` likely make VoiceOver say "Seconds, Minimum pause threshold" (hidden title spoken before the label); the new group uses an empty stepper label to avoid it.
- Stale doc comments: `ReaderViewModel.swift`'s `currentOffsetMap` comment ("filter → pause → substitution") and `refreshLookAhead`/`observeSpokenAudioSettings` could mention repeated symbols.
- Decisions: default style Say how many; default symbol set leaves out sentence punctuation, quotes, and brackets (voices already compress "...."); independent of the substitution switch; a single horizontal space of any kind joins a run; Leave out inserts a lone period for the pause; a GroupBox hid controls from the hosted accessibility test, so the group is a plain stack under a heading.
- Not verified: live VoiceOver on the checkbox and Reset button; the real Settings window layout (about 165 pt estimated for the group); how the voices sound (durations measured, not listened to).

## From the migration agent (fix/migration-publication-guard, S10), Oct 3
- Pre-existing: a book whose path is outside the data directory makes every move fail with the misleading "The migrated copy is missing the content for <title>".
- For the cloud work: the staged copy still lives in a hidden folder beside the destination (needed for the atomic rename), so a provider would upload it mid-copy; copy and publication still run on the main thread; a provider's or Finder's metadata file (`.DS_Store`) arriving mid-copy stops a move, safely, so Phase 1 may want a list of names to ignore; no size or local-volume assumptions were added.
- Side effect: Reset to Default is refused if `~/.TextMouth` is a link to the current custom folder (same real folder).
- ARCHITECTURE.md text suggested: "DataDirectoryMigrator (Services/DataDirectoryMigrator.swift) copies the data directory to a hidden staging folder beside the new location's real folder and publishes it with one rename. It never removes anything but an empty folder (rmdir). Anything that arrives meanwhile stops the move, and the setting and library change only after publication. Locations are compared as the real folders their links lead to (DataDirectoryLocation)."
- Brief error: `LegacyMigrationSafetyTests` does not exist on main and `LegacyBookMigration` is not on the move path. Tested on APFS only; not run with real VoiceOver; not run on a merged tree with readerrefresh (its data-directory move test was read, not run).

## From the completion agent (fix/completion-once-per-generation, P05), Oct 3
- `AudioEngineService` drops a buffer completion that arrives while paused, so resuming can leave speech stuck as Playing (board #166; the warnings agent held that file).
- Continue to Next Book's 0.5 s delayed request is not tied to a generation, so pressing Play in that half second still opens the next book; two readers of one book share `notifyDocumentEnd` through the book ID (P01); `willSpeakRange` has the same address-reuse issue (cursor positions only); a segmented section always gets at least one second of placeholder text, so a 0.5 s section's offsets seek beyond its clip end.
- Flaky: `AudioClipChainReaderTests` failed once in about 50 runs; the log points to an outside media "skip back" reaching the test reader through the shared `NowPlayingService` (pre-existing).
- Not verified: variable-bit-rate MP3s (no fixtures; a seek to exactly the true end of an overestimated file restarts once, then finishes); notices posted off the main thread (tested through the hook only).
- ARCHITECTURE.md text suggested: "The playback generation": every chapter play (`ChapterPlay`) begins a new generation, as do navigation and skips; each play hands its service a completion callback made for that play; the reported end moves the reader on from the chapter that played only while that generation is current; a stale end is logged once and ignored. "Audiobook playback": plays have generations (`AudioPlaybackGeneration`); `AudioEndNoticePolicy` judges each end-of-file notice by the generation and playhead read when it was posted; an end while paused is held until resume; a late end of an earlier playthrough restarts the play on a fresh player; `onPlaybackFinished` fires once per play that runs to its end.

## From the logtail agent (fix/log-direct-writers-and-table-breaks), Oct 3
- `CONTENT_INDEX_REJECTED` can quote heading labels (book text) into the log; the text is built in `BookContentIndex` outside any log call, so the source scan cannot catch it (board #153).
- DAISY 3 tables are written as pipe rows without the delimiter line Markdown needs, so each table reads as one paragraph with literal `|` characters; raw HTML blocks in Markdown books are silently dropped.
- Saved positions after a table shift only in books whose cache holds Markdown tables (DOCX text tables, Markdown books, possibly PDF text); HTML, EPUB, and plain-text caches escape table syntax, so they are unchanged. Cells within a row are joined by a space (a space or line break gives no pause in any voice measured; only a blank line or punctuation does), rows are paragraphs, as T03 does for HTML.
- Not listened to in the running app; the live library had no DOCX or Markdown books at the 2026-09-28 inventory.

## From the warnings agent (fix/warning-baseline, Q06), Oct 3
- 18 warnings remain, all in files other agents held: `LibraryViewModel+Import.swift:240` and `:303` (name `pathEncoding:` to select ZIPFoundation's throwing initializer; storagegen agreed to make it, #178); `DataDirectoryMigrationTests.swift:75` already fixed on main; 14 in `SpeechService.swift`'s delegate callbacks (wrap the utterance before dispatching as `didFinish` does with `FinishedUtterance`, and read `self.directSynth.isSpeaking`/`.isPaused` instead of the captured synthesizer; add tests for willSpeak, didStart, didPause, didContinue, and didCancel with live and stale utterances first).
- `make test`, `make check`, and CI call xcodebuild without `SWIFT_STRICT_CONCURRENCY=complete`, so they build at project.yml's `minimal` setting and never see these warnings (decide under Q02).
- The legacy scenario harness (`test(_:_:)`, 19 runners, 15 classes) is now `@MainActor`; `MediaGestureDetector` is a final thread-safe class with all state under one lock (each event now sees its settings and buffer together).
- Logs and the extraction script: scratchpad/warnings-baseline.log, warnings-final2.log, warnings-extract.py.

## From the pdftext agent (fix/pdf-short-embedded-text, T09), Oct 3
- The page report exists only at import time; showing `report.pdf?.summary` later in the Library would need it stored with the book.
- `PDFImportReportTests` carries its own copy of the small "After Importing a Book" helper, as three other test files do; worth sharing.
- Not OCR'd: text clipped inside an image, text drawn as vector outlines on a page that also has embedded text, and annotations; OCR text is still written into Markdown raw (pre-existing); only synthetic PDFs were tested, no real searchable scans; the warning and ZIP summary were not heard with VoiceOver.
- PDFs that benefit from Redo Text Extraction: pages under 10 characters (titles, folios, short non-Latin lines), pictures holding words, stamped scans.

## From the storage-generation agent (fix/storage-generation-boundary, S04), Oct 3
- Rebuild Directory still does not hold storage work, so orphan adoption can race an import that has published but not yet added its book (same mechanism would fix it).
- The new event tag `DATA_DIRECTORY_MOVE` is not yet in `LogContentPolicyTests.eventTags` (findings held the file); the two ZIP initializer sites in `LibraryViewModel+Import.swift` (commit 88df4cb) could use main's `Archive.openedForReading(at:)`.
- A reading-stats save in flight during a copy lands in the old directory until the next checkpoint rewrites everything; the 50 ms pause that lets the status line draw before the copy is untimed; moves across real volumes, removal through the real Trash, and VoiceOver speaking the new statuses were not verified.
- ARCHITECTURE text suggested: new entry "The data directory's location" (owner `StorageBoundary.shared` holding the current `StorageGeneration` and earlier ones; only `TextMouthPaths.moveDataDirectory` writes it, between the persistence queues' writes via `LibraryPersistenceService.betweenWrites`; writers run through `StorageBoundary.perform`; a move holds (`holdWork`), waits (`StorageWorkHold.waitForWorkUnderWay`), flushes, copies, publishes, releases; captured paths move with `rebasedToCurrent`/`rebaseToCurrent`; files `Services/StorageGeneration.swift`, `Services/TextMouthPaths.swift`, `ViewModels/LibraryViewModel+Migration.swift`); the concurrency paragraph and the hosted-test sandbox entry (`makeDataDirectoryMoveDestination(_:)`, `DataDirectoryLeakCheck`).

## From the findings agent (fix/board-findings-october-3), Oct 3
- Board #242: `MiscellaneousSettingsView`'s gesture-step pickers have the same hidden-title problem as the steppers ("Event for step 1, Step 1").
- The `DATA_DIRECTORY_MOVE` log tag from S04 still needs adding to `LogContentPolicyTests`' tag list on main.
- DAISY 3 books with tables imported before the fix keep their pipe rows until re-imported (deleting the book's content.md should rebuild it on the next open; untried); DTBook text outside tables is still written raw (open TODO item).
- Not verified: VoiceOver running; a real output-route loss (a test stands in for that report).

## From the cloudcore agent (feature/cloud-core), Oct 3
- Polish: a failed Remove Download says the book "couldn't download" because `removeDownload` throws `.provider`; add `BookCloudError.removalFailed(String)` once no sibling branch is in flight (#273, held).
- `LogContentPolicyTests.eventTags` lacks the six `CLOUD_DOWNLOAD_*` tags, storagegen's `DATA_DIRECTORY_MOVE`, and cloudlist's tags (#283); second findings bundle.
- Needs real drives (cloudtests): whether FileManager's download and remove calls work on Google Drive and Dropbox; whether a stale download error clears when asked again; whether downloading a cloud-only folder fills in its listing; whether every provider reports a file as downloading while it downloads.
- Docs (ARCHITECTURE/README): `TextMouthApp.init` installs the cloud services before SwiftUI creates `LibraryViewModel`; a "Cloud state (FR02)" section (contract types, `UbiquitousItemStatusProvider`, `BookCloudStorageService`, local stand-ins, nothing stored, `BookCloudStates.shared` observed by windows); the `CLOUD_DOWNLOAD_*` tags; helpers `DatalessFiles`, `MachineLocalPaths`, `NetworkReachability`; README line about cloud libraries once list and reader land.
- Timing measured: `state(of:)` over 700 packages took 85 ms locally, 138 ms with every file's state read.

## From the cloudlist agent (feature/cloud-list), Oct 3
- Not verified live: VoiceOver's custom actions (SwiftUI exposes none offscreen without a screen reader; tests check the action list each row builds; press VO-Command-Space on a real row), the context menu, the refusal alert, Show in Finder on a cloud folder; no real drive used.
- Six new log tags `DOWNLOAD_NOW_*` and `REMOVE_DOWNLOAD_*` for `LogContentPolicyTests`' pinned list (second findings bundle).
- README text for the list (notes after the badge, refresh timing, commands in the context menu and VoiceOver actions, selections counted, Download Now announcements, Remove Download never deleting from the cloud and refusing open or unsynced books, Book Info showing stored metadata with "Some details appear once the book is downloaded.") is in the agent's report (tasks/a33fb8068e6763362) for the docs pass.
- Beyond the brief: audiobooks only in the cloud show stored metadata in Book Info; saving metadata into a cloud-only EPUB is refused with a reason; `LibraryView`'s rows and context menu moved into separate functions because the compiler could no longer type-check the body.

## From the clouddownload agent (feature/cloud-reader-download), Oct 3
- Known gap: pausing during a chapter download (for example when the sleep timer expires) does not cancel it, so playback resumes when the download finishes; the fix is one line in `pause(playingPauseSound:)`; P10's move bracket has the same gap. Stop is respected.
- Untested: the Close button, the 30-second timing (tested at 0.05 s); on real drives, that a lookup inside a cloud-only folder fails at once with downloading off (TN3150) and that cloning a cloud-only file fails rather than producing an empty copy (guarded by a check after cloning).
- Log tags `READER_DOWNLOAD_*`, `READER_READ_REFUSED`, `WORKING_COPY_*`, `WORKING_COPIES_SWEPT` for `LogContentPolicyTests` (second findings bundle). `ReaderViewModel.init` gained `cloud: ReaderCloudServices? = nil`.
- README ("Opening books from a cloud library") and ARCHITECTURE ("Reader working copy, FR02") text is in the agent's report (tasks/af71517bf0a57c173) for the docs pass.

## From the cloudmaint agent (feature/cloud-maintenance), Oct 3
- Untested on real drives: whether macOS refuses a stat inside a dataless folder with EDEADLK while downloads are off (the fake models it; cloudtests confirms).
- `LibraryPersistenceService` metadata saves read the stored record first, which downloads a dataless `bookInfo.json` (datadir held the file); Rebuild Directory's empty-folder cleanup would delete a dataless folder full of books if it ever ran with downloads off (today it runs with downloads on); `bookFromPackageInfo` (package import) still drops the fingerprint (other half of finding #17); Redo Text Extraction only logs how many books it skipped, Storage settings does not tell the user.
- Docs: README lines 76-77 (import staging and archive extraction now in ~/Library/Application Support/com.textmouth.TextMouth/Import Staging and /Archive Extraction while the data directory shares the startup volume; library folders otherwise; the old folder swept at launch and removed once empty) and ARCHITECTURE lines 33 and 219; the `MAINTENANCE_SKIPPED_IN_CLOUD` tag for the Logs section and `LogContentPolicyTests`.

## From the datadir agent (feature/cloud-datadir), Oct 3
- The logs move (cf9e895, last commit, self-contained) is merged pending the user's objection; logs written by earlier releases stay in <data directory>/Logs.
- Gap for storagemove (#343): a drive gone for good leaves only Try Again and Quit; "Use This Library" or starting a fresh default library must work while the library is unavailable.
- Not verified: a real drive unplugged, renamed, or remounted (bookmark resolution, /Volumes mount detection, real unmount notifications); real cloud folders; the two-Mac warning alert as shown; VoiceOver timing; permission-denied behaviour on removable volumes; a full suite with the logs commit dropped. Known limit: two Macs adopting the same old cloud library at once could each write a marker.
- The launch check runs synchronously reading metadata only, so a network volume that hangs on stat could still stall launch, as today's loading would.
- New log tags for the policy list: DATA_DIRECTORY_FOUND, _AVAILABLE, _UNAVAILABLE, _UNMOUNTED, _LOST, LIBRARY_IDENTITY, LIBRARY_SESSION, SUBSTITUTIONS_FILE, READING_STATS_FILE.
- README/ARCHITECTURE text (logs location, library-identity.json, Sessions/<Mac ID>.json lease every minute with a 3-minute warning window and 30-day cleanup, the Library Not Available screen and Storage status, never creating a custom directory, ignoring a synced dataDirectoryPath; availability state owned by LibraryViewModel.dataDirectoryUnavailability and DataDirectoryGate, DataDirectoryCheck, LibraryIdentity plus DataDirectoryPreferences, LibrarySessionLease.shared) is in the agent's report (tasks/a2aad27ae48f6caa6) for the docs pass.

## From the cloudtests agent (test/cloud-real-drives), Oct 3
- Dropbox answers: FileManager download and eviction work (upload within 5 s, eviction immediate, re-download within 1 s); `Progress.addSubscriber` hears progress but only 0% and 100% for small files; evicted files report real sizes; modification times drift by 9 to 118 ns after re-download (microseconds kept), so `FileStamp` in `TextCacheFingerprint.swift` should compare at microsecond precision (board #355); an APFS clone stays readable after the original's eviction; a package renamed in publishes as one item; dot-folders sync within 4 s; Remove Download refuses while uploading.
- iCloud Drive and Google Drive: nothing ran; run with TEST_RUNNER_TEXTMOUTH_CLOUD_TEST_ROOTS naming "TextMouth Cloud Tests" folders in each drive once the user agrees (about 36 MB up and 10 MB down per drive).
- Unverified on Dropbox: the app's own screens and commands (manual matrix), behaviour while Dropbox is paused, quit, signed out, or offline, progress within one large file, `state(of:)` on a real drive under hosted tests.
- The manual test matrix with VoiceOver steps is in the agent's report (tasks/afa302f14d9ecbd3d) and copied to CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md.
- DerivedData-cloudtests (895 MB) kept for quick opt-in reruns; delete when done.

## From the storagemove agent (feature/cloud-storage-settings), Oct 3
- #382: an import question already showing when a move starts can be answered during the copy; "Replace Existing" could leave a stray package in the new library; a three-line guard in `answerImportDecision` closes it. #381: a doc comment in `StorageGeneration.swift` still says moves copy on the main actor. New tag `DATA_DIRECTORY_SWITCH` for the log policy list.
- Other Settings tabs stay usable during a move; a substitutions or statistics change made late in the copy stays only in the old folder (those files are copied last). The Library Not Available screen could carry one sentence pointing to Storage settings' Choose Another Library and Use Default Location (user's call: they asked for Try Again and Quit only).
- Not verified: moves on real cloud and external drives, a real relaunch, folder-metadata copying on exFAT, the sheet with VoiceOver running.
- README (Storage settings) and ARCHITECTURE ("Its location, and moving it": StorageDestinationAssessment, StorageChoice, StorageWording, withStorageWorkHeld, copyAndPublish on OffMainWork with the task-local DataDirectoryMigrator.copyObserver, DataDirectoryCopyPlan, DataDirectoryCopyProgress, DataDirectoryMoveProgress, DataDirectoryMoveSheet, TextMouthRelauncher) text is in the agent's report (tasks/a72b5d41f2753513e) for the docs pass.

## From the findings2 agent (fix/findings-october-3-second), Oct 3
- Cosmetic: storagemove's waiting helper logs waits under `DATA_DIRECTORY_MOVE` even for a Rebuild Directory; fingerprint times are truncated to the microsecond (about 6% of Dropbox re-downloads still cross a microsecond and cost one digest read; comparing within ±1 µs would catch every case).
- Idea: the log-policy test could also fail when a new event tag lands without being pinned.
- Not live: VoiceOver, real cloud drives, real media keys; Rebuild's waiting status and Redo's result line in Storage settings not exercised in a hosted window; the sleep timer tested with a zero-second fade only.
- Docs: every synthesizer callback's utterance is held (`ReportedUtterance`); a package record only in the cloud is never read or written (`BOOK_RECORD_IN_CLOUD`); Rebuild Directory holds storage work and is async; the `bookFromPackageInfo` duplication note is obsolete.

## From the strict agent (fix/strict-concurrency-requirement, Q02), Oct 3
- README passages for the build section are on the board (#429); apply as a docs commit after the merge.
- Possible follow-ups: a source-scan test that fails when a new `@unchecked Sendable` has no stated reason; `betweenWrites` in the persistence service would deadlock if its body called back into the service; the render coordinator's `DispatchQueue.main.sync` would deadlock if the main thread ever waited on that queue.
- Swift 6 mode: one type-inference error at `LegacyBookMigration.swift:292` (not concurrency); rewritten as an explicit closure, the suite passes in Swift 6 mode (not committed).
- Not verified: the workflow on GitHub; the synthesizer's callback thread probed only on this Mac; no Thread Sanitizer run. `make check` now takes about 7 minutes.

## From the polish1 agent (fix/cloud-polish-october-3), Oct 3
- After a move ends, the refusal message stays visible in the import sheet until the next press; clearing it needs a change in the sheet's view.
- Board #381 (stale comment in `StorageBoundary.perform` saying moves copy on the main actor) is still open; ARCHITECTURE notes are on the board (#442), including a stale sentence saying the app builds with minimal concurrency checking; manual matrix row 6 should say to expect a percentage within a large file on drives that publish one.
- When the iCloud Drive and Google Drive runs are enabled, check whether fractions strictly between 0 and 1 appear (a larger file or Network Link Conditioner may be needed), that percent rises while the completed-file count stays put, and whether published file paths differ in spelling from the listing's.

## From the drivetests agent (iCloud Drive and Google Drive runs), Oct 3
- Google Drive: all five opt-in tests pass (upload within 25 s, eviction immediate, re-download within 1 s; progress per file but only 0% and 100% on fast downloads, 14 to 24 fractions on uploads; evicted sizes real; mtime drifts 12 to 107 ns; clone survives eviction; package renamed in publishes as one item; dot-folders sync within 29 s; Remove Download refused while uploading; Google waits 15 to 30 s before uploading).
- iCloud Drive syncs a .tmb package as ONE item: files inside carry no upload or download flags, so the app read every book as uploaded, never refused Remove Download, failed it file by file with "doesn't exist", and heard no per-file progress (the package publishes 4 to 5 fractions). Fix in progress on fix/cloud-package-as-one-item (cloudpackage); the opt-in test's upload check must fall back to the package's flags. Unverified on iCloud until then: questions 1 to 5, download progress, Optimize Mac Storage behaviour.
- Both test folders deleted (the iCloud one held only a Finder .DS_Store, removed); DerivedData-drivetests deleted.

## Orchestrator finding, Oct 3: hosted-test sandboxes are never deleted
- `TextMouthRuntime`'s per-process sandbox (`$TMPDIR/TextMouthTests-<pid>`) is left behind by every hosted run; 1,025 dead ones (about 450 MB, some 110 to 172 MB each) were removed by hand after the disk hit 100% full during the performance reviews. Fix: delete the sandbox at process exit (an exit handler plus the test observer's teardown) and, at the next run, sweep sandboxes whose pid is gone; keep one when `TEXTMOUTH_KEEP_SANDBOX` is set for debugging. Goes into the performance fix wave.

## From the loglocation agent (fix/log-location-setting), Oct 3
- Docs to apply (README items 1 to 7 and ARCHITECTURE items 1 to 6) are in the agent's report (tasks/a69b6502b8b0c9209); CLOUD-STORAGE-PLAN line 115 ("Logs move to ~/Library/Logs/TextMouth") is superseded; the manual matrix check 12 grep path becomes <data directory>/Logs/textmouth_debug.log.
- Limits: before the launch check runs the gate is open; a line written during a move's copy after Logs was copied stays in the old folder; logs already in ~/Library/Logs/TextMouth from the cf9e895 builds are left; two untested paths (a log that becomes cloud-only after the check; truncating a cloud-only log); no real VoiceOver or real cloud drive.

## Orchestrator note, Oct 3 ~11:50: a crash popup from an agent's throwaway test
- The perfaudio agent's `PerfAudioThrowawayMeasurements.testSynthesizerPieceSizes` fulfilled an expectation more than once from the synthesizer's buffer callback, so the hosted test process aborted and macOS showed the user a crash report (process path under /private/tmp). The agent was told to fix it; the common brief now has a "Crash-proof test runs" rule.

## From the perfaudio agent (perf/audio-memory, PERF04 and PERF09), Oct 3
- PERF09 needs the reader to call `AudioPlaybackService.setFileAfterCurrent(_:)` from `ReaderViewModel+Playback.startCurrentChapterAudio` for multi-file chapters, never at the last chapter, never while the "End of document" sleep timer is set, and never when the next file is only in the cloud (board #519); until then track changes behave as before.
- Nothing was listened to; PERF09 not tried on real multi-file audiobooks; two opt-in benchmark tests skip by default; `scheduledSegmentAudioByteCount` now reports the slices waiting in the player.

## From the perfmodel agent (perf/library-model, PERF10/11/12/29/07), Oct 3
- Continue Listening's time left now updates at checkpoints, pause, stop, and close rather than every second (wire it to LiveReadingPositions if per-second updates are wanted); a launch with no voice chosen still lists voices immediately to pick a default; checkpoints still re-sort Recent and Last Opened (at most once per 30 s).
- Not verified: the running app, live VoiceOver, Release-build numbers, the real library (a generated 643-book one was used), first-launch timing.

## From the perfspeech agent (perf/speech-preparation, PERF01/02/03/05/06/08), Oct 3
- Merge note for perfviewsfix: `releaseWhatGrowsWithTheBook()` must call `speechService.releaseSpeech()` instead of `speechService.audioEngine.discardRenderedAudio()`, or every reader close builds a speech engine (posted on the board).
- PERF09's reader wiring (`setFileAfterCurrent` from `startCurrentChapterAudio`) is still open: follow-up bundle.
- An outdated background preparation of a long chapter finishes and is discarded rather than cancelled; the voice warm-up keeps one small synthesizer per voice per session; opt-in benchmarks run with TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1; no Release-build numbers, nothing listened to, no truly cold first-word timing.

## From the perftextfix agent (perf/text-pipeline, PERF18 to PERF25), Oct 3
- Not compared on the reviewer's 15 copied library books (deleted for disk space); the DAISY folder-copy path (an APFS clone that keeps permissions and extended attributes) is exercised only by tests; copying a 64 MB DAISY file from a ZIP is about 1 ms per MB slower than the whole-file read but uses 1.5 MB instead of 77.
- Opening a whole book is unchanged within noise: the Markdown parse still sets the open's time and its +304 MB peak (PERF22's later options: walk cmark directly or store the reading text).
- A Markdown line reading exactly `<!-- chapter: -->` used to crash the app; it now names an untitled chapter.

## From the cloudpackage agent (fix/cloud-package-as-one-item), Oct 3
- Board #624: `LibraryBookInfoLoader` checks whether a book file is dataless with downloading allowed, so Book Info on an evicted iCloud package would download the whole book; use `LocalBookFiles.availability(of:isDataless:)` as the reader does (follow-up bundle).
- iCloud facts: evicting or downloading a file inside a package is refused with "doesn't exist"; evicting the package makes the whole folder dataless and nothing inside can be looked up while evicted (dataless checks inside must run with downloading off); modification times become whole seconds after a download; a Progress subscription on a Google package folder also hears every file's progress. Dropbox was not rerun; intermediate iCloud download fractions were not seen on this connection (41 upload fractions were).
- ARCHITECTURE notes: the package-or-files decision and what each operation then uses; the flag reading added to the provider; listening on the package and the stricter progress listener.

## From the perfpersist agent (perf/persistence-and-launch, PERF15/14/13/17/16), Oct 3
- Record format: `bookInfo.json` no longer holds `contentIndex`; `contentIndex.json` (compact) sits beside it, written before bookInfo.json whenever a record with an index is saved; an embedded index in an old record still wins; migration happens on first save, no version bump; an older build reading a migrated record re-analyses the book once. `library.json` is compact. `reading-checkpoints.json` at the data directory root lists books whose record holds a checkpoint newer than the index; launch's repair reconciles it (cloud-only records skipped).
- Accepted races: removing a book in another window during a folder move; creating a folder in another window during cleanup. A Finder-started download of a second book during a long download shows at the next full refresh (up to 60 s). `DataDirectoryMigrator` still rewrites the index file during a move (wasted work). Tests on other branches that read config.json right after a settings change must call `flushScheduledSave()` first.
- Not verified: live VoiceOver for the sheets' working state and the move announcement; Release numbers; real cloud runs for a cloud-only config.json or a cloud-library refresh.
- Docs: the record format (contentIndex.json, compact library.json, reading-checkpoints.json), folder edits as held storage work, config save coalescing, the cloud refresh's one location read (ARCHITECTURE package records, library index, data directory, cloud state; README data directory layout).

## From the perfviewsfix agent (perf/views-and-windows, PERF26/27/28/30/31/32/33), Oct 3
- Not reported to Apple: AppKit keeps every closed window that was ever key (a KeyViewProxy held by an observer block in -[NSView _commonAwake]); SwiftUI still keeps 0.5 to 0.6 MB per closed window.
- `ArchiveExtractionDirectory` repeats the process-ID-only check the sandbox sweep had (a reused pid; finding #652); `BookmarkKeyboardAccessTests` flaked once more (#648) and `StorageGenerationMoveTests` once (#633) under load.
- Not verified: real window close and reopen (simulated offscreen); live VoiceOver (the closed-window placeholder reads "Library"); Release numbers; TEST_RUNNER_TEXTMOUTH_KEEP_SANDBOX end to end.
- Docs: the closed-window behavior, `LibraryBookListRow`, `ReaderSnapshot` and `SheetOverOneReader`, `ViewBodyCounter` (Debug only), the sandbox sweep rules, the opt-in view benchmarks (TEST_RUNNER_TEXTMOUTH_VIEW_BENCHMARKS=1).

## From the findings3 agent (fix/findings-october-3-third), Oct 3
- Board #676, pre-existing: an "End of document" sleep timer never stops an audiobook at a chapter's end with the default zero fade (VoiceOver says "Sleep timer expired. Playback paused." and the next chapter plays anyway); text books follow the same path. Needs the user's decision: does End of document mean the end of each chapter or of the book? (P01 design item.)
- Board #673 (from docs2): while books move between folders, a data-directory move or Rebuild Directory is refused with "TextMouth is already moving its data directory", which is not true; two tests pin the wording.
- Docs for docs2: the audiobook entry should mention the queued next chapter file; the data-directory entry that records are written as saves leaving content index files as copied; Book Info checks the package then the file with downloading off.
- A moved record's revision now goes up by one and keeps the analysis fields that match its index; a damaged index file is copied as it is instead of deleted.

## From the ci agent (fix/ci-hosted-accessibility-skips), Oct 3
- Expected CI result after merge: 3495 tests, 57 skipped, no accessibility failures; whether the runner's empty accessibility tree comes from having no assistive client or from macOS 26.6 is unknown (this Mac runs 26.3.1 with VoiceOver); keyboard navigation is off on the runner (4 bookmark keyboard tests skip there); 7 gitignored fixtures exist only in the main checkout, so CI imports 12 books instead of 19 in one test.
- `withHostedControls` now throws (new callers need `try`); `testAFailedSettingsSaveIsLeftToTheFailureBanner` has a fixed timing window and failed once under load (#741).
- Docs: ARCHITECTURE's test-support notes could mention `HostedWindowAccessibility` and the expected CI skip count.

## From the findings4 agent (fix/findings-october-3-fourth), Oct 3
- Use This Library is refused only during a data-directory move; it does not wait for a rebuild or a folder edit, so it could quit mid-operation (hard to reach from the UI).
- Archive-import tests fail whenever under 1 GB is free on the library's disk: keep 2 GB free before any merge suite.
- Docs: README line ~117 (the pointer), ARCHITECTURE ~116 (holds have reasons; `LibraryTransitionError` removed), ~139 (sweep uses the start-time rule), ~350 (`isFolderMakerRunning`), ~438 (#652 resolved); manual matrix row 9 expects the pointer sentence. The VoiceOver reading-order test skips here (no accessibility text from hosted SwiftUI).

## From the keeponmac agent (feature/keep-on-this-mac), Oct 3
- Risks left: the session lease still writes its own file on the main thread with downloading on (a first write on a Mac whose Sessions folder has not synced could wait on the network); a first launch on a new Mac before substitutions.json syncs writes the standard rules, which will conflict with the synced file; an offline Mac with evicted kept books logs one batch of download lines every five minutes. Conflict copies are never merged or cleaned up (later).
- `BookCloudError` gained `keptOnThisMac`; `MultiMacCrashSafetyTests.makeOwnDataDirectory` is a fourth copy of a private test helper; not verified: real eviction and re-download, the menu-to-window path end to end, the full suite in Swift 6 mode.
- README ("Keep on This Mac", "Several Macs") and ARCHITECTURE (cloud-state entry "Books kept on this Mac", data-directory entry "Files several Macs write", the list's cloud commands, this Mac's own folders, SavedFile) text is in the agent's report (tasks/a72e04a0ac56ffc09) for the next docs pass.

## From the sleeptimer agent (fix/sleep-timer-chapter-and-book-ends), Oct 3
- Board #787: the End of current heading timer never fires during normal playback; it advances only on manual heading jumps and fires after two (next bundle).
- The fade steps four times a second (may be audible on a one-second fade); DAISY and m4b chapter fades are only unit-tested; the sheet's button-press test skips without an assistive client; "End of current heading" stays in the New Timer section.
- Docs: ARCHITECTURE's sleep-timer entry (owned by the reader through `readerID`; `expireAtChapterEnd`, `stopsPlaybackAtChapterEnd`; the two timers, the stop, the fade), the audiobook bullet mentioning "the end of the document", the reading-path sentence; README's sleep timer section.

## From the swift6 agent (fix/swift-6-language-mode), Oct 3
- Board #732: `VoiceWarmUp.writeOneWord` (SpeechService.swift) hands AVSpeechSynthesizer a buffer callback that Swift 6 treats as main-actor-only; it relies on the synthesizer calling back on the main thread (38 of 38 did); build the callback in a `nonisolated` helper (next bundle).
- `SWIFT_STRICT_CONCURRENCY: complete` is kept though the mode implies it; removing it touches the docs and the agents' build command.
- Docs: README line ~223 and ARCHITECTURE line 28 wording is in the agent's report (tasks/ac92eff24609c67cc); `make check` was not rerun at the final tip (a Release build of the sleep-timer code is pending CI).

## From the perfbaselines agent (test/performance-baselines), Oct 3
- `make check` was never run end to end on the branch (disk); `check.sh --dry-run`, `make check-selftest` (48 cases) and a stubbed `swift` cover the strict step; CI's first run of the new gate is the real check.
- The perf tests skip on any other Mac model or build configuration even in strict mode (so CI measures nothing); recording mode never skips for that; a missing baselines file fails instead of skipping.
- Speech is prepared at pause level 1, not the developer's real level (config.json not read); render memory uses synthetic audio sized from PERF04's real render.
- `PersistenceCostTests` checkpoint helpers became internal; xcodegen copies the two JSON files into the test bundle (harmless; the tests read the source folder).
- Docs: README (make targets, hosted-suite skip list, a new "The performance baselines" section, the make check paragraph) and ARCHITECTURE ("Performance baselines" under the hosted-test sandbox) wording is in the agent's report (tasks/ad12c3edd8bccd12a) and scratchpad/perfbaselines/readme-text.md.

## From the docs3 agent (docs/october-3-evening), Oct 3
- ARCHITECTURE now states that Use This Library takes no hold on storage work (refused only during a move); findings5 item 5 changes that, so its docs must follow.
- README keeps "until the end of the heading" for the sleep timer; ARCHITECTURE says only heading navigation reports a boundary (#787, findings5 item 1): update both when findings5 lands.
- Manual matrix row 9 asks the user to check by ear that the Storage settings pointer is read right after the reason (the reading-order test always skips here).
- Not verified: the GitHub runner's lack of accessibility (the README states which kinds of test skip, not a count); re-downloading a kept book after a real eviction.

## From the findings5 agent (fix/findings-october-3-fifth), Oct 3
- Heading timer: moving backward (Previous Heading, a skip back across the heading's start) leaves the timer waiting for the same place; a forward move to or past it ends the timer at once (announcement after the move's words, medium priority); the crossing is checked in the reader's 0.12 s refresh; an End of heading timer also stops at the end of the book; not verified with single-file (m4b-style) audiobooks.
- Lease: `OffMainWork.run` gained an optional queue; `refresh()` awaitable; the lease takes the cloud services' provider; quitting waits at most 2 s for this Mac's lease file to go.
- Substitutions: a change made to the in-memory standard rules in the window before a synced file arrives is dropped (as the cloud and unavailable-library cases already do).
- Use This Library: new hold reason `.switchingLibraries`, wording "TextMouth is switching to another library and opening again on it."
- Board #829: `ReaderView`'s body is at the compiler's type-check limit (a defaulted parameter on `announceToVoiceOver` broke the build; a separate method was added instead).
- Docs: README (sleep timer "until the end of the heading" now true in playback; Use This Library refusal; substitutions defaults; Several Macs lease) and ARCHITECTURE (sleep-timer entry: heading boundary from the refresh; lease queue; `.switchingLibraries` hold; substitutions written only on change).

## From the readingtext agent (perf/reading-text-cache), Oct 3
- Cache at ~/Library/Caches/com.textmouth.TextMouth/Reading Text/<book ID>.readingtext for content.md >= 1 MiB (183 of the user's 625 text books); first opens unchanged; reopens about ten times faster; peak memory much lower; text byte-identical on every measured book.
- Rejected with numbers: lazy per-chapter parsing (no help for one-chapter books; ~70 reader call sites read chapter text), a direct cmark walk (still 3x slower than the cache; must reproduce swift-markdown's heading labels for heading IDs), a spoken-text cache (background preparation at open does the job without disk or invalidation).
- Follow-ups: EPUB metadata is re-read on every open (43 ms of the 28 MB book's 110 ms reopen); Play pressed before the background preparation finishes still prepares on the main thread (up to ~4 s for a 20 MB one-chapter book), so Play could wait for the background result; the open.textBook baseline now measures a cached open (208 to 16.8 ms, PERFORMANCE NOTE), so a first-open baseline and a cached-open baseline should be separate and the file re-recorded on a quiet Mac.
- Not verified: real sync clients rewriting content.md's extended attributes (one extra parse); Debug builds share a build identity so the cache is not reset between development builds.
- Docs: README (this Mac's own folders: the Reading Text cache; the Play description) and ARCHITECTURE (a kept reading text entry after the fingerprints; the ChapterSpeechCache entry; the reader-open paragraph) wording is in the agent's report (tasks/aefd149845ee1b489).

## From the readingtext2 agent (perf/reading-text-followups), Oct 3
- Baselines re-recorded with the one-minute load at 5.4 to 7.4 of 8 cores (below the skip threshold); every number within about 1 percent of the quiet recording; open.textBook 207.6 ms (first open), open.textBookCached 11.8 ms.
- 606 of the user's 629 EPUBs have no metadata fields on their rows, so they get the background read at every open (off the main thread, after the book shows); filling the fields in on first read would change the library and the records, so it was left (possible follow-up).
- Behaviour change: a row that keeps metadata for an EPUB whose file is now unreadable shows that metadata in the editor instead of the simple title-and-author editor.
- Play waits only for chapters over 100,000 characters (the look-ahead's limit); a settings change during the wait prepares fresh on the main thread; speech becoming ready while a Where Am I announcement speaks ends the play quietly, so the user presses Play again (edge case to revisit).
- The findings5 agent's DerivedData (1.4 GB) was left behind despite its report; removed by the orchestrator.
- Docs: README (Speed and memory bullet about Play waiting; Opening and importing: EPUB metadata; the performance baselines list and the measured items) and ARCHITECTURE (the reader's loading paragraph; the ChapterSpeechCache entry; the baselines entry) wording is in the agent's report (tasks/a88702aa729cff9fd).

## From the rssplan agent (docs/rss-reader-research), Oct 3
- Board #867: the Folders rotor says "1 books" (`LibraryView.swift` line 380) — next bundle, through `CountWording`.
- Measured: XMLParser stops at common feed faults (nbsp entity, bare ampersand, blank line before the declaration, control characters, wrong encoding, truncation); XMLDocument's tidy mode reads them all but must use `nodeLoadExternalEntitiesNever` (it read /etc/hosts through an external entity by default); AVFoundation plays Ogg Opus/Vorbis and MP4 video though imports reject those extensions today; only one of three podcast hosts honours conditional requests; iTunes Search returns feed URLs without a key.
- Ten open questions for the user are in the document.

## From the transcribeplan agent (docs/transcription-research), Oct 3
- SpeechAnalyzer (macOS 26): about 65 seconds of audio per second on this M3; 7.5 to 11 percent of words wrong on the two DAISY fixtures; words timed in 60 ms steps with pauses folded into the next word; resume at a time keeps file-relative times; cancel within 2 ms; the English model (139 MB) is already installed; no permission prompt appeared. The audio-buffer path drew four Swift 6 concurrency warnings in the prototype (watch for them when implementing).
- The older SFSpeechRecognizer path (macOS 14 and 15) was not run (it needs the permission prompt); DictationTranscriber stood in: 24 seconds of audio per second, 9.2 percent wrong, and some non-numeric time ranges to guard against.
- Seven open questions for the user are in the document; the prototype and scripts are in scratchpad/transcribe.

## From the audioplan agent (docs/audio-editor-research), Oct 3
- Recording: AVCaptureSession with a chosen microphone into 16-bit PCM CAF (the only format that survived a simulated crash); NSMicrophoneUsageDescription required (the app exits without it) plus the Audio Input entitlement; ad-hoc signing brings the microphone prompt back after every rebuild (TN3127); denied permission records silence.
- Editing: undoable edit list previewed through AVMutableComposition (sample-exact cuts, moves, inserted silence); passthrough export refuses empty ranges and edited AAC; pause search found all 31 pauses within 9 ms at 6,500x real time; offline effects at 33 to 880x real time under 20 MB; voice isolation removes music too; M4A/M4B chapter writing needs `beforeMainMediaDataNotInterleaved` on long files; the editor should be its own window (the reader's cursor has 0.1 s resolution).
- A prototype crash left ~/Library/Logs/DiagnosticReports/proto-2026-10-03-231609.ips (reverb connected in mono); tell the user if a problem report appears.
- Ten open questions for the user are in the document.

## From the appsize agent (build/smaller-app), Oct 3-4
- The size came from Xcode's generated scheme compiling everything with code coverage (13.5 MB) and unstripped symbol tables (16.9 MB); `make build` now passes CLANG_COVERAGE_MAPPING=NO (project.yml cannot override the scheme or reach the packages); Debug test builds still carry coverage nobody reads (turning it off changes the conditions the baselines were recorded in).
- `-Osize` rejected: 0.8 MB for 5 to 8 percent slower opens and 41 to 47 percent slower on two text loops.
- Remaining: the app's own code 6.3 MB, SwiftSoup 3.0 MB (replacing it is a large risky rewrite; the RSS plan relies on it), swift-markdown with cmark 0.8 MB (one file uses it; Foundation's Markdown drops the HTML comments the heading annotations live in), Release builds arm64 only (universal would be about 22 MB).
- `make install` keeps the last 5 installed builds' dSYMs in build/installed-dSYMs (about 58 MB each); `make clean` removes them with the rest of build/.
- Not verified: a real `make install`; `make check` was not rerun after the final commit (install recipes and self-test only). Board #875 was a mistaken placeholder, corrected by #876.

## From the transcribecore agent (feature/transcription-core), Oct 4
- Not verified: cancelling the real recognizer mid-file (scripted engine only); macOS 14/15 path never run; reserve-and-retry never triggered; missing-model states only scripted; long books (longest run 51 min); several Macs only simulated; an older build re-saving a package drops the index's transcript part (rebuilt from transcript.json at the next open).
- Not built: a Delete Transcript command; the model download (needs consent; API noted in the report); the UI task gets `TranscriptionService.shared.transcribeAndSave`, `TranscriptionAvailability`, `TranscriptionLanguage.preference`, `DocumentContent.transcript`, `ReaderViewModel.shownText`.
- Docs wording: scratchpad/transcribecore-docs-wording.md.
- Merge notes: exportedit also edits `ReaderViewModel.readContent`/`refreshPlaybackUI` (separate hunks); config fields adjacent to other agents' fields.

## From the recordcore agent (feature/recording), Oct 4
- Not verified: real microphone capture (opt-in test never run), macOS keeping the permission across builds (checked offline with codesign -R), make build/check/install not run (disk), VoiceOver with the live window (the 1-second pause after "Recording from X." may be short at slow speech rates), AirPods switch to the headset profile while recording (macOS limitation).
- Decisions: origin.json in the package (older builds leave unknown files alone); two settings recordingOriginalPolicy and recordingOriginalDays; signing after the build by certificate hash, no trust setting (a password dialog); Command-only shortcuts in the Record window (the shortcut manager swallows single keys); takes in ~/Library/Application Support/com.textmouth.TextMouth/Recordings until saved.
- Follow-ups: recover takes left by a crash; ask before quitting while recording; pause playing readers when recording starts; transcript.json needs the same isPackageContentName exclusion (transcribecore's owner); the per-book policy override exists but nothing sets it (editor).
- User action after merge: on this Mac the identity already exists; `make install` signs; first Record answers the microphone prompt once; a locked keychain over SSH needs `security unlock-keychain`.
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/adf5d52c0fd6ea068).

## From the airpods agent (fix/media-commands-regression), Oct 4
- Cause (strong circumstantial evidence): hosted test suites running on this Mac joined the system's media session under the app's bundle identifier and reported silent test playback as playing, so macOS sent the AirPods presses to the test host (exportedit's suite ran 07:59 to 08:07, when the user tried them; its IntegrationSleepTimerTests failures look like a Pause press landing in the tests). Until every branch rebases onto the fix, a running suite can still take the AirPods; pressing Play or Pause once in TextMouth gets them back.
- Not verified: the thread MediaPlayer calls handlers on; that the test host received the presses (no trace log arrived); how macOS reacts to the brief "stopped" blip.
- Quirks left: pausing direct speech before its first word is reported makes Resume restart the chapter; after Continue to Next Book, Now Playing shows the finished book as playing until the next starts.
- README line 50 stays accurate; no docs change needed beyond ARCHITECTURE's hosted-sandbox note (the test host never joins the media session).

## From the exportedit agent (feature/export-and-edit-text), Oct 4
- Still open: an edit saved while TextMouth is closed, and Redo after a relaunch, replace edits without a copy (no session exists then); finding #966: transcript.json counts as book content in isPackageContentName (transcribeui or a bundle); Redo's status says Done when it skips a held book.
- Decisions: copies are named content.md.edited-<UTC time>; a source-changed edit is copied but not held; a Book menu was added for reader windows; Export and Edit Text are in the context menu but not the VoiceOver Actions menu (as Open, Book Info, Move); the first-time explanation is kept out of config.json (editTextExplained).
- Not verified live: real editors, VoiceOver reading the held message, the Export announcement with Settings in front.
- Docs: README (Export dialog, Editing a book's text, package file list, config.json fields, the Book menu) and ARCHITECTURE (Exports section, Edited text entry, menus, logs, shared helpers) wording in the agent's two reports (tasks/a823db8ca68577104).

## From the feedcore agent (feature/feeds-core), Oct 4
- Not verified: live servers (304, redirects with validators, real resume data, ATS at runtime), the hourly timer in the running app, two Macs editing one feed record (last writer wins), very large feeds, iCloud deletion rule (fake storage only).
- Follow-ups not done: resume data saved at quit; re-importing video episode packages (Open Book still refuses video files); deleting played downloads no Mac holds whole; retrying automatic downloads put off by a metered network; failed record saves only logged, not reported to the failure center; Apple Podcasts lookup and JSON Feed.
- Decisions: a threshold setting is off at or below its off value (repeated symbols unchanged); feeds without dates (LibriVox) follow the feed's order and by default keep only the last 10 chapters (the user may want -1 for audiobook feeds); articles use the item's text unless under 200 words with a link; video kept as .mp4/.m4v/.mov with the audio format set; automatic deletion is permanent, never a book open in a reader, never during index recovery, never a package not wholly on this Mac.
- UI API: FeedCenter.shared (subscribe/unsubscribe/refresh/refreshAll/download/open/cancelDownload/markPlayed/markUnplayed/deleteDownload/deleteItem/setFolder/setKeepEntries/setDeleteDownloadsDaysAfterPlayed; feeds, feed(inFolder:), listedItems(of:), state(of:), fetchState(of:); FeedItemState.visibleNote/spokenNote; events subject; SettingsViewModel.feedSettings).
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/a977798f84612328f).

## From the docs4 agent (docs/october-4-wave-1), Oct 4
- README and ARCHITECTURE say nothing starts a transcription or subscribes to a feed yet: transcribeui and feedui must update those lines when they land; the editor branch renames RecordingOriginalPolicy to AudioOriginalPolicy (ARCHITECTURE names the old type); #966 (transcript.json in isPackageContentName) still open.

## Orchestrator note, Oct 4 10:56: a crash dialog from editorcore's test host
- AudioEditSaveTests.testAnEditIsSavedIntoTheBooksFileAndUndoneFromTheOriginal (line 41) trapped on an array subscript inside an XCTAssertEqual autoclosure; the user saw the system crash report. The agent was told to guard counts and audit its tests; the board got the reminder.

## From the transcribeui agent (feature/transcription-ui), Oct 4
- Not verified: a real model download, a real transcription through the UI (scripted engine), VoiceOver by hand, how the sheets and alerts stack in a real window, macOS 14/15, quitting during a transcription.
- Follow-ups: Where Am I could quote the current sentence of a transcript; transcriptions could write their own log lines; the suite's disk fell to 1.5 GB during its run.
- Decisions: progress in the same sheet; the Transcription group in the Playback tab; the offer after import is one of the import's own questions; an edit that changes the chapter count is refused and kept; #966 fixed for transcript.json.
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/a4774f58e9a6f7885); the docs' "nothing starts a transcription yet" line must go.

## From the editorcore agent (feature/audio-editor-core), Oct 4
- Incidents: the AudioEditSaveTests trap (an AVAudioFile read returned fewer frames; reads loop now; checked subscripts everywhere); a 10-minute hang in the shared chaptered-AAC fixture (fixed: beforeMainMediaDataNotInterleaved); a scratch ffmpeg probe filled the disk to 178 MB free at 11:55 (deleted within a minute).
- Found against ffmpeg 7.1.1: silenceremove rewritten from ffmpeg's source; loudnorm single-pass differs on speech (noted); MP3 length allows for LAME's delay and padding.
- LAME measured: about 0.29 MB in a universal app, LGPL 2; the ffmpeg route is implemented ("MP3 (needs ffmpeg)").
- Follow-ups: remap bookmarks and positions after an edit; export kept originals; DAISY books not editable; clear stale Caches/Audio Edits after a crash; two-pass loudnorm through ffmpeg; the iTunes gapless tag for MP3s.
- Renamed RecordingOriginalPolicy to AudioOriginalPolicy (settings keys unchanged); deleted RecordingTakeSweep and RecordingSettingsSection (now the Audio Editing group).
- Docs: scratchpad/editorcore/docs-wording.txt.

## From the feedui agent (feature/feeds-ui), Oct 4
- Not verified: live VoiceOver (speech, rotor, Address-field focus), real feeds over the network, the notification permission prompt and banners, the Preferences window at 700 points with nine tabs.
- Decisions: a new folder is made only after the feed is read, named after it; the Feeds section shows every feed at the root and in All Items, the feeds below a folder inside it; feed and item rows are buttons like folder rows; alerts and notifications follow only refreshes TextMouth makes by itself; Add Feed is Shift-Command-F; the tab is "Feeds"; #867 fixed.
- Testing lesson (#1077): hosted tests cannot press SwiftUI checkboxes (no action); steppers are raised through accessibility elements; number fields in a Form need .labelsHidden().
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/a269b279302ad4417); the docs' "nothing subscribes to a feed yet" line must go.

## From the docs5 agent (docs/october-4-wave-2), Oct 4
- Board #1091: Feed Info's hint says "Preferences, Feeds" while the app says Settings; #1092: the offer's hint suggests transcribing starts after the download, but it starts only when the model was already there; ARCHITECTURE calls a type ContentView that is really LibraryWindowView (older).
- Nothing sets a book's own original policy yet and nothing creates the filter presets file (both wait for the editor window).

## From the transcribeclean agent (feature/transcript-cleanup), Oct 4
- Headline: WER person 6.7%, TPB Narrator 10.4%, Alex 4.9%, Daniel 3.4%; a narrator's errors are conventions (pages, figures, compounds, names, spelling); only about 0.3% truly misheard; confidence cannot pick out errors on human speech; en-GB fixes British spelling; held-out corrections were right 13 times and wrong 90, so the built-in rule list is empty.
- Not verified: VoiceOver by hand, Edit Rules… opening a real editor, cloud behaviour of the rule file and the before-cleanup copy, more than one human narrator.
- Merge overlap with editorui on adjacent lines in commands(for:), TranscriptionPresenter.perform, ReaderBookCommands, MenuCommands (agreed on the board: the second keeps both).
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/aa8b6dd6c69cd29c1); the research document is TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md.

## Orchestrator note, Oct 4 14:28: a second crash dialog, from editorui's test host
- AudioEditorWindowTests.testEachSheetStartsVoiceOverOnOneControl: swift_unownedRetainStrong abort in the test support's EditorAnnouncements.announce closure (AudioEditorTestSupport.swift), reached from AudioEditorModel.announce via addMarker. An unowned reference to a released recorder. The agent was told to capture weakly, audit its tests, and report; reported to the user at ~17:40.

## From the editorui agent (feature/audio-editor-window), Oct 4
- The 14:28 crash: unowned captures in the test recorder and launcher stand-in; now weak, the harness kept alive for the test; no unowned or force unwraps remain in the editor tests.
- Engine bugs fixed: a save deleted the scratch folder the open session kept using (filters, silence, MP3 export failed after a save); a recording at the very end wrote the lossless take's packet padding (up to 93 ms).
- Follow-ups: markers are not saved when the window closes; quitting does not ask about unsaved edits (they persist in edits.json); no editor menu; rename LibraryTranscriptionCommand to LibraryAudioCommand; a filtered stretch purged from Caches mid-session is rebuilt only at the next edit; "M4B audiobook (AAC)" vs "M4B Audiobook (AAC)" wording.
- Not checked by hand: a real microphone and the punch-in beep, audible playback, live VoiceOver and braille, the Export panel and the close alert.
- Docs: README "Editing audio" section replacement and the ARCHITECTURE "editor window" bullet in the agent's report (tasks/a5c00e11eddabf5a7).

## From the readerpolish agent (fix/reader-polish-october-4), Oct 4
- ReaderView.body type-check 1,337 ms to 7 ms (parts 111 ms); next candidates: LibraryView.body 3.2 s, ReaderBookCommandsSupport 1.3 s, SpeechService.swift:185 at 231 ms (#1141).
- Flake: ContinueToNextBookTests.testATimerSetByAnotherReaderOfTheSameBookDoesNotStopContinuing failed once under load 10.4 (an extra "could not be saved" announcement from an earlier test's deleted package), passed alone (#1151); PlaybackSettingsAuditTests.testAFailedSettingsSaveIsLeftToTheFailureBanner failed twice alone and passed in the suite (isolation).
- Not verified: live VoiceOver; a reader opening a book before the launch pass still rebuilds the edit with the copy kept; edits taken outside a session are not announced.
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/a05fe6e5f93117ac0).

## From the editorpolish agent (fix/audio-editor-polish), Oct 4
- A race fixed: a preview and the level measurement could render the same filtered stretch at once; one rebuild is shared and the first result kept.
- Not verified: live VoiceOver and the real menu bar; the real quit alerts; bookmarks in an M4B with real chapters; two copies of TextMouth on one Mac; macOS emptying Caches (simulated).
- Decisions: markers under a `markers` key in edits.json (older builds drop them); a crash between the two writes could leave markers one edit out of place; Revert to Original deletes markers; the Edit menu acts only when the editor window itself is key; "MP3 needs ffmpeg" wording left for recordpolish.
- Docs: README and ARCHITECTURE wording in the agent's report (tasks/adf06ceb42b00205e).

## From the feedpolish agent (feature/feed-search-and-polish), Oct 4 evening
- Not verified: live servers (the search fixture copies one real iTunes answer with its text replaced; the directory's rate-limit answer is assumed), a real quit and relaunch, metered-network detection (stub only), VoiceOver live, M4V and MOV by extension only, the type-check time after the #1111 split.
- Decisions: Return presses Search only in the Search field; up to 50 results, one per feed; content_html before content_text; the quit hold answers "later" after the unsaved-changes check and waits three seconds; video extensions apply to folder and ZIP imports too; the finished book's kind is recorded at finish (deleted episodes cannot be classified later; older entries count by kind while in the library, then as other books).
- Flake seen once: ViewsAndWindowsReaderSheetTests drawing count over its limit while other agents built (3 of 3 alone; #1170).
- Docs: README and ARCHITECTURE wording in the agent's report (orchestrator session tasks/ae3a397d3365f52ed).

## From the recordpolish agent (feature/recording-polish-and-mp3), Oct 4 evening
- Not verified: a real microphone, live VoiceOver, a real crash, a real Command-Q; players other than AVFoundation for LAME's own tag; the ffmpeg fallback cannot happen in the real app; Intel (arm64 only here).
- Gap left: for under a second while an editor applies a punch-in no recorder holds the take, so a Record window opened then could list it (AudioEditorModel+PunchIn.keep is the editor's file).
- Licence: LAME is LGPL 2; a built app given to someone else must carry its notice and licence (README's "Third-party code" section is the notice).
- Signing: codesign asked for the "TextMouth Developer" key when the login keychain locked (dialog at 19:22); until codesign can sign without asking, make build, install, and check stop at signing (the last make check ran with SIGN_APP=: and an ad hoc signature).
- Release app: 15.1 MB on main, 15.4 MB with LAME (0.13 MB of it LAME).
- Possible follow-up: AudioEditorWording.formatName repeats AudioExportFormat.title.
- Docs: README (16 numbered edits, including the new "Third-party code" section) and ARCHITECTURE (12) wording in the agent's report (orchestrator session tasks/a1e6da3527c84b7aa).

# Agent notes, October 6, 2026

The wave after the user asked for the sleep timer's two place timers to become one, End of heading, and for the October 6 sheet sweep's findings to be fixed by agents.

## From the librarysheets agent (fix/library-sheet-polish), Oct 6
- Not verified: button labels and hints under live VoiceOver (the hosted Cancel New Folder check skips without an assistive app; wording pinned); the feed sheets' Return behavior in the real app rests on the measurement that, with two default-action buttons, the first in view order takes Return.
- Left alone deliberately: Escape still closes the whole sheet while the New Folder fields are shown; the fields do not take keyboard focus when opened; Move Folder's and Move Contents' destination lists only partly pre-filter depth (the model refuses with `.tooDeep` and the sheet shows why).
- Findings posted: #1205 (AddFeedSheet.swift, OPMLImportSheet.swift): adopt `isMakingFolder:` and withdraw Subscribe/Import's shortcut while the fields are shown; #1206 (FeedInfoSheet.swift): Return in a number field presses Create while the fields are open with a valid name.
- README wording (Library window bullets, after "Edit Mode selects several books at once to move or remove them."): "The Move dialog puts the selected books in a folder chosen from its pop-up, or in one its New Folder… fields make: while those fields are shown, Return presses their Create, and Cancel New Folder closes them and keeps the folder chosen; once they close, Return presses Move again. A move, a folder's rename or move, or Delete Folder's Move Contents that fails keeps its sheet open with the reason, and trying again clears that reason until the new attempt answers. Book Info for a plain text, Markdown, or HTML book edits the title and author; Save waits for a title of more than spaces and drops the spaces typed around the title or the author." Add Feed line: "…whose New Folder makes one; while its fields are shown, Return presses their Create rather than Subscribe."
- ARCHITECTURE wording (library views): "Views/Library/LibrarySheetViews.swift holds the library's folder sheets (New Folder, Move, Rename Folder, Move Folder, Delete Folder's Move Contents) and LibraryBookInfoSheet, whose edited(_:title:author:) trims the title and author and refuses a blank title for Save's availability and action alike; OperationFailureNotice, whose run(_:isWorking:failureMessage:) clears the sheet's failure as an edit starts, keeps the sheet working until the edit answers, then shows and announces any failure; and LibraryFolderPicker, the folder chooser the Move sheet, Add Feed, Feed Info, and Import OPML share. The picker's Create takes the Return key while its New Folder fields are shown, and its optional isMakingFolder binding tells an owner with a Return-key button of its own to stand that button down meanwhile, as the Move sheet does; the feed sheets have not adopted it and rely on SwiftUI giving Return to the first default-action button in view order. The fields' Cancel is Cancel New Folder (cancelNewFolderTitle, cancelNewFolderHint). Measured in hosted windows (LibraryFolderPickerTests): a Return offered as a key equivalent reaches the default button alone and a focused field's onSubmit stays silent, while the keyDown path alone runs onSubmit, so one press does one thing."

## From the feedfinder agent (fix/feed-info-and-duplicate-finder), Oct 6
- Not verified with live VoiceOver. Return and Escape in Show Description are proven in a hosted window through `window.performKeyEquivalent`, not in the live app; the scan announcement is proven through the wording helper, the view's private `runScan(announcing:)` only by hand; the three-criteria group heading is pinned by prefix and suffix because `ListFormatter` places the serial comma by locale.
- Decisions: Feed Info's text area reuses `FeedWording.descriptionTextLabel(title:)` ("Description of <title>") under the unchanged "Description" heading. Show Description's Close takes Return as the default action; Escape comes through `SilentKeyEquivalent` (FeedInfoSheet.swift), an NSViewRepresentable of no size and no accessibility element whose NSView takes one unmodified key in `performKeyEquivalent`, because `onExitCommand` sent from an AppKit text view's responder chain never reaches SwiftUI (measured in a hosted test); it is reusable by any one-button sheet. Nothing persists the duplicate criteria (`@State`, Identical File (MD5) checked at each opening), so no saved-choice restoration was needed; group headings name the criteria with `ListFormatter` ("Same Title and Same Author") and a title and author matched together read "Shared by One Author"; books without an author fall to Same Title alone. Found and fixed: each duplicate row now speaks its date added; the results count agrees in number ("1 duplicate group found") and a scan the user asks for is announced (the rescan after a removal stays quiet).
- Board: answered librarysheets' #1206 (reply #1209): Feed Info has no default-action button to withdraw while the picker's New Folder fields are open; once the library branch merged, Return in a Feed Info number field presses the picker's Create while those fields are open with a valid name.
- README wording: Feed Info line: replace "and its description in a text area" with "and its description, under a Description heading, in a text area labelled "Description of <the feed's title>", so VoiceOver says the word once". Show Description line: "…that VoiceOver reads by line, word, and character; Return or Escape closes it." Find Duplicate Books (Settings, Storage): "Find Duplicate Books… groups the library's books by the criteria you check, Identical File (MD5), Same ISBN, Same Title, and Same Author, which combine, so Same Title with Same Author groups by both and no separate Same Title & Author is offered. A scan says how many duplicate groups it found, or that it found none; each group's heading names the criteria and what the books share, as in "Same Title and Same Author: Shared by One Author"; each row speaks the book's title, author, format, folder, and the date it was added; and the books you check can be moved to the Trash or deleted, with confirmation when the preference asks."
- ARCHITECTURE wording: Feeds: "FeedInfoSheet.swift also holds FeedReadOnlyText, the read-only NSTextView both sheets read descriptions in, labelled FeedWording.descriptionTextLabel(title:), the feed's title in Feed Info, under a Description heading, and the item's in Show Description, and SilentKeyEquivalent, an NSViewRepresentable of no size and no accessibility element whose NSView takes one unmodified key in performKeyEquivalent, which AppKit offers to every view of a window before the focused view sees the key; Show Description's Close answers Escape through it while its one SwiftUI shortcut is Return (the default action). It exists because a SwiftUI button carries one shortcut and onExitCommand, sent from an AppKit text view's responder chain, never reaches SwiftUI (measured in a hosted test)." Settings/Storage: "Views/Settings/DuplicateFinderView.swift: DuplicateFilter, the four criteria (md5Hash, isbn, title, author), which combine (DuplicateFinderEngine.findDuplicates puts a book in a group only when every checked criterion has a value and books share a group only when every value matches, so the former titleAndAuthor case is gone); DuplicateGroup, whose matchDescription names the criteria with ListFormatter and whose matchKey gives the values shared, a title and author matched together as "Title by Author"; DuplicateFinderWording, the row label (title, author, format, folder, date added) and the scan-result phrase from CountWording, read as the results' accessibility label and announced through VoiceOverAnnouncer after a scan the user asks for, not after the rescan that follows a removal; DuplicateRemoval and DuplicateRemovalButton as before. The criteria live in @State, Identical File (MD5) checked at each opening; nothing persists them."

## From the editorpolish agent (fix/audio-editor-sheet-polish), Oct 6
- Not verified: the hosted half of `testARowsWordsAreReadOnce` (skips without an assistive app; the wording pins run); real VoiceOver reading of the rows; the intermediate commits were not each built alone. `previewedFilter` in `AudioEditorModel.swift` is not `@Published`: the hint stays right because `filterPreview`, `isWorking`, and `sheet` change at the same moments, but a one-line `@Published` would make it robust.
- Decisions: the Return experiment (hosted sheet, field as first responder, Return through `window.sendEvent`) ran each command once on every path, so item 3 is a proof test only; a `guard self.prompt == prompt` in `answer(_:with:)` was considered and left out. Escape: SwiftUI keeps Escape for a focused text field, so the rename row's Cancel takes it once the keyboard has left the field; Close takes it only while no name is typed (`closeShortcut(whileRenaming:)`). Notes left: the Filter sheet logs SwiftUI's "Picker: the selection nil is invalid" at its first draw (`presetID` nil until `onAppear`); `answer(.insertSilence)` computes `silenceLength` twice.
- Finding #1214: `AudioEditorLevels.measure` blocked nine cooperative-pool threads in `copyNextSampleBuffer`, one per `measureLevels()` task, and a cancelled measurement could not see its cancellation there; a targeted run hung once. Fixed by the levels agent (see below).
- README wording: "In Apply Filter, Apply's hint says what a press does now: with Preview filters before applying on, that it plays the filtered audio first until that preset has been previewed on that target, through Apply or Preview; after that, or with the setting off, that it applies the filter. With every preset deleted in Settings, Apply Filter starts VoiceOver on Cancel. In Markers and Pauses, VoiceOver reads each row's words once ("Marker 3, Intro, at 1 minute, 4 seconds"), then its buttons, which name the row ("Delete Marker 3"). While a name is being typed, Escape presses the row's Cancel rather than closing the list once the keyboard has left the field; Close takes Escape otherwise. One press of Return in Go to Time, Insert Silence, Insert Chapter Marker, or a rename row runs the command once."
- ARCHITECTURE wording: "`AudioEditorModel+Filters.swift`: `applyWouldPreview(_:on:)` says whether Apply previews first (the setting on, and the preset not yet previewed on that target since the sheet opened, per `previewedFilter`); `chooseApply` reads it, and `applyHint(for:on:)` turns it into Apply's hint (`AudioEditorWording.applyPreviewsFirstHint` or `applyHint`), which `AudioEditorFilterSheet` gives the button. `AudioEditorFilterSheet` takes its `AudioFilterPresetLibrary` (default: the saved presets) and asks VoiceOver's start for Cancel when it is empty. `AudioEditorMarkersSheet.swift`: the marker, chapter marker, and pause rows share `row(_:subject:commands:)` over `RowCommand` (title, destructive, action): one container labelled with the row's words, the drawn text hidden from VoiceOver, a button per command labelled `rowButton(title, subject)`, and the commands as the row's actions by title; `AudioEditorRenameRow` is a row's rename state (the field with its focus state, Save Name as the default button, Cancel as the cancel button), and `closeShortcut(whileRenaming:)` gives Close the cancel key only while no name is typed. Tests: `AudioEditorWindowTests` hosts the prompt sheets and the rename row, puts the keyboard in the field (`windowWithKeyboardInField`), and sends keys through `window.sendEvent` (`press`), which includes AppKit's key-equivalent pass; `testARowsWordsAreReadOnce` skips without an assistive app."

## From the timerunify agent (feature/sleep-timer-end-of-heading), Oct 6 evening
- Verified: the five cases of the one timer (a second heading in a chapter; a chapter boundary the next heading begins, with the audiobook fade and without one for speech; a next chapter with text before its first heading, or none, played on; a book with no headings stopping at its end; set while loading); Markdown with a level-2 heading through the real parser; a real chaptered m4b (`AudioTestFixtures.writeChapteredAAC`) stopping at its marker.
- Not verified: a DAISY or segmented audiobook (its chapter chains report an end per chapter, so the chapter-end path should serve it as for tracks); the sheet's End of heading button pressed through accessibility (the press test skips here); real EPUBs from the library.
- Open follow-ups: an m4b's marker inside one file stops an End of heading timer a moment past the marker (the next refresh after an audio position update, up to about a quarter second; the cursor is put back at the marker) and without the fade-out, since `AudioPlaybackService.timeLeftToPlay` measures the file, not the chapter; DAISY and segmented audiobooks have no sleep timer test of their own.
- Decisions: the heading's meaning holds where the two timers differed, said in `ReaderViewModel.chapterEnding(beforeChapter:)` and the enum's doc; one announcement for a stop at the heading's end; the book's end keeps its "Finished: … because of the sleep timer." sentences; `expireSleepTimerAtChapterEnd(beforeChapter:)` returns Bool; the two audiobook chapter-end tests merged; a sheet test asserts no label contains "chapter"; a service test pins `START kind=end-of-heading`.
- README wording (replace the reader section's sleep timer bullet): "The sleep timer runs for a set number of minutes, a preset or typed, or stops at a place in the book: its sheet's Stop At section sets one that stops at the end of the heading, or at the end of the book, for text books and audiobooks alike. Headings are one concept for any document: where the next heading of any level begins, as Next Heading finds it, or the book ends, in an EPUB, a Markdown, HTML, or plain-text file, a DAISY book, or an audiobook, whose chapters, tracks, and chapter markers are its headings. End of heading pauses playback where the heading playing ends: within a chapter, where the next heading begins, with the cursor put back at that heading for Play to start it; at a chapter's end, when the next chapter opens with the next heading, as every audiobook chapter does; and at the book's end, which ends the last heading. A next chapter that has text before its first heading, or no heading at all, goes on under the same heading, so playback goes on into it. End of heading took the place of End of chapter on October 6, 2026, and Restart Sleep Timer after a timer saved as End of chapter or End of document arms End of heading. VoiceOver says "Sleep timer: stops at the end of this heading." as it is set, reads the timer's status the same way, and says "Sleep timer expired at the end of the heading. Playback paused." where it stops; stopped at the book's end, the reader says that the book finished and why nothing follows, as in "Finished: Moby-Dick. Next book not started because of the sleep timer." End of book pauses playback when the book ends, before the book starts again or the next book starts. An audiobook fades out toward a stop at a chapter's end over the sleep timer's Fade out time, in Playback settings, when one is set; speech is not faded, and an m4b's chapter marker inside one file stops the timer a moment past the marker, without a fade. One timer serves the whole app, and it belongs to the reader window that set it: another window's playback, even of the same book, never pauses or ends it."
- ARCHITECTURE wording ("The sleep timer."): Owner: "What the timer waits for is a SleepTimerDuration: a number of minutes, the end of the heading (endOfHeading, the one place-based timer for any document since October 6, 2026, when End of chapter folded into it: where the next heading of any level begins or the book ends; an audiobook's chapters, tracks, and marker segments each begin with a heading, so its heading ends with its chapter), or the end of the book (endOfBook)." Who may write it (replacing the heading-timer and chapter-end sentences): "That timer waits for the heading after the cursor when it was set (ReaderViewModel.sleepTimerNextHeading, found once a loading book has its headings; nil after the last heading, which ends with the book): the reader's refresh, at most every 0.12 s, asks whether playback reached it (stopForSleepTimerIfPlaybackReachedHeadingEnd, through waitsForHeadingEnd(ownedBy:)) and, if so, stops playback, puts the cursor at that heading, and ends the timer (expireAtHeadingEnd(by:)); a move forward to or past it ends the timer the same way, after the move's own announcement (endSleepTimerIfMoveReachedHeadingEnd); a move back leaves it waiting. Where a chapter's speech or audio ends, the reader asks whether its own timer stops playback there and, if so, ends it (expireAtChapterEnd(endingTheHeading:endingTheBook:by:), deciding through stopsPlaybackAtChapterEnd(endingTheHeading:endingTheBook:ownedBy:)): End of heading stops there when the next chapter opens with the next heading (ReaderViewModel.chapterEnding(beforeChapter:), headingHasBegun(_:atStartOfChapter:text:)), which is where End of chapter and End of heading differed, since a next chapter with text before its first heading, or none, plays on under the heading; End of heading and End of book both stop at the last chapter's end, the book's. A timer ended so stops as stop() stops it, with no fade left to run and no expiry callback. The last timer started is saved, as sleepTimer.lastUsedDuration, for Restart Sleep Timer, and a saved endOfChapter or endOfDocument restores as End of heading." How others observe it: "every sleep timer sheet shows the shared state, with End of heading and End of book in its Stop At section, after the minute presets and the custom minutes (SleepTimerView.endOfHeadingTitle, endOfHeadingLabel, endOfHeadingHint, and the End of book constants), and VoiceOver reads the timer's status, in the sheet and in the reader, as spokenLabel, such as "Sleep timer: 4:59 remaining" or "Sleep timer: stops at the end of this heading". The owning reader's callbacks fade out and pause its playback when a timer counting minutes runs out (sleepTimerExpiredAnnouncement). A stop at the heading's end, within a chapter or with one, announces sleepTimerStoppedAtHeadingEndAnnouncement, "Sleep timer expired at the end of the heading. Playback paused."; at a chapter's end the reader stops before the next chapter starts (stopForSleepTimerAtChapterEnd(of:nextChapterIndex:)): its cursor waits, saved, at the next chapter's start, and a text book discards the chapter rendered ahead unplayed." Keep the handleEndOfBook and fade sentences, adding: "An m4b's chapter marker inside one file stops the timer through the heading path, a moment past the marker, without a fade, since AudioPlaybackService.timeLeftToPlay measures the file."
