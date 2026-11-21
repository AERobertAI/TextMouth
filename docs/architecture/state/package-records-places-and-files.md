# Package records: places, transcripts, origin, manifests
<!-- id: package-records-places-and-files; keys: package, tmb, transcript.json, origin.json, manifest; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Saved places' text anchors
<!-- id: saved-places-text-anchors; keys: saved position, relocate places, content.md rebuild, place moves; src: TextMouth/Models/TextAnchor.swift, TextMouth/Models/TextAnchorCapture.swift, TextMouth/Models/FineWords.swift, TextMouth/Models/TextAnchorFinder.swift, TextMouth/Models/PatienceDiff.swift, TextMouth/Models/PlaceRelocator.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift, TextMouth/Services/PlaceSnapshots.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/LibraryViewModel+TextAnchors.swift, TextMouth/ViewModels/LibraryViewModel+PlaceSnapshots.swift -->

Saved places' text anchors (T06, branches A to E): what a reading position, a bookmark, and a skipped heading keep of the text around them, so a place can be found again by its words when the book's text is read anew.
It also covers how the places follow their text: at every rebuild of it, every load of it, and every Edit Text edit.

### Who owns the anchors
<!-- id: who-owns-anchors; keys: anchor quote, context words, lenient decoding; src: TextMouth/Models/TextAnchor.swift, TextMouth/Models/Book.swift, TextMouth/Models/BookInfo.swift -->

Owner: the library row and the package record.
ReadingPosition.anchor and Bookmark.anchor are each a TextAnchor (Models/TextAnchor.swift).
It holds up to quoteLength, 64, UTF-16 units of the chapter's reading text before and after the place, cut on composed-character boundaries, a place inside a composed character counting as at its start.
It holds the place's share of the book, counted as Book.restsAtEnd counts a place, so an anchor captured at or past the book's total marks its end.
It holds the text cache's and content index's versions it was measured in (currentMeasure, as "3.0.7/1.0.0"), which nothing decides by, and its format version.
Book.skippedHeadings, and BookState.skippedHeadings in the record, hold a SkippedHeading for each skipped heading: its level, label, chapter, offset, and the anchor at its start.
Every field is read leniently, an anchor that can't be read counting as none, and written only when set, so a book with neither writes exactly what it wrote before.

### Who may write the anchors
<!-- id: who-may-write-anchors; keys: anchor capture, bookmark anchor, skip toggle, capture at load; src: TextMouth/Models/TextAnchorCapture.swift, TextMouth/Models/TextAnchor.swift, TextMouth/Models/Book.swift, TextMouth/Models/Library.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/ReaderViewModel+VoiceAndSpeed.swift, TextMouth/ViewModels/LibraryViewModel+Bookmarks.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/ViewModels/LibraryViewModel+TextAnchors.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Who may write it: ReaderViewModel.makeCurrentReadingPosition() gives every position its anchor (anchorToSave(at:)), keeping the opened place's saved anchor (openedPlaceAnchor) until the cursor moves.
Both bookmark adds pass one to LibraryViewModel.addBookmark and Library.addBookmark; toggleHeadingSkip saves SkippedHeadings with anchors through updateSkippedHeadings(bookID:headings:) and Book.setSkippedHeadings(_:), which writes skippedHeadingIDs from them.
Book.skippedHeadings is kept in step with skippedHeadingIDs, which older builds read: made from the IDs where a row or record has none, and following every change to them, keeping each still-named heading's anchor (SkippedHeading.inStep(with:keeping:)).
Places saved before anchors take theirs at load (captureMissingAnchorsAtLoad()) and in the launch pass captureMissingTextAnchors(access:then:), run by updateContentCachesAndStatistics after the metadata refresh and before the cache batch (TEXT_ANCHORS_BACKFILLED).
Both use CapturedPlaceAnchors.capturing and Book.adoptCapturedAnchors(_:), which gives words only to places still saved where they were read.
The pass reads each book's content.md off the main thread, writes nothing else, skips books only in the cloud, held by an Edit Text session, or open in a reader (they wait for a later launch), and changes no place's date and no lastOpened.
A place still saved past its chapter's end is quoted at that end.
A place in a chapter the book lacks, and a skipped heading whose ID names no current heading, get no words, since quoting where a skip's old place falls now could make it skip the wrong section.
An anchor's measuredIn is TextAnchor.measure(ofTextCachedBy:) of the content.md's recorded cache version, nil when the book records none.
DAISY text books (.daisy) take words like any text book; DAISY books with audio are audiobooks and keep places in time.

