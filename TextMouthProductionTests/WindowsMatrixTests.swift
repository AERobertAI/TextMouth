import AppKit
import AVFoundation
import XCTest
@testable import TextMouth

/// The acceptance matrix's "Multiple windows" row (TODO-2026-09-04.md): the
/// listener keeps Book A playing while editing, moving, or closing Book B,
/// while a timer is set, cancelled, or restarted in B's window, and while
/// every Library window closes and Finder opens a book. A change made to
/// one book, or in one window, must not disturb the book playing in another
/// unless that is the design. A listener with a screen reader cannot see
/// which window did what, so each cell pins what A does, what the timer
/// does, and what VoiceOver says.
///
/// The grid. Rows are the state of Book A: audio playing, speech playing (a
/// text book), audio paused, speech paused, each with no sleep timer, a
/// minutes timer, or an End of book timer running on A (twelve rows,
/// `Row.all`). Columns are what happens to Book B or to the library:
///
///  1. a reader window opens for B, not playing it
///  2. B's title and author are edited, with B's reader open
///  3. B moves to another folder, with B's reader open
///  4. B's folder is renamed, with B's reader open
///  5. B is removed from the library, and B is removed and its files deleted
///  6. B's reader window closes
///  7. a sleep timer is cancelled, started, expired, and restarted in B's reader
///  8. a library sort changes, a folder is created, and a book is added
///  9. every Library window closes, and Finder opens B's package and a file
/// 10. B starts playing
///
/// In each cell the observable outcome is: A's playing state; whether A's
/// position advanced and was not reset; whether A's timer is still in
/// effect and still A's; the announcement VoiceOver hears, if any; and B's
/// own state. Every operation goes through the entry point the UI uses (the
/// library model, the router, the reader's own methods), never a view.
///
/// The inventory as of October 17, 2026, by column and the rows of A it
/// covers (`covered` means a test checks the outcome for A in that
/// combination, not merely runs near it):
///
/// 1. open B's reader | every row | tested here (testQuietOperationsLeaveTheBookPlayingElsewhereAlone)
/// 2. edit B | A idle, not a row of this grid | ReaderRefreshTests.testEveryOpenReaderOfTheBookAppliesEachUpdateOnce (another book's reader applies nothing)
/// 2. edit B | every row | tested here (testQuietOperations...)
/// 3. move B | every row | tested here (ReaderRefreshTests moves A's own book, never B)
/// 4. rename B's folder | every row | tested here (ReaderRefreshTests renames A's own folder)
/// 5. remove B, delete B's files | every row | tested here (no test removes a book beside a playing one)
/// 6. close B's reader | speech playing, no timer | covered by MediaCommandPlaybackTests.testClosingAnotherWindowLeavesTheCommandsWithTheBookPlaying
/// 6. close B's reader | speech paused, no timer | covered by MediaCommandPlaybackTests.testClosingAWindowThatNeverPlayedKeepsThePausedBookShown
/// 6. close B's reader | audio playing, minutes timer fading out | covered by IntegrationSleepTimerTests.testExpiringTimerPausesItsOwnBookOnceWhileAnotherBooksWindowCloses and ReaderLifecycleAuditTests.testInactiveReaderCannotCancelAnotherBooksFade; counting down, not fading, is tested here
/// 6. close B's reader | the other ten rows | tested here
/// 7. cancel, start, expire, restart a timer in B's reader | every row | tested here (IntegrationSleepTimerTests.testTheTimerBelongsToTheReaderThatSetItNotToItsBook and testRestartFromAMediaGestureGoesToTheReaderThatSetTheTimer pin two windows of one book, never a second book)
/// 8. sort, folder contents | every row | tested here
/// 9. close every Library window, Finder open | routing only: LibraryWindowRouterTests.testClosingTheLastLibraryLeavesTheContinuedBookToAReaderWindow, testWithEveryLibraryWindowClosedAnActionOpensOneThatTakesIt, IntegrationWindowRoutingTests.testFinishedBookOpensOneReaderForTheNextBookWithNoLibraryWindow (A finished, not playing); A's state is tested here for every row
/// 10. B starts playing | speech playing, no timer | covered by MediaCommandPlaybackTests.testClosingTheFormerBooksWindowLeavesTheCommandsWithTheBookNowPlaying (the first book is paused); NowPlayingOwnershipTests.testStartingFocusedReaderPausesPreviousReaderBeforePlaying pins the coordinator alone
/// 10. B starts playing | audio playing, an End of heading timer on one book's two windows | IntegrationSleepTimerTests.testTheTimerBelongsToTheReaderThatSetItNotToItsBook; a different book and the other timers are tested here
/// 10. B starts playing | the other eleven rows | tested here
///
/// Of the 120 cells (twelve rows by ten columns), three were covered before
/// this class: column 6 for speech playing and speech paused with no timer,
/// and column 10 for speech playing with no timer. This class tests the
/// other 117; the three it skips are named by `isCovered(_:_:)` and
/// `isCoveredByStartingB(_:)`. No cell is UNCOVERED (needs a view): the
/// router and the library model are driven directly.
///
/// A cell whose outcome looks wrong is pinned as it is today, with a comment
/// saying it is under question; the findings are posted to the lead.
///
/// No test plays sound. Audio is silent WAV files, speech goes to a
/// recorder in place of the synthesizer (`SpeechService.
/// _directUtteranceRecorderForTesting`), announcements are recorded, and
/// the windows the router is given are never shown.
@MainActor
final class WindowsMatrixTests: XCTestCase {

