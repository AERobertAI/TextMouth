# Shared helpers
<!-- id: shared-helpers; keys: utilities, reuse, duplication, shared code; src: -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

These small types each own one rule that several parts of the app follow; use them rather than writing the rule again.

## LibraryWindowRouter
<!-- id: librarywindowrouter; keys: multiple windows, window routing, app-wide command, Library window, scene; src: TextMouth/Services/LibraryWindowRouter.swift -->

LibraryWindowRouter (Services/LibraryWindowRouter.swift): decides which window takes each app-wide action.

## WindowCommandRouting
<!-- id: windowcommandrouting; keys: NotificationCenter, shortcut notification, focused window, multi-window; src: TextMouth/Views/Library/LibraryView.swift -->

WindowCommandRouting (Views/Library/LibraryView.swift): decides which of several open windows takes a menu command or keyboard shortcut posted as a notification: a shortcut goes to the window it was pressed in, a menu command to the key window, and a window not attached yet takes either.
Every Library window asks it through LibraryView's takesCommand(_:), and a reader, which counts its own sheets as itself, asks it too, as does an audio editor window's model for the editor's own shortcuts.

## LibraryBookUpdates
<!-- id: librarybookupdates; keys: observer, book changed, files moving, reader refresh, notification; src: TextMouth/ViewModels/LibraryBookUpdates.swift -->

LibraryBookUpdates (ViewModels/LibraryBookUpdates.swift): how open readers learn that the library changed their book or is moving its files.

## ReaderRequestStore
<!-- id: readerrequeststore; keys: pending request, claim once, expiry, search jump; src: TextMouth/Services/ReaderRequestStore.swift, TextMouth/Services/ReaderAutoplayRequests.swift, TextMouth/Services/ReadingListOpenRequests.swift -->

ReaderRequestStore (Services/ReaderRequestStore.swift): the one store of requests that wait for a book's reader: Continue to Next Book's (ReaderAutoplayRequests) and the reading list's (ReadingListOpenRequests).
Each is one for a book, claimed once, thrown away after 30 seconds unless the book's reader holds it while the book downloads, and dropped when the open it waits for is refused (ReaderOpenRefusal).

## LiveReadingPositions
<!-- id: livereadingpositions; keys: playback position, save position, cursor, library write; src: TextMouth/ViewModels/LiveReadingPositions.swift -->

LiveReadingPositions (ViewModels/LiveReadingPositions.swift): where readers are between checkpoints.
A live position goes there, never into the library, which takes a reader's position only at its checkpoints.

## ReaderSnapshot and SheetOverOneReader
<!-- id: readersnapshot-sheetoveronereader; keys: redraw, ObservableObject, SwiftUI, Equatable sheet, performance; src: TextMouth/Views/Reader/ReaderSnapshot.swift -->

ReaderSnapshot and SheetOverOneReader (Views/Reader/ReaderSnapshot.swift): what a view shows of its reader, republished only when it changes, and sheets that compare equal while they show the same reader.
A view over a playing reader observes a snapshot, never the whole reader.

## TextCacheFingerprint
<!-- id: textcachefingerprint; keys: cache validity, stale cache, file size, modification date, Codable; src: TextMouth/Models/TextCacheFingerprint.swift -->

TextCacheFingerprint (Models/TextCacheFingerprint.swift): what a text cache was written from, checked by size and date before any file is read.

## Chapter marker in content.md
<!-- id: chapter-marker-content-md; keys: chapter heading, heading line, cache writer, transcript text; src: TextMouth/Services/MarkdownCacheService.swift -->

MarkdownCacheService.chapterMarker(title:) (Services/MarkdownCacheService.swift): the line that starts a chapter in content.md, which EPUB extraction and a transcript's text both write.

