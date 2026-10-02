import AppKit
import Combine

/// Keeps weak references to open Library windows and selects exactly one to
/// handle app-wide actions. A reader or Settings window can be key when Finder
/// opens a book, so routing cannot depend solely on a key Library window.
///
/// It also keeps each open reader window's way of opening another reader,
/// which the app delegate uses to open the next book's reader for Continue
/// to Next Book when no Library window is open to do it.
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

    // MARK: - Continue to Next Book

    /// Who opens the next book's reader window when a finished book
    /// continues to it.
    enum ContinueToNextBookOpener {
        /// The one Library window `selectedWindow(from:keyWindow:)` picks.
        case libraryWindow(NSWindow)
        /// The app delegate's fallback, because no Library window is open.
        case appFallback

        /// Whether `window` is the Library window chosen to open it.
        func isLibraryWindow(_ window: NSWindow) -> Bool {
            if case .libraryWindow(let chosen) = self {
                return chosen === window
            }
            return false
        }
    }

    /// Pure choice of who opens the next book's reader: the Library window
    /// that handles other app-wide actions or, only when there is no Library
    /// window at all, the app delegate's fallback. Exactly one opener is
    /// chosen, so the reader window is never opened twice, and never left
    /// unopened for want of a Library window.
    static func continueToNextBookOpener(
        libraryWindows: [NSWindow],
        keyWindow: NSWindow?
    ) -> ContinueToNextBookOpener {
        guard let chosen = selectedWindow(from: libraryWindows, keyWindow: keyWindow) else {
            return .appFallback
        }
        return .libraryWindow(chosen)
    }

    /// Who opens the next book's reader now, given the registered Library
    /// windows and the current key window.
    func continueToNextBookOpener(keyWindow: NSWindow?) -> ContinueToNextBookOpener {
        pruneClosedWindows()
        return Self.continueToNextBookOpener(
            libraryWindows: windows.compactMap(\.value),
            keyWindow: keyWindow
        )
    }

    /// Whether the Library window `window` opens the next book's reader.
    ///
    /// Unlike other app-wide actions, a Library scene that has not supplied
    /// its window yet never does: while no Library window is registered, the
    /// app delegate's fallback opens the reader instead, and the two must
    /// never both open it.
    func shouldOpenContinuedBook(in window: NSWindow?, keyWindow: NSWindow?) -> Bool {
        guard let window else { return false }
        return continueToNextBookOpener(keyWindow: keyWindow).isLibraryWindow(window)
    }

    // MARK: - Reader Windows

    /// An open reader window, and the action that opens a reader window
    /// from it.
    private final class ReaderWindowOpener {
        weak var window: NSWindow?
        let openReader: (UUID) -> Void

        init(window: NSWindow, openReader: @escaping (UUID) -> Void) {
            self.window = window
            self.openReader = openReader
        }
    }

    /// The open reader windows, in the order they registered.
    private var readerWindowOpeners: [ReaderWindowOpener] = []

    /// Registers a reader window with the action that opens a reader window
    /// from it, replacing any action the window registered before.
    ///
    /// SwiftUI gives `openWindow` only to views; the app and its delegate
    /// have none of their own. The app delegate's Continue to Next Book
    /// fallback therefore opens readers through one of these.
    func registerReaderWindow(_ window: NSWindow, openReader: @escaping (UUID) -> Void) {
        unregisterReaderWindow(window)
        readerWindowOpeners.append(ReaderWindowOpener(window: window, openReader: openReader))
    }

    /// Removes a reader window when its SwiftUI scene disappears.
    func unregisterReaderWindow(_ window: NSWindow) {
        readerWindowOpeners.removeAll { $0.window == nil || $0.window === window }
    }

    /// Opens the reader window for `bookID`, or brings it forward when it is
    /// already open, through an open reader window: the key window when it
    /// is one, otherwise the one registered most recently.
    ///
    /// - Returns: False when no reader window is open to open it through.
    @discardableResult
    func openReaderWindow(for bookID: UUID, keyWindow: NSWindow?) -> Bool {
        readerWindowOpeners.removeAll { $0.window == nil }
        let keyReader = readerWindowOpeners.first { $0.window === keyWindow }
        guard let opener = keyReader ?? readerWindowOpeners.last else { return false }
        opener.openReader(bookID)
        return true
    }
}
