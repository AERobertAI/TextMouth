import SwiftUI

/// What a reader window does for the commands that act on its book as a
/// whole (FR05): File > Export… exports the book of the reader that takes
/// the command, and, when Playback settings say so, an Export button in the
/// toolbar does the same. The Export dialog opens as a sheet on the reader.
/// The Book menu's Edit Text in Default Editor and Edit Text With… open the
/// book's text in the user's own editor (`BookTextEditor`), and are
/// available only while the reader's book has text to edit. Its Transcribe
/// Audio… opens the Transcribe Audio sheet on the reader for an audiobook,
/// Attach Transcript… asks for a WebVTT or SubRip file to make an
/// audiobook's transcript instead (FMT23), Clean Up Transcript
/// (Experimental)… opens the Clean Up sheet for a transcribed one, and
/// Delete Transcript… asks to delete a transcribed audiobook's
/// transcript. Its Edit Audio… opens an audiobook in the audio
/// editor (FR04), which first asks this reader to close, since editing
/// changes the audio it plays. Its Move to Library… opens Move to Library…'s
/// sheet for an episode or article in its feed (FR11, branch D), and the
/// reader follows its book's package as it moves into the library.
///
/// ReaderView attaches this in one line, as it attaches each of its parts,
/// so that its body stays well clear of the type checker's limit (board
/// #829); for the same reason, the commands this takes and the scene values
/// it publishes are steps of their own (`takingCommands(_:)`,
/// `publishingSceneValues(_:)`). The reader itself is not observed, so a
/// playing reader's frequent publishes never draw this again; only the
/// settings it shows, which books are transcribed, and which a transcript
/// is being attached to, are.
struct ReaderBookCommandsSupport: ViewModifier {
    /// The reader whose book the commands act on.
    let viewModel: ReaderViewModel
    /// The settings, observed for the toolbar's Export button.
    @ObservedObject private var settings: SettingsViewModel
    /// The Export dialog showing, or nil: one of the reader's panels
    /// (`ReaderPanels.export`), so that the report of a speech refusal waits
    /// while it shows.
    @Binding var exportModel: BookExportModel?
    /// Move to Library…'s sheet showing, or nil (FR11, branch D): one of the
    /// reader's panels too (`ReaderPanels.moveToLibrary`).
    @Binding var moveToLibrary: MoveToLibraryRequest?
    /// The reader's transcription dialogs (FR05), which the reader view
    /// keeps, so that the report of a speech refusal waits while one shows.
    @ObservedObject var transcription: TranscriptionPresenter
    /// Which audiobooks are transcribed (FR05), observed so Edit Text and
    /// Delete Transcript… follow the reader's book.
    @ObservedObject private var transcribedBooks = TranscribedBooks.shared
    /// Which audiobooks play a folder of tracks, whose manifest can be
    /// edited (FR17).
    @ObservedObject private var trackFolderBooks = TrackFolderBooks.shared
    /// Which audiobooks a transcript is being attached to (FMT23), observed
    /// so Attach Transcript… is dimmed for the reader's book while one is.
    @ObservedObject private var attachments = TranscriptAttachments.shared

    /// The commands of `viewModel`'s book, opening the Export dialog through
    /// `exportModel`, Move to Library…'s sheet through `moveToLibrary`
    /// (FR11, branch D), and the transcription dialogs through
    /// `transcription`.
    init(
        viewModel: ReaderViewModel,
        exportModel: Binding<BookExportModel?>,
        moveToLibrary: Binding<MoveToLibraryRequest?> = .constant(nil),
        transcription: TranscriptionPresenter
    ) {
        self.viewModel = viewModel
        _settings = ObservedObject(wrappedValue: viewModel.settingsViewModel)
        _exportModel = exportModel
        _moveToLibrary = moveToLibrary
        _transcription = ObservedObject(wrappedValue: transcription)
    }

    func body(content: Content) -> some View {
        publishingSceneValues(takingCommands(content))
            .toolbar {
                if settings.showExportInReaderToolbar {
                    ToolbarItem {
                        ReaderExportToolbarButton(action: openExport)
                    }
                }
            }
            .sheet(item: $exportModel) { model in
                BookExportSheet(model: model, close: { exportModel = nil })
            }
            // What the move did is said once the sheet has closed (REV11 F6).
            .modifier(MoveToLibrarySheetPresentation(
                request: $moveToLibrary,
                library: viewModel.libraryViewModel,
                say: { [weak viewModel] message in VoiceOverAnnouncer.announce(message, from: viewModel?.hostWindow) }
            ))
            .modifier(TranscriptionPresentation(presenter: transcription))
    }

