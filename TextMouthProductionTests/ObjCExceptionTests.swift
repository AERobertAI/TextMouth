import XCTest
@testable import TextMouth

/// `ObjCException.catching(_:)`: the way a framework call that may raise an
/// Objective-C exception is made without ending the process.
final class ObjCExceptionTests: XCTestCase {
    /// A block that raises nothing runs once, and no exception comes back.
    func testABlockThatRaisesNothingRunsAndYieldsNil() {
        var runs = 0

        let caught = ObjCException.catching { runs += 1 }

        XCTAssertNil(caught)
        XCTAssertEqual(runs, 1)
    }

    /// A block that raises comes back as that very exception, name, reason,
    /// and user info intact, and the test goes on.
    func testABlockThatRaisesYieldsTheExceptionItRaised() throws {
        let name = NSExceptionName("TextMouthTestException")

        let caught = ObjCException.catching {
            NSException(name: name, reason: "the output stopped cycling", userInfo: ["key": 1]).raise()
        }

        let exception = try XCTUnwrap(caught, "the exception was not caught")
        XCTAssertEqual(exception.name, name)
        XCTAssertEqual(exception.reason, "the output stopped cycling")
        XCTAssertEqual(exception.userInfo?["key"] as? Int, 1)
    }

    /// The statements before the raise ran, and the catcher is usable again
    /// after it caught one.
    func testTheCatcherWorksAgainAfterCatching() {
        var steps: [String] = []

        let first = ObjCException.catching {
            steps.append("before")
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
            steps.append("after")
        }
        let second = ObjCException.catching { steps.append("again") }

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(steps, ["before", "again"])
    }

    /// The log line names the tag, the exception, and its reason, and says
    /// so when the exception gave none.
    func testTheLogLineNamesTheExceptionAndItsReason() {
        let withReason = NSException(name: NSExceptionName("NSInternalInconsistencyException"), reason: "no IO cycle", userInfo: nil)
        let withoutReason = NSException(name: NSExceptionName("Odd"), reason: nil, userInfo: nil)

        XCTAssertEqual(
            ObjCException.logLine(tag: "SPEECH_PLAYER_EXCEPTION", for: withReason),
            "SPEECH_PLAYER_EXCEPTION: NSInternalInconsistencyException: no IO cycle"
        )
        XCTAssertEqual(
            ObjCException.logLine(tag: "SPEECH_PLAYER_EXCEPTION", for: withoutReason),
            "SPEECH_PLAYER_EXCEPTION: Odd: no reason given"
        )
    }
}
