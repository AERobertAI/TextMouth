# Every feed item keeps its record (FR11)

A design note for FR11, written before it is built. It draws on the code on main at 89691d5d, which includes the feed-counts merge (9ae7becc) and the reading list (01197eb1), and on a measurement program run in the session's scratchpad against a synthetic library in a sandbox folder that was deleted after each run. The user's two feed records and library.json were read only for sizes and counts, never copied or changed, and the debug log only for the feed lines. Nothing in the app or the library was changed.

The request, quoted whole in FR11 in TODO-2026-09-04.md: "I actually think I want to adjust the default feed  model a bit to by default have all items saved as records in there own packages, just to mange it so that the last N items stay downloaded (default 5) with older items files removed without there records being removed... maybe there can be a popup or a checkbox in the feed info/settings screen glbal and local to have iether trakc only last N items, download latest items, or to have all items tracked but manual download only (imrpove the wording to be clearer and concise)... by deafault as I said 5 latest items managed with all items tracked." Earlier in the same answer: a played episode may "drop off the latest list" if TextMouth will "keep a record of it somehow to save that it was played and any bookmarks or local settings to restore if the user later expands the list".

## Summary

- **Today, removing a download loses its book.** Delete Download and the after-playing sweep delete the episode's whole package. Its position, bookmarks, and its own voice, speed, and other settings go with the file. The feed's record keeps only the date it was played and the date its download went. The October 3 design (option B, which the first build followed) said a removed download's position and bookmarks would wait in the feed's record, but the build never kept them.
- **Recommendation: keep each item's record in its feed's record file**, `Feeds/<feed ID>.json`, where its played date already is (option c below). When a download's file is removed, its book's state is copied into the item and written to disk before the package is deleted. That state is the book's ID, position, bookmarks, the time it was last opened, and its own settings. Downloading the item again makes the same book, with the same ID, and its state is written into the new package before the package is published. No library row and no package exists for an item without its file. Unopened, All Items, Recent, the Reading List, the Books rotor, Search, and Stats therefore only meet books whose files are on disk.
- **Why not a package for every item, as the request words it.** Measured on a synthetic library sized like the user's, a package and a row for each of the 381 items of "Finish It!" would have these costs:
  - library.json grows by 34 percent.
  - With today's lookup of books by ID, each count of the feed takes 104 to 111 ms on the main thread. A 2,000-item feed takes 1.0 to 1.1 s.
  - The data directory gains 3 MB and 1,143 directory entries.
  - Every launch spends 5.3 ms on failed file checks on the main thread.
  - A book's file path is read in 107 places in 35 source files, and each of those would have to handle a row with no file.
  - A library index rebuilt from the packages leaves out every package that has no file.
