import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

// MARK: - Hosted views

/// The attributes VoiceOver reads from one native control in a hosted
/// view. SwiftUI stores `accessibilityValue` text in AXValueDescription,
/// which VoiceOver speaks instead of a slider's or stepper's raw number.
struct AccessibleControl {
    let element: NSAccessibilityProtocol
    let role: NSAccessibility.Role
    let label: String
    let valueDescription: String
    let hint: String
}

extension XCTestCase {
    /// Host `view` in an offscreen window that is never shown, lay it out
    /// until `isReady` accepts the hosting view, and pass the hosting view to
    /// `body` while the window is still alive.
    ///
    /// SwiftUI creates platform views during layout; polling for a ready
    /// state means a slow first render cannot let a test pass vacuously.
    @MainActor
    func withHostedView<Content: View>(
        _ view: Content,
        size: NSSize = NSSize(width: 450, height: 600),
        until isReady: (NSView) -> Bool,
        _ body: (NSView) throws -> Void
    ) rethrows {
        let hostingView = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Tests own this window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        // The app's VoiceOver focus requests take an untitled window for a
        // sheet, and bring a sheet forward and make it key before moving
        // VoiceOver. A title keeps a hosted view that requests focus (and
        // finds its target, as it does while VoiceOver runs) from putting
        // this window on screen: a titled window that is not key is left
        // alone.
        window.title = "Hosted test view"
        window.contentView = hostingView
        defer { window.close() }

        _ = waitUntil(timeout: 5) {
            hostingView.layoutSubtreeIfNeeded()
            return isReady(hostingView)
        }
        try body(hostingView)
    }

    /// Host `view` offscreen, wait for SwiftUI to create its AppKit
    /// controls, and pass their accessibility attributes to `body` while the
    /// window is still alive.
    ///
    /// Only controls AppKit exposes itself appear here: sliders, steppers,
    /// pop-up buttons, and a list's outline. SwiftUI builds the accessibility
    /// elements for its own text, toggles, and buttons lazily, only for a
    /// connected assistive app, so those are verified through the functions
    /// that produce their labels.
    @MainActor
    func withHostedControls<Content: View>(
        _ view: Content,
        _ body: ([AccessibleControl]) throws -> Void
    ) rethrows {
        try withHostedView(view, until: { !accessibleControls(in: $0).isEmpty }) { hostingView in
            try body(accessibleControls(in: hostingView))
        }
    }

    /// Spin the main run loop until `condition` holds or `timeout` passes,
    /// letting SwiftUI apply asynchronous view updates. Returns the outcome.
    @MainActor
    func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// Depth-first collection of every accessibility element below `root`
    /// that is not a plain group, i.e. the controls VoiceOver can land on.
    @MainActor
    func accessibleControls(in root: Any) -> [AccessibleControl] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        var controls: [AccessibleControl] = []
        if let role = node.accessibilityRole(), role != .group {
            controls.append(AccessibleControl(
                element: node,
                role: role,
                label: node.accessibilityLabel() ?? "",
                valueDescription: node.accessibilityValueDescription() ?? "",
                hint: node.accessibilityHelp() ?? ""
            ))
        }
        for child in node.accessibilityChildren() ?? [] {
            controls += accessibleControls(in: child)
        }
        return controls
    }
}

// MARK: - Announcements

/// One VoiceOver announcement captured during a test, with the window its
/// caller asked to post from (nil when the caller named none).
struct RecordedAnnouncement {
    let announcement: VoiceOverAnnouncement
    let window: NSWindow?
}

/// Collects what `VoiceOverAnnouncer` is asked to announce while a test
/// records, so nothing reaches VoiceOver on the machine running the tests.
@MainActor
final class AnnouncementRecorder {
    /// Every announcement so far, oldest first.
    private(set) var recorded: [RecordedAnnouncement] = []

    /// The announcements alone, for comparing messages and priorities.
    var announcements: [VoiceOverAnnouncement] {
        recorded.map(\.announcement)
    }

    fileprivate func record(_ announcement: VoiceOverAnnouncement, window: NSWindow?) {
        recorded.append(RecordedAnnouncement(announcement: announcement, window: window))
    }
}

extension XCTestCase {
    /// Run `body` with VoiceOver announcements recorded instead of posted,
    /// then put the previous poster back, even when `body` throws.
    /// - Returns: The recorder holding everything `body` announced.
    @MainActor
    @discardableResult
    func recordingAnnouncements(_ body: () throws -> Void) rethrows -> AnnouncementRecorder {
        let recorder = AnnouncementRecorder()
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, window in
            recorder.record(announcement, window: window)
        }
        defer { VoiceOverAnnouncer.poster = previousPoster }
        try body()
        return recorder
    }
}
