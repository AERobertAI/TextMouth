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
}
