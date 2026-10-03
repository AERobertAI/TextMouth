import Combine
import XCTest
@testable import TextMouth

/// A reader moves on from a chapter once for each time the chapter plays
/// through, and never skips one (TODO P05). The end its speech or audio
/// service reports belongs to the chapter play it began, so the end of a
/// play the reader has left, reported late or twice, moves nothing.
///
/// The audiobook tests play silent tracks through the real audio service.
/// The speech tests report an end the way the speech service does, through
/// the callback the reader gave it, and stop speech before the main run
/// loop turns, so nothing is ever heard.
@MainActor
final class CompletionGenerationReaderTests: XCTestCase {

    // MARK: - Audiobooks

    /// A chapter whose clip ends where its file does moves on once: the
    /// next chapter plays on well past the moment a second end of the first
    /// could have come.
    func testChapterEndingWithItsFileMovesOnOnce() throws {
        try withThreeChapterBook { audiobook in
            let reader = audiobook.openReader()
            let visits = ChapterVisits(of: reader)

            reader.play()
            XCTAssertTrue(
                eventually { reader.currentChapterIndex == 1 && reader.currentCharacterOffset >= 3 },
                "The second chapter never played on"
            )
            let fileOfSecondChapter = reader.audioPlaybackService.loadedURL?.lastPathComponent
            reader.stop()

            XCTAssertEqual(visits.chapters, [0, 1])
            XCTAssertEqual(fileOfSecondChapter, "b.wav")
        }
    }

