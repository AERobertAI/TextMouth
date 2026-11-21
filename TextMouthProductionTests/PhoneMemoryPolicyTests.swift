import XCTest
@testable import TextMouth

/// `PhoneMemoryPolicy`, what the iPhone's memory guard does about the memory
/// left to TextMouth, reading by reading, with no clock and no real memory.
final class PhoneMemoryPolicyTests: XCTestCase {
    /// A number of megabytes, in bytes.
    private func megabytes(_ count: UInt64) -> UInt64 {
        count << 20
    }

    // MARK: - Stopping a Playing Book

    /// The thresholds are the spec's: about 150 MB to stop a book, about
    /// 300 MB for a look-ahead render.
    func testTheThresholdsAreTheSpecs() {
        XCTAssertEqual(PhoneMemoryPolicy.stopPlaybackBelow, megabytes(150))
        XCTAssertEqual(PhoneMemoryPolicy.renderAheadNeeds, megabytes(300))
        XCTAssertEqual(PhoneMemoryPolicy().stopPlaybackBelow, megabytes(150))
    }

    /// Under the threshold while a book plays, the book is stopped; at the
    /// threshold or above, nothing happens.
    func testAPlayingBookIsStoppedUnderTheThreshold() {
        var policy = PhoneMemoryPolicy()

        XCTAssertEqual(policy.act(onAvailable: megabytes(900), isAnythingPlaying: true), .none)
        XCTAssertEqual(policy.act(onAvailable: megabytes(150), isAnythingPlaying: true), .none)
        XCTAssertEqual(
            policy.act(onAvailable: megabytes(149), isAnythingPlaying: true),
            .stopPlayback(availableBytes: megabytes(149))
        )
        XCTAssertEqual(policy.lastAvailableBytes, megabytes(149))
    }

    /// Nothing is stopped while nothing plays, however little is left: there is
    /// nothing to stop, and the guard never quits.
    func testNothingIsStoppedWhileNothingPlays() {
        var policy = PhoneMemoryPolicy()

        XCTAssertEqual(policy.act(onAvailable: megabytes(500), isAnythingPlaying: false), .none)
        XCTAssertEqual(policy.act(onAvailable: megabytes(20), isAnythingPlaying: false), .none)
    }

    /// A book played again while too little is left is stopped again at the
    /// next reading, as on the Mac.
    func testABookPlayedAgainWhileLowIsStoppedAgain() {
        var policy = PhoneMemoryPolicy()
        _ = policy.act(onAvailable: megabytes(400), isAnythingPlaying: true)

        XCTAssertEqual(
            policy.act(onAvailable: megabytes(100), isAnythingPlaying: true),
            .stopPlayback(availableBytes: megabytes(100))
        )
        XCTAssertEqual(policy.act(onAvailable: megabytes(100), isAnythingPlaying: false), .none)
        XCTAssertEqual(
            policy.act(onAvailable: megabytes(110), isAnythingPlaying: true),
            .stopPlayback(availableBytes: megabytes(110))
        )
    }

    /// A test may set its own threshold.
    func testAThresholdOfItsOwn() {
        var policy = PhoneMemoryPolicy(stopPlaybackBelow: megabytes(500))

        XCTAssertEqual(
            policy.act(onAvailable: megabytes(400), isAnythingPlaying: true),
            .stopPlayback(availableBytes: megabytes(400))
        )
    }

    // MARK: - A Reading of Zero

    /// A first reading of 0 is a process that can't be measured, as in the
    /// Simulator: the guard goes idle, and stops nothing ever after, however
    /// the readings run. Without this, every book there would be stopped.
    func testAFirstReadingOfZeroLeavesTheGuardIdle() {
        var policy = PhoneMemoryPolicy()

        XCTAssertEqual(policy.act(onAvailable: 0, isAnythingPlaying: true), .goIdle)
        XCTAssertTrue(policy.isIdle)
        XCTAssertNil(policy.lastAvailableBytes)
        XCTAssertEqual(policy.act(onAvailable: 0, isAnythingPlaying: true), .none)
        XCTAssertEqual(policy.act(onAvailable: megabytes(10), isAnythingPlaying: true), .none)
        XCTAssertTrue(policy.isIdle)
    }

    /// A first reading of 0 leaves the guard idle while nothing plays, too:
    /// what can't be measured stays so for the process.
    func testAFirstReadingOfZeroWhileNothingPlaysLeavesTheGuardIdle() {
        var policy = PhoneMemoryPolicy()

        XCTAssertEqual(policy.act(onAvailable: 0, isAnythingPlaying: false), .goIdle)
        XCTAssertTrue(policy.isIdle)
    }

    /// A 0 after a true reading means the process is over its limit: a
    /// playing book is stopped.
    func testAZeroAfterATrueReadingStopsTheBook() {
        var policy = PhoneMemoryPolicy()
        _ = policy.act(onAvailable: megabytes(800), isAnythingPlaying: false)

        XCTAssertEqual(policy.act(onAvailable: 0, isAnythingPlaying: true), .stopPlayback(availableBytes: 0))
        XCTAssertFalse(policy.isIdle)
    }

    // MARK: - Look-ahead Renders

    /// A look-ahead render needs about 300 MB left.
    func testARenderNeedsEnoughMemoryLeft() {
        XCTAssertTrue(PhoneMemoryPolicy.mayRenderAhead(availableBytes: megabytes(300), thermalState: .nominal))
        XCTAssertTrue(PhoneMemoryPolicy.mayRenderAhead(availableBytes: megabytes(2_000), thermalState: .fair))
        XCTAssertFalse(PhoneMemoryPolicy.mayRenderAhead(availableBytes: megabytes(299), thermalState: .nominal))
    }

    /// At serious or critical thermal state no look-ahead render starts,
    /// however much memory is left.
    func testAHotPhoneRendersNothingAhead() {
        XCTAssertFalse(PhoneMemoryPolicy.mayRenderAhead(availableBytes: megabytes(2_000), thermalState: .serious))
        XCTAssertFalse(PhoneMemoryPolicy.mayRenderAhead(availableBytes: megabytes(2_000), thermalState: .critical))
        XCTAssertFalse(PhoneMemoryPolicy.mayRenderAhead(availableBytes: 0, thermalState: .critical))
    }

    /// A reading of 0 says nothing about memory, so it leaves the decision to
    /// the thermal state: the Simulator still renders ahead.
    func testAReadingOfZeroLeavesTheRenderToTheThermalState() {
        XCTAssertTrue(PhoneMemoryPolicy.mayRenderAhead(availableBytes: 0, thermalState: .nominal))
        XCTAssertFalse(PhoneMemoryPolicy.mayRenderAhead(availableBytes: 0, thermalState: .serious))
    }

    /// The log's megabytes are rounded down.
    func testMegabytesForTheLog() {
        XCTAssertEqual(PhoneMemoryPolicy.megabytes(megabytes(150)), 150)
        XCTAssertEqual(PhoneMemoryPolicy.megabytes(megabytes(150) - 1), 149)
        XCTAssertEqual(PhoneMemoryPolicy.megabytes(0), 0)
    }
}
