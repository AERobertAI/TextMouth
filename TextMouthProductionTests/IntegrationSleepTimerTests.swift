import Combine
import XCTest
@testable import TextMouth

/// Sleep timer expiry at the real boundary (TODO Q04; repair F17): the
/// shared timer counts down on its own clock, fades the owning reader's
/// real audio out, and pauses it, while another book's reader window
/// closes, as windows do when a listener settles down for the night.
@MainActor
final class IntegrationSleepTimerTests: XCTestCase {
    /// Subscriptions the test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    /// A one-minute sleep timer with one second left, set in a reader
    /// playing silent audio with a one-second fade, pauses that reader once,
    /// when the fade has finished, and says so once ("Sleep timer expired.
    /// Playback paused."), even though another book's reader closes while
    /// the audio fades out. The volume is back to full for the next Play,
    /// and the timer has ended.
    ///
    /// The single shared timer belongs to the book that set it, so only that
    /// book's reader may cancel its fade. Before the repair, any reader that
    /// stopped during a fade cancelled it. With that decision restored in
    /// `ReaderViewModel.stop()` (commit 709c3b2 no longer reverts cleanly),
    /// this test fails with "XCTAssertTrue failed - The timer never paused
    /// Night Reading": the fade is cancelled, the book plays on at full
    /// volume, and nothing is announced.
    func testExpiringTimerPausesItsOwnBookOnceWhileAnotherBooksWindowCloses() throws {
        let timer = SleepTimerService.shared
        preserveSharedSleepTimer()
        let world = try makeIntegrationWorld("Integration Sleep Timer")
        world.settings.sleepFadeOutDuration = 1
        let owner = try world.makeSilentAudioBook(title: "Night Reading", trackDurations: [30])
        let other = try world.makeSilentAudioBook(title: "Morning Reading", trackDurations: [30])
        let ownerReader = world.openReader(for: owner)
        let otherReader = world.openReader(for: other)
        waitForReaderToLoad(ownerReader)
        waitForReaderToLoad(otherReader)
        let pauses = countPauses(of: ownerReader)

        let recorder = recordingAnnouncements {
            ownerReader.play()
            XCTAssertTrue(
                waitUntil(timeout: 5) { ownerReader.audioPlaybackService.isPlaying },
                "Night Reading never started playing"
            )
            ownerReader.startSleepTimer(duration: .minutes(1))
            // One second left on the clock: the next tick expires it.
            timer.remainingSeconds = 1
            XCTAssertTrue(waitUntil(timeout: 3) { timer.isFadingOut }, "The timer never began to fade out")

            otherReader.close()

            XCTAssertTrue(
                waitUntil(timeout: 4) { ownerReader.isCurrentlyPaused },
                "The timer never paused Night Reading"
            )
            // Another pause or announcement would follow within a countdown
            // tick; none may.
            XCTAssertFalse(
                waitUntil(timeout: 1.2) { pauses() > 1 || timer.isActive },
                "The timer paused again or started again"
            )
        }

        XCTAssertEqual(pauses(), 1, "Night Reading was not paused exactly once")
        XCTAssertEqual(recorder.announcements.map(\.message), ["Sleep timer expired. Playback paused."])
        XCTAssertTrue(ownerReader.audioPlaybackService.isPaused, "The audio is not paused")
        XCTAssertEqual(ownerReader.audioPlaybackService.outputVolume, 1, "The volume was not restored for the next Play")
        XCTAssertFalse(timer.isActive)
        XCTAssertFalse(timer.isFadingOut)
    }

    // MARK: - Helpers

    /// Counts each time `reader` goes from not paused to paused from now on.
    /// - Returns: A function reading the count so far.
    private func countPauses(of reader: ReaderViewModel) -> () -> Int {
        var count = 0
        reader.$isCurrentlyPaused
            .removeDuplicates()
            .dropFirst()
            .filter { $0 }
            .sink { _ in count += 1 }
            .store(in: &subscriptions)
        return { count }
    }
}
