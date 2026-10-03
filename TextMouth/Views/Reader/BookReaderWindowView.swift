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
                    viewModel.nowPlayingService.focus()
                }
            ))
            .focusedValue(\.activeWindowType, .reader)
            .focusedValue(\.canReleaseMediaControls, viewModel.canReleaseMediaControls)
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

    private var windowTitle: String {
        let book = viewModel.book
        if book.author.isEmpty || book.author == "Unknown" {
            return "Book: \(book.title)"
        }
        return "Book: \(book.title) by \(book.author)"
    }
}

/// Invisible NSView that captures its hosting NSWindow and passes it back to SwiftUI.
/// Used so the ReaderViewModel can check whether its window is focused before responding
/// to keyboard shortcut notifications.
struct WindowAccessor: NSViewRepresentable {
    let onWindowFound: (NSWindow) -> Void
    let onWindowBecameKey: () -> Void

    init(
        onWindowFound: @escaping (NSWindow) -> Void,
        onWindowBecameKey: @escaping () -> Void = {}
    ) {
        self.onWindowFound = onWindowFound
        self.onWindowBecameKey = onWindowBecameKey
    }

    func makeNSView(context: Context) -> NSView {
        let view = WindowAccessorView()
        view.onWindowFound = onWindowFound
        view.onWindowBecameKey = onWindowBecameKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? WindowAccessorView else { return }
        view.onWindowFound = onWindowFound
        view.onWindowBecameKey = onWindowBecameKey
    }
}

/// Helper NSView that reports attachment and every key-window transition.
private class WindowAccessorView: NSView {
    var onWindowFound: ((NSWindow) -> Void)?
    var onWindowBecameKey: (() -> Void)?
    /// The observation of the host window becoming key. Replacing it, as a
    /// move to another window does, or releasing it with this view stops
    /// observing, so a closed window never retains the callbacks.
    private var keyWindowObservation: NotificationObservation?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWindowObservation = nil
        if let window = window {
            onWindowFound?(window)
            if window.isKeyWindow {
                onWindowBecameKey?()
            }
            keyWindowObservation = NotificationObservation(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                // Delivered on the main queue, as `queue: .main` asks.
                MainActor.assumeIsolated { self?.onWindowBecameKey?() }
            })
        }
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
