import Network
import XCTest
@testable import TextMouth

/// Whether this Mac is online, as the cloud services ask it (FR02,
/// `NetworkReachability`): what the system's network path means, and the
/// fixed answers tests use.
final class NetworkReachabilityTests: XCTestCase {

    /// Only an unsatisfied path is offline. A path that needs a connection
    /// made, such as an on-demand VPN, comes up when the sync service
    /// connects, and before the first report nothing says the Mac is
    /// offline.
    func testOnlyAnUnsatisfiedPathIsOffline() {
        XCTAssertTrue(NetworkReachability.isOnline(given: .satisfied))
        XCTAssertTrue(NetworkReachability.isOnline(given: .requiresConnection))
        XCTAssertTrue(NetworkReachability.isOnline(given: nil))
        XCTAssertFalse(NetworkReachability.isOnline(given: .unsatisfied))
    }

    /// The fixed answers say what their names say.
    func testTheFixedAnswers() {
        XCTAssertTrue(NetworkReachability.online.isOnline())
        XCTAssertFalse(NetworkReachability.offline.isOnline())
    }

    /// Reachability asks its function every time, so an answer can change.
    func testReachabilityAsksItsFunctionEveryTime() {
        let answers = AnswerSequence([true, false, true])
        let reachability = NetworkReachability { answers.next() }

        XCTAssertEqual([reachability.isOnline(), reachability.isOnline(), reachability.isOnline()], [true, false, true])
    }
}

/// Answers given in order, from any thread; the last one repeats.
private final class AnswerSequence: @unchecked Sendable {
    /// Guards `answers`.
    private let lock = NSLock()
    /// The answers still to give; never empty.
    private var answers: [Bool]

    /// Answers `answers` in order; `answers` must not be empty.
    init(_ answers: [Bool]) {
        self.answers = answers
    }

    /// The next answer.
    func next() -> Bool {
        lock.withLock { answers.count > 1 ? answers.removeFirst() : answers[0] }
    }
}
