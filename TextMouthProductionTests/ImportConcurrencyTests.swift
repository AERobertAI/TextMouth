import os
import XCTest
@testable import TextMouth

/// Regression coverage for serialized off-main import execution.
final class ImportConcurrencyTests: XCTestCase {
    func testOperationsRunOffMainThreadAndNeverOverlap() {
        let queue = SerialImportQueue()
        let firstStarted = expectation(description: "first started")
        let firstFinished = expectation(description: "first finished")
        let secondStarted = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        // What the operations saw, under one lock, as they run on the
        // import queue: whether the first is running, and whether the
        // second found it running.
        let seen = OSAllocatedUnfairLock(initialState: (firstIsRunning: false, overlapDetected: false))

        queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            seen.withLock { $0.firstIsRunning = true }
            firstStarted.fulfill()
            releaseFirst.wait()
            seen.withLock { $0.firstIsRunning = false }
            firstFinished.fulfill()
        }
        queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            seen.withLock { $0.overlapDetected = $0.firstIsRunning }
            secondStarted.signal()
        }

        wait(for: [firstStarted], timeout: 1)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        wait(for: [firstFinished], timeout: 1)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(seen.withLock { $0.overlapDetected })
    }

    func testActivityCountIncludesQueuedOperations() {
        let queue = SerialImportQueue()
        let twoQueued = expectation(description: "two queued")
        let idle = expectation(description: "idle")
        let release = DispatchSemaphore(value: 0)
        queue.onActivityChanged = { count in
            if count == 2 { twoQueued.fulfill() }
            if count == 0 { idle.fulfill() }
        }

        queue.enqueue { release.wait() }
        queue.enqueue {}
        wait(for: [twoQueued], timeout: 1)
        release.signal()
        wait(for: [idle], timeout: 1)
    }

    /// The activity observer may be replaced from any thread while an import
    /// runs: the import queue reads it under the queue's lock as the import
    /// finishes, so the replacement, not the observer it replaced, is told
    /// that the queue is idle.
    func testAnActivityObserverReplacedWhileAnImportRunsIsToldItFinished() {
        let queue = SerialImportQueue()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let replacedToldIdle = expectation(description: "the replaced observer told the queue is idle")
        replacedToldIdle.isInverted = true
        queue.onActivityChanged = { count in
            if count == 0 { replacedToldIdle.fulfill() }
        }
        queue.enqueue {
            started.signal()
            // Bounded, so a failed test never leaves the import queue stuck.
            _ = release.wait(timeout: .now() + 5)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success, "The import never started")

        let idle = expectation(description: "the replacement told the queue is idle")
        let replaced = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            queue.onActivityChanged = { count in
                if count == 0 { idle.fulfill() }
            }
            replaced.signal()
        }
        XCTAssertEqual(replaced.wait(timeout: .now() + 5), .success, "The observer was never replaced")
        release.signal()

        wait(for: [idle], timeout: 5)
        // Both observers are told on the main queue, which has now told the
        // replacement; the replaced observer must not have been told.
        wait(for: [replacedToldIdle], timeout: 0.1)
    }
}
