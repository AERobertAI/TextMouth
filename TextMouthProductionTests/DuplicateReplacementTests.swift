import XCTest
@testable import TextMouth

/// Replace Existing keeps the old copy's state (ST04): what the new copy of a
/// duplicate carries over from the library's copy whose place it takes
/// (`DuplicateReplacement`).
///
/// The first tests check the row the new copy becomes, which is pure. The
/// rest prepare real packages, imported into library folders of the test's
/// own, as Replace Existing prepares the new copy's package before the old
/// one is deleted: what goes into it, where it moves, and how an undo puts
/// it back. The library's own answer is tested through the import queue in
/// `ImportDecisionFlowTests`.
@MainActor
final class DuplicateReplacementTests: XCTestCase {

    // MARK: - The Row

    /// A book under another ID is the same book in every other field: the
    /// record the change goes through carries them all.
    func testAnotherIDChangesNothingElse() {
        let book = Self.bookWithEveryFieldSet()
        let id = UUID()

        let renamed = book.withID(id)

        XCTAssertEqual(renamed.id, id)
        XCTAssertEqual(renamed.withID(book.id), book)
    }

    /// The new copy takes the old copy's ID, its place in the library, its
    /// playback times, its own settings, and the places given; everything
    /// else is the new copy's: its file, text, analysis, names, and source.
    func testTheNewCopyTakesTheOldCopysPlaceUnderItsID() {
        let existing = Self.existingTextBook()
        let copy = Self.newTextCopy()
        let moved = Self.movedPlaces()
        let location = Book.FileLocation(folderPath: "Shelf", filePath: "/library/Shelf/New.tmb/Atlas of Tides.txt", tmbDirectoryName: "New.tmb")

        let carried = DuplicateReplacement.carriedBook(replacing: existing, with: copy, places: moved, location: location)

        // The old copy's.
        XCTAssertEqual(carried.id, existing.id)
        XCTAssertEqual(carried.fileLocation, location)
        XCTAssertEqual(carried.manualSortOrder, existing.manualSortOrder)
        XCTAssertEqual(carried.dateAdded, existing.dateAdded)
        XCTAssertEqual(carried.lastOpened, existing.lastOpened)
        XCTAssertEqual(carried.lastPlaybackStarted, existing.lastPlaybackStarted)
        XCTAssertEqual(carried.lastPlaybackStopped, existing.lastPlaybackStopped)
        XCTAssertEqual(carried.localVoiceSettings, existing.localVoiceSettings)
        XCTAssertEqual(carried.localEndOfBookBehavior, existing.localEndOfBookBehavior)
        XCTAssertEqual(carried.localSkipForwardUnit, existing.localSkipForwardUnit)
        XCTAssertEqual(carried.localSkipBackwardUnit, existing.localSkipBackwardUnit)
        XCTAssertEqual(carried.relocatablePlaces, moved)
        XCTAssertEqual(carried.skippedHeadingIDs, moved.skippedHeadings.map(\.id))
        // The new copy's.
        XCTAssertEqual(carried.title, copy.title)
        XCTAssertEqual(carried.author, copy.author)
        XCTAssertEqual(carried.format, copy.format)
        XCTAssertEqual(carried.md5Hash, copy.md5Hash)
        XCTAssertEqual(carried.sourceFilePath, copy.sourceFilePath)
        XCTAssertEqual(carried.contentAnalysisFields, copy.contentAnalysisFields)
        XCTAssertEqual(carried.metadataReaderVersion, copy.metadataReaderVersion)
        XCTAssertEqual(carried.handEdits, copy.handEdits)
        XCTAssertNil(carried.editedText, "an edit of the old text was laid over the new one")
        XCTAssertNil(carried.feedLink)
    }

