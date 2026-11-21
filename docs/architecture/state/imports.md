# Imports
<!-- id: imports; keys: import, add book, Open Book, ingest, importer; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## An import in progress
<!-- id: import-in-progress; keys: UTType, file types, staging folder, import queue, archive limits, zip bomb, manifest check, video audiobook; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/ImportStaging.swift, TextMouth/Services/ImportScratchSpace.swift, TextMouth/Services/ImportFailure.swift, TextMouth/Services/ArchiveBudget.swift, TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Parsers/ArchiveEntryReader.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/AudioManifest.swift, TextMouth/Parsers/AudioManifestCheck.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Models/Book.swift, TextMouth/Models/FeedItem.swift, TextMouth/Resources/Info.plist -->

An import in progress.

- Owner:
  - LibraryViewModel's SerialImportQueue, which runs one import at a time off the main thread, each as storage work that a data-directory move waits for or holds back (StorageBoundary.perform), and reports activity on the main queue, and
  - ImportCancellation, which the queued imports share and the progress overlay's Cancel button sets.
- Who may write it: FileImportService does the work.
  Open Book offers the types it reads (FileImportService.supportedTypes), video among them, since an audiobook may be an MPEG-4, M4V, or QuickTime file whose sound alone plays (BookFormat.audio's mp4, m4v, and mov).
  So a video episode's package imports again too, as does the audio the import converts (BookFormat.audio's ogg, oga, and opus, and ImportAudioConverter.coreAudioExtensions) and an M3U playlist.
  ArchiveEntryLimits.audioExtensions is the same list.
  A feed still tells a video enclosure from audio for itself (FeedMediaKind, whose audioExtensions leave video's out).
  It identifies the source and builds the package under a hidden staging name (ImportStaging, .import- followed by a UUID and .tmb).
  The package is in this Mac's Import Staging folder while the data directory is on its volume, and beside the package's destination otherwise (ImportScratchSpace).
  It then copies the content, reads the book as the reader will, writes bookInfo.json and reads it back, and only then publishes the package with one rename.
  A TextMouth package is staged as every import is (REV13).
  ImportStaging.makeEmpty makes the staged package, then the .copying step copies the source package's items into it (copyContents(of:)), so the import overlay names the copy, and a package whose own folder is read-only imports, since the staged folder is TextMouth's own.
  A failure removes whatever was staged and throws an ImportFailure naming the file and the step, and the original file is never touched after a failure.
  A ZIP is inspected and extracted within an ArchiveBudget into an Archive Extraction folder on the same condition, this Mac's or the data directory's (ArchiveExtraction), and every format reader takes entries out of archives through ArchiveEntryReader, which holds each entry to its limits.
  A reader that looks up more than a member or two, as the EPUB, Word, and DAISY readers do, finds them in an IndexedArchive, the archive's entries read into an index by path once, since ZIPFoundation finds each by reading the archive's central directory from its start.
  The index answers exactly as the archive would, the first entry at a path winning.
  IndexedArchive.file(at:) finds the entry at exactly a path, else the first file entry whose path matches it without regard to case (ST09).
  The exact spelling always wins.
  Archive.file(at:) is the same rule for an archive not indexed.
  The EPUB reader's lookups and the DAISY reader's use the rule, since a badly made book may name a member in another case than its ZIP spells it.
  DAISY audio conversion copies each audio file through DAISYFileProvider.copyFile(at:to:): out of a ZIP a megabyte at a time (ArchiveEntryReader.stream), never whole, and from a folder as a clone.
  A ZIP batch reads each book's checksum once, for its duplicate check, and hands it to the book's import (importFileWithReport(from:checksum:toFolder:observer:)).
- How others observe it: LibraryViewModel adds the published book to the library, unless the library already holds a copy, and the overlay shows how far the import has got (import progress, below); every question an import raises waits its turn in one queue (import questions, below).
- The manifest's check (FR15): an archive whose manifest.json is found (AudioManifestLocation.find(in:)) is checked in a step of its own, Reading its manifest (ImportStep.readingManifest), after extraction and before the book is read.
  AudioManifestCheck.checkedManifest(at:audioFolder:) stops at the first problem, in the order a person fixes them, with an AudioManifestProblem whose sentence begins "manifest.json".
  Only the import checks; every later read is lenient (AudioManifest.read(inAudioFolder:)).

## Import progress
<!-- id: imports-import-progress; keys: ETA, time remaining, spoken progress, progress bar, batch import, extraction percent, announcement, Library menu; src: TextMouth/ViewModels/ImportProgress.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/Models/TimeLeftEstimate.swift, TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/ImportFailure.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+Recording.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/CountWording.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift -->

Import progress (FR10): what the import overlay shows, and what VoiceOver hears of an import.

- Owner: LibraryViewModel.importProgress, an ImportProgress (ViewModels/ImportProgress.swift) on the main actor, whose state is an ImportProgressState (its fields are in that file).
  The book under way carries, for an archive holding one audiobook, how far its extraction has got (BookUnderWay.extraction), which its line says while it extracts.
  The imports waiting behind the one shown (waitingImports) are what a new import's state keeps.
  The duplicates a batch skipped are counted once, in its ZipImportResult (skippedDuplicates).
  Whether the overlay shows at all is still the model's isImporting.
- Who may write it: the imports, on the main queue.
  ArchiveExtractor reports an archive's extraction as an ArchiveExtractionProgress, its entries and the bytes they declare, both totals from the archive's central directory, which the budget reads anyway.
  It reports at the start, and whenever the whole percentage of either changes, between the chunks of a large entry as well as between entries.
  A ZIP batch reports ZipImportProgress.extracting, then .importingBook as each book begins and as each step of it begins (through the importer's ImportStepObserver), and .importing(done:total:skippedDuplicate:) as each book is imported, fails, or is skipped as a duplicate.
  A batch also reports .foundBooks(sizes:) once, before its first book, each size from FileImportService.timedSize(of:).
  A text book's size is its file size, and nil for an audiobook's file, whose import reads its chapters rather than its every byte, for a DAISY book, a DTBook on its own included, and for an RTFD, which is a folder.
  A single file, or an archive holding one book, reports through ImportProgress.observeBook(_:startingAt:then:), which tells the overlay of each step before the queue's test hook.
  So do a TextMouth package opened from the Finder (openTMBPackage(from:), from .checkingPackage), New from Text (createBookFromText, from .preparingPackage, by its title), and a recording's save (LibraryViewModel.saveRecording, from .preparingPackage, by its title, REV13).
  The line of a recording's save is cleared (clear()) rather than ended, so it announces nothing, since the New Recording window says how the save ended.
  An archive holding one audiobook reports its extraction through observeExtraction().
  TimeLeftEstimate (Models/TimeLeftEstimate.swift, shared with the feed downloads' progress) gives the time left from the WorkTiming of the books imported or failed, duplicates not timed.
  Each book still to come of known size takes its bytes at the rate the sized books took theirs, and any other the average time of the books timed without a size, or of every book timed before any of those, less the time it has run.
  TimeLeftEstimate.rounded(_:) rounds it to the minute under 10 minutes, to 5 minutes under an hour, and to 15 beyond.
  The library follows the import queue's count of imports queued or running through importActivityChanged(to:), which observeImportActivity() starts (REV13).
  It assigns isImporting only when the count changes, so the library model publishes as imports start and end and not with each import queued or done.
  The progress counts those behind the one shown as waiting (noteImportsQueued(_:)).
  Cancel calls cancel(), and end(_:) ends the import shown.
### How others observe an import
<!-- id: how-others-observe-import; keys: ProgressObserver, TimelineView, announcement, nothing imported alert, Speak Import Progress, zip alert title, reading list; src: TextMouth/ViewModels/ImportProgress.swift, TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel+ReadingList.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/App/MenuCommands.swift -->

- How others observe it: only ProgressObserver, a generic view in Views/ContentView.swift, observes it, as it observes the text cache's progress (PERF12, #1461).
  It draws the overlay in a TimelineView that ticks every 5 seconds from the book's start, so the time on a book keeps up between reports while the library model is never republished.
  ProgressOverlay takes detail lines and a spoken summary from its caller; the text cache overlay keeps its own.
  ImportProgressWording words every line, the overlay's VoiceOver label, the announcements, and Speak Import Progress, the imports waiting included (waiting(_:), "2 more imports waiting", left out once Cancel is pressed, since queued ZIP archives never start).
  An import that has run 10 seconds (ImportProgress.announcedAfter) announces each quarter of a batch's books once, at medium priority, and its end, unless Cancel was pressed, when its alert says where it stopped; Cancel is announced at once.
  A batch that found no new book and in which nothing failed (ZipImportResult.foundNoNewBook) is not announced.
  LibraryViewModel.completeZIPImport raises the library's alert instead, which waits on screen and which VoiceOver reads, since an announcement made while TextMouth has no window in front is never spoken.
  The alert is titled ImportProgressWording.nothingImportedTitle ("Nothing Imported", set in LibraryViewModel.errorTitle, which goes back to nil, "Error", whenever showError turns false).
  It says nothingImported(from:result:): the duplicates sentence, noNewBooks(in:alreadyInLibrary:), or, for an archive with no book, noBooksFound(in:holding:).
  After the kinds named comes RefusedFormatAdvice's sentence for each kind that has one, once each (Pages, Keynote, Numbers, WordPerfect, Compiled HTML Help, DjVu, XPS, RAR, copy-protected audio).
  The one table also serves FileImportError.unsupportedFormat, so a single refused file reads the same.
  The last names what the archive held by kind from ZipImportResult.nonBookFiles, a NonBookFiles that FileImportService.importCandidates counts by extension for every file it passes over, those in archives inside included.
  A batch with failures or an incomplete book raises the alert under ImportProgressWording.zipAlertTitle(for:addedBooks:), set through presentImportMessage(_:title:), where addedBooks counts the books the library took (completeZIPImport's acceptedBooks, not result.books):
  - nothingImportedTitle when the batch found no book,
  - alreadyInLibraryTitle ("Already in Library") when it found books and the library took none,
  - someFilesNotImportedTitle ("Some Files Not Imported") when books came in but a file failed or the batch was cancelled, and
  - otherwise bookImportedTitle or, for more than one book, booksImportedTitle ("Books Imported"), so that title never reads "Error" over books that came in.

  Every batch also ends with one ZIP_IMPORT_FINISHED event line in the debug log (ZipImportResult.logLine(archiveName:)).
  The reading list's join after an import made at the Reading List is announced at medium priority (addImportedBooksToReadingList(_:request:)), after the import's own words rather than over them.
  ShortcutAction.speakImportProgress, under Information with no default key, and Library > Speak Import Progress post speakImportProgress, which the library model hears from any window (observeImportProgressRequests()) and answers through VoiceOver.

## Import questions
<!-- id: import-questions; keys: question sheet, modal dialog, duplicate dialog, delete original, transcribe offer, focus, queue of questions; src: TextMouth/Models/ImportDecision.swift, TextMouth/Models/ImportDecisionQueue.swift, TextMouth/ViewModels/TranscriptionOffers.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/DataDirectoryMoveProgress.swift, TextMouth/Views/Library/ImportDecisionPresenter.swift, TextMouth/Views/Library/ImportDecisionSheet.swift, TextMouth/Views/ContentView.swift, TextMouth/Models/RemovalWording.swift, TextMouth/Views/Transcription/TranscriptionPresentation.swift, TextMouth/Services/DuplicateReplacement.swift -->

Import questions.

- Owner: LibraryViewModel.importDecisions, an ImportDecisionQueue of the questions imports are waiting to ask (the cases of ImportDecision.Kind), asked one at a time in the order they arose.
  Each ImportDecision holds everything its answer acts on, captured when its import finished (a duplicate's new copy and the copy it matched, an original file, a ZIP archive's books and folder, or an audiobook's ID, title, and length).
  It holds the ImportRequest its import was made with too: the Library window it started in (ImportOrigin), whether to open the book afterwards, and the cancellation its batch shares.
- Who may write it: LibraryViewModel+Import and LibraryViewModel+Duplicates. ask(_:) queues a question behind those waiting, and a question an answer raises about the same file, such as whether to delete the original of a duplicate just kept, is asked next.
  An offer to transcribe (ImportDecision.Kind.transcriptionOffer, FR05) is queued after an import's own questions, for each audiobook it added, when TranscriptionOffers.offersTranscription(of:) allows it:
  - an audiobook in a package of its own,
  - Offer to transcribe after importing an audiobook on,
  - and a Mac that can transcribe.

  Its Transcribe sends LibraryViewModel.acceptedTranscriptionOffers to the Library window that asked (LibraryTranscriptionSupport), which opens the Transcribe Audio sheet, starting at once when it can.
  A second press can never answer the next question, since answerImportDecision(_:with:) acts only on the question being asked, named by its ID.
  An answer that fails, such as a folder name the library refuses, keeps the question open with the reason.
  While the data directory moves (dataDirectoryMove is set), it refuses every answer with DataDirectoryMoveWording.importAnswerRefusal, shown in the sheet and spoken, and the question stays until the move ends, since a window asking one when a move begins keeps that sheet instead of the move's.
  The progress overlay's Cancel, cancelImports(), withdraws the questions of its batch, those waiting and those raised later:
  - a duplicate's new copy is discarded,
  - an original file is kept,
  - a ZIP archive's books stay where they are, and
  - an offer to transcribe is dropped.
- How others observe it: each Library window's ImportDecisionPresenter watches the queue, and exactly one window asks the question at its front (ImportDecisionQueue.askingWindow).
  It is the window its import started in while that is open, or else the first open Library window, the question waiting while none is open.
  That window shows ImportDecisionSheet, whose words, the screen's and VoiceOver's alike, come from ImportDecisionWording, with a title that gives the question's place when there is more than one, as in "Duplicate Book Found, 2 of 5".
  The choice that removes nothing comes first; Return and Escape press the marked choices, and Replace Existing and deleting an original file are never on a key.
  A duplicate's question says what Replace Existing keeps (ST04).
  ImportDecisionWording.duplicateMessage adds, after the choice, replacingKeepsSentence(existing:new:), which chooses from both copies' kinds and never promises what DuplicateReplacement.carriedBook drops:
  - replacingKeepsTextSentence or replacingKeepsAudioSentence for two copies of one kind, and
  - replacingAcrossKindsSentence when one is an audiobook (BookFormat.isAudio) and the other is not, which says "played from its recording" and "read aloud from its text" rather than "not an audiobook", so that it is true of a DAISY book too.

  Then replacedCopySentence(movesToTrash:) follows the Trash setting (RemovalPreferences.movesToTrash):
  - with the Trash on it says that the files go to the Trash but putting them back won't return that copy to the library, since the package's record names the book the new copy now is, which no launch adopts a second time (adoptOrphanedTMBPackages);
  - with it off it is RemovalMode.deletePermanently's files clause.

  The choice's hint is ImportDecisionChoiceWording.replaceExisting(acrossKinds:), which across kinds promises only the folder and the place on the reading list.
  The words say what Replace Existing does (replacing a duplicate, below).
  A question that appears while the user is in another window waits without taking focus or being announced.
  A book whose import asked to open it, as one opened from Finder does, opens through LibraryViewModel.readerOpener once it is in the library and its questions are answered.

## Packages and originals
<!-- id: packages-originals; keys: tmb, package import, reinstate, original file, Trash, ID collision, add back; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Services/BookTextEditing.swift -->

Packages and originals: FileImportService.isBookPackage(_:) is the one test of the .tmb extension, shared by importFiles, importAndOpenFiles, and deleteOriginalFile(at:).
- importFiles sends a package to openTMBPackage(from:) as importAndOpenFiles does, handing it the window's folder and reading-list request, with only the first of several packages opening a reader (LibraryViewModel.importFiles(urls:toFolder:...)).
- importCandidates lists a .tmb folder in a ZIP as one book and never walks into it.
  The batch identifies it once (identifyTMBPackage) and imports it as a package opened from Finder is, or takes back the package Remove from Library Only retained, and one whose book the library lists, by ID or checksum, is skipped, importZip taking existingBookIDs.
- listedBookID(for:) repairs a listing from a package only when it is the book's own package or the listing has none left, and any other copy opens the listed book and logs TMB_ID_LISTED.
- reasonToKeepOriginal(at:) keeps an original that is a folder, inside a .tmb package, or inside the data directory (resolved links, compared by path component and without regard to case), logging ORIGINAL_KEPT.
- stagedFileName(for:) stages a source named content.md, in any capitals, as "content (book)" with its own extension, so the text cache never replaces the book's file.
  The legacy migration uses it too.
- readableContent catches EditedTextKept, so a package whose record holds a taken edit imports with content.md as it is and the edit kept, and RemovedFromLibraryMarker carries editedText and textCacheFingerprint (decoded leniently) so a book added back keeps its edit.
  A marker without them keeps content.md as a content.md.edited- copy when reading the file would write other text there (BookTextEditWording.replaced, addBackNoCopyKept), and a copy that cannot be kept stops the reinstatement.

## Limits of what a file claims
<!-- id: limits-what-file-claims; keys: XXE, entity expansion, hostile file, untrusted input, stack overflow, integer overflow, malformed header; src: TextMouth/Parsers/EPUBParser.swift, TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/DAISYParser+NCXParser.swift, TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/Parsers/AudioContentSniffer.swift -->

Limits of what a file claims: EPUBParser.readingXML(_:_:) is the one way EPUB XML is read, with .nodeLoadExternalEntitiesNever, as the feed and OPML readers do, so an entity naming a local file reads as nothing.
The NCX is read through withNCX, which hands its document to the navigation and page-list readers the same way.
The EPUB and DAISY navigation and the PDF outline are walked with explicit stacks, not recursion, and a PDF's outline is taken apart before it is released.
AudioMediaProbe refuses a length past a year, and a sample rate past maximumCappedSampleRate is refused before a downmix counts it, with the size arithmetic capped by cappedSeconds and cappedSampleRate.
AudioPlaybackService.metadataAssetOptions(for:) refuses an Ogg file under another extension by its "OggS" bytes (AudioContentSniffer.isOgg(at:)), so no Ogg file reaches AVFoundation's tag readers.

## A folder of tracks
<!-- id: folder-tracks; keys: audiobook folder, folder import, no book error, loose audio files; src: TextMouth/Services/FileImportService.swift -->

A folder of tracks (FR17): importFileWithReport sends a folder of tracks that no format reads to importAudioFolderWithReport, which shares publishTracks with the ZIP import.
A folder with neither a DAISY book nor tracks throws FolderWithoutBookError.

## Copying tracks, and room for them
<!-- id: copying-tracks-room-them; keys: disk space, free space, reserve, APFS clone, copy on write, playlist, M3U; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/ArchiveBudget.swift, TextMouth/Services/ImportFailure.swift, TextMouth/Services/SpeechExport/SpeechExportSpace.swift, TextMouth/ViewModels/LibraryViewModel+OggConversion.swift -->

A folder of tracks and a playlist copy their tracks through FileImportService.copyTracks(_:into:), which first asks requireRoom(forCopying:onVolumeOf:).
The check is the rule of the archives (ArchiveLimits.current, so its freeSpace and freeSpaceReserve, which tests replace), applied to the sum of the tracks' sizes (the reserve is 1 GB) before the first byte is copied.
It throws CocoaError.fileWriteOutOfSpace, which ImportFailure words as a full disk.
- A track the copy will clone counts as empty (ArchiveLimits.copyIsClone, from volumeClonesCopy(from:to:): the source and the destination on one volume that supports cloning, and the source not still in the cloud),
- a file whose size cannot be read counts as empty, and
- a disk whose free space cannot be told is not checked.
The manifest and a later Ogg conversion's output are not counted, so the check is a lower bound, and the space is measured where the package is staged, not where it publishes.
The same rule is written out again in ArchiveBudget's admission of an archive, SpeechExportSpace, and LibraryViewModel+OggConversion's check, and a shared helper is a known follow-up.

## A folder with a DAISY book beneath it
<!-- id: folder-daisy-book-beneath-it; keys: nested DAISY, __MACOSX, symlink, Finder metadata, enumerator, subfolder; src: TextMouth/Services/FileImportService.swift, TextMouth/Parsers/DAISYParser.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Models/ImportProgressWording.swift -->

A folder with a DAISY book in a folder beneath it, at any depth, is no folder of tracks either, and throws FolderWithoutBookError too.
Here isFolderOfTracks is false when holdsDAISYBookBeneath finds a folder holding a DAISY book at its top level (DAISYParser.isDAISYDirectory), since such a folder is no book and its tracks belong to the books beneath it.
The search runs only once the folder is known to hold audio, and passes over hidden items, Finder's __MACOSX folder, and symbolic links.
Every walk of tracks (AudioBookParser.audioFiles, filesHeld, and holdsDAISYBookBeneath) calls skipFinderMetadataFolder, which skips only a real folder of that name.
NSDirectoryEnumerator.skipDescendants() on a file or a symbolic link skips the contents of the next folder listed beside it, so only a real folder is skipped, and MaintenanceFileAccess's walk of a package skips only folders for the same reason.
A book folder that is itself a symbolic link still scans as an error: isFolderOfTracks is false and filesHeld is 0.
The error's words (ImportProgressWording.noBookInFolder) list the files the folder holds at any depth, and do not say the books are inside it.

## A folder's original is never deleted
<!-- id: folder-original-never-deleted; keys: delete original, keep original, folder import, cover, lyrics, Move to Trash; src: TextMouth/Services/FileImportService.swift -->

A folder's original is never deleted.
ImportedBook.isFromFolder (once isFromPackageFolder, set only for a DAISY book copied from its folder) is set for both folder branches, the DAISY book's and importAudioFolderWithReport's, so mayDeleteOriginal is false for a folder of tracks too.
It holds files the import did not copy (a cover, lyrics, a Bonus folder), and is never deleted or offered for deletion.
FileImportService.deleteOriginalFile(at:) refuses a folder too, or a link to one (fileExists(atPath:isDirectory:) follows links), whatever its caller decided: it removes nothing, sends nothing to the Trash, and does not throw, since nothing failed; it writes one ORIGINAL_KEPT line.

## A file with no text to read
<!-- id: file-no-text-read; keys: empty file, blank book, empty Markdown, silent book, fuzz, whitespace only; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouthProductionTests/ImportFuzzTests.swift -->

A file with no text to read: FileImportError.noTextToRead ("This file has no text to read.") is thrown by FileImportService.readableContent(of:run:refusingBlankText:) when all of these hold:

- refusingBlankText is set,
- refusesBlankText(_:) holds for the book (formatsRefusedWhenBlank, under Refusals in [Imports: documents textutil reads](imports-textutil.md), which includes the Word documents), and
- no chapter of the generated content holds a character that is not white space.

Then the .readingText step fails and no silent, empty book is published.
Only importFileWithReport sets it, through publishReadableBook(_:from:run:feedLink:replacing:refusingBlankText:publish:), so Open Book, Finder, and the members of a ZIP (importSupportedFiles imports each through importFileWithReport) are refused.
New from Text, a feed's download, and every rebuild of an existing book's text are not refused.
The check is in readableContent and not in MarkdownCacheService, because every rebuild of an existing book's text goes through that, and a book already in the library must never become unreadable.
A Markdown file that is only a heading still imports.
ImportFuzzTests.knownIssues, which held the empty Markdown file the first sweep found, is empty.

## A full disk
<!-- id: full-disk; keys: ENOSPC, disk full, no space left, free space, disk quota; src: TextMouth/Services/ImportFailure.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift -->

A full disk: ImportFailure.isOutOfSpace(_:) says a volume is full when an error, or one it wraps under NSUnderlyingErrorKey at any depth, is Cocoa's NSFileWriteOutOfSpaceError or POSIX ENOSPC.
ImportFailure.outOfSpaceDescription ("There isn’t enough free space on the disk.") is then the failed step's reason in place of the system's own sentence, which names the hidden staged package (.import- followed by an ID and .tmb).
Both reason and reason(for:) word an error this way, so an alert, a ZIP batch's list of failures, the IMPORT_FAILED line, and a feed download's failure (FeedDownloadError.importFailed) say it alike.

## Pictures and comic book archives
<!-- id: pictures-comic-archives-import; keys: FMT34, PageImageReader, PageImageArchive, ComicInfo.xml, ImportPageProgress, BookFormat.picture, BookFormat.comic; src: TextMouth/Parsers/PageImageReader.swift, TextMouth/Parsers/PageImageReader+Formats.swift, TextMouth/Parsers/PageImageDecoder.swift, TextMouth/Parsers/PageImageArchive.swift, TextMouth/Parsers/PageImageText.swift, TextMouth/Models/PageImageWording.swift, TextMouth/Services/ImportPageProgress.swift, TextMouth/Models/Book.swift -->

Pictures of pages and comic book archives (FMT34) are the formats BookFormat.picture (png, jpg, jpeg, heic, heif, tif, tiff) and BookFormat.comic (cbz); their raw values "picture" and "comic" are new in 0.5.0, so an older TextMouth keeps their rows and hides the books.
- PageImageReader decodes each page within PageImageDecoding's limits and reads its text through VisionTextRecognition, the recognizer a scanned PDF's pages use (moved unchanged from PDFTextRecognizer).
  PageImageText turns the lines into paragraphs and the pages into chapters, a chapter for each page with text, each page a page marker (page reader 1.0.0 for the two formats only).
- Decoding runs in process, within limits: the kind is judged by the bytes (seven decoder kinds), and a declared size of more than 100 megapixels is refused before decoding.
  A page is decoded to at most 16 megapixels (4 on the iPhone, which reads a larger one at a fraction of its sides), and flattened onto white (onto black when nothing is found and it has transparency).
  EXIF orientation is applied.
  If a hang is ever seen, the fallback is to decode through sips under WatchedProcess.
- PageImageArchive lists a CBZ's pictures in the natural order of their paths, reads each into memory when its turn comes (an entry of at most 64 MB, checked against the archive's checksum, nothing extracted), and caps the book at 2,000 pages.
  PageImageComicInfo reads ComicInfo.xml (at most 1 MB, through the guarded XML parser): title, or series and number, writer, pages whose Type list includes Deleted (the Type is a white-space list), cover page titles, and bookmarks.
- The import is told the page count through ImportPageProgress.pagesRead(_:of:) after each page, which the overlay words "reading its text: 3 of 12 pages", and Cancel (ImportCancellation) stops before the next page.
  A page that can't be read leaves the others to be read, and the report names it (PageImageWording.pagesNotRead).
- A picture among other files is no book: Book.isBookAmongOtherFiles is false for BookFormat.picture, so a ZIP of books, an audiobook's tracks, or a DAISY archive passes it over, and a ZIP of only pictures imports nothing.
  A .cbz in a ZIP is a book.
- Not built: Photos on the iPhone, recognition in another language, a title from the first recognized line.
  A scanned PDF could report its pages and honour Cancel the same way (ImportPageProgress.pagesRead in PDFTextParser.extract).
