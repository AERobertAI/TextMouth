import AVFoundation
import XCTest
@testable import TextMouth

/// A reader whose speech the Mac's speech engine refused twice keeps the
/// report of the refusal for its window to show (B05): the book, the place,
/// the passage as the book has it and as it was handed to the engine, and
/// how often the place was refused, one report at a time.
///
/// Nothing is ever heard. Each book's one chapter is longer than speech ever
/// renders, so its speech is always direct, every direct utterance goes to a
/// recorder in place of the synthesizer, and the tests deliver the
/// synthesizer's cancels themselves. Announcements are recorded, not spoken.
@MainActor
final class SpeechRefusalReaderTests: XCTestCase {

    /// The engine refuses the chunk where Play starts and the retry of it:
    /// the reader keeps the report of the refusal, which names the book, its
    /// format, the chapter, the place as Where Am I? says it, and the place
    /// where speech stopped, counted once; and one line in speech's log
    /// records it, by offsets alone.
    func testARefusalGivesTheReaderItsReport() throws {
        let world = try makeIntegrationWorld("Refusal Report")
        let book = openTextBook(in: world)
        let reader = book.reader
        reader.playOrResume()

        let lines = logLines(in: .speechTransitions) {
            _ = recordingAnnouncements {
                refuseTwice(book)
            }
        }

        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not stop")
        let report = try XCTUnwrap(reader.speechRefusalAlert.report, "The reader keeps no report of the refusal")
        XCTAssertEqual(report.bookTitle, "Quay Ledger")
        XCTAssertEqual(report.bookFormat, "Plain Text")
        XCTAssertEqual(report.chapterIndex, 0)
        XCTAssertEqual(report.chapterCount, 1)
        XCTAssertEqual(report.chapterTitle, "Harbour Ledger")
        XCTAssertEqual(report.chapterLength, Self.ledgerText.utf16.count)
        XCTAssertEqual(report.chapterOffset, Self.openingOffset)
        XCTAssertEqual(reader.currentCharacterOffset, Self.openingOffset, "The cursor is not where speech stopped")
        XCTAssertEqual(report.refusal.offset, Self.openingOffset, "Nothing changes the spoken text here")
        XCTAssertEqual(report.timesRefusedHere, 1)
        XCTAssertTrue(report.position.hasPrefix("Moorings. Heading 1 of 2. "), report.position)
        XCTAssertFalse(report.position.contains("Quay Ledger"), "The position repeats the book's title")
        XCTAssertTrue(report.bookPassage.refused.hasPrefix("Mooring 200 of the harbour ledger"), report.bookPassage.refused)
        XCTAssertTrue(report.bookPassage.before.hasSuffix("Mooring 199 of the harbour ledger is checked. "), report.bookPassage.before)

        let chunkEnd = report.refusal.refusedRange.upperBound
        XCTAssertTrue(
            lines.contains {
                $0.contains(
                    "SPEECH_REFUSAL_REPORTED: chapter=0 offset=\(Self.openingOffset) spokenOffset=\(Self.openingOffset) "
                        + "chunkStart=\(Self.openingOffset) chunkEnd=\(chunkEnd) timesHere=1"
                )
            },
            "\(lines)"
        )
        for words in ["Mooring", "harbour", "ledger"] {
            XCTAssertFalse(lines.contains { $0.contains(words) }, "\(words) reached speech's log: \(lines)")
        }
    }

