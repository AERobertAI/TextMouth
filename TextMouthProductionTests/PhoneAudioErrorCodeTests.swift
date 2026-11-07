import XCTest
@testable import TextMouth

/// The audio session's error codes, as the log writes them.
final class PhoneAudioErrorCodeTests: XCTestCase {
    /// The codes and numbers `AudioSessionTypes.h:84-97` gives.
    func testTheHeadersCodesReadAsTheirFourCharacters() {
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 560030580), "!act")
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 560557684), "!int")
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 561015905), "!pla")
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 561017449), "!pri")
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 1768841571), "inac")
        XCTAssertEqual(PhoneAudioErrorCode.fourCharacters(of: 1836282486), "msrv")
    }

    func testTheDescriptionGivesBoth() {
        XCTAssertEqual(PhoneAudioErrorCode.description(of: 560557684), "'!int' (560557684)")
    }

    func testANumberThatIsNoFourCharactersIsWrittenAsANumber() {
        XCTAssertNil(PhoneAudioErrorCode.fourCharacters(of: -50))
        XCTAssertNil(PhoneAudioErrorCode.fourCharacters(of: 0))
        XCTAssertNil(PhoneAudioErrorCode.fourCharacters(of: 4))
        XCTAssertNil(PhoneAudioErrorCode.fourCharacters(of: Int(UInt32.max) + 1))
        XCTAssertEqual(PhoneAudioErrorCode.description(of: -50), "-50")
    }
}