    // MARK: - The Grid

    /// How Book A is playing.
    enum Playback: String, CaseIterable {
        case audioPlaying = "audio playing"
        case speechPlaying = "speech playing"
        case audioPaused = "audio paused"
        case speechPaused = "speech paused"

        /// Whether A is a text book, spoken.
        var isSpeech: Bool { self == .speechPlaying || self == .speechPaused }
        /// Whether A is playing rather than paused.
        var isPlaying: Bool { self == .audioPlaying || self == .speechPlaying }
    }

    /// The sleep timer running on Book A.
    enum TimerCase: String, CaseIterable {
        case none = "no timer"
        case minutes = "minutes timer"
        case endOfBook = "End of book timer"

        /// The duration A sets, or nil for no timer.
        var duration: SleepTimerDuration? {
            switch self {
            case .none: return nil
            case .minutes: return .minutes(30)
            case .endOfBook: return .endOfBook
            }
        }
    }

    /// A row of the grid: the state of Book A.
    struct Row: CustomStringConvertible {
        let playback: Playback
        let timer: TimerCase

        var description: String { "\(playback.rawValue), \(timer.rawValue)" }

        /// All twelve rows.
        static let all: [Row] = Playback.allCases.flatMap { playback in
            TimerCase.allCases.map { Row(playback: playback, timer: $0) }
        }
    }

    /// A column of the grid: what happens to Book B or to the library, among
    /// the columns that change nothing about A (the others, the timer's and
    /// B's start, are tests of their own).
    enum Column: String, CaseIterable {
        case openReader = "open B's reader"
        case edit = "edit B's title and author"
        case move = "move B to another folder"
        case renameFolder = "rename B's folder"
        case remove = "remove B from the library"
        case deleteFiles = "remove B and delete its files"
        case closeReader = "close B's reader"
        case sortAndContents = "change a sort, a folder, and a folder's contents"
        case libraryWindowsAndFinder = "close every Library window, open from Finder"
    }

    /// Whether another test class already checks the outcome for A in this
    /// cell (see the inventory above), so this one does not repeat it.
    static func isCovered(_ row: Row, _ column: Column) -> Bool {
        column == .closeReader && row.playback.isSpeech && row.timer == .none
    }

    /// Whether another test class already checks B's start against this row.
    static func isCoveredByStartingB(_ row: Row) -> Bool {
        row.playback == .speechPlaying && row.timer == .none
    }

    // MARK: - What Is Observed

    /// The sleep timer as A's cell sees it.
    struct TimerObserved: Equatable {
        let active: Bool
        let owner: UUID?
        let duration: SleepTimerDuration?
        let remaining: Int
    }

    /// Everything about Book A that a cell compares before and after.
    struct Observed {
        /// The reader's own flags.
        let readerPlaying: Bool
        let readerPaused: Bool
        /// The audio player's or the speech service's flags.
        let servicePlaying: Bool
        let servicePaused: Bool
        /// Where A is: chapter, offset, and the audio player's time.
        let chapter: Int
        let offset: Int
        let audioTime: TimeInterval
        /// The speech's playback generation, which moves when speech restarts.
        let generation: Int
        /// How many utterances the speech has been handed.
        let utterances: Int
        let timer: TimerObserved
    }

