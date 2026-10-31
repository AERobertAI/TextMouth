# bughunt-recoverysaves: places saved during index recovery survive, and Rebuild never replaces an index that reads again

Worker slug `bughunt-recoverysaves`, branch `bughunt/recoverysaves` (from `team/bughunt`). Read `README.md` beside this file first. Two fixes in `TextMouth/Services/LibraryPersistenceService.swift`, one commit each, each with its test. Both were verified by the lead by reading.

## 1. Reading positions saved while the library index is unreadable are lost at the next launch that can read it
`saveReadingCheckpoint(_:of:writingWithin:)` (lines 231-247) returns as soon as `indexWriteHold()` (`:1474-1478`) gives a hold, **before** it names the book in the checkpoint journal (`ReadingCheckpointJournal.note`, `:1142-1150`). While the index is unreadable (`.unreadableIndex`), the recovery sheet says reading positions are still saved with each book, and they are: each checkpoint reaches the book's record. But no book is named in the journal, so when the user restores library.json and relaunches, `adoptNewerRecordedPositions` (`LibraryViewModel+Migration.swift:140-144`) finds nothing to take from the records (`booksWithCheckpointsAhead()`, which reads the journal), the reader opens at the row's old position (`ReaderViewModel.swift:708`), and its next save overwrites the newer position in the record. An hour of listening during recovery is lost.

Fix: when the hold is `.unreadableIndex`, still note the book in the journal before returning (the data directory is there, and the record was written); when it is `.dataDirectoryUnavailable`, write nothing, as now (the journal file lives in the data directory, `TextMouthPaths.readingCheckpointsFile`, and the record was not written either). The journal is cleared only by an index write (`:454`), which resumes once the index is readable, so the entries survive until then. Update the function's doc comment to say so.

Test, in `LibraryIndexRecoveryTests` (grep how it makes an unreadable index in the sandbox, saves a checkpoint, and loads a fresh model): with an unreadable index, save a reading checkpoint of position 30 for a book whose row says 1, flush, make library.json readable again (restore the good bytes, as the user would), resume index writes as a relaunch would (`resumeIndexWrites()` or a fresh load, whichever the class uses), and load a fresh library model: the book's position is 30 (today 1). And with the data directory unavailable (grep `isDataDirectoryUnavailable` in the tests for how one is made), no journal file is written.

## 2. Rebuild Library Index replaces an index that can be read again
`replaceUnreadableIndex(with:)` (`:1440-1462`) re-reads the file at the index location only to preserve a copy of it, then writes the rebuilt library over it. If the file became readable while the recovery sheet was open (another Mac finished its save; the user restored the file from a backup), Rebuild still replaces it, losing its folders, manual order, reading list, and the books whose packages are only in the cloud; only the preserved copy keeps them.

Fix: before preserving, try to decode the bytes it re-reads with the same decoding the load uses (find the load's decoding function in this file and call it; do not write a second decoder). When they decode as a library, replace nothing, keep index writes suspended, and throw a new `LibraryIndexRecoveryError` case (`TextMouth/Services/LibraryLoadResult.swift:94-112`) whose description is: "The library index can be read again, so TextMouth did not rebuild it. Choose Try Again to use it." Read how the Library window presents a failure of Rebuild (grep `rebuildLibraryIndex` in `LibraryViewModel+IndexRecovery.swift`) and confirm the sentence reaches VoiceOver the way the other recovery errors do; say in your report what the listener hears and where.

Test, in `LibraryIndexRecoveryTests`: with an unreadable index, then the good bytes put back at the index location, Rebuild throws the new error, the file's bytes are unchanged, and no copy was preserved; with the bytes still unreadable, Rebuild works as today (the existing tests). Pin the sentence exactly.

## Run
`LibraryIndexRecoveryTests LibraryRecoveryAvailabilityTests ReadingPositionPersistenceTests CloudMaintenanceRepairTests` (grep each name; drop any that does not exist and say so) and the `storage` area's class that tests the checkpoint journal (grep `readingCheckpoints` in the tests).

## Do not touch
`LibraryViewModel+IndexRecovery.swift`'s merge (`carryingRecoverySessionState`) and launch adoption: another task. `LibraryViewModel.swift` and `LibraryViewModel+FolderManagement.swift` are claimed by team `views` tonight.

## What a listener hears
The new sentence in item 2, exactly.