### How others observe the anchors
<!-- id: how-others-observe-anchors; keys: find place by words, fuzzy match, word hash, word matching, place recovery; src: TextMouth/Models/TextAnchor.swift, TextMouth/Models/TextAnchorFinder.swift, TextMouth/Models/FineWords.swift -->

How others observe it: TextAnchor.stands(at:in:) is the direct check, the anchor's text standing exactly around the saved numbers, compared unit for unit.
TextAnchorFinder (Models/TextAnchorFinder.swift), a pure Sendable value built once per book's text, off the main thread and only when a direct check fails, finds a place again by its words, read as fine words (FineWords and BookWords, Models/FineWords.swift).
Fine words are runs of letters or digits, ending where letters meet digits and where a small letter meets a capital, compared in lower case, each keyed by a 64-bit FNV-1a hash, the one word rule every way of finding a place shares.
It tries these, in order:

1. The end of the book stays the end.
2. The direct check.
3. Every spot where the first four words after the place, or the last four before it, stand, scored 2 for each word after that agrees, in order, and 1 for each word before, a candidate needing 8.
   Equal best spots are settled by nearness to where the place was, and a best spot far from it (more than 5% of the book, and more than 3,000 units) yields to a near one scoring 8 or more, both silent best guesses.
4. A tolerant second search, lining the quote's words up with the book's around every spot where three of them stand together.
5. Last, the same share of the place's chapter, at a word start, when the chapter's old length is known, or else its saved offset held within the chapter (for a chapter the book no longer has, its share of the whole book).

TextAnchorFinder.findHeading names a skipped heading only by the direct check, or when all the skip's saved words after the heading match from a heading's first word, within its chapter, with at least sectionProofWords (four) of them past the label, ties settled by the skip's label (REV16 F1).
Otherwise it returns nil so the skip waits.
Each result says how the place was found (TextAnchorFinder.Finding: unchanged, found, or guessed, with its reason).

### Moving places across a rebuilt text
<!-- id: moving-places-across-rebuilt-text; keys: relocation, waiting skip, bookmark move, text rebuild; src: TextMouth/Models/PlaceRelocator.swift, TextMouth/Models/PatienceDiff.swift, TextMouth/Models/TextAnchorFinder.swift, TextMouth/Models/FineWords.swift, TextMouth/Models/Book.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift -->

Moving them across a rebuilt text (T06, branch C): PlaceRelocator (pure, Sendable) moves a book's reading position, bookmarks, and skipped headings from its old text (the old content.md as this build reads it) to its new one.
It lines the two texts' fine words up once by a patience diff (PatienceDiff).
For each place it:

- keeps it when its anchor still stands or marks the end of the book (TextAnchorFinder.settled);
- finds it in the old text, at its numbers or else by its words;
- carries it by the diff's rules (solid matches, a place keeping the words that follow it, like-for-like stretches, removals slid back, moved text followed into text the diff found put in, the end to the end);
- else asks the saved-words search, then guesses silently.

