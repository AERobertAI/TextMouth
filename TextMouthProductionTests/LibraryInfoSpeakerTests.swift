import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import TextMouth

/// A synthesizer that records what it is told and plays nothing, standing
/// in for the app's in every test of Speak Info.
final class InfoSynthesizerRecorder: LibraryInfoSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    /// Every utterance it was told to speak, in order.
    private(set) var utterances: [AVSpeechUtterance] = []
    /// How many times it was told to stop.
    private(set) var stops = 0

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        return true
    }

    /// The texts it was told to speak, in order.
    var spoken: [String] {
        utterances.map(\.speechString)
    }
}

/// Speak Info's speaker (October 7, 2026; FR12): Speak Info's brief summary
/// and Speak Full Info's full one, each press doing what section 3 of the
/// design says with nothing speaking, the brief summary speaking, or the
/// full one; each summary tied to the row it describes (REV07, Library
/// finding 2); a summary's end told by its utterance, and a cancel nobody
/// asked for ending it and replacing the synthesizer (finding 4); with the
/// app's own voice and speed, through a recorder, so no test plays sound;
/// and the Library window's part: which row is spoken, the facts gathered
/// for it, and I, I twice, and Command-I in a hosted window.
@MainActor
final class LibraryInfoSpeakerTests: XCTestCase {

    // MARK: - Fixtures

    /// The moment every press is made at.
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A folder's facts, whose summaries differ between brief and full.
    private let classics = LibraryInfoSubject.folder(
        FolderInfoFacts(name: "Classics", bookCount: 2, unopenedCount: 1, feedCount: 0, subfolderCount: 1, timeRemaining: 120)
    )

    /// Another folder's facts, for a press on another row.
    private let history = LibraryInfoSubject.folder(
        FolderInfoFacts(name: "History", bookCount: 1, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil)
    )

    /// The IDs of Classics' row and History's.
    private let classicsRow = UUID()
    private let historyRow = UUID()

    /// The recorders a speaker made, oldest first.
    private final class Recorders {
        var made: [InfoSynthesizerRecorder] = []
    }

    /// A speaker speaking through a recorder, which also stands in for any
    /// fresh synthesizer it makes.
    private func makeSpeaker() -> (speaker: LibraryInfoSpeaker, recorder: InfoSynthesizerRecorder) {
        let recorder = InfoSynthesizerRecorder()
        return (LibraryInfoSpeaker(synthesizer: recorder), recorder)
    }

    /// A speaker making a fresh recorder for each synthesizer it makes, with
    /// the recorders it made.
    private func makeSpeakerCountingSynthesizers() -> (speaker: LibraryInfoSpeaker, recorders: Recorders) {
        let recorders = Recorders()
        let speaker = LibraryInfoSpeaker(makingSynthesizersWith: {
            let recorder = InfoSynthesizerRecorder()
            recorders.made.append(recorder)
            return recorder
        })
        return (speaker, recorders)
    }

    /// Presses `detail` on the row `row`, whose facts are `subject`, at
    /// `start`, and returns what was spoken, or nil for a stop.
    @discardableResult
    private func press(_ detail: SummaryDetail, on speaker: LibraryInfoSpeaker, row: UUID?, subject: LibraryInfoSubject?) -> String? {
        speaker.press(detail, about: row, voice: nil, wordsPerMinute: 200, now: start) { _ in subject }
    }

    /// Presses `detail` on Classics' row.
    @discardableResult
    private func pressOnClassics(_ detail: SummaryDetail, _ speaker: LibraryInfoSpeaker) -> String? {
        press(detail, on: speaker, row: classicsRow, subject: classics)
    }

    /// Tells `recorder`'s delegate, as a synthesizer tells it on the main
    /// thread, that `utterance` finished, or was cancelled when `cancelled`.
    private func report(
        _ utterance: AVSpeechUtterance?,
        to recorder: InfoSynthesizerRecorder,
        cancelled: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let utterance, let delegate = recorder.delegate else {
            return XCTFail("no utterance, or nothing hears the synthesizer", file: file, line: line)
        }
        // A synthesizer that speaks nothing here stands in for the one
        // reporting.
        let synthesizer = AVSpeechSynthesizer()
        if cancelled {
            delegate.speechSynthesizer?(synthesizer, didCancel: utterance)
        } else {
            delegate.speechSynthesizer?(synthesizer, didFinish: utterance)
        }
    }

    // MARK: - Pressing

