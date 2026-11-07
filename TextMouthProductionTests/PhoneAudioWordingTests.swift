import XCTest
@testable import TextMouth

/// The words the iPhone's audio session says.
final class PhoneAudioWordingTests: XCTestCase {
    /// The sentence the engineer's review gives (F7), whole and plain.
    func testTheRefusedPlaySaysWhyInOneSentence() {
        XCTAssertEqual(PhoneAudioWording.cannotPlayNow, "Can't play now: a call or another app is using the audio.")
        XCTAssertTrue(PhoneAudioWording.cannotPlayNow.hasSuffix("."))
        XCTAssertFalse(PhoneAudioWording.cannotPlayNow.lowercased().contains("tap"), "a sentence names no gesture")
    }
}