A place goes to the new text's end only when it was at the old text's end (TextPlace.restsAtEnd, which Book.restsAtEnd also uses).
A place at its chapter's end stays at that chapter's end.
A place in a chapter without words goes to the matching chapter without words between its neighbours.
A reading position at the very start of the book stays at the start.
A place saved without words in a lost chapter is held as the reader opens it (TextPlace.opening, which ReaderViewModel.openingPlace also uses).
A skipped heading is found first in the old text: by the heading its ID names, else by its level and label when one old heading has them (of several, the one its saved words find for certain), else at its place where its saved words still stand exactly.
It is never found by saved words alone or at stale numbers.
That heading's start is carried like a place, and a new heading there takes the skip only on the diff's proof:

- no rival old heading that lent it words, or whose section continues in it, has a label more like it (or as like, with its own section continuing there instead), and
- its label is the skip's, or the skipped section continues in it, or most of the skipped heading's words went into it.

Among several, the label decides, then the level, so a re-levelled heading keeps its skip.
Failing that, the one new heading of its level with its label takes the skip unless the diff makes it another section; otherwise the skip waits, unchanged.
The relocator takes both texts' headings together, or neither (the initializers for places alone let every skip wait).
Its relocate(_:movedAt:) takes the time of the move, which a moved position takes as its date, and returns the places to save (anchors captured anew), how each was found, and the counts for the PLACES_RELOCATED line (Counts.logLine(title:)).
The findings and counts cover only the skips kept.
It shares BookWords.landing and TextAnchorFinder.settled and onlyBestSpot with the finder.

### Moving places when a rebuild writes the text
<!-- id: moving-places-when-rebuild-writes; keys: place snapshot, snapshot recovery, text cache rebuild, rebuild snapshot; src: TextMouth/Services/PlaceSnapshots.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Models/PlaceRelocator.swift, TextMouth/Models/Book.swift, TextMouth/Models/Book+OwnSettings.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/LibraryViewModel+PlaceSnapshots.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Moving them when a rebuild writes the text (T06, branch D): MarkdownCacheService.writeCache(for:) copies the old content.md and the book's places aside before it writes (PlaceSnapshot.keep, in MachineLocalPaths.placeSnapshots).
After writing it moves the places with PlaceSnapshot.movePlaces(to:at:), through PlaceRelocator.relocate(_:from:to:movedAt:), which builds a relocator only when some place does not stand.
Nothing is copied for a book with no places, one in an Edit Text session, one whose content.md is only in the cloud, or one whose new text is unchanged.
The moved places travel in GeneratedCache.movedPlaces and BookContentAnalysisService.Result.movedPlaces.
The batch, Redo Text Extraction, the statistics pass, a re-read in another encoding (readTextAgain, in [Kept texts, re-reads, and edited text](text-caches-rereads-edits.md)), and the reader commit them with LibraryPersistenceService.saveContentAnalysis(…movedPlaces:).
Book.takeMovedPlaces(original:moved:) guards them: it compares each place as stored (the record and the row keep dates to the second, so a place saved during the session would otherwise never equal its stored copy and silently not move).
It guards each place on its own, except the skip lists, which move as one because the relocator merges skips.
That save deletes the copy.
Library rows take them through ContentAnalysisSummary, which narrows them with MovedPlaces.taken(by:), and the reader in showLoadedContent by takeMovedPlaces(_:), in order with the moves of the next bullet.
The launch's recovery, finishLeftoverPlaceMoves, runs first in updateContentCachesAndStatistics and commits through saveMovedPlaces.
PlaceSnapshot lists the copies this run is still using, and the recovery skips them, so it never sweeps or takes one a reader's rebuild is still using (the test seam forgetCopiesInUse() empties the list, as a quit does).
A skipped heading the new text no longer has waits: Book.waitingSkippedHeadings and BookState.waitingSkippedHeadings hold it, a list of its own that no reader of skippedHeadingIDs sees, so it skips nothing (older builds drop the list, so for them the section plays).
It names a heading again only where that heading stands exactly as it was skipped, with saved words.
Waiting skips are not a book's own settings (Book.hasOwnSettings).
The debug log's lines are PLACES_NOT_KEPT, PLACES_NOT_MOVED, PLACES_RECOVERED, and PLACES_RELOCATED.
The recovery's finishPlaceMove gives the row moved.taken(by: committed), so a place the row changed meanwhile is kept (REV16 C1).
The next launch's recovery of a committed text cache (committedTextCache) reads the book's record once (BookContentAnalysisService.recoveredTextCache) and brings its moved places to the row through ContentAnalysisSummary(recovered:record:):

