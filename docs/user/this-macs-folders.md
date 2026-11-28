# Folders of this Mac's own
<!-- id: folders-this-mac-own; keys: local folders, Application Support, Caches, not synced; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/CloudStorageContract.swift -->

Part of [TextMouth's documentation](../../README.md).

TextMouth also keeps folders of this Mac's own, which never sync and keep working while the data directory isn't available:

## Logs on this Mac
<!-- id: logs-this-mac; keys: Logs folder, Library Logs, log location; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/LogWriter.swift -->

~/Library/Logs/TextMouth: the diagnostic logs (see Logs in [The diagnostic logs](library-logs.md)), when Storage settings put them on this Mac, and while the data directory can't take them.
Logs that earlier builds wrote only here stay here.

## Application Support folder
<!-- id: application-support-folder; keys: Application Support, com.textmouth.TextMouth, local folders; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/CloudStorageContract.swift -->

~/Library/Application Support/com.textmouth.TextMouth:

### Working Copies
<!-- id: working-copies; keys: cloud audiobook, local copy, reader window; src: TextMouth/Services/ReaderWorkingCopy.swift -->

Working Copies: the copies that open audiobooks in a library in the cloud play from.
Each is deleted when its reader window closes, and any that a crash left behind are removed the next time a copy is made.

### Import Staging
<!-- id: import-staging; keys: import in progress, new book, same disk; src: TextMouth/Services/ImportStaging.swift, TextMouth/Services/ImportScratchSpace.swift -->

Import Staging: the packages imports are building, while the data directory is on the same disk as this folder: the startup disk, which also holds the folders of iCloud Drive and other cloud drives.
A data directory on another drive keeps them in its own library folders instead, so a new book is always put in place with one rename on one disk.

### Archive Extraction on this Mac
<!-- id: archive-extraction-this-mac; keys: ZIP import, unzip, same disk; src: TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/ImportScratchSpace.swift -->

Archive Extraction: the working folders of ZIP imports, under the same condition.

### Recordings
<!-- id: this-mac-recordings; keys: New Recording, Recovered recordings, Discard Recording, CAF, crash; src: TextMouth/Services/RecordingTake.swift -->

Recordings: the takes being recorded, and any not yet saved as a book, each a CAF file named for when it started, in the form "Take yyyy-MM-dd HH.mm.ss 1A2B3C4D.caf".
A take leaves once its book, with the original the original audio policy keeps, is in the library, or when Discard Recording deletes it.
A take cut off by a crash or a forced quit, or whose save failed after its window closed, stays here, still readable, and the New Recording window lists it under Recovered recordings until it is saved or discarded (see [Recording from a microphone](recording.md)).
A punch-in's take, recorded in the audio editor, leaves once its edit holds it, or when it is discarded.

### Feed Downloads
<!-- id: feed-downloads; keys: interrupted download, episodes, podcast download; src: TextMouth/Services/Feeds/FeedDownloadManager.swift -->

Feed Downloads: episodes downloaded and not yet imported, for a moment each.
Whatever an interrupted download left here is removed at the next launch.

### Kept Books.json
<!-- id: kept-books-json; keys: Keep on This Mac, Download Now, cloud, local choice; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/KeptBooks.swift -->

Kept Books.json: the books kept on this Mac (see Keep on This Mac, in [Keeping your library in the cloud](cloud-library.md)), a choice another Mac sharing the library never reads.

### Keep Reading List Books.json
<!-- id: keep-reading-list-books-json; keys: Reading List, Keep these books on this Mac, cloud, local choice; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/KeptBooks.swift -->

Keep Reading List Books.json, beside it: whether this Mac keeps the reading list's books downloaded (the checkbox "Keep these books on this Mac" in the Reading List's options), also this Mac's own choice, which another Mac never reads.

### Move Leftovers.json
<!-- id: move-leftovers-json; keys: migration staging, hidden folders, unfinished move; src: TextMouth/Services/MigrationStagingLeftovers.swift, TextMouth/Models/CloudStorageContract.swift -->

Move Leftovers.json: the hidden folders that moves of the library began and have not yet cleaned up (see Moving the library in [Where TextMouth keeps your library](where-your-library-lives.md)), which the next launch removes.
It is kept here because those folders are on the new location's drive, which may be away.
The file is there only while it lists a folder.

## Audio Edits cache
<!-- id: audio-edits-cache; keys: audio editor, filtered stretches, preview, silence; src: TextMouth/Services/AudioEditing/AudioEditComposition.swift, TextMouth/Services/AudioEditing/AudioEditCaches.swift -->

