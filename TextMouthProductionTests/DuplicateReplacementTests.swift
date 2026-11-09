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

    /// Places move from the old text only when it is the text they were
    /// saved in, by the digest the record keeps, as Edit Text checks: not
    /// from a save no edit took, nor when no digest is kept (ST04 review,
    /// finding 8).
    func testPlacesMoveFromTheOldTextOnlyWhenItIsTheTextTheyWereSavedIn() {
        let written = Data("The chart notes as TextMouth wrote them.".utf8)
        let saved = Data("The chart notes as another editor saved them.".utf8)
        let fingerprint = FileFingerprint(
            stamp: FileStamp(byteCount: Int64(written.count), modificationTimeNanoseconds: 0),
            digest: FingerprintHasher.md5.digestOfData(written)
        )
        var book = Self.existingTextBook()
        book.textCacheFingerprint = TextCacheFingerprint(source: fingerprint, cache: fingerprint)
        var unrecorded = book
        unrecorded.textCacheFingerprint = nil

        XCTAssertTrue(DuplicateReplacement.holdsTextOfPlaces(written, of: book))
        XCTAssertFalse(DuplicateReplacement.holdsTextOfPlaces(saved, of: book))
        XCTAssertFalse(DuplicateReplacement.holdsTextOfPlaces(written, of: unrecorded))
    }

    /// An audiobook read as one chapter and replaced by the same recording
    /// read with its chapter marks: each place goes through its time on the
    /// recording to the chapter that holds it, never held at the end of the
    /// first, the end of the book stays the end, and a skip waits, naming no
    /// heading (ST04 review, finding 2).
    func testAudiobookPlacesGoThroughTheirTimeToANewChapterList() {
        let old = Self.audioIndex([(nil, 100)])
        let new = Self.audioIndex([(nil, 40), (nil, 60)])
        let skip = SkippedHeading(level: 1, label: "Chapter 1", chapterIndex: 0, characterOffset: 0)
        let places = PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 600, globalCharacterOffset: 600),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 0, characterOffset: 950, label: "Toll", dateCreated: Self.date),
                Bookmark(number: 2, chapterIndex: 0, characterOffset: 1_000, label: "End", dateCreated: Self.date),
            ],
            skippedHeadings: [skip]
        )

        let moved = DuplicateReplacement.movedAudioPlaces(places, from: old, to: new, at: Self.date)

        XCTAssertEqual(moved.position?.chapterIndex, 1)
        XCTAssertEqual(moved.position?.characterOffset, 200)
        XCTAssertEqual(moved.position?.globalCharacterOffset, 600)
        XCTAssertEqual(moved.position?.lastUpdated, Self.date)
        XCTAssertEqual(moved.bookmarks.map(\.chapterIndex), [1, 1])
        XCTAssertEqual(moved.bookmarks.map(\.characterOffset), [550, 600])
        XCTAssertEqual(moved.bookmarks.map(\.label), ["Toll", "End"])
        XCTAssertEqual(moved.skippedHeadings, [])
        XCTAssertEqual(moved.waitingSkippedHeadings, [skip])
    }

    /// Books of tracks whose old copy played them in another order, as an
    /// edit of its manifest leaves it: each place follows its track, at the
    /// same time into it. The same chapter list moves nothing.
    func testAudiobookPlacesFollowTheirTracksAndStayOnTheSameChapters() {
        let old = Self.audioIndex([("c.wav", 10), ("a.wav", 10), ("b.wav", 10)])
        let new = Self.audioIndex([("a.wav", 10), ("b.wav", 10), ("c.wav", 10)])
        let places = PlaceRelocator.Places(
            position: ReadingPosition(chapterIndex: 0, characterOffset: 50),
            bookmarks: [Bookmark(number: 1, chapterIndex: 2, characterOffset: 30, label: "Weir", dateCreated: Self.date)]
        )

        let moved = DuplicateReplacement.movedAudioPlaces(places, from: old, to: new, at: Self.date)
        let unmoved = DuplicateReplacement.movedAudioPlaces(places, from: old, to: old, at: Self.date)

        XCTAssertEqual(moved.position?.chapterIndex, 2)
        XCTAssertEqual(moved.position?.characterOffset, 50)
        XCTAssertEqual(moved.bookmarks.map(\.chapterIndex), [1])
        XCTAssertEqual(moved.bookmarks.map(\.characterOffset), [30])
        XCTAssertEqual(unmoved, places)
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

    /// A new copy given a transcript at its import, from a file beside its
    /// audio (FMT23), against the old copy's transcript of the same audio
    /// (B1): one recognition made is kept, over the file's, as the question
    /// says, and the file is named as not used; so is one the listener
    /// edited; one from outside the listener never touched gives way to the
    /// file's. Whichever stays, the new package holds a transcript, which
    /// the library row records (S1).
    func testReplacingKeepsTheListenersTranscriptOverOneBroughtFromAFile() throws {
        let scene = try makeScene()
        let sound = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: sound, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: sound, toFolder: scene.shelf.path).book
        let recognized = try TranscriptFixtures.transcript(of: existing, sentences: [
            "Earlier Tide.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        let sameAudio = scene.sources.appendingPathComponent("Tide.wav")
        try FileManager.default.copyItem(at: sound, to: sameAudio)
        try Data("WEBVTT\n\n00:00.000 --> 00:00.800\nThe slip is clear.\n".utf8)
            .write(to: scene.sources.appendingPathComponent("Tide.vtt"))
        /// The old copy given `old`, then a new copy of the same audio with
        /// Tide.vtt beside it, replacing it: what the question was told, the
        /// preparation, and the transcript the new package holds.
        func replace(
            withOld old: Transcript
        ) throws -> (outcome: DuplicateReplacement.TranscriptOutcome, preparation: DuplicateReplacement.Preparation, held: Transcript?) {
            try TranscriptStore.write(old, into: existing.tmbDirectory)
            let copy = try FileImportService.importFileWithReport(from: sameAudio, toFolder: scene.imports.path).book
            XCTAssertTrue(TranscriptStore.hasTranscript(of: copy), "the file beside the new copy was not attached")
            let outcome = DuplicateReplacement.transcriptOutcome(replacing: existing, with: copy)
            let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)
            guard case .found(let held) = TranscriptStore.read(from: preparation.movedTo) else { return (outcome, preparation, nil) }
            return (outcome, preparation, held)
        }

        // Recognition's: kept, and the file's is named as not used.
        let keptRecognized = try replace(withOld: recognized)
        XCTAssertEqual(keptRecognized.outcome, .keepsExisting)
        XCTAssertEqual(keptRecognized.held?.files.first?.sentences.map(\.text), ["The ferry waits at the slip."])
        XCTAssertTrue(keptRecognized.preparation.keptTranscript)
        XCTAssertTrue(keptRecognized.preparation.hasTranscript)
        XCTAssertEqual(keptRecognized.preparation.broughtTranscriptNotUsed, DuplicateReplacement.BroughtTranscript(fileName: "Tide.vtt"))

        // Edited by the listener, though from outside: kept.
        var edited = recognized
        edited.source = TranscriptSource(origin: .attached, format: .subRip, fileName: "Older.srt")
        edited.editedAt = TranscriptFixtures.date
        let keptEdited = try replace(withOld: edited)
        XCTAssertEqual(keptEdited.outcome, .keepsExisting)
        XCTAssertNotNil(keptEdited.held?.editedAt)
        XCTAssertEqual(keptEdited.preparation.broughtTranscriptNotUsed, DuplicateReplacement.BroughtTranscript(fileName: "Tide.vtt"))

        // Cleaned up by the listener, though from outside and never edited:
        // kept as well. This pins the cleanup half of "touched" on the
        // replacement path (the question reads it from transcript.json, the
        // replacement from the decoded transcript); losing it there would
        // make the question promise what the replacement does not do.
        var cleaned = recognized
        cleaned.source = TranscriptSource(origin: .attached, format: .subRip, fileName: "Older.srt")
        cleaned.cleanedUp = TranscriptCleanupNote(
            cleanedAt: TranscriptFixtures.date, rulesVersion: 1, rulesDate: "2026-10-04", rules: "built-in", corrections: 2
        )
        let keptCleaned = try replace(withOld: cleaned)
        XCTAssertEqual(keptCleaned.outcome, .keepsExisting, "the question did not count a cleanup as touching the transcript")
        XCTAssertEqual(
            keptCleaned.held?.files.first?.sentences.map(\.text), ["The ferry waits at the slip."],
            "Replace Existing gave a cleaned-up transcript way to the file's, though the question said it was kept"
        )
        XCTAssertNotNil(keptCleaned.held?.cleanedUp, "the cleanup record was not carried with the transcript")
        XCTAssertEqual(keptCleaned.preparation.broughtTranscriptNotUsed, DuplicateReplacement.BroughtTranscript(fileName: "Tide.vtt"))

        // From outside and untouched: gives way to the file's.
        var outside = recognized
        outside.source = TranscriptSource(origin: .attached, format: .subRip, fileName: "Older.srt")
        let gaveWay = try replace(withOld: outside)
        XCTAssertEqual(gaveWay.outcome, .broughtReplacesExisting)
        XCTAssertEqual(gaveWay.held?.files.first?.sentences.map(\.text), ["The slip is clear."])
        XCTAssertEqual(gaveWay.held?.source?.origin, TranscriptSource.Origin.imported.rawValue)
        XCTAssertFalse(gaveWay.preparation.keptTranscript)
        XCTAssertTrue(gaveWay.preparation.hasTranscript, "the new package's own transcript was not counted")
        XCTAssertNil(gaveWay.preparation.broughtTranscriptNotUsed)
    }

    /// What the listener hears when Replace Existing kept the existing
    /// copy's transcript over the one the new copy brought (B1): the file by
    /// name, with the way to use it after all; several tracks' files
    /// together, which Attach Transcript…, taking one file, cannot use.
    func testTheListenerIsToldOfATranscriptFileReplacingDidNotUse() {
        XCTAssertEqual(
            TranscriptionWording.broughtTranscriptNotUsed(fileName: "Tide.vtt"),
            "“Tide.vtt” was beside the audio but wasn't attached as the book's transcript: "
                + "Replacing kept the existing copy's transcript. "
                + "To use the file instead, open the book and choose Attach Transcript… from the Book menu."
        )
        XCTAssertEqual(
            TranscriptionWording.broughtTranscriptNotUsed(fileName: nil),
            "The transcript files beside the audio weren't attached as the book's transcript: "
                + "Replacing kept the existing copy's transcript."
        )
    }

    /// Nothing to choose: a new copy that brought no transcript leaves the
    /// question as it was, whatever the old copy holds.
    func testANewCopyWithoutATranscriptFileHasNothingToChoose() throws {
        let scene = try makeScene()
        let sound = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: sound, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: sound, toFolder: scene.shelf.path).book
        let recognized = try TranscriptFixtures.transcript(of: existing, sentences: [
            "Earlier Tide.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        try TranscriptStore.write(recognized, into: existing.tmbDirectory)
        let sameAudio = scene.sources.appendingPathComponent("Tide.wav")
        try FileManager.default.copyItem(at: sound, to: sameAudio)
        let copy = try FileImportService.importFileWithReport(from: sameAudio, toFolder: scene.imports.path).book

        XCTAssertEqual(DuplicateReplacement.transcriptOutcome(replacing: existing, with: copy), .asBefore)
        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)
        XCTAssertNil(preparation.broughtTranscriptNotUsed)
        XCTAssertTrue(preparation.hasTranscript)
    }

    // MARK: - Analyses on Their Way

    /// An analysis of the old copy still on its way when the new copy took
    /// its place under the same ID never lands on the new row, being the
    /// old package's; one of the new package does (ST04 review, finding 6).
    func testAnAnalysisOfTheOldPackageNeverLandsOnItsReplacement() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let existing = Self.existingTextBook()
        let replacement = Self.newTextCopy().withID(existing.id)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [replacement])
        var oldAnalysis = existing
        oldAnalysis.totalWordCount = 999
        oldAnalysis.editedText = EditedText(cacheDigest: "old", takenAt: Self.date)
        var newAnalysis = replacement
        newAnalysis.totalWordCount = 41

        model.applyAnalysisSummaries([ContentAnalysisSummary(committed: oldAnalysis)])
        XCTAssertEqual(model.bookByID(existing.id)?.totalWordCount, replacement.totalWordCount)
        XCTAssertNil(model.bookByID(existing.id)?.editedText)
        model.applyAnalysisSummaries([ContentAnalysisSummary(committed: newAnalysis)])
        XCTAssertEqual(model.bookByID(existing.id)?.totalWordCount, 41)
    }

    // MARK: - A Stop Partway

    /// A stop after the new copy's record is written under the book's ID,
    /// before the index that names its package is saved, leaves the book as
    /// it was: a launch reads the saved index, which lists the old copy in
    /// its own package, and leaves the new package, whose record names that
    /// listed book, as it is. Its content differs, so only the ID keeps it
    /// out (ST04 verify, finding 4).
    func testAStopBeforeTheIndexIsSavedLeavesTheBookAsItWas() throws {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let scene = try makeScene()
        let existing = try scene.importText("Chart notes for the season.", named: "Earlier Atlas of Tides", into: scene.shelf)
        let copy = try scene.importText("Chart notes for the season, revised.", named: "Atlas of Tides", into: scene.imports)
        XCTAssertNotEqual(copy.md5Hash, existing.md5Hash, "the same content would keep the new package out by itself")
        XCTAssertTrue(LibraryPersistenceService.saveAndWait(Library(books: [existing])))
        let oldPackage = try entries(of: existing.tmbDirectory)
        let oldRecord = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: existing.tmbDirectory))

        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)
        try preparation.book.saveBookInfoThrowing()
        let newRecord = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: preparation.movedTo))
        var relaunched = try XCTUnwrap(LibraryPersistenceService.load().library)
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &relaunched, libraryDirectory: scene.shelf.url)

        XCTAssertEqual(adopted, 0)
        XCTAssertEqual(relaunched.books.map(\.id), [existing.id])
        XCTAssertEqual(relaunched.books.map(\.tmbDirectoryName), [existing.tmbDirectoryName])
        XCTAssertEqual(try entries(of: existing.tmbDirectory), oldPackage)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: existing.tmbDirectory)), oldRecord)
        XCTAssertEqual(try BookInfo.load(from: preparation.movedTo).metadata.bookID, existing.id)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: preparation.movedTo)), newRecord)
    }

    // MARK: - The Old Copy Put Back

    /// The old copy Replace Existing sent to the Trash names its
    /// replacement's ID, as does an old package a stop or a failed removal
    /// left. Put back by Finder into the folder it left, it is never adopted
    /// at a launch, with the replacement's content or another, and its
    /// record is not rewritten: no two rows share an ID, and nothing is
    /// written on a guess, inside the test's folder or anywhere (ST04 review,
    /// finding 9).
    func testAnOldCopyNamingAListedBookIsLeftAsItIs() throws {
        for hash in ["new", "old"] {
            let libraryDirectory = try makeSandboxDirectory("ReplaceAdoption")
            let id = UUID()
            let replacement = try Self.writePackage(named: "New.tmb", id: id, hash: "new", in: libraryDirectory)
            _ = try Self.writePackage(named: "Old.tmb", id: id, hash: hash, in: libraryDirectory)
            let putBack = libraryDirectory.appendingPathComponent("Old.tmb", isDirectory: true)
            let recordBefore = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: putBack))
            var library = Library(books: [replacement])

            let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDirectory)

            XCTAssertEqual(adopted, 0, "content \(hash)")
            XCTAssertEqual(library.books.map(\.tmbDirectoryName), ["New.tmb"], "content \(hash)")
            XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: putBack)), recordBefore, "content \(hash)")
            XCTAssertEqual(try BookInfo.load(from: putBack).metadata.bookID, id, "content \(hash)")
        }
    }

    /// An index rebuilt from the packages, as an index recovery builds it,
    /// takes of two packages naming one book the one whose record was
    /// written later, as a replacement's is after its old copy's, whichever
    /// the folder lists first, and rewrites neither record (ST04 verify,
    /// finding 5).
    func testOfTwoPackagesNamingOneBookTheLaterWrittenIsTheBook() throws {
        for (older, newer) in [("Atlas A.tmb", "Atlas B.tmb"), ("Atlas B.tmb", "Atlas A.tmb")] {
            let libraryDirectory = try makeSandboxDirectory("ReplaceRecovery")
            let id = UUID()
            _ = try Self.writePackage(named: older, id: id, hash: "older", in: libraryDirectory)
            _ = try Self.writePackage(named: newer, id: id, hash: "newer", in: libraryDirectory)
            let olderRecord = TextMouthPaths.bookInfoPath(in: libraryDirectory.appendingPathComponent(older, isDirectory: true))
            let newerRecord = TextMouthPaths.bookInfoPath(in: libraryDirectory.appendingPathComponent(newer, isDirectory: true))
            try FileManager.default.setAttributes([.modificationDate: Self.date], ofItemAtPath: olderRecord.path)
            try FileManager.default.setAttributes(
                [.modificationDate: Self.date.addingTimeInterval(60)],
                ofItemAtPath: newerRecord.path
            )
            let records = [olderRecord, newerRecord]
            let recordsBefore = try records.map { try Data(contentsOf: $0) }
            var library = Library(books: [])

            let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library, libraryDirectory: libraryDirectory)

            XCTAssertEqual(adopted, 1, "the later written is \(newer)")
            XCTAssertEqual(library.books.map(\.tmbDirectoryName), [newer], "the later written is \(newer)")
            XCTAssertEqual(library.books.map(\.md5Hash), ["newer"], "the later written is \(newer)")
            XCTAssertEqual(try records.map { try Data(contentsOf: $0) }, recordsBefore, "the later written is \(newer)")
        }
    }

    /// A package named `name` in `folder`, holding a plain-text book file
    /// and a record of the book `id`, whose content hash is `hash`.
    private static func writePackage(named name: String, id: UUID, hash: String, in folder: URL) throws -> Book {
        let package = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("Atlas of Tides.txt")
        try Data("Chart notes for the season.".utf8).write(to: file)
        let book = Book(id: id, title: "Atlas of Tides", format: .txt, filePath: file.path, md5Hash: hash, tmbDirectoryName: name)
        try book.makeBookInfo().save(to: package)
        return book
    }

    /// A transcript is kept only where the new copy's audio is proven the
    /// audio transcribed, and nothing is hashed to prove it (ST04 review,
    /// finding 7): the same bytes downloaded again under a new date keep it,
    /// their content hash being the digest it recorded; a file only in the
    /// cloud proves nothing; and a file whose date moved, with no recorded
    /// digest to match, is not proven.
    func testATranscriptIsKeptOnlyWhereTheSameAudioIsProvenWithoutHashing() throws {
        let scene = try makeScene()
        let sound = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: sound, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: sound, toFolder: scene.shelf.path).book
        var transcript = try TranscriptFixtures.transcript(of: existing, sentences: [
            "Earlier Tide.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        try TranscriptStore.write(transcript, into: existing.tmbDirectory)
        let redated = try importAudioCopy(of: sound, named: "Tide.wav", into: scene)
        try FileManager.default.setAttributes([.modificationDate: Self.date], ofItemAtPath: redated.filePath)
        let inCloud = try importAudioCopy(of: sound, named: "Cloud Tide.wav", into: scene)
        let cloudFile = inCloud.bookFileURL.standardizedFileURL.path
        let cloud = MaintenanceFileAccess(isDataless: { $0.standardizedFileURL.path == cloudFile })

        let keptForRedated = try DuplicateReplacement.prepare(replacing: existing, with: redated)
        let keptForCloud = try DuplicateReplacement.prepare(replacing: existing, with: inCloud, access: cloud)
        guard !transcript.files.isEmpty else { return XCTFail("the transcript names no file") }
        transcript.files[0].fingerprint.digest = "0123456789abcdef0123456789abcdef"
        try TranscriptStore.write(transcript, into: existing.tmbDirectory)
        let unproven = try importAudioCopy(of: sound, named: "Unproven Tide.wav", into: scene)
        try FileManager.default.setAttributes([.modificationDate: Self.date], ofItemAtPath: unproven.filePath)
        let keptForUnproven = try DuplicateReplacement.prepare(replacing: existing, with: unproven)

        XCTAssertTrue(keptForRedated.keptTranscript, "the same bytes under a new date are the same audio")
        XCTAssertFalse(keptForCloud.keptTranscript, "a file only in the cloud proves nothing")
        XCTAssertFalse(keptForUnproven.keptTranscript, "a file whose date moved was taken for the same audio unproven")
    }

    /// The transcript of an audiobook imported from a ZIP goes with the same
    /// archive imported again, though extracting it gave every track a new
    /// date: the archive's content hash is the same, and so are its tracks'
    /// paths and sizes (ST04 verify, finding 1). An archive with one track
    /// changed, its size the same, keeps none.
    func testATranscriptGoesWithTheSameArchiveOnly() throws {
        let scene = try makeScene()
        let harbor = scene.sources.appendingPathComponent("01 Harbor.wav")
        let tollRoad = scene.sources.appendingPathComponent("02 Toll Road.wav")
        try AudioTestFixtures.writeSilence(to: harbor, duration: 1)
        try AudioTestFixtures.writeSilence(to: tollRoad, duration: 2)
        let harborBytes = try Data(contentsOf: harbor)
        let tollRoadBytes = try Data(contentsOf: tollRoad)
        var changedBytes = tollRoadBytes
        changedBytes[changedBytes.count - 1] ^= 0x01
        let archive = try writeArchive(named: "Harbor Lectures.zip", in: scene, holding: [
            TestZIPEntry("01 Harbor.wav", harborBytes), TestZIPEntry("02 Toll Road.wav", tollRoadBytes),
        ])
        let sameArchive = scene.sources.appendingPathComponent("Harbor Lectures Again.zip")
        try FileManager.default.copyItem(at: archive, to: sameArchive)
        let changedArchive = try writeArchive(named: "Harbor Lectures Revised.zip", in: scene, holding: [
            TestZIPEntry("01 Harbor.wav", harborBytes), TestZIPEntry("02 Toll Road.wav", changedBytes),
        ])
        let existing = try FileImportService.importAudioZipWithReport(from: archive, toFolder: scene.shelf.path).book
        let transcript = try TranscriptFixtures.transcript(of: existing, sentences: [
            "01 Harbor.wav": [TranscriptFixtures.sentence("The ferry waits at the slip.", from: 0, to: 900)],
        ])
        XCTAssertEqual(transcript.files.map(\.path), ["01 Harbor.wav", "02 Toll Road.wav"])
        try TranscriptStore.write(transcript, into: existing.tmbDirectory)
        let copy = try FileImportService.importAudioZipWithReport(from: sameArchive, toFolder: scene.imports.path).book
        let changed = try FileImportService.importAudioZipWithReport(from: changedArchive, toFolder: scene.imports.path).book
        let copyIndex = try XCTUnwrap(try BookInfo.load(from: copy.tmbDirectory).contentIndex)
        XCTAssertNil(
            DuplicateReplacement.fitted(transcript, to: copy, index: copyIndex),
            "the extracted tracks kept their dates, so the archive's hash went untested"
        )

        let kept = try DuplicateReplacement.prepare(replacing: existing, with: copy)
        let notKept = try DuplicateReplacement.prepare(replacing: existing, with: changed)

        XCTAssertTrue(kept.keptTranscript, "the same archive's transcript was dropped")
        XCTAssertEqual(TranscriptStore.read(from: kept.movedTo), .found(transcript))
        XCTAssertFalse(notKept.keptTranscript, "an archive with a track changed kept the transcript")
        XCTAssertEqual(TranscriptStore.read(from: notKept.movedTo), .missing)
    }

    /// A ZIP archive named `name` in the scene's sources, holding `entries`.
    private func writeArchive(named name: String, in scene: Scene, holding entries: [TestZIPEntry]) throws -> URL {
        let made = try makeTemporaryZip(prefix: "ReplaceArchive", orderedEntries: entries)
        let archive = scene.sources.appendingPathComponent(name)
        try FileManager.default.moveItem(at: made, to: archive)
        return archive
    }

    /// A transcript of a layout a later TextMouth writes, which this one
    /// cannot check, goes into the new copy's package as it is, rather than
    /// leave with the old package unannounced.
    func testATranscriptOfALaterLayoutGoesAsItIs() throws {
        let scene = try makeScene()
        let sound = scene.sources.appendingPathComponent("Earlier Tide.wav")
        try AudioTestFixtures.writeSilence(to: sound, duration: 1)
        let existing = try FileImportService.importFileWithReport(from: sound, toFolder: scene.shelf.path).book
        let later = Data(#"{"version": 99, "chapters": []}"#.utf8)
        try later.write(to: TextMouthPaths.transcriptPath(in: existing.tmbDirectory))
        let copy = try importAudioCopy(of: sound, named: "Tide.wav", into: scene)

        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)

        XCTAssertTrue(preparation.keptTranscript)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.transcriptPath(in: preparation.movedTo)), later)
    }

    /// Imports a copy of the audio file `sound`, named `name`, into the
    /// scene's imports folder.
    private func importAudioCopy(of sound: URL, named name: String, into scene: Scene) throws -> Book {
        let copy = scene.sources.appendingPathComponent(name)
        try FileManager.default.copyItem(at: sound, to: copy)
        return try FileImportService.importFileWithReport(from: copy, toFolder: scene.imports.path).book
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

    /// An audiobook's index whose chapters each play `file` (nil for a book
    /// of one file, whose chapters name none) for `seconds`, ten of the
    /// reader's units to the second.
    private static func audioIndex(_ chapters: [(file: String?, seconds: TimeInterval)]) -> BookContentIndex {
        var start = 0
        let entries = chapters.enumerated().map { number, chapter -> BookContentChapterIndex in
            let length = Int(chapter.seconds * ReaderViewModel.audioCharsPerSecond)
            defer { start += length }
            return BookContentChapterIndex(
                chapterIndex: number,
                title: "Chapter \(number + 1)",
                startCharacterOffset: start,
                characterCount: length,
                wordCount: 0,
                headings: [],
                audio: BookContentAudioChapterIndex(relativeFilePath: chapter.file, startTime: 0, duration: chapter.seconds)
            )
        }
        return BookContentIndex(
            version: BookContentIndex.currentVersion,
            kind: .audio,
            format: .audio,
            generatedAt: date,
            totalWordCount: 0,
            totalCharacterCount: start,
            totalAudioDuration: chapters.reduce(0) { $0 + $1.seconds },
            audioLayout: chapters.allSatisfy { $0.file != nil } ? .multiFile : .singleFile,
            chapters: entries
        )
    }

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
            brailleTableVersion: "liblouis",
            brailleFileCode: "ascii-eurobraille"
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