    /// The metadata the user edited by hand in the old copy stays the
    /// user's own, recorded as such; a field they did not edit is the new
    /// copy's.
    func testHandEditedMetadataStaysTheUsersOwn() {
        var existing = Self.existingTextBook()
        existing.title = "My Own Title"
        existing.handEdits = Book.HandEdits(fields: [.title], sinceImport: true)
        let copy = Self.newTextCopy()

        let carried = DuplicateReplacement.carriedBook(
            replacing: existing,
            with: copy,
            places: existing.relocatablePlaces,
            location: copy.fileLocation
        )

        XCTAssertEqual(carried.title, "My Own Title")
        XCTAssertEqual(carried.author, copy.author)
        XCTAssertEqual(carried.handEdits, Book.HandEdits(fields: [.title], sinceImport: true))
    }

    /// A copy of the other kind, an audiobook for a text book, keeps the old
    /// copy's ID and place in the library, but none of its places, speed, or
    /// settings, which mean nothing to it.
    func testACopyOfTheOtherKindKeepsOnlyTheIDAndPlace() {
        let existing = Self.existingTextBook()
        var copy = Self.newTextCopy()
        copy.format = .audio

        let carried = DuplicateReplacement.carriedBook(
            replacing: existing,
            with: copy,
            places: existing.relocatablePlaces,
            location: copy.fileLocation
        )

        XCTAssertEqual(carried.id, existing.id)
        XCTAssertEqual(carried.manualSortOrder, existing.manualSortOrder)
        XCTAssertNil(carried.readingPosition)
        XCTAssertEqual(carried.bookmarks, [])
        XCTAssertNil(carried.localWPM)
        XCTAssertNil(carried.localVoiceID)
        XCTAssertNil(carried.localEndOfBookBehavior)
    }

    /// The new copy's file stays at the same path inside its package once
    /// the package moves, for a folder of tracks as for one file.
    func testTheFileKeepsItsPathInsideTheMovedPackage() {
        let published = TextMouthPaths.tmbPath(folderPath: "Imports", tmbName: "New.tmb")
        var copy = Self.newTextCopy()
        copy.folderPath = "Imports"
        copy.tmbDirectoryName = "New.tmb"
        copy.filePath = published.appendingPathComponent("Disc 1").appendingPathComponent("01.mp3").path
        let moved = TextMouthPaths.tmbPath(folderPath: "Shelf/Sea", tmbName: "New.tmb")

        let location = DuplicateReplacement.location(of: copy, movedTo: moved, folderPath: "Shelf/Sea")

        XCTAssertEqual(location.folderPath, "Shelf/Sea")
        XCTAssertEqual(location.tmbDirectoryName, "New.tmb")
        XCTAssertEqual(location.filePath, moved.appendingPathComponent("Disc 1/01.mp3").path)
    }

    // MARK: - The Places

    /// A bookmark and the reading position follow their words into the new
    /// text, where a preface moved them on, keeping their identity and note.
    func testPlacesFollowTheirWordsIntoTheNewText() throws {
        let old = Self.text(Self.oldWords)
        let new = Self.text(Self.newWords)
        let existing = try Self.book(withPlacesIn: old)

        let places = DuplicateReplacement.carriedPlaces(
            of: existing,
            copy: Self.newTextCopy(),
            oldText: { old },
            newText: { new },
            movedAt: Self.date
        )

        try assertPlacesStand(places, in: new, keeping: existing)
    }

    /// Without the old text, as when it is gone, the places are found in the
    /// new text by their words alone.
    func testPlacesAreFoundByTheirWordsWithoutTheOldText() throws {
        let old = Self.text(Self.oldWords)
        let new = Self.text(Self.newWords)
        let existing = try Self.book(withPlacesIn: old)

        let places = DuplicateReplacement.carriedPlaces(
            of: existing,
            copy: Self.newTextCopy(),
            oldText: { throw CocoaError(.fileReadNoSuchFile) },
            newText: { new },
            movedAt: Self.date
        )

        try assertPlacesStand(places, in: new, keeping: existing)
    }

    /// An audiobook's places count time in its recording, so they stay as
    /// they were saved, and no text is read for them.
    func testAnAudiobooksPlacesStayAsTheyWere() {
        var existing = Self.existingTextBook()
        existing.format = .audio
        var copy = Self.newTextCopy()
        copy.format = .audio
        var textsRead = 0

        let places = DuplicateReplacement.carriedPlaces(
            of: existing,
            copy: copy,
            oldText: {
                textsRead += 1
                throw CocoaError(.fileReadNoSuchFile)
            },
            newText: {
                textsRead += 1
                return nil
            },
            movedAt: Self.date
        )

        XCTAssertEqual(places, existing.relocatablePlaces)
        XCTAssertEqual(textsRead, 0)
    }

