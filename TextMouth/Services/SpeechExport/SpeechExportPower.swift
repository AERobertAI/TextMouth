import Foundation
#if os(macOS)
import IOKit.pwr_mgt
#endif

/// Keeps the Mac awake while a speech export (FMT43) speaks a book into a
/// file, which can take half an hour: a power assertion that stops the Mac
/// sleeping when it is left idle, while still letting the display sleep.
///
/// An assertion's ID is a plain number, so the two closures that hold and
/// release one are all there is to it; tests pass their own, which record
/// what was asked of them.
struct SpeechExportPower: Sendable {
    /// An assertion's ID: the plain number the Mac's `IOPMAssertionID` is.
    typealias AssertionID = UInt32

    /// Holds an assertion named `reason` (the name `pmset -g assertions`
    /// lists it by), and gives its ID, or nil when the system would not
    /// take it.
    var hold: @Sendable (_ reason: String) -> AssertionID?
    /// Lets the assertion with an ID go.
    var release: @Sendable (AssertionID) -> Void

    #if os(macOS)
    /// The system's own power assertions: one that keeps the system from
    /// sleeping when the user leaves the Mac idle (the display still
    /// sleeps), taken through `IOPMAssertionCreateWithName` and let go
    /// through `IOPMAssertionRelease`.
    static let live = SpeechExportPower(
        hold: { reason in
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertPreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            return result == kIOReturnSuccess ? id : nil
        },
        release: { id in
            _ = IOPMAssertionRelease(id)
        }
    )
    #else
    /// Phase 0 stand-in: iOS has no IOKit, so no assertion is held, and
    /// `whileHeld` runs its work anyway, as it does when the Mac refuses one.
    /// The iPhone interface decides how an export keeps its device awake.
    static let live = SpeechExportPower(hold: { _ in nil }, release: { _ in })
    #endif

    /// Runs `body` while an assertion named `reason` is held, and lets the
    /// assertion go however `body` ends, returning or throwing. When the
    /// system would not take the assertion, `body` still runs: the export
    /// goes on, and the Mac may sleep when left idle.
    /// - Returns: What `body` returns.
    /// - Throws: What `body` throws.
    func whileHeld<Value>(reason: String, _ body: () throws -> Value) rethrows -> Value {
        let id = hold(reason)
        defer {
            if let id {
                release(id)
            }
        }
        return try body()
    }
}
