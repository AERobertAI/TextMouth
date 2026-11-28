# Where TextMouth keeps your library
<!-- id: where-textmouth-keeps-your-library; keys: storage directory, library folder, preferences, bookmark, .TextMouth, data directory location; src: TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

Part of [TextMouth's documentation](../../README.md).

TextMouth keeps everything in one data directory: .TextMouth in your home folder unless you chose another folder in Storage settings.
Any folder can hold it, hidden or not: on this Mac, on an external or network drive, or in a cloud folder such as iCloud Drive, Dropbox, or Google Drive (see [Keeping your library in the cloud](cloud-library.md)).
That choice itself is kept in TextMouth's preferences, with a bookmark of the folder and the identity of the library in it, because config.json lives inside the directory it names.

## What the library's folders hold
<!-- id: library-folders-other-pages; keys: data directory contents, library files, logs, caches, helper programs, book package; src: TextMouth/Services/TextMouthPaths.swift -->

This page covers choosing the location, moving the library, and a library that is not available.
The rest is on these pages.

- [What the data directory holds](data-directory-files.md): library.json, settings files, feeds, and sessions.
- [A book's package](book-packages.md): the files inside each book's folder.
- [The diagnostic logs](library-logs.md): the log files and where they go.
- [Folders of this Mac's own](this-macs-folders.md): working copies, staging, recordings, and caches.
- [Helper programs TextMouth watches](helper-programs.md): the converters, textutil, and the braille helper.

## Choosing a location
<!-- id: choosing-location; keys: Storage tab, Settings, storage location, move the library; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Services/StorageDestinationAssessment.swift -->

### Change Location
<!-- id: change-location; keys: folder chooser, open panel, Choose Location button, hidden folders; src: TextMouth/Views/Settings/StorageSettingsView.swift -->

Change Location… in Storage settings opens a folder chooser that shows hidden folders and can make a new folder; its button says Choose Location.
The folder you choose becomes the data directory itself, with nothing added to its name.

### What TextMouth offers for a folder
<!-- id: what-textmouth-offers-folder; keys: folder check, destination assessment, status line, Checking; src: TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

TextMouth first looks at the folder, reading only what the file system says about it and downloading nothing, while the status line says "Checking" and the folder's path.
Then it offers what the folder can hold, and VoiceOver announces each status line as it appears:

#### Move Library Here
<!-- id: move-library-here; keys: migrate library, empty folder, copy the library, recovery data; src: TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Services/DataDirectoryMigrator.swift -->

Move Library Here, for an empty folder, such as one just made in the chooser.
The confirmation says that the library is copied there, checked, and used, with the current folder kept as recovery data, and what the place means:

- in a cloud folder, that the library, with its size, uploads in the background, and that a book only in the cloud needs an internet connection to open;
- on another drive, that the drive must be connected to open the library.

#### Use This Library
<!-- id: user-use-this-library-folder; keys: switch library, restore from the cloud, second Mac, quit and reopen; src: TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/StorageGeneration.swift -->

Use This Library, for a folder that holds a TextMouth library: its library-identity.json, or a library.json beside a Library folder.
TextMouth switches to that library as it is, copying nothing, then quits and opens again on it.
This is how another Mac restores a library from the cloud.
The confirmation names both libraries, and says when the folder holds another copy of the library in use, such as the folder an earlier move left behind, which of the two copies is newer.
First TextMouth compares the two, for up to a minute.
Storage settings says:
  "Comparing this library with the copy in the folder you chose, to say which is newer.
  This can take up to a minute; choose Stop Comparing to skip it."
The confirmation then says, for example, that the copy in this folder is the newer, with newer places in so many books and so many books the other lacks, or that neither is newer, or that TextMouth couldn't tell (and why, such as that you stopped the comparison).
It points to Compare Libraries for every difference.
Changes not yet saved are written first, and the switch is refused while some still can't be saved: choose Retry Saving, then try again.
It is refused too while a move, Rebuild Directory, or a change that moves books between folders is under way, saying which, and while it runs those are refused in turn: "TextMouth is switching to another library and opening again on it."

#### Compare Libraries
<!-- id: compare-libraries; keys: another copy, which copy is newer, differences, Stop, Copy Results, read-only; src: TextMouth/Models/LibraryComparison.swift, TextMouth/Models/LibraryComparisonWording.swift, TextMouth/Services/LibraryCopyReader.swift, TextMouth/Views/Settings/CompareLibrariesSheet.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

Compare Libraries… is a button in Storage settings beside Change Location.
It asks for the folder that holds another copy of this library, with the prompt "Compare", and lists what differs.
It changes nothing in either copy, and asks the sync service for nothing to be downloaded beyond reading the files it needs.
The sheet, "Compare Libraries, results", reads the count first: "7 differences between this library and the copy in FOLDER."
Each difference is one sentence, such as:
- "Position in TITLE: newer in this copy, chapter 3, 41%.
  The other copy has chapter 2, 20%."
- "Bookmark 2 in TITLE: only in the other copy, chapter 2, with the note “NOTE”."
It lists books only in one copy, a book filed in different folders, positions, bookmarks, the reading list's books, order and options, and folders.
A file it couldn't read is listed apart, under "Files not read", and is never counted as missing; the count says so, since the comparison may then be missing differences.
In a cloud folder, files that are only in the cloud are brought to this Mac to be read, each waited for up to 30 seconds and the whole comparison up to 5 minutes.
While it works it says so, and every 30 seconds it says:
  "Still comparing: N seconds so far.
  Press Escape to stop."
Stop, or Escape, ends it, and it says:
  "Comparing stopped.
  Nothing was changed."
Copy Results puts the count and every difference on the clipboard, one to a line, and says "Results copied to the clipboard."
A folder that holds a different library compares nothing.

#### The folder the library is in already
<!-- id: folder-library-already; keys: same folder, current library, in use; src: TextMouth/Services/StorageDestinationAssessment.swift -->

For the folder the library is in already, the status line says it is the library TextMouth is using.

#### Folders TextMouth refuses
<!-- id: folders-textmouth-refuses; keys: refused folder, folder in the Trash, cloud folder not downloaded, not enough room; src: TextMouth/Services/StorageDestinationAssessment.swift -->

Anything else is refused, with the reason:

- a file rather than a folder,
- a folder holding other items, which it names,
- a folder inside the library,
- a folder in the Trash,
- one TextMouth can't read or isn't allowed to change,
- a cloud folder that isn't on this Mac yet,
- a missing folder whose enclosing folder is missing too,
- or another drive without room for the library.

### Reset to Default
<!-- id: reset-default; keys: default location, home folder, back to ~/.TextMouth; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Reset to Default moves a library in another folder back to ~/.TextMouth, the same way.

## Moving the library
<!-- id: moving-library; keys: data directory move, migration, relocate the library; src: TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/DataDirectoryMoveProgress.swift -->

### When a move is refused
<!-- id: when-move-refused; keys: migration refused, open books, books not downloaded, Rebuild Directory; src: TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Services/StorageGeneration.swift -->

A move is refused while any book is open, naming the open books, and while books in a library in the cloud aren't downloaded: "3 books aren't downloaded.
Download them first: select them in the library, then choose Download Now."
It is refused too while another move, Rebuild Directory, or a change that moves books between folders is under way, saying which, as in "TextMouth is rebuilding its data directory.
Try again when that finishes."
A move from a current data directory that is not there, or is a file, says "The current data directory does not exist."

### A book stored outside the data directory
<!-- id: book-stored-outside-data-directory; keys: external file, linked book, copy is missing content; src: TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

A book stored outside the data directory stops the move before anything is copied or published (0.4.3).
The move cannot carry a file that is not in the data directory.
The alert names the book and where it is, as in "The book Harbour Pilots is stored at /Volumes/Shelf/pilots.mp3, outside the data directory, so the move cannot carry it.
Import it again, which asks about the duplicate, and choose Replace Existing so that the copy stored in the data directory takes its place, or remove it from the library, then move the data directory again."
The title and path are the book's own.

Replace Existing puts the new copy, which is stored in the data directory, in place of the existing one, under the same ID, keeping its reading position, bookmarks, and settings (see [Adding books](duplicate-books.md)).
Keep Both would leave the book outside the data directory, and the move would stop again.

### What a move waits for
<!-- id: what-move-waits; keys: waits, imports, text extraction, feed rules; src: TextMouth/Services/StorageGeneration.swift, TextMouth/ViewModels/DataDirectoryMoveProgress.swift -->

An import, text extraction, or book analysis under way finishes first, and the move's progress says which it waits for; any that start meanwhile wait until the move is over.
A move also waits for the feed rules' deletion of downloads under way, saying "Waiting for feed downloads to be deleted...", and a rule's deletion waits while a move copies the library.

### How the copy is made
<!-- id: how-copy-made; keys: staging copy, symbolic link, rename into place, empty destination; src: TextMouth/Services/DataDirectoryMigrator.swift -->

Moving copies everything into a hidden folder beside the new location, a book at a time, checks the copy, then renames it into place in one step and switches to it.
The new location must be an empty folder or one that does not exist yet.
If anything else appears there, or the location is changed to lead somewhere else, while the copy is made, the move stops: TextMouth deletes only its own copy, leaves what appeared alone, keeps using the old folder, and says what appeared and where.
A location that is a symbolic link counts as the folder it leads to, and messages name that folder too.
The old folder is left where it was.
A substitution rule, listening statistics, or filter preset changed while the library is copied is saved again once the move is over, in the library then in use: the moved one when the move finishes, the old one when it is cancelled or fails.
Until then a failed save of the same file is still reported as unsaved.
A save in progress never stops a move: the files TextMouth makes while it saves are not copied, and a stale one that a crash left stays in the old folder.

### The hidden folder of a move
<!-- id: hidden-folder-move; keys: migration staging, leftovers, UUID, cleanup at launch; src: TextMouth/Services/MigrationStagingLeftovers.swift, TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/Models/CloudStorageContract.swift -->

The hidden folder is gone when the move ends, however it ends: renamed into place when the move finishes, removed when it is cancelled or fails.
When it can't be removed, because the new location's drive was unplugged during the copy or TextMouth was force-quit, it stays on that drive, and TextMouth removes it the next time it starts.

- TextMouth notes each hidden folder in Move Leftovers.json, a file of this Mac's own (see [Folders of this Mac's own](this-macs-folders.md)), before the move creates it, and a launch removes only the folders that list names.
  Even then it removes a folder only if its name is exactly .TextMouth-migration- followed by a UUID and it is a real folder, never a link.

- A folder that can't be seen, because its drive is still away, stays on the list for 30 days, and each launch in that time tries again.

- The debug log records MIGRATION_STAGING_REMOVED for each folder removed, and MIGRATION_STAGING_LEFT for each that could not be removed.

### Progress while the library moves
<!-- id: progress-while-library-moves; keys: progress sheet, progress bar, VoiceOver announcements; src: TextMouth/ViewModels/DataDirectoryMoveProgress.swift, TextMouth/Views/Library/DataDirectoryMoveSheet.swift -->

While the library moves, every Library window shows a sheet with its progress, as in "Moving the library… 40 percent", and Cancel, which Escape also presses; Storage settings show the same.
VoiceOver moves to the progress bar, and announces what the move waits for, where the library is going as the copy starts, each quarter of the copy, and how the move ended.
Books can't be opened or added meanwhile; a book opened from Finder is imported once the move is over.

### Cancelling a move
<!-- id: cancelling-move; keys: Cancel button, Escape, partial copy; src: TextMouth/ViewModels/DataDirectoryMoveProgress.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Cancel deletes the partial copy and leaves the library where it was, with no setting changed, and the status then says so, as in "Move cancelled.
The library is still at /Users/you/.TextMouth."
Once every item is copied, the move can only finish.

### Quitting during a move
<!-- id: quitting-during-move; keys: quit, Command-Q, stop for quit; src: TextMouth/ViewModels/DataDirectoryMoveProgress.swift, TextMouth/Platform/macOS/App/AppDelegate.swift -->

Quitting during the copy stops the move first, as Cancel does, or lets it finish once every item is copied, and then quits.
A move still waiting to start its copy doesn't hold up quitting.

## When the library isn't available
<!-- id: when-library-isnt-available; keys: unavailable library, missing library, unplugged drive; src: TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift -->

### How TextMouth checks the data directory
<!-- id: how-textmouth-checks-data-directory; keys: launch check, unmounted drive, metadata only; src: TextMouth/Services/DataDirectoryAvailability.swift -->

TextMouth checks the data directory at launch, before it creates or loads anything, reading only metadata.
It checks again when the drive holding it is unmounted, or when a save finds its folder gone.

### A missing folder you chose
<!-- id: missing-folder-you-chose; keys: unplugged drive, signed-out cloud service, moved folder, default location; src: TextMouth/Services/DataDirectoryAvailability.swift -->

The default location is always available: it is created when it is missing, as on a first launch.
A folder you chose is never created, nor any folder above it: a missing one is an unplugged drive, a signed-out cloud service, or a folder that was moved or deleted, and creating it would start an empty library in its place.
A folder that was renamed, or a drive that mounted under another name, is found again through its bookmark, unless that leads into the Trash or to another library.

### The Library Not Available window
<!-- id: library-not-available-window; keys: error screen, reason, copy path, Quit TextMouth; src: TextMouth/Views/Library/DataDirectoryUnavailableView.swift, TextMouth/Services/DataDirectoryAvailability.swift -->

Otherwise every Library window shows Library Not Available in place of the library:

- the reason, such as "The drive “Backup” isn't connected." or "The folder is there, but it holds a different TextMouth library.",
- then where to choose another folder instead, "To use another folder, open Settings, Storage, and choose Choose Another Library or Use Default Location.",
- the folder's full path, which you can select and copy,
- and two buttons, Try Again, which Return presses, and Quit TextMouth.

VoiceOver moves to the reason and announces it once.
Meanwhile the library index isn't saved, and no book can be opened or added.

### Files that are only in the cloud
<!-- id: files-that-are-only-cloud; keys: placeholder files, sync service, Google Drive, iCloud Drive, waiting for files; src: TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift -->

When library.json, library-identity.json, the Feeds folder, a feed's folder, or a feed's index is only in the cloud, TextMouth gets it from the sync service itself and opens the library when it arrives, so you needn't do anything.
Meanwhile every Library window shows Getting Your Library, with the reason "Some of the library's files are in Google Drive and aren't on this Mac yet.
TextMouth is getting them now, and the library opens when they arrive.", naming your cloud service.
It gets only these files, never a book or an episode, and TextMouth stays usable meanwhile.
VoiceOver hears "The library is available." when the library opens, and every book you opened from Finder while waiting opens then.

A read that fails is tried again after 5, 15, and 30 seconds, since a cloud service may not be running yet just after a restart.
TextMouth waits 60 seconds for a service that gives no answer at all, and at most eight files are read at once.
If they still can't be had, the heading goes back to Library Not Available, the reason says that TextMouth couldn't get the files and what to check, and any books you opened from Finder are named as not opened.
Try Again starts over, and a file that turns up late still opens the library.

### Try Again
<!-- id: try-again; keys: retry, reopen the library, newer reading positions; src: TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift -->

Try Again opens the library once it is back.
When the library went missing while TextMouth was open, library.json is read afresh, and the session's newer reading positions are carried into it.

### Storage settings when the library is missing
<!-- id: storage-settings-when-library-missing; keys: Choose Another Library, Use Default Location, switch library; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Views/Library/DataDirectoryUnavailableView.swift -->

Storage settings say Library Not Available, with the same reason, and offer the ways out: Choose Another Library…, for a folder that holds a TextMouth library, and Use Default Location…, which uses the library in ~/.TextMouth or starts a new, empty one there.
Either quits and opens TextMouth again on that library, and the confirmation lists the changes that couldn't be saved, which switching loses.
Nothing is created at the missing location.
