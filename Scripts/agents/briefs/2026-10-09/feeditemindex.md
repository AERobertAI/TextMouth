# Task brief: feeditemindex — FR11's branch A1, each feed's packages and index of its own

Slug `feeditemindex`; branch `feature/feed-item-index`. Read `common.md` beside this file first.

## The design and the user's answers
The design is `FEED-ITEMS-ADDENDUM-2026-10-07.md` in the repository root, read with the first note it amends, `FEED-ITEMS-RESEARCH-2026-10-07.md`. Read the addendum whole: sections 1 to 3 and 6 define this branch, and section 7's "A1 `feature/feed-item-index`" lists its scope and tests. Build exactly A1. Branches A2 (a removed download keeps its record), B (the newest-N rule), C (the interface and read-only commands), and D (Move to Library… and Unsubscribe) come after you; build nothing of theirs, but leave the seams they need (section 7 says which).

The user's answers that bind this branch, quoted from `humanQuestions/2026-10-07-evening.md` and `humanQuestions/2026-10-07-late.md` (FR11's entry in TODO-2026-09-04.md quotes them all):
- The layout: "I would really want to stick to the package per item, but maybe each feed.json can be like a mini library.json with that information that the library refrances when needed? I don't want the number of episodes or items from feeds to blote the normal book count (maybe that can say like 700 books 2 feeds or something if there are feeds loaded?) … ALso make sure playback position is also saved".
- Late question 1, yes: a package is made at an item's first download (P1), never for an item only listed, and lives in `Feeds/<feed ID>/` (L2), outside the Library folder.
- Late question 2, yes: the library counts books only and names the feeds beside them, "743 books, 2 feeds", in the summary bar (seen and spoken), on entering a folder, in a folder's row, and in Storage settings, as the addendum's table in section 3 lists, place by place. "Feeds" is left out where there are none.
- Late question 3, yes: Recent lists books as now and, of each feed's episodes and articles, only the one opened last, within the same ten. (The user also asked to rename Recent to "Recently Opened": that is FR13, a later branch. Do not rename it here.)
- Evening question 9: "I don't think episodes or items should show up in the all or unopened views at all, just the feeds." Episodes leave All Items and Unopened; their feeds' rows count them.

## This user's data comes first
- The user's library holds 744 rows; one is a downloaded article of "The Digital Antiquarian" ("The Lamentable Later Life of Lemmings", an HTML book, opened, with a position). At the first launch of your build it moves to `Feeds/<that feed's ID>/` with its book ID, position, last-opened date, and Stats history kept, and library.json drops to 743 rows (addendum section 2, "This user's data"). "Finish It!" has nothing downloaded, so nothing of it moves.
- The move runs in the addendum's order (section 2, "The move"): make the folder, rename the package, give the row its feed link and `folderPath` "", write its bookInfo.json, write the feed's index and wait for it to be on disk, and only then take the row out of library.json and save. A crash between any two steps is mended at the next launch; test each crash point.
- **library.json must never hold a row with a feed link**, through every write path: save, checkpoint, the quit flush, retries, Rebuild Library Index (`replaceUnreadableIndex(with:)`), and the data-directory move (`DataDirectoryMigrator.stage`). One test per writer.
- Never read or write the live `~/.TextMouth`. Build fixtures shaped like the user's data in the test sandbox.
- A downloaded episode's position, playback times, bookmarks, and own settings keep working through the paths already tested: rows of items whose files are here join the library model's books after the startup repair (addendum "In memory: why downloaded rows join the library model"), and every reader function that looks a row up in `library.books` keeps finding them. Prove it with a test that plays or checkpoints a feed row and finds its position in the package and in the feed's index.

## Files you own
TextMouth/Models/Book.swift (`feedLink`, carried by `makeBookInfo()` and `Book(record:…)`, and `tmbDirectory`'s rule), the library model and its persistence (`Library`, `LibraryPersistenceService`, the startup repair's join and the feed repair, `LibraryViewModel+Feeds.swift`, the filters, counts, and sorter for All Items, Unopened, Recent, and Folders, `nextBookInFolder` for episodes), new feed index and path types (`FeedIndex`, `FeedPaths`, or names that fit the code), the feed importer's destination (`FeedEpisodeImporter`, and `FeedDownloadManager.commit(_:for:)` only where it adds the row), the summary bar (`TimeRemainingBar`), the Books header, `FolderNavigationHistory.announcement`, the folder rows' counts, Storage settings' statistics and `StorageWording`, Rebuild Directory's message, `DataDirectoryMigrator`, the provisional index, the metadata refresh's skip of feed rows, and Find Duplicate Books' skip, with their tests. Feed deletion, the sweep, and the reconciler are A2's; leave them alone except where a test of yours needs them unchanged. No other agent edits these files now: `doublepress` owns the keyboard and Shortcuts files, `refusalalert` the speech service and the reader's refusal handling.

## Items, one commit each, each with its tests
Follow the addendum's A1 list, in an order that keeps every commit building and green, for example:
1. `Book.feedLink` (decoded with `decodeIfPresent`, written only when set, so library.json's rows are unchanged), in the package record and both field-pinning tests.
2. The path rule: `Book.tmbDirectory` names `Feeds/<feed ID>/<package>` for a row with a feed link; the feed's folder and index paths.
3. The feed's index file: read with library.json in `LibraryPersistenceService.load()`, written per feed only when its contents changed, through the one write path that writes library.json without feed rows; an unreadable index preserved beside itself (`SavedFile.preserveUnusable`) and rebuilt from the packages, each of which names its feed and item in bookInfo.json; `Library.feedShelf` for the rows of removed downloads, never encoded into library.json (A2 fills it; give it its type and its place in the save now).
4. The join after the startup repair and the feed's own repair (a downloaded row whose file is gone goes to the shelf; a journaled checkpoint newer than the index comes from the record, as `adoptNewerRecordedPositions` does for books).
5. New downloads go to `Feeds/<feed ID>/`, with `addFeedBook` setting the link and "".
6. The move of today's feed books at the first launch (section 2), resumable at every step.
7. The data-directory move, Rebuild Library Index, and the provisional index, each keeping feed rows out of the library.json they write.
8. The places that leave feed rows out: All Items, Unopened, the top of Folders, the folder counts (`folderTreeCounts`, `totalBooksInFolderTree`), search at those places, the metadata refresh, Find Duplicate Books, Rebuild Directory, the folder transition planner (no package move for a feed row); Recent with one item per feed; `nextBookInFolder` for an episode (the next downloaded episode its feed's folder lists after it).
9. The counts' wording: "743 books, 2 feeds" in every place section 3's table lists, spoken and shown alike, with VoiceOver reading the same words as the screen, "1 feed" in the singular, and "Feeds" left out where there are none. Pin each sentence with a test.

Each filter and wording gets a test; the reading list across a launch keeps an episode's ID (rows join before anything can edit the list).

## Verify or report as unverified
- Say exactly what the user's library looks like after the first launch of your build: library.json's row count, the article's new home, what its feed's index holds, and that its position, last-opened date, and book ID are unchanged (tested on a fixture shaped like it; the real library was not touched).
- Live VoiceOver and braille on the new count wording are unverified; say so.
- An older build of TextMouth run after this one would lose sight of downloaded episodes (addendum, "What remains"). Say what your build does to heal that at launch, or report it as a follow-up.
- Report the main-thread time your launch adds for the user's two feeds, measured or estimated from the addendum's figures.
