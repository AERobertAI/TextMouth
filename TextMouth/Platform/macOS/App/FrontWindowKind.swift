import AppKit
import SwiftUI

// MARK: - The Window in Front (FR12's Branch E)

/// The kind of window in front, which the menus act on: the main window's,
/// or the key window's while no window is main, as the menu bar's own
/// menus go by (`MenuVisibilityManager`); nil with no window at all. A menu
/// command working in one kind of window shows its key and acts only while
/// a window of that kind is in front (`menuCommandKey(_:shortcuts:frontKind:)`).
@MainActor
final class FrontWindowKind: ObservableObject {
    /// The app's one.
    static let shared = FrontWindowKind()

    /// The kind of window in front, or nil with none.
    @Published private(set) var kind: ShortcutWindowKind?

    /// The notification observers, kept for the app's life.
    private var observers: [NSObjectProtocol] = []

    /// Follows the window in front from now on.
    private init() {
        kind = Self.kind(of: NSApp.mainWindow ?? NSApp.keyWindow)
        let center = NotificationCenter.default
        // A window that becomes main or key is in front at once; one that
        // resigns, or the app going away or coming back, leaves the next
        // window to settle first, as the menu bar's own update does.
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [
            NSWindow.didResignMainNotification, NSWindow.didResignKeyNotification,
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refresh() }
                }
            })
        }
    }

    /// Takes the kind of the window now in front, published when it changed.
    private func refresh() {
        let current = Self.kind(of: NSApp.mainWindow ?? NSApp.keyWindow)
        if current != kind {
            kind = current
        }
    }

    /// The kind of `window`, as the shortcut manager tells kinds of window
    /// apart, or nil for no window.
    ///
    /// The Search Library window is `.other`, as Settings is, though the
    /// manager matches no shortcut in it (`windowKind(ofKeyWindow:)` gives
    /// nil there, as it does for a sheet over an audio editor): a menu
    /// command working in one kind of window must not show its key or act
    /// there, while nil would read as no window in front, which admits every
    /// command.
    static func kind(of window: NSWindow?) -> ShortcutWindowKind? {
        guard let window else { return nil }
        if KeyboardShortcutManager.isLibrarySearchWindow(window) {
            return .other
        }
        return KeyboardShortcutManager.windowKind(ofKeyWindow: window)
    }
}