- **One choice with three answers and one number.** It is set globally in the Feeds tab and per feed in Feed Info:
  - "Every item listed, newest 5 downloaded" (the default).
  - "Every item listed, downloads by hand".
  - "Only the newest 5 listed".

  It replaces "Keep the newest … entries" (`feedKeepEntries`, and each feed's `keepEntriesOverride`) and "Download new episodes and articles by themselves" (`feedAutoDownload`). "Delete downloads after playing" stays as it is, globally and per feed.
- **What FR11 changes of the user's October 4 answers.**
  - Keeping the last 10 entries becomes listing every entry.
  - Downloading nothing by itself becomes keeping the newest 5 downloaded.
  - These stay as they are: deleting a download one day after playing, downloads syncing in a cloud library, refreshing at launch and hourly, plain http with a warning, finished episodes counting as Books Finished, the refresh alert and notifications off, and video played as audio.
- **The user's data.** Both feed records and the one downloaded article load as they are, and nothing is lost.
  - "Finish It!" keeps all 381 entries today through its own setting. It will follow the new default and download its newest 5 episodes once, 315.8 MB, on a network without data limits.
  - The episode downloaded and then deleted on October 7 had nothing kept, so nothing of it can be restored.
- Section 8 asks the user ten yes-or-no questions, each with a recommended answer. Section 9 plans the build in three branches: the records, then the choice and the newest-N rule, then the interface.

## 1. How it works today

### The record

- **`FeedRecord`** (Models/Feed.swift) is the file `Feeds/<feed ID>.json` beside library.json. It holds the subscription (`Feed`) and its items (`FeedItem`), newest first, pretty-printed with sorted keys (`FeedRecordCoding`). The file syncs with a library in the cloud.
- **`FeedStore`** (Services/Feeds/FeedStore.swift) holds every record on the main actor. It rewrites a record whole, on a queue of its own, whenever the record's durable form changes; a download's progress alone writes nothing (`FeedRecord.durable`).
- **What an item keeps of the listener:**
  - `state` (`FeedItemState`): not downloaded, downloading, failed with a reason, or downloaded as a book ID.
  - `playedDate`, `downloadDeletedDate`, and `deletedDate`.
  - Everything else follows the feed at each refresh. Each text is kept three times (`FeedText`: HTML, plain text, and Markdown).
- **The book's side:** a download's package names its feed and item in bookInfo.json (`FeedBookLink`, `BookMetadata.feedLink`). Its library.json row does not.
- **This Mac's side:** fetch details (`FeedFetchState`) and resume data in Caches, and finished downloads waiting to be imported (`MachineLocalPaths.feedDownloads`).

### Listing and counting

- **The list:** `FeedRecord.listedItems` is every item not deleted. A feed's folder lists them newest first (`FeedFolderListing.make`).
  - A downloaded item shows as its book's row, with the item's commands.
  - Any other item shows as an item row (`FeedItemRowContent`), spoken by `FeedWording.itemRowLabel`: "How the Fed sets rates, Not Downloaded, New, October 1, 2026, 28 minutes".
- **The counts:** `FeedCenter.counts(of:)` (Views/Feeds/FeedLibraryPresentation.swift) counts the items listed, downloaded, downloading, new, and unplayed, with the feed's size (`Feed.entryTotal`, merged October 7).
  - `FeedWording.countsPhrase` says them: "10 of 381 episodes kept, 3 downloaded, 2 new, 5 unplayed".
  - It finds each downloaded item's book through `FeedLibraryHost.feedBook(withID:)`, which is `LibraryViewModel.bookByID`, a linear scan of `library.books`. It scans twice for each downloaded item, once in `state(of:)` and once in `isNew`.
- **Unopened** lists every book never opened. Its Feeds section lists every feed with an unplayed item (`LibraryFeedsSectionRows.feeds(at:center:)`).

### The kept-entries window

- **Matching:** `FeedReconciler.merge(_:into:keepEntries:now:texts:)` matches the parsed items to the record's: by identity, then by guid, then by enclosure address.
- **What the record keeps** (`FeedReconciler.kept`):
  - every item downloaded or downloading;
  - every deleted item the feed still lists;
  - the newest `keepEntries` of the rest, in the order of `FeedReconciler.isNewer`: by publication date, else the date first seen, then the feed's own order, then the episode number.
- **What it loses:** an item outside the window leaves the record whether or not it was played. A played item without a download that falls outside the window loses its played date. The October 3 design said such an item would stay.
- **The number:** `keepEntries` is `Feed.keepEntries(under:)`, which takes the feed's `keepEntriesOverride` or else the setting `feedKeepEntries`. `SettingsPolicy.feedKeepEntries` allows 0 to 2,000, defaults to 10, and takes -1 for every entry.
- **Two merges per refresh:** a refresh merges first off the main actor into a copy, reading the texts, and then on the main actor into the record as it is by then (`FeedRefresher.perform`). A changed number makes the next check read the feed whole (`FeedFetchState.keptEntriesOfLastBody`).

### Automatic downloads

- **The setting:** with `feedAutoDownload` on (it is off by default), `FeedCenter.refreshEnded(_:)` asks `FeedDownloadManager` to download each item a refresh found new, with the origin `.automatic`.
- **`FeedDownloadManager`** (Services/Feeds/FeedDownloadManager.swift):
  - downloads one item at a time and keeps resume data;
  - refuses a file whose declared length would leave less than the app's 1 GB reserve free (`ArchiveLimits.standard.freeSpaceReserve`, `FeedDownloadError.notEnoughSpace`);
  - runs automatic downloads as discretionary requests, which a network with data limits refuses.
- **Put-off downloads:** a refused automatic download is put off (`putOff`). Its row says "Download Failed" with the reason "“X” waits for a network without data limits to download by itself". It is asked for again once a refresh TextMouth made by itself reaches the network (`retryPutOffDownloads()`).
- **Quitting:** downloads under way when TextMouth quits resume at the next launch (`stopForQuit()`, `resumeDownloadsSavedAtQuit()`).
- **Announcements:** none of this is announced; only the commands the listener chooses speak.

### A download becomes a book

- **The import:** `FeedEpisodeImporter.importBook` (Services/Feeds/FeedEpisodeImporter.swift) stages an empty package and moves the file in; for an article, the file is HTML that it writes itself.
- **The book:** it makes a `Book` whose ID is a new `UUID()`, with the item's title, the show as album, and "Podcast" as genre. It publishes the book through `FileImportService.publishReadableBook(_:from:run:feedLink:)`.
- **The row:** `FeedDownloadManager.commit(_:for:)` adds the row through `LibraryViewModel.addFeedBook`, which skips the duplicate question, and marks the item `.downloaded(bookID:)`.

### Deleting, marking, and unsubscribing

- **Delete Download** (`FeedCenter.deleteDownload(_:of:)`, Services/Feeds/FeedLifecycle.swift):
  - It is refused while the book is open in a reader.
  - Otherwise the package goes to the Trash, or is deleted for good, as the removal setting says. The row leaves the library, and the item becomes not downloaded with a `downloadDeletedDate`.
  - The position, bookmarks, and per-book settings lived in that package and that row, so they are gone.
- **The after-playing sweep** (`sweepPlayedDownloads()`) runs at launch, after every refresh, every finished book, Mark Played, Mark All Played, and every reader closing (`requestSweep()`).
  - It deletes, for good and off the main thread, the package of every item played at least the set number of days ago. The setting is `feedDeleteDownloadsDaysAfterPlayed`: 0 for at once, 1 by default, -1 for never. A feed can override it with `deleteDownloadsDaysAfterPlayedOverride`.
  - It never deletes a book open in a reader, never a package that is not wholly on this Mac in a cloud library, and nothing while the library's index is being recovered.
  - An item whose book the library no longer lists, because the book was deleted from the library, becomes not downloaded.
- **Delete Episode** (`deleteItem`) stops the item's download and deletes it. The item stays in the record with a `deletedDate`, so no refresh brings it back.
- **Mark Played and Mark Unplayed** set and clear `playedDate`. A book that plays to its end sets it too (`bookDidFinish`, heard through `.bookDidFinish`). **Mark All Played** marks every listed item.
- **Unsubscribe** (`unsubscribe(_:)`) stops the feed's downloads and deletes its record and this Mac's fetch details. The downloaded books stay in the folder.

### What the user's record shows

- In "Finish It!", "Ep. 368" was downloaded at 14:50:42 UTC on October 7, and its download was deleted 25 seconds later (`downloadDeletedDate` 14:51:07). It had not been played to its end. Any position or bookmark it held went with its package.
- Neither Delete Download nor removing a book from the library writes a log line, so which of the two deleted it cannot be told.

## 2. Where an item's record lives

### The options

- **(a) A package for each item from its first download, kept when its file is removed.** The row stays in library.json, marked as having no file. The package keeps bookInfo.json and contentIndex.json.
- **(b) A package and a row for every item, made when the item is first seen.** These are the user's own words: "all items saved as records in there own packages".
- **(c) The item's state in its feed's record until the item is downloaded again.** A removed download's book state is copied into its item, and the package and the row go.

### How it was measured

- **The program:** a standalone Swift program (Swift 6.2, optimized) in the session's scratchpad, not kept and not part of the app.
  - It mirrors the field names and types of `Book` (library.json rows), `BookInfo` (bookInfo.json), `FeedItem`, and `FeedRecord`, and fills them with synthetic values sized like the user's files.
  - It encodes them with the app's own encoder settings: library.json compact with ISO 8601 dates; feed records and bookInfo.json pretty-printed with sorted keys.
  - It writes, reads, and walks the files in a sandbox folder that it deletes at the end of each run. It never touched ~/.TextMouth.
- **Calibration:** 744 synthetic rows come to 882 KB, against the user's 895 KB. A 381-item synthetic record comes to 2.22 MB, against the user's 2.32 MB, with each item's summary sized to the user's averages: 2,361 bytes of HTML, 1,011 of plain text, and 1,615 of Markdown.
- **The machine:** an Apple M3 with 8 GB, macOS 26.3.
  - Each figure is the median of 5 to 21 runs. Two full runs agreed within about 10 percent; atomic writes varied more. Where the two runs differ, both figures are given.
  - Three other agents were building throughout (load average 10 to 13 on eight cores), so the times are upper bounds.
  - The real types decode through lenient field readers (`LenientFields`), which the mirrors leave out, so real decoding is somewhat slower. What matters is the comparison between options.

### What each option costs

**Library rows and library.json**

- **Row sizes:** an episode's row is 740 bytes before it is opened, and 1,151 bytes once it has been played and holds one bookmark. The user's rows have a median of 1,226 bytes.
- **(a)** adds one row for each item ever downloaded. "Finish It!" publishes 34 to 54 episodes a year, so the default rule would add about 40 to 50 rows a year for that feed. 52 such rows make library.json 60 KB larger (882 to 942 KB) and its encoding 0.5 to 0.8 ms slower.
- **(b)** adds 381 rows at once for "Finish It!":
  - library.json grows from 882 KB to 1,183 KB, 34 percent more.
  - Encoding it takes 12.5 to 12.8 ms instead of 9.7 to 9.9 ms. Every save encodes it: half a second after a change, and within five minutes of each reading checkpoint.
  - Decoding it at launch takes 15.2 to 15.6 ms instead of 11.1 to 12.1 ms.
  - A feed of 2,000 entries (the parser's limit) makes library.json 2,466 KB, 25.9 to 27.0 ms to encode and 32.6 to 33.2 ms to decode.
- **(c)** adds no rows.

**Packages on disk**

- **A package left without its file** holds bookInfo.json (1,498 bytes) and contentIndex.json (199 bytes). With its folder, that is 8 KB on disk.
- **(a):** 8 KB for each item ever downloaded, about 400 KB a year for a weekly show.
- **(b):**
  - 381 packages: 3,048 KB and 1,143 directory entries, made in 0.16 to 0.23 s.
  - 2,000 packages: 16 MB, made in 0.88 to 1.24 s.
- **(c):** no packages. The feed's record grows by 864 bytes for each item that holds a removed download's state.
  - 50 such items add 59 KB, 2.6 percent of a 2.2 MB record. Encoding it on the record's own queue takes 9.7 to 11.4 ms instead of 8.5 to 9.3 ms.
  - If all 376 items not downloaded held one, they would add 440 KB.

**Launch and maintenance passes over rows**

- **`repairStaleFilePaths`:** `migrateOldBooksIfNeeded` calls it at every launch, on the main thread. For each row whose file is missing it checks two more places.
  - 381 rows without files cost 5.3 ms; 2,000 cost 29 to 33 ms.
  - Under (a), 52 rows would cost about 0.7 ms (scaled from the 381-row figure).
- **`adoptOrphanedTMBPackages`** walks the Library folder at every launch:
  - 744 packages: 3.9 to 4.1 ms;
  - 1,125 packages: 5.6 to 5.7 ms;
  - 3,125 packages: 13.9 to 15.2 ms.
- **`refreshOutdatedMetadata`** reads a row's file again when no metadata reader has stamped the row, or an older one has. Feed downloads are imported without a stamp. A row that still needs reading but has no file is skipped and left unstamped, so it is looked at again at every launch.
- **The text cache batch** (`booksNeedingCacheUpdate`) leaves audio out. It would still list an article's row that has no content.md at every launch, and show the Extracting Text overlay for it.
- **The statistics pass** (`calculateMissingBookStats`) skips a missing file without saying so. After a change of the content index's version, it would look at such a row again at every launch.
- **(c):** none of these passes ever sees an item without a file.

**List derivation and counts**

- **The lists that would need a filter:** All Items lists every row (`booksForCategory`), Unopened every row never opened (`Library.unopenedBooks()`), Recent every row opened lately, and the Books rotor the rows at the current location. Under (a) and (b), each of them must leave out rows without files. Under (b), before that filter, Unopened in the synthetic library grows from 651 rows (the user's has 653) to 993 for one feed.
- **The counts:** `FeedCenter.counts(of:)` looks up each item's book with a linear scan, twice for each item that has a book.
  - With 5 downloaded items in 749 rows, as the new default would make it under (c), a call takes 1.1 to 1.2 ms.
  - Under (b), a call takes 104 to 111 ms for 381 items and 1.0 to 1.1 s for 2,000. Counts are asked for every feed row as the list draws, and twice for each feed at Unopened.
  - An index of rows by ID would bring these down to 0.2 and 0.6 ms, but the library keeps no such index today.
- **(c):** the counts stay as they are today.

**Search**

- **Today:** the library's search narrows the rows at the current location by title and author. Inside a feed's folder, it narrows the feed's item rows too (`FeedFolderListing.make`).
- **(a) and (b):** episodes without files would also answer a search in All Items.
- **(c):** an item without a file is found by searching inside its feed's folder, as an item never downloaded is found today.

**Stats**

- **Today:** reading statistics are kept by book ID (`bookListeningSeconds`, and Books Finished by kind through `finishedBookKind(of:)`). They never count rows.
- **Every option:** a book's history stays when its file goes.
- **(c):** a download made again keeps the same ID, so its listening time adds up as one book.

**Cloud sync** (downloads sync in a cloud library, as the user answered on October 4)

- **(b):** 381 packages, 1,143 files, are uploaded when the user subscribes, and each bookInfo.json is uploaded again whenever it changes.
- **(a):** one package for each download, as today, which is kept after its file goes.
- **(c):** no new files. The feed's record is rewritten whole at each change (2.2 MB for "Finish It!") and uploads as it does today.

**A row with no file**

- **Code that reads the file:** `bookFileURL` or a `.filePath` appears 107 times in 35 source files. Each of these expects the file to be there:
  - the reader: an audiobook whose file is missing says "Re-import the book to restore it";
  - Book Info, Export, Edit Audio, and Transcribe;
  - the cloud commands, which judge a package by the files it holds (`BookCloudStorageService.survey(of:)`), so a package without its file reads as downloaded;
  - the File Size sort;
  - the duplicate check: the row keeps its file's MD5, so importing the same MP3 by hand would ask the duplicate question about a book that has no file;
  - Continue to Next Book, the reading list, and quick resume;
  - folder counts, and the summary bar's time left.
- **A rebuilt index:** `buildProvisionalLibrary()` builds the library shown while its index cannot be read, and Rebuild Library Index saves that library. It adopts packages through `adoptOrphanedTMBPackages`, whose `orphanedBook(in:)` returns nil for a package with no content file. A rebuilt index would therefore leave out every row of (a) and (b) that has no file.
- **Tests:** a new `Book` field, such as the date a file was removed, would have to be added to the two tests that pin every field (`ContentAnalysisMergeTests.bookWithEveryFieldSet` and `testBookRebuiltFromItsRecordHasEveryField`).
- **(c):** adds no field to `Book` and no row without a file.

### What (c) gives up, and how to keep it

- **More than state lives in a package.** A removed download's package may also hold:
  - a transcript: transcript.json, and the content.md made from it;
  - audio edits and their kept originals (audioEdits/);
  - an edited text.

  Option (a) would keep these. Option (c) keeps them by never removing such a download automatically (question 6). Only Delete Download removes it, and for such a download it asks first, naming what goes with it.
- **The record is one file per feed, rewritten whole at each change.** For a 2,000-entry feed:
  - the record is 11.6 MB, and encoding it on its queue takes 47 to 51 ms;
  - each whole percent of a download's progress costs 2.2 to 2.3 ms on the main actor, because `FeedStore.update` compares the whole record twice;
  - the merge on the main actor takes 15.7 to 19.6 ms.

  This cost exists today for any feed set to keep every entry; FR11 makes it the default.
- **A follow-up would roughly halve it.** Keeping one copy of each text instead of three would roughly halve the record: the plain text and Markdown copies are 1.0 MB of the 2.3 MB of "Finish It!". That is a follow-up, not part of FR11.

### Recommendation: option (c)

- **It keeps what the user asked for:** every item is tracked, and its played date, position, bookmarks, and own settings stay when its file goes, ready to be restored. They are kept where the feed's items already keep their state.
- **It adds no row and no package** for an item without its file, so no list or file path has to learn about one.
- **It fixes today's loss on Delete Download** even before the new choice is built (branch A in section 9).
- **Option (a) comes second.** Its sizes are small, but every list and every use of a book's file would have to handle rows without files, and a rebuilt index would drop those rows.
- **Option (b) costs the most** on every measure above.

## 3. Where these records show

What a VoiceOver user meets for each kind of item, under (c):

- **An item never downloaded** (from the back catalogue, or new):
  - an item row in its feed's folder;
  - counted in its feed's size and in its unplayed count;
  - nowhere else. Search inside the feed's folder finds it, and Unopened lists its feed while the item is new (question 8).
- **A downloaded item, never opened:**
  - its book's row in the feed's folder, with the item's commands;
  - its book's row in All Items, and in the Books rotor wherever that lists it;
  - counted as downloaded;
  - in Unopened as a book, today. Question 9 asks whether its feed's row should stand for it there instead.
- **A downloaded item, opened:** all of the above, and in Recent. Its listening counts in Stats, and in Books Finished when it ends.
- **An item whose download was removed** (played, or started and then deleted by hand):
  - an item row in its feed's folder that says its saved progress and bookmarks;
  - counted in its feed's size, and in the unplayed count while it is unplayed;
  - not in All Items, Unopened, Recent, or the Books rotor, which list books;
  - its history in Stats stays under its book ID.
- **An item the short list hides** (under "Only the newest 5 listed"):
  - nowhere;
  - counted in "7 of 381 episodes listed";
  - listed again, with its record, when the list widens.
- **A deleted item** (Delete Episode): nowhere, as today.
- **The Reading List** (merged 01197eb1) lists books and no feeds. A downloaded episode can be put on it, and the rule never removes the file of one that is (question 5). Delete Download takes it off the list, because a row leaving the library leaves the list too (`Library.removeBook(id:)`). Downloading it again does not put it back.
- **Navigation:** in a feed's folder, the Books rotor lists the books of the downloaded items, and item rows are reached by arrowing, as today. A rotor of a feed's items could come later.

## 4. The three choices, worded

### The pop-up menu and the number

- **Where:** in Settings, the Feeds tab, group "Episodes and Articles". A pop-up menu labelled "List and download" takes the place of "Keep the newest … entries" and of the "Download new episodes and articles by themselves" checkbox.
- **The three choices, each with its one-sentence hint:**
  1. "Every item listed, newest 5 downloaded" (the default). Hint: "Lists every episode and article with what you did with it, keeps the newest 5 downloaded, and removes older downloads while keeping their place, bookmarks, and settings."
  2. "Every item listed, downloads by hand". Hint: "Lists every episode and article; nothing downloads by itself, and a download stays until you delete it or its days after playing pass."
  3. "Only the newest 5 listed". Hint: "Lists the newest 5, leaving out those you have played; the others keep their records and come back when you list more."
- **The number:** "How many of the newest", a number field and a stepper drawn as the feed settings draw numbers today, labelled, with its value spoken.
  - It runs from 1 to 2,000, the parser's limit, with 5 by default.
  - The first and third choices share it. It is dimmed under the second.
  - The choices' titles show the number in force, as in "newest 3 downloaded".
- **Per feed:** Feed Info's group "This Feed's Settings" gains the same pop-up menu and number, under a checkbox "Use the global setting (Every item listed, newest 5 downloaded)" (`FeedWording.useGlobal`), as its two numbers have today. In Feed Info, the titles use the feed's noun: "Every episode listed, newest 5 downloaded".
- **Why a pop-up menu rather than radio buttons:** VoiceOver reads a pop-up menu in one stop, with its value. The hosted tests can also reach it: they see AppKit pop-up menus, but on this Mac they never see SwiftUI's buttons.

### Behind the three: two fields and one number

- **`FeedItemPolicy`** holds:
  - `listing`: every item, or the newest N;
  - `downloading`: the newest N, or by hand;
  - `count`: N.
- **The fourth combination:** the pop-up menu offers three of the four combinations. "The newest N listed and downloaded" stays out unless the user asks for it (question 3); it would cost only a fourth title.

### What it replaces and what stays

- **Replaced:**
  - `feedKeepEntries` and `Feed.keepEntriesOverride`, by `listing` and `count`;
  - `feedAutoDownload`, by `downloading`;
  - their config.json keys, by `feedItems` and `feedNewestCount`.
- **Stays:**
  - "Delete downloads after playing" (`feedDeleteDownloadsDaysAfterPlayed`, 1 day by default, with each feed's override);
  - the refresh settings, the refresh alert, and the notifications.
- **How they combine:**
  - Under every choice, the after-playing rule removes a played item's file once its days have passed, and keeps the item's record.
  - Under the first choice, a played item still counts among the newest N. The rule that keeps N downloaded never downloads an item already played, so as you play, the newest N hold fewer downloads until new items arrive (question 4).
  - With "Never delete played downloads" checked, the played downloads the rule made stay until they fall out of the newest N.

### Exactly which items count as "the newest N"

- **Order:** the order the feed's folder lists items in. That is by publication date, else by the date first seen, then by the feed's own order, then by episode number (`FeedReconciler.isNewer`). Deleted items do not count. Played items do.
- **Which downloads the rule manages:** only the ones it made itself.
  - Each item records why it was downloaded, in a new `FeedItem.downloadOrigin`: by the rule, or by you. An item downloaded before FR11 counts as yours.
  - A download you asked for is kept until you delete it or the after-playing rule removes it.
- **Never removed by the rule** (questions 5 and 6):
  - a book open in a reader;
  - an item you opened and have not finished;
  - an item on the reading list;
  - an item with a transcript, audio edits, or an edited text.
- **A refresh that brings new items:**
  - Each unplayed item among the newest N is downloaded as discretionary work.
  - When a download the rule made finishes and the rule then holds more than N downloads, the files of its oldest downloads outside the newest N are removed (section 5).
  - A download that fails or waits removes nothing, so the episodes ready to play never drop because a new one could not arrive.
- **Disk space:**
  - A download that would leave less than the 1 GB reserve free is not started. Its item says it is waiting for room, as in "Waiting to Download, it needs room for 61 MB on this Mac".
  - The rule tries again at its next pass. Nothing is ever removed to make room.
- **A network with data limits:**
  - The rule's downloads are discretionary, like the automatic downloads of today. Such a network refuses them, so they are put off and asked for again once a refresh TextMouth makes by itself reaches a network without limits.
  - Their items say "Waiting to Download" with that reason, rather than "Download Failed".
  - Removing files needs no network.
- **A download that fails for any other reason** is tried again at the next refresh, not at every pass, so a broken file never strains its server.
- **Subscribing, and the first launch of the new build:** the rule downloads the newest N at once, on a network without data limits (question 7).
- **Changing N or the choice:**
  - A larger N downloads the items it newly includes.
  - A smaller N removes the files beyond it, once the number has stayed unchanged for ten seconds, so typing 15 never passes through 1.
  - Moving from the first choice to the second or third removes nothing.
  - A new choice makes the next check read the feed whole, as a new kept-entries number does today.
- **The short list ("Only the newest N listed"):**
  - It lists the newest N in the order above, leaving out played items that have no download. That is the user's "a played episode drop off the latest list". A played item that is still downloaded stays listed until the after-playing rule removes its file.
  - It also lists every item downloaded or downloading, wherever that item falls in the order.
  - A played item's place is not taken by an older one.
  - Items outside the list that hold a played date or a removed download's state stay in the record, hidden. The rest leave the record, as today, and come back from the feed when the list widens.
  - Downloads are by hand (question 3).
- **Mark All Played** marks every item the record holds, hidden ones included.

## 5. Removing a file and restoring it

### What is removed

- **The whole package:** the audio file or the article's HTML, bookInfo.json, contentIndex.json, content.md, and caches. The row leaves library.json.
- **Where it goes:** the rule and the after-playing sweep delete it for good, so played episodes never fill the Trash. Delete Download sends it to the Trash, or deletes it for good, as the removal setting says, as today.

### What stays, in the item

- **Where:** in `FeedItem.savedBook`, a new optional `FeedSavedBook`.
- **What it holds:**
  - the book's ID;
  - its reading position, with the total character count and the duration its row needs to say how far it got;
  - its bookmarks, with their labels;
  - when it was last opened, and its playback times, for the rewind when playback resumes;
  - its own voice, speed, pitch, skip units, end-of-book behavior, and skipped headings;
  - any title or author edited by hand, with `handEdits`.
- **Size:** 864 bytes pretty-printed, for a position, two bookmarks, and a speed of its own.
- **When:** it is kept only when the book was opened, or holds bookmarks, settings of its own, or hand edits. A book never opened leaves nothing, and its next download is a new book.
- **Unchanged:** the played date and the deleted date stay on the item, as today.

### In what order

1. Copy the book's state into the item.
2. Write the record and wait until it is on disk (`FeedStore.flush()`, with the feed absent from `unsavedFeedIDs`).
3. Delete the package.
4. Take the row out of the library.

- **A failed write:** if the record cannot be written, the package stays, and the failure reaches the Library window's banner, as every failed save does.
- **Several removals in one pass** write the record once.
- **A book deleted from the library by hand** (Command-Delete on its row) goes through the same four steps, so its state is kept as it is with Delete Download.

### Restoring

- **Downloading again:** the item can be downloaded again through Download, Open, the rule, or a widened list. The new book takes the saved ID, and the saved state is written into its row and its package record before the package is published.
  - `FeedEpisodeImporter.importBook` takes the saved state; `publishReadableBook` writes the package record from the row.
  - The reader opens the book where it was, with its bookmarks and its settings.
  - Stats adds its listening to the same book.
  - `savedBook` is cleared once the row is in the library.
- **No stale text:** the reading text cache in this Mac's Caches is kept by book ID and checked against the text it was made from (`ReadingTextKey`). An article made again under the same ID never reads a stale cache.
- **A widened list** (a larger N, or the third choice changed to the first or second) lists the hidden items again, with their played dates and saved states.
  - Items the record had dropped come back from the feed's next whole read, with no record of their own, since they had none.
  - A removed download comes back as a file only when it is downloaded again.
- **Deleting and unsubscribing:**
  - Delete Episode discards the item's saved state along with the item.
  - Unsubscribe deletes the record, saved states included. Its message says so: "…and forgets the items it hasn't downloaded, with the places and bookmarks kept for them."

## 6. This user's data

### What is there

These were read on October 7 in the evening, without changing anything.

- **library.json:** 895,236 bytes and 744 rows: 729 EPUB, 11 audio, 2 plain text, 1 DAISY, and 1 HTML. There are 41 folders, and 653 rows have never been opened.
- **"Finish It!"** (`Feeds/74086855-….json`, 2,316,662 bytes):
  - 381 items, every one kept through the feed's own `keepEntriesOverride` of -1. None is downloaded and none is played.
  - Published from May 2018 to October 2, 2026, 34 to 54 a year.
  - Enclosures of 5.3 to 194.4 MB, 60.7 MB in the middle, 26.2 GB in all. Durations of 2.7 to 121 minutes, 64 in the middle.
  - Summaries make up 82 percent of the file.
  - The log shows the subscription at 14:48:27 UTC keeping 10 entries, then a refresh at 14:50:14 adding 371 once the feed was set to keep every entry. "Ep. 368" was downloaded at 14:50:42 and its download deleted at 14:51:07, unplayed.
- **"The Digital Antiquarian"** (`Feeds/6452A5C0-….json`, 1,009,599 bytes):
  - 10 items kept under the global number: 8 articles and 2 episodes, a 5.7 MB MP4 video (played as audio) and a 2.1 MB MP3. The articles' full texts make up 97 percent of the file.
  - One article, the second newest, is downloaded and opened, with a reading position, no bookmarks, and no voice or speed of its own. It is the only book in either feed's folder.

### How the change meets it

- **Loading:** both records load as they are. Every new field is optional (`decodeIfPresent`), and the record's format version stays 1.
- **Settings:**
  - The global choice becomes the new default: every item listed, newest 5 downloaded.
  - The -1 of "Finish It!" ("keep every entry") becomes "Use the global setting", which lists every entry, as the feed does now.
  - Any other number a feed kept would become "Only the newest n listed".
  - The old global values (`feedKeepEntries` and `feedAutoDownload`) are read once for this and then left in place, unused. This note did not read them.
- **"Finish It!":**
  - All 381 entries stay listed.
  - Its newest 5 (September 5 to October 2, 2026; 319 minutes; 315.8 MB) download once, on a network without data limits.
  - Nothing is removed.
  - "Ep. 368" (July 17, 2026) is outside the newest 5, so it stays a plain item, not downloaded.
- **"The Digital Antiquarian":**
  - Its next check reads the feed whole and lists every entry the feed offers.
  - Of its newest 5, the 4 not yet downloaded download: 2 articles and both episodes, 7.8 MB in all.
  - The downloaded article stays as it is: it is among the newest 5, it was downloaded before FR11 so it counts as the user's, and it is not played.
- **library.json** keeps its format. It gains a row for each download made: 9 at first.
- **Nothing is lost:** the change removes no position, bookmark, played date, or download.
- **One caution:** an older build of TextMouth that writes a record drops the fields it does not know, as `FeedRecord` says it does, and the saved states are among them. Once the new build is installed, an older one should not be run.

## 7. Accessibility

### Item rows

- **Order:** a row's label puts first what matters most on a braille display: the title, then Played (or Read), the state, the saved progress, the bookmarks, New, the date, and the duration.
  - A removed download, unplayed: "How the Fed sets rates, Not Downloaded, 42 percent, 16 minutes remaining, 2 bookmarks, October 1, 2026, 28 minutes".
  - A removed download, played: "How the Fed sets rates, Played, Not Downloaded, 2 bookmarks, October 1, 2026, 28 minutes". A played item says no progress.
  - A download waiting for its network: "How the Fed sets rates, Waiting to Download, it downloads on a network without data limits, October 1, 2026, 28 minutes".
- **Progress words:** they are the book row's own (`BookRow.spokenProgress`, `Book.estimatedTimeRemaining`), computed from the saved state, so an episode says the same before and after its file goes.
- **Visible notes:** what a row shows matches what it speaks: "Not Downloaded", "Waiting to Download", "42%", "2 bookmarks".
- **Hints:** an item with a saved state hints "Downloads it again, then opens it where you left off". Any other item keeps today's hint, "Downloads it, then opens it".
- **Commands:** as today, from the context menu and as VoiceOver actions.

### The pop-up menu and the number

- **What VoiceOver hears:** the label "List and download", the value ("Every item listed, newest 5 downloaded"), and "pop-up button". The number reads as "How many of the newest", its value, and "stepper"; under the second choice, VoiceOver adds "dimmed".
- **In Feed Info:** the checkbox reads as "Use the global setting (Every item listed, newest 5 downloaded), checkbox, checked", and while it is checked, the pop-up menu and the number are dimmed.
- **Hints:** each choice's hint is the sentence given in section 4. It is spoken after a pause and also appears on a braille display.

### Counts

- **Every item listed:** on the first day, a feed's row says "Finish It!, Feed, 381 episodes, 5 downloaded, 381 unplayed, checked today at 3:05 PM" (`FeedWording.feedRowLabel`); once a new episode has arrived and one has been played, "Finish It!, Feed, 382 episodes, 5 downloaded, 1 new, 381 unplayed, …". The open feed's summary bar uses the same counts, and its items are headed "Episodes (381)".
- **The short list:** "7 of 381 episodes listed, …" and "Episodes (7 of 381 listed)". Question 10 decides whether the word stays "kept".

### Announcements

- **Delete Download:** "Deleted the download of “How the Fed sets rates”. Its place and bookmarks are kept for when you download it again."
- **The rule's own work:** its downloads and removals are silent and logged, as automatic downloads are today. The download progress of FR10 will make the downloads under way audible.

## 8. Questions for you

Each has a recommended answer.

1. **Should each item's record live in its feed's record file**, where its played date already is, rather than in a package of its own? Recommended: yes. A package for every item would make library.json a third larger, slow each count of the feed to a tenth of a second, and leave a rebuilt index without them (section 2).
2. **Should the three choices be worded as in section 4** ("Every item listed, newest 5 downloaded", "Every item listed, downloads by hand", "Only the newest 5 listed"), with one "newest" number, 5 by default, for the first and third? Recommended: yes.
3. **Should "Only the newest 5 listed" leave downloading to you, as today?** Recommended: yes. Downloading them too would be a fourth choice.
4. **Should played episodes count among the newest 5**, so that playing one never downloads an older one? Recommended: yes.
5. **Should the newest-5 rule leave alone a download you asked for, started, or put on your reading list?** Recommended: yes.
6. **Should no rule ever remove a download you transcribed or edited**, the after-playing rule included? Recommended: yes. Removing it would delete the transcript or the edits with it.
7. **Should subscribing, and the new build's first launch, download the newest 5 at once?** For "Finish It!" that is 315.8 MB. Recommended: yes, on a network without data limits.
8. **Should a feed stay in Unopened only while it has a new item**, rather than any unplayed one? Recommended: yes. With every item listed, a podcast's back catalogue would otherwise keep it there for good.
9. **Should Unopened leave out downloaded episodes**, which their feed's row already counts? Recommended: yes. Otherwise the rule adds up to 5 books per feed there.
10. **Should "10 of 381 episodes kept" become "10 of 381 episodes listed"**, since every record is now kept? Recommended: yes.

## 9. Build plan

### Branch A: `feature/feed-item-records` (engine: a removed download keeps its record)

- **What it changes:**
  - `FeedSavedBook`, a new type in Models, with `FeedItem.savedBook` read through `decodeIfPresent`. It is made from a library row and applied to a staged `Book`.
  - `deleteDownload`, the after-playing sweep, and a removal from the library (a hook before `LibraryViewModel.removeBooks` deletes a feed book) copy the state into the item, write and flush the record, and only then delete the package.
  - `FeedEpisodeImporter.importBook` takes the saved state and reuses its book ID.
  - `FeedDownloadManager.commit(_:for:)` clears `savedBook`.
  - `FeedReconciler.kept` keeps an item with a played date or a saved state in the record, listed as a downloaded item is today. This also ends today's loss of a played date when an item falls outside the window.
- **Tests:**
  - delete, then download again: the same ID, position, bookmarks, and settings;
  - the sweep, and the removal from the library;
  - a record that cannot be written keeps the package;
  - a record written before this change decodes;
  - the reconciler keeps saved and played items;
  - an article made again under the same ID reads a fresh text.
- **Size:** about 300 lines, with 400 lines of tests.
- **Useful alone:** it fixes today's loss on Delete Download before anything else lands.

### Branch B: `feature/feed-item-policy` (engine: the choice and the newest-N rule)

- **What it changes:**
  - `FeedItemPolicy` (`listing`, `downloading`, `count`), with `SettingsPolicy.feedNewestCount` (1 to 2,000, default 5), the stored preferences, and the config.json mirror (`SettingsViewModel.servicePreferenceKeys`).
  - The migration from `feedKeepEntries`, `feedAutoDownload`, and `keepEntriesOverride`, done once.
  - `Feed.itemPolicyOverride`, and `FeedItem.downloadOrigin`.
  - `FeedDownloadManager.Origin.window`, which is discretionary, and put-offs for disk space.
  - `FeedItemState.waiting(String)`, never written to disk, as downloading is not.
  - The rule's pass, run with the after-playing sweep (`requestSweep()`) at launch, after refreshes, downloads, and marks, and when the setting changes, with the ten-second wait before removals for a smaller number.
  - The reconciler's short list, which hides played items and keeps the hidden records.
  - The listing of the last body, in place of `keptEntriesOfLastBody`.
  - Mark All Played over every item the record holds.
- **Tests:**
  - the window: order, played items, and N growing and shrinking;
  - every protection;
  - waiting for a network without limits, and for disk space (`FeedEnvironment.freeSpace` is injectable);
  - quitting and resuming with the new origin;
  - the migration of preferences and of a feed's override;
  - the short list, and restoring it when it widens.
- **Size:** about 700 lines, with 900 lines of tests.

### Branch C: `feature/feed-item-policy-ui` (interface)

- **What it changes:**
  - The Feeds tab's pop-up menu and number, in place of "Keep the newest …" and the auto-download checkbox.
  - Feed Info's pop-up menu with "Use the global setting".
  - The new words in `FeedSettingsWording` and `FeedWording`.
  - Item rows that speak saved progress and bookmarks, the new hint, and the "Waiting to Download" note.
  - The new wording for Delete Download and for the Unsubscribe confirmation.
  - Delete Download asks first when the download holds a transcript, audio edits, or an edited text, naming what goes with it.
  - "listed" in `sizePhrase` (question 10).
  - Unopened's rule for feeds and for downloaded episodes (questions 8 and 9). These need a set of downloaded feed book IDs published by `FeedCenter`, so no row is looked up by a scan.
- **Tests:**
  - wording pinned by static constants;
  - hosted tests of the pop-up menu, the stepper, and the checkbox, all AppKit controls the tests can see;
  - Unopened's lists.
- **Size:** about 400 lines, with 450 lines of tests.
- **After it:** a documentation pass for README.md and ARCHITECTURE.md.

### FR10 and the download manager

- **What overlaps:** FR10's second half (spoken progress for feed downloads under way, after the ZIP half in `importprogress.md`) reads `FeedDownloadManager`'s queue. Branch B changes the same queue: it adds the rule's batches (5 at once on subscribing and at the first launch), `Origin.window`, and the waiting state.
- **Order:** FR10's feed half should start once branch B has merged, because both edit FeedDownloadManager.swift and `FeedItemState`'s notes. It then adds a published summary of the queue (done of total since the queue was last empty, and the current item and its percent) and its announcements. It does not touch the rule.
- **The ZIP half** of FR10 touches neither branch.

### Risks

- **Losing a state on removal:** prevented by writing and flushing the record before deleting the package, and keeping the package when the write fails.
- **Reusing a book ID:** the old row must be gone before the new one is added (`addFeedBook` already ignores a second row with an ID it lists). The reading list drops a book whose row leaves the library (`Library.removeBook(id:)`), so it no longer names the ID. A reading-checkpoint journal entry left under the old ID only makes the next launch compare the new record's position with the row's, and the two match.
- **Disk and uploads:** the default keeps 5 downloads per podcast feed, 315.8 MB for "Finish It!". In a cloud library every download uploads, as the user chose on October 4.
- **Large records:** a 2,000-entry feed is 11.6 MB, rewritten at each change, and costs 2.2 to 2.3 ms on the main actor for each percent of a download. That calls for the follow-ups below.
- **Two Macs sharing a cloud library** each run the rule. One Mac at a time stays the policy.
- **An older build** drops the new fields of a record it writes (section 6).
- **Existing feeds change at once:** under the new default, "The Digital Antiquarian" lists every entry the feed offers and downloads 4 more items, and "Finish It!" downloads 5. The migration is pinned by tests, and the TODO entry for the merge says what changes.

## Follow-ups noticed (not part of FR11)

- `FeedCenter.counts(of:)` finds each downloaded item's book by a linear scan (`bookByID`). Today that costs 1.1 to 1.2 ms per call, and the cost grows with downloads times rows. An index of rows by ID, or a set of feed book IDs, would bring it to about 0.2 ms. (Views/Feeds/FeedLibraryPresentation.swift, ViewModels/LibraryViewModel+BookOperations.swift)
- `FeedText` keeps each text three times. For "Finish It!", the plain text and Markdown copies are 1.0 MB of the record's 2.3 MB, rewritten whole at each change. (Models/FeedItem.swift)
- `FeedStore.update` compares the whole record twice for each whole percent of a download's progress, on the main actor: 0.4 to 0.6 ms at 381 items, 2.2 to 2.3 ms at 2,000. Comparing only the changed item would make it nearly free. (Services/Feeds/FeedStore.swift)
- Delete Download and the sweep's path for a book removed from the library write no log line, so the deletion of the user's October 7 download cannot be traced. (Services/Feeds/FeedLifecycle.swift)
- A played item without a download that falls outside the kept-entries window loses its played date (`FeedReconciler.kept`). Branch A fixes it.
- An automatic download put off by a network with data limits shows "Download Failed". Branch B's "Waiting to Download" says it plainly.

## What I could not verify

- **VoiceOver and braille** on the proposed rows, pop-up menu, and number: they exist only on paper.
- **Real cloud drives:** how they handle a 2.2 MB record rewritten at each change, or hundreds of small packages. No drive was touched.
- **Real decoding costs:** the mirrors leave out the lenient field readers of the real types.
- **The user's global feed settings:** config.json was not read, under this brief. The migration's outcome above assumes the defaults.
- **Which command deleted the October 7 download.**
- **The true size of "The Digital Antiquarian":** its record keeps 10 entries, and its size is recorded at its next check.
- **Precise timings:** every timing was taken under load (load average 10 to 13), so the figures are upper bounds.

## Addendum, October 7 evening: the user's answers

The user answered the ten questions on the evening of October 7 (`humanQuestions/2026-10-07-evening.md`, quoted in FR11 in TODO-2026-09-04.md): yes to 2, 3, 4, 7, 8, and 10, and changes to 1, 5, 6, and 9. `FEED-ITEMS-ADDENDUM-2026-10-07.md` measures the user's layout for question 1 (a package for each item, each feed's own index of its packages, and no feed item in library.json) and recommends it in place of option (c).

- **Replaced by the addendum:**
  - section 2's recommendation;
  - section 3, where the records show;
  - section 5, since a removed download's state stays in its package, not in `FeedItem.savedBook`;
  - the moving of the downloaded article in section 6;
  - section 9's build plan, now five branches.
- **Still standing:**
  - section 4's three choices and their number, except the rule's protections, which answer 5 changes: a download started and not finished may be removed, and a transcribed one needs no protection;
  - section 7's wording, with the addendum's new counts;
  - the follow-ups.
- **What comes next:** six new questions end the addendum.
