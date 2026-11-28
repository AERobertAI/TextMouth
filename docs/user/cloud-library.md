# Keeping your library in the cloud
<!-- id: keeping-your-library-cloud; keys: iCloud Drive, Dropbox, Google Drive, CloudStorage, dataless file, offline; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/BookCloudStorageService.swift -->

Part of [TextMouth's documentation](../../README.md).

A data directory in iCloud Drive, Dropbox, Google Drive (streaming), or another cloud drive that macOS keeps in ~/Library/CloudStorage works as any other, and lets the sync service keep books only in the cloud to free space on this Mac:
- macOS removes the downloads of files it can fetch again when it needs space,
- and you can remove a book's download yourself.

TextMouth recognizes such a folder from its path, tells each book's state from file-system metadata without downloading anything, and downloads a book when you open it.

To put your library there, choose a folder in the drive with Change Location… and then Move Library Here;
- on another Mac signed in to the same drive, choose that folder and Use This Library (see [Where TextMouth keeps your library](where-your-library-lives.md)).

research/CLOUD-STORAGE-RESEARCH-2026-10-03.md and research/CLOUD-STORAGE-PLAN-2026-10-03.md, in the same folder as this file, explain the design.

A library kept on this Mac and synced with an iPhone through a TextMouth Sync folder in iCloud Drive is a different thing: see [Syncing your library between your devices](syncing-your-library.md).

## How each cloud drive keeps a book
<!-- id: how-each-cloud-drive-keeps; keys: package sync flags, .tmb, per-file sync, BookCloudStorageService; src: TextMouth/Services/BookCloudStorageService.swift, TextMouth/Models/CloudStorageContract.swift -->

How each drive keeps a book: iCloud Drive syncs a book's package, its .tmb folder, as one item, while Google Drive and Dropbox sync each file in it.
TextMouth tells which from the package's own sync flags and acts on what the drive syncs.
On iCloud Drive it reads a book's state, and whether its changes have uploaded, from the package, and Download Now, opening a book, and Remove Download ask for the whole package, which comes to this Mac, or leaves it, all at once; on the other drives it does each of these file by file.

## The Library window
<!-- id: cloud-library-window; keys: Library window, cloud notes, downloads, refresh; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

In the Library window:

### A book's state in its row
<!-- id: book-state-row; keys: Downloaded, In Cloud, Downloading 40%, Download Failed, Waiting for Sync, row badge; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Views/Library/BookCloudNote.swift -->

Each book's row shows and speaks its state after the New or Now Reading badge: Downloaded, In Cloud, Downloading 40%, Download Failed, or Waiting for Sync, which means the book's package hasn't arrived on this Mac yet.
While a row speaks a download's percentage, it speaks the reading progress as "42 percent read", so the two never sound alike.
A book kept on this Mac (below) shows and speaks "Kept on this Mac" after its state.
A library on this Mac or on another drive looks and reads as before.

### The summary line
<!-- id: cloud-summary-line; keys: books in the cloud, kept on this Mac, status line; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

The summary line adds how many of the books shown are in the cloud, as in "3 books in the cloud": those not wholly on this Mac; and how many are kept on this Mac, as in "2 books kept on this Mac".

### When the states are read
<!-- id: when-states-are-read; keys: refresh interval, 2 seconds, every minute, BookCloudStates; src: TextMouth/ViewModels/LibraryViewModel+Cloud.swift, TextMouth/Models/CloudStorageContract.swift -->

The states are read again when a Library window opens, when TextMouth becomes the active app, after books are added, moved, or removed, and every minute while a Library window is open.
While any book downloads, even one Finder started, the downloading books are read every 2 seconds; a download that starts meanwhile shows when every book is next read, within a minute.

### Commands for a book in the cloud
<!-- id: commands-book-cloud; keys: Download Now, Remove Download, Show in Finder, Actions menu, Keep Downloaded, Offline Access; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

A book's context menu, and its actions in VoiceOver's Actions menu (VO-Command-Space), offer
- Download Now for a book in the cloud or one whose download failed,
- Remove Download for a downloaded book,
- Keep on This Mac, or Stop Keeping on This Mac for a book kept already (below),
- and Show in Finder, which selects the book's package.

Each cloud service also has its own command for keeping a book on this Mac, in Finder: Keep Downloaded for iCloud Drive, Offline Access for Google Drive, and Make available offline for Dropbox.

### Commands on several books
<!-- id: commands-several-books; keys: multiple selection, Download 3 Books, plural titles; src: TextMouth/Models/LibraryCloudWording.swift -->

With several books selected, these commands act on the selection and count the books they act on: "Download 3 Books", "Remove Downloads of 3 Books", "Keep 3 Books on This Mac", "Show 3 Books in Finder".

### Download Now
<!-- id: download-now; keys: download queue, one at a time, download summary; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

Download Now downloads the books one at a time, each showing Downloading 0% until its turn.
It announces when it starts, and gives one summary when every book has ended, naming any book that wasn't downloaded and why.

### Remove Download
<!-- id: remove-download; keys: evict, free space, refusal alert, unsaved changes; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

Remove Download frees the space a downloaded book takes on this Mac, leaving it in the cloud.
It deletes nothing from the cloud, so it doesn't ask first.
It refuses a book open in a reader, a book kept on this Mac, and one with changes not yet uploaded.
It also refuses when the sync service doesn't prove that the cloud holds the book's copy: no upload state, an upload error, two versions of a file, or a copy on this Mac that isn't said to be the latest.
Each refusal says what to do, since the only copy might be the one on this Mac; the first and the last say "Try again in a moment.", and a conflict says to settle it in the sync service first.
When the sync service reports no downloading status at all, waiting won't change that, so the refusal says so and ends, for Google Drive:
  "To free the space anyway, choose Show in Finder, then use Google Drive's Offline Access menu.
  That keeps the book's copy in the cloud."
For Dropbox it says "choose Make online-only", for iCloud Drive "choose Remove Download", and for another drive "use the drive's own command to keep the book only online".
TextMouth never deletes anything for you.
When it keeps any download, an alert says what was removed, what stayed, and why; VoiceOver reads the alert, and nothing repeats it.
When every download is removed, one announcement says so.

### Book Info and a book in the cloud
<!-- id: book-info-book-cloud; keys: Book Information, metadata, EPUB write refused, details appear; src: TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Models/CloudStorageContract.swift -->

Book Info never waits for a download.
For a book only in the cloud, it shows the details the library keeps, with "Some details appear once the book is downloaded.", and refuses to write changes into the book's EPUB file until the book is downloaded.

## Keep on This Mac
<!-- id: keep-this-mac; keys: Keep Downloaded, pin, offline, KeptBooks; src: TextMouth/Services/KeptBooks.swift, TextMouth/Models/LibraryCloudWording.swift -->

Keep on This Mac:

### Keep and Stop Keeping
<!-- id: keep-stop-keeping; keys: Stop Keeping, Library menu, No books are selected; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

A book's context menu, and its VoiceOver actions, offer Keep on This Mac, or Stop Keeping on This Mac for a book kept already, for any book in a library in the cloud, even one whose package hasn't arrived yet.
With several books selected, each counts the books it acts on, as in "Keep 3 Books on This Mac".
The Library menu has both commands too, for the books selected in the Library window in front; when nothing would change, VoiceOver says why, as in "No books are selected."
While library sync is on, a synced library offers Keep on All Devices and Stop Keeping on All Devices in their place (see [Syncing your library between your devices](syncing-your-library.md)).

### What a kept book does
<!-- id: what-kept-book-does; keys: download at once, retry delay, five minutes, keptBookRetryDelay; src: TextMouth/ViewModels/LibraryViewModel+Cloud.swift, TextMouth/Services/KeptBooks.swift -->

A kept book stays downloaded.
One only in the cloud, or whose download failed, downloads at once, as Download Now downloads it, and VoiceOver hears "Keeping Moby-Dick on this Mac.
Downloading it now", then the summary when the downloads end.
One whose download the sync service removes, while TextMouth runs or before it started, downloads again, without an announcement, when the books' states are next read, and one whose download failed then waits five minutes before it is tried again.

### Remove Download and a kept book
<!-- id: remove-download-kept-book; keys: refusal, Stop Keeping first; src: TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

Remove Download refuses a kept book: "The book is kept on this Mac, so its download can't be removed.
Choose Stop Keeping on This Mac first."
Stop Keeping on This Mac removes nothing: the download stays until the sync service or Remove Download removes it.

### Keeping is this Mac's own choice
<!-- id: keeping-this-mac-own-choice; keys: Kept Books.json, machine-local, MachineLocalPaths; src: TextMouth/Services/KeptBooks.swift, TextMouth/Models/CloudStorageContract.swift -->

Keeping is this Mac's own choice, as Finder's Keep Downloaded is: another Mac that opens the same library keeps only the books chosen there.
The choice is saved in this Mac's own Kept Books.json (see [Where TextMouth keeps your library](this-macs-folders.md)), never in the library.

### The reading list's books
<!-- id: reading-list-books; keys: Keep these books on this Mac, free space check, DOWNLOAD_SKIPPED_NO_ROOM, 1 GB reserve, options bar; src: TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/Models/ReadingListWording.swift, TextMouth/Services/KeptBooks.swift -->

The reading list's books are kept too, in a library in the cloud, while the checkbox "Keep these books on this Mac" in the Reading List's options bar is checked, which it is until you clear it.
The checkbox is not there for a library on this Mac or another drive.
A book on the list shows and speaks "Kept on this Mac" like any kept book, downloads at once when it is only in the cloud, downloads again when the sync service removes it, and counts in the summary.
When you add a book with Add to Reading List, VoiceOver hears the add, then, after it has finished, "Downloading Moby-Dick, a reading list book" (or "Downloading 3 books"), and the summary as Download Now says it.
Books that arrive on the list from another Mac's sync, a first start after an update, and checking the checkbox download with one notice, once, such as "Downloading 7 reading list books".
TextMouth first checks that the books fit in the free space on this Mac, less the 1 GB it always leaves free, and starts only those that do; if some don't, the notice says so, as in "Downloading 4 reading list books.
There isn't enough free space for 3 more books", and they download at a later refresh once there is room.
A book whose size TextMouth cannot learn, such as an iCloud Drive book that syncs as one item and is only in the cloud, takes no room in that check, so books of unknown size download one at a time:
- TextMouth starts the first,
- and when it has downloaded, reads the free space again and plans the books after it.

A book you took off the list, or stopped keeping, while it waited is left out.

If a later pass finds that the room has gone, it says once, as in "There isn't enough free space to download 3 reading list books", counting only the books it leaves out.

One huge book of unknown size can still fill the disk once it has started, since nothing can weigh it before it downloads.

A book left out for room, a book you kept yourself included, is written once to the debug log as DOWNLOAD_SKIPPED_NO_ROOM; VoiceOver hears only of the reading list's books, so a book you kept yourself waits for a later refresh with no notice, and the log alone tells of it.

### Remove Download and the reading list
<!-- id: remove-download-reading-list; keys: refusal, Kept on this Mac for the reading list, both reasons; src: TextMouth/Models/ReadingListWording.swift, TextMouth/Models/LibraryCloudWording.swift, TextMouth/Services/KeptBooks.swift -->

Remove Download refuses a book kept only for the reading list: "The book is on the reading list, which this Mac keeps downloaded, so its download can't be removed.
Take it off the reading list, or clear Keep these books on this Mac in the Reading List's options first."
A book you kept yourself that is on the list too is refused with both reasons named, and the advice in order.
Stop Keeping on This Mac is offered only for a book you kept yourself; it says the reading list still keeps the book when it does, and, from the Library menu on a book only the list keeps, VoiceOver says the book is kept for the reading list and how to let it go.
A book you kept stays kept after it leaves the list.
Book Information says "Kept on this Mac for the reading list" for a book the list alone keeps.

### A book that leaves the list
<!-- id: book-that-leaves-list; keys: Keep Reading List Books.json, Remove books when finished, keeps nothing; src: TextMouth/Services/KeptBooks.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift -->

A book that leaves the list (taken off it, finished with Remove books when finished checked, or removed from the library) stops being kept for it, and nothing is removed from this Mac: its download stays until the sync service or Remove Download removes it.
Clearing the checkbox keeps none of the list's books for the list and removes nothing.
The choice is this Mac's own, saved in its Keep Reading List Books.json beside Kept Books.json, never in the library or the list, so another Mac that opens the library decides for itself.

## Opening a book from the cloud
<!-- id: opening-book-from-cloud; keys: download on open, reader window, progress bar, Downloading; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift -->

Opening a book:

### A book with files in the cloud
<!-- id: book-files-cloud; keys: 2 of 3 files, progress percentage, sync service name; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift -->

A downloaded book opens at once.
A book with files only in the cloud downloads first, in its reader window: "Downloading" and the book's title, the sync service's name, and a progress bar that VoiceOver moves to and reads as "2 of 3 files, 40 percent".
While a single file is left and nothing has been counted yet, the bar gives that file's size and the time waited instead.
Where the sync service reports how much of a file, or of a package iCloud Drive downloads whole, has arrived, the percentage counts that part too, never going back, so a book of one large file shows how far it has got.

### What VoiceOver hears during a download
<!-- id: what-voiceover-hears-during-download; keys: 25 50 75 percent, announcements, Downloaded. Loading.; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift -->

VoiceOver hears the download start, then 25, 50, and 75 percent (or, while there is no percentage, the time waited, every 30 seconds), then "Downloaded.
Loading."

### Cancel a download
<!-- id: cancel-download; keys: Escape, Download button, Close; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift -->

Cancel, which Escape also presses, stops waiting, and the window then says the book isn't downloaded, with two buttons: Download, which Return presses, and Close.

### When a download fails
<!-- id: when-download-fails; keys: Try Again, offline, paused, signed out, 60 seconds; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

A failure shows the reason with Try Again, which Return presses, and Close.
Offline, the download fails at once: "This Mac is offline, so the book can't be downloaded from Dropbox.
Connect to the internet and try again."
A sync service that downloads nothing for 60 seconds is reported as perhaps paused, signed out, or not running.
A book whose package hasn't arrived on this Mac yet says so.

### After the download
<!-- id: after-download; keys: read offline, part of the book isn't on this Mac; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

The book is then read without ever waiting on the network.
A file that went back to the cloud meanwhile is downloaded once more; if it has gone again, the reader says that part of the book isn't on this Mac.

### A book that another book continues to
<!-- id: book-that-another-book-continues; keys: Next in Folder, Reading List hand-over, autoplay, library moving; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift -->

A book that another book continues to, from its folder or through the reading list, starts playing once it has downloaded and loaded, however long the download takes.
If the download fails or you cancel it, the book doesn't start by itself later, and once you close its window, it starts by itself only if it opens again within about 30 seconds of the hand-over.
While the library is moving or isn't available, opening such a book, or a book from the Reading List, is refused as before, and nothing of the refused open is left waiting: when the book is opened later, it is neither started nor read from the reading list.

## Playing an audiobook from the cloud
<!-- id: playing-audiobook-from-cloud; keys: working copy, offline playback, Working Copies; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

Playing an audiobook:

### Playing from a working copy
<!-- id: playing-from-working-copy; keys: Working Copies folder, clone, same disk; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Models/CloudStorageContract.swift -->

An open audiobook plays from a working copy: a copy of its package in this Mac's Working Copies folder, which on the same disk takes almost no extra space.
So it keeps playing offline, or after the sync service removes the book's download.
The copy is deleted when the reader window closes, and positions and bookmarks still save to the library.

### When no copy can be made
<!-- id: when-no-copy-can-be; keys: Chapter Not Downloaded, Play/Pause, sleep timer, Try Again; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Models/CloudStorageContract.swift -->

When no copy can be made, a chapter whose file is only in the cloud downloads before it plays, in the same view, while the reader shows Playing.
Pausing, with Play/Pause or when the sleep timer runs out, stops waiting, so the chapter doesn't start by itself later; it downloads again when you next play it, if it still has to.
A second Play while the audiobook waits for its chapter's download does nothing, with no second play sound.
A failure stops at that chapter with a Chapter Not Downloaded alert offering Try Again.

### A text book
<!-- id: text-book; keys: memory, no working copy; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

A text book is read into memory when it opens, so it needs no copy.

## Background maintenance
<!-- id: background-maintenance; keys: startup repair, metadata refresh, text cache, MAINTENANCE_SKIPPED_IN_CLOUD, Storage settings; src: TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Models/CloudStorageContract.swift -->

Background maintenance never downloads a book.
The startup repair, the metadata refresh, the text cache and statistics passes, and Redo Text Extraction
- leave a book whose files are in the cloud as it is,
- decide nothing from what only the cloud knows,
- and catch the book up once its files are on this Mac.

Opening a book also rebuilds its text cache when that is out of date.

Each pass that skipped books writes one MAINTENANCE_SKIPPED_IN_CLOUD line in the debug log, saying how many, and Redo Text Extraction says so in Storage settings too, as in "Done.

12 books in the cloud were skipped."

## Logs in the cloud
<!-- id: logs-cloud; keys: debug log, Logs folder, 2 MB, In this Mac's Logs folder; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Models/CloudStorageContract.swift -->

Logs: they live in the library's Logs folder and sync with it, each kept to 2 MB with one older generation, so the uploads stay small, and TextMouth never downloads a log to write to it.
To keep them off the cloud, choose In this Mac's Logs folder in Storage settings (see [Where TextMouth keeps your library](library-logs.md)).

## Using several Macs
<!-- id: using-several-macs; keys: two Macs, Sessions folder, TextMouth Is Open on Another Mac, lease; src: TextMouth/Services/LibrarySessionLease.swift -->

Several Macs:

### One Mac at a time
<!-- id: one-mac-at-time; keys: Continue, Quit TextMouth, three minutes, session file; src: TextMouth/Services/LibrarySessionLease.swift -->

Use a library on one Mac at a time.
While a library on another drive or in a cloud folder is open, TextMouth keeps a file for this Mac in its Sessions folder.
When another Mac's file was refreshed in the last three minutes, TextMouth warns, once a session: "TextMouth is also open on “Study iMac” (active 2 minutes ago).
Using one library on two Macs at the same time can lose reading positions and changes."
Continue, which Return presses, keeps the library open here, and Quit TextMouth quits.
It is only a warning: nothing is locked.
A sync service's conflict copy of this Mac's own file never counts as another Mac.
The file is written and read away from the main thread, so a Sessions folder that hasn't synced yet never stalls TextMouth; at quit, removing the file is given up to two seconds.

### A Mac that is behind
<!-- id: mac-that-is-behind; keys: reading position, later place, two Macs, bookmarks, close window; src: TextMouth/Models/Book+ReadingState.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

When you open a book on a Mac that the cloud has not caught up with, and the book's own record already holds a later place saved on another Mac, TextMouth opens it at the later place.
The bookmarks, the headings you skip, and the book's own voice and speed settings come with that place, as the other Mac left them, and are not mixed with this Mac's.
Going back to reread is a later place too.
A bookmark or setting changed on the Mac whose place is the earlier, without moving in the book, gives way to the other Mac's.
Opening, closing, or quitting without moving never makes an older place the later one: closing a second window of a book you have not moved in puts nothing back.

### Settings travel with the library
<!-- id: settings-travel-library; keys: dataDirectoryPath, config.json, ignored path; src: TextMouth/Services/ConfigService.swift -->

config.json travels with the library, so a dataDirectoryPath that another Mac wrote is ignored when it names a folder this Mac doesn't have (see [Editing settings in config.json](config-json.md)).

### Update TextMouth on every Mac
<!-- id: update-textmouth-every-mac; keys: 0.1.1, Rebuild Library Index, library.json.unreadable, KFX, older version; src: TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Update TextMouth on every Mac that opens the library.
A TextMouth older than 0.2.0, such as 0.1.1, can't open a library that holds a book in a format 0.2.0 added: rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, web archive, SSML, or braille (BRF, BRL, or PEF).
It finds the index unreadable and leaves it as it is, writing no index, but it still writes each book's record, which loses 0.2.0's records of edits and pages.
It offers Rebuild Library Index; never choose it there (see library.json.unreadable-, under [Where TextMouth keeps your library](data-directory-files.md)).
A TextMouth from 0.2.1 to 0.3.2 opens a library that holds a KFX book, a format added in 0.4.0, without that book (see the [changelog](changelog.md)).

### Conflict copies
<!-- id: conflict-copies; keys: library 2.json, library (1).json, duplicate files, merge; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/Feeds/FeedStore.swift -->

TextMouth leaves alone the conflict copies a sync service makes of library.json, library-identity.json, config.json, reading_stats.json, substitutions.json, a feed's record and its index of episodes, and a book's package and record, such as "library 2.json" or "library (1).json":
- it never reads one in place of the file it copies,
- nor adopts a copied package as a second book,
- and leaves each where it is.

It doesn't merge what two Macs wrote.
In a library in the cloud it does tell you, once for each copy, when a library is opened: an alert titled "Conflicting Copies Found" says which sync service set aside a copy of what, where it is, and what it holds beside what the original holds, and ends "TextMouth hasn't merged it or removed it."
For example, for a feed's index: "It holds 0 episodes; the index holds 1 episode."
The alert lists five copies at most, the rest go to the log; OK is the default, and Show in Finder shows the first copy's folder.
It recognizes iCloud Drive's " 2" names, Google Drive's " (1)", and Dropbox's "(NAME's conflicted copy DATE)" and "(Case Conflict)" names, and iCloud's unresolved versions of a file.
A copy not yet on this Mac is not downloaded to look inside it, and the alert says so.
A copy is reported again only if it changes or you haven't yet seen the report; this Mac remembers what it reported.

