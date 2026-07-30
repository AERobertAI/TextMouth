import SwiftUI

/// Root view for a book reader window. Creates and manages a ReaderViewModel for the book.
struct BookReaderWindowView: View {
    let bookID: UUID
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @EnvironmentObject var soundEffectService: SoundEffectService
    @StateObject private var viewModel: ReaderViewModel

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
        ReaderView(viewModel: viewModel)
            .background(WindowAccessor(
                onWindowFound: { window in
                    viewModel.hostWindow = window
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
    private var keyWindowObserver: NSObjectProtocol?

    deinit {
        removeKeyWindowObserver()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyWindowObserver()
        if let window = window {
            onWindowFound?(window)
            if window.isKeyWindow {
                onWindowBecameKey?()
            }
            keyWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.onWindowBecameKey?()
            }
        }
    }

    /// Stops observing the previous host when SwiftUI moves or destroys the
    /// representable, preventing a closed window from retaining callbacks.
    private func removeKeyWindowObserver() {
        if let keyWindowObserver {
            NotificationCenter.default.removeObserver(keyWindowObserver)
            self.keyWindowObserver = nil
        }
    }
}