    /// A brief press speaks the brief summary with the chosen voice at the
    /// chosen speed, never VoiceOver's, and the speaker knows it speaks it.
    func testABriefPressSpeaksTheBriefSummaryWithTheChosenVoiceAndSpeed() throws {
        let (speaker, recorder) = makeSpeaker()
        let voice = AVSpeechSynthesisVoice.speechVoices().first
        var asked: [SummaryDetail] = []

        let text = speaker.press(.brief, about: classicsRow, voice: voice, wordsPerMinute: 250, now: start) { spoken in
            asked.append(spoken)
            return classics
        }

        XCTAssertEqual(text, LibraryInfoWording.brief(classics))
        XCTAssertEqual(text, "Classics. Folder. 2 books, 1 unopened.")
        XCTAssertEqual(recorder.spoken, [text])
        XCTAssertEqual(asked, [.brief])
        XCTAssertTrue(speaker.isSpeaking)
        XCTAssertEqual(speaker.detailSpeaking, .brief)
        XCTAssertEqual(speaker.lastSpokenText, text)
        let utterance = try XCTUnwrap(recorder.utterances.first)
        XCTAssertEqual(utterance.rate, SpeechService.rateForWPM(250))
        XCTAssertFalse(utterance.prefersAssistiveTechnologySettings)
        XCTAssertEqual(utterance.voice?.identifier, voice?.identifier)
        XCTAssertNotNil(recorder.delegate, "nothing tells the speaker when the summary ends")
    }

    /// Each press does what section 3 of the design says: with nothing
    /// speaking, it speaks the summary pressed for; a brief press stops the
    /// summary speaking; a full press switches the brief summary to the full
    /// one, asking for the full one's facts, and stops the full one. A stop
    /// asks for no facts and speaks nothing.
    func testEachPressDoesWhatTheDesignSays() {
        let brief = LibraryInfoWording.brief(classics)
        let full = LibraryInfoWording.full(classics, now: start)
        XCTAssertEqual(full, "Classics. Folder. 2 books, 1 unopened. 1 subfolder. 2 minutes remaining in total.")
        // What speaks, the press, what the press speaks (nil for a stop),
        // and what speaks after it.
        let cases: [(speaking: SummaryDetail?, pressed: SummaryDetail, spoken: String?, after: SummaryDetail?)] = [
            (nil, .brief, brief, .brief),
            (nil, .full, full, .full),
            (.brief, .brief, nil, nil),
            (.brief, .full, full, .full),
            (.full, .brief, nil, nil),
            (.full, .full, nil, nil),
        ]
        for (speaking, pressed, spoken, after) in cases {
            let (speaker, recorder) = makeSpeaker()
            if let speaking {
                pressOnClassics(speaking, speaker)
            }
            let stopsBefore = recorder.stops
            let utterancesBefore = recorder.utterances.count
            var asked: [SummaryDetail] = []

            let text = speaker.press(pressed, about: classicsRow, voice: nil, wordsPerMinute: 200, now: start) { detail in
                asked.append(detail)
                return classics
            }

            let label = "\(pressed) pressed while \(speaking.map { "\($0)" } ?? "nothing") speaks"
            XCTAssertEqual(text, spoken, label)
            XCTAssertEqual(speaker.detailSpeaking, after, label)
            XCTAssertEqual(asked, spoken == nil ? [] : [pressed], label)
            XCTAssertEqual(recorder.utterances.count, utterancesBefore + (spoken == nil ? 0 : 1), label)
            if speaking != nil {
                XCTAssertGreaterThan(recorder.stops, stopsBefore, "\(label): the summary speaking was not silenced")
            }
        }
    }

    /// The three-second rule is retired (question 4): however soon after
    /// the last summary, a brief press speaks the brief summary and never
    /// the full one unasked, after a summary that ended as after one a
    /// press stopped.
    func testABriefPressNeverSpeaksTheFullSummaryUnasked() {
        let (speaker, recorder) = makeSpeaker()
        let brief = LibraryInfoWording.brief(classics)

        XCTAssertEqual(pressOnClassics(.brief, speaker), brief)
        report(recorder.utterances.last, to: recorder)
        XCTAssertEqual(pressOnClassics(.brief, speaker), brief, "a press just after a summary ended")
        XCTAssertNil(pressOnClassics(.brief, speaker))
        XCTAssertEqual(pressOnClassics(.brief, speaker), brief, "a press just after a stop")

        XCTAssertEqual(recorder.spoken, [brief, brief, brief])
    }

    /// With nothing selected, a press of either summary says so, and a
    /// brief press while it says so stops it, as for a row.
    func testNothingSelectedIsSaidForEitherSummary() {
        let (speaker, recorder) = makeSpeaker()

        XCTAssertEqual(press(.brief, on: speaker, row: nil, subject: nil), "Nothing is selected.")
        report(recorder.utterances.last, to: recorder)
        XCTAssertEqual(press(.full, on: speaker, row: nil, subject: nil), "Nothing is selected.")
        XCTAssertNil(press(.brief, on: speaker, row: nil, subject: nil))

        XCTAssertEqual(recorder.spoken, ["Nothing is selected.", "Nothing is selected."])
    }

