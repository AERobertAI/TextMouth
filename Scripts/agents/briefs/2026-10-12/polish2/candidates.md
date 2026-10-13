# polish2 candidates, verified against main eb66b22f, October 12

Main's code is unchanged since eb66b22f (0d801ef1 adds only documents). Counts: 18 still open, one right answer, 8 still open, needs the user, 34 already fixed, 15 too large for one task, 8 skipped without checking.

## Still open, one right answer

- L3072 [refactor] `answer(.insertSilence)` calls `silenceLength(typed:)` twice (AudioEditorModel+Commands.swift 203-204). Fix: call once, keep the tuple. Size: S. Test: none new (existing insert-silence tests).
- L3091 #1377 [comment] `Book.handEdits` doc (Book.swift 188-195) says every book made since October 7 has no record, but imports stamp `.noneSinceImport` (FileImportService.swift:778). Fix: reword to say an import begins its record and only older rows and other creators have none. Size: S. Test: none.
- L3091, L3144 #2037 [tests] `handleQueuedCallbacks` is a private copy in 6 test files (SpeechDirectChunkingTests, CompletionGenerationTests, SpeechRefusalReaderTests, WhereAmIAnnouncementEndTests, FullSummaryReaderTests, MediaCommandPlaybackTests). Fix: one helper in `AccessibilityTestSupport.swift`/`IntegrationTestSupport.swift`. Size: M. Test: those six classes still pass.
- L3108 [refactor] `EPUBMetadataSaveWording.notInLibrary(title:)` (EPUBMetadataSave.swift:130) now serves the audio save and the reader's bookmark path (LibraryViewModel+BookOperations.swift:768, ReaderViewModel+Bookmarks.swift:327). Fix: move it to a format-neutral wording type. Size: S. Test: existing wording tests, renamed.
- L3113 [refactor] `FeedReadOnlyText` and `SilentKeyEquivalent` (FeedInfoSheet.swift:432, 483) serve the reader's refusal sheet and FeedItemBookInfoSheet too; `LogsSettingsSection.showLogs(for:)` (LogsSettingsSection.swift:137) is called from SpeechRefusalReportSheet.swift:128. Fix: move the two views to a neutral file and name; put `showLogs` where both can call it. Size: S/M. Test: none new.
- L3091 [tests] The Alice EPUB fixture path is built twice: `EPUBMetadataWritebackTests.swift:250` and `ReaderEPUBMetadataTests.swift:239` (two more tests read TestData/alice.epub). Fix: one shared static in a test support file. Size: S. Test: both classes still pass.
- L3126, L3122 [listener] `DataDirectoryAvailability.Reason.notDownloaded` always says "The library index is in <cloud> and isn't on this Mac yet." (line 234) though the check also covers feed index files (lines 484-489). Fix: neutral wording ("The library's index files …"). Size: S. Test: wording test in the availability tests.
- L3133 #1937 [listener] The bookmark command has two names: menu "Toggle Bookmark" (MenuCommands.swift:439) vs `ShortcutAction.addBookmark = "Add Bookmark"` (KeyboardShortcut.swift:37, the Shortcuts tab) and the empty list's help (BookmarkPanelView.swift:457). Fix: raw value "Toggle Bookmark" with "Add Bookmark" in `formerNames`, help worded to match. Size: M. Test: config round trip of the former name; wording test.
- L3152 [refactor] `Library.folderHasContents` (Library.swift:788) builds a list with `booksInFolderTree` where a short-circuit would do; Delete Folder spells the tree filter a fourth time (`LibraryViewModel+FolderManagement.swift:146-148`). Fix: add `Library.hasBooks(inFolderTree:)`, use it in both, and `booksInFolderTree` in the delete. Size: S. Test: existing folder tests.
- L3152 #1857 [tests] next slices of unguarded numeric subscripts: `LibraryBookUpdatesTests` (23 hits), `BookmarkKeyboardAccessTests` (32), `ContentIndexValidationTests` (131). Fix: replace each `[n]` by a guarded `XCTUnwrap`/`first`. Size: S for LibraryBookUpdatesTests, M for BookmarkKeyboardAccessTests, L for ContentIndexValidationTests. Test: the class itself.
- L3123, L3128 [refactor] Four private copies of one list-joiner ("a, b, and c"): `LibraryCloudWording.list` (LibraryCloudWording.swift:240), `AudioFilterChain.list` (:199, empty gives "none"), `ReadingStatsTile.spokenList` (:106), `PDFExtractionDiagnostics.listed` (:205). Fix: one `CountWording.list(_:)` (or similar), callers handle empty. Size: S. Test: list of 0, 1, 2, 3 items.
- L3141 #2005 [refactor] `ReaderViewModel.timeToHeading(_:)` (ReaderViewModel.swift:799) has no caller anywhere. Fix: delete it. Size: S. Test: none.
- L3146 #2078 [refactor] `LibraryViewModel.updateReadingPosition(bookID:position:)` (LibraryViewModel+BookOperations.swift:686) has no caller. Fix: delete it (the markingOpened form at :674 stays). Size: S. Test: none.
- L3138 [tests] `control(labelled:in:)` is still a private copy in `AudioEditorWindowTests.swift:577` and `RepeatedSymbolSettingsViewTests.swift:231`. Fix: one helper in `AccessibilityTestSupport.swift`. Size: S. Test: both classes.
- L3139 #1988 #1989 [correctness] `AudioFilterProcessor.process` (AudioFilterProcessor.swift ~66-75) removes the shared result file, then moves its partial there, so a second render of the same stretch can find the file missing between the two steps (the cause of `AudioEditCachesTests.testTwoRendersOfOneStretchAtOnceBothGetIt`'s failure). Fix: replace atomically (`replaceItemAt`) instead of remove then move. Size: S. Test: that class's two-renders test, run in a loop.
- L3089 [correctness] `FEED_SUBSCRIBED` (FeedCenter.swift:717) still logs only the entries kept ("N item(s) kept"), not how many the feed lists. Fix: add the feed's entry total (`record.feed.entryTotal`) to the line. Size: S. Test: a log-line test beside the other feed tags (`LogContentPolicyTests.eventTags`).
- L3123 [refactor] `TextEditingKeys.editMenuKeys` (TextEditingKeys.swift:68) repeats the Edit-menu entries of `KeyBinding.systemCommands` (KeyboardShortcut.swift:609-623). Fix: derive the set from `systemCommands`' keys for Undo, Redo, Cut, Copy, Paste, Select All. Size: S. Test: set equals today's six keys.
- L3137 [refactor] `BookSettingsSheetWording` (ReaderView.swift:1107) and `BookVoiceSettingsWording` are two wording types for the per-book settings. Fix: one type. Size: M. Test: existing wording tests, renamed.