- the position only when the record's is at least as new,
- a bookmark only when nothing but its place and words differ,
- and the skips as one (REV16 C5).

### Moving places at every load and Edit Text edit
<!-- id: moving-places-at-every-load; keys: edit session, open cursor, load check, edit snapshot; src: TextMouth/Models/PlaceRelocator.swift, TextMouth/Models/FineWords.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/PlaceSnapshots.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+SavedPlaces.swift, TextMouth/ViewModels/ReaderViewModel+EditedText.swift, TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

Moving them at every load and at every Edit Text edit (T06, branch E): PlaceRelocator.relocate(_:within:movedAt:) checks the places at every load, with no old text, and returns nil when every place stands, by direct checks only.
Places nothing finds stay exactly as saved, numbers and words, so a later text that has the words again can find them (keepingPlacesNothingFound), and a skip with no saved words whose heading no longer exists waits, as it does at a rebuild.
ReaderViewModel.readContent runs the check off the main thread.
LoadedContent.movedPlaces is a list: the edit's moves, then a rebuild's, then the check's, which showLoadedContent takes in order through takeMovedPlaces(_:).
The check saves nothing on its own: the reader takes the moves into the row, and updateBook writes the row and the record, as any change is saved.
The row takes a move only as far as the record took it (MovedPlaces.taken(by:) puts each move the record refused back to its original, so a place another Mac or the listener saved meanwhile wins).
It also takes a move only where no reader is involved: the batch, the statistics pass, Edit Text's takes, and edits saved while closed.
A place saved without moving keeps its date (ReaderViewModel.savePosition(), durablePosition()), so an open never makes an old place the later one.
Which of two Macs' places stands is decided at the record's write and at the opening load (see [Package records](package-records.md)).

- The cursor: PlaceRelocator.relocate(_:from:to:) carries an open reader's cursor into edited text, on the main actor, once for each edit taken; the reader's own cursor wins over the saved position's move.
- Edit Text's copy: BookTextEditSessions.Session.oldText is the session's copy of the text as TextMouth last took or wrote it, with the book's places, in MachineLocalPaths.editTextSnapshots, a folder of its own because the recovery of placeSnapshots deletes any folder it cannot read.
  It is kept by keepOldText(of:) and replaced at each take through BookTextEdit.textAside; textRebuilt replaces it too, and end deletes it.
  The static check(…placesFrom:) moves the places when the copy's digest matches the baseline's cache digest, that is, when the copy's bytes are the text the places were saved in, and commits them with the analysis.
  A copy that does not match is not used, and nothing is copied for an audiobook. sweepLeftoverEditTexts(of:access:then:) keeps a copy whose book's content.md is only in the cloud (REV16 S1).
- Where the moves go: BookTextEdit.movedPlaces reaches the row, through ContentAnalysisSummary, and the readers, through LibraryBookUpdates.textReplaced(…movedPlaces:) and showEditedText(_:movedPlaces:).
  BookTextEditSettlement.readTaken carries the whole BookTextEdit.
  For an edit saved while TextMouth was closed, settleEditSavedWhileClosed uses the newest copy a quit left, and extractMissingContentCaches sweeps the rest.
- Shared rules: MovedPlaces.taken(by:), above, and TextPlace.isExactlyTheEnd, the one end-of-book rule.

