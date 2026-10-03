import Foundation

// Fixtures shared by the log tests (`LogWriteSafetyTests` and
// `LogLocationTests`), so each exists once.

/// A value a test shares with the closures that a log writer of the test's
/// own reads on its queue, such as the folder lines go to, so the test can
/// change it between lines.
///
/// `@unchecked Sendable`: the one variable is read and changed only while
/// holding `lock`.
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    /// Guards `stored`: the test changes it, the writer's queue reads it.
    private let lock = NSLock()
    /// The value, read and changed only under `lock`.
    private var stored: Value

    /// A box holding `value`.
    init(_ value: Value) {
        stored = value
    }

    /// The value now.
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
