import XCTest
@testable import TextMouth

/// Cover the release paths used by background library analysis and normal UI teardown.
final class LibraryLifecycleTests: XCTestCase {
    /// Reproduce the crash report's final release on a utility queue. Retaining the
    /// timer separately also proves cleanup happens, rather than merely avoiding a trap.
    @MainActor
    func testBackgroundFinalReleaseInvalidatesTimerOnMainThread() async throws {
        var model: LibraryViewModel? = LibraryViewModel(initializeServices: false)
        model?.startRefreshTimer()
        let timer = try XCTUnwrap(model?.refreshTimer?.timer)
        weak var releasedModel = model
        let backgroundOwner = BackgroundOwner(try XCTUnwrap(model))
        model = nil
        XCTAssertTrue(timer.isValid)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                backgroundOwner.release()
                // Deinit enqueues timer invalidation before this main-queue marker.
                // Resuming here makes the assertions deterministic without sleeps.
                DispatchQueue.main.async { continuation.resume() }
            }
        }

        XCTAssertNil(releasedModel)
        XCTAssertFalse(timer.isValid)
    }

    /// Ordinary teardown should cancel synchronously without an extra timer tick.
    @MainActor
    func testMainThreadFinalReleaseInvalidatesTimerImmediately() throws {
        var model: LibraryViewModel? = LibraryViewModel(initializeServices: false)
        model?.startRefreshTimer()
        let timer = try XCTUnwrap(model?.refreshTimer?.timer)
        weak var releasedModel = model

        model = nil

        XCTAssertNil(releasedModel)
        XCTAssertFalse(timer.isValid)
    }

    /// Restarting refresh must leave only the replacement timer active, with the
    /// same callback behavior used to update library time estimates.
    @MainActor
    func testRestartCancelsPreviousTimerAndReplacementRefreshesLibrary() throws {
        let model = LibraryViewModel(initializeServices: false)
        model.startRefreshTimer()
        let previousTimer = try XCTUnwrap(model.refreshTimer?.timer)
        model.startRefreshTimer()
        let replacementTimer = try XCTUnwrap(model.refreshTimer?.timer)

        XCTAssertFalse(previousTimer.isValid)
        XCTAssertTrue(replacementTimer.isValid)
        replacementTimer.fire()
        XCTAssertEqual(model.refreshTick, 1)
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