## MarkdownLiteral
<!-- id: markdownliteral; keys: escaping, literal text, Markdown injection; src: TextMouth/Parsers/MarkdownLiteral.swift, TextMouth/Parsers/MarkdownEmphasis.swift, TextMouth/Parsers/PlainTextParser.swift, TextMouth/Parsers/HTMLToMarkdownConverter.swift, TextMouth/Services/Export/MarkdownExportWriter.swift, TextMouth/Services/TranscriptTextBuilder.swift -->

MarkdownLiteral (Parsers/MarkdownLiteral.swift): the one place text is written as literal Markdown.
MarkdownLiteral.escaped(_:) puts a backslash before every ASCII punctuation character, the form every content.md writer uses so that TextMouth's reader reads exactly a book's characters.
The writers that use it are PlainTextParser, HTMLToMarkdownConverter, the DOCX and DAISY converters, and the braille reader through MarkdownEmphasis.
MarkdownLiteral.minimallyEscaped(_:smartPunctuation:) puts one only where a Markdown reader needs it, and guardingLineStart(_:) adds the one a line's start needs.
With smartPunctuation, which TextMouth's own reader needs, quotes and doubled hyphens or periods are escaped too.
The export's Markdown (MarkdownExportWriter) writes without it, and a transcript's content.md (TranscriptTextBuilder.markdown) with it.
MarkdownEmphasis.markdown(_:styles:literal:) takes the writer for each stretch between delimiters, MarkdownLiteral.escaped unless the caller gives its own.

## Soft hyphens left out of a book's words
<!-- id: soft-hyphens-left-out-book; keys: shy entity, line break, braille dots 3-6, speech hyphen, discretionary hyphen; src: TextMouth/Parsers/ParserUtilities.swift, TextMouthProductionTests/SoftHyphenEffectTests.swift -->

ParserUtilities.removingSoftHyphens(_:) (Parsers/ParserUtilities.swift): the one place a soft hyphen (U+00AD) is left out of a book's words.
The Kindle readers call it, for a KF8 book's markup and its contents' labels, and for a MOBI 6 book's markup, labels, and plain text (see [Imports: Kindle books](state/imports-kindle.md)).
The EPUB reader does not call it.
A publisher puts soft hyphens inside words to say where a line may break.

- The spellings it catches, in the text it is given, which is markup that SwiftSoup decodes afterwards:
  - the character itself, U+00AD;
  - `&shy;` in lower case, and `&shy` with no semicolon when no ASCII letter or digit follows it, which SwiftSoup decodes too;
  - `&#173;` and `&#xAD;`, with `x` in either case, with or without the semicolon, and with any number of leading zeros.
    The number's value is judged, capped while its digits are read, and not its length.
- The spellings it leaves alone, since the parser keeps them as text: `&SHY;` and `&Shy;` (HTML has no such entity), `&shy1` and `&shyx` (a letter or digit follows), and any other number.
- A text with no soft hyphen costs one scan and no copy.
- Measured, a soft hyphen left in a word:
  - hid the word from Search in Book: `hyphenation` did not find `hy\u{AD}phenation`, literal or as a regular expression (`SoftHyphenEffectTests`);
  - became a visible hyphen in braille, dots 3-6, with the rest of the word unchanged where no contraction spans the cut, in UEB grades 1 and 2 (`SoftHyphenEffectTests`); a cut inside a contraction was not measured;
  - was spoken as the hyphen it is taken for: the speech engine rendered exactly the frames a hyphen-minus gives, 2.2% and 5.8% more than the same words whole, in two sentences with compact Samantha (`Scripts/agents/probes/speech-soft-hyphen-probe.swift`, with its results at the end of the file).
    Nothing was played.
- Known gap: `&shy` directly followed by `=`, `-`, `_`, `#`, or `&` is removed by the helper, while SwiftSoup would keep it as text (`a&shy=b` becomes `a=b`).
  The check found 43 such strings in 60,000 random ones, and no real book writes this.
- Not decided: the EPUB reader keeps soft hyphens, and they do the same there.
  The EPUB samples hold none.

## TranscriptText
<!-- id: transcripttext; keys: sentence index, time to place, transcript lookup; src: TextMouth/Models/TranscriptTextIndex.swift -->

