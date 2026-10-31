import AppKit
import Combine
import UniformTypeIdentifiers
import XCTest
@testable import TextMouth

/// Attach Transcript… (FMT23): a reader's Book menu command that gives an
/// audiobook a transcript from a WebVTT or SubRip file instead of
/// transcribing it, timed on the book's audio from its start, so one file
/// times a book of several tracks across all of them. A book that has a
/// transcript keeps it unless the listener confirms its replacement; a file
/// of another kind, one that cannot be read or was made for other audio, a
/// book only in iCloud, and a book being transcribed are each refused with
/// a notice saying why; and VoiceOver hears what was attached.
///
/// Every presenter here reaches services of the test's own
/// (`makeSheetServices`): no transcription reaches the system's recognizer,
/// and what VoiceOver would hear is recorded, not spoken. A format sample is
/// copied before it is read.
@MainActor
final class TranscriptAttachTests: XCTestCase {

    // MARK: - The Words

    /// The command's title, its Open panel's words, its notices, and its
    /// confirmation's title and button, exactly as the screen shows them and
    /// VoiceOver speaks them.
    func testTheCommandsWords() {
        XCTAssertEqual(TranscriptionWording.attachCommandTitle, "Attach Transcript…")
        XCTAssertEqual(
            TranscriptionWording.attachPanelMessage(bookTitle: "Four Tones"),
            "Choose a WebVTT (.vtt) or SubRip (.srt) transcript of Four Tones. "
                + "Its times count from the start of the book's audio."
        )
        XCTAssertEqual(TranscriptionWording.attachPanelPrompt, "Attach")
        XCTAssertEqual(TranscriptionWording.attachNoticeTitle, "Attach Transcript")
        XCTAssertEqual(
            TranscriptionWording.attachWhileTranscribing(bookTitle: "Four Tones"),
            "Four Tones is being transcribed. Cancel the transcription first, or attach the transcript once it finishes."
        )
        XCTAssertEqual(TranscriptionWording.attachUnknownFormat, "TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files.")
        XCTAssertEqual(
            TranscriptionWording.attachFailed(fileName: "tone4.vtt", bookTitle: "Four Tones", reason: "The file is damaged."),
            "“tone4.vtt” wasn't attached to Four Tones: The file is damaged."
        )
        XCTAssertEqual(TranscriptionWording.replaceConfirmationTitle(bookTitle: "Four Tones"), "Replace the Transcript of Four Tones?")
        XCTAssertEqual(TranscriptionWording.replaceButtonTitle, "Replace Transcript")
    }

    /// The confirmation's message names the file, promises that the audio,
    /// the place, and the bookmarks stay, and says when the user's edits or
    /// a cleanup go too.
    func testTheConfirmationsMessage() {
        let plain = "The transcript from “tone4.vtt” replaces the book's transcript and the text made from it. "
            + "The audiobook's audio, your place, and your bookmarks stay as they are."

        XCTAssertEqual(TranscriptionWording.replaceConfirmationMessage(fileName: "tone4.vtt", isEdited: false, isCleanedUp: false), plain)
        XCTAssertEqual(
            TranscriptionWording.replaceConfirmationMessage(fileName: "tone4.vtt", isEdited: true, isCleanedUp: false),
            plain + " Your edits to the transcript are replaced too."
        )
        XCTAssertEqual(
            TranscriptionWording.replaceConfirmationMessage(fileName: "tone4.vtt", isEdited: false, isCleanedUp: true),
            plain + " Its cleanup is replaced too."
        )
        XCTAssertEqual(
            TranscriptionWording.replaceConfirmationMessage(fileName: "tone4.vtt", isEdited: true, isCleanedUp: true),
            plain + " Your edits to the transcript are replaced too. Its cleanup is replaced too."
        )
    }

