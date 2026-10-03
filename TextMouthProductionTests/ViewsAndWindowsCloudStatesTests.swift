import Combine
import XCTest
@testable import TextMouth

/// A cloud refresh reads every book's state off the main thread and then
/// records them all. Recorded one at a time, each state copied the shared
/// dictionary whole and published it, once per book: 644 times for a
/// 643-book library, redrawing every Library window each time (PERF31).
@MainActor
final class ViewsAndWindowsCloudStatesTests: XCTestCase {

    /// A first refresh of 643 books publishes twice at most, once for where
    /// the library lives and once for every book's state, and records each
    /// book's state as the storage reports it.
    func testFirstRefreshPublishesOnceForEveryBooksState() async {
        let library = CloudLibraryFixture(bookCount: 643)
        var publishes = 0
        let counter = library.states.objectWillChange.sink { publishes += 1 }
        defer { counter.cancel() }

        await library.states.refresh(library.packages, using: library.storage)

        XCTAssertLessThanOrEqual(publishes, 2, "The refresh published once per book")
        for (index, package) in library.packages.enumerated() {
            XCTAssertEqual(library.states.state(of: package.bookID), CloudLibraryFixture.state(at: index), "book \(index)")
        }
    }

    /// A refresh that finds every state as it was publishes nothing, and one
    /// that finds one book's state changed publishes once and records it.
    func testRefreshPublishesOnlyWhenAStateChanged() async {
        let library = CloudLibraryFixture(bookCount: 50)
        await library.states.refresh(library.packages, using: library.storage)
        var publishes = 0
        let counter = library.states.objectWillChange.sink { publishes += 1 }
        defer { counter.cancel() }

        await library.states.refresh(library.packages, using: library.storage)
        XCTAssertEqual(publishes, 0, "A refresh that changed nothing published")

        let changed = library.packages[0].bookID
        library.storage.setState(.downloaded, of: changed)
        await library.states.refresh(library.packages, using: library.storage)
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(library.states.state(of: changed), .downloaded)
    }
}

/// A cloud library of books the storage reports alternately in the cloud
/// and downloaded, with a store of states of the test's own.
@MainActor
private struct CloudLibraryFixture {
    let states = BookCloudStates()
    let storage = FakeBookCloudStorage(location: .cloud(.iCloudDrive))
    let packages: [BookPackage]

    init(bookCount: Int) {
        let books = (0..<bookCount).map { number in
            Book(
                title: "Cloud Book \(number)",
                format: .epub,
                filePath: "/nonexistent/cloud-states/\(number).epub",
                md5Hash: "cloud-states-\(number)"
            )
        }
        for (index, book) in books.enumerated() {
            storage.setState(Self.state(at: index), of: book.id)
        }
        packages = books.map { BookPackage($0) }
    }

    /// The state the storage reports for the book at `index`.
    static func state(at index: Int) -> BookCloudState {
        index % 2 == 0 ? .inCloud : .downloaded
    }
}
