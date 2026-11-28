#if os(macOS)
import AppKit
#else
import Foundation
#endif

/// The one way TextMouth asks AppKit to quit again, after it has cancelled a
/// quit to ask a question or to end work first: Quit Anyway, a Retry that
/// saves, an audio editor's Save or Discard, the Record window's take, a
/// library move's end, the end of work a quit waited for, Quit in the
/// data-directory screens, and a relaunch.
///
/// Why one helper: when a quit is held (`applicationShouldTerminate` answers
/// `.terminateLater`), AppKit waits for the reply inside the main queue's
/// drain, and that wait runs no main-queue work. A quit asked again from a
/// main-queue block or a main-actor Task then never lets the hold's own Task
/// start, so nothing replies and TextMouth stays open with its main actor
/// stopped. A run-loop timer fires outside the drain, so the request goes
/// through one (found on November 9, 2026 by the review of the transcript
/// branch, and shown by `Scripts/test/quit-while-held.py`). A quit the person
/// asks for is no longer left pending (`QuitFinisher`), but the system ending
/// the session still is, and one helper keeps every other path safe too.
@MainActor
enum QuitRequest {
    /// How a request reaches AppKit. At first the one this process's runtime
    /// calls for: AppKit in the app, nothing under hosted tests, so a test
    /// that does not replace it can never quit the test host. A test may
    /// install its own, and must put the previous one back when it ends.
    static var deliver: @MainActor () -> Void = makeDelivery(isHostedTest: TextMouthRuntime.current.isHostedTest)

    /// Requests that go out in a process hosting tests are kept here, and
    /// nothing quits.
    private(set) static var heldBackUnderTest = 0

    /// Asks AppKit to quit, from outside the main queue's drain (see above).
    /// The delegate is asked as it is for any quit; this returns at once.
    static func ask() {
        deliver()
    }

    /// The delivery for a process: `isHostedTest` keeps the request, and
    /// quits nothing; otherwise AppKit is asked.
    static func makeDelivery(isHostedTest: Bool) -> @MainActor () -> Void {
        if isHostedTest {
            return { heldBackUnderTest += 1 }
        }
        return deliverToAppKit
    }

    /// Schedules `terminate(_:)` on the main run loop in every common mode,
    /// as a timer, a moment from now: the Quit menu item's action is called
    /// outside the main queue in the same way. The common modes make it fire
    /// beside a modal panel too, such as the unsaved-changes alert's.
    private static func deliverToAppKit() {
#if os(macOS)
        NSApplication.shared.perform(
            #selector(NSApplication.terminate(_:)), // quit-ok: the one helper every quit goes through
            with: nil,
            afterDelay: 0,
            inModes: [.common]
        )
#endif
        // An iPhone app never ends itself (the system decides): nothing.
    }
}
