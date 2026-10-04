import XCTest
@testable import TextMouth

/// Delete Transcript (FR05): offered for one transcribed audiobook, it asks
/// first, naming the book, then removes transcript.json, the content.md
/// written from it, the index's transcript layer, and the reading text this
/// Mac kept, while the audio, position, and bookmarks stay; an open reader
/// stops showing the text, the row stops saying "Transcribed", and
/// VoiceOver hears it. While the same book is transcribed it waits, and a
/// failure says why.
@MainActor
final class TranscriptDeletionTests: XCTestCase {

    // MARK: - The Command

    /// Delete Transcript… is offered for one transcribed audiobook alone,
    /// after Transcribe Audio…, under the same name in the menu and among
    /// VoiceOver's actions; never for several books, or a book without a
    /// transcript.
    func testDeleteTranscriptIsOfferedForOneTranscribedAudiobook() {
        let book = TranscriptionSheetTests.audiobook("Harbour Bells")
        let other = TranscriptionSheetTests.audiobook("Tide Clock")
        let transcribed: (UUID) -> Bool = { $0 == book.id }

        XCTAssertEqual(
            LibraryTranscriptionCommand.commands(for: [book], isTranscribed: transcribed),
            [.transcribe([book]), .deleteTranscript(book)]
        )
        XCTAssertEqual(LibraryTranscriptionCommand.commands(for: [other], isTranscribed: transcribed), [.transcribe([other])])
        XCTAssertEqual(
            LibraryTranscriptionCommand.commands(for: [book, other], isTranscribed: transcribed),
            [.transcribe([book, other])]
        )
        XCTAssertEqual(LibraryTranscriptionCommand.deleteTranscript(book).title, "Delete Transcript…")
        let row = BookRow(
            book: book,
            transcriptionNote: .transcribed,
            transcriptionCommands: LibraryTranscriptionCommand.commands(for: [book], isTranscribed: transcribed)
        )
        XCTAssertEqual(row.accessibilityActionNames, ["Transcribe Audio…", "Delete Transcript…"])
    }

    // MARK: - Deleting

    /// Deleting removes transcript.json, content.md, the index's transcript
    /// layer and the record's note of it, and the reading text this Mac
    /// kept; the audio index, the position, and the bookmarks stay.
    func testDeletingRemovesTheTranscriptItsTextAndItsLayer() throws {
        let world = try makeIntegrationWorld("Transcript Deletion")
        let book = try world.makeSilentAudioBook(
            title: "Breakwater Notes",
            trackDurations: [3, 2],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 12)
        )
        let installation = try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        let kept = ReadingTextCache.shared.url(for: book.id)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept reading text".utf8).write(to: kept)
        addTeardownBlock { ReadingTextCache.shared.remove(bookID: book.id) }

        try TranscriptStore.delete(for: book)

        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: MarkdownCacheService.cacheURL(for: book).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "the kept reading text stayed")
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertNil(record.state.transcript)
        let index = try XCTUnwrap(record.contentIndex)
        XCTAssertNil(index.transcript)
        var audioOnly = installation.index
        audioOnly.transcript = nil
        XCTAssertEqual(index, audioOnly, "the audio index changed")
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 12)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing)
        XCTAssertNil(TranscriptTextLoader.load(for: book, audioIndex: index).text)
        XCTAssertNoThrow(try TranscriptStore.delete(for: book), "deleting again failed")
    }

    /// Delete Transcript asks first, naming the book; once confirmed, the
    /// transcript goes, an open reader stops showing its text, the row's
    /// note goes, and VoiceOver hears it.
    func testDeleteAsksFirstThenDeletesAndAnnounces() async throws {
        let world = try makeIntegrationWorld("Transcript Deletion Confirmed")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        XCTAssertNotNil(reader.content?.transcript, "the reader showed no transcript before the deletion")
        let store = TranscribedBooks()
        store.record(book.id, isTranscribed: true)
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: {
            self.makeSheetServices(transcribedBooks: store, announcements: announcements)
        })

        presenter.perform(.deleteTranscript(book), library: world.library, window: nil)
        let asked = await eventuallyHolds { presenter.deletion != nil }

        XCTAssertTrue(asked, "the deletion was not confirmed first")
        let request = try XCTUnwrap(presenter.deletion)
        XCTAssertEqual(request.book.id, book.id)
        XCTAssertFalse(request.isEdited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path),
                      "the transcript went before the user confirmed")
        XCTAssertEqual(TranscriptionWording.deleteConfirmationTitle(bookTitle: book.title),
                       "Delete the Transcript of Breakwater Notes?")

        await presenter.deleteConfirmed(request)

        XCTAssertNil(presenter.deletion)
        XCTAssertNil(presenter.notice)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path))
        XCTAssertNil(reader.content?.transcript, "the reader still shows the transcript")
        XCTAssertNil(store.note(for: book.id))
        XCTAssertEqual(announcements.messages, ["Deleted the transcript of Breakwater Notes."])
    }

    /// While the same book is transcribed, Delete Transcript says to wait
    /// instead of asking, and deletes nothing.
    func testDeleteWaitsWhileTheBookIsTranscribed() async throws {
        let world = try makeIntegrationWorld("Transcript Deletion Busy")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices(center: center) })

        await presenter.confirmDeletion(of: book, library: world.library, window: nil)

        XCTAssertNil(presenter.deletion)
        XCTAssertEqual(presenter.notice?.title, "Delete Transcript")
        XCTAssertEqual(
            presenter.notice?.message,
            "Long Pier Recordings is being transcribed. Cancel the transcription first, or delete the transcript once it finishes."
        )
        center.cancel()
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never stopped")
    }

    /// A deletion that cannot remove the transcript says why, and the row
    /// keeps its note.
    func testAFailedDeletionSaysWhy() async throws {
        let world = try makeIntegrationWorld("Transcript Deletion Failure")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks),
            for: book
        )
        // A package whose files cannot be removed: put back before the
        // world's folder is removed, as tear-down blocks run in reverse.
        let package = book.tmbDirectory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: package)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: package)
        }
        let store = TranscribedBooks()
        store.record(book.id, isTranscribed: true)
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: {
            self.makeSheetServices(transcribedBooks: store, announcements: announcements)
        })
        await presenter.confirmDeletion(of: book, library: world.library, window: nil)
        let request = try XCTUnwrap(presenter.deletion)

        await presenter.deleteConfirmed(request)

        let message = try XCTUnwrap(presenter.notice?.message)
        XCTAssertTrue(message.hasPrefix("Couldn't delete the transcript of Breakwater Notes: "), message)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path))
        XCTAssertEqual(store.note(for: book.id), .transcribed)
        XCTAssertEqual(announcements.messages, [])
    }

    /// The confirmation's words, saying when the user's edits go too.
    func testTheConfirmationsWords() {
        let plain = TranscriptionWording.deleteConfirmationMessage(isEdited: false)
        let edited = TranscriptionWording.deleteConfirmationMessage(isEdited: true)
        XCTAssertTrue(plain.contains("The audiobook's audio, your place, and your bookmarks stay as they are"), plain)
        XCTAssertFalse(plain.contains("edits"))
        XCTAssertEqual(edited, plain + " Your edits to the transcript are deleted too.")
        XCTAssertEqual(TranscriptionWording.deleteButtonTitle, "Delete Transcript")
    }
}