## Transcripts
<!-- id: transcripts; keys: speech recognition, word timings, transcribe audiobook, transcript sentence, stale transcript, cleanup rules; src: TextMouth/Models/Transcript.swift, TextMouth/Models/TranscriptTextIndex.swift, TextMouth/Models/TranscriptCleanupRules.swift, TextMouth/Models/TextCacheFingerprint.swift, TextMouth/Models/BookContentIndex.swift, TextMouth/Models/BookInfo.swift, TextMouth/Models/Book.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Services/TranscriptInstallation.swift, TextMouth/Services/TranscriptDeletion.swift, TextMouth/Services/TranscriptEdit.swift, TextMouth/Services/TranscriptCleanupStore.swift, TextMouth/Services/TranscriptCleanup.swift, TextMouth/Services/TranscriptTextBuilder.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/StorageGeneration.swift, TextMouth/Services/SavedFile.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Parsers/MarkdownLiteral.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/ViewModels/TranscribedBooks.swift, TextMouth/ViewModels/LibraryBookUpdates.swift, TextMouth/ViewModels/ReaderViewModel.swift, TextMouth/ViewModels/ReaderViewModel+Transcript.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift -->

Transcripts (FR05): a transcribed audiobook's transcript.json, and the text written from it.

- Owner: the package. transcript.json (Transcript, in layout Transcript.currentVersion, 1) is a record, not a cache: only transcribing the book again replaces it, only Edit Text and a cleanup or its undo change it, and only Delete Transcript removes it.
  It is compact JSON with sorted keys and ISO 8601 dates, written atomically (TranscriptStore).
  It holds its layout version, the locale, the recognizer and its model (model: the engine, SpeechTranscriber, the asset status the system reported, and the macOS version), and the build of TextMouth (app: its version, build number, and commit).
  It holds when the transcription finished (createdAt, in whole seconds), and when the user last edited it (editedAt, in whole seconds, left out until then, so an earlier TextMouth reads an edited transcript as any other).
  Its last cleanup by rule is cleanedUp, a TranscriptCleanupNote: when, in whole seconds, the rules' version and date, whose rules they were ("built-in" or "user"), and how many corrections it made; it is left out until a cleanup.
  The source is kept as words so that a source a later TextMouth adds never keeps this one from reading the transcript.
  It holds files, one for each audio file in the order the book plays them.
  Each has its path as the book's audio index names it, its fingerprint (FileFingerprint: size, modification time in nanoseconds, and MD5 digest) taken just before it was transcribed, its duration in milliseconds, and its sentences.
  A sentence holds its text, its start and end, and its words, each an array of [UTF-16 offset in the sentence, UTF-16 length, start, end, confidence], the confidence to three decimals and left out when the recognizer gives none.
  Times are whole milliseconds from the start of their own file, so the recognizer's 60-millisecond steps stay exact.
  None lies beyond Transcript.maximumMilliseconds, 100 hours, and a file that says so is refused as damaged (validationFailure), so that no sum of times can overflow (the text builder's arithmetic is clamped for the same reason, and a bad offset is worded, never added).
  The text derived from it is a cache: content.md, which TranscriptTextBuilder writes, and the transcript layer of the book's content index.
  TranscriptTextBuilder writes each chapter's marker and heading, then paragraphs of at most four sentences or about 600 UTF-16 units, a pause of two seconds or more starting a new one.
  It escapes only as TextMouth's reader needs, by MarkdownLiteral.minimallyEscaped with smartPunctuation and guardingLineStart, where a text book's content.md has a backslash before every ASCII punctuation character.
  The layer is BookContentIndex.transcript, a BookContentTranscriptIndex, version BookContentTranscriptIndex.currentVersion, "1.1.0", raised from "1.0.0" with that escaping, so each transcribed book's text is written again once as it opens.
  It records the text's own index (as a text book's: chapters, headings, and counts), each chapter's sentences as [UTF-16 offset, length, start, end], in milliseconds of chapter time, and the audio files' fingerprints.
  It also records a TextCacheFingerprint with transcript.json as the source and content.md as the cache.
  The audio index itself is unchanged, so BookContentIndex.currentVersion, and every position and bookmark, which count time, stay as they were. bookInfo.json notes the transcript (BookState.transcript, a TranscriptNote: the layout version, the locale, and the date); library.json does not.
  Beside it, transcript.json.before-cleanup (TextMouthPaths.transcriptBeforeCleanupPath(in:)) holds the bytes of the transcript as it was before its last cleanup, for Undo Cleanup.