TranscriptText (Models/TranscriptTextIndex.swift): a transcribed audiobook's text with its timing, sentence by sentence: the sentence heard at a time, the place in the text for a time and the time for a place, and so the reader's audio cursor converted both ways.
Search in Book, Where Am I?, and anything else that follows the narration in the text should use it rather than converting time again.

## TranscriptSentence.rewrite
<!-- id: transcriptsentence-rewrite; keys: edit transcript, word timings, clean up, retime; src: TextMouth/Models/Transcript.swift, TextMouth/Services/TranscriptEdit.swift, TextMouth/Services/TranscriptCleanup.swift -->

TranscriptSentence.rewrite(as:) (Models/Transcript.swift): a transcript's sentence given new text, keeping its time in the audio and dropping its words' timings, which no longer fit.
An edit in the user's editor (TranscriptEditing.apply) and a cleanup (TranscriptCleanup) both rewrite sentences through it.

## TranscriptAccuracy
<!-- id: transcriptaccuracy; keys: word error rate, WER, read-aloud match; src: TextMouth/Services/TranscriptAccuracy.swift, TextMouth/Services/TranscriptEditAlignment.swift -->

TranscriptAccuracy (Services/TranscriptAccuracy.swift): a transcript aligned word by word with the text that was read aloud:
- its words compared as the edit alignment compares them (TranscriptEditAlignment.key(of:)), with every apostrophe read as one;
- the differences sorted into the kinds of mistake a recognizer makes;
- its confidence weighed against them;
- and the corrections that would have been right in every place they apply.
It is in the app rather than the tests so that later work, such as learning rules from the user's own edits, can use it.

## RowNoteBadge
<!-- id: rownotebadge; keys: hidden image, row accessory, VoiceOver label, capsule; src: TextMouth/Views/Library/BookCloudNote.swift -->

RowNoteBadge (Views/Library/BookCloudNote.swift): the outlined badge a library row's notes are drawn in, its cloud notes and its transcription note, with a picture hidden from VoiceOver, which only repeats the words.

## PersistenceFailureCenter
<!-- id: persistencefailurecenter; keys: save failure, error alert, write error, disk full; src: TextMouth/Services/PersistenceFailureCenter.swift -->

PersistenceFailureCenter (Services/PersistenceFailureCenter.swift): where every failed save is reported and settled.

## ImportStaging
<!-- id: importstaging; keys: atomic publish, package build, temporary folder, half-written package; src: TextMouth/Services/ImportStaging.swift -->

ImportStaging (Services/ImportStaging.swift): builds a package out of sight and publishes it with one rename.

## Managed package names in a row
<!-- id: managed-package-names-row; keys: package name, package directory, symbolic link, book folder; src: TextMouth/Services/FileImportService.swift, TextMouth/Models/Book.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/ViewModels/LibraryListCache.swift, TextMouth/ViewModels/LibraryViewModel+Feeds.swift -->

FileImportService.namesManagedPackage(_:) (Services/FileImportService.swift): whether a row names a package the library manages, by the package's name and folder.
It is the one check that the deletion guard, the first launch's move of feed downloads, Move to Library…, and the return of a gone feed's downloads share.
Book.FileLocation.packageDirectory(inDataDirectory:) (Models/Book.swift): where a row's package is, the one package rule, which Book.packageDirectory(inDataDirectory:) and the audio editor's AudioBookPlace follow.
FileImportService.isManagedPackageName(_:) and isSymbolicLink(_:) are the check's parts, which a feed item's own check shares (FeedItemPackage.isPackageName(_:) and packageForRemoval(of:in:)).
TextMouthPaths.bookInfoFileName and contentMarkdownFileName name a package's record and text.
LibraryListCache.index(of:) gives each book's place in a list by ID, the first of an ID winning, for the list cache and the feed rows' lookup (FeedItemRowLookup) alike.