## Still open, needs the user

- L3103 After a second refusal Play at the same place runs the whole cycle again. Question: should an automatic skip past the passage end the loop? Recommended: no change until the user hears it again; it needs their ear.
- L3116 Focusing a window that never played, while another book shows paused, sends the next AirPods Play to the focused window's book. Question: should Play go to the paused book instead? Recommended: keep today's rule (the user's October 10 note says Play moves the stream to the front window, the skips do not).
- L3128 Keyboard and menu moves in the reading list say "Moved X above Y"; the VoiceOver actions say "X, 3 of 12". Question: which one wording? Recommended: "X, moved to 3 of 12" for both, and the keyboard also says it at either end of the list.
- L3124 Wording for a number of 1 ("newest 1 downloaded"). Question: other words for 1? Recommended: "newest download" / "the newest episode".
- L3127 Whether Cancel should also stop the rule's downloads waiting for a network or room (humanQuestions/2026-10-09.md question 5). Recommended: check the answer already given there before asking again.
- L3132 Cancel does not stop queued single-file imports, only ZIPs. Question: should it? Recommended: yes, stop the ones not yet begun.
- L3133 Captions now heard only as hints are lost with VoiceOver's hints off; search is capped at 500 matches (was 2,000). Questions: keep? Recommended: keep the cap, and name the captions' controls in their labels where short.
- L3148 Move Contents Out on a feed's own folder does not move the feed with the contents. Question: should the feed follow? Recommended: yes, as Feed Info's folder choice does.

## Already fixed

- L3072 Return-key test helpers twice (board #1241): c2b5f437 Keep the Return-key test helpers in one place.
- L3072 Add Feed, Feed Info, OPML and Move sheets: Escape withdrawn while the New Folder fields show: AddFeedSheet.swift:461, FeedInfoSheet.swift:228, LibrarySheetViews.swift:319 (`isMakingFolder`).
- L3089 `FeedCenter.counts(of:)` linear scan: FeedLibraryPresentation.swift:55-57 says an item's row is found by identity, one step per item.
- L3090 `UnopenedCategoryTests` warnings (#1391): c259f91f Run the Unopened category's tests on the main actor one by one.
- L3090 `removeRetiredBooks` leaves ID on the reading list: RemovedFromLibraryMarker.swift:115-125 removes through `Library.removeBook(id:)`, whose doc says it leaves the reading list too.
- L3090 Import/New from Text at the Reading List add nothing: ReadingListWording.swift:122-128 "Added to reading list: ..."; Move Up/Down row actions: L3128 shows the VoiceOver actions exist.
- L3092 replacing a recorded shortcut never takes the key: KeyboardShortcutManager.swift 215-235 (`change` takes it from other actions); Shift+Skip and Increase Speed's "+" by the Shift fallback (L3114); holding a key repeats: `isARepeat` is read at KeyboardShortcutManager.swift:562, 575.
- L3092 feed deletions write no log line (#1411): FeedLifecycle.swift:224, 562 log FEED_DOWNLOAD_DELETED with the command.
- L3092 `FeedReconciler.kept` drops the played date (#1412): FeedReconciler.kept (line 202+) keeps `item.playedDate != nil`.
- L3103 `DirectSpeechFadePlanner.segments` slow type-check (#1141): SpeechService.swift:248 comment shows the expression was split.
- L3104 text cache observer duplicates `ImportProgressObserver` (#1461): StorageSettingsView.swift:363 and ContentView.swift:76 use `ProgressObserver`; the 5-second elapsed rule (#1460) now has one home, `ReaderCloudWording.elapsedStep`.
- L3105 #1455 design notes in future tense: LibraryViewModel+ReadingList.swift has no future-tense line left.
- L3106 #1452 F keys, Home, End, Page Up/Down unreadable: KeyboardShortcut.swift:877-912 names them. Shift-Command-T clash (#1451): KeyboardShortcut.swift:222, 1505, 1581 give each its own kind/scope.
- L3109 playing book paused behind another window: NowPlayingService.updateNowPlayingInfo (1152-1167) calls `playingOwnerPaused`; `unregister(ownerID:)` (598-627) takes down a shown, inactive reader's item.
- L3110 `FeedUIAddFeedTests.testAnHttpsFeedIsAnnouncedOnceTheSheetCloses` load failure: FeedUIAddFeedTests.swift:765 comment shows the fix.
- L3111 #1508 keyName repeats the table: AudioEditorWording.swift:942 uses `KeyBinding.keyNames`. L3112 Up One Level order (#1528): KeyboardShortcut.swift:32 comment places it last of Navigation.
- L3116 #1581 priority-inversion backtraces: AsyncBridgeTests.swift:9, 65-68 pin that the task runs at the waiting thread's priority.
- L3118 `writePendingBookInfoNow` doc "call off the main thread": LibraryPersistenceService.swift:338-345 now explains the wait cannot deadlock.
- L3120 branch C removals: `ConfigService.swift:630` lists `FeedSettings.retiredPreferenceKeys`; ShortcutConfigFileTests.swift:500 pins feedKeepEntries and feedAutoDownload; no `setKeepEntries`/`Feed.keepEntries(under:)` remain.
- L3115 `feedBook(withID:)` linear scan: LibraryViewModel+Feeds.swift:52-56 uses `feedItemRowLookup`.
- L3103 `seek(toCharOffset:)` with a failed engine: SpeechService.swift:2036-2052 goes through `switchToRenderedAudioOrSpeakDirectly(... failureTag: "SEEK_ENGINE_FAILED")`, which falls back to direct speech.
- L3089 `FeedCommands` spells "unplayed" itself: FeedCommands.swift:334 uses `unplayedNote`.
- L3135-3136 comments #1935 (FeedItemPackage.swift:222), #1936 (FeedLibraryWording.swift:207-213 now "1 hour, 4 minutes"), FeedDownloadManager.commit's Cancel comment (line 351), #1742 FeedRows.swift:14-15, 168-169.
- L3132 `FeedDownloadProgressObserver` could use `ProgressObserver`: FeedDownloadProgressSection.swift:131-146 does.
- L3133 minutes counted by hand (AudioEditWording ~24, LibrarySessionLease ~471): AudioEditWording.swift:24 uses `CountWording.minutes`; LibrarySessionLease has no hand-counted minutes left.
- L3125 `isPackageContentName` spelling bookInfo.json and content.md: FileImportService+Packages.swift:449-460 uses `TextMouthPaths` constants.
- L3135 `"cachedAudio"` literal: `TextMouthPaths.cachedAudioFolderName` is used at FileImportService+Packages.swift:455.
- L3139 `FeedFetchError.constrainedNetwork.downloadMessage` single wait wording: FeedDownloadManager.swift:116-118 uses `FeedDownloadWait.networkWait`.
- L3129 `action(holding:in:)` used only by tests: no longer exists.
- REV12 reviewreader (5) unguarded subscripts in ReaderCloudDownloadTests: none left above line 600; REV10 reviewrecords (5) unlistable kept package taken for empty: FeedItemPackage.swift:86-96 `listedEntryNames` throws; (6) swap errno: FeedItemPackage.swift:478 logs FEED_PACKAGE_SWAP_FAILED with errno.
- L3130 OPML import counts an unsubscribed feed as "subscribed already" (#1814): OPMLImportSheet.swift:136 tests `existing.isSubscribed`; export lists only `isSubscribed` feeds (:382, :409). #1815: `FeedStore.remove`/`FeedFetchState.remove` now have a caller (FeedCenter+DeleteFeed.swift:154-155); `cancelAll(of:)` is gone.
- L3129, L3134 Play/Pause during Where Am I? with a chapter downloading, and `restartPlaybackBackendOnNextResume` in Where Am I?'s resume: ReaderViewModel+Playback.swift:395-432 (`stopWhereAmIWithoutResuming` pauses a waiting play), ReaderViewModel+WhereAmI.swift:633-642.
- L3131 `jumpToTime`'s comment: ReaderViewModel+Jump.swift:32-43 describes what the code does. L3133 `withHostedView` doc names the crash: AccessibilityTestSupport.swift:28-37. L3126 `FeedCenter.setFolder` comment: FeedCenter.swift:1050-1058 says nothing moves. L3112 punctuation keys (#1529): KeyboardShortcut.swift:927 names "Left Bracket"; ShortcutsSettingsTabTests.swift:31 pins "Command + Left Bracket".
- L3133 "Remove failure heading says books" (L3122): RemovalWording.failureHeading(count:noun:) takes the noun. REV11 F7 (A1's move and B's first pass on one launch): FeedNewestRuleTests.swift:885. L3138 `ShortcutConfigFileTests` fixed-window wait: no sleep or wait remains in the file. L3129 `DAISYPackageImportTests` front-window dependence (#1777): no window lookup remains.

## Too large for one task

- L3052 A Finder-started download of a second book during a long download shows at the next full refresh (up to 60 s): unsettled, needs a file-system watcher design.
- L3072 An m4b chapter marker inside one file ends the End of heading timer a moment late and without the fade (`AudioPlaybackService.timeLeftToPlay` measures the file): needs playback-timer work and a live check.
- L3072 #1252 `AudioEditRenderer.drain` (AudioEditRenderer.swift:730-748) still reads on the pool thread and sees cancellation only between buffers: needs the render path restructured.
- L3117 REV10 (10), `LibraryInfoSpeechDelegate` (LibraryInfoSpeaker.swift:30) beside `WhereAmIDelegateHelper` (ReaderViewModel.swift:1925) still repeat utterance handling: one shared short-announcement speaker, M to L.
- L3105 `ReaderAutoplayRequests` and `ReadingListOpenRequests` (ReaderViewModel.swift:253-258) have one shape one store could serve: touches the hand-over paths, M to L.
- L3137 The reader's text area never scrolls to the reading position (`ReaderTextArea`): a visible-behavior change that needs a live VoiceOver check.
- L3147 #2075 `TimeFormatting.wholeSeconds` (DocumentContent.swift:438) rounds toward zero, so a time summed from chapter lengths can show a second early; unsettled: the right place to round (the Headings sheet's Time In only) is not stated.
- L3152 The Continue button reads the saved place where a row reads a reader's live position; unsettled: needs the row's live-position source, and no test exists.
- L3144 Play during an off-main package move, and `stop()` leaving a chapter's download running: several play-state cases in `ReaderViewModel+Playback.swift`; unsettled without a live check.
- L3142 The refresh refusal "waits for a network without data limits to refresh by itself" (FeedNetwork.swift:188): unsettled, the TODO does not say what is wrong with it.
- L3125 Downloading an article again replaces an old edit the rules kept (`FeedEpisodeImporter.restoreBook`): the fix (keep content.md as an `.edited-` copy when it differs) touches user data; not S.
- L3115 library.json is rewritten whole at each checkpoint while an episode plays, even unchanged (`LibraryPersistenceService.writeIndexFile`, line 432): needs a change check, M.
- L3144 #2037 test helpers repeated: the announcement recorder exists as `AnnouncementCapture` (BookExportSheetTests.swift:437), `AnnouncementLog` (BookSearchModelTests.swift:590) and `AnnouncementRecorder` (AccessibilityTestSupport.swift:399) with different shapes; unsettled which to keep.
- L3104 Import progress gaps (each ZIP book's checksum read twice, no bytes for audio ZIPs, silence after a quick ZIP with no new book): several separate import paths, not checked line by line.
- L3092, L3111 Not checked, unsettled: one undecodable saved shortcut resets every shortcut (KeyboardShortcut.swift:1322 decodes with `try?`); an old-form config.json marks every action edited.

## Skipped without checking

- L3052 SWIFT_STRICT_CONCURRENCY, baselines, flake notes, `make check`: not a defect (project.yml:44 keeps it on purpose). L3072 `previewedFilter` not @Published and the two Voice-sheet stops: by design.
- L3143, L3146, L3149, L3150 Whole paragraphs on `showLoadedContent`, T06 branches B to E, `PlaceRelocator`, `TextAnchorFinder`, `findHeading`, `PatienceDiff`, `Counts.anythingMoved`: the t6d team's lanes.
- L3151 All board items (`bbs.py`, worktree bases, old `worktree-agent-*` branches): board rule.
- L3152 Closed list (#1542, #1552, #1553, #867, `showEditedMetadata`, Release Media Controls, `pause(playingPauseSound:)`, "0 of 1 books processed", Feed Info's help, #1816, Remove menu title, #1593, #1695, Speak Info "In reading list", edit bar Deselect All, summary bar, recorder Command-Q, #2094, the Headings sheet's rows, Create's announcement, Reset to Defaults announcements, `Book.isUnopened`, `booksInFolderTree`, Continue's finished time, #1551, #1857's first slice): closed by the first polish round.
- L3152, L3140, L3114 The Continue button's "Finished", the Shortcuts Reset alert's wording, Delete Feed…'s in-use refusal naming every download, and #2077: asked in humanQuestions/2026-10-12.md. Shift fallback reach (L3114): answered October 10.
- L3052 P09, T10, A01, FR02, and the load-sensitive tests (BookmarkKeyboardAccessTests, StorageGenerationMoveTests, BookSearchModelTests.testCancelledSearchPublishesNothing, DataDirectoryMoveTests, ViewsAndWindowsReaderSheetTests redraw count, FeedDownloadTests resume, the sleep-timer tests): manual or not a defect. Design notes (rotor, two Macs never merged, EPUB metadata reads, cmark walk, SwiftUI window memory): not a defect.
- L3107, L3112, L3119, L3126, L3136, L3145 Items whose whole fix lies in README, ARCHITECTURE or a research document: documents. REV10 (11), REV11 F8, REV12 (6), REV13 (9) and (14), REV14 (8) and (10): documents or sent to docsNN.
- REV10 to REV14 Every other numbered finding is called done by a named agent and merge (`feedindexfixes`, `feeditempolicy`, `playbackfixes`, `menukeys`, `feedpolicyfixes`, `whereamimoves`, `appcleanup`, `feeddelete`, `feedfollowups2`, `endfixes` 31d51c42, `anchorcapture`, `feedfixes14` e6c23266): not re-checked.
