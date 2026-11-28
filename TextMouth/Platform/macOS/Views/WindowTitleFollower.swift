import AppKit

/// Sets a window's title again whenever the interface language changes (FR39), for the windows whose title the code sets
/// once (the Record, Search Library, and audio editor windows, and the quit notice's panel): a SwiftUI window's own
/// title follows through its view's body, and these have none.
///
/// A follower lives from `follow` until its window closes: its two observers hold it, and the close removes them. A
/// window or alert already open keeps whatever else it shows until it closes; only the title follows.
@MainActor
final class WindowTitleFollower {
    /// The window, held weakly: a follower never keeps a window open.
    private weak var window: NSWindow?
    /// The title in the language now in use, or nil when there is none to set (the thing the title names is gone).
    private let title: @MainActor () -> String?
    /// The observers of a language change and of the window's closing.
    private var observers: [NSObjectProtocol] = []

    private init(window: NSWindow, title: @escaping @MainActor () -> String?) {
        self.window = window
        self.title = title
    }

    /// Starts keeping `window`'s title at what `title` gives, read again after each switch of language.
    ///
    /// - Parameters:
    ///   - window: The window to retitle.
    ///   - title: The title in the language in use now; nil leaves the window's title as it is.
    static func follow(_ window: NSWindow, title: @escaping @MainActor () -> String?) {
        let follower = WindowTitleFollower(window: window, title: title)
        let center = NotificationCenter.default
        follower.observers.append(center.addObserver(forName: InterfaceLanguage.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { follower.refresh() }
        })
        follower.observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { follower.stop() }
        })
    }

    /// Sets the title now.
    func refresh() {
        guard let window, let text = title() else { return }
        window.title = text
    }

    /// Stops following: removes the observers, which lets this follower go.
    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
}
