import XCTest
@testable import TextMouth

final class SpeechRenderCoordinatorTests: XCTestCase {
    func testRendersAreSerialized() {
        let coordinator = SpeechRenderCoordinator()
        let bothFinished = expectation(description: "both renders finished")
        bothFinished.expectedFulfillmentCount = 2
        var activeRenders = 0
        var overlapDetected = false

        for _ in 0..<2 {
            coordinator.enqueue(
                textLength: 10,
                shouldStart: { true },
                start: { finish in
                    activeRenders += 1
                    overlapDetected = overlapDetected || activeRenders > 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                        activeRenders -= 1
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
        XCTAssertFalse(overlapDetected)
    }

    func testOversizedRenderIsRejectedWithoutStarting() {
        let coordinator = SpeechRenderCoordinator()
        let rejected = expectation(description: "oversized render rejected")
        var started = false

        coordinator.enqueue(
            textLength: SpeechRenderCoordinator.maximumTextLength + 1,
            shouldStart: { true },
            start: { _ in started = true },
            completion: { success in
                XCTAssertFalse(success)
                rejected.fulfill()
            }
        )

        wait(for: [rejected], timeout: 1)
        XCTAssertFalse(started)
    }

    func testStaleQueuedRenderIsRejectedBeforeStarting() {
        let coordinator = SpeechRenderCoordinator()
        let firstStarted = expectation(description: "first render started")
        let staleRejected = expectation(description: "stale render rejected")
        var generation = 1
        var staleStarted = false

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
            shouldStart: { generation == 1 },
            start: { _ in staleStarted = true },
            completion: { success in
                XCTAssertFalse(success)
                staleRejected.fulfill()
            }
        )

        wait(for: [firstStarted], timeout: 1)
        generation = 2
        wait(for: [staleRejected], timeout: 1)
        XCTAssertFalse(staleStarted)
    }
}