## Audio edit history store and package
<!-- id: audio-edit-history-store-package; keys: audio editor, undo history, revision log, mutex; src: TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioEditPackage.swift -->

AudioEditHistoryStore and AudioEditPackage (Services/AudioEditing/):
- the one way to change a book's audio edit history, under one lock for the whole process;
- and where a package keeps that history, its originals, and its takes, with the one check that a path a history records stays inside the package.

## Data directory migrator and location
<!-- id: data-directory-migrator-location; keys: move library, copy and rename, symlink, relocate, storage move; src: TextMouth/Services/DataDirectoryMigrator.swift -->

DataDirectoryMigrator and DataDirectoryLocation (Services/DataDirectoryMigrator.swift): copy a whole data directory out of sight and publish it with one rename, and take a location as the real folder its links lead to.
SaveTemporaryNames, in the same file, says which names are a save's temporary file, so the copy leaves them out ([Copying and publishing](state/data-directory.md)).

## StorageBoundary and StorageGeneration
<!-- id: storageboundary-storagegeneration; keys: write fence, move publication, stale writes; src: TextMouth/Services/StorageGeneration.swift -->

StorageBoundary and StorageGeneration (Services/StorageGeneration.swift): where the data directory is now, and the boundary that keeps the work writing into it from running across a move's publication.

## Storage destination assessment and wording
<!-- id: storage-destination-assessment-wording; keys: choose folder, iCloud, volume, free space, storage settings; src: TextMouth/Services/StorageDestinationAssessment.swift -->

StorageDestinationAssessment, StorageChoice, and StorageWording (Services/StorageDestinationAssessment.swift): what a folder chosen for the library can become, judged from metadata alone, and the words that offer it.

## Data directory move progress and wording
<!-- id: data-directory-move-progress-wording; keys: move sheet, VoiceOver progress, observable, percent done; src: TextMouth/ViewModels/DataDirectoryMoveProgress.swift -->

DataDirectoryMoveProgress and DataDirectoryMoveWording (ViewModels/DataDirectoryMoveProgress.swift): a move under way, with its Cancel, as every Library window's sheet, Storage settings, and VoiceOver present it.

## OffMainWork
<!-- id: offmainwork; keys: background queue, blocking IO, DispatchQueue, network drive, hang; src: TextMouth/Services/StorageDestinationAssessment.swift -->

OffMainWork (Services/StorageDestinationAssessment.swift): runs blocking work, such as reading or copying a folder that can wait on a drive or the network, on a background dispatch queue, and hands back its result without holding the main actor.

## Archive extraction, budget, and reader
<!-- id: archive-extraction-budget-reader; keys: zip bomb, entry limit, size budget, central directory, unzip; src: TextMouth/Parsers/ArchiveEntryReader.swift, TextMouth/Services/ArchiveBudget.swift, TextMouth/Services/ArchiveExtraction.swift -->

ArchiveExtractor, ArchiveBudget, ArchiveEntryReader, and IndexedArchive (Services/ArchiveExtraction.swift, Services/ArchiveBudget.swift, Parsers/ArchiveEntryReader.swift): bounded, cancellable ZIP extraction, the one way to read an archive entry, and the one way to find many entries.

## ImportScratchSpace
<!-- id: importscratchspace; keys: temporary folder, staging, import temp, caches; src: TextMouth/Services/ImportScratchSpace.swift -->

ImportScratchSpace (Services/ImportScratchSpace.swift): where imports stage packages and extract archives, on this Mac or beside the library.

## SettingsPolicy
<!-- id: settingspolicy; keys: validated preferences, defaults, clamp, range, setting limits; src: TextMouth/Models/SettingsPolicy.swift -->

SettingsPolicy (Models/SettingsPolicy.swift): the table of every validated preference.

## StoredPreference and PreferenceObserver
<!-- id: storedpreference-preferenceobserver; keys: UserDefaults, preference key, KVO, settings change; src: TextMouth/Models/StoredPreference.swift -->

