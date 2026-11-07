import XCTest
@testable import TextMouth

/// Saving on the iPhone (`PhoneLifeCycle+Saving`): the timed flush, and what a
/// memory warning lets go of and saves. The flush and the clock are the
/// test's own where it can give them; the memory warning runs over real readers
/// of a silent audiobook in a private world.
@MainActor
final class PhoneLifeCycleSavingTests: XCTestCase {
    /// What the test's clock reads, one reading at a time.
    private var readings: [ContinuousClock.Instant] = []
    /// How many times the test's flush ran.
    private var flushes = 0
    /// The names of the holds begun.
    private var holds: [String] = []
    /// How many holds were ended.
    private var holdsEnded = 0

    /// The flush runs once, and its time is what the clock read around it.
    func testTheFlushRunsOnceAndIsTimed() {
        let start = ContinuousClock.now
        readings = [start, start.advanced(by: .milliseconds(42))]

        let took = PhoneLifeCycle.flushPendingWrites(
            because: "test",
            flush: { [unowned self] in self.flushes += 1 },
            now: { [unowned self] in self.readings.removeFirst() }
        )

        XCTAssertEqual(flushes, 1)
        XCTAssertEqual(took, .milliseconds(42))
        XCTAssertTrue(readings.isEmpty, "The clock is read before and after, once each")
    }

    /// The log's milliseconds are whole ones, rounded down.
    func testMillisecondsForTheLog() {
        XCTAssertEqual(PhoneLifeCycle.milliseconds(.milliseconds(1_250)), 1_250)
        XCTAssertEqual(PhoneLifeCycle.milliseconds(.microseconds(1_999)), 1)
        XCTAssertEqual(PhoneLifeCycle.milliseconds(.zero), 0)
    }

    /// A memory warning in the background saves inside a hold named for it;
    /// in front, no hold is begun, since the app is not about to be suspended.
    func testAMemoryWarningHoldsOnlyInTheBackground() throws {
        let world = try makeIntegrationWorld("PhoneMemoryWarning")
        let session = makeSession(in: world)
        let lifeCycle = PhoneLifeCycle()
        lifeCycle.beginHold = { [unowned self] name in
            self.holds.append(name)
            return { [unowned self] in self.holdsEnded += 1 }
        }

        lifeCycle.memoryWarningReceived(in: session, isInBackground: false)
        XCTAssertEqual(holds, [])

        lifeCycle.memoryWarningReceived(in: session, isInBackground: true)
        XCTAssertEqual(holds, ["Saving at a memory warning"])
        XCTAssertEqual(holdsEnded, 1, "The hold outlived the flush")
    }

    /// A memory warning lets go of the look-ahead only: the open reader stays
    /// open, on screen, with nothing looked ahead to.
    func testAMemoryWarningLeavesTheReaderOpen() throws {
        let world = try makeIntegrationWorld("PhoneMemoryLookAhead")
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [5, 5])
        let session = makeSession(in: world)
        let reader = try XCTUnwrap(session.open(book))
        waitForReaderToLoad(reader)
        let lifeCycle = PhoneLifeCycle()

        lifeCycle.memoryWarningReceived(in: session, isInBackground: false)

        XCTAssertNil(reader.lookAhead)
        XCTAssertFalse(reader.hasClosed)
        XCTAssertTrue(session.reader === reader)
    }

    /// A session over `world`, whose readers close as the test ends.
    private func makeSession(in world: IntegrationWorld) -> PhoneSession {
        let media = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let session = PhoneSession(
            library: world.library,
            settings: world.settings,
            soundEffects: SoundEffectService(
                preferences: makeSandboxedPreferences("PhoneLifeCycleSaving Sounds"),
                player: HeldSoundEffectPlayer(holding: false)
            ),
            notificationCenter: world.notifications,
            autoplayRequests: world.autoplayRequests,
            preferences: makeSandboxedPreferences("PhoneLifeCycleSaving"),
            makeReader: { book in world.openReader(for: book, nowPlaying: media) }
        )
        addTeardownBlock { session.closeReader() }
        return session
    }
}