    /// What VoiceOver hears once a file is attached: the words counted with
    /// the user's grouping, one word as "1 word", then the timed passages
    /// left out, one or several, only when there are any.
    func testWhatVoiceOverHearsOnceAFileIsAttached() {
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "tone4.vtt", bookTitle: "Four Tones", wordCount: 30, skipped: 0),
            "Attached “tone4.vtt” to Four Tones: 30 words."
        )
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "lock.srt", bookTitle: "Lock Keeper", wordCount: 1, skipped: 0),
            "Attached “lock.srt” to Lock Keeper: 1 word."
        )
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "lock.srt", bookTitle: "Lock Keeper", wordCount: 7_077, skipped: 1),
            "Attached “lock.srt” to Lock Keeper: \(7_077.formatted()) words. "
                + "1 timed passage couldn't be read and was left out."
        )
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "lock.srt", bookTitle: "Lock Keeper", wordCount: 7_077, skipped: 3),
            "Attached “lock.srt” to Lock Keeper: \(7_077.formatted()) words. "
                + "3 timed passages couldn't be read and were left out."
        )
    }

    // MARK: - The Command

    /// Attach Transcript… is offered for an audiobook in a package of its
    /// own while no transcript is being attached to it, whatever is being
    /// attached to other books; never for a text book, nor for an audiobook
    /// without a package.
    func testTheCommandIsOfferedForAnAudiobookNotBeingAttachedTo() {
        let audiobook = TranscriptionSheetTests.audiobook("Harbour Bells")
        let textBook = Book(title: "Lock Keeper", format: .markdown, filePath: "/nonexistent/lock.md", md5Hash: "lock",
                            tmbDirectoryName: "lock.tmb")
        let unpackaged = Book(title: "Loose Track", format: .audio, filePath: "/nonexistent/loose.mp3", md5Hash: "loose",
                              tmbDirectoryName: "")

        XCTAssertTrue(TranscriptAttachments.canAttach(audiobook, attaching: []))
        XCTAssertTrue(TranscriptAttachments.canAttach(audiobook, attaching: [UUID()]), "another book's attaching dimmed it")
        XCTAssertFalse(TranscriptAttachments.canAttach(audiobook, attaching: [audiobook.id]))
        XCTAssertFalse(TranscriptAttachments.canAttach(textBook, attaching: []))
        XCTAssertFalse(TranscriptAttachments.canAttach(unpackaged, attaching: []))
    }

    /// The record of books being attached to holds each book once, and
    /// publishes only a change, so a book recorded twice, or ended twice,
    /// never redraws the reader's commands for nothing.
    func testTheRecordOfBooksBeingAttachedToPublishesOnlyAChange() {
        let attachments = TranscriptAttachments()
        let bookID = UUID()
        var publishes = 0
        let watcher = attachments.objectWillChange.sink { publishes += 1 }
        defer { watcher.cancel() }

        attachments.begin(bookID)
        attachments.begin(bookID)
        XCTAssertEqual(attachments.bookIDs, [bookID])
        attachments.end(bookID)
        attachments.end(bookID)

        XCTAssertEqual(attachments.bookIDs, [])
        XCTAssertEqual(publishes, 2)
    }

    // MARK: - The Open Panel

    /// The Open panel offers WebVTT and SubRip files, each by its extension.
    func testTheOpenPanelOffersWebVTTAndSubRipFiles() {
        let extensions = TranscriptAttachments.fileTypes.map { $0.tags[.filenameExtension] ?? [] }

        XCTAssertEqual(extensions.count, 2)
        XCTAssertTrue(extensions.first?.contains("vtt") == true, "\(extensions)")
        XCTAssertTrue(extensions.last?.contains("srt") == true, "\(extensions)")
    }

    /// The Open panel starts where the book was imported from: the folder of
    /// tracks it was imported from, or the folder holding the one file it
    /// was imported from; nowhere in particular when that folder is gone,
    /// or no whole path was recorded.
    func testTheOpenPanelStartsWhereTheBookWasImportedFrom() throws {
        let folder = try makeSandboxDirectory("Attach Panel Folder")
        let file = folder.appendingPathComponent("Four Tones.m4b")
        try Data("not audio".utf8).write(to: file)
        let tracks = folder.appendingPathComponent("Four Tones", isDirectory: true)
        try FileManager.default.createDirectory(at: tracks, withIntermediateDirectories: true)
        var book = TranscriptionSheetTests.audiobook("Four Tones")

        book.sourceFilePath = file.path
        XCTAssertEqual(TranscriptAttachments.startingFolder(for: book)?.path, folder.path)
        book.sourceFilePath = tracks.path
        XCTAssertEqual(TranscriptAttachments.startingFolder(for: book)?.path, tracks.path)
        book.sourceFilePath = folder.appendingPathComponent("Gone/Four Tones.m4b").path
        XCTAssertNil(TranscriptAttachments.startingFolder(for: book))
        book.sourceFilePath = "Four Tones.m4b"
        XCTAssertNil(TranscriptAttachments.startingFolder(for: book), "a name alone named the current folder")
        book.sourceFilePath = nil
        XCTAssertNil(TranscriptAttachments.startingFolder(for: book))
    }
}