~/Library/Caches/com.textmouth.TextMouth/Audio Edits:

- one folder for each book being edited, with the filtered stretches and the silence its preview and saves read,
- removed when the edits are saved or the editing session ends, or, after TextMouth quit or crashed with an editor open, at its next launch.

macOS may empty it, and everything in it can be made again from the book's package: a filtered stretch macOS removed is made again when the editor next needs it.

## Audio Editor Clips cache
<!-- id: audio-editor-clips-cache; keys: Copy, Cut, Paste, clipboard, audio editor window; src: TextMouth/Services/AudioEditing/AudioEditCaches.swift -->

~/Library/Caches/com.textmouth.TextMouth/Audio Editor Clips: a folder for each open editor window, holding the audio Copy or Cut keeps for Paste, removed when the window closes, or, after TextMouth quit or crashed with the window open, at its next launch.

## Feeds cache
<!-- id: feeds-cache; keys: podcast refresh, Fetch State, Resume Data, Downloads at Quit; src: TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

~/Library/Caches/com.textmouth.TextMouth/Feeds:

- how this Mac last checked each feed (Fetch State), which lets a refresh skip a feed that hasn't changed,
- and the partial downloads a stopped download resumes from (Resume Data, kept a week),
- with the list of downloads under way or waiting when TextMouth last quit (Downloads at Quit.json), which the next launch asks for again and removes.

macOS may empty it.
The next refresh then reads each feed whole once.

## Search Text cache
<!-- id: search-text-cache; keys: Search Library, search index, Time Machine, Preparing books; src: TextMouth/Services/TextSearch/LibrarySearchEngine.swift, TextMouth/Services/TextSearch/LibrarySearchPreparer.swift, TextMouth/Models/CloudStorageContract.swift -->

~/Library/Caches/com.textmouth.TextMouth/Search Text: the text of each book, ready to search, one file for each book, so that Search Library (see [Search Library](search-library.md)) can search the whole library in a second or two.
It holds about as much as the library's text, 650 MB for 676 MB of text on the library it was measured on.
TextMouth makes it in the background after the first launch of each new installation, and again for a book whose text changes, and keeps it only while the disk keeps 1 GB free after it.
When it is gone, because macOS emptied Caches, the next launch makes it again, and a search made before then makes what it needs and says "Preparing 120 of 737 books…".
Searching never downloads a book that is only in the cloud.
A finished search and a finished pass remove the files of books that have left the library.
Time Machine leaves it out of backups.
The debug log has one LIBRARY_SEARCH_PREPARATION line for each background pass, with counts only.

## Reading Text cache
<!-- id: reading-text-cache; keys: large books, open quickly, ReadingTextCache, Time Machine; src: TextMouth/Services/ReadingTextCache.swift, TextMouth/Models/CloudStorageContract.swift -->

~/Library/Caches/com.textmouth.TextMouth/Reading Text: the reading text of the large books this Mac opened lately, those whose content.md is a megabyte or more, so that opening one again reads it from here instead of re-reading the book's Markdown.
The largest anthology reopens in about a tenth of a second instead of three quarters of one, and a 20 MB book in one chapter in about 50 ms instead of a second or more.
Nothing about speech is kept here, so changing substitution rules or speech settings never makes it wrong.
A book's file is removed a day after the book was last opened, at once when its text is extracted again or the book is deleted, and whenever its content.md or title changes or a new version of TextMouth is installed.
Time Machine leaves it out of backups, and macOS may empty it when the disk runs low; the next open simply reads the book again.

## Braille Tables cache
<!-- id: braille-tables-cache; keys: braille tables, liblouis, unpacked tables, Caches, Time Machine; src: TextMouth/Packs/BrailleTableUnpacker.swift, TextMouth/Models/CloudStorageContract.swift -->

~/Library/Caches/com.textmouth.TextMouth/BrailleTables: the braille tables TextMouth has used, one folder for each liblouis version, each table beside the files it includes.
TextMouth carries its tables inside the app, packed, and writes the ones it needs here the first time a braille book is read or written with them.
When a file is gone, because macOS emptied Caches, TextMouth writes it again when it is next needed, and a damaged file is written again.
When TextMouth has a newer liblouis, it removes the folders of the older versions.
Time Machine leaves it out of backups.

## memory-quit.json
<!-- id: memory-quit-json; keys: memory guard, quit to protect, runaway memory; src: TextMouth/Services/PlaybackMemoryGuard.swift -->

memory-quit.json: present only after TextMouth quit to protect your Mac; the next launch reads it, tells you, and removes it.