### Statistics and substitutions only in the cloud
<!-- id: statistics-substitutions-only-cloud; keys: reading_stats.json, substitutions.json, Retry, standard rules; src: TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/TextSubstitutionService.swift -->

While reading_stats.json or substitutions.json is only in the cloud, TextMouth neither waits for it nor saves over it, and asks the sync service for it.
Meanwhile the statistics count only this session's listening, which is added to the file's totals once the file is on this Mac.
The standard substitution rules stand in, and a change to them is reported as unsaved, with Retry; the file is read again whenever TextMouth becomes the active app and before each save, and once it is on this Mac its rules take the place of the standard ones, and that change is dropped.
Where there is no substitutions.json at all, as on a Mac's first launch before the sync service has brought it down, the standard rules stand in without being written: the file is written only when a rule changes, so one that arrives later is adopted without a conflict copy.

### Small files fetched when the library opens
<!-- id: small-files-fetched-when-library; keys: config.json, feed records, background fetch, new value kept; src: TextMouth/Services/ConfigService.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

When a library in the cloud opens, TextMouth gets its other few small files in the background if they're only in the cloud: config.json, reading_stats.json, substitutions.json, interface_text.json, and the feeds' records.
Never a book or an episode, and the library doesn't wait for them.
Until config.json arrives, the settings already on this Mac stand, nothing is saved over it, and a setting you change meanwhile keeps your new value when it arrives.

