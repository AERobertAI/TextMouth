import XCTest
@testable import TextMouth

/// What pauses the books that play while Preview Voice speaks, and plays them
/// on after (`PhonePreviewPause`), over plain stand-ins for the readers.
@MainActor
final class PhonePreviewPauseTests: XCTestCase {
    /// A stand-in for a reader, counting its pauses and resumes. On the main
    /// actor, as the closures it gives are.
    @MainActor
    private final class Stand {
        var isPlaying: Bool
        private(set) var pauses = 0
        private(set) var resumes = 0

        init(isPlaying: Bool) {
            self.isPlaying = isPlaying
        }

        /// What the pause is given for this reader.
        var reader: PhonePreviewPause.Reader {
            PhonePreviewPause.Reader(
                isPlaying: { [self] in isPlaying },
                pause: { [self] in
                    isPlaying = false
                    pauses += 1
                },
                resume: { [self] in
                    isPlaying = true
                    resumes += 1
                }
            )
        }
    }

    /// With nothing playing, nothing is paused and nothing resumes.
    func testNothingPlayingPausesNothing() {
        let idle = Stand(isPlaying: false)

        XCTAssertNil(PhonePreviewPause.pause([idle.reader]))
        XCTAssertNil(PhonePreviewPause.pause([]))
        XCTAssertEqual(idle.pauses, 0)
    }

    /// The reader that plays is paused, and plays on when resumed.
    func testThePlayingBookPausesAndPlaysOn() throws {
        let playing = Stand(isPlaying: true)

        let resume = try XCTUnwrap(PhonePreviewPause.pause([playing.reader]))

        XCTAssertEqual(playing.pauses, 1)
        XCTAssertFalse(playing.isPlaying)
        resume()
        XCTAssertEqual(playing.resumes, 1)
        XCTAssertTrue(playing.isPlaying)
    }

    /// Of two readers, only the one that plays is paused and resumed: the
    /// book behind the screen's, or the screen's, either one.
    func testOnlyTheReaderThatPlaysIsTouched() throws {
        let idle = Stand(isPlaying: false)
        let playing = Stand(isPlaying: true)

        let resume = try XCTUnwrap(PhonePreviewPause.pause([idle.reader, playing.reader]))
        resume()

        XCTAssertEqual(idle.pauses, 0)
        XCTAssertEqual(idle.resumes, 0)
        XCTAssertEqual(playing.pauses, 1)
        XCTAssertEqual(playing.resumes, 1)
    }

    /// A book the listener started meanwhile is left alone: a second Play
    /// would only restart it.
    func testABookStartedMeanwhileIsNotResumedAgain() throws {
        let playing = Stand(isPlaying: true)
        let resume = try XCTUnwrap(PhonePreviewPause.pause([playing.reader]))
        playing.isPlaying = true

        resume()

        XCTAssertEqual(playing.resumes, 0)
    }
}
