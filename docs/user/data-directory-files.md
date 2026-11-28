# What the data directory holds
<!-- id: what-data-directory-holds; keys: files in the library folder, folder layout, library folder contents; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/CloudStorageContract.swift -->

Part of [TextMouth's documentation](../../README.md).

The data directory holds:

## library.json, the library index
<!-- id: library-json-library-index; keys: library index, book rows, bookmarks, folders, reading list, compact JSON; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Models/Library.swift -->

library.json: the library index.
It lists:

- every book of the library's own (title, author, format, folder, file path, reading position, bookmarks, and per-book settings),
- every folder,
- each location's sort (that of Feeds, and of a view of your own, under a key that begins with "/views/", as "/views/Feeds"),
- and the reading list, with its order and options, as compact JSON, without line breaks.

### Feeds are not in library.json
<!-- id: feeds-are-not-library-json; keys: feed episodes, articles, feed index; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/Feeds/FeedIndex.swift -->

It never holds a feed's downloaded episode or article, whose feed's own index lists it instead (see Feeds, below), and a row it holds is always a book of the library's own, whatever a hand edit of the file says.

### How reading positions reach the index
<!-- id: how-reading-positions-reach-index; keys: saving position, five minutes, autosave, reader closes; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift -->

While a book plays, its reading position reaches the index within five minutes, or sooner when anything else in the library changes, when the book's reader closes, or when TextMouth quits; meanwhile the book's record in its package holds it (see [bookInfo.json](book-packages.md)).

### The metadata reader and the Unknown author refresh
<!-- id: metadata-reader-unknown-author-refresh; keys: metadata refresh, author, title, edited by hand, metadata reader version; src: TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouth/Models/Book.swift -->

Each book's row also records which version of TextMouth's metadata reader last read its file for its title and author, and which of its details you edited by hand (see [The Library window](book-information.md), under [Finding your way around](../../README.md)).
The first launch after an update that reads a format's metadata better reads every older row's file again, in the background before the text caches, and takes the author the file names where the row still says Unknown; an author you typed stays, and a file that still names no one leaves Unknown.
It never replaces a field edited by hand.
For a book imported from its own file by Open Book, from Finder, in a ZIP of books, or with Import Folder…, whose record of hand edits begins at its import, it also brings up to date the title, author, publisher, and publication date the file names.
Every other book is one imported before its record of hand edits began, or made with New from Text, by a recording, from a feed's episode or article, or from a ZIP of audio tracks or a DAISY audio book's ZIP, whose names come from elsewhere than the file it reads.
For such a book it replaces nothing but that Unknown author, and only with a name, so a title or an author you typed stays.
It never reads an episode or article its feed lists, whose title and author come from the feed.
A book whose files are only in the cloud waits for a launch that finds them on this Mac.
library.json is read one row at a time.

### Rows this TextMouth cannot read
<!-- id: library-json-unreadable-rows; keys: unknown format, newer TextMouth, kept rows, unknown sort; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Models/Library.swift -->

A row this TextMouth cannot read, as a book that a later TextMouth added in a format this one does not know, is kept exactly as the file held it, written back at every save, and never shown, counted, opened, or searched.
Storage settings say how many there are (see [Settings](settings-storage.md)).
The package such a row names is left alone by the library's repairs:

- no sweep for packages that no row lists adopts it as a second book, repairs it, or deletes it,
- though Delete Folder… still removes the packages of kept books filed in the folder it deletes, and Delete Feed… those of a feed's kept books.

A sort that a later TextMouth saved by a field this one does not know reads as the default sort and is written back as it was until you choose another.
A feed's index is read the same way.
An index that is cut short or is not JSON at all, or whose folders, or whose list of books, are in a layout this TextMouth cannot read, is still unreadable as a whole (below).

## reading-checkpoints.json
<!-- id: reading-checkpoints-json; keys: checkpoint journal, crash recovery, reading position; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/TextMouthPaths.swift -->

reading-checkpoints.json: present only while some books' records hold reading positions that library.json doesn't have yet.
It names those books, so that a launch after a crash takes their newer positions from their records.

## library.json.unreadable- copies and Rebuild Library Index
<!-- id: library-json-unreadable-copies-rebuild; keys: Recovery Options, damaged index, corrupt library.json, quarantine; src: TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/Views/Library/LibraryIndexRecoveryViews.swift, TextMouth/Services/LibraryLoadResult.swift -->

library.json.unreadable- followed by a date and time: a preserved copy of an index that could not be read.
When library.json cannot be read, TextMouth never overwrites it, and the Library window's Recovery Options… offer Try Again and Rebuild Library Index, which rebuilds the index from the books on disk.
Rebuild Library Index keeps your reading list and the sort settings of your folders and views: those TextMouth held when the index became unreadable, or else those it can still read in the unreadable file itself, each on its own.
When neither gives one, as when the file was cut short, the Rebuild choice says so, and so does its result, as in "TextMouth could not read the reading list or the sort settings in the previous index.", as does Try Again when the unreadable file has gone and it saves the rebuilt library instead.
The preserved copy keeps them.

### Older TextMouths find the index unreadable
<!-- id: older-textmouths-find-index-unreadable; keys: older version, downgrade, compatibility, new format names; src: TextMouth/Models/Library.swift, TextMouth/Services/LibraryPersistenceService.swift -->

A TextMouth that does not know a format finds the index unreadable whenever it holds a book in that format: 0.1.1 does for all eight (braille, rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archives, and SSML).
The index names each book's format, and 0.1.1 does not know the names rtf, rtfd, doc, odt, wordml, webarchive, ssml, and braille.
It leaves library.json as it is, saves this copy beside it, and writes no index, but it still writes each book's package record, and those records lose the fields it does not know: the record of an edit of the book's text and of the page reader that wrote it.
A newer TextMouth then reads a book whose text you edited from its file again, keeping your edit beside it as content.md.edited- followed by a date and time (see content.md.edited- in [A book's package](book-packages.md)).
Nothing else is lost until someone chooses Rebuild Library Index there, which makes an index without the books in the formats it does not know, though their packages stay in the Library folder, and without the folders and the manual order that only the index held, which the preserved copy keeps.
Never choose it.
Open the library with a TextMouth built on or after the day its newest format was added instead.

### When Rebuild Library Index refuses
<!-- id: when-rebuild-library-index-refuses; keys: Last attempt, index readable again, recovery sheet; src: TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift, TextMouth/Views/Library/LibraryIndexRecoveryViews.swift -->

Rebuild Library Index refuses, and replaces nothing, when the index can be read again by the time you choose it, as when another Mac finished its save or you restored library.json from a backup: VoiceOver and the sheet's Last attempt row say "The library index was not rebuilt.
It can be read again now.
Choose Try Again to use it."

### Reading positions and folders after a failed read
<!-- id: reading-positions-folders-after-failed; keys: checkpoint journal, folder rows, launch repair; src: TextMouth/Services/LibraryPersistenceService.swift -->

A reading position saved while the index can't be read reaches the book's record, and is named in the checkpoint journal too, so the launch after you restore library.json takes it from the record instead of opening the book at the index's older place.
At launch TextMouth gives each folder a book lies in, and the folders above it, a row in the index when it has none, so a library opened without its index, or with a book in a folder that has no row, keeps those folders.

## library-identity.json
<!-- id: library-identity-json; keys: library identifier, identity, UUID, wrong drive; src: TextMouth/Services/LibraryIdentity.swift, TextMouth/Services/DataDirectoryAvailability.swift -->

library-identity.json: which library this is, an identifier and the date the library was given it.
It is written once, when TextMouth creates the library or first opens one an earlier version made, and never overwritten, so the library keeps its identity wherever its folder goes.
TextMouth remembers the identifier it expects, so a folder that only has the right name, such as another drive called Backup, is never taken for your library.

## Sync, this Mac's own sync files
<!-- id: sync-folder-data-directory; keys: Sync folder, library sync, outbox, device.json, registers.json, baseline.json; src: TextMouth/Services/Sync/SyncLocalFiles.swift, TextMouth/Services/TextMouthPaths.swift -->

Sync: present only once you have set up sync (see [Syncing your library between your devices](syncing-your-library.md)).
It holds a folder for the sync folder's store, with this device's own files: who it is in the store, its clock, what it has merged from each other device, the latest value of each synced setting, and an Outbox of changes not yet uploaded.
These stay on this Mac and are never in iCloud Drive; Stop Syncing leaves them where they are.
A copy of the library made while sync is on is told from the original, and takes a new identity of its own at its first sync.
[Library sync](../architecture/state/library-sync.md) says what each file holds.

## config.json, your settings
<!-- id: config-json-your-settings; keys: settings file, edit by hand, preferences; src: TextMouth/Services/ConfigService.swift -->

config.json: your settings, which you can edit by hand (see [Editing settings in config.json](config-json.md)).
From 0.5.0 on, TextMouth keeps a setting a later one added when it saves the file, and keeps a later one's keys in library.json, bookInfo.json, and reading_stats.json the same way.

## interface_text.json, your own interface lines
<!-- id: interface-text-json; keys: own lines, interface words, Edit Interface Text, Export Interface Text, base, plural forms; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Localization/InterfaceText/InterfaceTextOverridesFile.swift, TextMouth/Localization/InterfaceText/InterfaceTextOverridesWriter.swift, TextMouth/Services/InterfaceTextOverrides.swift -->

interface_text.json: the words of TextMouth's interface that you changed (see [Your own words for the interface](settings.md#your-own-words-for-the-interface)).
TextMouth never makes it by itself: Edit Interface Text… in Settings makes it, or you do.
It is a JSON file with a version of 1 and a "languages" object.
Each language, by its code (es, pt-BR, zh-Hant), holds "lines", and each line is keyed by the line's ID, such as common.sleepTimer.
A line holds, in this order:
- "text", or for a line with a count "plural", with a text for each form the language uses (one, many, other, and so on);
- "english", the English of the line, and "note", what the line is for, which are there for you to read and are never used;
- "base", or for plural forms "basePlural", the text TextMouth had when the file was written.

A line applies when its text differs from its base, or when it has no base, as when you write it by hand or copy it from someone else's export.
A line you leave alone never applies, so it keeps taking the better wording of each update.
If the English of a line you changed has changed since, the line still applies, and Settings lists it to check.

A line is ignored, and Settings says why, when:
- its language or ID is not one TextMouth has;
- it has no text, or both a text and plural forms, or a text where plural forms belong or the other way round;
- a text is empty or holds a control character other than a line break or a tab;
- its plural forms are not the ones the language uses;
- its placeholders do not match the English's: only %@, %lld, their numbered forms such as %1$@, and %% are allowed, in the English's number and kinds, and in any order when numbered;
- another key names the same language and has the same line.

A file that is not JSON or not this shape, with another version, larger than 64 MB, or that is a folder or another thing that is not a file, is ignored whole, and Settings says so.
A missing or empty file is no lines and no problem.
An export has the same shape, with no "base", and with "changed": true on each line of your own.
The file is in the data folder, so another Mac that shares the library in the cloud reads it too.

## substitutions.json
<!-- id: substitutions-json; keys: text substitutions, pronunciation rules, Text tab; src: TextMouth/Services/TextSubstitutionService.swift -->

substitutions.json: the text substitution rules from the Text tab of Settings.

## audio-filters.json
<!-- id: audio-filters-json; keys: filter presets, audio editor presets, premade presets; src: TextMouth/Services/AudioEditing/AudioFilterPresets.swift -->

audio-filters.json: the audio editor's filter presets.
Until one is changed, the premade presets stand in and nothing is written.
In a library in the cloud it is read and written as substitutions.json is (see [Keeping your library in the cloud](cloud-library.md)).

## transcript-cleanup.json
<!-- id: transcript-cleanup-json; keys: Edit Rules, cleanup rules, transcript rules; src: TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/Models/TranscriptCleanupRules.swift -->

transcript-cleanup.json: your own rules for Clean Up Transcript (Experimental)…, once Edit Rules… has made it from TextMouth's own (see [Transcribing an audiobook](transcribing.md)).
TextMouth writes it only then, never over a copy of yours.
It is read as substitutions.json is: one only in the cloud is asked for and waits there, and a copy of one that can't be used is kept beside it, its name followed by .unreadable- and a date and time; TextMouth's own rules stand in for either.

## reading_stats.json
<!-- id: reading-stats-json; keys: listening statistics, Books Finished, daily totals; src: TextMouth/Services/ReadingStatsService.swift -->

reading_stats.json: listening statistics, kept by day, and the books finished, each with its kind once TextMouth began to record kinds.

## Sessions, the Macs that have the library open
<!-- id: sessions-macs-that-have-library; keys: session lease, computer name, which Mac has the library open, heartbeat; src: TextMouth/Services/LibrarySessionLease.swift -->

Sessions: in a library on another drive or in a cloud folder, a small file for each Mac that has the library open, holding the computer's name, when TextMouth was last active there, and its version.
TextMouth writes this Mac's when the library opens, refreshes it every minute, and removes it at quit, and it removes any left untouched for 30 days (see [Keeping your library in the cloud](cloud-library.md)).

## Feeds, a feed's file and folder
<!-- id: feeds-feed-file-folder; keys: Feeds folder, podcast, subscription, episodes, articles; src: TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/Feeds/FeedItemPackage.swift -->

Feeds: one file for each feed in the library, subscribed to or not, Feeds/ followed by the feed's identifier and .json, holding

- the feed's address, title, folder, and own settings,
- the date you unsubscribed, while you are,
- and the episodes and articles it keeps, with whether each is downloaded, in the library (Move to Library…), played, or deleted.

It moves and syncs with the library.
A file that can't be read is kept beside itself, its name followed by .unreadable- and a date and time, and its feed is left out until the file can be read; a file only in the cloud is read once it has arrived, at the next refresh of every feed; and a sync service's conflict copy is never read.

### A feed's own folder
<!-- id: feed-own-folder; keys: downloaded episode, feed package, deleted download; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedIndex.swift -->

Beside its file, a feed that has downloaded anything has a folder of its own, Feeds/ followed by the feed's identifier alone, holding

- a package for each episode or article it downloaded, laid out as a book's package is (Library, in [A book's package](book-packages.md)),
- and the feed's own index of them, library.json, holding a row for each as the library's index holds a book's.

A package whose download was deleted stays there without its file, holding its record, its content index, its content.md (an episode's transcript text, or an article's text unless Delete Download removed it), its transcript, and any copies Edit Text kept of an edited text.
It stays while it keeps your place, bookmarks, settings, details you edited by hand, transcript, or such a copy, and its row stays in the index, so downloading the item again restores the same book.

### Hidden folders in a feed's folder
<!-- id: hidden-folders-feed-folder; keys: replaced package, removing folder, record absent, Delete Download; src: TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift -->

A feed's folder can also hold, hidden,

- .replaced- followed by a package's name, a package a new download replaced, set aside when the two packages couldn't be swapped in one step, as on a drive that can't swap two folders,
  - until the new one is in place, which the item's next download puts back or removes should TextMouth stop meanwhile;
- .removing- followed by the download's identifier and a name of its own, the folder an article's Delete Download moves its file and text into to remove them as one item, which,
  - should a crash cut the deletion short, the next launch sends to the Trash under the article's own name, or deletes, as Removal Behavior says;
- should a refused Delete Download leave its files there, the next launch puts them back into the package;
- and, in a library in the cloud, empty .record-absent- files named after a Mac and one of its launches, each noting that the launch found the feed's record missing.

### Saving a feed's index
<!-- id: saving-feed-index; keys: save order, feed index, small index; src: TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/Feeds/FeedIndex.swift -->

Each save of the library writes a feed's index before the library's, and only when it changed or its file is gone, so listening to an episode rewrites its feed's small index and no other; a save stops before the library's index when a feed's can't be written.
An index that can't be read is kept beside itself, its name followed by .unreadable- and a date and time, and its rows are read from its packages' records, as are those of a package its index doesn't list.
An index only in the cloud, as when it went back to the cloud after the launch waited for it, or one a newer version of TextMouth wrote, is neither read nor written over while TextMouth runs: its rows are read from its packages' records meanwhile.

### Unsubscribing, Delete Feed, and Move to Library
<!-- id: unsubscribing-delete-feed-move-library; keys: unsubscribe, remove feed, move episode to the library; src: TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/Services/Feeds/FeedStore.swift -->

Unsubscribing keeps this folder and its downloads, deleting only the packages kept for downloads you removed.
Delete Feed… deletes the feed's packages, then this folder, then the feed's file, so no launch finds the folder without the file while a package is in it.
Move to Library… moves an item's package out of it in one rename, and its row from this index into the library's.
A launch that finds this folder while the feed's record is gone returns its downloads to the library, then deletes the kept packages and, once nothing else is in it, the folder.

## Archive Extraction in the data directory
<!-- id: archive-extraction-data-directory; keys: ZIP import, unzip, working folder; src: TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/ImportScratchSpace.swift -->

Archive Extraction: the working folder of ZIP imports while the data directory is on another drive than this Mac's own folders; otherwise ZIPs are extracted in this Mac's Archive Extraction folder (see [Folders of this Mac's own](this-macs-folders.md)).
Each import removes its own folder when it ends.
At startup TextMouth removes any left over, here and in this Mac's folder, and, while this Mac's folder is the one in use, removes this one once it is empty.