### Who may write a transcript
<!-- id: transcript-writers; keys: install transcript, cleanup, undo cleanup, delete transcript, TRANSCRIPT_TEXT_REBUILT; src: TextMouth/Services/TranscriptStore.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Services/TranscriptCleanupStore.swift, TextMouth/Services/TranscriptDeletion.swift -->

- Who may write it: TranscriptStore.install, which TranscriptionJobCenter runs off the main thread once the audio is transcribed (TranscriptionService.transcribeAndSave does both for the fixture tests), as storage work (StorageBoundary.perform(.textExtraction)).
  It checks that the book's audio is still the audio transcribed and that content.md is on this Mac (TranscriptTextLoader.requireTextOnThisMac).
  When content.md is only in the cloud, nothing is read, downloaded, or written, and TranscriptTextError.textOnlyInCloud is thrown, before transcript.json changes.
  It then reads the transcript the package holds (previous), writes transcript.json, writes content.md from it (TranscriptTextLoader.writeText), saves the index through LibraryPersistenceService.saveContentAnalysis, and drops the book's kept reading text.
  TranscriptTextLoader writes content.md and the layer again from transcript.json, as storage work, when either is missing, was changed, or was made by another version (TRANSCRIPT_TEXT_REBUILT), and tells the sessions of the text it wrote (BookTextEditSessions.textRebuilt).
  Before it replaces content.md, writeText(of:for:over:replacing:previous:hasher:isDataless:keepCopy:sessions:) keeps a content.md holding text TextMouth didn't write or take beside itself (BookTextEditSessions.keepCopy(of:bytes:), TEXT_EDIT_KEPT).
  It also keeps one that TextMouth wrote from an edited transcript but that reads differently from the text written from that transcript (unwrittenTextNeedsKeeping, which compares reading text, so escapes and paragraph breaks alone keep nothing).
  When that copy cannot be made it throws TranscriptTextError.textNotKept and leaves content.md as it is, as it leaves one only in the cloud (a rewrite so left is logged and tried again at the book's next open).
  TranscriptStore.takeEdit writes an edit of the text into transcript.json (see [Edited text](text-caches-rereads-edits.md)).
  TranscriptStore.cleanUp(_:expecting:with:from:now:hasher:) and undoCleanup(of:hasher:) (Services/TranscriptCleanupStore.swift) clean a transcript up by rule, and undo that, as storage work, for the Clean Up sheet (see [A transcript's cleanup](transcription.md)).
  A cleanup reads transcript.json with dataless files left in the cloud, and goes on only while it still holds the transcript the sheet previewed (TranscriptCleanupError.transcriptChanged) and the rules change something.
  It writes the bytes it read to transcript.json.before-cleanup, replacing an earlier copy.
  It rewrites each sentence a rule changed (TranscriptCleanup, through TranscriptSentence.rewrite(as:), which TranscriptEditing.apply shares), records cleanedUp, and installs the result as a transcription installs one (install).
  A cleanup that fails while transcript.json still holds what it read puts the earlier copy back, or removes the new one. undoCleanup installs the copy again, when the transcript records a cleanup and the copy can be used, then removes it.
  TranscriptStore.delete(for:), as storage work, removes transcript.json first, so a deletion cut short leaves no transcript to show, then the copy kept before a cleanup, content.md, and the kept reading text, and saves the audio index without its layer, which drops the record's note.
  The copies kept beside the files stay.
  The record's note follows the index each write carries, an import's included (Book.bookInfo(replacing:contentIndex:revisionFloor:), FileImportService.writeVerifiedRecord), and every other save keeps it.
- How others observe it: ReaderViewModel.readContent loads the text (TranscriptTextLoader.load) into DocumentContent.transcript (TranscriptText).
  It trusts it only when the layer validates against the audio index, transcript.json and content.md match their fingerprints, and the parsed content.md lines up with the layer's index.
  The text area shows the chapter's transcript around the sentence heard at the cursor's time (ReaderViewModel.shownText).
  Where Am I? quotes that sentence, at most its first 40 words (ReaderViewModel.heardTranscriptSentence, whereAmIQuoteWordLimit), found through the same conversion of the audio cursor (TranscriptText.sentence(atAudioOffset:inChapter:), which textOffset(atAudioOffset:inChapter:) goes through too).
  An audio file whose size or contents changed since transcription makes the transcript stale (TRANSCRIPT_STALE), and it shows no text; one only touched keeps it, its new stamp recorded.
  Before it calls a transcript stale, the load reads transcript.json again, in case another Mac has transcribed the changed audio meanwhile. transcript.json and content.md are never read while either is only in the cloud, and an audio file only in the cloud is taken on trust.
  When a book that has a transcript shows none of its text, the load says why, if it is a reason Search in Book names (Load.withheld, a TranscriptTextWithheld: transcriptInCloud, textInCloud, or audioChanged; the reader adds editHeld).
  A transcript.json that can't be used is preserved beside itself (SavedFile.preserveUnusable, TRANSCRIPT_FILE), and one of a later layout is left as it is, unread (TranscriptStore.Lookup.unsupportedVersion).
  TextMouthPaths.isTranscriptFile keeps transcript.json, the copy kept before a cleanup, and the preserved copies out of the candidates for the book's own file (FileImportService.isPackageContentName).
  A transcript saved, edited, cleaned up, or deleted, or a cleanup undone, reaches the book's readers through LibraryBookUpdates.transcriptReplaced, which ReaderViewModel.showTranscript(_:) shows as the book plays on, or once it has loaded.
  It reaches the library rows through TranscribedBooks (see [Which audiobooks are transcribed](transcription.md)).

## Recording origin record
<!-- id: recording-origin-record; keys: recorded book, audio recording, recorder; src: TextMouth/Models/BookOrigin.swift, TextMouth/Services/FileImportService+Recording.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioOriginalSweep.swift -->

A recording's origin record (FR04): origin.json, only in the package of a book recorded in TextMouth, and the original take it may name, original-take.caf.

- Owner: the package, apart from its record.
  origin.json (BookOrigin) holds the kind (recording), when recording started, the take's duration, and the microphone's name.
  It also holds the original take kept, if any, until the book's audio is first edited, when edits.json records it instead (see [The edit history](audio-edits.md)): its file name, when the book's audio was last made from it (lastEditedAt), and a policy of the book's own (policyOverride).
  It is pretty-printed with sorted keys and ISO 8601 dates.
  Earlier versions of TextMouth rewrite bookInfo.json and library.json without the fields they don't know, but leave a file they don't know alone, so the record survives them; no save of a book's state touches it.
- Who may write it: FileImportService.importRecording writes both files into the staged package once, as a recording is saved.
  Afterwards only AudioEditHistoryStore, under its lock: it records a policy of the book's own beside the take, strikes the take once edits.json records it, and clears originalTake once AudioOriginalSweep has deleted the take (see [The originals and the original policy](audio-edits.md)).
- How others observe it: BookOrigin.load(fromPackage:) never downloads, throwing only the refusal for a record only in the cloud, and a record that can't be read counts as none.
  FileImportService.isPackageContentName keeps both files out of the candidates for the book's own file.

## Book of tracks manifest
<!-- id: book-tracks-manifest; keys: manifest.json, audio tracks, edit session, track folder; src: TextMouth/Services/BookManifestEditing.swift, TextMouth/Models/TrackPlaces.swift, TextMouth/ViewModels/LibraryViewModel+ManifestEdits.swift -->

A book of tracks' manifest (FR17): BookManifestEditSessions checks each edited manifest on one serial queue as storage work, and a taken edit's index, with the transcript layer, and its moved places (TrackPlaces) are committed by saveContentAnalysis.
BookManifestFile.write is TextMouth's one write of a manifest, and tells an open session.
LibraryViewModel.setTitleAndAuthor(ofManifestBook:title:author:) is the one write of a book of tracks' title and author into the row and the manifest together, for a metadata editor's save.
A taken edit (commitManifestEdit) gives only the row the manifest's title and author (setRowTitleAndAuthor) and writes nothing back, since a write queued after the take would land on a save made meanwhile and erase it (Q16).

## Title or author a manifest is owed
<!-- id: title-author-manifest-owed; keys: manifest cloud, deferred write, manifest.json, title author sync; src: TextMouth/Services/BookManifestEditing.swift, TextMouth/ViewModels/LibraryViewModel+ManifestEdits.swift -->

A title or author a manifest is owed (FR17): when the manifest cannot take one now, because it is only in the cloud or is not one JSON object (the user is midway through an edit of it), the field is owed to it.
LibraryViewModel.setTitleAndAuthor gives the fields it changes to BookManifestEditSessions.settleOwedFields(of:adding:isDataless:), on the sessions' queue, the one place the record changes.
That writes the row's current title and author for each field owed (BookManifestFile.keepTitleAndAuthor), logging a failure as MANIFEST_NOT_WRITTEN unless it was a refusal to download.
It records what is still owed in ManifestOwedFields: nothing once BookManifestFile.holds(_:of:isDataless:) finds the manifest holding the row's values, which is also so for a book whose audio is no folder of tracks.
The fields are still owed while the folder or the manifest is only in the cloud, the folder is not there at all, there is no manifest, or it cannot be read.
A take adds nothing owed; a field already owed stays owed until a look or a retitle writes it.
ManifestOwedFields is an @unchecked Sendable struct over the preferences (the manifestOwedFields key: each book ID to the names of its owed fields, only title and author, never a title), one record for every library, so it is this Mac's alone and another Mac opening the library does not know it.
While a field is owed, the manifest's value for it is neither compared nor adopted: check passes owed to take, and look to manifest(_:at:arranges:as:tracks:showingPauses:owed:) and take, whose BookManifestEdit then carries no title or author for an owed field, so the row's value stands.

## Manifest edited outside a session
<!-- id: manifest-edited-outside-session; keys: manifest change detection, external edit, manifest.json; src: TextMouth/Services/BookManifestEditing.swift, TextMouth/Parsers/AudioManifest.swift, TextMouth/Platform/macOS/Services/BookManifestEditor.swift, TextMouth/Platform/iOS/Services/BookManifestEditor+iOS.swift -->

A manifest edited outside a session (FR18) is found by comparing it with the book, never by date: BookManifestEditSessions.look(at:showingPauses:owed:hasher:isDataless:) reads the record's index, the manifest, and the audio folder's listing.
It compares the manifest's AudioTrackPlan (track paths, and the headings' text, level, and chapter), title, author (each left out that is owed), and, for an open reader, pauses.
Each look begins with settleOwedFields(of:isDataless:), so the manifest holds what it is owed before it is compared.
A difference goes to the take FR17's check uses (take(_:manifestAt:digest:owed:)), on the same serial queue, as storage work.
A take reads every track, so look and check both wait while any track is only in the cloud (hasTrackOnlyInCloud(_:in:isDataless:), the tracks listed with downloading off).
The answer is .inCloud, nothing is taken or downloaded, check keeps its baseline so the next check tries again once the tracks are back, and BookManifestEditor.handle(_:for:) says nothing.
A book in a session is left to its session.
