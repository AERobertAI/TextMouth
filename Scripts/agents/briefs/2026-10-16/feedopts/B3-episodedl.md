# Task B3, `feedopts-episodedl`: the episode that follows may not be downloaded

Branch `feedopts/episodedl`. Read `00-contract.md` first (rules 3, 4, and 7 are this task). Tasks A, B1, and B2 are on the team branch: `EndOfBookRule`, `ReaderViewModel.endOfBookRule`, `LibraryViewModel.nextBook(after:going:skippingFinished:)`, `BookSuccession`, `goOnPastThisBook`. **When a feed's episode ends and listening goes on, the next episode is the next *listed* one in the chosen direction, whether or not its file is here.** Today the search passes over episodes not downloaded, so a serial drama jumps over a part. Instead: download it, say so, and play it once it arrives; say why playback stopped if the download fails.

## What exists (read by line range)

- `ReaderViewModel+GoingOn.swift` (B1): `BookSuccession` and `goOnPastThisBook(to:in:startingWith:sleepTimerEndsListening:sleepTimerStoppedHere:sayingNothingFollows:)`. `ReaderViewModel+Playback.swift`: `continueToNextBookInFolder` (B2 made it take the rule), `handOverToNextBook(to:titled:askingWith:)` (`:2816`), `continueToNextBook(_:)` (`:2883`), `hasFinishedBook` (`ReaderViewModel.swift:426`, true while the finished book rests at its end; cleared by Play, a skip or jump, stop, closing, and the hand-over), `finishListening(announcing:)` (`:2661`), `announceToVoiceOver(_:)`, `close()` (`ReaderViewModel.swift:1993`), `private var cancellables` (`:493`).
- `LibraryViewModel.feeds` (`LibraryViewModel+Feeds.swift:10`) is the `FeedCenter`. `FeedCenter.listedItems(of: feedID)` (`FeedCenter.swift:614`) is the list the library shows (newest first). `FeedCenter.download(_:of:)` (`:984`) asks for a download with origin `.listener`; asking again for an item that waits or downloads adds nothing. `FeedCenter.events` (`:339`) is a `PassthroughSubject<FeedEvent, Never>`: `.downloadFinished(feedID:itemID:bookID:)` and `.downloadFailed(feedID:itemID:reason:)` (`FeedCenter.swift:178-182`) arrive on the main actor, the first once the book is in the library, the second with the sentence the item's row shows (`FeedDownloadManager.swift:641-651`). Cancelling a download sends neither.
- `FeedItem` (`Models/FeedItem.swift`): `id`, `title`, `isArticle`, `playedDate`, `state` (`.notDownloaded`, `.downloading`, `.waiting`, `.failed`, `.downloaded(bookID)`, `.inLibrary(bookID)`; `state.bookID`, `state.libraryBookID`, `state.isTransient`).
- The existing old-name search, `nextBookInFolder(after:)` and `laterBooksInFolder(after:)`, **keeps passing over undownloaded items; existing tests pin that** (`FeedItemIndexListTests.swift:136-176`). Leave them. This task adds a new search beside them.

## What to build

1. **`BookSuccession`** gains `case episodeToDownload(feedID: UUID, item: FeedItem)`.
2. **New `TextMouth/ViewModels/LibraryViewModel+Succession.swift`**: `func succession(after book: Book, going direction: ReadingList.Direction, skippingFinished: Bool) -> BookSuccession`.
   - A plain folder's book: `.book(next)` from `nextBook(after:going:skippingFinished:)`, else `.nothing(note:)` with `EndOfBookWording.noMoreBooksInFolderNote` when `booksBeyond` is empty, else `EndOfBookWording.onlyFinishedBooksInFolderNote(going:)` (B2).
   - A feed's item (`book.feedLink`): walk the items of `feeds.listedItems(of: feedID)` beyond the book's item in `direction` (use `ListNeighbors.beyond`; the book's item is the one whose `state.bookID` is the book or whose `id` is `book.feedLink?.itemID`, as `laterFeedItems` found it before B1). Leave out items moved into the library (`state.libraryBookID != nil`: they are the library's, as today). If none is left: `.nothing(noMoreBooksInFolderNote)`. Else take the first that is not passed over: an item whose book is here (`state.bookID`, its row in `library.books` with this `feedLink.feedID`) is `.book(row)` unless `skippingFinished` and the row `restsAtEnd`; an item with no book here is `.episodeToDownload` unless `skippingFinished` and `playedDate != nil` (played, its file since deleted). If everything beyond was passed over: `.nothing(onlyFinishedBooksInFolderNote(going:))`.