    /// What a cell expects of A's playback.
    enum ExpectedPlayback {
        /// A plays or rests exactly as before.
        case unchanged
        /// Another book started, which paused A if it was playing.
        case pausedByAnotherBook
    }

    /// What a cell expects of the one shared sleep timer.
    enum ExpectedTimer {
        /// Still in effect, still A's, not restarted.
        case asBefore
        /// Not in effect.
        case ended
        /// Set by another reader.
        case takenBy(UUID, SleepTimerDuration)
    }

    /// The utterances a text book's speech handed over in place of the
    /// synthesizer.
    final class HandedOver {
        var utterances: [AVSpeechUtterance] = []
    }

    // MARK: - A Stage: Book A Playing, a World Around It

    /// A world with Book A in the state of a row, and the readers opened for
    /// other books beside it.
    @MainActor
    final class Stage {
        let world: IntegrationWorld
        let coordinator: NowPlayingService
        let row: Row
        let a: ReaderViewModel
        /// The speech handed over for A, for a text book.
        let handedOver: HandedOver
        /// The readers opened for other books.
        private(set) var otherReaders: [ReaderViewModel] = []

        init(world: IntegrationWorld, coordinator: NowPlayingService, row: Row, a: ReaderViewModel, handedOver: HandedOver) {
            self.world = world
            self.coordinator = coordinator
            self.row = row
            self.a = a
            self.handedOver = handedOver
        }

        /// Remember a reader opened for another book, to close it later.
        func keep(_ reader: ReaderViewModel) {
            otherReaders.append(reader)
        }

        /// Close the readers opened for other books.
        func closeOtherReaders() {
            otherReaders.forEach { $0.close() }
            otherReaders = []
        }

        /// Close every reader of the stage and stop its timer.
        func close() {
            closeOtherReaders()
            a.close()
            SleepTimerService.shared.stop(reason: "windows matrix stage ended")
        }
    }