    /// With a substitution rule that speaks "harbour" as "harbor", the
    /// report shows the passage as the book has it, "harbour", and the text
    /// as it was handed to the engine, "harbor", each at its own offsets:
    /// the 199 sentences before the place each lost a letter in the spoken
    /// text.
    func testTheReportShowsTheBooksWordsAndTheWordsHandedToTheEngine() throws {
        let world = try makeIntegrationWorld("Refusal Report Substitution")
        let book = openTextBook(in: world, substituting: [SubstitutionRule(pattern: "harbour", replacement: "harbor")])
        book.reader.playOrResume()

        _ = recordingAnnouncements {
            refuseTwice(book)
        }

        let report = try XCTUnwrap(book.reader.speechRefusalAlert.report)
        XCTAssertEqual(report.chapterOffset, Self.openingOffset)
        XCTAssertEqual(report.refusal.offset, Self.openingOffset - 199)
        XCTAssertTrue(report.bookPassage.refused.hasPrefix("Mooring 200 of the harbour ledger"), report.bookPassage.refused)
        XCTAssertTrue(report.spokenPassage.refused.hasPrefix("Mooring 200 of the harbor ledger"), report.spokenPassage.refused)
        XCTAssertFalse(report.spokenPassage.refused.contains("harbour"), "The text handed over was not the spoken text")
        XCTAssertEqual(report.spokenPassage.range.lowerBound, Self.openingOffset - 199)
    }

    /// One report at a time: a second refusal at the same place, after
    /// Play spoke on from the cursor, updates the report the reader keeps,
    /// counting twice; closing the report lets it go, but the count stays
    /// while the window is open, so the third refusal there counts three.
    func testEachRefusalUpdatesTheOneReportAndCountsItsPlace() throws {
        let world = try makeIntegrationWorld("Refusal Report Count")
        let book = openTextBook(in: world)
        let reader = book.reader
        reader.playOrResume()
        _ = recordingAnnouncements { refuseTwice(book) }
        XCTAssertEqual(reader.speechRefusalAlert.report?.timesRefusedHere, 1)

        reader.playOrResume()
        XCTAssertTrue(reader.speechService.isSpeaking, "Play did not speak after the refusal")
        assertSpeaks(book, from: Self.openingOffset, "Play after the refusal")
        _ = recordingAnnouncements { refuseTwice(book) }

        XCTAssertEqual(reader.speechRefusalAlert.report?.timesRefusedHere, 2, "The second refusal did not update the report")
        XCTAssertEqual(reader.speechRefusalAlert.report?.chapterOffset, Self.openingOffset)

        reader.closeSpeechRefusalReport()
        XCTAssertNil(reader.speechRefusalAlert.report)
        reader.playOrResume()
        _ = recordingAnnouncements { refuseTwice(book) }
        XCTAssertEqual(reader.speechRefusalAlert.report?.timesRefusedHere, 3, "Closing the report forgot the count")
    }

    /// A refusal that reaches a reader whose window has closed shows
    /// nothing and says nothing.
    func testAClosedReaderShowsNoReport() throws {
        let world = try makeIntegrationWorld("Refusal Report Closed")
        let book = openTextBook(in: world)
        let reader = book.reader
        reader.close()

        let announced = recordingAnnouncements {
            reader.speechService.onSpeechRefused?(Self.refusal(at: Self.openingOffset))
        }

        XCTAssertNil(reader.speechRefusalAlert.report)
        XCTAssertEqual(announced.announcements, [])
    }

    // MARK: - A Text Book That Is Never Heard

    /// The utterances a reader's speech handed over in place of the
    /// synthesizer, oldest first.
    private final class HandedOverUtterances {
        var utterances: [AVSpeechUtterance] = []
    }

    /// A text book's reader, and what its speech handed over.
    private struct RefusalBook {
        let reader: ReaderViewModel
        let handedOver: HandedOverUtterances
    }

    /// Where every book opens: the start of the 200th mooring, inside the
    /// Moorings heading and far from either end of the chapter.
    private static let openingOffset = (ledgerText as NSString).range(of: "Mooring 200 ").location

    /// The one chapter of every book: the Moorings heading at its start and
    /// the Tides heading past its middle, in all longer than speech ever
    /// renders, so speech stays direct.
    private static let ledgerText: String = {
        var text = "Moorings\n\n"
        for entry in 1...1_400 {
            text += "Mooring \(entry) of the harbour ledger is checked. "
        }
        text += "\n\nTides\n\n"
        for entry in 1...1_200 {
            text += "Tide \(entry) of the harbour ledger is noted. "
        }
        return text
    }()

