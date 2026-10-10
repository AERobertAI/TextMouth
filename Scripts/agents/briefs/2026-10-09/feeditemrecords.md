# Task brief: feeditemrecords — FR11's branch A2, a removed download keeps its record; and FR13

Slug `feeditemrecords`; branch `feature/feed-item-records`. Read `common.md` beside this file first. Main is at ab6bd997 or later: since the common brief was written, the documentation pass (d6c0426e), B05's refusal report (6c5b4d9d), FR12's double presses (ed23f19c), and **FR11's branch A1 (de0839c5, `feature/feed-item-index`)** merged; main's suite counts **5099 tests, 58 skipped, 0 failures**. `nowplaying` (Now Playing and the markup guard) and `fullsummary` (FR12's full summaries: keyboard, menus, Speak Info, Where Am I) are working; their files are not yours.

## The design and the user's answers
`FEED-ITEMS-ADDENDUM-2026-10-07.md`: read sections 1 ("When a package is made: P1 or P2"), 4 ("Transcripts in the package"), 6 ("The playback position") and 7's "A2 `feature/feed-item-records`", and build A2. A1 is on main: read the feeditemindex agent's notes in `AGENT-NOTES-2026-10-04.md` ("From the feeditemindex agent", October 10) and its merge entry in TODO-2026-09-04.md first. `Library.feedShelf` (`FeedShelf`), `FeedIndex`, `FeedIndexFiles`, `joinFeedItems`, and `LibraryPersistenceService.saveAndWait(_:)` are yours to build on.

The user's answers that bind this branch (FR11's entry in the TODO quotes them all):
- "ALso make sure playback position is also saved": a removed download keeps its position, playback times, bookmarks, own settings, and transcript, and downloading it again restores them under the same book ID.
- Late question 1, yes: a package is kept after its file is removed for as long as it holds something of the listener's (a place, bookmarks, a setting of its own, or a transcript); a package that holds nothing of theirs goes whole, so an automatic download that aged out unopened leaves nothing.
- Evening question 6: "feed items and episodes shouldn't act like normal books and should not be editable, maybe transcribed but if we keep the package format just put the transcription in the package and keep it there". A transcript stays in the package when the file goes.

## This user's data comes first
Removing a file must never lose a position (addendum section 6, "Removing the file keeps it"): the book's pending record write is made at once (`writePendingBookInfoNow`), then the row moves to the feed's shelf and the feed's index is written and waited for, and only then is the file deleted; a failed index write keeps the file. `removeDeletedBook` is not used for this, since it forgets pending record writes. Never read or write the live `~/.TextMouth`.

## Items, one commit each, each with its tests
1. Delete Download, the after-playing sweep, and the library's Remove on a feed item remove the file and the caches made from it (an article's content.md, `cachedAudio/`) and keep the package with bookInfo.json, contentIndex.json, and any transcript when it holds the listener's state, the row moving to the shelf; otherwise they delete the package whole. Test: delete, then a never-opened download leaves nothing; an opened one keeps its package, and its row is on the shelf and in the feed's index.
2. Downloading again into a kept package restores the same book: the importer builds the new package from the kept record (the same book ID and state, the transcript copied) and puts it in place of the kept one; the row joins the library model. Test: delete, then download again: the same ID, position, playback times, bookmarks, settings, and transcript; a transcript whose audio differs is kept and logged stale (`TRANSCRIPT_STALE`), as the addendum says.
3. `FeedReconciler.kept` keeps an item with a played date or a kept record, so a refresh never drops it from the record (ends #1412, the played date lost outside the window).
4. Delete Episode deletes the package, kept or not.
5. Counts and `state(of:)` find rows through the feed's index by the item's identity, not `bookByID`'s linear scan (`FeedCenter.counts(of:)`, `LibraryViewModel.feedBook(withID:)`).
6. A failed index write keeps the file (test with an index file that cannot be written).
7. **FR13, a separate commit:** Recent becomes "Recently Opened". The user, answering whether Recent should list each feed's item opened last: "Yes, I actually forgot recents was recently opened so maybe add a todo to rename it to that or similar wording?" `LibraryCategory.recent`'s raw value, which is its name in the View picker and is saved with each window's category, becomes "Recently Opened"; a category saved as "Recent" still reads as it, as "No Folder" reads as Unopened (`LibraryCategory.formerNoFolderName`); its sort key `__recent__` stays. Check every place the name is shown or spoken (the picker, menus, entering it, the summary bar, Speak Info, Where Am I in the Library) and pin the new words with tests.

## Files you own
The feed services and models (`FeedLifecycle`, `FeedReconciler`, `FeedDownloadManager`, `FeedEpisodeImporter`, `FeedCenter`, `FeedStore` where needed, `FeedIndex`, `FeedShelf`), `LibraryViewModel+Feeds.swift`, the library's removal of a feed item (`LibraryViewModel+BookOperations.swift`, only that path), the transcript store only where a kept package keeps its transcript, `LibraryCategory` in `LibraryViewModel.swift` and the places that name it (item 7), and their tests. Leave the keyboard, menu, Speak Info, Where Am I, Now Playing, and playback files alone.

## Verify or report as unverified
- Say exactly what happens to the user's one downloaded article if they press Delete Download after your build: it is opened, with a position, so its package is kept and its row moves to the shelf.
- Real cloud drives and live VoiceOver are unverified; say so.
- Report the README and ARCHITECTURE wording, and the TODO sentences for A2 and FR13.
