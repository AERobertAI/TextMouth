import AppKit
import Combine

/// Keeps weak references to open Library windows and selects exactly one to
/// handle app-wide actions. A reader or Settings window can be key when Finder
/// opens a book, so routing cannot depend solely on a key Library window.
@MainActor
final class LibraryWindowRouter: ObservableObject {
    /// Shared registry used by both SwiftUI views and the AppKit delegate.
    static let shared = LibraryWindowRouter()

    /// Weak storage avoids extending an `NSWindow`'s lifetime after SwiftUI
    /// closes its scene.
    private final class WeakWindow {
        weak var value: NSWindow?

        init(_ value: NSWindow) {
            self.value = value
        }
    }

    private var windows: [WeakWindow] = []

    /// Whether at least one Library scene has supplied its hosting window.
    var hasRegisteredWindow: Bool {
        pruneClosedWindows()
        return windows.contains { $0.value != nil }
    }

    /// Registers a Library window once its hosting AppKit window is available.
    func register(_ window: NSWindow) {
        pruneClosedWindows()
        guard !windows.contains(where: { $0.value === window }) else { return }
        windows.append(WeakWindow(window))
    }

    /// Removes a Library window when its SwiftUI scene disappears.
    func unregister(_ window: NSWindow) {
        windows.removeAll { $0.value == nil || $0.value === window }
    }

    /// Returns true for the single Library window that should handle a global
    /// notification. Prefer a key Library; otherwise use the first registered
    /// Library while a reader or another app window is key.
    func shouldHandleGlobalAction(in window: NSWindow?) -> Bool {
        pruneClosedWindows()
        let liveWindows = windows.compactMap(\.value)

        // During initial scene construction, the WindowAccessor might not have
        // supplied an NSWindow yet. Only allow that unregistered scene to act
        // when no established Library window could handle the notification.
        guard let window else { return liveWindows.isEmpty }
        return Self.selectedWindow(
            from: liveWindows,
            keyWindow: NSApp.keyWindow
        ) === window
    }

    /// Pure selection core used by production routing and deterministic tests.
    /// A key window only wins when it is itself one of the Library candidates.
    static func selectedWindow(
        from libraryWindows: [NSWindow],
        keyWindow: NSWindow?
    ) -> NSWindow? {
        if let keyWindow,
           libraryWindows.contains(where: { $0 === keyWindow }) {
            return keyWindow
        }
        return libraryWindows.first
    }

    /// Drops windows that SwiftUI has already released.
    private func pruneClosedWindows() {
        windows.removeAll { $0.value == nil }
    }
}