    /// Opens a reader of a text book titled "Quay Ledger" in `world`, at
    /// `openingOffset` of its one chapter, speaking with `rules`.
    ///
    /// The reader's direct utterances go to a recorder before it can speak,
    /// and its look-ahead renders are held. The book names a file that is
    /// not there, so its own load fails before the chapter is given to it,
    /// and nothing is read from disk. Punctuation pauses are off, so without
    /// rules the spoken text is the chapter's own.
    private func openTextBook(in world: IntegrationWorld, substituting rules: [SubstitutionRule] = []) -> RefusalBook {
        XCTAssertGreaterThan(
            Self.ledgerText.utf16.count,
            SpeechRenderCoordinator.maximumTextLength,
            "The chapter is short enough to render, so speech could be heard"
        )
        world.settings.punctuationPauseLevel = 0
        let book = Book(
            title: "Quay Ledger",
            author: "Harbour Office",
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: Self.openingOffset)
        )
        world.library.library.addBook(book)
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: rules),
            autoplayRequests: world.autoplayRequests,
            notificationCenter: world.notifications,
            renderScheduler: HeldRenderQueue()
        )
        // Registered after the world's own teardown, so it runs first.
        addTeardownBlock { reader.close() }
        let handedOver = HandedOverUtterances()
        reader.speechService._directUtteranceRecorderForTesting = { handedOver.utterances.append($0) }
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: [
            Chapter(
                title: "Harbour Ledger",
                text: Self.ledgerText,
                headings: [
                    Heading(level: 1, text: "Moorings"),
                    Heading(level: 1, text: "Tides", characterOffset: (Self.ledgerText as NSString).range(of: "Tides\n").location),
                ]
            ),
        ])
        return RefusalBook(reader: reader, handedOver: handedOver)
    }

    /// Has the Mac's speech engine refuse the utterance `book`'s speech
    /// handed over last, and then the fresh synthesizer's retry of it, as
    /// the synthesizer reports it, and lets the main queue handle each
    /// report. Speech then stops where that utterance began.
    private func refuseTwice(_ book: RefusalBook, file: StaticString = #filePath, line: UInt = #line) {
        let speech = book.reader.speechService
        let synthesizer = AVSpeechSynthesizer()
        guard let refused = book.handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
            return
        }
        speech.speechSynthesizer(synthesizer, didCancel: refused)
        handleQueuedCallbacks(file: file, line: line)
        guard let retry = book.handedOver.utterances.last, retry !== refused else {
            XCTFail("The refused utterance was not spoken again", file: file, line: line)
            return
        }
        speech.speechSynthesizer(synthesizer, didCancel: retry)
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Asserts that `book`'s speech is speaking, directly, the chunk that
    /// begins at `offset` of its chapter.
    private func assertSpeaks(
        _ book: RefusalBook,
        from offset: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = DirectSpeechChunk.starting(at: offset, in: Self.ledgerText, maximumLength: SpeechService.directModeFirstChunkSize)
        XCTAssertEqual(
            book.handedOver.utterances.last?.speechString,
            expected.words(of: Self.ledgerText),
            "\(context): speech did not speak from \(offset)",
            file: file,
            line: line
        )
    }

    /// What a speech service hands its reader for a refusal at `offset`
    /// of the chapter, as if speech had stopped there.
    private static func refusal(at offset: Int) -> SpeechRefusal {
        SpeechRefusal(
            offset: offset,
            refusedRange: offset..<(offset + 12),
            refusedText: "Mooring 200 ",
            strictlyGuardedRange: offset..<(offset + 12),
            voice: nil,
            wordsPerMinute: 200,
            rate: 0.5,
            pitchMultiplier: 1,
            volume: 1,
            recentLines: []
        )
    }

    /// Returns once the main queue has run every block queued on it so far:
    /// the speech service handles each of the synthesizer's callbacks there.
    private func handleQueuedCallbacks(file: StaticString = #filePath, line: UInt = #line) {
        var handled = false
        DispatchQueue.main.async { handled = true }
        XCTAssertTrue(waitUntil(timeout: 5) { handled }, "The main queue never ran", file: file, line: line)
    }
}