3. **`successionInFolder(following:)`** (B2's private helper below `continueToNextBookInFolder(following:...)` in `ReaderViewModel+Playback.swift`) asks `succession(after:going:skippingFinished:)` instead of building the succession itself, with the rule's direction and skip. B2's tests show how a reader is made for a feed's item and how its requests and announcements are recorded: read `FeedEndOfBookRuleTests.swift` (a subclass of `FeedItemIndexTestCase`, which gives `makeFeedItem`) before you write yours, and reuse its helpers where they are not `private` (do not edit that file).
4. **`goOnPastThisBook`** handles `.episodeToDownload(feedID, item)`, in a new file `TextMouth/ViewModels/ReaderViewModel+EpisodeDownload.swift` for the waiting part:
   1. This reader's sleep timer in effect: exactly as for a `.book`: "Finished: <title>. Next book not started because of the sleep timer." (`nextBookNotStartedNote`), **and no download is started.**
   2. Otherwise say, through `say` (the caller's `finishListening(announcing:)` or `announceToVoiceOver`): `EndOfBookWording.finished(book.title, notes: [EndOfBookWording.downloadingNextNote(item)], sleepTimerExpired: sleepTimerStoppedHere)` which reads "Finished: <title>. Downloading the next episode: <next title>." ("article" for an article).
   3. Subscribe to `libraryViewModel.feeds.events` (kept in one new stored property of the reader, `var nextEpisodeWait: AnyCancellable?` and whatever small value it needs, added to the class body in `ReaderViewModel.swift` beside `hasFinishedBook` at `:426`, because `cancellables` is `private` and an extension cannot hold a stored property; a new wait replaces an earlier one; `close()` (`ReaderViewModel.swift:1993`) sets it to nil; these are the only two edits you make to that file), **then** call `libraryViewModel.feeds.download(item.id, of: feedID)`. If, right after asking, the item is neither downloading, waiting, nor downloaded (the engine refused: quitting, a feed being deleted), drop the wait and say `EndOfBookWording.nextEpisodeNotDownloaded(reason: EndOfBookWording.downloadNotStartedReason)`.
   4. On `.downloadFinished` for that feed and item: if the reader is still resting finished (`hasFinishedBook`, not `hasClosed`, not `isPlaybackUnderWay`) hand over exactly as a `.book` does: `handOverToNextBook(to: bookID, titled: item.title) { start(bookID) }` ("Starting: <title>"); otherwise do nothing (the listener has moved on). Either way the wait ends.
   5. On `.downloadFailed` for that item: say `EndOfBookWording.nextEpisodeNotDownloaded(reason:)` with the event's reason (through `announceToVoiceOver`), end the wait. Do nothing if the reader is no longer finished or is closed.
5. **Wording** (new in `EndOfBookWording.swift`, each pinned by a test, exact):
   - `downloadingNextNote(_ item: FeedItem) -> String`: "Downloading the next episode: <title>" (article: "Downloading the next article: <title>").
   - `nextEpisodeNotDownloaded(reason: String) -> String`: "The next episode could not be downloaded, so playback stopped. <reason>" (the reason is the download's own sentence, kept whole; for an article, "The next article ...").
   - `downloadNotStartedReason`: "TextMouth is not downloading right now."

## Tests

- New `TextMouthProductionTests/EpisodeSuccessionTests.swift` (needs `xcodegen generate`, `project.pbxproj` committed with it): `succession(after:)` for a plain folder (same as `nextBook`, both directions, both notes) and for a feed with downloaded and undownloaded items, both directions, skip on and off, a played undownloaded item skipped, a finished downloaded item skipped, an item moved into the library skipped, the end of the list, a deleted item absent, a book whose item is gone.
- New `TextMouthProductionTests/EpisodeDownloadContinuationTests.swift` with `FeedTestWorld` (`FeedTestSupport.swift:439`) and a reader opened as `FeedEndToEndTests.swift:125` opens one; downloads served by the stub server as `FeedEndToEndTests.swift:26-60` serves them (`FeedMediaFixtures.silentAAC(duration:)`, short, silent: no test plays sound aloud). Give the reader a private notification center and request store so the running app never sees them, and record announcements instead of speaking them (`ContinueToNextBookTests.swift:23-60` shows both):
  1. A feed with the option "Play the episode below" and the next episode not downloaded: at the end, the announcement "Finished: A. Downloading the next episode: B." comes once, the download starts once (origin `.listener`), and when it finishes "Starting: B" is announced and `.continueToNextBook` is posted for B's book.
  2. The same with the global Continue to Next Book and the feed's options standard.
  3. Going above.
  4. The download fails (the server answers 404): the failure line, with the item's own sentence; nothing else plays.
  5. The reader plays again (or closes) while the download runs: nothing is handed over when it arrives.
  6. The sleep timer in effect: the note, no download.
  7. The next episode is downloaded already: no download, handed over as before. It is played and not downloaded with Skip finished on: passed over. Skip finished off: downloaded and played.
  8. `playFromTheEnd` (Play on the finished episode) does the same as the end.
  9. Nothing below: "Finished: A. No more books in folder." as today.

## Tests to run

`EpisodeSuccessionTests`, `EpisodeDownloadContinuationTests`, `ContinueToNextBookTests`, `ReadingListReaderTests`, `FeedItemIndexListTests`, `FeedEndToEndTests`, `EndOfBookRuleTests`, `FeedEndOfBookRuleTests`, `FeedDownloadTests` (`FeedDownloadTests.testADownloadThatStopsPartwayGoesOnFromWhereItStopped` is load-sensitive: rerun it alone if it fails and report both).

## Commits

1. `succession(after:going:skippingFinished:)` and its tests.
2. The reader's wait, the wording, and their tests.

## Do not touch

`FeedDownloadManager.swift`, `FeedCenter.swift` (read only), the old `nextBookInFolder`/`laterBooksInFolder`, `handOverToNextBook`, every existing test. If an existing test fails because a feed now downloads where it used to skip, stop and ask.
