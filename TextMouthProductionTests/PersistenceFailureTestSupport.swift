import XCTest
@testable import TextMouth

// Fixtures shared by the tests of failed writes and cleanups (TODO S09).

/// A write failure with a fixed reason, so sentences compare word for word.
struct WriteRefused: LocalizedError {
    var errorDescription: String? { "The volume is read-only." }
}

/// Records each call a test hands to the code under test, such as a retry
/// or a file operation. Main-actor isolated, so `@Sendable` closures may
/// capture it.
@MainActor
final class CallLog<Value> {
    /// Every value recorded so far, in order.
    private(set) var calls: [Value] = []

    /// Records one call.
    func record(_ value: Value) {
        calls.append(value)
    }
}
