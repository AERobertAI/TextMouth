import Combine
import XCTest
@testable import TextMouth

// Helpers for tests of what a book does as it ends (`EndBehaviorMatrixTests`,
// `IntegrationSleepTimerTests`): a reader of a text book whose speech is held
// silent, the requests a finished book leaves for the next one, and how a
// test waits for them. Moved unchanged out of `IntegrationSleepTimerTests`
// so the matrix reuses them, except that `startSpeakingSilently` is renamed
// `startSpeakingSilentlyUntilItsEnd`, which another test class's private helper
// of the name made ambiguous, and that `recordContinueRequests(in:)` ends
// its subscription at the test's tear-down, not with a property of the class.

@MainActor
extension XCTestCase {
    /// Whether the next book is asked for, as `continued` records the
    /// requests, within twice the time a finished book takes to ask for it:
    /// a wait that ends as soon as one is asked for, and otherwise shows that
    /// none was.
    func nextBookIsAskedFor(_ continued: () -> [Notification]) -> Bool {
        eventually(within: ReaderViewModel.continueToNextBookDelay * 2) { !continued().isEmpty }
    }

    /// Record every `.continueToNextBook` posted in `world` from now on.
    ///
    /// - Returns: A function reading the notifications posted so far.
    func recordContinueRequests(in world: IntegrationWorld) -> () -> [Notification] {
        var posted: [Notification] = []
        // An extension cannot hold the subscription in a property of the test
        // class, so the test's tear-down ends it.
        let subscription = world.notifications.publisher(for: .continueToNextBook)
            .sink { posted.append($0) }
        addTeardownBlock { subscription.cancel() }
        return { posted }
    }

    // MARK: - A Text Book's Reader

    /// The surroundings of a test of a text book's reader.
    struct SpeechWorld {
        /// The world the reader belongs to.
        let world: IntegrationWorld
        /// The reader, loaded with the test's chapters.
        let reader: ReaderViewModel
        /// The book the reader reads.
        let book: Book
        /// The book after it in its folder, where Continue to Next Book goes.
        let nextBook: Book
    }

    /// Run `body` with a reader of a text book of `chapters`, three short
    /// ones with no headings unless the test gives its own, in a world of
    /// its own whose folder holds another book after it.
    ///
    /// The reader's content is given to it directly: the book names a file
    /// that is not there, so the reader's own load fails before the content
    /// is given, and nothing is read from disk. Its look-ahead renders are
    /// held, never rendered, and a test silences its speech before the main
    /// run loop turns (`startSpeakingSilentlyUntilItsEnd`, `endSpeechSilently`), so
    /// nothing is ever heard.
    ///
    /// - Parameters:
    ///   - label: Names the world's folder, config, and preferences.
    ///   - endOfBook: What the book does when its last chapter ends.
    ///   - fadeSeconds: The sleep timer's fade-out setting.
    ///   - chapters: The book's chapters.
    func withSpeechReader(
        _ label: String,
        endOfBook: EndOfBookBehavior = .stop,
        fadeSeconds: TimeInterval = 0,
        chapters: [Chapter] = ["Bollard", "Capstan", "Davit"].map {
            Chapter(title: $0, text: "The \($0.lowercased()) is noted here.")
        },
        _ body: (SpeechWorld) throws -> Void
    ) throws {
        let world = try makeIntegrationWorld(label)
        world.settings.sleepFadeOutDuration = fadeSeconds
        let book = listTextBook(titled: "Quay Notes", in: world, endOfBook: endOfBook)
        let nextBook = listTextBook(titled: "Slipway Notes", in: world, endOfBook: .stop)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue())
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(title: book.title, author: "Test Author", chapters: chapters)
        try body(SpeechWorld(world: world, reader: reader, book: book, nextBook: nextBook))
    }

    /// Three short chapters that each open with their own heading, as most
    /// EPUB chapters and every audiobook chapter do, so that each heading
    /// ends where its chapter does.
    func headedChapters() -> [Chapter] {
        ["Bollard", "Capstan", "Davit"].map { title in
            Chapter(
                title: title,
                text: "\(title)\n\nThe \(title.lowercased()) is noted here.",
                headings: [Heading(level: 1, text: title)]
            )
        }
    }

    /// A text book titled `title`, listed in `world`'s folder, whose file is
    /// not there.
    func listTextBook(titled title: String, in world: IntegrationWorld, endOfBook: EndOfBookBehavior) -> Book {
        let book = Book(
            title: title,
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            localEndOfBookBehavior: endOfBook.rawValue
        )
        world.library.library.addBook(book)
        return book
    }

    /// Start `reader` speaking from its cursor, then stop its speech before
    /// the main run loop turns, so nothing is heard. The chapter play stays
    /// under way, with its look-ahead.
    ///
    /// - Returns: The end of that chapter's speech, to report as the speech
    ///   service reports it once the chapter has been spoken.
    func startSpeakingSilentlyUntilItsEnd(_ reader: ReaderViewModel) throws -> () -> Void {
        reader.play()
        let endOfChapter = try XCTUnwrap(reader.speechService.onUtteranceFinished, "Speech did not start")
        reader.speechService.stop()
        return endOfChapter
    }

    /// Report the end of a chapter's speech through `endOfChapter`, then stop
    /// anything `reader` began speaking in reply before the main run loop
    /// turns, so nothing is heard.
    ///
    /// - Returns: Whether the reader went on speaking.
    func endSpeechSilently(_ endOfChapter: () -> Void, of reader: ReaderViewModel) -> Bool {
        endOfChapter()
        let spokeOn = reader.speechService.isSpeaking
        reader.speechService.stop()
        return spokeOn
    }
}
