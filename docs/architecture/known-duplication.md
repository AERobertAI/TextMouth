# Known duplication
<!-- id: known-duplication; keys: duplicate code, repeated code, refactoring candidates, cleanup; src:  -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

Repeated code that is known and left for now, each with the reason:

## Singular and plural wording
<!-- id: singular-plural-wording; keys: pluralization, CountWording.phrase, plural noun, ternary, count == 1, message wording; src: TextMouth/Models/CountWording.swift, TextMouth/Services/FileImportService.swift, TextMouth/Services/LegacyBookMigration.swift, TextMouth/Services/PersistenceFailureCenter.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Models/RemovalWording.swift -->

More than a dozen messages still choose singular or plural inline, in FileImportService, LegacyBookMigration, PersistenceFailureCenter, LibraryViewModel+BookOperations, and AudioBookParser; they could use CountWording.
A few sentences deliberately drop the number for one ("Remove Book?", "the book inside") and do not fit it.

## Time remaining tally
<!-- id: time-remaining-tally; keys: summary bar, time left, LibraryInfoRow, LiveReadingPositions, reading time sum, unused code; src: TextMouth/ViewModels/TimeRemainingTally.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Views/Library/LibrarySubviews.swift -->

TimeRemainingTally (ViewModels/TimeRemainingTally.swift), which the Library's summary bar adds its list up with, repeats LibraryViewModel.totalTimeRemaining(books:wpm:) (ViewModels/LibraryViewModel+Migration.swift), which nothing calls at all, applying each book's live reading position first.

## PDF page readers
<!-- id: pdf-page-readers; keys: PDFKit, readPage, embeddedLines, plainLines, formattedLines, paragraph joiner, font size; src: TextMouth/Parsers/PDFTextParser.swift -->

PDFTextParser's two line readers, `plainLines(in:)` and `formattedLines(in:)`, which `embeddedLines(of:detectsHeadings:)` chooses between, share most of their loop, but record font sizes differently in ways that the paragraph joiner reads, so merging them would change some PDFs' paragraphs.

## VoiceOver focus searches
<!-- id: voiceover-focus-searches; keys: accessibility tree, NSView, focus trigger, VoiceOverFocus, initial focus; src: TextMouth/Platform/macOS/Views/VoiceOverFocus.swift -->

VoiceOverFocus.swift repeats its accessibility-tree searches (findElementByIdentifier and findFirstInteractiveElement) and its focus scheduling in StandardVoiceOverFocusTriggerView and VoiceOverFocusTriggerView.

## JSON encoder configuration
<!-- id: json-encoder-configuration; keys: JSONEncoder, prettyPrinted, sortedKeys, iso8601, withoutEscapingSlashes, library.json; src: TextMouth/Models/BookInfo.swift, TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/DataDirectoryMigrator.swift, TextMouth/Services/LibraryIdentity.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/LibraryPersistenceService.swift -->

Several stores configure their own JSON encoder with ISO 8601 dates and sorted, pretty output (bookInfo.json in BookInfo, RemovedFromLibraryMarker, ReadingStatsService, DataDirectoryMigrator, LibraryIdentity, LibrarySessionLease, and AudioEditHistoryStore, which also leaves slashes unescaped).
The files library.json (LibraryPersistenceService.encodedIndex(_:), whose keys are sorted so that equal libraries encode to equal bytes for the write-only-what-changed memory), contentIndex.json, and reading-checkpoints.json are written compact with sorted keys.
So sharing one encoder with the pretty ones would change those files' layouts.
DataDirectoryMigrator writes a moved library's library.json with its own pretty, sorted encoder rather than encodedIndex(_:), so the index stays pretty-printed after a move until the library is next saved.

## Coding keys of arbitrary names
<!-- id: any-coding-key; keys: AnyCodingKey, EntryKey, LibraryViewFileKey, CodingKey; src: TextMouth/Models/UnknownKeys.swift -->

AnyCodingKey (Models/UnknownKeys.swift) is a CodingKey for any name, as EntryKey and LibraryViewFileKey are for their files.

## Off-main work helpers
<!-- id: off-main-work-helpers; keys: DispatchQueue.global, withCheckedContinuation, background queue, blocking work, cloud download; src: TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/Services/StorageDestinationAssessment.swift -->

ReaderViewModel.offMain repeats OffMainWork.run: both run blocking work on a global dispatch queue and hand back its result.
Two cloud branches written side by side added them; the reader could call OffMainWork.

## Same-volume checks
<!-- id: same-volume-checks; keys: volumeIdentifierKey, same volume, rename or copy, scratch space, destination assessment; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Services/ImportScratchSpace.swift, TextMouth/Services/StorageDestinationAssessment.swift -->

Three functions compare two items' volume identifiers: ReaderWorkingCopies.isOnSameVolume, ImportScratchSpace.areOnSameVolume, which first climbs to the nearest folder that exists, and the live areOnOneVolume probe of StorageDestinationAssessment.
They could share one.

## Folder listing failure classes
<!-- id: folder-listing-failure-classes; keys: FileManager.enumerator, errorHandler, first error, directory enumeration; src: TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Services/DataDirectoryMigrator.swift -->

ListingFailure (Services/ReaderWorkingCopy.swift) and FolderListingFailure (Services/DataDirectoryMigrator.swift) are the same small class, keeping the first error a folder enumeration's handler meets; one could serve both.

