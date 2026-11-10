import Combine
import XCTest
@testable import TextMouth

/// `PhoneReaderModel`: the state its controls read, and the one move path,
/// over a real reader of a text book held in memory: nothing plays, nothing
/// is read from disk, and every announcement is caught, never posted.
@MainActor
final class PhoneReaderModelTests: XCTestCase {
    /// What the model posted, oldest first.
    private var posted: [VoiceOverAnnouncement] = []
    /// The delays the model asked to wait before posting.
    private var delays: [TimeInterval] = []
    /// How many times the model said the book was engaged.
    private var engagements = 0
    /// How many times the model asked for Play or Pause.
    private var playPresses = 0

    // MARK: - Moving While Paused

    /// Adjusting Play by sentence while paused moves to the next sentence,
    /// puts that sentence in Play's value, and announces nothing: the value
    /// is the adjustment's answer. The Mac's "Next sentence" isn't said.
    func testAPausedSentenceMovePutsTheSentenceInPlaysValue() {
        let (model, reader) = makeModel()

        model.moveOnScreen(forward: true, source: .adjustingPlay)

        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 19)
        XCTAssertEqual(model.description(of: .play)?.value, "The wind rose at noon.")
        XCTAssertEqual(posted, [])
        XCTAssertEqual(engagements, 1, "A first move engages the book")
    }

    /// A paused move by heading from a button says the Mac's heading words,
    /// in Play's value and, a moment later, announced.
    func testAPausedHeadingMoveFromAButtonIsAlsoAnnounced() {
        let (model, reader) = makeModel()

        model.moveOnScreen(forward: true, unit: .heading, source: .command)

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(model.description(of: .play)?.value, "Heading: The Crossing")
        XCTAssertEqual(posted.map(\.message), ["Heading: The Crossing"])
        XCTAssertEqual(delays, [PhoneAnnouncer.delay])
    }

    /// A move with nothing that way says so, and the cursor stays.
    func testAMoveWithNothingThatWaySaysSo() {
        let (model, reader) = makeModel()

        model.moveOnScreen(forward: false, unit: .heading, source: .adjustingPlay)

        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertEqual(model.description(of: .play)?.value, "No previous heading.")
    }

    /// Play forgets what the last move said, and asks the session to play.
    func testPlayForgetsTheMovesWords() {
        let (model, _) = makeModel()
        model.moveOnScreen(forward: true, source: .adjustingPlay)

        model.togglePlayPause()

        XCTAssertEqual(playPresses, 1)
        XCTAssertEqual(model.description(of: .play)?.value, "")
    }

    /// The next move's words replace the last one's.
    func testTheNextMoveReplacesTheWords() {
        let (model, _) = makeModel()
        model.moveOnScreen(forward: true, source: .adjustingPlay)
        model.moveOnScreen(forward: true, source: .adjustingPlay)

        XCTAssertEqual(model.description(of: .play)?.value, "It fell by evening.")
    }

    /// A move while the book loads does nothing.
    func testAMoveWhileLoadingDoesNothing() {
        let (model, reader) = makeModel()
        reader.isLoading = true

        model.moveOnScreen(forward: true, source: .command)

        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertEqual(posted, [])
        XCTAssertEqual(engagements, 0)
    }

    // MARK: - Navigation Unit and Speed

    /// The unit in force is the kind's default until the book has its own;
    /// adjusting Navigation unit makes the next one the book's own, says
    /// nothing, and the value reads the new unit at once.
    func testAdjustingTheUnitChangesTheValueAtOnceAndSaysNothing() {
        let (model, reader) = makeModel()
        XCTAssertEqual(model.description(of: .navigationUnit)?.value, "Sentence")

        model.adjustUnit(up: true)

        XCTAssertEqual(model.description(of: .navigationUnit)?.value, "Paragraph")
        XCTAssertEqual(model.description(of: .play)?.hint, "Moves back or forward by paragraph.")
        XCTAssertEqual(model.description(of: .skipForward)?.label, "Skip forward: Paragraph")
        XCTAssertEqual(reader.book.localSkipForwardUnit, "Paragraph")
        XCTAssertEqual(posted, [], "The shared \"Navigation unit: Paragraph\" isn't posted")
    }

    /// Adjusting down from the first unit wraps to the last offered: a book
    /// without pages offers no Page.
    func testAdjustingTheUnitDownWraps() {
        let (model, _) = makeModel()
        model.choose(.seconds10)

        model.adjustUnit(up: false)

        XCTAssertEqual(model.description(of: .navigationUnit)?.value, "Bookmark")
    }

    /// Adjusting Speed steps by 25 words per minute, says nothing, and the
    /// value reads the new speed at once.
    func testAdjustingSpeedChangesTheValueAtOnceAndSaysNothing() {
        let (model, reader) = makeModel()
        let before = reader.speechService.wordsPerMinute

        model.adjustSpeed(up: true)

        XCTAssertEqual(reader.speechService.wordsPerMinute, min(before + 25, reader.speechService.maximumWPM))
        XCTAssertEqual(
            model.description(of: .speed)?.value,
            "\(Int(reader.speechService.wordsPerMinute)) words per minute"
        )
        XCTAssertEqual(posted, [])
    }

    // MARK: - Answers

    /// Return with no place to return to says the Mac's words, a moment
    /// later.
    func testReturnWithNoPlaceSaysSo() {
        let (model, _) = makeModel()

        model.returnToPreviousPlace()

        XCTAssertEqual(posted.map(\.message), [BookSearchWording.nothingToGoBackTo])
        XCTAssertEqual(delays, [PhoneAnnouncer.delay])
    }

    /// Return after a heading move goes back, and says the Mac's words.
    func testReturnAfterAJumpGoesBack() {
        let (model, reader) = makeModel()
        model.moveOnScreen(forward: true, unit: .heading, source: .adjustingPlay)
        posted = []

        model.returnToPreviousPlace()

        XCTAssertEqual(reader.currentChapterIndex, 0)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertEqual(posted.map(\.message), ["Returned to previous position"])
    }

    // MARK: - The State

    /// The state is built once per turn of the main queue: a change from
    /// outside the model shows only after the turn, or after `invalidate()`.
    func testTheStateIsKeptForATurn() {
        let (model, reader) = makeModel()
        XCTAssertEqual(model.state?.bookmarkCount, 0)

        reader.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: 0)]
        XCTAssertEqual(model.state?.bookmarkCount, 0, "Rebuilt within the turn")

        model.invalidate()
        XCTAssertEqual(model.state?.bookmarkCount, 1)
    }

    /// The state reads the real cursor and the book: a paused text book at
    /// its first heading, with no timer.
    func testTheStateReadsTheReader() throws {
        let (model, _) = makeModel()
        let state = try XCTUnwrap(model.state)

        XCTAssertEqual(state.bookTitle, "Weather Notes")
        XCTAssertFalse(state.isPlaying)
        XCTAssertFalse(state.isAudioBook)
        XCTAssertEqual(state.unit, .sentence)
        XCTAssertEqual(state.headingPosition.number, 1)
        XCTAssertEqual(state.whereAmI.heading, "Morning")
        XCTAssertEqual(model.description(of: .headings)?.value, "Morning, 1 of 3")
    }

    /// Play's rotors are offered only where the book has what they move by:
    /// headings here, bookmarks once there's one, pages never in a book
    /// without them.
    func testPlaysRotorsFollowWhatTheBookHas() {
        let (model, reader) = makeModel()
        XCTAssertEqual(model.playRotorUnits, [.heading])

        reader.bookmarks = [Bookmark(number: 1, chapterIndex: 1, characterOffset: 0)]

        XCTAssertEqual(model.playRotorUnits, [.heading, .bookmark])
    }

    /// A move says whether the place changed, as a rotor's search needs.
    func testAMoveSaysWhetherThePlaceChanged() {
        let (model, _) = makeModel()
        XCTAssertTrue(model.moveOnScreen(forward: true, unit: .heading, source: .command))
        XCTAssertTrue(model.moveOnScreen(forward: true, unit: .heading, source: .command))
        XCTAssertFalse(model.moveOnScreen(forward: true, unit: .heading, source: .command), "There's no fourth heading")
    }

    /// With no book open, nothing is described, and moves do nothing.
    func testWithNoBookNothingIsDescribed() {
        let model = PhoneReaderModel(
            currentReader: { nil },
            readers: Empty<ReaderViewModel?, Never>().eraseToAnyPublisher(),
            playOrPause: {}
        )
        XCTAssertNil(model.state)
        XCTAssertNil(model.description(of: .play))
        model.moveOnScreen(forward: true, source: .command)
        model.adjustUnit(up: true)
        model.returnToPreviousPlace()
    }

    // MARK: - Search in Book

    /// A text book's search result moves the place to the match itself,
    /// keeping where the reader was for Return, and says nothing; a transcript's
    /// path is not taken.
    func testGoingToATextResultMovesToTheMatchAndKeepsTheReturnPlace() {
        let (_, reader) = makeModel()
        XCTAssertFalse(reader.hasSavedPosition)

        reader.goToSearchResult(chapterIndex: 1, characterOffset: 4, inTranscript: false)

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 4)
        XCTAssertTrue(reader.hasSavedPosition, "The old place wasn't kept for Return")
        XCTAssertNil(reader.pendingJumpAnnouncement, "A text result left a transcript's \"Moved to\" waiting")
    }

    /// A text book with its text loaded opens the search, and says nothing.
    func testSearchInBookOpensForABookWithText() {
        let (model, _) = makeModel()

        XCTAssertTrue(model.openSearch())
        XCTAssertEqual(posted, [], "Opening the sheet said something")
    }

    /// While the book loads, the button doesn't open the sheet, and says the
    /// Mac's "Loading" words, so a press is never met with silence.
    func testSearchInBookWhileLoadingSaysSo() {
        let (model, reader) = makeModel()
        reader.isLoading = true
        reader.content = nil

        XCTAssertFalse(model.openSearch())
        XCTAssertEqual(posted.map(\.message), ["Loading Weather Notes"])
        XCTAssertEqual(delays, [PhoneAnnouncer.delay], "The words didn't wait for the activation's own sounds")
    }

    /// An audiobook with no transcript text doesn't open the sheet, and says
    /// why without telling anyone to transcribe: the phone has no Transcribe
    /// Audio, and an imported audiobook is in a package of its own, which on
    /// the Mac makes the command available and the words name it.
    func testSearchInBookForAnUntranscribedAudiobookSaysWhyWithoutTranscribing() {
        let (model, reader) = makeModel(format: .audio, packaged: true)
        XCTAssertTrue(LibraryAudioCommand.isTranscribable(reader.book), "The test's book isn't one the Mac could transcribe")

        XCTAssertFalse(model.openSearch())

        XCTAssertEqual(posted.map(\.message), ["Weather Notes has no transcript to search."])
        XCTAssertFalse(posted.contains { $0.message.contains("ranscribe") }, "The phone told the listener to transcribe")
    }

    /// The Mac's words for the same book name the command, so the phone's
    /// differ on purpose; and a stale transcript's tell no one to transcribe
    /// again where nothing can.
    func testTheMacsSearchWordsStillNameTranscribingAndThePhonesDoNot() {
        XCTAssertEqual(
            BookSearchWording.noTextToSearch(bookTitle: "Weather Notes", canTranscribe: true, hasTranscript: false, withheld: nil),
            "Weather Notes has no transcript to search. Transcribe it first, with Transcribe Audio."
        )
        let stale = { (offers: Bool) in
            BookSearchWording.noTextToSearch(
                bookTitle: "Weather Notes", canTranscribe: true, hasTranscript: true,
                withheld: .audioChanged, offersTranscription: offers
            )
        }
        XCTAssertTrue(stale(true).hasSuffix("Transcribe it again, then search the new transcript."), stale(true))
        XCTAssertFalse(stale(false).contains("ranscribe it"), stale(false))
        XCTAssertTrue(stale(false).hasPrefix("Weather Notes has no transcript text to search now, because "), stale(false))
    }

    /// With no book open, the button does nothing and says nothing.
    func testSearchInBookWithNoBookDoesNothing() {
        let model = PhoneReaderModel(
            currentReader: { nil },
            readers: Empty<ReaderViewModel?, Never>().eraseToAnyPublisher(),
            playOrPause: {},
            post: { [weak self] in self?.posted.append($0) }
        )

        XCTAssertFalse(model.openSearch())
        XCTAssertEqual(posted, [])
    }

    // MARK: - Helpers

    /// A model over a paused reader of "Weather Notes", three chapters of
    /// two sentences each, a heading at each chapter's start, moving by
    /// Sentence, its announcements caught here and posted at once.
    private func makeModel(format: BookFormat = .txt, packaged: Bool = false) -> (PhoneReaderModel, ReaderViewModel) {
        let reader = makeReader(format: format, packaged: packaged)
        let model = PhoneReaderModel(
            currentReader: { reader },
            readers: Just(reader).map(Optional.some).eraseToAnyPublisher(),
            playOrPause: { [weak self] in self?.playPresses += 1 },
            preferences: makeSandboxedPreferences("PhoneReaderModel"),
            post: { [weak self] in self?.posted.append($0) },
            schedule: { [weak self] delay, work in
                self?.delays.append(delay)
                work()
            },
            noteEngaged: { [weak self] in self?.engagements += 1 }
        )
        return (model, reader)
    }

    /// A jump from the Headings, Bookmarks, or Go To sheet engages the book.
    func testAJumpFromASheetEngagesTheBook() {
        let (model, _) = makeModel()
        XCTAssertEqual(engagements, 0)
        model.noteJumped()
        XCTAssertEqual(engagements, 1)
    }

    /// A stopped reader of a text book held in memory: nothing plays, and
    /// nothing is read from disk.
    private func makeReader(format: BookFormat = .txt, packaged: Bool = false) -> ReaderViewModel {
        let book = Book(
            title: "Weather Notes",
            format: format,
            filePath: "/tmp/\(UUID().uuidString)-weather-notes.txt",
            md5Hash: UUID().uuidString,
            tmbDirectoryName: packaged ? "weather-notes.tmb" : ""
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(initializeServices: false)
        )
        let texts = [
            ("Morning", "Clouds came early. The wind rose at noon. It fell by evening."),
            ("The Crossing", "The ferry left late. Nobody minded the wait."),
            ("Harbor", "Lamps were lit. The day was done."),
        ]
        let chapters = texts.enumerated().map { index, entry in
            Chapter(
                title: entry.0,
                text: entry.1,
                headings: [Heading(level: 1, text: entry.0, chapterIndex: index, characterOffset: 0)]
            )
        }
        reader.content = DocumentContent(title: book.title, author: book.author, chapters: chapters)
        reader.isLoading = false
        return reader
    }
}