    /// The first chapter of every text book: longer than speech ever
    /// renders, so its speech is direct and goes to the recorder.
    static let ledgerText: String = {
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

    /// Where the text book opens: the start of the 200th mooring.
    static let openingOffset = (ledgerText as NSString).range(of: "Mooring 200 ").location

    /// Book A's title and Book B's, which order A before B in their folder.
    static let titleOfA = "Alpha Tides"
    static let titleOfB = "Beta Tides"

    /// The announcement a timer that runs out says.
    static let expiredAnnouncement = ReaderViewModel.sleepTimerExpiredAnnouncement

    /// A new stage: a world of its own, with Book A in the state of `row`.
    ///
    /// Audio A is a silent book of two tracks, playing from the tenth second
    /// of the long second track. Text A is a book whose one long chapter is
    /// spoken to the recorder. A timer of the row is set last, with its
    /// clock put back to ten minutes so that a reset shows.
    func makeStage(for row: Row, index: Int) throws -> Stage {
        let world = try makeIntegrationWorld("Windows Matrix \(index)")
        world.settings.sleepFadeOutDuration = 0
        world.settings.punctuationPauseLevel = 0
        let coordinator = NowPlayingService(installsSystemIntegrations: false)
        world.library.library.folders = [BookFolder(name: world.folder.path)]
        let handedOver = HandedOver()
        let reader: ReaderViewModel
        if row.playback.isSpeech {
            XCTAssertGreaterThan(
                Self.ledgerText.utf16.count,
                SpeechRenderCoordinator.maximumTextLength,
                "The chapter is short enough to render, so speech could be heard"
            )
            let book = Book(
                title: Self.titleOfA,
                author: "Harbour Office",
                format: .txt,
                filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
                md5Hash: UUID().uuidString,
                folderPath: world.folder.path,
                readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: Self.openingOffset)
            )
            world.library.library.addBook(book)
            reader = world.openReader(for: book, renderScheduler: HeldRenderQueue(), nowPlaying: coordinator)
            reader.speechService._directUtteranceRecorderForTesting = { handedOver.utterances.append($0) }
            waitForReaderToLoad(reader)
            reader.errorMessage = nil
            reader.content = DocumentContent(
                title: book.title,
                author: book.author,
                chapters: [Chapter(
                    title: "Harbour Ledger",
                    text: Self.ledgerText,
                    headings: [Heading(level: 1, text: "Moorings")]
                )]
            )
            reader.play()
            reportWordSpoken(by: reader, handedOver: handedOver)
        } else {
            let book = try world.makeSilentAudioBook(
                title: Self.titleOfA,
                trackDurations: [2, 60],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: 100)
            )
            reader = world.openReader(for: book, nowPlaying: coordinator)
            waitForReaderToLoad(reader)
            XCTAssertNil(reader.errorMessage, "\(row): A did not open")
            reader.play()
            XCTAssertTrue(
                eventually(within: 5) { reader.audioPlaybackService.isPlaying },
                "\(row): A never started playing"
            )
        }
        if !row.playback.isPlaying {
            reader.pause()
            // A text book's pause is finished on the main queue's next turn.
            XCTAssertTrue(
                eventually(within: 5) { reader.isCurrentlyPaused },
                "\(row): A never paused"
            )
        }
        let stage = Stage(world: world, coordinator: coordinator, row: row, a: reader, handedOver: handedOver)
        armTimer(of: stage)
        return stage
    }

    /// Set A's timer of the row, or stop the timer when the row has none.
    func armTimer(of stage: Stage) {
        let timer = SleepTimerService.shared
        guard let duration = stage.row.timer.duration else {
            timer.stop(reason: "windows matrix, no timer")
            return
        }
        stage.a.startSleepTimer(duration: duration)
        // A clock put back from its full length shows a restart.
        if case .minutes = duration {
            timer.remainingSeconds = 600
        }
    }

    /// Tell `reader`'s speech, as the synthesizer does once it begins, that
    /// it speaks the first word of the last utterance handed over, so the
    /// place is where speech really is.
    func reportWordSpoken(by reader: ReaderViewModel, handedOver: HandedOver) {
        guard let spoken = handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer")
            return
        }
        let firstWord = (spoken.speechString as NSString).range(of: " ")
        reader.speechService.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 0, length: max(1, firstWord.location)),
            utterance: spoken
        )
        handleQueuedCallbacks()
    }

    /// Book B: a silent audio book of one long track, in the world's root
    /// folder, listed in the library.
    func makeB(in stage: Stage) throws -> Book {
        try stage.world.makeSilentAudioBook(title: Self.titleOfB, trackDurations: [30])
    }

    /// Open a reader for `book` in `stage`'s world, wait for it to load, and
    /// keep it to be closed with the stage.
    func openReader(for book: Book, in stage: Stage) -> ReaderViewModel {
        let reader = stage.world.openReader(for: book, nowPlaying: stage.coordinator)
        waitForReaderToLoad(reader)
        stage.keep(reader)
        return reader
    }

    // MARK: - Observing and Asserting

    /// What A is now.
    func observe(_ stage: Stage) -> Observed {
        let a = stage.a
        let timer = SleepTimerService.shared
        let isAudio = !stage.row.playback.isSpeech
        return Observed(
            readerPlaying: a.isCurrentlyPlaying,
            readerPaused: a.isCurrentlyPaused,
            servicePlaying: isAudio ? a.audioPlaybackService.isPlaying : a.speechService.isSpeaking,
            servicePaused: isAudio ? a.audioPlaybackService.isPaused : a.speechService.isPaused,
            chapter: a.currentChapterIndex,
            offset: a.currentCharacterOffset,
            audioTime: a.audioPlaybackService.currentTime,
            generation: a.chapterPlaybackGeneration,
            utterances: stage.handedOver.utterances.count,
            timer: TimerObserved(
                active: timer.isActive,
                owner: timer.ownerID,
                duration: timer.duration,
                remaining: timer.remainingSeconds
            )
        )
    }

    /// Check that A, and the shared timer, are as `expectedPlayback` and
    /// `expectedTimer` say, after `before`, naming `cell` in every failure.
    ///
    /// A's place is never reset and never goes back; it may move forward
    /// only while A plays audio. Nothing is spoken to a speech A.
    func assertA(
        _ stage: Stage,
        since before: Observed,
        playback expectedPlayback: ExpectedPlayback = .unchanged,
        timer expectedTimer: ExpectedTimer = .asBefore,
        _ cell: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let after = observe(stage)
        switch expectedPlayback {
        case .unchanged:
            XCTAssertEqual(after.readerPlaying, before.readerPlaying, "\(cell): A's playing flag changed", file: file, line: line)
            XCTAssertEqual(after.readerPaused, before.readerPaused, "\(cell): A's paused flag changed", file: file, line: line)
            XCTAssertEqual(after.servicePlaying, before.servicePlaying, "\(cell): A's player or speech started or stopped", file: file, line: line)
            XCTAssertEqual(after.servicePaused, before.servicePaused, "\(cell): A's player or speech paused or resumed", file: file, line: line)
            XCTAssertEqual(after.generation, before.generation, "\(cell): A's speech was restarted or moved", file: file, line: line)
        case .pausedByAnotherBook:
            XCTAssertTrue(after.readerPaused, "\(cell): A was not paused", file: file, line: line)
            XCTAssertEqual(after.readerPlaying, before.readerPlaying, "\(cell): A stopped rather than paused", file: file, line: line)
            XCTAssertTrue(after.servicePaused, "\(cell): A's player or speech is not paused", file: file, line: line)
        }
        XCTAssertEqual(after.chapter, before.chapter, "\(cell): A's chapter changed", file: file, line: line)
        XCTAssertGreaterThanOrEqual(after.offset, before.offset, "\(cell): A's place went back or was reset", file: file, line: line)
        XCTAssertGreaterThanOrEqual(after.audioTime, before.audioTime, "\(cell): A's audio time went back or was reset", file: file, line: line)
        XCTAssertEqual(after.utterances, before.utterances, "\(cell): A's speech was handed something new", file: file, line: line)
        switch expectedTimer {
        case .asBefore:
            XCTAssertEqual(after.timer.active, before.timer.active, "\(cell): the timer's activity changed", file: file, line: line)
            XCTAssertEqual(after.timer.owner, before.timer.owner, "\(cell): the timer changed hands", file: file, line: line)
            XCTAssertEqual(after.timer.duration, before.timer.duration, "\(cell): the timer's duration changed", file: file, line: line)
            XCTAssertLessThanOrEqual(after.timer.remaining, before.timer.remaining, "\(cell): the timer was reset", file: file, line: line)
        case .ended:
            XCTAssertFalse(after.timer.active, "\(cell): the timer is still in effect", file: file, line: line)
        case .takenBy(let owner, let duration):
            XCTAssertTrue(after.timer.active, "\(cell): the timer is not in effect", file: file, line: line)
            XCTAssertEqual(after.timer.owner, owner, "\(cell): the timer is not the new owner's", file: file, line: line)
            XCTAssertEqual(after.timer.duration, duration, "\(cell): the timer has another duration", file: file, line: line)
        }
    }

    /// A window that is never shown, for a router to be given.
    static func makeHiddenWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - Columns 1 to 6, 8, and 9: B or the Library Changes, A Plays On

    /// Every cell of the columns that change nothing about A: A plays, or
    /// rests, exactly as before, its place is not reset or moved back, its
    /// timer is still in effect and still A's, and VoiceOver hears nothing.
    /// Each cell also checks B's own outcome.
    func testQuietOperationsLeaveTheBookPlayingElsewhereAlone() throws {
        preserveSleepTimers()
        for (index, row) in Row.all.enumerated() {
            let stage = try makeStage(for: row, index: index)
            defer { stage.close() }
            let startTime = stage.a.audioPlaybackService.currentTime
            for column in Column.allCases where !Self.isCovered(row, column) {
                let cell = "\(row) | \(column.rawValue)"
                let before = observe(stage)
                let recorder = try recordingAnnouncements {
                    try perform(column, in: stage, cell: cell)
                }
                assertA(stage, since: before, cell)
                XCTAssertEqual(recorder.announcements.map(\.message), [], "\(cell): VoiceOver heard something")
                stage.closeOtherReaders()
            }
            if row.playback == .audioPlaying {
                XCTAssertTrue(
                    eventually(within: 3) { stage.a.audioPlaybackService.currentTime > startTime },
                    "\(row): A's audio never advanced"
                )
            }
        }
    }

    /// Make the change of `column`, as the Library window or the router
    /// makes it, and check B's own outcome.
    func perform(_ column: Column, in stage: Stage, cell: String) throws {
        let library = stage.world.library
        let root = stage.world.folder.path
        switch column {
        case .openReader:
            let b = try makeB(in: stage)
            let reader = openReader(for: b, in: stage)
            XCTAssertNil(reader.errorMessage, "\(cell): B did not open")
            XCTAssertFalse(reader.isCurrentlyPlaying, "\(cell): B's reader began playing")

        case .edit:
            let b = try makeB(in: stage)
            let reader = openReader(for: b, in: stage)
            let original = try XCTUnwrap(library.bookByID(b.id))
            library.updateBookMetadata(
                Book.MetadataEdit(
                    opened: [.title: original.title, .author: original.author],
                    saved: [.title: "Beta Revised", .author: "Another Author"]
                ),
                of: b.id
            )
            let row = try XCTUnwrap(library.bookByID(b.id))
            XCTAssertEqual([row.title, row.author], ["Beta Revised", "Another Author"], "\(cell): B's row was not edited")
            XCTAssertEqual(reader.book.title, "Beta Revised", "\(cell): B's own reader did not follow the edit")

        case .move:
            let b = try makeB(in: stage)
            let reader = openReader(for: b, in: stage)
            let shelf = makeShelf(in: stage)
            let move = outcome { await library.moveBooksReturningOutcome([b], toFolder: shelf.fullPath) }
            XCTAssertTrue(move.succeeded, "\(cell): \(move.failureMessage ?? "")")
            let row = try XCTUnwrap(library.bookByID(b.id))
            XCTAssertEqual(row.folderPath, shelf.fullPath, "\(cell): B did not move")
            XCTAssertEqual(reader.book.filePath, row.filePath, "\(cell): B's own reader names its old files")

        case .renameFolder:
            let b = try makeB(in: stage)
            let reader = openReader(for: b, in: stage)
            let shelf = makeShelf(in: stage)
            let move = outcome { await library.moveBooksReturningOutcome([b], toFolder: shelf.fullPath) }
            XCTAssertTrue(move.succeeded, "\(cell): \(move.failureMessage ?? "")")
            let renamed = outcome { await library.renameFolderReturningOutcome(shelf, to: "Stacks \(UUID().uuidString.prefix(4))") }
            XCTAssertTrue(renamed.succeeded, "\(cell): \(renamed.failureMessage ?? "")")
            let row = try XCTUnwrap(library.bookByID(b.id))
            XCTAssertNotEqual(row.folderPath, shelf.fullPath, "\(cell): B's folder was not renamed")
            XCTAssertTrue(row.folderPath.hasPrefix(root + "/Stacks"), "\(cell): B is not in the renamed folder")
            XCTAssertEqual(reader.book.filePath, row.filePath, "\(cell): B's own reader names its old files")

        case .remove:
            let b = try makeB(in: stage)
            library.removeBooksFromLibraryOnly([b])
            XCTAssertNil(library.bookByID(b.id), "\(cell): B is still in the library")

        case .deleteFiles:
            let b = try makeB(in: stage)
            let package = b.tmbDirectory
            // The package is deleted by a closure of the test's own, and
            // only inside the world's folder, so nothing goes to the Trash.
            let removal = library.removeBooksAndDeleteReturningOutcome([b]) { book in
                guard book.tmbDirectory.path.hasPrefix(stage.world.folder.url.path) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: book.tmbDirectory)
            }
            XCTAssertTrue(removal.succeeded, "\(cell): \(removal.failureMessage ?? "")")
            XCTAssertNil(library.bookByID(b.id), "\(cell): B is still in the library")
            XCTAssertFalse(FileManager.default.fileExists(atPath: package.path), "\(cell): B's files are still there")

        case .closeReader:
            let b = try makeB(in: stage)
            let reader = openReader(for: b, in: stage)
            reader.close()
            XCTAssertNotNil(library.bookByID(b.id), "\(cell): closing B's window removed B from the library")

        case .sortAndContents:
            let location = LibraryLocation(category: .folders, folderPath: root)
            library.userChangedSort(.choose(.author), at: location)
            library.userChangedSort(.reverseDirection, at: location)
            XCTAssertEqual(library.sortState(at: location).setting.sortField, .author, "\(cell): the sort did not change")
            let created = library.createFolderReturningOutcome(name: "Annex", parentPath: root)
            XCTAssertTrue(created.succeeded, "\(cell): \(created.failureMessage ?? "")")
            let added = try makeB(in: stage)
            XCTAssertNotNil(library.bookByID(added.id), "\(cell): the added book is not listed")

        case .libraryWindowsAndFinder:
            try performLibraryWindowsAndFinder(in: stage, cell: cell)
        }
    }

    /// A folder in the root, for B to move to, listed in the library.
    func makeShelf(in stage: Stage) -> BookFolder {
        let shelf = BookFolder(name: "Shelf \(UUID().uuidString.prefix(4))", parentPath: stage.world.folder.path)
        stage.world.library.library.folders.append(shelf)
        return shelf
    }

    /// Two Library windows are open, then both close while A's reader window
    /// stays registered; Finder then opens B's package, which the router
    /// gives to the reader window, and a file, which waits for a Library
    /// window and is taken by the next one SwiftUI shows.
    func performLibraryWindowsAndFinder(in stage: Stage, cell: String) throws {
        let b = try makeB(in: stage)
        let router = LibraryWindowRouter(keyWindow: { nil })
        var libraryWindowRequests = 0
        router.openLibraryWindow = {
            libraryWindowRequests += 1
            return false
        }
        let readerWindow = Self.makeHiddenWindow()
        var openedBooks: [UUID] = []
        router.registerReaderWindow(readerWindow) { bookID in
            openedBooks.append(bookID)
            if let book = stage.world.library.bookByID(bookID) {
                _ = self.openReader(for: book, in: stage)
            }
        }
        let libraryWindows = [Self.makeHiddenWindow(), Self.makeHiddenWindow()]
        for window in libraryWindows {
            router.register(window) { _ in }
        }
        for window in libraryWindows {
            router.unregister(window)
        }
        XCTAssertFalse(router.hasRegisteredWindow, "\(cell): a closed Library window stayed registered")

        let items = [URL(fileURLWithPath: "/Books/Volume.epub")]
        router.route(.openBookWindow(b.id))
        router.route(.openFiles(items))

        XCTAssertTrue(waitUntil(timeout: 5) { openedBooks == [b.id] }, "\(cell): B's package was not opened by the reader window")
        XCTAssertEqual(router.waitingActions, [.openFiles(items)], "\(cell): the file did not wait for a Library window")
        var taken: [GlobalAction] = []
        let newLibrary = Self.makeHiddenWindow()
        router.register(newLibrary) { taken.append($0) }
        XCTAssertTrue(waitUntil(timeout: 5) { taken == [.openFiles(items)] }, "\(cell): the new Library window did not take the file")
        XCTAssertEqual(libraryWindowRequests, 0, "\(cell): a Library window was asked for")
        router.unregister(newLibrary)
        router.unregisterReaderWindow(readerWindow)
    }

    // MARK: - Column 7: A Timer Cancelled, Started, Run Out, and Restarted in B's Window

    /// The sleep timer is one for the whole app, owned by the reader that set
    /// it. Four things happen to it in B's reader, for every row:
    ///
    /// - B's reader cancels it. Anyone may cancel, so A's timer ends
    ///   (`ReaderViewModel.cancelSleepTimer()`).
    /// - B's reader starts one. It replaces A's, which A no longer owns.
    /// - B's timer runs out. B pauses (it plays nothing) and says "Sleep
    ///   timer expired. Playback paused." while A plays on. That is under
    ///   question: the listener who set a timer in A and then set one in B
    ///   hears that playback paused while the book they were listening to
    ///   goes on. It is pinned as it is today.
    /// - B's reader restarts the timer (the Restart Sleep Timer shortcut or
    ///   a media gesture in B's window). It takes the duration of the timer
    ///   in effect, or the last one used, owns it, and starts B playing,
    ///   which pauses A. Also under question for the same reason: A's timer
    ///   has become B's.
    ///
    /// In every case A is not stopped or moved by the timer's changes alone;
    /// only the restart's play pauses it.
    func testATimerCancelledStartedRunOutAndRestartedInAnotherBooksWindow() throws {
        preserveSleepTimers()
        let timer = SleepTimerService.shared
        for (index, row) in Row.all.enumerated() {
            let stage = try makeStage(for: row, index: 100 + index)
            defer { stage.close() }
            let bReader = openReader(for: try makeB(in: stage), in: stage)

            // Cancelled in B's reader.
            var cell = "\(row) | cancel a timer in B's reader"
            var before = observe(stage)
            var recorder = recordingAnnouncements { bReader.cancelSleepTimer() }
            assertA(stage, since: before, timer: .ended, cell)
            XCTAssertEqual(recorder.announcements.map(\.message), [], "\(cell): VoiceOver heard something")

            // Started in B's reader.
            armTimer(of: stage)
            cell = "\(row) | start a timer in B's reader"
            before = observe(stage)
            recorder = recordingAnnouncements { bReader.startSleepTimer(duration: .minutes(5)) }
            assertA(stage, since: before, timer: .takenBy(bReader.readerID, .minutes(5)), cell)
            XCTAssertEqual(recorder.announcements.map(\.message), [], "\(cell): VoiceOver heard something")

            // B's timer runs out while A plays on.
            cell = "\(row) | B's timer runs out"
            before = observe(stage)
            recorder = recordingAnnouncements {
                timer._expireForTesting()
                XCTAssertTrue(eventually(within: 3) { !timer.isActive }, "\(cell): the timer never ended")
                handleQueuedCallbacks()
            }
            assertA(stage, since: before, timer: .ended, cell)
            XCTAssertEqual(recorder.announcements.map(\.message), [Self.expiredAnnouncement], "\(cell): what VoiceOver heard")

            // Restarted in B's reader, which plays B and so pauses A.
            armTimer(of: stage)
            cell = "\(row) | restart the timer in B's reader"
            let expectedDuration = row.timer.duration ?? .minutes(5)
            let expectedWords = row.timer == .none ? "Timer restarted: 5 minutes." : "Timer reset."
            before = observe(stage)
            recorder = recordingAnnouncements {
                bReader.restartOrStartLastSleepTimer()
                // A text book's pause, asked for by B's start, finishes on
                // the main queue's next turn.
                handleQueuedCallbacks()
            }
            assertA(
                stage,
                since: before,
                playback: row.playback.isPlaying ? .pausedByAnotherBook : .unchanged,
                timer: .takenBy(bReader.readerID, expectedDuration),
                cell
            )
            XCTAssertEqual(recorder.announcements.map(\.message), [expectedWords], "\(cell): what VoiceOver heard")
            XCTAssertTrue(bReader.isPlaybackUnderWay, "\(cell): B did not start playing")
        }
    }

    // MARK: - Column 10: B Starts Playing

    /// B starts playing. Only one book plays at a time, so A, if it was
    /// playing, is paused where it was; a paused A stays paused. Nothing
    /// ends A's timer or hands it to B, and VoiceOver hears nothing.
    func testStartingAnotherBookPausesTheBookPlayingAndKeepsItsTimer() throws {
        preserveSleepTimers()
        for (index, row) in Row.all.enumerated() where !Self.isCoveredByStartingB(row) {
            let stage = try makeStage(for: row, index: 200 + index)
            defer { stage.close() }
            let bReader = openReader(for: try makeB(in: stage), in: stage)
            let cell = "\(row) | B starts playing"
            let before = observe(stage)

            let recorder = recordingAnnouncements {
                bReader.play()
                XCTAssertTrue(
                    eventually(within: 5) { bReader.audioPlaybackService.isPlaying },
                    "\(cell): B never started playing"
                )
                // A text book's pause, asked for by B's start, finishes on
                // the main queue's next turn.
                handleQueuedCallbacks()
            }

            assertA(stage, since: before, playback: row.playback.isPlaying ? .pausedByAnotherBook : .unchanged, cell)
            XCTAssertFalse(bReader.isCurrentlyPaused, "\(cell): B is paused")
            XCTAssertNotEqual(SleepTimerService.shared.ownerID, bReader.readerID, "\(cell): B took the timer")
            XCTAssertEqual(recorder.announcements.map(\.message), [], "\(cell): VoiceOver heard something")
        }
    }
}