    /// `view` taking the File and Book menus' commands for this reader, each
    /// when the reader's window, or a sheet over it, is key
    /// (`takesCommand`), and closing as the audio editor opens on its book.
    /// A step of its own, which the type checker reads apart from the rest
    /// of the body, so the body stays well clear of its limit (board #829).
    private func takingCommands(_ view: some View) -> some View {
        view
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
            .onReceive(NotificationCenter.default.publisher(for: .editBookManifest)) { notification in
                guard takesCommand(notification) else { return }
                editManifest(choosingApp: false)
            }
            .onReceive(NotificationCenter.default.publisher(for: .editBookManifestWith)) { notification in
                guard takesCommand(notification) else { return }
                editManifest(choosingApp: true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .transcribeBookAudio)) { notification in
                guard takesCommand(notification) else { return }
                transcribe()
            }
            .onReceive(NotificationCenter.default.publisher(for: .attachBookTranscript)) { notification in
                guard takesCommand(notification) else { return }
                attachTranscript()
            }
            .onReceive(NotificationCenter.default.publisher(for: .cleanUpBookTranscript)) { notification in
                guard takesCommand(notification) else { return }
                cleanUpTranscript()
            }
            .onReceive(NotificationCenter.default.publisher(for: .deleteBookTranscript)) { notification in
                guard takesCommand(notification) else { return }
                deleteTranscript()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editBookAudio)) { notification in
                guard takesCommand(notification) else { return }
                editAudio()
            }
            .onReceive(NotificationCenter.default.publisher(for: .moveToLibrary)) { notification in
                guard takesCommand(notification) else { return }
                requestMoveToLibrary()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closeReaderForAudioEditing)) { notification in
                // The audio editor is opening on this reader's book.
                guard notification.object as? UUID == viewModel.book.id else { return }
                viewModel.hostWindow?.performClose(nil)
            }
    }

    /// `view` publishing which of the Book menu's commands the reader's book
    /// takes, as scene values: published whenever this reader's window is
    /// key, even while none of its views has keyboard focus, as when
    /// VoiceOver reads its text, since a focused value would leave the Book
    /// menu's commands unavailable then. A step of its own, as
    /// `takingCommands(_:)` is.
    private func publishingSceneValues(_ view: some View) -> some View {
        view
            .focusedSceneValue(
                \.canEditBookText,
                BookTextEditor.canEditText(of: viewModel.book, isTranscribed: transcribedBooks.contains(viewModel.book.id))
            )
            .focusedSceneValue(
                \.canEditBookManifest,
                BookManifestEditing.canEditManifest(of: viewModel.book, isTrackFolder: trackFolderBooks.contains(viewModel.book.id))
            )
            .focusedSceneValue(\.canTranscribeBookAudio, LibraryAudioCommand.isTranscribable(viewModel.book))
            .focusedSceneValue(
                \.canAttachBookTranscript,
                TranscriptAttachments.canAttach(viewModel.book, attaching: attachments.bookIDs)
            )
            // A transcribed audiobook's transcript is cleaned up, an episode's
            // in its feed included: the transcript is the listener's own work.
            .focusedSceneValue(\.canCleanUpBookTranscript, hasTranscript)
            .focusedSceneValue(\.canDeleteBookTranscript, hasTranscript)
            .focusedSceneValue(\.canEditBookAudio, AudioEditorLauncher.canEdit(viewModel.book))
            // An episode or article in its feed moves into the library
            // (FR11, branch D); once it has, it is the library's own.
            .focusedSceneValue(\.canMoveBookToLibrary, viewModel.book.isFeedItem)
    }

    /// Whether the reader's book is a transcribed audiobook, whose
    /// transcript Clean Up Transcript (Experimental)… and Delete Transcript…
    /// act on.
    private var hasTranscript: Bool {
        LibraryAudioCommand.isTranscribable(viewModel.book) && transcribedBooks.contains(viewModel.book.id)
    }

    /// Opens the Transcribe Audio sheet for the reader's audiobook, as the
    /// library holds the book now (FR05).
    private func transcribe() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        transcription.transcribe([book], library: library, window: viewModel.hostWindow)
    }

    /// Asks for a WebVTT or SubRip file to make the reader's audiobook's
    /// transcript, as the library holds the book now (FMT23).
    private func attachTranscript() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        transcription.chooseTranscriptFile(for: book, library: library, window: viewModel.hostWindow)
    }

    /// Opens the Clean Up sheet for the reader's audiobook's transcript, as
    /// the library holds the book now (FR05, experimental).
    private func cleanUpTranscript() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        transcription.cleanUp(book, library: library, window: viewModel.hostWindow)
    }

    /// Opens Move to Library…'s sheet for the reader's book, as the library
    /// holds it now, when it is an episode or article downloaded in its feed
    /// (FR11, branch D); for any other book, as when the command's key is
    /// pressed over one, VoiceOver hears why and no sheet opens. The reader
    /// follows its book's package as it moves.
    private func requestMoveToLibrary() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        guard let request = MoveToLibraryRequest.forBooks([book], in: library) else {
            VoiceOverAnnouncer.announce(FeedWording.nothingToMoveToLibrary, from: viewModel.hostWindow)
            return
        }
        moveToLibrary = request
    }

    /// Opens the reader's audiobook, as the library holds it now, in the
    /// audio editor (FR04), which closes this reader first.
    private func editAudio() {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        AudioEditorLauncher.edit(book, in: library, from: viewModel.hostWindow)
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

    /// Opens the reader's audiobook's manifest in the user's own editor, or
    /// in an app they choose, as the library holds the book now (FR17).
    private func editManifest(choosingApp: Bool) {
        let library = viewModel.libraryViewModel
        let book = library.bookByID(viewModel.book.id) ?? viewModel.book
        let window = viewModel.hostWindow
        Task {
            await BookManifestEditor.shared.edit(book, choosingApp: choosingApp, in: library, from: window)
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
