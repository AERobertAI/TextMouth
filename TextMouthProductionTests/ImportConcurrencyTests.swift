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
        let lock = NSLock()
        var firstIsRunning = false
        var overlapDetected = false

        queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock()
            firstIsRunning = true
            lock.unlock()
            firstStarted.fulfill()
            releaseFirst.wait()
            lock.lock()
            firstIsRunning = false
            lock.unlock()
            firstFinished.fulfill()
        }
        queue.enqueue {
            XCTAssertFalse(Thread.isMainThread)
            lock.lock()
            overlapDetected = firstIsRunning
            lock.unlock()
            secondStarted.signal()
        }

        wait(for: [firstStarted], timeout: 1)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 0.1), .timedOut)
        releaseFirst.signal()
        wait(for: [firstFinished], timeout: 1)
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(overlapDetected)
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
}
