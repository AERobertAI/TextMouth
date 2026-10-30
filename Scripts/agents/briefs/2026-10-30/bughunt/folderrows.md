# bughunt-folderrows: a library without its index keeps its folders, and every book's folder has a row

Worker slug `bughunt-folderrows`, branch `bughunt/folderrows` (from `team/bughunt`). Read `README.md` beside this file first. One fix, one or two commits, with its tests. Verified by the lead by reading.

## The bug
- `LibraryViewModel.loadLibraryIndex()` (`TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift:203-212`): when library.json is missing (`.missing`) but the data directory's identity file and the book packages are there (`DataDirectoryAvailability.swift:502-506` calls that library available), the library starts with no books and no folders.
- The launch repair (`TextMouth/ViewModels/LibraryViewModel+Migration.swift:96-114`) adopts every package (`FileImportService.adoptOrphanedTMBPackages`), each book keeping its `folderPath`, and saves. Nothing makes the folders' rows: `FileImportService.adoptLibraryFolders(library:libraryDirectory:)` (`TextMouth/Services/FileImportService.swift:3262-3300`), which recreates rows for the folders on disk and every folder a book names, runs only while the index is unreadable (`buildProvisionalLibrary`, `LibraryViewModel+IndexRecovery.swift:329-332`).
- So the books in folders appear only in All Items, never in the Folders view, the empty folders are gone, and the saved index makes that permanent at every later launch. The same row is missing for a book imported into a folder that was renamed or deleted while the import ran (a race the bughunt library review found, item 7): nothing ever adds a row for a folder a book names.

## What to build
1. `adoptLibraryFolders` gains a parameter choosing whether the folders on disk count, or only the folders books name (default: both, as today), so one function does both jobs (DRY); its doc comment says which caller wants which.
2. The launch repair, right after it adopts orphaned packages:
   - when the library started the repair with no books and no folders (library.json was missing, or held an empty library), adopts the folders on disk and every folder a book names, as recovery does;
   - otherwise adopts only the folders books name, so a book never lies in a folder with no row, while a folder the user deleted, whose directory is gone, never comes back;
   - either way, a row added means the library is saved (`needsSave`), and one `DiagnosticLog` event says how many rows were added and why (grep the repair's other events for the tag and the style).
3. Rows are added parents first, as the function already does, so `Library.createFolderThrowing` accepts each (team branch: it may now refuse a parent that does not exist).
4. Nothing else in the repair changes.

## Tests
In `LibraryIndexRecoveryTests` (grep how it builds packages in folders in the sandbox and loads a fresh library model):
- library.json removed, two packages in `Library/Essays/Short/` and one in `Library/Novels/`, and an empty `Library/Empty/` directory: after the load and the launch repair, the folders Essays, Essays/Short, Novels, and Empty have rows, each book is in its folder, and the index saved holds them.
- An index that lists a book whose `folderPath` names a folder with no row (write such an index): after the repair the folder has a row; an empty directory on disk that the index has no row for is **not** adopted (the user deleted that folder).
- Running the repair again adds nothing.

## Run
`LibraryIndexRecoveryTests LibraryFolderTests FolderSafetyTests LibraryStartupRepairTests` (grep each; drop any that does not exist and say so) and every class that calls `adoptLibraryFolders` (grep it).

## Do not touch
`withStorageWorkHeld` and `library(afterMoving:from:current:)` in `LibraryViewModel+Migration.swift` (the tests team and another bughunt task change them tonight); `LibraryViewModel.swift` and `LibraryViewModel+FolderManagement.swift` (team `views` claims them); the recovery merge (`carryingRecoverySessionState`).
