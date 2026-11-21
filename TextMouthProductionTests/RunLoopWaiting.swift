import XCTest

/// Waiting on the main run loop for work that arrives there later: observations,
/// callbacks, and main-queue tasks. It names no audio framework, so the
/// iPhone's unit tests share this file with the Mac's (AudioTestFixtures keeps
/// the waits that name an AVPlayerItem).
extension XCTestCase {
    /// Let queued main-queue work, such as AVFoundation observations, run
    /// for `interval` seconds.
    @MainActor
    func spinMainRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// Waits for one turn of the main queue: everything queued on it before
    /// the call has run when this returns, such as the library's published
    /// `openBookIDs`, which follows a reader's registration a turn later
    /// (B22). The wait has a limit.
    @MainActor
    func waitForMainQueueTurn() {
        let turn = expectation(description: "a turn of the main queue")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 5)
    }

    /// The wait for one turn of the main queue, for a test that is `async`:
    /// it suspends instead of blocking the main actor, which the blocking
    /// wait cannot do there (B22).
    @MainActor
    func waitForMainQueueTurnAsync() async {
        // Named `continuation`, the one name the iPhone unit bundle's sound check lets resume
        // (Scripts/agents/ios_ui_tests.py), since a continuation's resume makes no sound.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Run the main run loop until `condition` holds or `timeout` passes.
    ///
    /// - Returns: Whether `condition` came to hold.
    @MainActor
    func eventually(within timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            spinMainRunLoop(for: 0.01)
        }
        return condition()
    }

    /// Waits, letting the main actor run, until `condition` holds or
    /// `timeout` seconds pass, and returns whether it held: for what code
    /// does in tasks of its own, such as the recorder's, or a wait for held
    /// storage work to end, so a wait that never ends fails its test rather
    /// than hanging it.
    @MainActor
    func eventually(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
