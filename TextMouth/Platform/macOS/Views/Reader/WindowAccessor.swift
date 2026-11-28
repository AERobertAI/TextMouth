import AppKit
import SwiftUI

/// Invisible NSView that captures its hosting NSWindow and passes it back to SwiftUI.
/// Used so the ReaderViewModel can check whether its window is focused before responding
/// to keyboard shortcut notifications, and so a view can tell when its
/// window closes and when it comes on screen again.
struct WindowAccessor: NSViewRepresentable {
    let onWindowFound: (NSWindow) -> Void
    let onWindowBecameKey: () -> Void
    /// Called as the window closes. SwiftUI keeps a closed window and its
    /// views for the rest of the session, so a view can stop doing work
    /// nobody will see (PERF27).
    let onWindowWillClose: () -> Void
    /// Called each time the window comes on screen, as when SwiftUI shows a
    /// closed Library window again for a book opened from Finder.
    let onWindowBecameVisible: () -> Void

    init(
        onWindowFound: @escaping (NSWindow) -> Void,
        onWindowBecameKey: @escaping () -> Void = {},
        onWindowWillClose: @escaping () -> Void = {},
        onWindowBecameVisible: @escaping () -> Void = {}
    ) {
        self.onWindowFound = onWindowFound
        self.onWindowBecameKey = onWindowBecameKey
        self.onWindowWillClose = onWindowWillClose
        self.onWindowBecameVisible = onWindowBecameVisible
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAccessorView()
        pass(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowAccessorView else { return }
        pass(to: view)
    }

    /// Gives `view` this accessor's callbacks, the latest SwiftUI made.
    private func pass(to view: WindowAccessorView) {
        view.onWindowFound = onWindowFound
        view.onWindowBecameKey = onWindowBecameKey
        view.onWindowWillClose = onWindowWillClose
        view.onWindowBecameVisible = onWindowBecameVisible
    }
}

/// Helper NSView that reports attachment, every key-window transition, the
/// window closing, and the window coming on screen.
private class WindowAccessorView: NSView {
    var onWindowFound: ((NSWindow) -> Void)?
    var onWindowBecameKey: (() -> Void)?
    var onWindowWillClose: (() -> Void)?
    var onWindowBecameVisible: (() -> Void)?
    /// The observations of the host window. Replacing them, as a move to
    /// another window does, or releasing them with this view stops
    /// observing, so a closed window never retains the callbacks.
    private var windowObservations: [NotificationObservation] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservations = []
        guard let window else { return }
        onWindowFound?(window)
        if window.isKeyWindow {
            onWindowBecameKey?()
        }
        windowObservations = [
            observe(NSWindow.didBecomeKeyNotification, of: window) { $0.onWindowBecameKey?() },
            observe(NSWindow.willCloseNotification, of: window) { $0.onWindowWillClose?() },
            // Posted as the window is hidden or shown, and closed; only
            // coming on screen is reported.
            observe(NSWindow.didChangeOcclusionStateNotification, of: window) { view in
                if view.window?.occlusionState.contains(.visible) == true {
                    view.onWindowBecameVisible?()
                }
            },
        ]
    }

    /// Observes `name` posted by `window`, calling `action` with this view,
    /// while it exists, on the main queue.
    private func observe(
        _ name: Notification.Name,
        of window: NSWindow,
        _ action: @escaping @MainActor @Sendable (WindowAccessorView) -> Void
    ) -> NotificationObservation {
        NotificationObservation(NotificationCenter.default.addObserver(
            forName: name,
            object: window,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, as `queue: .main` asks.
            MainActor.assumeIsolated {
                if let self {
                    action(self)
                }
            }
        })
    }
}

/// One block-based NotificationCenter observation, ended when this object
/// is released (TODO Q06). The view that owns it is main-actor isolated, but
/// its deinit is not, so it cannot remove an observer itself; this object's
/// token never changes after `init`, and `removeObserver(_:)` is
/// thread-safe, so releasing it from any thread ends the observation.
private final class NotificationObservation {
    /// The token `addObserver(forName:object:queue:using:)` returned.
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
