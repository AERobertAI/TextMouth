# Imports: duplicates
<!-- id: imports-duplicates; keys: duplicate book, duplicate question, duplicate dialog, Keep Both, Replace Existing, ImportDecision; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Unanswered duplicates
<!-- id: unanswered-duplicates; keys: duplicate dialog, pending question, hidden marker file, orphaned package, grace period, abandoned import, iCloud; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/FileImportService.swift, TextMouth/Models/ImportDecision.swift, TextMouthProductionTests/ImportDecisionFlowTests.swift, TextMouthProductionTests/TMBPackageImportTests.swift -->

Unanswered duplicates: a duplicate's question lives only in memory, and the new copy's package is published before it is asked.

- Owner: DuplicateQuestionMarker (Services/DuplicateReplacement.swift), the empty hidden file .awaitingDuplicateAnswer at the top of the new copy's package, written before the question is queued.
  Keep Both takes it off before the copy joins the library, and Replace Existing after the copy's record is written and before the index names it, and puts it back when the replacement is not committed.
  Either keeps the question, saying why (DuplicateCopyWording.markerStays), when the marker cannot come off.
- Who may write it: no walk of the library adopts a marked package.
  The walk adoptOrphanedTMBPackages passes it over before reading its record and records it in an optional collector, UnansweredDuplicates.
  A package whose folder or marker is only in the cloud, where another Mac may still be asking, counts as a cloud skip instead.
  Only the launch repair gives the collector (LibraryViewModel.adoptOrphanedPackages).
  Then discardUnanswered moves each recorded package whose question this library is not asking to the Trash, whatever the Trash setting says, logging DUPLICATE_UNANSWERED.
  A package whose marker is less than a day old (unansweredQuestionGrace, by the marker's modification date; a date that cannot be read counts as new) stays, since another Mac may be asking.
  A rebuild, the provisional library, and a repair run again while a question waits discard nothing.
  A package imported with the marker still on it, as a copy that Cancel or the discard sent to the Trash and Open Book or Finder opens again, has it removed beside the removal marker.
- How others observe it: one alert after the repair, DuplicateCopyWording.unansweredTrashedTitle, "Duplicate Copies Moved to the Trash", names the titles moved (up to three; more are counted), appended to an alert already showing.
  Keep Both and Replace Existing say why they cannot keep a copy through DuplicateCopyWording:
  - libraryUnreachable(bookTitle:) while the data directory is unavailable, checked first, and
  - copyGone(bookTitle:) when the package is gone, so the original is never deleted by then.

  A marker that stays is logged as DUPLICATE_KEEP_FAILED with the system's reason.
  Tests: ImportDecisionFlowTests.

## Replacing a duplicate
<!-- id: replacing-duplicate; keys: duplicate dialog, swap copies, same ID, reimport, duplicate book; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Models/ImportDecision.swift -->

Replacing a duplicate (ST04): what Replace Existing does with the two copies of a duplicate's question.
The new copy, which its import has already published in a package of its own, takes the place in the library of the copy the library holds, as that same book.

### What the new copy keeps
<!-- id: what-new-copy-keeps; keys: bookmarks, settings per book, metadata edits, chapters, audiobook, carry over, relocate; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/Book.swift, TextMouth/Models/Book+OwnSettings.swift, TextMouth/Models/PlaceRelocator.swift, TextMouth/Models/PlaceClock.swift, TextMouth/Models/TrackPlaces.swift -->

Owner: the library's row of the replaced copy, which the new copy takes over under the same ID.
DuplicateReplacement (Services/DuplicateReplacement.swift) decides what the new copy keeps (carriedBook(replacing:with:places:location:)):
- the ID, so that what the app keeps by ID stays, such as the place on the reading list;
- the folder, the place in the folder's manual order, the date added, and when it was last opened and played;
- the old row's unknown keys, those a later TextMouth added ([Keys a later TextMouth adds](package-records.md)), though not the old package record's;
- the metadata the user edited by hand (Book.HandEdits, keepHandEditedMetadata(of:)); and,
- for two books of one kind (areSameKind: both audiobooks, or both read from their text, a DAISY book among them, since BookFormat.isAudio tells them apart), the book's own settings (Book.hasOwnSettings, takeOwnSettings(of:)) and its places (carriedPlaces).

A text book's places are moved from the old text to the new one by the words they were saved by where the two texts differ (PlaceRelocator.relocate(_:from:to:movedAt:)).
They move so only from an old text that is the text they were saved in, the content.md TextMouth last wrote or took, whose digest the record keeps (holdsTextOfPlaces, as Edit Text moves places only then).
From a save no edit took, or when the old text cannot be read, they are found in the new text by their words alone (PlaceRelocator.relocate(_:within:movedAt:)), and a place nothing finds stays as it was saved.
PLACES_RELOCATED is logged when any moved.
An audiobook's places count time in its recording (P08) and follow the new chapter list (movedAudioPlaces(_:from:to:at:)):
- the same list leaves them;
- a book of tracks, one track to a chapter with every old track among the new copy's, moves each place to its track at the same time into it, a skipped heading with it (TrackPlaces.moved);
- any other list moves each place through time on the recording (PlaceClock) to the new chapter that holds the time where its old chapter starts plus its offset's time, never held to that chapter's end, and its skipped headings wait, naming no heading, since another chapter list does not keep them.

A copy of the other kind keeps only the ID, the place in the library, and the hand-edited metadata, since a text's places and speed mean nothing to a recording.
Everything else is the new copy's: its file and text, what reading them measured, its title and author where the user edited neither, and where it came from.
The new copy's package record keeps the import's own ID until the library commits the new row, so a stop before then never leaves two records naming one book.

### The steps of a replacement
<!-- id: steps-replacement; keys: rollback, undo replace, kept text copy, old package, hidden folder, half-deleted; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Models/FeedBookUse.swift, TextMouth/Services/AudioEditing/AudioEditActivity.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Services/ReadingTextCache.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/ViewModels/TranscribedBooks.swift -->

Who may write it: LibraryViewModel.replaceExisting(with:of:), which answerImportDecision(_:with:) reaches for Replace Existing, on the main actor, in this order.
It finds the library's copy that matches now (duplicateMatch(for:)), which an earlier answer may have changed since the question arose, and adds the new copy as Keep Both does (keep(_:of:)) when none matches.
It refuses (replacementRefusal(of:), a DuplicateReplacement.Refusal)
- while another operation holds the library's storage work (StorageBoundary.shared.heldFor: .storageBusy, as a folder edit does while it moves packages off the main thread, when the replacement would carry nothing from a package moved meanwhile and write its record into the old package's new place);
- while the copy is open in a reader, being transcribed, or being exported, the uses a deletion of a feed's download refuses (.inUse, FeedBookUse.refusal(of:doing:retry:), whose clause names the action);
- while its audio is edited in the audio editor or saved from it (.audioBeingEdited, AudioEditActivity.isBeingEdited);
- while its text is being read again in another encoding (.readingAgain, which carries that re-read's own sentence, LibraryViewModel.readingAgainRefusal(of:), and is asked last, since a re-read ends by itself in a moment);
- and when the old package or a file carried over is only in the cloud (.filesInCloud), which a replacement never downloads.

Reading a book again in another encoding is in [Kept texts, re-reads, and edited text](text-caches-rereads-edits.md).

It flushes the analyses of the old copy that wait in the buffer (analysisSummaries.flush()); one still on its way names the old package, which the new row's is not, so it never lands on the new row (applyAnalysisSummaries).
DuplicateReplacement.prepare(replacing:with:) then reads everything carried over before it writes anything, and writes it into the new copy's package, which it moves into the old copy's folder:
- the copies Edit Text kept (TextMouthPaths.isKeptTextCopy);
- the old text, kept beside the new text as content.md.edited- (BookTextEditSessions.keepCopy(of:bytes:)) when the two differ and it holds text TextMouth did not write (TextNotKept is thrown when no copy can be made), that is:
  - an edit on record (Book.editedText) or a content.md whose digest is not the one written (DuplicateReplacement.holdsUnwrittenText(_:of:hasher:), which a re-read in another encoding asks too), or
  - for an audiobook, a save its transcript's layer does not account for or the text of an edited transcript that stays behind;
- the transcript, with the one kept before its cleanup; and
- the places.

The transcript is kept only when the new copy's audio is proven to be the audio transcribed (fitted(_:to:index:sourceMatches:access:)), and nothing is hashed, since this runs on the main thread:
- a book of one file whose content hash (Book.md5Hash) is the digest the transcript recorded for its file, whatever its name (the transcript's file is then renamed to the new copy's);
- the same source imported again (the two copies' content hashes equal, an archive's own or a folder's), with every file the transcript names at the same path and of the same size, since extracting an archive gives every file a new date; or
- each file the same by path, size, and date (TranscriptTextLoader.audioCheck with no hasher).

A file only in the cloud proves nothing, and a transcript of a later layout goes into the new package as it is.
### Committing a replacement
<!-- id: committing-replacement; keys: IndexNotSaved, commit order, Trash, hidden name, DUPLICATE_REPLACED, removeReplacedPackage, Edit Text session; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Services/ReadingTextCache.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/ViewModels/TranscribedBooks.swift -->

A failure while writing undoes what was written (Preparation.undo()), putting the package back as the import published it.
Then commitReplacement(of:by:) commits the new copy, each step on disk before the next:

- whatever waits to be written for the old copy goes into its own package (LibraryPersistenceService.writePendingBookInfoNow(bookID:)),
- then the new row's record under the kept ID (saveBookInfoThrowing()),
- then the library's index naming it (LibraryPersistenceService.saveAndWait(_:)).

A failure of the last throws IndexNotSaved, and the caller undoes the preparation and writes the new copy's record under the import's own ID again.
Only then does the library hold the new row, at the old row's place, and these follow:

- the old row's queued writes are forgotten (LibraryPersistenceService.forgetDeletedBook) with the reading text this Mac kept for it (ReadingTextCache);
- the old copy's Edit Text session ends saying so (endEditingSessions(of:): BookTextEditor.endBecauseBookWasReplaced(_:title:), BookTextEditWording.stoppedBookReplaced) and its Edit Manifest session ends quietly;
- the transcript is noted (TranscribedBooks); and
- DUPLICATE_REPLACED is logged.

Then removeReplacedPackage(of:) removes the old package (DuplicateReplacement.removeReplacedPackage(of:movesToTrash:)):

- to the Trash in one move under its own name, or,
- with the Trash off, renamed first to a staged package's hidden name in its own folder (ImportStaging.freshName()) and deleted with everything in it (ImportStaging.removeStagedPackage(at:), which gives back the write permission a read-only item took away).

The rename comes first since a deletion can stop partway and a half-deleted package under its own name would be a broken book.
What cannot be deleted stays hidden, and the next import into that folder removes it (ImportStaging.removeAbandoned(in:)).
The replacement stands whatever happens then: a package that cannot be removed stays in its folder, and the library's alert says so (DuplicateReplacement.oldCopyLeftMessage).
When the old text was kept, VoiceOver says where, after the answer's own words (DuplicateReplacement.keptTextAnnouncement(title:copy:), whose second sentence is BookTextEditWording.earlierTextKept(_:), which a re-read in another encoding says too).
The new row then finishes as a kept book does (finishKeeping(_:from:of:offeringTranscription:)): a book already on the reading list keeps its place there, and an audiobook is offered for transcription only when its transcript was not kept.
A refusal, or a failure before the commit ("Could not replace duplicate" and the reason, or TextNotKept's or IndexNotSaved's sentence), is an OperationOutcome.failure: the question stays open and the library's copy is as it was.

### Replacing off the main actor
<!-- id: replacing-off-main-actor; keys: background thread, async, beachball, progress indicator, iPhone, responsiveness; src: TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/ImportDecision.swift, TextMouth/Models/ImportDecisionQueue.swift, TextMouth/Views/Library/ImportDecisionPresenter.swift, TextMouth/Views/Library/ImportDecisionSheet.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Platform/iOS/Services/PhoneImportCopier.swift, TextMouth/Services/StorageDestinationAssessment.swift, TextMouth/ViewModels/DataDirectoryMoveProgress.swift -->

Off the main actor: the sheets, Mac and iPhone, answer through LibraryViewModel.answerImportDecisionOffMain(_:with:prepare:) (ImportDecisionPresenter, PhoneImportCopier), which acts as answerImportDecision(_:with:) does for every answer but Replace Existing of a duplicate.
For that one, replaceExistingOffMain refuses and starts as replaceExisting does (refusalToKeep, startReplacing), then:

- marks the question as being answered (ImportDecisionQueue.beginAnswering, endAnswering; another answer meanwhile does nothing and says DuplicateCopyWording.answerUnderWay),
- marks the book as being read again (textRereads.begin(_:for: .replacement), so a quit, Edit Text, and the readers wait), and
- awaits DuplicateReplacement.prepare through OffMainWork inside the storage boundary (the replacementPreparer, which a test replaces).
It touches the new copy's package and the old copy's files, never the library's rows.
Back on the main actor it re-checks, in this order, and puts the new copy back as its import published it (putBack, Preparation.undo()) at the first that fails:

- the question is still the one asked (else nothing is answered);
- no data-directory move is under way (DataDirectoryMoveWording.importAnswerRefusal);
- the library's copy is still the row the work was made from (DuplicateCopyWording.changedWhileReplacing(bookTitle:)); and
- replacementRefusal(of:) is clear.
Then finishReplacing commits.
The sheet dims its choices and shows a SheetWorkIndicator with DuplicateCopyWording.replacing(bookTitle:), which VoiceOver hears once if the work lasts ImportDecisionSheet.announcementDelay (1 second); the iPhone's sheet does not announce it yet (a follow-up).

### Reading the new copy again
<!-- id: reading-new-copy-again; keys: charset, code page, braille code, reread, BOM; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Parsers/TextEncodingGuesser.swift -->

What the new copy is read again in (DuplicateReplacement.readingToCarry(replacing:with:), a CopyReading, read by readCopyAgain):
- the Braille File Characters of the old copy for the same bytes (brailleFileCodeToReadAgain);
- its braille table for the same bytes (brailleTableToReadAgain(replacing:with:): both are braille books, the content hashes are equal, and the table that stands for the old copy, the row's, is not the new copy's, nil being the default table);
- both in one re-read when both apply (.brailleFileCodeAndTable); or,
- for a plain text, Markdown, or HTML book, the old copy's chosen encoding (textEncodingToReadAgain(replacing:with:)), when the old record isChosen, and either:
  - the files are the same bytes, or
  - bytesMayBeReadInChoice(_:of:) holds, that is:
    - the new bytes' import rests on a guess or the Windows-1252 fallback and not on a byte order mark, unmarked Unicode, valid UTF-8, or a declaration,
    - TextEncodingGuesser.guessSevenBit finds nothing in them, and
    - they read strictly in the choice.

Other bytes keep their import's reading and the replacement goes ahead.
A reading that fails refuses the replacement by name as Refusal.copyNotReadAgain, in the re-read's own words (a table this Mac no longer offers, a choice the same bytes can't be read in), and leaves the question open.

### How others observe a replacement
<!-- id: how-others-observe-replacement; keys: index rebuild, recovery, sheet error, reading list, cloud library, VoiceOver error; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/Models/TrackPlaces.swift, TextMouth/Models/ImportDecision.swift, TextMouth/Views/Library/ImportDecisionSheet.swift, TextMouth/Views/Library/ImportDecisionPresenter.swift, TextMouth/Platform/iOS/Services/PhoneImportCopier.swift, TextMouth/Models/FeedBookUse.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Services/FileImportService.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Models/ReadingList.swift -->

How others observe it: the question's sheet shows a refusal or failure above its buttons (OperationFailureNotice, which VoiceOver reads as "Error: " and the sentence, and announces once).
ReadingList.replace(_:with:) is no longer called by the app, since the new row keeps the old row's ID and so its place on the list.
The old package's record names a listed book, so the launch's repair that adopts packages missing from the index (FileImportService.adoptOrphanedTMBPackages(library:libraryDirectory:access:skips:)) leaves it as it is, unadopted and unwritten, with one ORPHAN_ID_LISTED line.
It does so whether Finder put it back from the Trash, a stop left it beside its replacement, or a failed removal kept it.
So no two rows share an ID, no index recovery rewrites a record, and in a cloud library whose library.json arrives after its packages no new ID is written over the index's.
Of two such packages that no row listed before the walk, as an index rebuilt from the packages finds an old copy put back beside its replacement, the one whose record was written later becomes the book, whichever the folder lists first.
That one is the replacement, whose record Replace Existing wrote after the old copy's last one.
Folder-path fixes wait for the walk's end, so the other package is never written.
