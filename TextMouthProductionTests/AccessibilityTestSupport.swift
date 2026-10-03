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
    ///
    /// Where this session exposes no accessibility elements for a hosted
    /// window's AppKit controls at all, as on a CI runner, the test is
    /// skipped before `view` is hosted (see `HostedWindowAccessibility`).
    @MainActor
    func withHostedControls<Content: View>(
        _ view: Content,
        _ body: ([AccessibleControl]) throws -> Void
    ) throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        try withHostedView(view, until: { !accessibleControls(in: $0).isEmpty }) { hostingView in
            try body(accessibleControls(in: hostingView))
        }
    }

    /// Every view of type `T` inside `view`, depth first in subview order:
    /// the AppKit controls, and other platform views, SwiftUI drew.
    @MainActor
    func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
        var found: [T] = []
        for subview in view.subviews {
            if let match = subview as? T {
                found.append(match)
            }
            found += descendants(of: subview, as: type)
        }
        return found
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

    /// Every accessibility element below `root` whose label is `label`,
    /// groups included.
    @MainActor
    func accessibilityElements(labelled label: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityLabel() == label ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap {
            accessibilityElements(labelled: label, in: $0)
        }
    }

    /// Offer `key` to the window hosting `hostingView` as a key equivalent,
    /// as AppKit does with a key pressed in a window, so that the button
    /// with that keyboard shortcut can take it. Returns whether anything
    /// did; some macOS releases hand an offscreen window none.
    @MainActor
    func pressKeyEquivalent(_ key: KeyEquivalent, in hostingView: NSView) -> Bool {
        guard let window = hostingView.window, let event = keyDown(key, in: window) else { return false }
        return window.performKeyEquivalent(with: event)
    }

    /// A key-down event for `key` in `window`, as the keyboard sends it; nil
    /// for a key the tests never press.
    @MainActor
    func keyDown(_ key: KeyEquivalent, in window: NSWindow) -> NSEvent? {
        // Virtual key codes of the keys the tests press.
        let keyCodes: [Character: UInt16] = [
            KeyEquivalent.return.character: 36,
            KeyEquivalent.escape.character: 53,
            KeyEquivalent.space.character: 49,
            KeyEquivalent.upArrow.character: 126,
            KeyEquivalent.downArrow.character: 125,
        ]
        guard let keyCode = keyCodes[key.character] else { return nil }
        let characters = String(key.character)
        // The keyboard flags arrow keys as function keys on the numeric pad.
        let isArrow = key == .upArrow || key == .downArrow
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: isArrow ? [.function, .numericPad] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )
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

// MARK: - Hosted-window accessibility

/// Whether this session exposes the AppKit controls SwiftUI draws in a
/// hosted window to accessibility, as every check that reads those controls
/// the way VoiceOver does needs it to.
///
/// The development Mac does: a hosting view's accessibility children hold
/// its sliders, steppers, pop-up buttons, and text fields. A GitHub Actions
/// macOS runner draws the same AppKit controls, and the checks that find
/// them as views pass there, but exposes none of them to accessibility, so
/// the checks that read them would fail for want of the capability rather
/// than for a missing control; there they are skipped instead, all with one
/// message. The answer is measured once per run on a probe of its own, never
/// on the view under test, so wherever the capability exists a control
/// missing from the view under test, or left without its label, still fails
/// its test.
@MainActor
enum HostedWindowAccessibility {
    /// The one message every test skipped for want of the capability gives.
    nonisolated static let unavailableMessage =
        "This session exposes no accessibility elements for the AppKit controls in a hosted window"

    /// This run's answer: nil until first asked, then the measured one,
    /// unless `assuming(_:_:)` has put another in its place for a while.
    fileprivate static var verdict: Bool?

    /// Run `body` as though this session's answer were `exposed`, then put
    /// back the answer it had, measured or not yet, even when `body` throws:
    /// for the tests of the skip itself, which must see both answers on
    /// every Mac.
    static func assuming(_ exposed: Bool, _ body: () throws -> Void) rethrows {
        let saved = verdict
        verdict = exposed
        defer { verdict = saved }
        try body()
    }
}

/// One stepper in a form, drawn as the settings panes draw theirs, which
/// AppKit draws as an `NSStepper`: labelled `label`, or, given nil,
/// deliberately left without a label.
struct LoneStepper: View {
    /// The stepper's accessibility label; nil leaves it without one.
    let label: String?

    var body: some View {
        Form {
            // A stepper's title does not become the AppKit stepper's
            // accessibility label, which stays empty, so the settings panes
            // give each stepper an accessibility label of its own; forgetting
            // that label is how a stepper comes to have none.
            let stepper = Stepper(value: .constant(1), in: 0...2) { EmptyView() }
            if let label {
                stepper.accessibilityLabel(label)
            } else {
                stepper
            }
        }
    }
}

extension XCTestCase {
    /// Whether this session exposes the AppKit controls in a hosted window
    /// to accessibility (see `HostedWindowAccessibility`). The first call
    /// measures it: it hosts a labelled `LoneStepper` and waits, as
    /// `withHostedView` waits out a slow first render, for the stepper to
    /// appear among the window's accessibility elements. Later calls return
    /// that answer.
    @MainActor
    func hostedWindowsExposeAccessibility() -> Bool {
        if let verdict = HostedWindowAccessibility.verdict {
            return verdict
        }
        var exposed = false
        withHostedView(LoneStepper(label: "Accessibility probe"), until: { exposesAStepper($0) }) { hostingView in
            exposed = exposesAStepper(hostingView)
            if !exposed {
                // Say once, in the run's log, what the probe found: a stepper
                // drawn but not exposed is the missing capability, while no
                // stepper drawn at all would point at the probe instead.
                let drawn = descendants(of: hostingView, as: NSStepper.self).count
                print(
                    "HOSTED_ACCESSIBILITY_UNAVAILABLE: a hosted window drew \(drawn) AppKit stepper(s) "
                        + "and exposed none to accessibility; tests that read hosted controls are skipped"
                )
            }
        }
        HostedWindowAccessibility.verdict = exposed
        return exposed
    }

    /// Skip the running test, with the one message naming the capability,
    /// unless this session exposes the AppKit controls in a hosted window to
    /// accessibility. Every test that reads hosted controls through
    /// `accessibleControls(in:)` calls this first, through
    /// `withHostedControls` or on its own.
    @MainActor
    func skipUnlessHostedWindowsExposeAccessibility() throws {
        guard hostedWindowsExposeAccessibility() else {
            throw XCTSkip(HostedWindowAccessibility.unavailableMessage)
        }
    }

    /// Whether the accessibility elements below `hostingView` include a
    /// stepper, as they include the probe's wherever the capability exists.
    @MainActor
    private func exposesAStepper(_ hostingView: NSView) -> Bool {
        accessibleControls(in: hostingView).contains { $0.role == .incrementor }
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
