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
        // As the saving begins (follow-up 6).
        XCTAssertEqual(
            TranscriptionWording.attaching(fileName: "tone4.vtt", bookTitle: "Four Tones"),
            "Attaching “tone4.vtt” to Four Tones."
        )
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
        // Passages cut short for their length (one cue has a limit).
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "lock.srt", bookTitle: "Lock Keeper", wordCount: 30, skipped: 0, cut: 1),
            "Attached “lock.srt” to Lock Keeper: 30 words. 1 timed passage was too long and was cut short."
        )
        XCTAssertEqual(
            TranscriptionWording.attached(fileName: "lock.srt", bookTitle: "Lock Keeper", wordCount: 30, skipped: 2, cut: 2),
            "Attached “lock.srt” to Lock Keeper: 30 words. 2 timed passages couldn't be read and were left out. "
                + "2 timed passages were too long and were cut short."
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

    /// The reader's Book menu offers Attach Transcript… right after
    /// Transcribe Audio…, the other way a book gets a transcript.
    func testTheBookMenuOffersAttachTranscriptAfterTranscribeAudio() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let bookMenu = try XCTUnwrap(menu.items.first { $0.title == "Book" }?.submenu)
        let titles = bookMenu.items.map(\.title)
        let transcribe = try XCTUnwrap(titles.firstIndex {
            $0 == TranscriptionWording.transcribeCommandTitle || $0 == TranscriptionWording.retranscribeCommandTitle
        })

        XCTAssertEqual(titles.firstIndex(of: TranscriptionWording.attachCommandTitle), transcribe + 1, "\(titles)")
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

        // The panel looks off the main thread, from the path alone, and
        // gets the answer the book's own lookup gives.
        XCTAssertEqual(TranscriptAttachments.startingFolder(forSource: file.path)?.path, folder.path)
        XCTAssertEqual(TranscriptAttachments.startingFolder(forSource: tracks.path)?.path, tracks.path)
        XCTAssertNil(TranscriptAttachments.startingFolder(forSource: nil))
    }

    // MARK: - Attaching

    /// The WebVTT sample attached to a 4-second audiobook becomes its
    /// transcript, saved in its package and recording that it was attached
    /// from "tone4.vtt", its first sentence naming its speaker and its cues
    /// keeping their times; VoiceOver hears it, the row says the book is
    /// transcribed, and the book is no longer being attached to.
    func testAttachingTheWebVTTSampleMakesItTheBooksTranscript() async throws {
        let world = try makeIntegrationWorld("Attach Transcript")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let transcribedBooks = TranscribedBooks()
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: {
            self.makeSheetServices(transcribedBooks: transcribedBooks, announcements: announcements)
        })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertNil(presenter.notice, presenter.notice?.message ?? "")
        XCTAssertNil(presenter.attachReplacement, "a book without a transcript was asked about replacing one")
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("no transcript was saved")
        }
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .attached, format: .webVTT, fileName: "tone4.vtt"))
        XCTAssertEqual(transcript.files.first?.sentences.first?.text, "Ana: First tone, 440 hertz.")
        XCTAssertEqual(transcript.files.first?.sentences.map(\.startMilliseconds), [0, 1_000, 2_000, 3_000])
        XCTAssertEqual(
            announcements.messages,
            ["Attaching “tone4.vtt” to Four Tones.", "Attached “tone4.vtt” to Four Tones: 30 words."]
        )
        XCTAssertFalse(TranscriptAttachments.shared.bookIDs.contains(book.id), "the book is still being attached to")
        XCTAssertTrue(transcribedBooks.contains(book.id), "the row does not say the book is transcribed")
    }

    /// One SubRip file times a book of two 2-second tracks across both, as
    /// Export writes one: its first two cues land in the first track, and
    /// its third and fourth in the second, timed from that track's start.
    func testOneFileTimesABookOfTwoTracksAcrossBoth() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Tracks")
        let book = try world.makeSilentAudioBook(title: "Two Tones", trackDurations: [2, 2])
        let url = try copyOfFormatSample("srt/tone4.srt")
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices(announcements: announcements) })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertNil(presenter.notice, presenter.notice?.message ?? "")
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("no transcript was saved")
        }
        XCTAssertEqual(transcript.source, TranscriptSource(origin: .attached, format: .subRip, fileName: "tone4.srt"))
        XCTAssertEqual(transcript.files.map(\.path), ["01.wav", "02.wav"])
        let times = transcript.files.map { file in
            file.sentences.map { [$0.startMilliseconds, $0.endMilliseconds] }
        }
        XCTAssertEqual(times, [[[0, 900], [1_000, 1_900]], [[0, 900], [1_000, 1_900]]])
        XCTAssertEqual(
            announcements.messages,
            ["Attaching “tone4.srt” to Two Tones.", "Attached “tone4.srt” to Two Tones: 34 words."]
        )
    }

    // MARK: - Replacing a Transcript

    /// A book with a transcript the user edited is asked about first, the
    /// confirmation naming the edits and counting among the dialogs a speech
    /// refusal's report waits for, and nothing changes until Replace,
    /// which replaces the transcript. Attached again and cancelled, as the
    /// alert's Cancel or Escape closes it, the transcript stays byte for
    /// byte, nothing is announced, and the book is no longer being attached
    /// to.
    func testABooksTranscriptIsReplacedOnlyOnceTheListenerConfirms() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Replace")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let path = try XCTUnwrap(try TranscriptionPlan.make(for: book).files.first?.path)
        var edited = try TranscriptFixtures.transcript(
            of: book,
            sentences: [path: [TranscriptFixtures.sentence("Gulls circle the lock gates.", from: 0, to: 1_800)]]
        )
        edited.editedAt = TranscriptFixtures.date
        try TranscriptStore.install(edited, for: book)
        let transcriptFile = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let before = try Data(contentsOf: transcriptFile)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: {
            // The transcript as the book's package holds it at each ask.
            self.makeSheetServices(transcript: TranscriptStore.read(from: book.tmbDirectory), announcements: announcements)
        })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        let request = try XCTUnwrap(presenter.attachReplacement, "the replacement was not confirmed first")
        XCTAssertEqual(request.book.id, book.id)
        XCTAssertEqual(request.fileName, "tone4.vtt")
        XCTAssertTrue(request.isEdited)
        XCTAssertFalse(request.isCleanedUp)
        XCTAssertTrue(presenter.isShowingAny, "a speech refusal's report would not wait for the confirmation")
        XCTAssertEqual(
            TranscriptionWording.replaceConfirmationMessage(
                fileName: request.fileName,
                isEdited: request.isEdited,
                isCleanedUp: request.isCleanedUp
            ),
            "The transcript from “tone4.vtt” replaces the book's transcript and the text made from it. "
                + "The audiobook's audio, your place, and your bookmarks stay as they are. "
                + "Your edits to the transcript are replaced too."
        )
        XCTAssertTrue(TranscriptAttachments.shared.bookIDs.contains(book.id), "the book stopped being attached to while asked")
        XCTAssertEqual(try Data(contentsOf: transcriptFile), before, "the transcript changed before the listener confirmed")
        XCTAssertEqual(announcements.messages, [])

        await presenter.replaceConfirmed(request)

        XCTAssertNil(presenter.attachReplacement)
        XCTAssertNil(presenter.notice, presenter.notice?.message ?? "")
        guard case .found(let replaced) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the replacement saved no transcript")
        }
        XCTAssertEqual(replaced.source, TranscriptSource(origin: .attached, format: .webVTT, fileName: "tone4.vtt"))
        XCTAssertNil(replaced.editedAt, "the replaced transcript's edits stayed")
        XCTAssertEqual(replaced.files.first?.sentences.first?.text, "Ana: First tone, 440 hertz.")
        XCTAssertEqual(
            announcements.messages,
            ["Attaching “tone4.vtt” to Four Tones.", "Attached “tone4.vtt” to Four Tones: 30 words."]
        )
        XCTAssertFalse(TranscriptAttachments.shared.bookIDs.contains(book.id), "the book is still being attached to")

        // Attached again, and cancelled as the alert's dismissal does.
        let replacedBytes = try Data(contentsOf: transcriptFile)
        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)
        let second = try XCTUnwrap(presenter.attachReplacement, "the second replacement was not confirmed first")
        XCTAssertFalse(second.isEdited)
        presenter.attachReplacement = nil

        XCTAssertFalse(presenter.isShowingAny, "a dialog still counts once the confirmation was cancelled")
        XCTAssertEqual(try Data(contentsOf: transcriptFile), replacedBytes, "a cancelled replacement changed the transcript")
        XCTAssertFalse(TranscriptAttachments.shared.bookIDs.contains(book.id), "a cancelled replacement left the book being attached to")
        XCTAssertEqual(announcements.messages.count, 2, "a cancelled replacement was announced")
    }

    /// A transcript of a later layout, which this TextMouth cannot read, is
    /// replaced only once confirmed, though nothing can be said of its edits;
    /// a transcript set aside as unusable is replaced at once, as there is
    /// nothing in it the listener would lose.
    func testALaterLayoutIsAskedAboutAndAnUnusableTranscriptIsNot() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Layouts")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let later = TranscriptionPresenter(services: { self.makeSheetServices(transcript: .unsupportedVersion(2)) })

        await later.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        let request = try XCTUnwrap(later.attachReplacement, "a later layout's transcript was replaced unasked")
        XCTAssertFalse(request.isEdited)
        XCTAssertFalse(request.isCleanedUp)
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing, "a transcript was saved before the listener confirmed")
        later.attachReplacement = nil
        XCTAssertFalse(TranscriptAttachments.shared.bookIDs.contains(book.id), "a cancelled replacement left the book being attached to")

        let unusable = TranscriptionPresenter(services: { self.makeSheetServices(transcript: .unusable("damaged")) })
        await unusable.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertNil(unusable.attachReplacement, "an unusable transcript was asked about")
        XCTAssertNil(unusable.notice, unusable.notice?.message ?? "")
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("no transcript was saved in place of the unusable one")
        }
        XCTAssertEqual(transcript.source?.fileName, "tone4.vtt")
    }

    /// A window that closes while its confirmation shows takes its presenter
    /// with it, and the alert's dismissal may never run: the book must not
    /// stay "being attached to", which would dim Attach Transcript… for it in
    /// every window until TextMouth quits. The transcript stays byte for
    /// byte.
    func testAPresenterGoingAwayWhileAskingEndsTheAttaching() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Window Closed")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let path = try XCTUnwrap(try TranscriptionPlan.make(for: book).files.first?.path)
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(
                of: book,
                sentences: [path: [TranscriptFixtures.sentence("Gulls circle the lock gates.", from: 0, to: 1_800)]]
            ),
            for: book
        )
        let transcriptFile = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let before = try Data(contentsOf: transcriptFile)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        var presenter: TranscriptionPresenter? = TranscriptionPresenter(services: {
            self.makeSheetServices(transcript: TranscriptStore.read(from: book.tmbDirectory))
        })
        await presenter?.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)
        XCTAssertNotNil(presenter?.attachReplacement, "the replacement was not confirmed first")
        XCTAssertTrue(TranscriptAttachments.shared.bookIDs.contains(book.id), "the book stopped being attached to while asked")

        // The window closes: nothing else is told.
        presenter = nil

        let ended = await eventuallyHolds { !TranscriptAttachments.shared.bookIDs.contains(book.id) }
        XCTAssertTrue(ended, "the book is still being attached to after its window closed")
        XCTAssertEqual(try Data(contentsOf: transcriptFile), before, "the transcript changed without the listener's say")
    }

    // MARK: - Refusals

    /// A .vtt file without its WEBVTT line is refused with the reader's own
    /// reason, and nothing is saved.
    func testAFileThatIsNotWebVTTIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Garbage")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try makeSandboxDirectory("Attach Garbage").appendingPathComponent("garbage.vtt")
        try Data("Gulls circle the lock gates.\n\n00:00.000 --> 00:01.000\nNo signature line above.\n".utf8).write(to: url)
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(
            presenter.notice?.message,
            "“garbage.vtt” wasn't attached to Four Tones: The file isn't a WebVTT transcript TextMouth can read."
        )
        assertNothingAttached(to: book, by: presenter)
    }

    /// A file whose last cue ends at 20 seconds, made for other audio than a
    /// 4-second book's, is refused, saying how far past the audio it runs.
    func testAFileRunningPastTheEndOfTheAudioIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Too Long")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try makeSandboxDirectory("Attach Too Long").appendingPathComponent("lecture.vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nThe lock opens.\n\n00:19.000 --> 00:20.000\nThe barge goes through.\n".utf8)
            .write(to: url)
        let audioEnd = try TranscriptionPlan.make(for: book).files.reduce(0) { $0 + Transcript.milliseconds($1.duration) }
        let reason = try XCTUnwrap(OutsideTranscriptError.runsPastTheEnd(transcriptEnd: 20_000, audioEnd: audioEnd).errorDescription)
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(presenter.notice?.message, "“lecture.vtt” wasn't attached to Four Tones: \(reason)")
        assertNothingAttached(to: book, by: presenter)
    }

    /// Only a regular file, or a link to one, is read: a named pipe, which
    /// would wait for ever, a folder, and nothing at all are not.
    func testOnlyARegularFileIsRead() throws {
        let folder = try makeSandboxDirectory("Attach Regular")
        let file = folder.appendingPathComponent("lecture.vtt")
        try Data("WEBVTT\n".utf8).write(to: file)
        let link = folder.appendingPathComponent("link.vtt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let pipe = folder.appendingPathComponent("pipe.vtt")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        let directory = folder.appendingPathComponent("folder.vtt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)

        XCTAssertTrue(TranscriptAttachments.isReadableFile(at: file))
        XCTAssertTrue(TranscriptAttachments.isReadableFile(at: link))
        XCTAssertFalse(TranscriptAttachments.isReadableFile(at: pipe))
        XCTAssertFalse(TranscriptAttachments.isReadableFile(at: directory))
        XCTAssertFalse(TranscriptAttachments.isReadableFile(at: folder.appendingPathComponent("missing.vtt")))
    }

    /// A folder named like a transcript is refused with its own reason, and
    /// nothing is attached or left being attached to.
    func testAFolderNamedLikeATranscriptIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Folder")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try makeSandboxDirectory("Attach Folder").appendingPathComponent("lecture.vtt", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(
            presenter.notice?.message,
            "“lecture.vtt” wasn't attached to Four Tones: That item isn't a plain file TextMouth can read."
        )
        assertNothingAttached(to: book, by: presenter)
    }

    /// A file of another kind is refused by its name, whatever it holds: the
    /// WebVTT sample named as plain text is not read.
    func testAFileOfAnotherKindIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Text File")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try copyOfFormatSample("vtt/tone4.vtt", named: "tone4.txt")
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(
            presenter.notice?.message,
            "“tone4.txt” wasn't attached to Four Tones: TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files."
        )
        assertNothingAttached(to: book, by: presenter)
    }

    /// A book whose transcript is only in iCloud keeps it, neither read nor
    /// replaced, and one whose text is only there keeps that: each notice
    /// says to download the book first.
    func testABookOnlyInICloudIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Cloud")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let transcriptInCloud = TranscriptionPresenter(services: { self.makeSheetServices(transcript: .inCloud) })
        let textInCloud = TranscriptionPresenter(services: { self.makeSheetServices(textInCloud: true) })

        await transcriptInCloud.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)
        await textInCloud.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(
            transcriptInCloud.notice?.message,
            "“tone4.vtt” wasn't attached to Four Tones: The book's transcript is only in iCloud, "
                + "so TextMouth leaves it as it is. Download the book, then try again."
        )
        XCTAssertEqual(
            textInCloud.notice?.message,
            "“tone4.vtt” wasn't attached to Four Tones: The book's text is only in iCloud, "
                + "so TextMouth leaves it as it is. Download the book, then try again."
        )
        assertNothingAttached(to: book, by: transcriptInCloud)
        assertNothingAttached(to: book, by: textInCloud)
    }

    /// While the same book is being transcribed, the command says to wait
    /// instead of opening its Open panel, and a file chosen before the
    /// transcription began is not attached.
    func testABookBeingTranscribedIsRefused() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Busy")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices(center: center) })

        presenter.chooseTranscriptFile(for: book, library: world.library, window: nil)

        XCTAssertFalse(presenter.isChoosingTranscriptFile, "the Open panel opened")
        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(presenter.notice?.message, Self.waitWhileTranscribing("Long Pier Recordings"))

        presenter.notice = nil
        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)

        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(presenter.notice?.message, Self.waitWhileTranscribing("Long Pier Recordings"))
        assertNothingAttached(to: book, by: presenter)
        center.cancel()
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never stopped")
    }

    /// Transcribe Audio… is not offered for an audiobook a transcript is being
    /// attached to, and is again once that ends (follow-up 7); asked for all
    /// the same, as from a library row, it opens no sheet and says to wait.
    func testTranscribeAudioWaitsWhileATranscriptIsBeingAttached() throws {
        let world = try makeIntegrationWorld("Attach Transcript Transcribe")
        let book = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let text = Book(title: "Harbour Notes", format: .markdown, filePath: "/Harbour Notes.md", md5Hash: "")
        XCTAssertTrue(TranscriptAttachments.canTranscribe(book, attaching: []))
        XCTAssertFalse(TranscriptAttachments.canTranscribe(book, attaching: [book.id]))
        XCTAssertFalse(TranscriptAttachments.canTranscribe(text, attaching: []))
        let attachments = TranscriptAttachments.shared
        attachments.begin(book.id)
        defer { attachments.end(book.id) }
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        presenter.transcribe([book], library: world.library, window: nil)

        XCTAssertNil(presenter.sheet, "the sheet opened while a transcript was being attached")
        XCTAssertEqual(presenter.notice?.title, "Transcribe Audio")
        XCTAssertEqual(
            presenter.notice?.message,
            "A transcript is being attached to Four Tones. Transcribe it once that finishes."
        )

        attachments.end(book.id)
        presenter.notice = nil
        presenter.transcribe([book], library: world.library, window: nil)

        XCTAssertNotNil(presenter.sheet, "the sheet did not open once the attaching ended")
        XCTAssertNil(presenter.notice)
    }

    /// The wait covers every request, not only a one-book request: a
    /// selection of several rows that includes a book a transcript is being
    /// attached to opens no sheet either, in whatever place the book stands
    /// in the list, and says which book to wait for. A selection of other
    /// books is untouched by it.
    func testTranscribeAudioWaitsForABookAmongSeveral() throws {
        let world = try makeIntegrationWorld("Attach Transcript Transcribe Several")
        let attached = try world.makeSilentAudioFileBook(title: "Four Tones", duration: 4)
        let other = try world.makeSilentAudioFileBook(title: "Long Pier", duration: 4)
        let attachments = TranscriptAttachments.shared
        attachments.begin(attached.id)
        defer { attachments.end(attached.id) }
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices() })

        for books in [[attached, other], [other, attached]] {
            presenter.notice = nil
            presenter.transcribe(books, library: world.library, window: nil)

            XCTAssertNil(presenter.sheet, "a sheet opened for \(books.map(\.title)) while a transcript was being attached")
            XCTAssertEqual(
                presenter.notice?.message,
                "A transcript is being attached to Four Tones. Transcribe it once that finishes.",
                "the notice for \(books.map(\.title)) did not name the book being attached to"
            )
        }

        // Books none of which is being attached to still reach the sheet
        // (which, for several books, says why it cannot transcribe them).
        presenter.notice = nil
        presenter.transcribe([other], library: world.library, window: nil)
        XCTAssertNotNil(presenter.sheet, "a book not being attached to was refused")
        XCTAssertNil(presenter.notice)
    }

    /// A transcription of the book begun while the confirmation showed keeps
    /// Replace from attaching, since it would save its own transcript over
    /// the file's: the notice says to wait, the transcript stays byte for
    /// byte, and the book is no longer being attached to.
    func testATranscriptionBegunWhileAskingKeepsReplaceFromAttaching() async throws {
        let world = try makeIntegrationWorld("Attach Transcript Busy Later")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(
                of: book,
                sentences: ["01.wav": [TranscriptFixtures.sentence("Bollards line the old pier.", from: 0, to: 1_500)]]
            ),
            for: book
        )
        let transcriptFile = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        let before = try Data(contentsOf: transcriptFile)
        let url = try copyOfFormatSample("vtt/tone4.vtt")
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        let announcements = SheetAnnouncements()
        let presenter = TranscriptionPresenter(services: {
            self.makeSheetServices(
                transcript: TranscriptStore.read(from: book.tmbDirectory),
                center: center,
                announcements: announcements
            )
        })
        await presenter.attachTranscript(fileAt: url, to: book, library: world.library, window: nil)
        let request = try XCTUnwrap(presenter.attachReplacement, "the replacement was not confirmed first")
        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))

        await presenter.replaceConfirmed(request)

        XCTAssertEqual(presenter.notice?.title, "Attach Transcript")
        XCTAssertEqual(presenter.notice?.message, Self.waitWhileTranscribing("Long Pier Recordings"))
        XCTAssertEqual(try Data(contentsOf: transcriptFile), before, "the file was attached during the transcription")
        XCTAssertEqual(announcements.messages, [])
        XCTAssertFalse(TranscriptAttachments.shared.bookIDs.contains(book.id), "the book is still being attached to")
        center.cancel()
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never stopped")
    }

    // MARK: - Helpers

    /// What the notice says while the book `bookTitle` is being transcribed,
    /// as `testTheCommandsWords` pins it.
    private static func waitWhileTranscribing(_ bookTitle: String) -> String {
        "\(bookTitle) is being transcribed. Cancel the transcription first, or attach the transcript once it finishes."
    }

    /// Checks that nothing was attached to `book` through `presenter`: no
    /// transcript in its package, no confirmation showing, and the book no
    /// longer being attached to.
    private func assertNothingAttached(
        to book: Book,
        by presenter: TranscriptionPresenter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .missing, "a transcript was saved", file: file, line: line)
        XCTAssertNil(presenter.attachReplacement, "a replacement was asked about", file: file, line: line)
        XCTAssertFalse(
            TranscriptAttachments.shared.bookIDs.contains(book.id),
            "the book is still being attached to",
            file: file,
            line: line
        )
    }
}