    // MARK: - A Summary Tied to Its Row (REV07, Library Finding 2)

    /// A press on another row while a summary speaks speaks that row's
    /// summary in its place, the one the press asks for, rather than only
    /// stopping the summary speaking; and a full press on the row the brief
    /// summary describes switches to that row's full summary.
    func testAPressOnAnotherRowSpeaksThatRowsSummary() {
        let (speaker, recorder) = makeSpeaker()
        pressOnClassics(.brief, speaker)

        XCTAssertEqual(press(.brief, on: speaker, row: historyRow, subject: history), LibraryInfoWording.brief(history))
        XCTAssertEqual(press(.full, on: speaker, row: historyRow, subject: history), LibraryInfoWording.full(history, now: start))
        XCTAssertEqual(pressOnClassics(.brief, speaker), LibraryInfoWording.brief(classics), "a brief press on another row while a full summary speaks")
        XCTAssertEqual(press(.full, on: speaker, row: nil, subject: nil), "Nothing is selected.", "a press once nothing is selected")
        XCTAssertNil(press(.brief, on: speaker, row: nil, subject: nil), "a press with still nothing selected stops it")

        XCTAssertEqual(recorder.spoken.count, 5)
    }

    // MARK: - How a Summary Ends (REV07, Library Finding 4)

    /// The end of the summary speaking ends it, so the next press speaks:
    /// the synthesizer's delegate is told on the main thread and ends it at
    /// once.
    func testTheSynthesizersDelegateEndsTheSummary() {
        let (speaker, recorder) = makeSpeaker()
        pressOnClassics(.brief, speaker)

        report(recorder.utterances.last, to: recorder)

        XCTAssertFalse(speaker.isSpeaking, "the summary never ended")
        XCTAssertEqual(pressOnClassics(.brief, speaker), LibraryInfoWording.brief(classics))
    }

    /// A cancel nobody asked for, as when the speech engine refuses the
    /// summary's text, ends the summary, so the next press speaks rather
    /// than stopping nothing (board #1378), and replaces the synthesizer,
    /// which would never speak again: the next summary speaks through a
    /// fresh one, and the old one is let go. The debug log says so.
    func testACancelNobodyAskedForEndsTheSummaryAndReplacesTheSynthesizer() throws {
        let (speaker, recorders) = makeSpeakerCountingSynthesizers()
        pressOnClassics(.brief, speaker)
        let refused = try XCTUnwrap(recorders.made.first)

        report(refused.utterances.last, to: refused, cancelled: true)

        XCTAssertFalse(speaker.isSpeaking, "the speaking flag stuck after the cancel")
        XCTAssertEqual(recorders.made.count, 2, "the synthesizer that refused was kept")
        XCTAssertNil(refused.delegate, "the refused synthesizer still reports to the speaker")
        XCTAssertEqual(pressOnClassics(.brief, speaker), LibraryInfoWording.brief(classics))
        XCTAssertEqual(recorders.made.last?.spoken, [LibraryInfoWording.brief(classics)])
        XCTAssertEqual(refused.spoken.count, 1)
        XCTAssertFalse(debugLogLines(containing: "SPEAK_INFO_CANCEL_UNEXPECTED").isEmpty)
    }

    /// The end of a summary the speaker stopped or replaced changes nothing.
    /// A summary that takes the place of one still speaking, here the full
    /// one after the brief, speaks on a fresh synthesizer, and the one that
    /// spoke the brief summary is silenced and let go with its delegate, so
    /// nothing it reports reaches the speaker: on the same synthesizer, the
    /// new summary could be cancelled with the old, and that cancel taken
    /// for one nobody asked for would end it at once. The end of a summary
    /// a press stopped, reported by the synthesizer that spoke it, ends no
    /// summary speaking after it, and the synthesizer is kept.
    func testTheEndOfAStoppedOrReplacedSummaryChangesNothing() throws {
        let (speaker, recorders) = makeSpeakerCountingSynthesizers()
        pressOnClassics(.brief, speaker)
        let briefSynthesizer = try XCTUnwrap(recorders.made.first)
        pressOnClassics(.full, speaker)

        XCTAssertEqual(recorders.made.count, 2, "the full summary did not speak on a fresh synthesizer")
        let fullSynthesizer = try XCTUnwrap(recorders.made.last)
        let full = try XCTUnwrap(fullSynthesizer.utterances.last)
        XCTAssertEqual(full.speechString, LibraryInfoWording.full(classics, now: start))
        XCTAssertNil(briefSynthesizer.delegate, "the brief summary's synthesizer still reports to the speaker")
        XCTAssertGreaterThan(briefSynthesizer.stops, 0, "the brief summary was not silenced")
        XCTAssertEqual(speaker.detailSpeaking, .full)

        XCTAssertNil(pressOnClassics(.full, speaker), "a full press stops the full summary")
        report(full, to: fullSynthesizer, cancelled: true)
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(recorders.made.count, 2, "a cancel the speaker asked for replaced the synthesizer")
        XCTAssertEqual(pressOnClassics(.brief, speaker), LibraryInfoWording.brief(classics))
        XCTAssertEqual(recorders.made.count, 2, "a summary with nothing speaking took a fresh synthesizer")
        report(full, to: fullSynthesizer)
        XCTAssertEqual(speaker.detailSpeaking, .brief, "the stopped summary's finish ended the one speaking")
    }

