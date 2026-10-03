import XCTest
@testable import TextMouth

/// The library list's cloud commands (FR02): which a book or a selection
/// offers, what they are called, and what they do and say. Download Now and
/// Remove Download appear only in a cloud library; Show in Finder in every
/// library. Commands act on the clicked book or on the selection it belongs
/// to, and their titles count the books they act on.
@MainActor
final class LibraryCloudCommandTests: XCTestCase {
    /// A download partway done.
    private let partway = BookDownloadProgress(completedFiles: 1, totalFiles: 2, completedBytes: 300, totalBytes: 900)

    // MARK: - Commands Offered

    /// A local library offers only Show in Finder, whatever was recorded.
    func testLocalLibraryOffersOnlyShowInFinder() {
        let book = cloudTestBook()
        let states = BookCloudStates()
        states.record(.inCloud, for: book.id)

        XCTAssertEqual(titles(of: LibraryCloudCommand.commands(for: [book], isSelection: false, states: states)), ["Show in Finder"])
    }

    /// In a cloud library each state offers its commands: Download Now for
    /// a book in the cloud or whose download failed, Remove Download for a
    /// downloaded one, and Show in Finder for every book whose package is on
    /// this Mac. A book not checked yet offers only Show in Finder.
    func testCloudLibraryOffersCommandsByState() {
        let expected: [(BookCloudState?, [String])] = [
            (nil, ["Show in Finder"]),
            (.downloaded, ["Remove Download", "Show in Finder"]),
            (.inCloud, ["Download Now", "Show in Finder"]),
            (.downloadFailed("It failed."), ["Download Now", "Show in Finder"]),
            (.downloading(partway), ["Show in Finder"]),
            (.waitingForSync, []),
            (.local, ["Show in Finder"]),
        ]
        for (state, commandTitles) in expected {
            let book = cloudTestBook()
            let states = cloudStates(recording: state.map { [book.id: $0] } ?? [:])

            XCTAssertEqual(
                titles(of: LibraryCloudCommand.commands(for: [book], isSelection: false, states: states)),
                commandTitles,
                "\(String(describing: state))"
            )
        }
    }

    /// For a selection, each command acts on the books it suits and its
    /// title counts them, as "Move 3 Books to Folder…" does.
    func testSelectionCommandsActOnTheBooksTheySuit() {
        let books = [
            cloudTestBook("Moby-Dick"),
            cloudTestBook("Middlemarch", author: "George Eliot"),
            cloudTestBook("Bleak House", author: "Charles Dickens"),
            cloudTestBook("Cranford", author: "Elizabeth Gaskell"),
        ]
        let states = cloudStates(recording: [
            books[0].id: .inCloud,
            books[1].id: .downloadFailed("It failed."),
            books[2].id: .downloaded,
            books[3].id: .waitingForSync,
        ])

        let commands = LibraryCloudCommand.commands(for: books, isSelection: true, states: states)

        XCTAssertEqual(titles(of: commands), ["Download 2 Books", "Remove Download of 1 Book", "Show 3 Books in Finder"])
        XCTAssertEqual(commands.map { $0.books.map(\.title) }, [
            ["Moby-Dick", "Middlemarch"],
            ["Bleak House"],
            ["Moby-Dick", "Middlemarch", "Bleak House"],
        ])
    }

    /// A selection of downloaded books removes all their downloads, and a
    /// selection of books in the cloud downloads them all.
    func testSelectionTitlesCountEveryBook() {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Middlemarch"), cloudTestBook("Bleak House")]
        let downloaded = cloudStates(recording: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.downloaded)
        }))
        let inCloud = cloudStates(recording: Dictionary(uniqueKeysWithValues: books.map {
            ($0.id, BookCloudState.inCloud)
        }))

        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: books, isSelection: true, states: downloaded)),
            ["Remove Downloads of 3 Books", "Show 3 Books in Finder"]
        )
        XCTAssertEqual(
            titles(of: LibraryCloudCommand.commands(for: books, isSelection: true, states: inCloud)),
            ["Download 3 Books", "Show 3 Books in Finder"]
        )
    }

    // MARK: - Wording

    /// Titles in a sentence join as "A", "A and B", "A, B, and C".
    func testListsJoinTitlesInASentence() {
        XCTAssertEqual(LibraryCloudWording.list([]), "")
        XCTAssertEqual(LibraryCloudWording.list(["Moby-Dick"]), "Moby-Dick")
        XCTAssertEqual(LibraryCloudWording.list(["Moby-Dick", "Emma"]), "Moby-Dick and Emma")
        XCTAssertEqual(LibraryCloudWording.list(["Moby-Dick", "Emma", "Dracula"]), "Moby-Dick, Emma, and Dracula")
    }

    /// A command that ended nothing says nothing.
    func testNothingEndedSaysNothing() {
        XCTAssertNil(LibraryCloudWording.downloadFinished(downloaded: [], failed: []))
        XCTAssertNil(LibraryCloudWording.removalFinished(removed: [], refused: [], provider: .dropbox))
    }

    /// The same reason for several books is said once.
    func testASharedReasonIsSaidOnce() {
        let offline = BookCloudError.offline.explanation(in: .googleDrive)

        XCTAssertEqual(
            LibraryCloudWording.downloadFinished(
                downloaded: [],
                failed: [(title: "Moby-Dick", explanation: offline), (title: "Emma", explanation: offline)]
            ),
            "2 books weren't downloaded: Moby-Dick and Emma. " + offline
        )
    }

    // MARK: - Helpers

    /// The titles of `commands`, in order.
    private func titles(of commands: [LibraryCloudCommand]) -> [String] {
        commands.map(\.title)
    }

    /// A store for a library in iCloud Drive with `recorded` states.
    private func cloudStates(recording recorded: [UUID: BookCloudState]) -> BookCloudStates {
        let states = BookCloudStates()
        states.setLibraryLocation(.cloud(.iCloudDrive))
        for (bookID, state) in recorded {
            states.record(state, for: bookID)
        }
        return states
    }
}
