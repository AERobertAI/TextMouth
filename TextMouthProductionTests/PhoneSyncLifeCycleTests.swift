import XCTest
@testable import TextMouth

/// The sync's moments that the iPhone's life cycle makes (FR43): each
/// activation, and the move to the background with its held task, which ends when
/// the send does or at its limit, whichever is first. A stand-in takes the place
/// of `SyncCenter`, and each wait is a gate the test opens, so nothing here sleeps
/// for a guessed time or touches a folder.
@MainActor
final class PhoneSyncLifeCycleTests: XCTestCase {
    /// A wait that lasts until the test opens it.
    private final class Gate: @unchecked Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }

        /// Returns once `open()` has been called.
        func wait() async { for await _ in stream {} }

        /// Lets every `wait()` return.
        func open() { continuation.finish() }
    }

    /// What the handlers did, in order.
    private final class Record {
        var moments: [SyncReason] = []
        var holdsBegun: [String] = []
        var holdsEnded = 0
        /// Fulfilled each time a hold ends.
        var ended: XCTestExpectation?
    }

    /// A life cycle with the sync's handlers on it, over `isOn`.
    private func makeLifeCycle(
        _ record: Record,
        isOn: Bool,
        idle: @escaping @MainActor () async -> Void = {},
        wait: @escaping @MainActor (Duration) async -> Void = { _ in }
    ) -> PhoneLifeCycle {
        let lifeCycle = PhoneLifeCycle()
        lifeCycle.beginHold = { name in
            record.holdsBegun.append(name)
            return {
                record.holdsEnded += 1
                record.ended?.fulfill()
            }
        }
        PhoneSyncLifeCycle.install(on: lifeCycle, isOn: { isOn }, moment: { record.moments.append($0) }, idle: idle, wait: wait)
        return lifeCycle
    }

    /// Becoming active is the active moment, each time.
    func testEachActivationIsAMoment() {
        let record = Record()
        let lifeCycle = makeLifeCycle(record, isOn: true)
        lifeCycle.sceneDidBecomeActive()
        lifeCycle.sceneDidBecomeActive()
        XCTAssertEqual(record.moments, [.active, .active])
    }

    /// The hold begins with the background moment and ends when the send does, though the limit has not come: the hold is
    /// tied to the sync, not to a guessed time.
    func testTheHoldEndsWhenTheSendDoes() async {
        let record = Record()
        record.ended = expectation(description: "the hold ends")
        let limit = Gate()
        let lifeCycle = makeLifeCycle(record, isOn: true, wait: { _ in await limit.wait() })
        lifeCycle.sceneDidEnterBackground()
        XCTAssertEqual(record.moments, [.background])
        XCTAssertEqual(record.holdsBegun, ["sync"])
        await fulfillment(of: [record.ended!], timeout: 10)
        XCTAssertEqual(record.holdsEnded, 1)
        // The limit coming later ends nothing twice.
        limit.open()
        await Task.yield()
        XCTAssertEqual(record.holdsEnded, 1)
    }

    /// A send that never finishes is cut off at the limit: the hold ends there, once.
    func testTheHoldEndsAtTheLimitWhenTheSendDoesNot() async {
        let record = Record()
        record.ended = expectation(description: "the hold ends")
        let send = Gate()
        var limits: [Duration] = []
        let lifeCycle = makeLifeCycle(record, isOn: true, idle: { await send.wait() }, wait: { limits.append($0) })
        lifeCycle.sceneDidEnterBackground()
        await fulfillment(of: [record.ended!], timeout: 10)
        XCTAssertEqual(record.holdsEnded, 1)
        XCTAssertEqual(limits, [.seconds(20)])
        // The send finishing later ends nothing twice.
        send.open()
        await Task.yield()
        XCTAssertEqual(record.holdsEnded, 1)
    }

    /// With sync off, nothing happens at either moment: no task, no hold, no call (R1).
    func testNothingHappensWhileSyncIsOff() async {
        let record = Record()
        let lifeCycle = makeLifeCycle(record, isOn: false)
        lifeCycle.sceneDidBecomeActive()
        lifeCycle.sceneDidEnterBackground()
        await Task.yield()
        XCTAssertEqual(record.moments, [])
        XCTAssertEqual(record.holdsBegun, [])
    }

    /// The hold's limit is 20 seconds, as the plan says.
    func testTheBackgroundLimitIsTwentySeconds() {
        XCTAssertEqual(PhoneSyncLifeCycle.backgroundHold, .seconds(20))
    }
}