    // MARK: - The Text of a Press

    /// The text of a press is the wording's: its subject's brief summary or
    /// full one, or, with no subject, that nothing is selected, whichever
    /// summary was asked for.
    func testTheTextOfAPressIsTheWordings() {
        XCTAssertEqual(LibraryInfoSpeaker.text(for: nil, detail: .brief, now: start), LibraryInfoWording.nothingSelected)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: nil, detail: .full, now: start), LibraryInfoWording.nothingSelected)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, detail: .brief, now: start), LibraryInfoWording.brief(classics))
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, detail: .full, now: start), LibraryInfoWording.full(classics, now: start))
    }

    /// A title holding a tag-shaped run the synthesizer would take as
    /// markup is handed over neutralized, as every book text is, and the
    /// text the press reports stays the wording's.
    func testTitlesWithSynthesizerMarkupAreNeutralized() throws {
        let (speaker, recorder) = makeSpeaker()
        let marked = LibraryInfoSubject.folder(
            FolderInfoFacts(name: "<sm>Classics</sm>", bookCount: 1, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil)
        )

        let text = try XCTUnwrap(speaker.press(.brief, about: nil, voice: nil, wordsPerMinute: 200, now: start) { _ in marked })

        XCTAssertEqual(text, "<sm>Classics</sm>. Folder. 1 book.")
        XCTAssertEqual(recorder.spoken, [SpeechMarkupGuard.neutralized(text)])
        XCTAssertEqual(recorder.spoken, ["\u{2039}sm\u{203A}Classics\u{2039}/sm\u{203A}. Folder. 1 book."])
        XCTAssertNotEqual(recorder.spoken.first, text)
        XCTAssertEqual(recorder.spoken.first?.utf16.count, text.utf16.count)
    }

    /// The app's own synthesizer is what a speaker made without one speaks
    /// through; made here, it speaks nothing.
    func testTheAppsSynthesizerIsTheDefault() {
        let synthesizer = LibraryInfoSpeaker.makeSynthesizer()
        XCTAssertTrue(synthesizer is AVSpeechSynthesizer)
        XCTAssertNil(synthesizer.delegate)
    }

    // MARK: - The Selected Row

    /// The row the window's commands act on is the first selected row in
    /// the list's order, a folder's or a feed's as a book's; the edit
    /// selection's first book when the List selects none of the rows shown;
    /// nothing otherwise.
    func testTheSelectedRowIsTheFirstInListOrderOrTheEditSelectionsFirstBook() {
        let folders = [BookFolder(name: "Classics"), BookFolder(name: "History")]
        let feed = FeedRowContent(
            id: UUID(),
            title: "Planet Money",
            folderPath: "Podcasts/Planet Money",
            counts: FeedItemCounts(),
            check: FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        )
        let books = [
            Book(title: "First", format: .txt, filePath: "/nonexistent/first.txt", md5Hash: "first"),
            Book(title: "Second", format: .txt, filePath: "/nonexistent/second.txt", md5Hash: "second"),
        ]
        func selected(_ ids: Set<UUID>, edit: Set<UUID> = []) -> LibraryInfoRow? {
            LibraryInfoRow.selected(ids, editSelection: edit, folders: folders, feeds: [feed], books: books)
        }

        XCTAssertEqual(selected([books[1].id]), .book(books[1]))
        XCTAssertEqual(selected([books[0].id, books[1].id]), .book(books[0]))
        XCTAssertEqual(selected([folders[1].id, books[0].id]), .folder(folders[1]))
        XCTAssertEqual(selected([feed.id, books[0].id]), .feed(feed))
        XCTAssertEqual(selected([folders[0].id, feed.id]), .folder(folders[0]))
        XCTAssertEqual(selected([], edit: [books[1].id]), .book(books[1]))
        XCTAssertEqual(selected([UUID()], edit: [books[1].id]), .book(books[1]))
        XCTAssertNil(selected([UUID()]))
        XCTAssertNil(selected([]))
    }

    /// Command-I opens Book Info for a book's row and Feed Info for a
    /// feed's row or a feed's folder, by the feed's ID, and speaks a plain
    /// folder's full summary, since a folder has no sheet (REV07, Library
    /// finding 8: what Command-I does for each row, not only that a feed's
    /// row speaks nothing).
    func testCommandIOpensEachRowsInfo() {
        let book = Book(title: "First", format: .txt, filePath: "/nonexistent/first.txt", md5Hash: "first")
        let plain = BookFolder(name: "Classics")
        let feedsFolder = BookFolder(name: "Planet Money")
        let feedID = UUID()
        let feed = FeedRowContent(
            id: feedID,
            title: "Planet Money",
            folderPath: "Podcasts/Planet Money",
            counts: FeedItemCounts(),
            check: FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        )
        /// The feed whose folder is `folderID`: Planet Money's alone.
        func feedInFolder(_ folderID: UUID) -> UUID? {
            folderID == feedsFolder.id ? feedID : nil
        }

        XCTAssertEqual(LibraryInfoRow.book(book).infoCommand(feedInFolder: feedInFolder), .bookInfo(book))
        XCTAssertEqual(LibraryInfoRow.feed(feed).infoCommand(feedInFolder: feedInFolder), .feedInfo(feedID))
        XCTAssertEqual(LibraryInfoRow.folder(feedsFolder).infoCommand(feedInFolder: feedInFolder), .feedInfo(feedID))
        XCTAssertEqual(LibraryInfoRow.folder(plain).infoCommand(feedInFolder: feedInFolder), .speakFullInfo)
    }

    /// A row's identity, by which a summary is tied to the row it
    /// describes, is its book's, folder's, or feed's ID.
    func testARowsIdentityIsItsBooksFoldersOrFeedsID() {
        let book = Book(title: "First", format: .txt, filePath: "/nonexistent/first.txt", md5Hash: "first")
        let folder = BookFolder(name: "Classics")
        let feed = FeedRowContent(
            id: UUID(),
            title: "Planet Money",
            folderPath: nil,
            counts: FeedItemCounts(),
            check: FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        )

        XCTAssertEqual(LibraryInfoRow.book(book).id, book.id)
        XCTAssertEqual(LibraryInfoRow.folder(folder).id, folder.id)
        XCTAssertEqual(LibraryInfoRow.feed(feed).id, feed.id)
    }

    // MARK: - A Book's Facts

    /// A book's facts are its row's: the progress and time left from its
    /// reader's live position when that is newer, the cloud note and the
    /// kept note in a cloud library and neither on this Mac, whether a
    /// reader has it open, and its file size, measured only for the full
    /// summary and never for a book in the cloud.
    func testABooksFactsAreItsRowsAndTheFileSizeIsMeasuredOnlyForTheFullSummary() throws {
        let sandbox = try makeSandboxDirectory("SpeakInfoBookFacts")
        let file = sandbox.appendingPathComponent("Middlemarch.txt")
        try Data(repeating: 0x61, count: 4_096).write(to: file)
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let book = Book(
            title: "Middlemarch",
            author: "George Eliot",
            format: .txt,
            filePath: file.path,
            md5Hash: "middlemarch",
            folderPath: "Classics",
            dateAdded: added,
            lastOpened: added.addingTimeInterval(3_600),
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 50_000),
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 10), Bookmark(number: 2, chapterIndex: 0, characterOffset: 20)],
            totalWordCount: 80_000,
            totalCharacterCount: 200_000
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book], folders: [BookFolder(name: "Classics")])
        library.openBookIDs = [book.id]
        let kept = KeptBooks(file: nil)
        kept.keep([book.id])
        func facts(_ book: Book, cloud: BookCloudStates, full: Bool) -> BookInfoFacts {
            BookInfoFacts(book, library: library, wordsPerMinute: 200, cloudStates: cloud, keptBooks: kept, measuresFileSize: full)
        }

        // On this Mac: no cloud note, and kept says nothing.
        let local = BookCloudStates()
        XCTAssertEqual(facts(book, cloud: local, full: true), BookInfoFacts(
            title: "Middlemarch",
            author: "George Eliot",
            format: "Plain Text",
            folderPath: "Classics",
            progress: "25 percent",
            timeRemaining: book.estimatedTimeRemaining(wpm: 200),
            isUnopened: false,
            dateAdded: added,
            lastOpened: book.lastOpened,
            bookmarkCount: 2,
            fileSize: 4_096,
            cloudNote: nil,
            isKeptOnThisMac: false,
            isOpenInWindow: true
        ))
        XCTAssertEqual(facts(book, cloud: local, full: true).progress, BookRow.spokenProgress(for: book, besideDownloadPercentage: false))
        XCTAssertNil(facts(book, cloud: local, full: false).fileSize, "the brief summary measured the file")

        // The reader's live position, newer than the row's, is the row's.
        library.livePositions.update(ReadingPosition(chapterIndex: 0, characterOffset: 100_000), of: book)
        let live = facts(book, cloud: local, full: false)
        XCTAssertEqual(live.progress, "50 percent")
        XCTAssertEqual(live.timeRemaining, library.livePositions.applied(to: book).estimatedTimeRemaining(wpm: 200))

        // In a cloud library: the note, the kept note, and no measured size
        // for a book in the cloud, which must never be downloaded for it.
        let cloud = BookCloudStates()
        cloud.setLibraryLocation(.cloud(.iCloudDrive))
        cloud.record(.inCloud, for: book.id)
        let inCloud = facts(book, cloud: cloud, full: true)
        XCTAssertEqual(inCloud.cloudNote, "In Cloud")
        XCTAssertTrue(inCloud.isKeptOnThisMac)
        XCTAssertNil(inCloud.fileSize)
        cloud.record(.downloaded, for: book.id)
        XCTAssertEqual(facts(book, cloud: cloud, full: true).fileSize, 4_096)
        XCTAssertEqual(facts(book, cloud: cloud, full: true).cloudNote, "Downloaded")

        // A book never opened, with no position and no file to measure.
        let draft = facts(Book(title: "Draft", format: .txt, filePath: "/nonexistent/draft.txt", md5Hash: "draft"), cloud: local, full: true)
        XCTAssertTrue(draft.isUnopened)
        XCTAssertNil(draft.progress)
        XCTAssertNil(draft.timeRemaining)
        XCTAssertNil(draft.fileSize)
        XCTAssertEqual(draft.author, Book.unknownAuthor)
        XCTAssertFalse(draft.isOpenInWindow)
        XCTAssertEqual(draft.bookmarkCount, 0)
    }

    /// A book's facts give its place in the reading list as the Reading
    /// List counts it, passing over an ID that names no book, and none for
    /// a book not in the list (FR09).
    func testABooksFactsGiveItsPlaceInTheReadingList() {
        let first = Book(title: "First", format: .txt, filePath: "/nonexistent/first.txt", md5Hash: "first")
        let unlisted = Book(title: "Unlisted", format: .txt, filePath: "/nonexistent/unlisted.txt", md5Hash: "unlisted")
        let last = Book(title: "Last", format: .txt, filePath: "/nonexistent/last.txt", md5Hash: "last")
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(
            books: [first, unlisted, last],
            readingList: ReadingList(bookIDs: [last.id, UUID(), first.id])
        )
        func place(of book: Book) -> ReadingListPlace? {
            BookInfoFacts(
                book,
                library: library,
                wordsPerMinute: 200,
                cloudStates: BookCloudStates(),
                keptBooks: KeptBooks(file: nil),
                measuresFileSize: false
            ).readingListPlace
        }

        XCTAssertEqual(place(of: last), ReadingListPlace(position: 1, count: 2))
        XCTAssertEqual(place(of: first), ReadingListPlace(position: 2, count: 2))
        XCTAssertNil(place(of: unlisted))
    }

    // MARK: - A Folder's and a Feed's Facts

    /// A folder's facts count the books in it and below it with the
    /// unopened ones, the feeds inside it, its own subfolders, and the time
    /// left in all its books; a feed's folder is its feed, with its
    /// address, as a feed's row is; and a feed's row whose feed is gone
    /// keeps the row's facts without an address.
    func testAFoldersFactsCountItsTreeAndAFeedsFolderIsItsFeed() async throws {
        let world = try FeedTestWorld(self, label: "SpeakInfoFolderFacts")
        let base = world.bookFolder.fullPath
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        let feedFolderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        try world.library.createFolderReturningFolder(name: "Shelf", parentPath: base)
        /// A book at `path`, opened a sixth of the way through when `opened`.
        func book(_ title: String, in path: String, opened: Bool) -> Book {
            Book(
                title: title,
                format: .txt,
                filePath: "/nonexistent/\(title).txt",
                md5Hash: title,
                folderPath: path,
                lastOpened: opened ? Date() : nil,
                readingPosition: opened ? ReadingPosition(chapterIndex: 0, characterOffset: 1_000) : nil,
                totalWordCount: 1_000,
                totalCharacterCount: 6_000
            )
        }
        world.library.library.books += [
            book("Read", in: base, opened: true),
            book("Unread", in: base, opened: false),
            book("Shelved", in: "\(base)/Shelf", opened: true),
            book("Elsewhere", in: "", opened: true),
        ]
        let feedFolders = LibraryFeedFolders(center: world.center)
        let now = Date()
        let cloud = BookCloudStates()
        let kept = KeptBooks(file: nil)
        func subject(_ row: LibraryInfoRow) -> LibraryInfoSubject {
            LibraryInfoSubject(row, library: world.library, feedFolders: feedFolders, wordsPerMinute: 200, cloudStates: cloud, keptBooks: kept, measuresFileSize: false, now: now)
        }

        // The folder: its tree's books, feeds, its own subfolders, and the
        // time left: two books of 300 seconds opened a sixth of the way
        // through, and the unopened one, measured, whole.
        let folder = FolderInfoFacts(world.bookFolder, library: world.library, feedFolders: feedFolders, wordsPerMinute: 200)
        XCTAssertEqual(folder.name, world.bookFolder.name)
        XCTAssertEqual(folder.bookCount, 3)
        XCTAssertEqual(folder.unopenedCount, 1)
        XCTAssertEqual(folder.feedCount, 1)
        XCTAssertEqual(folder.subfolderCount, 2)
        XCTAssertEqual(folder.timeRemaining ?? 0, 800, accuracy: 0.001)
        XCTAssertEqual(subject(.folder(world.bookFolder)), .folder(folder))
        let empty = FolderInfoFacts(BookFolder(name: "Empty"), library: world.library, feedFolders: feedFolders, wordsPerMinute: 200)
        XCTAssertEqual(empty, FolderInfoFacts(name: "Empty", bookCount: 0, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil))

        // The feed's folder is its feed, as its row in the Feeds section is.
        let feedFolder = try XCTUnwrap(world.library.library.folders.first { $0.id == feed.folderID })
        let atlas = try XCTUnwrap(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: now))
        XCTAssertEqual(atlas.title, "The Tactile Atlas")
        XCTAssertEqual(atlas.address, world.server.url("/atlas.xml").absoluteString)
        XCTAssertEqual(atlas.folderPath, feedFolderPath)
        XCTAssertEqual(atlas.counts, world.center.counts(of: feed.id))
        XCTAssertEqual(atlas.counts.listed, 1)
        XCTAssertEqual(atlas.check, world.center.checkWording(of: feed.id, now: now).visible)
        XCTAssertEqual(subject(.folder(feedFolder)), .feed(atlas))
        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: ""), center: world.center, now: now).first)
        XCTAssertEqual(subject(.feed(row)), .feed(atlas))

        // Gone since the row was drawn, its record with it (unsubscribing
        // keeps a feed since FR11's branch D): the row's facts, with no
        // address; and the folder, no longer a feed's, is a folder again.
        world.center.store.remove(feed.id)
        XCTAssertNil(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: now))
        XCTAssertEqual(subject(.feed(row)), .feed(FeedInfoFacts(row)))
        XCTAssertNil(FeedInfoFacts(row).address)
        XCTAssertEqual(FeedInfoFacts(row).title, "The Tactile Atlas")
        guard case .folder(let plain) = subject(.folder(feedFolder)) else {
            return XCTFail("a folder whose feed is gone was still spoken as a feed")
        }
        XCTAssertEqual(plain.name, feedFolder.name)
    }

    // MARK: - The Library Window

    /// In a hosted Library window, the I key speaks that nothing is
    /// selected, then, once a row is selected (the List selects a folder's
    /// row by its ID as a book's), that row's brief summary, every time,
    /// however quick the presses: a plain folder's, a feed's row's as the
    /// feed, and a book's. The feed's folder has no row of its own here,
    /// since the feed's row stands for it, so the feed is heard once. I
    /// twice speaks a row's full summary, and I on another row while a
    /// summary speaks speaks that row's. Command-I on the plain folder
    /// speaks its full summary, since a folder has no sheet, and on the
    /// feed's row opens Feed Info and speaks nothing. The window's speaker
    /// speaks through a recorder, so nothing is heard.
    func testThePlainIKeyInAHostedLibraryWindowSpeaksTheSelectedRow() async throws {
        let recorder = InfoSynthesizerRecorder()
        let previous = LibraryInfoSpeaker.makeSynthesizer
        LibraryInfoSpeaker.makeSynthesizer = { recorder }
        defer { LibraryInfoSpeaker.makeSynthesizer = previous }

        let world = try FeedTestWorld(self, label: "SpeakInfoHosted")
        let base = world.bookFolder.fullPath
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        try world.library.createFolderReturningFolder(name: "Classics", parentPath: base)
        // A shelf in Classics, which Classics' full summary counts and its
        // brief one does not.
        try world.library.createFolderReturningFolder(name: "Shelf", parentPath: "\(base)/Classics")
        world.library.library.books.append(Book(
            title: "Middlemarch",
            author: "George Eliot",
            format: .epub,
            filePath: "/nonexistent/middlemarch.epub",
            md5Hash: "middlemarch",
            folderPath: base
        ))
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(base),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: LibraryFeedFolders(center: world.center)
            )
            .environmentObject(world.library)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let userInfo: [AnyHashable: Any] = ["sourceWindow": hosted.window]
        let list = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")

        /// Posts `name` as the key pressed in the window would, and returns
        /// what was spoken for it, if anything, ending that summary, unless
        /// `leavingItSpeaking`, so the next press speaks rather than stops.
        func press(_ name: Notification.Name, leavingItSpeaking: Bool = false) -> String? {
            let before = recorder.utterances.count
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
            flush(hosted.hostingView)
            guard recorder.utterances.count > before, let utterance = recorder.utterances.last else { return nil }
            if !leavingItSpeaking {
                // Told on the main thread, the speaker's delegate ends the
                // summary at once.
                recorder.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
                flush(hosted.hostingView)
            }
            return utterance.speechString
        }

        /// Selects the list's row at `index` alone.
        func select(_ index: Int) {
            list.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            flush(hosted.hostingView)
        }

        XCTAssertEqual(press(.speakInfo), LibraryInfoWording.nothingSelected)

        // Each row of the list selected in turn, from the top, and spoken.
        var heard: [(row: Int, text: String)] = []
        var outcomes: [String] = []
        for row in 0..<list.numberOfRows {
            list.deselectAll(nil)
            flush(hosted.hostingView)
            select(row)
            let stopsBefore = recorder.stops
            if let text = press(.speakInfo) {
                outcomes.append("\(row): \(text)")
                if text != LibraryInfoWording.nothingSelected {
                    heard.append((row, text))
                }
            } else {
                outcomes.append("\(row): \(recorder.stops > stopsBefore ? "stopped" : "silent")")
            }
        }
        let texts = heard.map(\.text)
        let report = outcomes.joined(separator: " | ")
        let atlasPrefix = "The Tactile Atlas. Feed. 1 episode"
        let classicsBrief = "Classics. Folder. 0 books."
        let middlemarchBrief = "Middlemarch. By George Eliot. EPUB. In \(base). Unopened."
        XCTAssertEqual(texts.filter { $0 == classicsBrief }.count, 1, report)
        XCTAssertEqual(texts.filter { $0.hasPrefix(atlasPrefix) }.count, 1, "the feed's row alone, its folder not listed twice: " + report)
        XCTAssertEqual(texts.filter { $0.hasPrefix(middlemarchBrief) }.count, 1, report)
        XCTAssertEqual(texts.count, 3, report)
        XCTAssertFalse(
            texts.contains { $0.contains("Added ") || $0.contains("Address ") || $0.contains("subfolder") },
            "a press of I spoke a full summary: " + report
        )
        XCTAssertNotNil(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: Date()))

        // I twice on Middlemarch's row: its brief summary, then its full one.
        let middlemarchIndex = try XCTUnwrap(heard.first { $0.text.hasPrefix(middlemarchBrief) }?.row)
        select(middlemarchIndex)
        XCTAssertNotNil(press(.speakInfo, leavingItSpeaking: true))
        let full = try XCTUnwrap(press(.speakFullInfo), "I twice spoke nothing")
        XCTAssertTrue(full.hasPrefix(middlemarchBrief) && full.contains("Added "), full)

        // I on Classics while Middlemarch's summary speaks: Classics' own
        // summary, never a silent stop (REV07, Library finding 2).
        XCTAssertNotNil(press(.speakInfo, leavingItSpeaking: true))
        let classicsIndex = try XCTUnwrap(heard.first { $0.text == classicsBrief }?.row)
        select(classicsIndex)
        let stopsBefore = recorder.stops
        XCTAssertEqual(press(.speakInfo), classicsBrief, "I on another row while a summary spoke said nothing")
        XCTAssertGreaterThan(recorder.stops, stopsBefore, "Middlemarch's summary went on under Classics'")

        // Command-I on the plain folder speaks its full summary; on the
        // feed's row it speaks nothing, opening Feed Info instead, as
        // `testCommandIOpensEachRowsInfo` pins (a sheet never shows on a
        // window kept off the screen).
        XCTAssertEqual(press(.showBookInfo), "Classics. Folder. 0 books. 1 subfolder.")
        let feedIndex = try XCTUnwrap(heard.first { $0.text.hasPrefix(atlasPrefix) }?.row)
        select(feedIndex)
        XCTAssertNil(press(.showBookInfo), "Command-I on a feed's row spoke instead of opening Feed Info")
        settle(hosted.hostingView, seconds: 0.3)
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed titled `title` served at `path`, its
    /// folder made at `parentPath`, each item offering audio, so every one
    /// is an episode.
    private func subscribe(_ world: FeedTestWorld, title: String, path: String, into parentPath: String) async throws -> Feed {
        let item = FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/audio/ep-1.mp3")
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: [item])))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(to: world.server.url(path).absoluteString, into: .newFolder(inParentPath: parentPath))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "LibraryInfoSpeakerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