StoredPreference and PreferenceObserver (Models/StoredPreference.swift): one definition of each preference's key and stored form, and notice of its changes.

## Key names and accessible key display
<!-- id: key-names-accessible-key-display; keys: keyboard shortcut, key name, spoken shortcut; src: TextMouth/Models/KeyboardShortcut.swift -->

KeyBinding.keyNames and KeyBinding.accessibleDisplayString (Models/KeyboardShortcut.swift): the one table of named keys, with each key's words, what the screen shows, and config.json's name, and a shortcut in words, single or double.
The Shortcuts tab, its announcements, the audio editor's hints, and config.json all read them.
Say or write a key through them rather than naming it again.

## VoiceOverAnnouncer
<!-- id: voiceoverannouncer; keys: accessibility post, speech after sheet closes, VoiceOver speech; src: TextMouth/Services/VoiceOverAnnouncer.swift -->

VoiceOverAnnouncer (Services/VoiceOverAnnouncer.swift): every VoiceOver announcement, recorded instead under tests.
VoiceOverAnnouncer.announceAfterSheetCloses(_:from:), and AnnouncementAfterSheet for a sheet's owner, say what a sheet's work did VoiceOverAnnouncer.afterSheetDelay, 0.6 seconds, after the sheet closes, so the closing never cuts it off (REV11 F6).
A subscription, the Move sheet's note of the items it left, Move to Library…, and the Remove question's Delete Download use them.
The feed's own confirmations, Unsubscribe's, Delete Episode's, and Delete Feed's, wait the same way through afterSheetCloses(_:), as does the feed downloads section's Cancel, which moves VoiceOver's focus to the list first and speaks after it (REV13 items 1 and 3).

## Sheet focus marker
<!-- id: sheet-focus-marker; keys: focus state, accessibility focus, FocusState, defaultFocus; src: TextMouth/Views/Transcription/TranscriptionSheet.swift -->

focusing(_:first:_:) (Views/Transcription/TranscriptionSheet.swift): marks a sheet's control that takes keyboard focus while the sheet's focus is on it, and that VoiceOver moves to once when it becomes the sheet's first control.
The Transcribe Audio sheet and the Clean Up sheet both mark theirs with it.

## VoiceCatalog
<!-- id: voicecatalog; keys: AVSpeechSynthesisVoice, voice list, voice picker; src: TextMouth/Services/VoiceCatalog.swift -->

VoiceCatalog (Services/VoiceCatalog.swift): the installed voices, listed once off the main thread and again when the system's voices change.
Offer its list rather than asking the system for the voices.

## SpeechMarkupGuard
<!-- id: speechmarkupguard; keys: SSML, angle brackets, UTF-16 offset; src: TextMouth/Services/SpeechMarkupGuard.swift -->

SpeechMarkupGuard (Services/SpeechMarkupGuard.swift): makes tag-shaped text, and the NUL character, harmless to the speech engine at the same UTF-16 length, so an offset into the guarded text is an offset into the original.
Every utterance made from a book's text, or quoting a book, as Where Am I? and Speak Info do, goes through it.
SpeechMarkupGuard.neutralizedStrictly(_:) silences every bracket, tag-shaped or not, and neutralized(_:strictlyWithin:) does so within a range of a text, for the rest of a chunk the engine refused; neither touches the ampersand.

## TextMouthRuntime
<!-- id: textmouthruntime; keys: test isolation, data directory, XCTest, user data; src: TextMouth/App/TextMouthRuntime.swift -->

TextMouthRuntime (App/TextMouthRuntime.swift): the one switch that keeps hosted tests away from the user's data, and the sandbox it gives each test process instead, deleted when the process is done with it.

## ViewBodyCounter
<!-- id: viewbodycounter; keys: redraw count, body evaluation, SwiftUI, view invalidation, performance tests; src: TextMouth/Views/ViewBodyCounter.swift -->

ViewBodyCounter (Views/ViewBodyCounter.swift): how many times a view's body ran, counted in Debug builds for the tests that check what a change redraws.

