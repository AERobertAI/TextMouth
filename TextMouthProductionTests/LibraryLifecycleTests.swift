import XCTest
@testable import TextMouth

/// Cover the release paths used by background library analysis and normal UI
/// teardown. The model kept a refresh timer, which these tests once watched;
/// the timer is gone (TODO PERF29), and the model must still be freed
/// wherever its last reference is dropped, with nothing it made keeping it
/// alive.
final class LibraryLifecycleTests: XCTestCase {
    /// Reproduce the crash report's final release on a utility queue, after
    /// the model has used what it keeps for its Library windows: the list
    /// cache and the live positions.
    @MainActor
    func testBackgroundFinalReleaseFreesTheModel() async throws {
        var model: LibraryViewModel? = LibraryViewModel(initializeServices: false)
        Self.useWhatTheModelKeeps(try XCTUnwrap(model))
        weak var releasedModel = model
        let backgroundOwner = BackgroundOwner(try XCTUnwrap(model))
        model = nil
        XCTAssertNotNil(releasedModel, "the worker holds the last reference")

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                backgroundOwner.release()
                // Resuming from the main queue, after the release, makes the
                // assertion deterministic without sleeps.
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        XCTAssertNil(releasedModel)
    }

    /// Ordinary teardown on the main thread frees the model at once.
    @MainActor
    func testMainThreadFinalReleaseFreesTheModel() throws {
        var model: LibraryViewModel? = LibraryViewModel(initializeServices: false)
        Self.useWhatTheModelKeeps(try XCTUnwrap(model))
        weak var releasedModel = model

        model = nil

        XCTAssertNil(releasedModel)
    }

    /// Fills the model's list cache and live positions, as a Library window
    /// showing a playing book does.
    @MainActor
    private static func useWhatTheModelKeeps(_ model: LibraryViewModel) {
        let book = Book(title: "Kept", format: .txt, filePath: "/tmp/kept.txt", md5Hash: "kept")
        model.library = Library(books: [book])
        _ = model.displayedBooks(at: LibraryLocation(category: .allItems, folderPath: ""), matching: "kept")
        _ = model.bookCount(inFolderTree: "")
        model.updateLiveReadingPosition(bookID: book.id, position: ReadingPosition(characterOffset: 3))
    }
}

/// Transfer sole ownership to a worker without retaining the model in a dispatched
/// closure. All mutable storage is protected by the lock, making this Sendable
/// conformance safe even if a future test releases from more than one queue.
private final class BackgroundOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var model: LibraryViewModel?

    /// Store the model before handing this owner to the worker queue.
    init(_ model: LibraryViewModel) {
        self.model = model
    }

    /// Drop the last strong reference synchronously on the calling worker.
    func release() {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        defer { lock.unlock() }
        model = nil
    }
}