    /// Places a new text could not move, as a position at the very start of
    /// a book with no bookmark or skip, stay, and no text is read for them.
    func testPlacesNothingCouldMoveReadNoText() {
        var existing = Self.existingTextBook()
        existing.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: 0)
        existing.bookmarks = []
        existing.setSkippedHeadings(nil)
        var textsRead = 0

        let places = DuplicateReplacement.carriedPlaces(
            of: existing,
            copy: Self.newTextCopy(),
            oldText: {
                textsRead += 1
                throw CocoaError(.fileReadNoSuchFile)
            },
            newText: {
                textsRead += 1
                return nil
            },
            movedAt: Self.date
        )

        XCTAssertEqual(places, existing.relocatablePlaces)
        XCTAssertEqual(textsRead, 0)
    }

    // MARK: - Refusals

    /// Each refusal says why Replace Existing waits, and what to do before
    /// choosing it again; a download's deletion keeps its own words.
    func testRefusalsSayWhyAndWhatToDo() {
        typealias Refusal = DuplicateReplacement.Refusal
        XCTAssertEqual(
            Refusal.inUse(.openInReader, title: "Atlas of Tides").sentence,
            "“Atlas of Tides” is open in a reader. Close it, then choose Replace Existing again."
        )
        XCTAssertEqual(
            Refusal.inUse(.transcribing, title: "Atlas of Tides").sentence,
            "“Atlas of Tides” is being transcribed, and replacing it now would lose the transcript. "
                + "Wait until the transcription ends, or cancel it, then choose Replace Existing again."
        )
        XCTAssertEqual(
            Refusal.inUse(.exporting, title: "Atlas of Tides").sentence,
            "“Atlas of Tides” is being exported, and replacing it now would stop the export. "
                + "Wait until the export ends, then choose Replace Existing again."
        )
        XCTAssertEqual(
            Refusal.audioBeingEdited(title: "Atlas of Tides").sentence,
            "The audio of “Atlas of Tides” is being edited. Close the audio editor, or wait until it has saved, "
                + "then choose Replace Existing again."
        )
        XCTAssertEqual(
            Refusal.filesInCloud(title: "Atlas of Tides").sentence,
            "Some of the files of “Atlas of Tides” are only in the cloud, and replacing it now would leave them behind. "
                + "Download the book, then choose Replace Existing again."
        )
        XCTAssertEqual(
            FeedBookUse.transcribing.refusal(of: "“Ep. 368”"),
            "“Ep. 368” is being transcribed, and deleting its download now would lose the transcript. "
                + "Wait until the transcription ends, or cancel it, then try again."
        )
    }

    // MARK: - Preparing the New Copy's Package

    /// The new copy's package moves into the old copy's folder, with the
    /// copies Edit Text kept, and the old copy's edited text kept beside
    /// the new text as one more copy, never laid over it. Undo puts the
    /// package back as its import published it.
    func testTheNewPackageMovesInWithTheEditKeptBesideTheNewText() throws {
        let scene = try makeScene()
        var existing = try scene.importText(Self.oldWords, named: "Earlier Atlas", into: scene.shelf)
        let edited = Data((Self.oldWords + "\n\nA paragraph the reader added.").utf8)
        try edited.write(to: MarkdownCacheService.cacheURL(for: existing))
        existing.editedText = EditedText(cacheDigest: FingerprintHasher.md5.digestOfData(edited), takenAt: Self.date)
        let earlierCopy = existing.tmbDirectory.appendingPathComponent("content.md.edited-20261001T000000Z")
        try Data("An older edit.".utf8).write(to: earlierCopy)
        let copy = try scene.importText(Self.oldWords, named: "Atlas of Tides", into: scene.imports)
        let published = try scene.imports.entries()
        let packageEntries = try entries(of: copy.tmbDirectory)
        let newText = try Data(contentsOf: MarkdownCacheService.cacheURL(for: copy))

        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)

        let moved = scene.shelf.url.appendingPathComponent(copy.tmbDirectoryName)
        XCTAssertEqual(preparation.movedTo.standardizedFileURL.path, moved.standardizedFileURL.path)
        XCTAssertEqual(try scene.imports.entries(), [], "the new package is still where it was imported")
        XCTAssertEqual(try scene.shelf.entries(), [existing.tmbDirectoryName, copy.tmbDirectoryName])
        XCTAssertEqual(preparation.book.id, existing.id)
        XCTAssertEqual(preparation.book.folderPath, scene.shelf.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preparation.book.filePath), preparation.book.filePath)
        XCTAssertNil(preparation.book.editedText)
        XCTAssertFalse(preparation.keptTranscript)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("content.md")), newText, "the new text changed")
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent(earlierCopy.lastPathComponent)), Data("An older edit.".utf8))
        let kept = try XCTUnwrap(preparation.keptText)
        XCTAssertTrue(TextMouthPaths.isKeptTextCopy(kept.lastPathComponent), kept.lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: kept), edited)

        preparation.undo()

        XCTAssertEqual(try scene.imports.entries(), published)
        XCTAssertEqual(try entries(of: copy.tmbDirectory), packageEntries, "the undo left what was carried in")
        XCTAssertEqual(try scene.shelf.entries(), [existing.tmbDirectoryName])
    }

    /// Text saved in the old copy's content.md that no edit took is kept
    /// too, being no text TextMouth wrote; a text TextMouth wrote, untouched,
    /// is not kept, nor is anything carried into a package in the same
    /// folder, which stays where it is.
    func testOnlyTextTextMouthDidNotWriteIsKept() throws {
        let scene = try makeScene()
        let untouched = try scene.importText(Self.oldWords, named: "Earlier Atlas", into: scene.shelf)
        let saved = try scene.importText(Self.oldWords, named: "Earlier Bestiary", into: scene.shelf)
        let save = Data("A save made in another editor.".utf8)
        try save.write(to: MarkdownCacheService.cacheURL(for: saved))
        let atlas = try scene.importText(Self.oldWords, named: "Atlas of Tides", into: scene.shelf)
        let bestiary = try scene.importText(Self.oldWords, named: "Bestiary of Knots", into: scene.imports)
        let atlasEntries = try entries(of: atlas.tmbDirectory)

        let keptNothing = try DuplicateReplacement.prepare(replacing: untouched, with: atlas)
        let keptTheSave = try DuplicateReplacement.prepare(replacing: saved, with: bestiary)

        XCTAssertNil(keptNothing.keptText)
        XCTAssertEqual(keptNothing.movedTo.standardizedFileURL.path, atlas.tmbDirectory.standardizedFileURL.path)
        XCTAssertEqual(try entries(of: atlas.tmbDirectory), atlasEntries)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(keptTheSave.keptText)), save)
    }

    /// An edit on record whose text is only in the cloud is never left
    /// behind: the replacement is refused, saying why, and the new package is
    /// as its import published it.
    func testAnEditOnlyInTheCloudRefusesTheReplacement() throws {
        let scene = try makeScene()
        var existing = try scene.importText(Self.oldWords, named: "Earlier Atlas", into: scene.shelf)
        existing.editedText = EditedText(cacheDigest: "edited", takenAt: Self.date)
        let copy = try scene.importText(Self.oldWords, named: "Atlas of Tides", into: scene.imports)
        let published = try entries(of: copy.tmbDirectory)
        let oldText = MarkdownCacheService.cacheURL(for: existing).standardizedFileURL.path
        let access = MaintenanceFileAccess(isDataless: { $0.standardizedFileURL.path == oldText })

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: existing, with: copy, access: access)) { error in
            XCTAssertEqual(error as? DuplicateReplacement.Refusal, .filesInCloud(title: existing.title))
        }
        XCTAssertEqual(try entries(of: copy.tmbDirectory), published)
        XCTAssertEqual(try scene.shelf.entries(), [existing.tmbDirectoryName])
    }

    /// A row naming no package the library manages has nothing to carry,
    /// and its package could not be deleted: nothing is touched.
    func testARowWithoutAManagedPackageIsNotReplaced() throws {
        let scene = try makeScene()
        let copy = try scene.importText(Self.oldWords, named: "Atlas of Tides", into: scene.imports)
        let unmanaged = Book(title: "Unmanaged Atlas", format: .txt, filePath: "/nonexistent/Atlas.txt", md5Hash: copy.md5Hash)
        let published = try scene.imports.entries()

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: unmanaged, with: copy))
        XCTAssertEqual(try scene.imports.entries(), published)
    }

    /// The transcript of a book of one audio file goes with it into a copy
    /// of the same audio imported under another name, renamed to the new
    /// file, so the new copy's audio is the audio it describes; a copy of
    /// other audio gets no transcript.
    func testTheTranscriptGoesWithTheSameAudioOnly() throws {
        let scene = try makeScene()
        let sound = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: sound, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: sound, toFolder: scene.shelf.path).book
        let transcript = try TranscriptFixtures.transcript(of: existing, sentences: [
            "Earlier Tide.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        try TranscriptStore.write(transcript, into: existing.tmbDirectory)
        let sameAudio = scene.sources.appendingPathComponent("Tide.wav")
        try FileManager.default.copyItem(at: sound, to: sameAudio)
        let copy = try FileImportService.importFileWithReport(from: sameAudio, toFolder: scene.imports.path).book
        let otherAudio = scene.sources.appendingPathComponent("Other Tide.wav")
        try AudioTestFixtures.writeSilence(to: otherAudio, duration: 2)
        let other = try FileImportService.importFileWithReport(from: otherAudio, toFolder: scene.imports.path).book

        let withTranscript = try DuplicateReplacement.prepare(replacing: existing, with: copy)
        let withoutTranscript = try DuplicateReplacement.prepare(replacing: existing, with: other)

        XCTAssertTrue(withTranscript.keptTranscript)
        guard case .found(let carried) = TranscriptStore.read(from: withTranscript.movedTo) else {
            return XCTFail("the transcript did not go with the same audio")
        }
        XCTAssertEqual(carried.files.map(\.path), ["Tide.wav"])
        XCTAssertEqual(carried.files.first?.sentences, transcript.files.first?.sentences)
        let index = try XCTUnwrap(try BookInfo.load(from: withTranscript.movedTo).contentIndex)
        XCTAssertNotNil(DuplicateReplacement.fitted(carried, to: withTranscript.book, index: index), "the new copy's audio is not the audio described")
        XCTAssertFalse(withoutTranscript.keptTranscript)
        XCTAssertEqual(TranscriptStore.read(from: withoutTranscript.movedTo), .missing)
    }

    // MARK: - Assertions

    /// Checks that the position and the bookmark of `places` stand on the
    /// words they were saved by in `new`, and that the bookmark kept its
    /// identity and note from `existing`.
    private func assertPlacesStand(
        _ places: PlaceRelocator.Places,
        in new: DocumentContent,
        keeping existing: Book,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let text = try XCTUnwrap(new.chapters.first?.text, file: file, line: line) as NSString
        let bookmark = try XCTUnwrap(places.bookmarks.first, file: file, line: line)
        XCTAssertEqual(bookmark.characterOffset, text.range(of: Self.markedWords).location, file: file, line: line)
        XCTAssertEqual(bookmark.id, existing.bookmarks.first?.id, file: file, line: line)
        XCTAssertEqual(bookmark.label, "Pilot", file: file, line: line)
        XCTAssertEqual(places.position?.characterOffset, text.range(of: Self.positionWords).location, file: file, line: line)
    }

    // MARK: - Fixtures

    /// When fixtures' dates fall, in whole seconds.
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)
    /// The words the bookmark marks.
    private static let markedWords = "the harbor pilot"
    /// The words the reading position is at.
    private static let positionWords = "The last paragraph"
    /// The old copy's text.
    private static let oldWords = """
        The first paragraph tells of the tides along the outer coast.

        The second paragraph names the harbor pilot who keeps the channel.

        The last paragraph ends the chart notes for the season.
        """
    /// The new copy's text: a preface put in before the old copy's.
    private static let newWords = """
        A preface added in this edition, before the notes begin.

        The first paragraph tells of the tides along the outer coast.

        The second paragraph names the harbor pilot who keeps the channel.

        The last paragraph ends the chart notes for the season.
        """

    /// `words` as a reader reads a content.md holding them.
    private static func text(_ words: String) -> DocumentContent {
        MarkdownCacheService.parseMultiChapterMarkdown(words, bookTitle: "Atlas", bookAuthor: "Pilots")
    }

    /// The old copy, with a bookmark on `markedWords` and its reading
    /// position at `positionWords` in `old`, each with its words.
    private static func book(withPlacesIn old: DocumentContent) throws -> Book {
        let text = try XCTUnwrap(old.chapters.first?.text) as NSString
        let marked = TextPlace(chapter: 0, offset: text.range(of: markedWords).location)
        let reading = TextPlace(chapter: 0, offset: text.range(of: positionWords).location)
        var book = existingTextBook()
        book.bookmarks = [Bookmark(
            number: 1,
            chapterIndex: 0,
            characterOffset: marked.offset,
            label: "Pilot",
            dateCreated: date,
            anchor: old.anchor(at: marked, measuredIn: nil)
        )]
        book.readingPosition = ReadingPosition(
            chapterIndex: 0,
            characterOffset: reading.offset,
            anchor: old.anchor(at: reading, measuredIn: nil)
        )
        book.setSkippedHeadings(nil)
        book.waitingSkippedHeadings = nil
        return book
    }

    /// The library's copy of a text book, with a place in its folder, a
    /// position, a bookmark, a skipped heading, and settings of its own.
    private static func existingTextBook() -> Book {
        Book(
            title: "Earlier Atlas",
            author: "Harbor Board",
            format: .txt,
            filePath: "/library/Shelf/Old.tmb/Earlier Atlas.txt",
            md5Hash: "old",
            folderPath: "Shelf",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(60),
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 40),
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 12, label: "Pilot", dateCreated: date)],
            totalWordCount: 30,
            totalCharacterCount: 180,
            tmbDirectoryName: "Old.tmb",
            sourceFilePath: "/sources/Earlier Atlas.txt",
            lastPlaybackStarted: date.addingTimeInterval(120),
            lastPlaybackStopped: date.addingTimeInterval(180),
            localVoiceID: "com.apple.voice.compact.en-GB.Daniel",
            localWPM: 240,
            localPitch: 1.2,
            skippedHeadingIDs: ["0-0-1-Notes"],
            localEndOfBookBehavior: "loop",
            localSkipForwardUnit: "paragraph",
            localSkipBackwardUnit: "sentence",
            manualSortOrder: 3,
            cacheFormatVersion: "3.0.0",
            handEdits: .noneSinceImport
        )
    }

    /// A new copy of the text book, just imported elsewhere, with nothing of
    /// the listener's.
    private static func newTextCopy() -> Book {
        Book(
            title: "Atlas of Tides",
            author: "Pilots' Guild",
            format: .txt,
            filePath: "/library/Imports/New.tmb/Atlas of Tides.txt",
            md5Hash: "new",
            folderPath: "Imports",
            dateAdded: date.addingTimeInterval(86_400),
            totalWordCount: 40,
            totalCharacterCount: 240,
            tmbDirectoryName: "New.tmb",
            sourceFilePath: "/sources/Atlas of Tides.txt",
            cacheFormatVersion: "3.1.0",
            contentIndexVersion: "2.0.0",
            metadataReaderVersion: "1.2.0",
            handEdits: .noneSinceImport
        )
    }

    /// Places as a relocation might give them, unlike the old copy's own.
    private static func movedPlaces() -> PlaceRelocator.Places {
        PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 64),
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 36, label: "Pilot", dateCreated: date)],
            skippedHeadings: [SkippedHeading(level: 1, label: "Notes", chapterIndex: 0, characterOffset: 20)],
            waitingSkippedHeadings: [SkippedHeading(level: 2, label: "Errata", chapterIndex: 0, characterOffset: 90)]
        )
    }

    /// A book with every field set, its feed link included.
    private static func bookWithEveryFieldSet() -> Book {
        let anchor = TextAnchor(before: "before", after: "after", fraction: 0.5, measuredIn: "3.0.7/1.0.0")
        let skipped = SkippedHeading(level: 2, label: "Heading", chapterIndex: 1, characterOffset: 7, anchor: anchor)
        let fingerprint = FileFingerprint(
            stamp: FileStamp(byteCount: 1_000, modificationTimeNanoseconds: 1_000_000_007),
            digest: "digest"
        )
        return Book(
            title: "Title",
            author: "Author",
            format: .epub,
            filePath: "/library/Folder/Package.tmb/book.epub",
            md5Hash: "hash",
            folderPath: "Folder",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(1),
            readingPosition: ReadingPosition(chapterIndex: 3, headingIndex: 1, characterOffset: 30, globalCharacterOffset: 300, anchor: anchor),
            bookmarks: [Bookmark(number: 1, chapterIndex: 1, characterOffset: 5, label: "Mark", dateCreated: date, anchor: anchor)],
            totalWordCount: 100,
            totalCharacterCount: 500,
            tmbDirectoryName: "Package.tmb",
            sourceFilePath: "/sources/book.epub",
            lastPlaybackStarted: date.addingTimeInterval(2),
            lastPlaybackStopped: date.addingTimeInterval(3),
            localVoiceID: "voice",
            localWPM: 200,
            localPitch: 1.1,
            skippedHeadingIDs: [skipped.id],
            skippedHeadings: [skipped],
            waitingSkippedHeadings: [SkippedHeading(level: 3, label: "Waiting", chapterIndex: 2, characterOffset: 9, anchor: anchor)],
            localEndOfBookBehavior: "behavior",
            localSkipForwardUnit: "forward",
            localSkipBackwardUnit: "backward",
            manualSortOrder: 4,
            audioDuration: 60,
            audioAlbum: "Album",
            audioGenre: "Genre",
            audioYear: "2000",
            epubPublisher: "Publisher",
            epubPublicationDate: "Published",
            epubISBN: "ISBN",
            epubLanguage: "en",
            epubIdentifier: "identifier",
            epubVersion: "3.0",
            cacheFormatVersion: "cache",
            contentIndexVersion: "index",
            textCacheFingerprint: TextCacheFingerprint(source: fingerprint, cache: fingerprint),
            editedText: EditedText(cacheDigest: "cache", takenAt: date.addingTimeInterval(4)),
            pageReaderVersion: "pages",
            metadataReaderVersion: "reader",
            handEdits: Book.HandEdits(fields: [.title], sinceImport: true),
            feedLink: FeedBookLink(feedID: UUID(), itemID: "item"),
            brailleTable: "table.ctb",
            brailleTableVersion: "liblouis"
        )
    }

    /// Where one test imports from and into: two library folders of its
    /// own, the old copy's shelf and the folder the new copy is imported
    /// into, and a folder for the source files, outside the library.
    private struct Scene {
        let shelf: IntegrationLibraryFolder
        let imports: IntegrationLibraryFolder
        let sources: URL

        /// Imports a plain-text book of `words`, from a file named `name`,
        /// into `folder`, as Open Book... imports a chosen file.
        func importText(_ words: String, named name: String, into folder: IntegrationLibraryFolder) throws -> Book {
            let source = sources.appendingPathComponent("\(name).txt")
            try Data(words.utf8).write(to: source)
            return try FileImportService.importFileWithReport(from: source, toFolder: folder.path).book
        }
    }

    /// A scene of this test's own, removed when the test ends.
    private func makeScene() throws -> Scene {
        Scene(
            shelf: makeIntegrationLibraryFolder("Replace Shelf"),
            imports: makeIntegrationLibraryFolder("Replace Imports"),
            sources: try makeSandboxDirectory("ReplaceSources")
        )
    }

    /// The names at the top of the package at `package`.
    private func entries(of package: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: package.path))
    }
}