## DatalessFiles
<!-- id: datalessfiles; keys: iCloud, file provider, evicted file, cloud-only; src: TextMouth/Models/CloudStorageContract.swift -->

DatalessFiles (Models/CloudStorageContract.swift): whether a file's content is only in the cloud, and running work that must never download with dataless files left there.

## LibraryIndexQuarantine
<!-- id: libraryindexquarantine; keys: corrupt file, copy aside, backup, library.json, recovery, undecodable; src: TextMouth/Services/LibraryIndexQuarantine.swift, TextMouth/Services/SavedFile.swift -->

LibraryIndexQuarantine (Services/LibraryIndexQuarantine.swift): keeps a file beside itself, never changing the original, under a name marker of the caller's own: .unreadable- for the stores and transcript.json and .edited- for Edit Text's copies of content.md.
It uses an earlier copy of the same bytes again.
SavedFile.preserveUnusable reaches it with dataless files left in the cloud.

## SavedFile
<!-- id: savedfile; keys: atomic write, unchanged bytes, skip write, cloud sync; src: TextMouth/Services/SavedFile.swift -->

SavedFile (Services/SavedFile.swift): reads a small file that TextMouth reads whole and replaces whole, one another Mac writes too or one of this Mac's own, with dataless files left in the cloud.
It tells a missing file, one only in the cloud, and one that can't be read apart, and preserves one that can't be used before anything replaces it.
SavedFile.renameReplacing(_:_:) is the one rename(2) helper, which puts a file in place of another in one step: the log writer's rotation, the reading-text cache, and a filtered audio render's result use it.
SavedFile.OnDiskMemory is the one memory of what this process last read or wrote of some files in one data directory (holds(_:for:at:), remember(_:for:), write(_:for:using:), forget(_:), startOver(unlessIn:)), so a save writes a file only when its freshly encoded bytes differ.
The file library.json and each feed's index use it (see [The library index](state/library-index.md)).
A write goes through write(_:for:using:), which runs it and remembers the bytes only when it succeeds.
When it throws, it forgets what was remembered of the file, since a rename on a network volume can land and still report failure, so the file's state is unknown.
A later save, an undo to the older bytes included, then writes instead of being skipped as unchanged.
OnDiskMemory.remember(_:for:) is for bytes just read, or known to be what the file holds.
The caller must encode the same content to the same bytes, with sorted keys and a fixed row order, and confine the value to the queue it reads and writes on, since it does no locking of its own.

## MachineLocalPaths
<!-- id: machinelocalpaths; keys: not synced, iCloud, local folder, working copy; src: TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/AudioEditing/AudioEditComposition.swift, TextMouth/Services/AudioEditing/AudioEditCaches.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/RecordingTake.swift -->

MachineLocalPaths (Models/CloudStorageContract.swift): this Mac's own folders, which never sync:
- its Logs folder;
- the working copies;
- import staging;
- archive extraction;
- the takes being recorded (MachineLocalPaths.recordings, in Services/RecordingTake.swift);
- the feeds' downloads waiting to be imported (MachineLocalPaths.feedDownloads, in Services/Feeds/FeedStore.swift);
- and, in its Caches folder:
  - the kept reading text;
  - the feeds' fetch details and resume data;
  - the braille tables unpacked from the pack at first use (MachineLocalPaths.brailleTables, a folder for each liblouis version);
  - audio editing's scratch folders (AudioEditScratch, in Services/AudioEditing/AudioEditComposition.swift);
  - and the audio editor's clips (AudioEditCaches.clipsRoot, in Services/AudioEditing/AudioEditCaches.swift).

## NetworkReachability
<!-- id: networkreachability; keys: offline, expensive network, data limits, constrained; src: TextMouth/Services/NetworkReachability.swift -->

NetworkReachability (Services/NetworkReachability.swift): whether this Mac is online, from one NWPathMonitor, or a test's answer.