### A library file that hasn't arrived
<!-- id: library-file-not-arrived; keys: library.json, library-identity.json, Library Not Available, Open Without the Index, Restore Its Identity, Give It a New Identity; src: TextMouth/Models/LibraryFileWaitWording.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift -->

A sync service can bring a library's small files down one at a time.
When the folder holds the library's index, library.json, but not its identity file, library-identity.json, or the reverse, TextMouth waits for the missing one, about a minute, and never opens the library as a new one on its own.
If it doesn't come, the Library Not Available screen says which file is here and which hasn't arrived from your sync service, and that TextMouth waited for it.
For a missing identity file on a library in Google Drive it begins:
  "The library's index is on this Mac, but its identity file, library-identity.json, hasn't arrived from Google Drive.
  TextMouth waited for it."
It then says what to check and names the way out; the service named is your sync service.
The choice is yours, and each button asks first in an alert, with Cancel leaving everything as it is:
- Open Without the Index…, when library.json is missing, makes a new index from the books in the folder, with the button Make a New Index.
  The reading list, the folders' sorts and listening options, and any book whose files aren't there yet won't be in it.
  If library.json arrives later, the sync service may keep two copies of it.
- Restore Its Identity…, when this Mac knows the library's identity, writes library-identity.json with it, and the library opens as the same library, with the button Restore and Open.
- Give It a New Identity…, when this Mac knows none, gives the library a new identity, with the button Give a New Identity.
  If the library's own file arrives later, the sync service may keep two copies, and this Mac and the other would disagree about which library it is.

