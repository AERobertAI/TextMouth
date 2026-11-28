import XCTest
@testable import TextMouth

/// `PhoneFocusRequests`: a request for focus that waits is cancelled by the
/// listener's own move, so it can't pull focus from under a flick (the
/// interface spec, "Any focus event cancels a request still waiting").
final class PhoneFocusRequestsTests: XCTestCase {
    /// With no landing, the request's time comes and it may post, once.
    func testAnUndisturbedRequestPostsOnce() {
        var requests = PhoneFocusRequests()
        let ticket = requests.request()
        XCTAssertEqual(requests.waitingCount, 1)

        XCTAssertTrue(requests.claim(ticket), "Nothing cancelled it, yet it may not post")
        XCTAssertFalse(requests.claim(ticket), "A request posted twice")
        XCTAssertEqual(requests.waitingCount, 0)
    }

    /// A landing on a reader control, while a request waits, cancels it. Every
    /// control counts, so the test names any that does not.
    func testALandingOnAnyReaderControlCancelsTheWaitingRequest() {
        var notCancelledBy: [PhoneControlKind] = []
        for control in PhoneControlKind.allCases {
            var requests = PhoneFocusRequests()
            let ticket = requests.request()

            requests.focusLanded(on: control)

            if requests.claim(ticket) { notCancelledBy.append(control) }
        }
        XCTAssertEqual(notCancelledBy, [], "A landing on these did not cancel a waiting request")
    }

    /// A landing on the system's Back button or the title, where VoiceOver
    /// wanders by itself, is not the listener's: the request stays, as it is
    /// what puts focus back from there.
    func testALandingElsewhereCancelsNothing() {
        var requests = PhoneFocusRequests()
        let ticket = requests.request()

        requests.focusLanded(on: nil)

        XCTAssertEqual(requests.waitingCount, 1)
        XCTAssertTrue(requests.claim(ticket), "A landing on Back or the title cancelled the request")
    }

    /// One landing cancels every request that waits.
    func testALandingCancelsEveryWaitingRequest() {
        var requests = PhoneFocusRequests()
        let first = requests.request()
        let second = requests.request()
        XCTAssertNotEqual(first, second)

        requests.focusLanded(on: .headings)

        XCTAssertEqual(requests.waitingCount, 0)
        XCTAssertFalse(requests.claim(first))
        XCTAssertFalse(requests.claim(second))
    }

    /// A request made after the landing is a new one, and stands: only the
    /// requests waiting at the landing are cancelled.
    func testARequestMadeAfterALandingStands() {
        var requests = PhoneFocusRequests()
        let before = requests.request()
        requests.focusLanded(on: .speed)
        let after = requests.request()

        XCTAssertFalse(requests.claim(before), "A request that waited through a landing posted")
        XCTAssertTrue(requests.claim(after), "A request made after the landing was cancelled by it")
    }

    /// A landing with nothing waiting changes nothing, and a cancelled ticket
    /// stays cancelled however many landings follow.
    func testALandingWithNothingWaitingIsHarmless() {
        var requests = PhoneFocusRequests()
        requests.focusLanded(on: .play)
        XCTAssertEqual(requests.waitingCount, 0)

        let ticket = requests.request()
        requests.focusLanded(on: .play)
        requests.focusLanded(on: nil)
        XCTAssertFalse(requests.claim(ticket))
    }
}
