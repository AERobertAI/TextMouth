import SwiftUI

/// What a reader window does for the commands that act on its book as a
/// whole (FR05): File > Export… exports the book of the reader that takes
/// the command, and, when Playback settings say so, an Export button in the
/// toolbar does the same. The Export dialog opens as a sheet on the reader.
/// The Book menu's Edit Text in Default Editor and Edit Text With… open the
/// book's text in the user's own editor (`BookTextEditor`), and are
/// available only while the reader's book has text to edit. Its Transcribe
/// Audio… opens the Transcribe Audio sheet on the reader for an audiobook,
/// Clean Up Transcript (Experimental)… opens the Clean Up sheet for a
/// transcribed one, and Delete Transcript… asks to delete a transcribed
/// audiobook's transcript.
///
/// ReaderView attaches this in one line: its body sits at the type
/// checker's limit (board #829), so everything here lives in views of its
/// own. The reader itself is not observed, so a playing reader's frequent
/// publishes never draw this again; only the settings it shows, and which
/// books are transcribed, are.
struct ReaderBookCommandsSupport: ViewModifier {
    /// The reader whose book the commands act on.
    let viewModel: ReaderViewModel
    /// The settings, observed for the toolbar's Export button.
    @ObservedObject private var settings: SettingsViewModel
    /// The Export dialog showing, or nil.
    @State private var exportModel: BookExportModel?
    /// The reader's transcription dialogs (FR05).
    @StateObject private var transcription = TranscriptionPresenter()
    /// Which audiobooks are transcribed (FR05), observed so Edit Text and
    /// Delete Transcript… follow the reader's book.
    @ObservedObject private var transcribedBooks = TranscribedBooks.shared

    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settingsViewModel)
    }

    func body(content: Content) -> some View {
        content
            .toolbar {
                if settings.showExportInReaderToolbar {
                    ToolbarItem {
                        ReaderExportToolbarButton(action: openExport)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .exportBooks)) { notification in
                guard takesCommand(notification) else { return }
                openExport()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editBookText)) { notification in
                guard takesCommand(notification) else { return }
                editText(choosingApp: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .editBookTextWith)) { notification in
                guard takesCommand(notification) else { return }
                editText(choosingApp: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .transcribeBookAudio)) { notification in
                guard takesCommand(notification) else { return }
                transcribe()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cleanUpBookTranscript)) { notification in
                guard takesCommand(notification) else { return }
                cleanUpTranscript()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteBookTranscript)) { notification in
                guard takesCommand(notification) else { return }
                deleteTranscript()
            }
            // Scene values, published whenever this reader's window is key,
            // even while none of its views has keyboard focus, as when
            // VoiceOver reads its text: a focused value would leave the Book
            // menu's commands unavailable then.
            .focusedSceneValue(
                \.canEditBookText,
                BookTextEditor.canEditText(of: viewModel.book, isTranscribed: transcribedBooks.contains(viewModel.book.id))
            )
            .focusedSceneValue(\.canTranscribeBookAudio, LibraryTranscriptionCommand.isTranscribable(viewModel.book))
            .focusedSceneValue(\.canCleanUpBookTranscript, hasTranscript)
            .focusedSceneValue(\.canDeleteBookTranscript, hasTranscript)
            .sheet(item: $exportModel) { model in
                BookExportSheet(model: model, close: { exportModel = nil })
            }
            .modifier(TranscriptionPresentation(presenter: transcription))
    }

    /// Whether the reader's book is a transcribed audiobook, whose
    /// transcript Clean Up Transcript (Experimental)… and Delete Transcript…
    /// act on.
    private var hasTranscript: Bool {
        LibraryTranscriptionCommand.isTranscribable(viewModel.book) && transcribedBooks.contains(viewModel.book.id)
    }

    /// Opens the Transcribe Audio sheet for the reader's audiobook, as the
    /// library holds the book now (FR05).
    private func transcribe() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        transcription.transcribe([book], library: library, window: viewModel.hostWindow)
    }

    /// Opens the Clean Up sheet for the reader's audiobook's transcript, as
    /// the library holds the book now (FR05, experimental).
    private func cleanUpTranscript() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        transcription.cleanUp(book, library: library, window: viewModel.hostWindow)
    }

    /// Asks to delete the transcript of the reader's audiobook, as the
    /// library holds the book now (FR05).
    private func deleteTranscript() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        let window = viewModel.hostWindow
        Task {
            await transcription.confirmDeletion(of: book, library: library, window: window)
        }
    }

    /// Opens the reader's book's text in the user's own editor, or in an
    /// app they choose, as the library holds the book now.
    private func editText(choosingApp: Bool) {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        let window = viewModel.hostWindow
        Task {
            await BookTextEditor.shared.edit(book, choosingApp: choosingApp, in: library, from: window)
        }
    }

    /// Opens the Export dialog for the reader's book, as the library holds
    /// it now, unless it is open already.
    private func openExport() {
        guard exportModel == nil else { return }
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        exportModel = BookExportModel(books: [book], library: library)
    }

    /// Whether this reader takes the menu command `notification` carries:
    /// the reader whose window, or a sheet over it, is key, as for every
    /// reader command (`WindowCommandRouting`).
    private func takesCommand(_ notification: Notification) -> Bool {
        WindowCommandRouting.shouldAccept(
            sourceWindow: notification.userInfo?["sourceWindow"] as? NSWindow,
            hostWindow: viewModel.hostWindow,
            keyWindow: NSApp.keyWindow
        )
    }
}

/// The reader toolbar's Export button, shown while Playback settings' "Show
/// Export in the reader toolbar" is on: a labelled button with a hint.
struct ReaderExportToolbarButton: View {
    /// Opens the Export dialog.
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(BookExportWording.toolbarTitle, systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel(BookExportWording.toolbarLabel)
        .accessibilityHint(BookExportWording.toolbarHint)
    }
}