Choose Try Again instead if the sync service may still be working.
A library from before identities in a cloud folder waits about a minute once.
A new library saves its empty index with its identity at its first launch, so that its next launch doesn't wait.
A statistics or settings file that hasn't arrived is never written over: this session's listening and the settings on this Mac are kept until it comes.

### A file that can't be read
<!-- id: file-that-cant-be-read; keys: unreadable copy, truncated write, .unreadable-; src: TextMouth/Services/SavedFile.swift, TextMouth/Services/LibraryIndexQuarantine.swift -->

Either file, when it can't be read, as a write cut short on another Mac can leave it, is kept beside itself before anything replaces it, its name followed by .unreadable- and the date and time, as an unreadable library.json is; the statistics then start afresh, and the standard rules stand in.

## Feeds in the cloud
<!-- id: feeds-cloud; keys: podcasts, episode downloads, Resubscribe, unsubscribed feed, feed index; src: TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/Feeds/FeedPaths+Items.swift -->

Feeds: their records, and their folders of downloads with their indexes, sync with the library, and each Mac refreshes them on its own.
A played episode's download is deleted, and a download beyond a feed's newest is removed under its List and download choice, only by a Mac that holds the whole book, as its cloud state says.
Opening the library waits for every feed's index, as it waits for library.json (see When the library isn't available, under [Where TextMouth keeps your library](where-your-library-lives.md)),
- and a Mac marks an item downloaded again, after an older version of TextMouth marked it otherwise, only when its file is on that Mac.

A feed whose record is missing when TextMouth opens, as one an earlier version unsubscribed from on another Mac, keeps its downloads in its folder until a later launch of this Mac finds the record missing again;
- only this Mac's own launches count (see Commands, under [Podcasts and article feeds](feed-commands.md)).

Unsubscribing and Resubscribe live in the feed's record, which another Mac reads as it next opens the library.

## What was tested
<!-- id: what-was-tested; keys: real cloud drives, manual tests, opt-in tests; src: docs/developer/testing.md -->

What was tested:
- the opt-in tests in [Testing on real cloud drives](../developer/testing.md#testing-on-real-cloud-drives), passed against Dropbox, Google Drive, and iCloud Drive,
- and research/CLOUD-STORAGE-MANUAL-TESTS-2026-10-03.md lists the checks, with VoiceOver steps, still to be made by hand on each drive.
