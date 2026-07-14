import XCTest
@testable import TextMouth

final class MediaGestureDetectorTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000)

    /// Builds an enabled detector so each test only states the behavior that
    /// differs from the normal configured state.
    private func detector(_ pattern: [MediaGestureDetector.EventType]) -> MediaGestureDetector {
        let detector = MediaGestureDetector()
        detector.isEnabled = true
        detector.pattern = pattern
        return detector
    }

    func testEmptyPatternNeverMatches() {
        XCTAssertFalse(detector([]).recordEvent(.play, at: origin))
    }

    func testDisabledDetectorNeverMatches() {
        let detector = MediaGestureDetector()
        detector.pattern = [.previousTrack, .previousTrack, .previousTrack]

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.1)))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.2)))
    }

    func testMatchOccursOnFinalCorrectEvent() {
        let detector = detector([.previousTrack, .previousTrack, .previousTrack])

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.3)))
        XCTAssertTrue(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.6)))
    }

    func testWrongMiddleEventPreventsMatch() {
        let detector = detector([.previousTrack, .previousTrack, .previousTrack])

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.nextTrack, at: origin.addingTimeInterval(0.2)))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.4)))
    }

    func testExpiredEventsAreExcludedFromWindow() {
        let detector = detector([.previousTrack, .previousTrack, .previousTrack])
        detector.window = 2

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(3)))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(3.1)))
        XCTAssertTrue(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(3.2)))
    }

    func testSuccessfulMatchClearsBuffer() {
        let detector = detector([.nextTrack, .nextTrack])

        XCTAssertFalse(detector.recordEvent(.nextTrack, at: origin))
        XCTAssertTrue(detector.recordEvent(.nextTrack, at: origin.addingTimeInterval(0.1)))
        XCTAssertFalse(detector.recordEvent(.nextTrack, at: origin.addingTimeInterval(0.2)))
        XCTAssertTrue(detector.recordEvent(.nextTrack, at: origin.addingTimeInterval(0.3)))
    }

    func testMixedEventPatternMatchesInOrder() {
        let detector = detector([.previousTrack, .nextTrack, .play])

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.nextTrack, at: origin.addingTimeInterval(0.2)))
        XCTAssertTrue(detector.recordEvent(.play, at: origin.addingTimeInterval(0.5)))
    }

    func testRightEventTypesInWrongOrderDoNotMatch() {
        let detector = detector([.previousTrack, .nextTrack, .play])

        XCTAssertFalse(detector.recordEvent(.nextTrack, at: origin))
        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.1)))
        XCTAssertFalse(detector.recordEvent(.play, at: origin.addingTimeInterval(0.2)))
    }

    func testResetDiscardsPartialSequence() {
        let detector = detector([.previousTrack, .previousTrack, .previousTrack])
        _ = detector.recordEvent(.previousTrack, at: origin)
        _ = detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.1))

        detector.reset()

        XCTAssertFalse(detector.recordEvent(.previousTrack, at: origin.addingTimeInterval(0.2)))
    }

    func testPatternEncodingRoundTripsEveryEventType() {
        let pattern = MediaGestureDetector.EventType.allCases
        let encoded = MediaGestureDetector.patternToString(pattern)

        XCTAssertEqual(MediaGestureDetector.patternFromString(encoded), pattern)
    }

    func testPatternDecoderCapsExcessSteps() {
        let raw = Array(repeating: "previousTrack", count: 20).joined(separator: ",")

        XCTAssertEqual(
            MediaGestureDetector.patternFromString(raw),
            Array(repeating: .previousTrack, count: MediaGestureDetector.maxPatternLength)
        )
    }

    func testConcurrentSingleEventMatchesAreSerialized() {
        let detector = detector([.play])
        let queue = DispatchQueue(label: "MediaGestureDetectorTests.concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var matches = 0

        for index in 0..<1_000 {
            group.enter()
            queue.async {
                let matched = detector.recordEvent(
                    .play,
                    at: self.origin.addingTimeInterval(Double(index) / 1_000)
                )
                if matched {
                    resultLock.lock()
                    matches += 1
                    resultLock.unlock()
                }
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(matches, 1_000)
    }

    func testMalformedPatternDropsUnknownValuesAndKeepsValidOnes() {
        XCTAssertEqual(
            MediaGestureDetector.patternFromString("junk,nextTrack,bogus"),
            [.nextTrack]
        )
    }
}