## MaintenanceFileAccess
<!-- id: maintenancefileaccess; keys: launch maintenance, cloud file check, no download, startup scan, dataless; src: TextMouth/Services/MaintenanceFileAccess.swift -->

MaintenanceFileAccess (Services/MaintenanceFileAccess.swift): how maintenance asks whether a book's files are in the cloud, and reads them without downloading.

## DiagnosticLog
<!-- id: diagnosticlog; keys: logging, privacy, no titles, log level, redaction; src: TextMouth/Services/DiagnosticLog.swift -->

DiagnosticLog (Services/DiagnosticLog.swift): what a log line may say, and which lines are written.

## LogWriter and the log destination
<!-- id: logwriter-log-destination; keys: rotation, Logs folder, log location, logging setting; src: TextMouth/Services/LogWriter.swift, TextMouth/Services/TextMouthPaths.swift -->

LogWriter and TextMouthPaths.logDestination (Services/LogWriter.swift, Services/TextMouthPaths.swift): the one writer of log files, and the one place that decides each line's folder.

## BookTextSearch
<!-- id: booktextsearch; keys: regular expression, canonical equivalence, find; src: TextMouth/Services/TextSearch/BookTextSearch.swift, TextMouth/App/BuildIdentity.swift, TextMouth/Services/ReadingTextCache.swift, TextMouth/Services/TextSearch/LibrarySearchText.swift -->

BookTextSearch (Services/TextSearch/BookTextSearch.swift): the one matcher of Search in Book and Search Library (BookTextSearch.Matcher), the one context function (contextSnippet, 30 characters each side), and TextSearchOptions (matchCase, isRegularExpression).
The matcher is NSString's range(of:options:range:) with .caseInsensitive, or none for Match Case, never .literal, so canonically equivalent spellings match; or an NSRegularExpression, case-insensitive unless case must match.
Matcher.regexMatch(at:in:) is one attempt anchored at a place ([.anchored, .withTransparentBounds, .withoutAnchoringBounds]), which the reader uses to check where a library search's match is.
BuildIdentity.cacheProducer (App/BuildIdentity.swift) is the description of the build, version, build number, commit, and date, that ReadingTextCache and LibrarySearchTextStore both key on.

## XMLEscaping
<!-- id: xmlescaping; keys: ampersand, EPUB export, entity, markup injection; src: TextMouth/Services/Export/XMLEscaping.swift -->

XMLEscaping (Services/Export/XMLEscaping.swift): the one escaper of XML text.
XMLEscaping.text(_:) is for an element's content.
XMLEscaping.attribute(_:) is for a double-quoted attribute whose line breaks must read back (tab, line feed, and carriage return as character references).
XMLEscaping.markup(_:) is for markup that an HTML or XML parser reads, in content or in a double-quoted attribute where a tab or line break may stay: it does what text(_:) does, and writes " as &quot;.
Every character XML 1.0 forbids is left out, but a vertical tab and a form feed, which are white space and each become a space, so the words they kept apart stay apart; it walks scalars, as a parser reads.
The feed, OPML, SSML, and export writers use it (see [Known duplication](known-duplication.md) for the one copy left).

## MarkdownNesting
<!-- id: markdownnesting; keys: block quote depth, list depth, stack overflow, nested lists; src: TextMouth/Parsers/MarkdownNesting.swift, TextMouth/Parsers/MarkupGuard.swift, TextMouth/Parsers/MarkdownParser.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/Export/ExportDocumentWalker.swift, TextMouth/Parsers/MarkdownTree.swift, TextMouth/Models/MarkdownNestingWording.swift -->

MarkdownNesting (Parsers/MarkdownNesting.swift) is the first layer of the guard on Markdown's nesting: one linear pass over a Markdown text's bytes that finds how deep its block quotes and lists can nest:
- a `>` opens a quote, a list marker a list item, a marker after another on the line a list inside it, each two columns of white space before a quote or marker one more level, a tab four;
- the white space after a `>` or a marker is not counted;
- a thematic break such as `* * *` opens nothing;
- lines in code fences count like any other.

