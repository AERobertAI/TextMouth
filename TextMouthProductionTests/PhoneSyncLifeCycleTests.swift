import XCTest
@testable import TextMouth

/// The sync's moments that the iPhone's life cycle makes (FR43): each
/// activation, and the move to the background with its held task. A stand-in
/// takes the place of `SyncCenter`, and a wait that returns at once takes the
/// place of the hold's limit, so nothing here sleeps or touches a folder.
@MainActor
final class PhoneSyncLifeCycleTests: XCTestCase {
    /// What the handlers did, in order.
    private final class Record {
        var moments: [SyncReason] = []
        var holdsBegun: [String] = []
        var holdsEnded = 0
        var waited: [Duration] = []
    }

    /// A life cycle with the sync's handlers on it, over `isOn`.
    private func makeLifeCycle(_ record: Record, isOn: Bool, hold: Duration = .seconds(20)) -> PhoneLifeCycle {
        let lifeCycle = PhoneLifeCycle()
        lifeCycle.beginHold = { name in
            record.holdsBegun.append(name)
            return { record.holdsEnded += 1 }
        }
        PhoneSyncLifeCycle.install(
            on: lifeCycle,
            isOn: { isOn },
            moment: { record.moments.append($0) },
            hold: hold,
            wait: { duration in record.waited.append(duration) }
        )
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

    /// Going to the background is the background moment, held by a task that ends at its limit and not before the moment began.
    func testTheBackgroundMomentIsHeldForItsLimit() async {
        let record = Record()
        let lifeCycle = makeLifeCycle(record, isOn: true, hold: .seconds(20))
        lifeCycle.sceneDidEnterBackground()
        XCTAssertEqual(record.moments, [.background])
        XCTAssertEqual(record.holdsBegun, ["sync"])
        // The ending waits for the limit on a task of its own; give that task its turn.
        for _ in 0..<5 where record.holdsEnded == 0 { await Task.yield() }
        XCTAssertEqual(record.waited, [.seconds(20)])
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
        XCTAssertEqual(record.waited, [])
    }

    /// The hold's limit is 20 seconds, as the plan says.
    func testTheBackgroundLimitIsTwentySeconds() {
        XCTAssertEqual(PhoneSyncLifeCycle.backgroundHold, .seconds(20))
    }
}
