import AppKit
import SwiftUI

/// Opens the Search Library window (LIBRARY-SEARCH-RESEARCH-2026-11-13.md,
/// section 6), one at a time, from Edit > Find > Search Library… in any
/// window, the Library's and a reader's alike (`Notification.Name.searchLibrary`).
///
/// The window is an AppKit window hosting `LibrarySearchWindowView`, as the
/// Record window is, so it is one window whatever opens it. Its identifier,
/// "library-search", tells the menu bar it is neither a Library nor a reader
/// window, so neither's menus show while it is in front
/// (`MenuVisibilityManager`), and tells the shortcut manager to leave every
/// key to the window's own controls (`KeyboardShortcutManager`), so Return
/// and Space act in its list rather than playing a book.
///
/// The model lives here, not in the window: closing the window keeps the
/// query, its options, and its results, and the next opening shows them,
/// with the search field taking the keyboard. A search the closing cut off
/// runs again when the window opens.
@MainActor
final class LibrarySearchWindowController: NSObject, NSWindowDelegate {
    /// The app's controller.
    static let shared = LibrarySearchWindowController()

    /// The identifier the Search Library window carries.
    nonisolated static let windowIdentifier = "library-search"

    /// The library searched.
    private weak var library: LibraryViewModel?
    /// The window, while it is open.
    private(set) var window: NSWindow?
    /// The searches and their results, kept while the window is closed.
    private(set) var model: LibrarySearchModel?
    /// Whether closing the window cut a search off, to run again when the
    /// window opens.
    private var searchWasCutOff = false
    /// The observer of Search Library commands, once attached.
    private var commandObserver: NSObjectProtocol?

    /// Makes `library` the one searched, and listens for Search Library
    /// commands: as each Library window appears, the first one's attaching
    /// counts.
    func attach(_ library: LibraryViewModel) {
        self.library = library
        guard commandObserver == nil else { return }
        commandObserver = NotificationCenter.default.addObserver(
            forName: .searchLibrary, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                LibrarySearchWindowController.shared.show()
            }
        }
    }

    /// Brings the Search Library window forward, opening it when it is not
    /// open. Does nothing before a library is attached, which happens as the
    /// first Library window appears.
    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let model = model ?? makeModel() else { return }
        self.model = model
        let view = LibrarySearchWindowView(model: model) { [weak self] in
            self?.window?.performClose(nil)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = LibrarySearchWording.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // TextMouth reopens no window at launch (AppDelegate), this one too.
        window.isRestorable = false
        window.setFrameAutosaveName("LibrarySearchWindow")
        if !window.setFrameUsingName("LibrarySearchWindow") {
            window.center()
        }
        window.delegate = self
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The menu bar shows this window's menus: none of Library's or a
        // reader's.
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        if searchWasCutOff {
            searchWasCutOff = false
            model.searchAgain()
        }
    }

    /// The model searching the attached library, announcing from this
    /// window; nil before a library is attached.
    private func makeModel() -> LibrarySearchModel? {
        guard let library else { return nil }
        return LibrarySearchModel(
            books: { [weak library] in
                library.map { LibrarySearchModel.searchableBooks(in: $0.library) } ?? []
            },
            announce: { [weak self] message in
                VoiceOverAnnouncer.announce(message, from: self?.window)
            }
        )
    }

    // MARK: NSWindowDelegate

    /// Lets the window go, keeping the model: a search under way stops, so
    /// nothing is announced from a window that is gone, and runs again when
    /// the window opens.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if let model, model.status.isSearching {
            model.cancelSearch()
            searchWasCutOff = true
        }
        window?.delegate = nil
        window = nil
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }
}