## Cached audio folder
<!-- id: cached-audio-folder; keys: cachedAudio, unused code, package folder, tmb package; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService+Packages.swift -->

TextMouthPaths.cachedAudioDir(in:) names a per-package cachedAudio folder (TextMouthPaths.cachedAudioFolderName, which a package's import leaves out) that nothing in the app creates or reads.

## Frozen performance test oracles
<!-- id: frozen-performance-test-oracles; keys: golden tests, benchmark, baseline, oracle, legacy code, speech preparation; src: TextMouthProductionTests/TextPipelineFixtures.swift, TextMouthProductionTests/TextPipelineBenchmarkTests.swift, TextMouthProductionTests/SpeechPreparationSubstitutionTests.swift, TextMouthProductionTests/SpeechPreparationPauseAndSymbolTests.swift, TextMouthProductionTests/SpeechPreparationCacheTests.swift -->

The performance tests keep, verbatim, the code each change replaced, as the oracle and the baseline the new code is compared with.
Each speech-preparation test file keeps its own privately (legacyTransform, legacyPauses, legacyRuns, legacyPreparedSpeech), and the text pipeline's are kept once, in TextPipelineBefore (TextMouthProductionTests/TextPipelineFixtures.swift), for the golden tests and the benchmarks.
They are frozen on purpose and must not be changed to call the new code.

## Feed badge and book row badges
<!-- id: feed-badge-book-row-badges; keys: capsule, badge, status label, FeedRows, BookRow; src: TextMouth/Views/Feeds/FeedRows.swift, TextMouth/Views/Library/LibrarySubviews.swift -->

FeedBadge (Views/Feeds/FeedRows.swift) draws the same capsule that BookRow (Views/Library/LibrarySubviews.swift) draws inline for New and Now Reading: white words on a colored background, in the same font and padding.
The book row could use it.

## Library info speaker
<!-- id: library-info-speaker; keys: AVSpeechSynthesizer, Speak Info, utterance delegate, announcement voice, synthesizer; src: TextMouth/ViewModels/LibraryInfoSpeaker.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel.swift -->

LibraryInfoSpeaker (ViewModels/LibraryInfoSpeaker.swift) repeats the utterance Where Am I? makes (speakWhereAmI, in ViewModels/ReaderViewModel+WhereAmI.swift): the text guarded, the voice, SpeechService.rateForWPM, and prefersAssistiveTechnologySettings off.
It also repeats its handling of the end of one:
- finishes and cancels told apart by ReportedUtterance;
- a check that the one reported is the one speaking;
- and a synthesizer replaced when the engine refused it or a summary takes the place of one still speaking (its isLive(_:) and replaceSynthesizer() beside the reader's isLiveWhereAmIUtterance(_:) and replaceWhereAmISynthesizer()).

LibraryInfoSpeaker's LibraryInfoSpeechDelegate does what WhereAmIDelegateHelper (ViewModels/ReaderViewModel.swift) does.
One speaker of short announcements in the app's own voice could serve both.

## Elapsed time rounding
<!-- id: elapsed-time-rounding; keys: TimeFormatting, spoken time, timeOnBookStep, elapsedStep, import progress, download wait; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift -->

ImportProgressWording.timeOnBook(_:) (Models/ImportProgressWording.swift) counts the time on a book in whole 5-second steps, as ReaderCloudWording.elapsed(since:at:) (ViewModels/ReaderViewModel+CloudDownload.swift) counts a download's wait, so VoiceOver and a braille display don't churn.
One TimeFormatting helper could serve both (board #1460).

## Listing a folder without downloading
<!-- id: listing-folder-without-downloading; keys: contentsOfDirectory, cloud placeholder, FeedRecordAbsence, package listing; src: TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/Services/Feeds/FeedItemPackage.swift -->

FeedRecordAbsence's notesOfThisMac(in:) (ViewModels/LibraryViewModel+FeedDownloadReturn.swift) lists a folder without downloading anything, as FeedItemPackage.entryNames(of:) does; both could list through one helper.

## XML escaping
<!-- id: xml-escaping; keys: escape, ampersand, markup, attribute, PEF, apostrophe; src: TextMouth/Services/Export/XMLEscaping.swift, TextMouth/Services/BrailleFileWriter.swift, TextMouth/Services/Feeds/FeedTextConverter.swift, TextMouth/Services/Feeds/FeedOPML.swift, TextMouth/Parsers/SSMLReader.swift, TextMouth/Services/Feeds/FeedParser.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift -->

XMLEscaping (Services/Export/XMLEscaping.swift) escapes text for XML for every writer of it.
The feed, OPML, and SSML code use it:
- FeedOPML writes attributes with XMLEscaping.attribute, so it no longer writes &apos;;
- SSMLReader uses XMLEscaping.markup directly;
- FeedTextConverter.escaped stays as a one-line delegate to XMLEscaping.markup, since FeedParser, FeedEpisodeImporter, and test support call it, and it walks scalars, as a parser reads, where the old Character walk left a "&" with a combining accent raw.

One copy is left: BrailleFileWriter.escaped (Services/BrailleFileWriter.swift, for the PEF's head), which could use it (an open follow-up in the TODO, from team export).
The PEF's version leaves out a vertical tab or a form feed where XMLEscaping writes a space.
