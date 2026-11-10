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
/// Why one helper: another work may hold the request. When a quit is held
/// (`applicationShouldTerminate` answers `.terminateLater`), AppKit waits for
/// the reply inside the main queue's drain, and that wait runs no main-queue
/// work. A quit asked again from a main-queue block or a main-actor Task then
/// never lets the hold's own Task start, so nothing replies and TextMouth
/// stays open with its main actor stopped. A run-loop timer fires outside the
/// drain, so the request goes through one (found on November 9, 2026 by the
/// review of the transcript branch, and shown by
/// `Scripts/test/quit-while-held.py`).
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
            #selector(NSApplication.terminate(_:)),
            with: nil,
            afterDelay: 0,
            inModes: [.common]
        )
#endif
        // An iPhone app never ends itself (the system decides): nothing.
    }
}

#if os(macOS)
/// Why a request to quit came, as far as the delegate needs to tell: the
/// system ending the session (log out, restart, shut down), which waits for
/// a reply and must not be cancelled, or the person asking to quit.
enum QuitReason {
    /// The Apple event attribute that says why the system asks an
    /// application to quit ('why ', `kAEQuitReason`).
    static let reasonKeyword = fourCharCode("why ")

    /// The reasons that end the session ('logo', 'rlgo', 'rest', 'shut':
    /// `kAELogOut`, `kAEReallyLogOut`, `kAERestart`, `kAEShutDown`).
    static let sessionEndingReasons: Set<FourCharCode> = [
        fourCharCode("logo"), fourCharCode("rlgo"), fourCharCode("rest"), fourCharCode("shut"),
    ]

    /// Whether `reason`, the quit reason of an Apple event if it had one,
    /// ends the session. Pure, so the choice is tested without an event.
    static func endsTheSession(_ reason: FourCharCode?) -> Bool {
        reason.map(sessionEndingReasons.contains) ?? false
    }

    /// Whether the quit being answered now was asked by the system ending the
    /// session. Command-Q, the Quit menu item, and a call to `terminate` have
    /// no Apple event; the Dock's Quit has one without a session-ending reason.
    @MainActor
    static var currentRequestEndsTheSession: Bool {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: reasonKeyword)?.enumCodeValue
        return endsTheSession(reason)
    }

    /// The code of a four-character string such as "logo".
    static func fourCharCode(_ text: String) -> FourCharCode {
        text.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }
}
#endif