    /// The end of a chapter's audio reported twice, as the audio service
    /// once did for a clip ending where its file ends, moves on once: the
    /// second report is of a play the reader has left.
    func testAudioEndReportedTwiceMovesOnOnce() throws {
        try withThreeChapterBook { audiobook in
            let reader = audiobook.openReader()
            reader.play()
            let endOfFirstChapter = try XCTUnwrap(reader.audioPlaybackService.onPlaybackFinished)

            endOfFirstChapter()
            XCTAssertEqual(reader.currentChapterIndex, 1)
            endOfFirstChapter()

            XCTAssertEqual(reader.currentChapterIndex, 1, "A second report of the first chapter's end moved on again")
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "b.wav")
            XCTAssertTrue(reader.isCurrentlyPlaying)
            reader.stop()
        }
    }

    /// A looping book of one file, whose last chapter ends where the file
    /// does, plays its first chapter again in full. AVFoundation reports the
    /// end of the last chapter's playthrough late, as the first chapter
    /// begins on the same player; that end used to finish the first chapter
    /// at once and skip it.
    func testLoopingAOneFileBookPlaysItsFirstChapterAgain() throws {
        try withSegmentedAudioBook(
            title: "Breakwater Rounds",
            files: ["whole.wav": 0.8],
            sections: [
                AudioSegment(title: "Outbound", file: "whole.wav", startTime: 0, endTime: 0.4),
                AudioSegment(title: "Return", file: "whole.wav", startTime: 0.4, endTime: 0.8)
            ],
            at: ReadingPosition(chapterIndex: 0, characterOffset: 0),
            endOfBook: .loop
        ) { audiobook in
            let reader = audiobook.openReader()
            let visits = ChapterVisits(of: reader)
            let reports = PlayerReportLog(observing: reader.audioPlaybackService)

            reader.play()
            let samples = trackPlayback(of: reader, within: 15) { visits.chapters.count >= 4 }
            reader.stop()

            XCTAssertEqual(Array(visits.chapters.prefix(4)), [0, 1, 0, 1], "The loop skipped a chapter: \(visits.chapters)")
            // The first chapter's second pass played it through.
            let replay = samples.drop { $0.chapter == 0 }.drop { $0.chapter == 1 }.prefix { $0.chapter == 0 }
            XCTAssertGreaterThanOrEqual(replay.map(\.offset).max() ?? 0, 2, "The first chapter was not played again: \(samples)")
            XCTAssertTrue(
                reports.endOfFileOutcomes.contains(.lateForEarlierPlaythrough),
                "The late end of the last chapter never came: \(reports.endOfFileOutcomes)"
            )
            XCTAssertFalse(reports.endOfFileOutcomes.contains(.endedPlay), "\(reports.endOfFileOutcomes)")
        }
    }

    /// Two readers of one book each play their own audio: one playing
    /// through its first chapter moves itself on, and leaves the other where
    /// it was.
    func testTwoReadersOfOneBookEachMoveOnlyThemselves() throws {
        try withThreeChapterBook { audiobook in
            let playing = audiobook.openReader()
            let idle = audiobook.openReader()

            playing.play()
            XCTAssertTrue(
                eventually { playing.currentChapterIndex == 1 && playing.currentCharacterOffset >= 3 },
                "The playing reader never moved on"
            )
            playing.stop()

            XCTAssertEqual(idle.currentChapterIndex, 0)
            XCTAssertFalse(idle.isCurrentlyPlaying)
            XCTAssertNil(idle.audioPlaybackService.loadedURL)
        }
    }

    // MARK: - Speech

    /// The end of a chapter's speech reported after the reader moved to
    /// another chapter while stopped moves nothing: the reader stays where
    /// it was sent and speaks nothing. The reader used to check its
    /// generation against itself, so such an end moved on from wherever the
    /// cursor stood.
    func testSpeechEndOfAChapterLeftBehindMovesNothing() throws {
        try withTextReader { reader in
            reader.play()
            let endOfFirstChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished)
            reader.stop()
            reader.navigateTo(chapterIndex: 2, characterOffset: 0)

            endOfFirstChapter()
            let chapterAfterLateEnd = reader.currentChapterIndex
            let spokeAfterLateEnd = reader.speechService.isSpeaking
            reader.stop()

            XCTAssertEqual(chapterAfterLateEnd, 2)
            XCTAssertFalse(spokeAfterLateEnd, "A late end started speech")
        }
    }

    /// The end of a chapter's speech reported twice moves on once; the end
    /// of the chapter now speaking moves on from it.
    func testSpeechEndReportedTwiceMovesOnOnce() throws {
        try withTextReader { reader in
            reader.play()
            let endOfFirstChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished)

            reader.speechService.stop()
            endOfFirstChapter()
            let chapterAfterFirstReport = reader.currentChapterIndex
            reader.speechService.stop()
            endOfFirstChapter()
            let chapterAfterSecondReport = reader.currentChapterIndex
            reader.speechService.stop()
            reader.speechService.onUtteranceFinished?()
            let chapterAfterSecondChapterEnds = reader.currentChapterIndex
            reader.stop()

            XCTAssertEqual(chapterAfterFirstReport, 1)
            XCTAssertEqual(chapterAfterSecondReport, 1, "A second report of the first chapter's end moved on again")
            XCTAssertEqual(chapterAfterSecondChapterEnds, 2)
        }
    }

    /// A closed reader moves on from nothing, whatever ends are reported
    /// to it afterwards.
    func testClosedReaderIgnoresAnEnd() throws {
        try withTextReader { reader in
            reader.play()
            let endOfFirstChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished)
            reader.close()

            endOfFirstChapter()

            XCTAssertEqual(reader.currentChapterIndex, 0)
            XCTAssertFalse(reader.speechService.isSpeaking)
        }
    }

    // MARK: - Fixtures

    /// Run `body` with a book of three headings, each playing a whole
    /// silent track of its own: a.wav for half a second, then b.wav and
    /// c.wav for a second each. The first heading's clip ends exactly where
    /// its file does. The book opens at its first heading and stops at its
    /// end.
    private func withThreeChapterBook(_ body: (SegmentedAudioBook) throws -> Void) throws {
        try withSegmentedAudioBook(
            title: "Tidal Ledger",
            files: ["a.wav": 0.5, "b.wav": 1, "c.wav": 1],
            sections: [
                AudioSegment(title: "Soundings", file: "a.wav", startTime: 0, endTime: 0.5),
                AudioSegment(title: "Moorings", file: "b.wav", startTime: 0, endTime: 1),
                AudioSegment(title: "Charts", file: "c.wav", startTime: 0, endTime: 1)
            ],
            at: ReadingPosition(chapterIndex: 0, characterOffset: 0),
            body
        )
    }

    /// Run `body` with a reader of a text book of four short chapters, its
    /// content given to it directly so nothing is read from disk. Speech
    /// rendered ahead is held and never rendered, settings live in a private
    /// suite, listening statistics are isolated, and announcements are
    /// recorded rather than spoken.
    private func withTextReader(_ body: (ReaderViewModel) throws -> Void) throws {
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: makeSandboxedPreferences("completion-generation-speech")
        )
        let chapters = ["Bollard", "Capstan", "Davit", "Fender"].map {
            Chapter(title: $0, text: "The \($0.lowercased()) is noted here.")
        }
        // A unique missing path keeps the reader's own loader from replacing
        // this content.
        let book = Book(
            title: "Quay Notes",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-quay-notes.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        try withIsolatedListeningStatistics {
            let reader = ReaderViewModel(
                book: book,
                libraryViewModel: library,
                settingsViewModel: settings,
                substitutionService: TextSubstitutionService(rules: []),
                notificationCenter: NotificationCenter(),
                renderScheduler: HeldRenderQueue()
            )
            reader.content = DocumentContent(title: "Quay Notes", author: "Test Author", chapters: chapters)
            reader.isLoading = false
            defer { reader.close() }
            try recordingAnnouncements {
                try body(reader)
            }
        }
    }
}

/// The chapters a reader visits, in order, each run of the same chapter
/// counted once, from the moment it is made.
@MainActor
private final class ChapterVisits {
    /// The chapters visited.
    private(set) var chapters: [Int] = []
    /// Keeps the subscription to the reader's chapter alive.
    private var subscription: AnyCancellable?

    /// Start recording `reader`'s chapters, the one it is at first.
    init(of reader: ReaderViewModel) {
        subscription = reader.$currentChapterIndex
            .removeDuplicates()
            .sink { [unowned self] chapter in self.chapters.append(chapter) }
    }
}
