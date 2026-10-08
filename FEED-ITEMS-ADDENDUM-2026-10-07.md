# Addendum to FR11: a package per item, each feed its own small library

An addendum to `FEED-ITEMS-RESEARCH-2026-10-07.md` (the first note), written on the evening of October 7, 2026, after the user answered its ten questions. It draws on the code on main at ee57fb1d and on a measurement program run against a synthetic library in a sandbox folder under this agent's temporary directory, deleted after each run. The user's library.json and both feed records were read only for counts and sizes, and the one downloaded article's package only for its file names, sizes, and record keys; nothing was copied, and nothing in the app or the library was changed.

The user's answers are quoted in FR11's entry in TODO-2026-09-04.md and in `humanQuestions/2026-10-07-evening.md`. The one that changes the design is the answer to question 1: "I would really want to stick to the package per item, but maybe each feed.json can be like a mini library.json with that information that the library refrances when needed? I don't want the number of episodes or items from feeds to blote the normal book count (maybe that can say like 700 books 2 feeds or something if there are feeds loaded?) try seeing if that would bave the same plan / speed problem. ALso make sure playback position is also saved if it wasn't in the plan..."

## Summary

- **The user's layout does not have the first note's speed problem.** That problem came from putting a row for every item in library.json, where every count scanned every row and every save encoded them all. Here, no feed item's row is ever in library.json. Each feed keeps its own index of its items' packages, and a count finds an item's row there by the item's identity. On this run, a count of "Finish It!" takes these times:

  | Layout | 381 items | 2,000 items |
  | --- | --- | --- |
  | The proposal (found by identity in the feed's own index) | 0.02 ms | 0.09 ms |
  | Today's code (5 downloads among 749 rows, found by a linear scan) | 0.91 ms | not measured |
  | The first note's option (b) (a row per item among 1,125 rows) | 59 to 60 ms | not measured |

- **Recommendation: build the user's layout.**
  - **Where:** each item's package lives in a folder of its feed's own, `Feeds/<feed ID>/`, outside the Library folder. Beside the packages, `Feeds/<feed ID>/library.json` lists them, with one row per package, written as library.json writes its rows.
  - **When:** a package is made when its item is first downloaded. After its file is removed, it stays as long as it holds something of yours: a place, bookmarks, a setting of its own, or a transcript.
  - **What stays:** the package keeps bookInfo.json, which holds the position, the playback times, the bookmarks, and the item's own settings. It also keeps the transcript. Downloading the item again puts the file back into the same package, under the same book ID, so the reader opens where you left off.
- **Why outside the Library folder.**
  - **The launch walk:** the walk that adopts orphaned packages (`FileImportService.adoptOrphanedTMBPackages`) would take a feed's packages inside the Library folder for lost books. Even with their names known, it would spend 3.4 to 4.6 ms more at every launch on the main thread for 381 packages, and 20 ms more for 2,000.
  - **Folder edits:** renaming, moving, or deleting a folder moves or deletes its books' packages one row at a time. Packages that are not rows in library.json would be left behind or deleted with the folder.
  - **The cost of moving them out:** one rule for where a feed row's package is (`Book.tmbDirectory`).
- **Making a package for every item the feed lists** (the user's own words, measured as "P2") would give "Finish It!" 376 packages that hold nothing of yours. That is 752 directory entries and 1.5 MB on disk (302 KB of small files to upload in a cloud library), and 3.8 ms more at each launch to read its index. A 2,000-item feed would have 3,990 entries and 8.2 MB on disk (1.6 MB of files), and would add 20 ms at launch. Making packages only on download ("P1") costs about 47 packages a year for a weekly show whose episodes you play: 141 entries, 0.4 MB, and 1 ms at launch.
- **In memory:** the rows of items whose files are on disk join the library model's books while TextMouth runs. The reader, positions, bookmarks, settings, the reading list, Stats, and transcription therefore work unchanged, through the code paths already tested. The rows of removed downloads never join the library model's books; it holds them apart, in a feed shelf. The lists, counts, and maintenance passes leave feed rows out, and one save path writes library.json without them.
- **Counts:** the library counts books only and names the feeds beside them: "743 books, 2 feeds". Every place that counts is listed in section 3.
- **Views:** episodes leave All Items and Unopened, where only their feeds show. In Recent, each feed shows only the episode or article you opened last.
- **Commands:**
  - **Lost, while an item is in its feed:** Edit Audio, Edit Text, Clean Up Transcript, and Book Info's editing.
  - **Kept:** Transcribe Audio and Delete Transcript; the transcript stays in the package when the file goes.
  - **New:** "Move to Library…" moves an episode into a folder you choose, where it becomes an ordinary book.
- **The newest-5 rule (answer 5):** it may remove a download you started and did not finish, keeping its place. It never removes a download that is open, playing, or downloading, and it looks again at the next refresh.
- **The build:** five branches. They are the feed's index, then keeping a removed download's record, then the rule, then the interface, then Move to Library.
- **Questions:** section 8 asks six yes-or-no questions.

## 1. The user's layout, measured

### The layout

```
.TextMouth/
  library.json                    books only; never a feed item
  Library/<folders>/<book>.tmb    books
  Feeds/
    <feed ID>.json                the feed's record, as today: the subscription and every item
    <feed ID>/                    new: the feed's own folder
      library.json                new: the feed's index, one row per package
      <item>.tmb/                 one package per item downloaded at least once
        <episode>.mp3             while downloaded
        bookInfo.json             always: position, playback times, bookmarks, own settings
        contentIndex.json         from the first download on
        transcript.json           when transcribed, kept when the file goes
        content.md                an article's text (goes with its file), or a transcript's (stays)
```

- **The record stays as it is:** `FeedRecord` keeps every item and what the listener did with it (`state`, `playedDate`, `downloadDeletedDate`, `deletedDate`). Its format version stays 1.
- **The played date is not copied into the package.** Items never downloaded have played dates too, so the record stays the one place for them.
- **The record is not where the rows go.** The record is 2.2 MB and rewritten whole at each change, and is read off the main thread after the library has loaded. The rows must be in memory before the first list draws: the reading list drops an ID it cannot find at its next edit (`LibraryViewModel.editReadingList`), and a reader window opened for a book ID the model does not list opens a book titled "Unknown" (`BookReaderWindowView.init`). So the rows go in a small file of their own that is read with library.json.

### When a package is made: P1 or P2

- **P1, recommended.** A package is made when the item is first downloaded, as today.
  - **When its file is removed** (by Delete Download, the after-playing rule, or the newest-N rule), the downloaded file and the caches made from it go. Those caches are an article's content.md and any speech prepared for it (`cachedAudio/`).
  - **What stays:** bookInfo.json, contentIndex.json, and a transcript with its text.
  - **When the whole package goes instead:** a package that holds nothing of the listener's goes whole. That means the item was never opened and has no position, no bookmark, no setting of its own, and no transcript. An automatic download that aged out unopened therefore leaves nothing, and its next download is a new book.
- **P2, the user's words taken literally.** A package is made for every item the moment a refresh first lists it, holding only bookInfo.json until its first download.
- **What P2's packages hold:** for an item never downloaded, nothing the record does not hold already, apart from a book ID chosen early. Its title would also live in three places (the record, the index row, bookInfo.json) and fall out of step when the feed renames the item.

### Where the packages live: inside the Library folder (L1) or a folder of the feed's own (L2)

- **L1, inside the feed's library folder, as today's downloads are.**
  - **The orphan walk at every launch.** `migrateOldBooksIfNeeded` runs `adoptOrphanedTMBPackages` on the main thread. The walk visits every `.tmb` folder under `Library/`, and adopts as a book any package that library.json does not name, whose bookInfo.json reads, and that holds a content file (`orphanedBook(in:)`, `isPackageContentName`). Every downloaded feed item would be adopted into library.json at the next launch unless the walk learned to skip packages whose record names a feed. A package left without its file is passed over only because it has no content file.
  - **Folder edits.** A folder's rename or move goes through `performLibraryTransition`, which moves the package of each `library.books` row whose folder changes, one row at a time. A feed's packages, being no rows there, would stay in the old folder. Delete Folder with its contents (`removeFolderAndEverything`) deletes the folder's directory with everything in it, the feed's kept records included.
  - **A data-directory move** writes each row's record at `Library/<folder>/<package>` (`DataDirectoryMigrator.stage`).
  - **Index recovery.** The provisional library built while library.json cannot be read, and Rebuild Library Index, adopt through the same walk (`buildProvisionalLibrary`).
- **L2, `Feeds/<feed ID>/`, recommended.**
  - **What never touches it:** none of the library's passes walks `Feeds/`, and folder edits and Delete Folder do not reach it. `FeedStore.readRecords(in:)` reads only names of the form `<UUID>.json`, so the new folder is invisible to it too.
  - **The one new rule:** `Book.tmbDirectory` names `Feeds/<feed ID>/<package>` for a row with a feed link (`Book.feedLink`, new), instead of `Library/<folder>/<package>`.
    - **Users of an existing package follow that property:** record saves, package deletion, cloud state (`BookPackage`), transcripts, the reader's working copy, and Show in Finder.
    - **The 10 other calls that build a package's path from a folder** (`TextMouthPaths.tmbPath`) are in the import's destination, the startup repair, the folder transition planner, the audio editor, the reinstating of a `.tmb` import, and the legacy migration. The feed's importer gets a destination of its own; the others never meet a feed row, or leave it out (branch A1).
  - **The feed's library folder stays the feed's place in the library tree.** It is where the feed's row shows and opens. Deleting that folder no longer deletes the feed's episodes.

### The feed's index

- **The file:** `Feeds/<feed ID>/library.json`. It holds `{"formatVersion": 1, "feedID": …, "books": [...]}`, with one `Book` row per package. It is compact, with ISO 8601 dates, as library.json is written (`LibraryPersistenceService.encodedIndex`).
- **The row:** the row library.json would hold, plus `feedLink`, which is the feed and item the row came from. bookInfo.json already holds that link (`BookMetadata.feedLink`).
- **No paths that matter:** the row's `filePath` is worked out again from its package when the index is read. So a data-directory move or a second Mac never needs the index rewritten.
- **Recovery:** an index that cannot be read is preserved beside itself, as an unreadable record is (`SavedFile.preserveUnusable`). It is rebuilt from the packages, each of which names its feed and item in bookInfo.json.

### How it was measured

- **The program:** a standalone Swift program (Swift 6.2, `swiftc -O`), in the session's scratchpad (`feedmodel2-bench/main.swift`), not part of the app.
  - **The mirrors:** it mirrors the fields of `Book`, `BookInfo`, `FeedRecord`, `FeedItem`, and `FeedText`, and the proposed index, with the app's encoder settings. library.json and the index are written compact. Records and bookInfo.json are written pretty-printed with sorted keys.
  - **The sandbox:** it writes, reads, walks, and deletes files in a sandbox folder under its own temporary directory, removed at the end of every run. It never touched ~/.TextMouth.
- **Calibration:**
  - library.json: 744 synthetic rows come to 902,523 bytes, against the user's 895,236.
  - The record: 381 synthetic items come to 2,203,229 bytes, against the user's 2,316,662 for "Finish It!".
  - An episode row as the index holds it is 888 bytes when downloaded and never opened, and 1,252 when opened with a position and one bookmark. That is about 110 bytes more than the first note's rows, for the feed link.
  - bookInfo.json is 1,428 bytes for an opened episode; the user's article's is 1,587. contentIndex.json is 134 bytes for an audio episode.
- **The machine and the runs:**
  - The machine: an Apple M3 with 8 GB, macOS 26.3.
  - Three full runs. Runs 1 and 3 had no build running (load average 2 to 3), and their figures are given below; where they differ, both are given. Run 2 met another agent's build (load 7 to 11) and was two to three times slower throughout, which is what a figure can become while the Mac builds.
  - Each figure is the median of 21 timings, or 7 for the 2,000-row cases.
  - File reads were warm, and the mirrors leave out the app's lenient field readers (`LenientFields`). Real decoding is somewhat slower; the comparisons are what count.
  - KB and MB are thousands and millions of bytes, as in the first note.

### What it costs

**The feed's index** (compact, as library.json)

| Rows | Bytes | Encode | Decode | Encode and write atomically | Read and decode |
| --- | --- | --- | --- | --- | --- |
| 5 (5 downloaded) | 4,454 | 0.05 ms | 0.05 to 0.06 ms | 0.28 to 0.29 ms | 0.07 ms |
| 52 (P1: 5 downloaded, 47 kept, a year of a weekly show) | 62,693 | 0.78 to 0.88 ms | 1.00 to 1.21 ms | 0.97 to 1.21 ms | 1.00 to 1.03 ms |
| 260 (P1: five years) | 321,413 | 3.76 to 3.87 ms | 4.93 to 4.97 ms | 4.42 to 4.53 ms | 5.14 to 5.21 ms |
| 381 (P2: "Finish It!") | 298,194 | 3.20 to 3.36 ms | 3.81 to 3.87 ms | 3.81 to 4.01 ms | 3.83 to 3.86 ms |
| 2,000 (P2: the parser's limit) | 1,572,008 | 16.9 to 17.4 ms | 20.0 to 20.6 ms | 17.9 to 18.7 ms | 20.2 to 21.3 ms |

The 260-row index is larger than the 381-row one because its rows are opened, with positions and bookmarks, while P2's rows are mostly items never downloaded.

**Packages on disk** (beyond the 5 downloaded packages, which every option has)

| Case | Packages | Made in | Entries | Logical | Allocated |
| --- | --- | --- | --- | --- | --- |
| P1, a year | 47 | 21 ms | 141 | 73 KB | 0.4 MB |
| P1, five years | 255 | 107 to 129 ms | 765 | 398 KB | 2.1 MB |
| P2, 381 items | 376 | 90 to 96 ms | 752 | 302 KB | 1.5 MB |
| P2, 2,000 items | 1,995 | 480 to 485 ms | 3,990 | 1.6 MB | 8.2 MB |

- **A kept package** is its folder, bookInfo.json, and contentIndex.json: 3 entries and 8 KB allocated. A P2 package for an item never downloaded is its folder and bookInfo.json: 2 entries and 4 KB.
- **The first note's option (b)** counted 1,143 entries for 381 items, since each of its packages held a content index too.
- **Against the whole data directory:** library.json's 744 rows imply about 3,700 entries in the data directory, at about five per package (an estimate from the rows; the Library folder was not walked). So P2's 752 would add about a fifth for one podcast.

**Launch and maintenance**

- **library.json:** decoding it takes 10.8 to 11.4 ms on the main thread for 744 rows, and 10.8 to 10.9 ms for 749 rows, which is 5 downloaded episodes kept in it as option (c) would keep them. The time to decode the rows is the same; what changes is which file holds the feed rows.
- **The feed indexes:** each is read with library.json, on the main thread, and adds its decode time from the table above.
  - P1: about 1 ms per year of listening to a weekly show, and 5 ms at five years.
  - P2: 3.8 ms for each 381-item feed, and 20 ms for a 2,000-item one.
- **The orphan walk:** 744 library packages take 7.95 to 8.17 ms, today and under L2. Under L1, 381 feed packages inside the Library folder would add these times on the main thread:

  | Feed packages under L1 | Names known from the feed's index | Each record read, since library.json names none |
  | --- | --- | --- |
  | 381 | +3.4 to 4.6 ms | +43 to 44 ms |
  | 2,000 | +20 ms | +226 to 234 ms |

- **The startup repair:** under L2, its passes (`removeRetiredBooks`, `adoptNewerRecordedPositions`, `repairStaleFilePaths`, the relocation and adoption passes) meet no feed row. The rows join the library model after the repair, and a feed's own small repair follows (section 7, branch A1).
- **Later maintenance:** the text cache batch, the statistics pass, and the metadata refresh meet only the rows of downloaded items, as today. The metadata refresh should skip them, since their titles come from the feed. Kept records never reach any of these passes.

**Counts and lists**

- **A count of a feed** (`FeedCenter.counts(of:)`): 0.02 ms for 381 items under the proposal, and 0.09 ms for 2,000. Each item's row is found in the feed's own rows by the item's identity, and whether its file is here comes from a set of downloaded book IDs.
  - Today's code takes 0.91 ms for the same count with 5 downloaded items among 749 rows, as the new default would make it, because it scans the rows twice for each downloaded item (`LibraryViewModel.feedBook(withID:)` is `bookByID`, a linear scan).
  - The first note's option (b) takes 59 to 60 ms on this run, and 124 ms under run 2's load (the first note measured 104 to 111 ms under its load).
- **Listing a feed's folder:** 0.16 to 0.17 ms for 381 items and 0.86 to 0.90 ms for 2,000. That is every item's row words, with a kept record's progress worked out from its row.
- **All Items:** with 5 episode rows in the library model, leaving them out and sorting 744 rows by title takes 4.72 to 4.83 ms, against 4.56 to 4.57 ms today. The filter costs under 0.3 ms, once per change, since the list is kept (`LibraryListCache`).

**Writes for one reading checkpoint of an episode** (every 30 seconds while it plays)

| What is written | When | Time |
| --- | --- | --- |
| bookInfo.json | within half a second, under every option | 0.22 to 0.23 ms |
| library.json, about 900 KB | within five minutes, today and under option (c) | 10.2 to 10.4 ms |
| The feed's index, 63 KB, 52 rows | within five minutes, under P1 | 0.95 to 0.97 ms |
| The feed's index, 298 KB, 381 rows | within five minutes, under P2 | 3.5 to 3.7 ms |

Listening to a podcast therefore no longer rewrites library.json, as long as each file is written only when its contents changed.

**Rebuilding and unsubscribing**

| Packages | Rebuild the feed's index (reading every bookInfo.json) | Delete the feed's packages (run 3) |
| --- | --- | --- |
| 47 | 2.3 to 2.4 ms | 7.2 ms |
| 255 | 13.2 to 13.4 ms | 38.4 ms |
| 376 | 15.6 to 15.9 ms | 38.6 ms |
| 1,995 | 86.3 to 86.7 ms | 212 ms |

**Cloud sync** (downloads sync in a cloud library, as the user answered on October 4)

- **P1:**
  - **Uploads:** each download uploads its package, as today. Its kept package stays: 2 small files after the media file goes.
  - **Per year:** about 47 packages, 141 entries, for a weekly show.
- **P2:**
  - **At subscription:** 376 packages, 752 entries, upload when you subscribe to "Finish It!", and 3,990 entries for a 2,000-item feed.
  - **Every new item:** each refresh that brings a new item makes and uploads a package.
- **Every option:**
  - **Each change:** a change to a downloaded episode uploads its bookInfo.json. The feed's index uploads within five minutes: 63 KB at a year under P1, 298 KB under P2, against library.json's 895 KB today.
  - **iCloud Drive** syncs a book package as one item (FR02), so it sees one item per package.
  - No real drive was used.

**The feed's record** (the same under every option except (c), which adds saved states to it)

| Record | Bytes | Encode | Decode |
| --- | --- | --- | --- |
| 381 items | 2,203,229 | 7.6 to 7.7 ms | 6.9 to 7.1 ms |
| 381 items, 50 holding option (c)'s saved state | 2,256,519 (53 KB more) | 8.25 to 8.28 ms | not measured |
| 2,000 items | 11,562,792 | 40.5 to 41.1 ms | 37.9 to 38.4 ms |

### Against option (c) and the first note's findings

| The first note found, for a row and package per item | The user's layout, P1 | The user's layout, P2 |
| --- | --- | --- |
| library.json 34 percent larger | None: library.json loses the feed rows (one, for this user) | None |
| Each count of the feed 104 to 111 ms (59 to 60 ms on this run) | 0.02 ms | 0.02 ms (381), 0.09 ms (2,000) |
| 3 MB and 1,143 directory entries | 0.4 MB and 141 entries a year | 1.5 MB and 752 entries (381); 8.2 MB and 3,990 entries (2,000) |
| 5.3 ms of failed file checks at every launch | None: kept records never join the launch passes | None |
| 107 uses of a book's file must handle a row with no file | None: rows without files never join the library model | None |
| A rebuilt library index drops packages without files | Not applicable: feed packages are outside the Library folder; the feed's index rebuilds from its packages in 2.3 ms | The same: 15.6 ms (381), 86 ms (2,000) |

**Against option (c)**, which the first note recommended:

| | Option (c) | The user's layout |
| --- | --- | --- |
| Where a removed download's state is kept | Its item in the record (808 bytes each) | Its own package |
| Downloaded rows | In library.json, 4.3 KB more for 5 | In the feed's index |
| A transcript once the file goes | Lost, unless no rule ever removes a transcribed download (question 6) | Kept in the package |
| Rebuilding after a lost record | Not possible: the state lives only in the record | The feed's index rebuilds from its packages |
| New files | None | One index per feed, and the kept packages |

The user's answer to question 6 ("just put the transcription in the package and keep it there") is the case (c) cannot meet.

**What remains:**

- **A second index per feed to keep in step with its packages.**
  - It is written on the same save path as library.json, with the same debounce and the same five-minute rule for checkpoints.
  - An unreadable one is preserved and rebuilt.
  - In a cloud library it is one file per feed rewritten whole, as library.json is, so the same rules apply: conflict copies are never read, and one Mac at a time stays the policy.
- **Launch time.** Each feed's index is read on the main thread at launch: about 1 ms per year of a weekly show under P1, and 3.8 ms per 381 items under P2.
- **Kept packages accumulate** under P1, at the pace of what you open. Delete Episode removes one, and nothing removes them in bulk (a follow-up if it matters).
- **A row has two homes.** It sits in the library model while its file is here, and in the feed's shelf while it is kept. The moves between them are two functions, each pinned by tests.
- **Every list, count, and maintenance pass that reads the library's rows must leave out feed rows.** There are about twelve such places in the code, listed in section 7 under branch A1. Missing one shows an episode where it should not appear, which is visible and loses nothing.
- **An older build of TextMouth** reads no feed index. It would lose sight of downloaded episodes and mark them not downloaded in the record. As the first note said, once the new build is installed an older one should not be run. The new build heals such an item at launch: a package with its file and an index row make it downloaded again.

### In memory: why downloaded rows join the library model

- **The reader finds everything by book ID in `library.books`.**
  - **The window:** a reader window takes its book from `LibraryViewModel.bookByID`.
  - **The writes:** the reader then calls about 22 functions of the library model. Among them are `persistReadingPosition`, `updateBook(id:)` (through `markBookOpened`, `updatePlaybackTimestamps`, `updateLocalVoiceAndSpeed`, `updateEndOfBookBehavior`, `updateSkippedHeadings`, `updateLocalSkipUnits`), `addBookmark`, `removeBookmark`, `updateBookmarkLabel`, `updateContentIndex`, `updateLiveReadingPosition`, `nextBookInFolder`, and `readingListNeighbor`. Each looks the row up in `library.books` and returns quietly when it is not there.
- **Kept outside it,** an episode would need every one of those functions taught a second place to look. One missed would drop a position without a word, which is the user's explicit worry ("make sure playback position is also saved").
- **Joined to it,** the rows of items whose files are here work through the paths already tested. The cost is a filter wherever the library lists or counts books, and a split where it saves:
  - `Book.feedLink` marks a feed row.
  - `LibraryPersistenceService.writeIndexFile(_:)` is the path every save of library.json takes: saves, checkpoints, the quit flush, retries, and Rebuild Library Index (`replaceUnreadableIndex(with:)`). It writes library.json from the rows without a feed link, and each feed's index from its rows: those in the library model, and its kept records, held in the library model's `feedShelf`, which is not encoded into library.json. Each file is written only when its contents changed.
  - The data-directory move writes its copy's library.json and records itself (`DataDirectoryMigrator.stage`), so it needs the same split. It moves feed rows' paths with the rest, writes them to their feed's index, and writes no record of theirs under `Library/`.
  - A feed row's `folderPath` is "". The feed's folder lists its items from the feed's rows, found by feed ID, so folder renames, moves, deletions, and Feed Info's change of folder never touch them.

## 2. Today's feed books, and moving them

### How a downloaded episode lives today

1. **The import.** `FeedDownloadManager` downloads the file, and `FeedEpisodeImporter.importBook` stages a package in the feed's library folder (`FileImportService.destinationPackageURL`) and publishes it with a new `UUID()` as its book ID (`publishReadableBook(_:from:run:feedLink:)`).
2. **The link, kept in the package only:** bookInfo.json names the feed and item (`BookMetadata.feedLink`). library.json's row does not.
3. **The row.** `FeedDownloadManager.commit(_:for:)` adds the row to library.json through `LibraryViewModel.addFeedBook` and marks the item `.downloaded(bookID:)`.
4. **Finding the book:** the engine finds the book through `FeedLibraryHost.feedBook(withID:)`, which the library model answers with `bookByID`, a linear scan.
5. **Removing it.** Delete Download and the sweep delete the whole package. `removeFeedBook` then takes the row out through `removeDeletedBook`, which removes it from the library and the reading list (`Library.removeBook(id:)`), forgets the book's pending record write, and drops its reading-text cache.

### The move, at the first launch of the new build

For every item that a feed's record names as `.downloaded(bookID:)` and whose row is in library.json, in this order:

1. Make `Feeds/<feed ID>/` if it is missing.
2. Move the package from `Library/<feed folder>/` to `Feeds/<feed ID>/`: one rename on one volume.
3. Give the row its feed link and the folder path "", work out its file path again, and write its bookInfo.json.
4. Write the feed's index with the row, and wait until it is on disk.
5. Take the row out of library.json and save it.

- **When it runs:** once the feed records have loaded, which happens off the main thread just after the library has (`FeedStore.load()`). The move needs the records to know which rows are downloads. Until it runs, the article shows where it does today.
- **A crash between steps** is mended at the next launch: the move runs again until no row in library.json is named by a record as downloaded. A row whose package has already moved is found under `Feeds/`. Meanwhile the startup repair leaves such a row as it is: `repairStaleFilePaths` changes a row only when it finds its package, and it looks only under `Library/`.
- **What stays an ordinary book:** a book whose feed is no longer subscribed, as Unsubscribe has always promised.

### This user's data

These figures were read on October 7 in the evening, without changing anything.

- **library.json:** 895,236 bytes and 744 rows, unchanged since the first note.
- **"The Digital Antiquarian"** has one downloaded article: "The Lamentable Later Life of Lemmings", an HTML book.
  - Its row: opened, with a position, no bookmarks, and no voice or speed of its own. The row is 1,242 bytes.
  - Its package: the HTML (36,112 bytes), bookInfo.json (1,587 bytes, with its feed link), content.md (30,263 bytes), and contentIndex.json (720 bytes).
  - **What changes:** it moves to `Feeds/6452A5C0-…/`. library.json drops to 743 rows, and the feed's index holds one row.
  - **What it keeps:** its position, its last-opened date, and its book ID, so its reading time in Stats stays with it. It leaves All Items, Unopened, and Recent, and shows in its feed's folder as today.
- **"Finish It!"** (381 items) has nothing downloaded, so nothing moves.
  - "Ep. 368", downloaded and deleted 25 seconds later on October 7, kept nothing, so nothing of it can be restored.
- **Both records** load as they are, with format version 1.

## 3. Counts and views

### Every place the app counts books

Feeds are counted where the Feeds section would list them at that place: every feed at All Items and at the top of Folders, the feeds below a folder, and the feeds with new items at Unopened. "Feeds" is left out when there are none.

| Place (code) | Today | Proposed |
| --- | --- | --- |
| The summary bar at All Items (`TimeRemainingBar`, visible) | "744 books" | "743 books, 2 feeds" |
| The same bar, spoken | "744 books. …" | "743 books, 2 feeds. …" (the rest unchanged) |
| The summary bar in Folders, which counts the books at the folder shown | "12 books" | "12 books, 2 feeds" where the Feeds section lists 2 feeds there |
| The summary bar at Unopened | "653 books" | "653 books, 1 feed" when one feed has a new item (the article was opened, so the count of books stays) |
| The Books section's header (`LibraryView.booksSection`) | "Books (744)" | "Books (743)" (the Feeds section is a section of its own) |
| A folder's row (`FolderRow`, from `bookCount(inFolderTree:)`) | "Podcasts, 3 books" (counting episodes below) | "Podcasts, 3 books, 2 feeds" or "Podcasts, 2 feeds" |
| Entering a folder (`FolderNavigationHistory.announcement`) | "Library, 744 books" | "Library, 743 books, 2 feeds" |
| Speak Info on a folder (`LibraryInfoWording.briefParts`) | "Classics. Folder. 12 books, 3 unopened. 2 feeds." | Unchanged: it already counts feeds apart, and its books no longer include episodes |
| Storage settings, Library Statistics | "Books: 744", "Folders: 41", "TMB Packages: 744 of 744" | "Books: 743", "Feeds: 2", "Folders: 41", "TMB Packages: 743 of 743" |
| Use This Library (`StorageWording.useSentence`) | "…the library in ~/.TextMouth (744 books)…" | "…(743 books, 2 feeds)…" |
| Rebuild Directory | "Done. 744 books in library." | "Done. 743 books in library." |
| Index recovery messages | "Your library has 744 books" | Unchanged: library.json holds books only |
| Stats, Books Finished | "7 books finished this year: … 1 podcast episode" | Unchanged: a finished episode counts, as the user chose on October 4 |
| Unsubscribe's announcement (`FeedWording.unsubscribed`) | "1 book it downloaded stays in the library." | "1 article it downloaded is now a book in The Digital Antiquarian." (section 4) |

A feed's own counts ("381 episodes, 5 downloaded, …") change only as the first note planned. Question 10 was answered yes: "10 of 381 episodes listed".

### All Items and Unopened

- **The user's answer to question 9:** "I don't think episodes or items should show up in the all or unopened views at all, just the feeds."
- **All Items** lists books, and its Feeds section lists every feed, as today.
- **Unopened** lists unopened books, and a feed while it has a new item (answer 8).
- **Episodes:** a downloaded episode is in neither. Its feed's row counts it.

### Recent

- **The user's answer:** "I'm unsure about the recent view, maybe the latest episodes only?"
- **Today:** Recent shows the 10 books opened last (`LibraryBookSorter.recent`). A week of listening to one podcast would fill it with episodes.
- **The options:**
  1. **No episodes at all.** Resuming an episode then takes three steps: Folders, the feed, the episode.
  2. **Each feed's episode or article opened last, beside the books, within the same 10** (recommended). A podcast takes at most one place, and resuming it stays one step. Played downloads leave on their own when the after-playing rule removes their files, and a removed download is not a book, so it is not listed.
  3. **Every episode opened, as today.**

### Elsewhere

- **Search:** a search at All Items finds books only. Inside a feed's folder it finds the feed's items, as today.
- **The Books rotor** lists the rows at the current place, so in a feed's folder it lists its downloaded episodes, as today.
- **The reading list** holds book IDs.
  - **Adding:** a downloaded episode can be added, and the newest-N rule never removes its file (answer 5).
  - **Leaving:** Delete Download takes it off the list, as today, since its row leaves the library model.
  - **The launch:** feed rows join before anything can edit the list, so no episode's ID is dropped then.
- **Continue Listening** finds an episode while its file is here.
- **Continue to Next Book** from an episode goes to the next downloaded episode listed after it in its feed's folder. Today it follows the folder's manual order (`nextBookInFolder`), which a feed row with no folder no longer has.
- **Speak Info and Book Info** name an episode's feed where they name a book's folder.

## 4. Not editable, transcribable, movable

The user's answer to question 6: "I really feel like feed items and episodes shouldn't act like normal books and should not be editable, maybe transcribed but if we keep the package format just put the transcription in the package and keep it there (is there an option somewhere to delete a transcription? for audio?). Maybe it should be possible to move certain episodes out of a feed into the normal folder system and then they would work nromally." (A transcript can be deleted: Delete Transcript…, which asks first.)

### What an item in its feed keeps and loses

| Command | While in its feed | After Move to Library |
| --- | --- | --- |
| Open, Speak Info, Add to and Remove from Reading List | Kept | Kept |
| Book Info (Command-I) | Kept, read-only: no field can be edited | Editable |
| The reader's metadata editor | Not offered | Offered |
| Edit Audio… | Lost | Offered |
| Edit Text… and Edit Text With… (a transcribed episode's too) | Lost | Offered |
| Clean Up Transcript (Experimental)… and Undo Cleanup | Lost: a cleanup rewrites the transcript | Offered |
| Transcribe Audio… and Transcribe Again | Kept: the transcript is written into the item's package | Kept |
| Delete Transcript… | Kept | Kept |
| Export… | Kept: it writes a copy elsewhere and changes nothing | Kept |
| Download Now, Remove Download, Keep on This Mac (a cloud library), Show in Finder | Kept: Show in Finder shows the package in the feed's folder under `Feeds/` | Kept |
| Move to Folder… | Replaced by Move to Library… | Offered |
| Remove from Library (Command-Delete) | Becomes Delete Download, which keeps the place, bookmarks, and transcript | The library's own Remove |
| The feed item's commands (Mark Played, Delete Download, Delete Episode…, Show Description…) | Kept | Mark Played and Delete Episode stay on the item's row |

- **Delete Download no longer needs the question the first note planned** for a download holding a transcript. It deletes only the file, and the transcript stays.
- **No feed item will hold audio edits or an edited text**, since neither can be made.

### Transcripts in the package

- **Where they are written:** Transcribe Audio writes transcript.json and the content.md made from it into the item's package, as for any audiobook (`TranscriptStore`).
- **When the file is removed:** the package stays, because it holds a transcript, and both files stay in it.
- **Downloading again:** the transcript is shown again if the new file is the same bytes as the one transcribed. Each audio file is fingerprinted when it is transcribed (`TranscriptTextLoader`).
- **When the bytes differ:** some podcast hosts insert advertisements into each download, so two downloads differ. The transcript is then logged as stale (`TRANSCRIPT_STALE`) and shows no text until the episode is transcribed again. It is kept, not deleted.

### Move to Library…

- **The name:** "Move to Library…". It sits in the row's context menu, its VoiceOver actions, and the Book menu.
- **What it opens:** the folder picker Move to Folder… uses, with the hint "Moves this episode into a folder of your library, where it becomes a book you can edit; it leaves the feed".
- **What it does,** in order:
  1. Write the package's record.
  2. Move the package from `Feeds/<feed ID>/` to `Library/<folder>/`, in one rename. A reader playing it follows the move as it follows any package move (`LibraryBookUpdates.packagesWillMove`).
  3. Clear the row's feed link, give it the folder, and move it from the feed's index into library.json.
  4. Set the item's state to "in library" (`FeedItemState.inLibrary(bookID:)`, new).
- **What the book keeps:** everything, because it is the same package and the same book ID: its place, playback times, bookmarks, own settings, transcript, its reading list membership, and its history in Stats.
  - bookInfo.json keeps its feed link, so Books Finished still counts it as a podcast episode.
- **What the feed shows:** an item row that says "In Library", as in "Ep. 368, In Library, July 17, 2026, 64 minutes", whose Open opens the book.
  - It keeps its played date, and Mark Played and Delete Episode… (which hides the row and leaves the book) stay.
- **Later refreshes** match the item by its identity and keep its state.
  - It counts among the newest N, and the rule never downloads it again or downloads another in its place. That is answer 4: "newest episodes should only update if there is a new episode / item".
- **If you later remove the book from the library,** the item becomes not downloaded, as an item whose book left the library does today.

### Unsubscribe

- **Today:** Unsubscribe deletes the record and keeps every downloaded book in the feed's folder (`FeedWording.unsubscribeMessage`).
- **Proposed:** the same promise.
  - Each item still downloaded is moved to the feed's library folder as an ordinary book, as Move to Library does, or to the library's top level when that folder is gone.
  - Then `Feeds/<feed ID>/` is deleted, with the places, bookmarks, and transcripts kept for removed downloads: 38 ms for 255 kept packages.
- **The confirmation says so:** "TextMouth stops checking this feed. The 2 episodes downloaded stay in Finish It! as books; the places and bookmarks kept for 12 others are deleted."

## 5. The newest-N rule with answer 5

The user's answer to question 5: "yes fir the first and third no for the second (its possible to just almost finish then stop a couple minutes / seconds before the end for long outtrows) … If the episode is open, currently playing, or in the progress of downloading maybe have a background check (or just in the next refresh check) to recheck and delete if unused".

- **The rule never removes these files:**
  - a download you asked for (`FeedItem.downloadOrigin`, the listener);
  - a download on the reading list;
  - a book open in a reader, which covers one playing, since only a reader plays;
  - a download under way.
- **It may remove a download you started and did not finish,** once it is outside the newest N. Its package stays, since it holds a position. Its row then says "Not Downloaded, 42 percent, 16 minutes remaining", and Open downloads it again and opens where you left off.
- **When it removes, chosen:** at the rule's passes that follow a refresh (at launch, hourly, Check Feed, Refresh All Feeds), when a download the rule made finishes, and when you lower the number (once it has stayed unchanged for ten seconds, as the first note planned); never when a reader closes.
  - **The background check:** a removable download that is open, playing, or downloading is passed over and looked at again at the next of those passes. With the user's settings (refresh at launch and hourly), that is within the hour.
  - **Why not when a reader closes:** removing a file the moment its reader closes would change its row under VoiceOver's cursor, from a book's row to an item's row, just as the Library window takes focus. It would also take the file from a listener who closed the reader for a moment.
  - **The after-playing rule keeps its own times,** reader closing included, as today. It removes only played downloads, after their days.
- **Answer 4 holds:** played items count among the newest N, so playing one never downloads an older one.
- **Answer 6 needs no protection now.** No rule has to spare a transcribed download, since removing its file keeps its transcript, and feed items hold no edits.

## 6. The playback position

- **What is kept, and where.** bookInfo.json, in the item's package, keeps the item's state:
  - the position (`ReadingPosition`: chapter, offsets, and when it was saved);
  - the playback times the rewind on resume uses (`lastPlaybackStarted`, `lastPlaybackStopped`);
  - the bookmarks;
  - the item's own voice, speed, pitch, skip units, and end-of-book choice, and its skipped headings;
  - a note of its transcript.

  The row in the feed's index holds the same, for the item's row to say its progress without opening the package.
- **When it is written.** A checkpoint comes every 30 seconds while playing, and at pause, stop, navigation, chapter end, and close (`persistReadingPosition`). The record takes it within half a second, and the feed's index within five minutes, as library.json does today (PERF15). A launch after a crash takes the newer position from the record: `adoptNewerRecordedPositions` does this for books, and the feed's own repair does it for feed rows, which the checkpoint journal names too.
- **Removing the file keeps it.**
  1. The book's pending record write is made at once (`writePendingBookInfoNow`).
  2. The row moves to the feed's shelf, and the feed's index is written and waited for.
  3. Only then is the file deleted.

  A failed index write keeps the file. `removeDeletedBook` is not used, since it forgets pending record writes.
- **Downloading again restores it.**
  - The importer builds the new package from the kept record (the same book ID and state, and the transcript copied) and puts it in place of the kept one. The row then joins the library model.
  - The reader opens at the saved position, with the bookmarks and settings. Stats adds the listening to the same book. The reading-text cache is keyed by the text it was made from (`ReadingTextKey`), so an article made again never reads a stale text.
- **One limit:** the position is a place in the file. If the second download differs from the first (an advertisement inserted, as above), the same time may be a few seconds away from the same words.

## 7. The revised build plan

### Branches, in order

**A1 `feature/feed-item-index`: the feed's packages and index**

- **What it changes:**
  - `Book.feedLink` (read with `decodeIfPresent`, written only when set, so library.json's rows are unchanged), carried by `makeBookInfo()` and `Book(record:…)`, with the two tests that pin every field of `Book`.
  - The package rule in `Book.tmbDirectory`, and `FeedPaths` for the feed's folder and index.
  - The `FeedIndex` file, read with library.json in `LibraryPersistenceService.load()` and written per feed by `writeIndexFile` only when changed, preserved when unreadable, and rebuilt from the packages.
  - `Library.feedShelf`. Rows join after the startup repair, and a feed repair follows: a downloaded row whose file is gone becomes kept, and journaled checkpoints come from records.
  - The move of today's feed books (section 2).
  - New downloads go to `Feeds/<feed ID>/`, and `addFeedBook` sets the link and "".
  - The places that leave feed rows out:
    - All Items, Unopened, the top of Folders, and the folder counts (`folderTreeCounts`, `totalBooksInFolderTree`);
    - the summary bar and its feeds, the Books header, the root announcement, and Storage settings;
    - Recent, with one per feed;
    - search at those places, the metadata refresh, and Find Duplicate Books;
    - Rebuild Directory, the data-directory move (feed rows go to their indexes, never to the staged library.json), and the provisional index (the split covers Rebuild Library Index);
    - the folder transition planner (no package move for a feed row), and `nextBookInFolder` for episodes.
- **Tests:**
  - library.json never holds a row with a feed link, through every write path;
  - the move, at each crash point;
  - the filters and counts' wording;
  - Recent;
  - the path rule;
  - an unreadable index;
  - the journal;
  - the reading list across a launch.
- **Size:** about 650 lines, with 800 lines of tests.
- **The user sees:** episodes leave All Items, Unopened, and Recent, and the counts read "743 books, 2 feeds". The user's article moves.

**A2 `feature/feed-item-records`: a removed download keeps its record**

- **What it changes:**
  - Delete Download, the after-playing sweep, and the library's Remove on a feed row remove the file and its caches and keep the package when it holds the listener's state (section 6); otherwise they delete it.
  - Downloading again into the kept package restores the same book.
  - `FeedReconciler.kept` keeps an item with a played date or a kept record (ending #1412, the played date lost outside the window).
  - Delete Episode deletes the package.
  - Counts and `state(of:)` find rows through the feed's index, not `bookByID`.
- **Tests:**
  - delete, then download again: the same ID, position, bookmarks, settings, and transcript;
  - a never-opened download leaves nothing;
  - the sweep;
  - a failed index write keeps the file;
  - the reconciler.
- **Size:** about 400 lines, with 500 lines of tests.
- **Useful alone:** it ends today's loss on Delete Download.

**B `feature/feed-item-policy`: the choice and the newest-N rule**

- **What it changes:** as the first note's branch B (`FeedItemPolicy`, the migration of the old settings, `downloadOrigin`, `Origin.window`, the waiting state, the short list), with answer 5's protections and section 5's timing. The rule's removals keep the package as A2 does.
- **Size:** about 700 lines, with 900 lines of tests.

**C `feature/feed-item-policy-ui`: the interface**

- **What it changes:**
  - The first note's branch C: the "List and download" pop-up menu globally and in Feed Info, item rows that speak a kept record's progress and bookmarks, "listed", and Unopened's rules (answers 8 and 9).
  - The commands an item in its feed loses (section 4), with a read-only Book Info.
- **Size:** about 450 lines, with 500 lines of tests.

**D `feature/move-to-library`: Move to Library… and Unsubscribe**

- **What it changes:** the command, the "in library" state and its row, and Unsubscribe's move of downloaded items into the feed's folder.
- **Size:** about 350 lines, with 400 lines of tests.
- **Then:** a documentation pass for README.md and ARCHITECTURE.md.

### How they meet the other work

- **`editbaselines`**, launched late on October 7, claims Book.swift and the Book Info sheets. A1 adds `Book.feedLink`, and C makes Book Info read-only for feed items, so A1 starts after that branch merges.
- **A2 needs A1. B needs A2,** whose keep-the-record removal its rule uses.
- **D needs A2.** It could run beside B with a contract for `FeedItemState`, which both change (B adds the waiting state, D adds "in library"); in order is simpler.
- **C comes after B**, whose choice it shows.
- **FR10's feed-download half** starts after B, as the first note said, since both edit FeedDownloadManager.swift.
- **FR12's branches B to E** (double presses, the full summaries with REV07's Speak Info items, the fixed menu keys, window-scoped shortcuts) edit the keyboard and menu files. Those are apart from A1, A2, and B, which can run beside them.
  - C and D add commands (Move to Library…, Delete Download on Command-Delete), so they come after FR12's branch D makes menu keys editable, or take its new action list as their contract. Each new command then gets a default key, or none, in the record of edits FR12's branch A builds.

### Risks

- **A feed row written into library.json:** prevented by the one write path's split and a test through each writer. The writers are save, checkpoint, quit flush, retry, the data-directory move, and Rebuild Library Index.
- **A position lost when a file is removed:** prevented by writing the record, then the index, then deleting the file, with a failed write keeping the file.
- **A row without a file in the library model:** the launch feed repair moves such a row to the shelf, and every removal moves its row before the file goes.
- **An episode shown where it should not be:** each filter is pinned by a test.
- **Disk:** the default keeps 5 downloads per podcast (315.8 MB for "Finish It!"), as the first note found, and kept packages add 8 KB each.
- **Two Macs, older builds, large records:** as the first note said. The record is unchanged here, so its follow-ups (one copy of each text instead of three; comparing only the changed item) stay follow-ups.

## 8. New questions for the user

Each is a yes-or-no question with a recommended answer.

1. **Should an episode get its package when it is first downloaded,** rather than as soon as the feed lists it, and keep that package after its file is removed while it holds something of yours (a place, bookmarks, its own settings, or a transcript)? Recommended: yes. A package for every listed episode would give "Finish It!" 376 packages holding nothing yet: 752 directory entries (1.5 MB on disk) to upload in a cloud library, and 3.8 ms more at each launch. A 2,000-episode feed would have 3,990 entries (8.2 MB on disk). Packages on download cost about 47 a year for a weekly show whose episodes you play.
2. **Should the library's counts read "743 books, 2 feeds"**, counting books only and naming the feeds beside them? That would apply in the summary bar, on entering a folder, in a folder's row, and in Storage settings. Recommended: yes.
3. **Should Recent list your books as now and, of each feed's episodes and articles, only the one you opened last?** Recommended: yes. A podcast then takes one place at most, and resuming it stays one step.
4. **While an episode or article is in its feed, should it lose Edit Audio, Edit Text, Clean Up Transcript, and Book Info's editing**, and keep Open, a read-only Book Info, Export, Transcribe Audio, Delete Transcript, the reading list, and Show in Finder, with Command-Delete doing Delete Download? Recommended: yes.
5. **Should "Move to Library…" move an episode into the folder you choose as an ordinary book**, with its place, bookmarks, settings, and transcript? Its feed would then list it as "In Library" and never download it again. Recommended: yes.
6. **When you unsubscribe, should the episodes and articles still downloaded become books in the feed's folder, as they do today**, and the places and bookmarks kept for removed downloads be deleted with the feed? Recommended: yes.

## Follow-ups noticed (not part of this addendum)

- `LibraryViewModel.feedBook(withID:)` is a linear scan: 0.91 ms per count of a 381-item feed with 5 downloads. A2 replaces it with lookups by identity (0.02 ms). (ViewModels/LibraryViewModel+Feeds.swift)
- The Feeds section ignores the library's search (`LibraryFeedsSectionRows.rows(at:center:)`). A search at All Items could narrow the feeds by title too. (Views/Feeds/FeedLibraryPresentation.swift)
- Continue to Next Book in a feed's folder follows the folder's manual order (`nextBookInFolder`), not the order the folder lists items in. A1 defines it for episodes. (ViewModels/LibraryViewModel+SortAndOrder.swift)
- Nothing removes kept packages in bulk. If many accumulate, a "Forget Kept Places" command in Feed Info could. (Services/Feeds/FeedLifecycle.swift)
- A kept transcript could be read as text while its audio is gone. Nobody asked for this; it is noted as a possibility.
- The first note's follow-ups stand: each feed text is kept three times; `FeedStore.update` compares the whole record twice for each percent of a download; Delete Download writes no log line.

## What I could not verify

- **VoiceOver and braille** on the proposed sentences, rows, and commands: they exist only on paper.
- **Real cloud drives** with a feed's packages and index: no drive was used.
- **Real decoding costs:** the mirrors leave out the lenient field readers.
- **Whether "Finish It!"'s host inserts advertisements into each download**, which decides whether a downloaded-again episode's transcript and position match exactly. No network was used.
- **Whether macOS reopens reader windows at launch** for an episode. The design does not depend on it, since rows join before any window opens.
- **The user's global feed settings:** config.json was not read.
- **Timings under load:** run 2, during another agent's build, was two to three times slower than the figures given.