The count is never less than the tree's real depth in block containers and stops as soon as it passes the limit.
MarkdownDocParser.parseChapter:
- refuses past MarkupGuard.limits.deepestNesting (128) with MarkupRefusal.nestedTooDeeply, the sentence the HTML guard gives, before anything is built;
- and then parses, walks, and releases the tree on MarkupGuard.onLargeStack, the walk stopping at the limit on the tree (PlainTextExtractor.deepestTree: Limits.deepestTree when set, else twice deepestNesting and 16, 272 levels).

A marker line's rest, which is parsed again, is counted first.
Every caller goes through parseChapter: BookParser's .md and .txt, EPUB, MOBI, DOCX, DAISY, and content.md.
Markdown is parsed with cmark-gfm directly (MarkdownTree), which the reader's walk and ExportDocumentWalker both read.
ExportDocumentWalker holds the same limit, through MarkdownTree.read(_:within:insideLevel:_:), so that one limit serves every walk:
- a text whose quotes and lists pass 128 is refused before anything is parsed, and a tree deeper than 272 levels, which inline emphasis, links, and images also make, is refused before the walk begins, measured with cmark's iterator (MarkdownNode.levels(stopAbove:)), which does not recurse;
- a table's body rows count one level more, as the reader counts them, which levels(stopAbove:) and PlainTextExtractor.readTable each do, and MarkdownDepthLimitTests pins together;
- a marker line's rest is counted on top of its HTML block's level (insideLevel), as the reader counts it;
- the walk runs on MarkupGuard.onLargeStack, whose stack holds a tree at the limit however small the stack of the thread that asks;
- the refusal is ExportWalkError.nestedTooDeeply(chapter:limit:), naming the chapter by its number, and the phrase of its sentence and of Edit Text's is one, MarkdownNestingWording.nestsTooDeeply(limit:).
Because the count includes lines in code fences and every two columns of indentation, a code line of 129 `>` or of 258 spaces before `- ` blocks an export and an edit too, which is the cost of one limit.

## AsyncBridge
<!-- id: asyncbridge; keys: semaphore, timeout, synchronous wait, Task.detached, priority inversion, audio tags; src: TextMouth/Services/AsyncBridge.swift, TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Parsers/BookParser.swift, TextMouth/Services/BookContentAnalysisService.swift -->

AsyncBridge (Services/AsyncBridge.swift): lets synchronous parsing and analysis wait for async work, such as reading audio through AVFoundation.
The work runs at the waiter's priority or .medium, whichever is higher (waitPriority(for:)), so no thread waits on work of lower priority (#1581).
waitForResult(timeLimit:cancelledBy:of:) ends the wait after a limit (ST07):
- the detached task is cancelled, so work that follows cancellation ends, and work that ignores it finishes on its own and stores its late result where nobody reads it;
- TimeLimitExceeded is thrown ("Reading the audio took longer than 5 minutes, so TextMouth stopped waiting for it.");
- and ASYNC_TIME_LIMIT is logged, naming no file or title.

Reading an audio file's tags has AsyncBridge.audioTagsTimeLimit (30 seconds; the import's and the reader's try? fall back to empty tags, and Book Info's LibraryBookInfoReader falls back to the metadata the library keeps).
Analyzing or parsing an audiobook's audio has AsyncBridge.audioAnalysisTimeLimit (5 minutes: BookParser and BookContentAnalysisService).
Every other user (audio-edit renders, conversions, textutil) keeps no limit, since each can honestly run for an hour and has its own cancel or watchdog.
A read of a file that passed its limit is remembered (`waitForResult(reading:timeLimit:abandoned:of:)`), and every later read of it is refused with AbandonedEarlier.
The sentence is AsyncBridgeWording.abandonedEarlier, from InProcessEngineWording.refused: "TextMouth stopped reading this audio earlier because it took too long, and won't try again until TextMouth is closed and opened again.".
It is true on both platforms: an iPhone app only switched back to keeps its process.
