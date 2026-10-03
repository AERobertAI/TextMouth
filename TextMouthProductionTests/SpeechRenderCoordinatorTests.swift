import os
import XCTest
@testable import TextMouth

/// The coordinator's closures are `@Sendable`, so what they record lives
/// in `OSAllocatedUnfairLock`s rather than captured variables.
final class SpeechRenderCoordinatorTests: XCTestCase {
    func testRendersAreSerialized() {
        let coordinator = SpeechRenderCoordinator()
        let bothFinished = expectation(description: "both renders finished")
        bothFinished.expectedFulfillmentCount = 2
        // How many renders are running, and whether two ever ran at once.
        let renders = OSAllocatedUnfairLock(initialState: (active: 0, overlapDetected: false))

        for _ in 0..<2 {
            coordinator.enqueue(
                textLength: 10,
                shouldStart: { true },
                start: { finish in
                    renders.withLock { state in
                        state.active += 1
                        state.overlapDetected = state.overlapDetected || state.active > 1
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        renders.withLock { $0.active -= 1 }
                        finish(true)
                    }
                },
                completion: { success in
                    XCTAssertTrue(success)
                    bothFinished.fulfill()
                }
            )
        }

        wait(for: [bothFinished], timeout: 1)
        XCTAssertFalse(renders.withLock { $0.overlapDetected })
    }

    func testOversizedRenderIsRejectedWithoutStarting() {
        let coordinator = SpeechRenderCoordinator()
        let rejected = expectation(description: "oversized render rejected")
        let started = OSAllocatedUnfairLock(initialState: false)

        coordinator.enqueue(
            textLength: SpeechRenderCoordinator.maximumTextLength + 1,
            shouldStart: { true },
            start: { _ in started.withLock { $0 = true } },
            completion: { success in
                XCTAssertFalse(success)
                rejected.fulfill()
            }
        )

        wait(for: [rejected], timeout: 1)
        XCTAssertFalse(started.withLock { $0 })
    }

    func testStaleQueuedRenderIsRejectedBeforeStarting() {
        let coordinator = SpeechRenderCoordinator()
        let firstStarted = expectation(description: "first render started")
        let staleRejected = expectation(description: "stale render rejected")
        // The generation the queued render was made for is 1; the test
        // moves on to 2 while it waits.
        let generation = OSAllocatedUnfairLock(initialState: 1)
        let staleStarted = OSAllocatedUnfairLock(initialState: false)

        coordinator.enqueue(
            textLength: 10,
            shouldStart: { true },
            start: { finish in
                firstStarted.fulfill()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { finish(true) }
            },
            completion: { _ in }
        )
        coordinator.enqueue(
            textLength: 10,
            shouldStart: { generation.withLock { $0 } == 1 },
            start: { _ in staleStarted.withLock { $0 = true } },
            completion: { success in
                XCTAssertFalse(success)
                staleRejected.fulfill()
            }
        )

        wait(for: [firstStarted], timeout: 1)
        generation.withLock { $0 = 2 }
        wait(for: [staleRejected], timeout: 1)
        XCTAssertFalse(staleStarted.withLock { $0 })
    }
}
