import AppKit
import XCTest
@testable import TextMouth

/// A VoiceOver focus request waits up to 1.2 seconds after its view joins a
/// window before it searches that window for its target. A window closed or
/// emptied meanwhile, as SwiftUI and the tests take windows down, must
/// neither crash the app nor be kept alive by the waiting request (PERF33).
///
/// Every window here is titled and never shown, and its request finds
/// nothing to focus, so no test window ever comes forward.
@MainActor
final class VoiceOverFocusClosedWindowTests: XCTestCase {

    /// A request whose window lost its content view entirely within the
    /// delay gives up when it runs, and leaves the window as it was. It
    /// used to force-unwrap the missing content view and crash the app.
    func testRequestForAWindowWithoutAContentViewDoesNothing() {
        for kind in FocusRequestKind.allCases {
            let window = makeWindow()
            defer { window.close() }
            let content = NSView()
            window.contentView = content
            content.addSubview(kind.makeTrigger(delay: 0.05))
            window.contentView = nil

            // Long enough for the request, and any attempt it could
            // schedule, to have run.
            spinMainRunLoop(for: 0.4)

            XCTAssertNil(window.contentView, "\(kind)")
            XCTAssertFalse(window.isVisible, "\(kind): a request with nothing to focus brought its window forward")
            XCTAssertFalse(window.isKeyWindow, "\(kind): a request with nothing to focus made its window key")
        }
    }

    /// A request still waiting holds its window weakly: a window closed and
    /// let go within the delay is freed at once, rather than when the
    /// request runs, which then finds no window and does nothing.
    func testWaitingRequestDoesNotKeepAClosedWindowAlive() {
        for kind in FocusRequestKind.allCases {
            weak var closedWindow: NSWindow?
            autoreleasepool {
                let window = makeWindow()
                let content = NSView()
                window.contentView = content
                content.addSubview(kind.makeTrigger(delay: 0.5))
                // Emptied rather than removed, as the app takes a window's
                // content down, then closed and let go.
                window.contentView = NSView()
                window.close()
                closedWindow = window
            }

            spinMainRunLoop(for: 0.05)
            XCTAssertNil(closedWindow, "\(kind): the waiting request kept the closed window alive")

            // The request then runs with its window gone.
            spinMainRunLoop(for: 0.6)
        }
    }

    /// What every waiting request checks before it searches: a window with
    /// no content view, or an empty one, has nothing to search.
    func testOnlyAWindowShowingContentHasContentForFocus() {
        let window = makeWindow()
        defer { window.close() }

        window.contentView = nil
        XCTAssertFalse(window.hasContentForVoiceOverFocus, "no content view")

        window.contentView = NSView()
        XCTAssertFalse(window.hasContentForVoiceOverFocus, "an empty content view")

        let content = NSView()
        content.addSubview(NSView())
        window.contentView = content
        XCTAssertTrue(window.hasContentForVoiceOverFocus, "a content view showing something")
    }

    // MARK: - Helpers

    /// A titled window that is never shown: the focus code treats an
    /// untitled one as a sheet and brings it forward, so a test window
    /// always has a title.
    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        window.title = "VoiceOver focus test"
        return window
    }
}

/// The two kinds of VoiceOver focus request: the standard one windows use,
/// and the one sheets use, which retries until VoiceOver lands.
private enum FocusRequestKind: CaseIterable {
    case standard
    case sheet

    /// A trigger view of this kind that asks for focus `delay` seconds after
    /// it joins a window.
    @MainActor
    func makeTrigger(delay: TimeInterval) -> NSView {
        switch self {
        case .standard:
            let trigger = StandardVoiceOverFocusTriggerView()
            trigger.focusDelay = delay
            return trigger
        case .sheet:
            let trigger = VoiceOverFocusTriggerView()
            trigger.focusDelay = delay
            return trigger
        }
    }
}
