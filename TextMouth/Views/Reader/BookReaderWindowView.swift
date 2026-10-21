import SwiftUI

/// Root view for a book reader window. Creates and manages a ReaderViewModel for the book.
struct BookReaderWindowView: View {
    /// The identifier of the reader window scene. Each of its windows
    /// shows one book and is opened with that book's ID.
    nonisolated static let windowID = "book-reader"

    let bookID: UUID
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var soundEffectService: SoundEffectService
    @StateObject private var viewModel: ReaderViewModel
    /// Opens reader windows. Lent to the router, which has no openWindow of
    /// its own, to open a book's reader while no Library window is open.
    @Environment(\.openWindow) private var openWindow

    init(bookID: UUID, libraryViewModel: LibraryViewModel, settingsViewModel: SettingsViewModel) {
        self.bookID = bookID
        // Create the ReaderViewModel as a StateObject
        let book = libraryViewModel.bookByID(bookID) ?? Book(
            title: "Unknown",
            format: .txt,
            filePath: "",
            md5Hash: ""
        )
        _viewModel = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            libraryViewModel: libraryViewModel,
            settingsViewModel: settingsViewModel
        ))
    }

    var body: some View {
        // Read while the view is installed, as SwiftUI requires, and kept
        // by the router for opening a book's reader from here.
        let openReaderWindow = openWindow
        ReaderView(viewModel: viewModel)
            .background(WindowAccessor(
                onWindowFound: { window in
                    viewModel.hostWindow = window
                    // With no Library window open, the router opens a book's
                    // reader through a reader window like this one (TODO A05).
                    LibraryWindowRouter.shared.registerReaderWindow(window) { bookID in
                        openReaderWindow(id: Self.windowID, value: bookID)
                    }
                    NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
                },
                onWindowBecameKey: {
                    // Focuses the reader's media session, and has the menus
                    // ask afresh whether it can release the media controls.
                    viewModel.windowBecameKey()
                }
            ))
            .focusedValue(\.activeWindowType, .reader)
            .focusedValue(\.canReleaseMediaControls, viewModel.canReleaseMediaControls)
            // Next in Reading List and Previous in Reading List are
            // available while this reader reads its book from the list
            // (FR09), whether or not a view of it holds keyboard focus.
            .focusedSceneValue(\.readsFromReadingList, viewModel.isOpenedFromReadingList)
            // Next Page, Previous Page, and Go to Page… are available while
            // this reader's book has pages (PG02), as above.
            .focusedSceneValue(\.readerHasPages, viewModel.hasPages)
            .navigationTitle(windowTitle)
            .onAppear {
                libraryViewModel.markBookOpened(bookID)
                NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
            }
            .onDisappear {
                if let window = viewModel.hostWindow {
                    LibraryWindowRouter.shared.unregisterReaderWindow(window)
                }
                viewModel.close()
            }
            .frame(minWidth: 600, minHeight: 400)
    }

    /// The window's title, which follows the reader: it changes as the book
    /// is renamed, and as it starts or stops being read from the reading
    /// list (FR09).
    private var windowTitle: String {
        Self.windowTitle(for: viewModel.book, readFromReadingList: viewModel.isOpenedFromReadingList)
    }

    /// What a reader window's title begins with for a book read from
    /// anywhere but the reading list.
    nonisolated static let windowTitlePrefix = "Book"

    /// The title of the reader window of `book`: "Book: <title> by
    /// <author>", or "Book: <title>" when the author is unknown. A book read
    /// from the reading list (FR09) begins "Reading List" in place of
    /// "Book", so the window says it wherever VoiceOver or an eye meets it,
    /// as the user asked on October 7, 2026: "the window title should be
    /// slightly different to indicate it in some way".
    nonisolated static func windowTitle(for book: Book, readFromReadingList: Bool) -> String {
        let prefix = readFromReadingList ? ReadingListReaderWording.windowTitlePrefix : windowTitlePrefix
        if Book.isUnknownAuthor(book.author) {
            return "\(prefix): \(book.title)"
        }
        return "\(prefix): \(book.title) by \(book.author)"
    }
}

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
