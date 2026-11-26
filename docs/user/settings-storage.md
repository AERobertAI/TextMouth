# Settings: the Storage tab
<!-- id: settings-storage-tab; keys: Storage settings, data directory, library folder, disk space, maintenance; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

Part of [TextMouth's documentation](../../README.md).

## Storage Directory
<!-- id: storage-directory; keys: data directory, library location, dataDirectoryPath, Status, newer version of TextMouth, library.json, feed index; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

The Storage tab's Storage Directory group shows where the library is (see [Where TextMouth keeps your library](where-your-library-lives.md)) and its Status.
Under the Status, when any are kept, it shows how many books this TextMouth cannot read because a newer one wrote them, as in "1 book in this library needs a newer version of TextMouth.
It is kept as it is, but not shown." or "3 books in this library need a newer version of TextMouth.
They are kept as they are, but not shown."
The count joins the books of library.json to those of the feeds' indexes, and the group says nothing when there are none.

## Audio Editing storage
<!-- id: audio-editing-storage; keys: original audio, recordingOriginalPolicy, recordingOriginalDays, useInstalledFFmpeg, filter presets, Filter Presets; src: TextMouth/Views/Settings/AudioEditingSettingsSection.swift, TextMouth/Views/Settings/AudioFilterPresetsView.swift, TextMouth/Models/AudioEditWording.swift -->

The Storage tab's Audio Editing group sets how long the original audio of recordings and edited audiobooks is kept, whether an installed ffmpeg runs the audio editor's filters.
It also sets whether the editor previews a filter before applying it and plays half a second after each move, and, through Filter Presets…, the editor's filter presets (see [Editing audio](editing-audio.md)).

## Import Behavior
<!-- id: import-behavior; keys: importDeleteBehavior, keepsOriginalOfConvertedAudio, .convertedOriginals, Keep Original, Delete After Import, Ask Each Time, Ogg; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/Models/ConvertedOriginalWording.swift, TextMouth/Models/OriginalFileDeletionWording.swift, TextMouth/Models/ImportDecision.swift -->

The Storage tab's Import Behavior group sets what happens to the original file after an import (After Importing a Book: Keep Original, the default, Delete After Import, or Ask Each Time; see [Adding books](adding-books.md)).
It also has Keep originals of converted audio, off by default, a switch whose hint VoiceOver reads as "Keeps each audio file an import converts, such as Ogg or AC-3, inside the book's package."
Its caption under the switch changes with it.
Off, it says "Audio that TextMouth converts at import keeps only the converted file."
On, it says "TextMouth keeps the original file of audio it converts at import.
An original takes about as much disk space as its converted file, or twice as much when uncompressed.
Export offers it as the Original file.
A feed episode's original is not kept: it can be downloaded again."
The kept original is in the book's package, in a hidden folder named .convertedOriginals, and only an import made while the switch is on keeps one; turning it on later brings back none.
Export's Original file offers it, with the hint "The book's file as imported; for an audiobook, its audio files before TextMouth converted them."
(see [Exporting books](exporting-books.md)). config.json holds the switch as keepsOriginalOfConvertedAudio (see [Editing settings in config.json](config-json.md)).

## Find Duplicate Books
<!-- id: find-duplicate-books; keys: duplicates, MD5, same ISBN, same title, same author, Scan for Duplicates, Next Groups; src: TextMouth/Views/Settings/DuplicateFinderView.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

The Storage tab's Find Duplicate Books… groups the library's books, never a feed's episodes and articles, by the criteria you check: Identical File (MD5), checked as the sheet opens, Same ISBN, Same Title, and Same Author.
Checked criteria combine, so Same Title with Same Author groups by both, and no separate Same Title & Author is offered; a book without an author is left out while Same Author is checked, so check Same Title alone to find two copies of it.
Scan for Duplicates says how many duplicate groups it found, or that it found none.
Each group's heading names the criteria and what its books share, as in "Same Title and Same Author" over "Moby-Dick by Herman Melville".
Each row speaks the book's title, author, format, folder, and the date it was added, which tells two copies apart, and the list keeps every row of the page it shows, so VoiceOver's cursor stays put in it.
And the books you check, on every page, are moved to the Trash or deleted together, as Removal Behavior says, after asking when it says to.
The groups are shown a page at a time: whole groups listing at most 40 books in all, or one larger group on a page of its own.
While there is more than one page, a line above the list, shown and spoken alike, says which groups are shown, as in "Showing groups 1 to 5 of 116", and Previous Groups and Next Groups, each dimmed where there is no page to turn to, turn the page and announce the new line.
Each page opens at its top.
After a removal, the list shows the page now holding the group that headed the page you were on.
Before the first scan, the sheet says "Check the criteria above, then Scan for Duplicates."

## Redo Text Extraction
<!-- id: redo-text-extraction; keys: re-read text, reextract, Library Maintenance, text encoding, edited text; src: TextMouth/Views/Settings/StorageSettingsView.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

The Storage tab's Redo Text Extraction…, in its Library Maintenance group, reads every text book's file again after asking first.
It also shows its progress (see [Where TextMouth keeps your library](book-packages.md), under content.md, and [Editing a book's text](editing-book-text.md) for what it does to text you edited).
It waits while TextMouth reads any book's file again in another encoding, with the Text Encoding pop-up in Book Information (see [The Library window](book-information.md)).
It starts nothing, and the status line under its button says, and VoiceOver announces once, "TextMouth is reading “Moby-Dick” again in another encoding.
Try again when that finishes.", naming that book.
Choose it again once the re-read has ended.

## Sync
<!-- id: storage-sync-section; keys: Set Up Sync, Join Sync Folder, Sync Now, Stop Syncing, iCloud Drive; src: TextMouth/Platform/macOS/Views/SyncSettingsSection.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

The Sync group, after Library maintenance, sets up, joins, runs, and stops the sync of your library with your iPhone through iCloud Drive.
Its status line and buttons are described in [Syncing your library between your devices](syncing-your-library.md).
