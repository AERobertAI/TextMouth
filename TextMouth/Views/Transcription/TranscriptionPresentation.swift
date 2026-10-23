import SwiftUI

// MARK: - A Window's Transcription Dialogs

/// Asking to delete one audiobook's transcript (FR05): the confirmation
/// names the book, and says whether the user's own edits go too.
struct TranscriptDeletionRequest: Identifiable, Equatable {
    /// Tells confirmations apart.
    let id = UUID()
    /// The book whose transcript would go.
    let book: Book
    /// Whether the user edited the transcript.
    let isEdited: Bool
}

/// A sentence a window's transcription dialogs show with OK: why a command
/// did nothing, or why it failed.
struct TranscriptionNotice: Identifiable, Equatable {
    /// Tells notices apart.
    let id = UUID()
    /// The alert's title.
    let title: String
    /// What happened, in plain words.
    let message: String
}

/// The transcription dialogs of one window (FR05), a Library window or a
/// book's: the Transcribe Audio sheet its commands open, the Clean Up sheet,
/// the confirmation before Delete Transcript, and a notice saying why a
/// command did nothing. The window's commands ask here, and
/// `TranscriptionPresentation` shows what is asked.
@MainActor
final class TranscriptionPresenter: ObservableObject {
    /// The Transcribe Audio sheet showing, or nil.
    @Published var sheet: TranscriptionSheetModel?
    /// The Clean Up sheet showing, or nil.
    @Published var cleanup: TranscriptCleanupSheetModel?
    /// The confirmation before deleting a transcript, while it shows.
    @Published var deletion: TranscriptDeletionRequest?
    /// The notice showing, or nil.
    @Published var notice: TranscriptionNotice?

    /// Whether any of the dialogs shows: a sheet, the confirmation, or the
    /// notice. A book's window waits for none to show before it shows the
    /// report of a speech refusal (`SpeechRefusalReportPresenter`).
    var isShowingAny: Bool {
        sheet != nil || cleanup != nil || deletion != nil || notice != nil
    }

    /// What the dialogs reach: the app's own, unless a test passes its own.
    private let services: @MainActor () -> TranscriptionSheetServices
    /// What the Clean Up sheet reaches: the app's own, unless a test passes
    /// its own.
    private let cleanupServices: @MainActor () -> TranscriptCleanupServices
    /// The library a confirmed deletion acts in.
    private weak var deletionLibrary: LibraryViewModel?
    /// The window a confirmed deletion is announced from.
    private weak var deletionWindow: NSWindow?

    /// A presenter whose dialogs reach `services`, and whose Clean Up sheet
    /// reaches `cleanupServices`.
    init(
        services: @escaping @MainActor () -> TranscriptionSheetServices = { .live },
        cleanupServices: @escaping @MainActor () -> TranscriptCleanupServices = { .live }
    ) {
        self.services = services
        self.cleanupServices = cleanupServices
    }

    /// Opens the Transcribe Audio sheet for `books`, the books a command was
    /// chosen for, transcribing through `library` and announcing from
    /// `window`: one audiobook's sheet, or, for several books or a book that
    /// is not an audiobook, the sheet saying why, unless a sheet is open
    /// already. With `startsAtOnce`, the sheet presses Transcribe for the
    /// user as soon as it can.
    func transcribe(_ books: [Book], library: LibraryViewModel, window: NSWindow?, startsAtOnce: Bool = false) {
        guard sheet == nil else { return }
        let model = TranscriptionSheetModel(
            request: TranscriptionRequest(books: books),
            library: library,
            startsAtOnce: startsAtOnce,
            services: services()
        )
        model.window = window
        model.onClose = { [weak self, weak model] in
            // Only the sheet showing closes: a sheet already replaced, or
            // closed, leaves the next one alone.
            guard let self, let model, self.sheet === model else { return }
            self.sheet = nil
        }
        sheet = model
    }

    /// Runs a library row's audio command, from its context menu or its
    /// VoiceOver actions: Edit Audio… opens the audio editor (FR04); the
    /// rest are transcription's.
    func perform(_ command: LibraryAudioCommand, library: LibraryViewModel, window: NSWindow?) {
        switch command {
        case .editAudio(let book):
            AudioEditorLauncher.edit(book, in: library, from: window)
        case .transcribe(let books):
            transcribe(books, library: library, window: window)
        case .retranscribe(let book):
            // The same sheet as Transcribe Audio… for one book.
            transcribe([book], library: library, window: window)
        case .cleanUpTranscript(let book):
            cleanUp(book, library: library, window: window)
        case .deleteTranscript(let book):
            Task {
                await confirmDeletion(of: book, library: library, window: window)
            }
        }
    }

    // MARK: Clean Up Transcript

    /// Opens the Clean Up sheet for `book`'s transcript (FR05,
    /// experimental), cleaning up through `library` and announcing from
    /// `window`, unless a Clean Up sheet is open already. It opens nothing
    /// for a book the command is never offered for
    /// (`LibraryAudioCommand.isTranscribable(_:)`), such as a book without a
    /// package of its own, and says nothing aloud: nothing offers the command
    /// for such a book, so no listener can ask.
    func cleanUp(_ book: Book, library: LibraryViewModel, window: NSWindow?) {
        // The menus' own rule, so every path through here agrees with them.
        guard cleanup == nil, LibraryAudioCommand.isTranscribable(book) else { return }
        let model = TranscriptCleanupSheetModel(book: book, library: library, services: cleanupServices())
        model.window = window
        model.onClose = { [weak self, weak model] in
            // Only the sheet showing closes: a sheet already replaced, or
            // closed, leaves the next one alone.
            guard let self, let model, self.cleanup === model else { return }
            self.cleanup = nil
        }
        cleanup = model
    }

    // MARK: Delete Transcript

    /// Asks to delete `book`'s transcript, in `library`, announcing from
    /// `window`: a confirmation naming the book, and saying when the user's
    /// edits go too, as the transcript, read off the main thread, records.
    /// While the same book is being transcribed, a notice says to wait
    /// instead.
    func confirmDeletion(of book: Book, library: LibraryViewModel, window: NSWindow?) async {
        guard deletion == nil else { return }
        let services = services()
        if services.center.current?.bookID == book.id {
            notice = TranscriptionNotice(
                title: TranscriptionWording.deleteNoticeTitle,
                message: TranscriptionWording.deleteWhileTranscribing(bookTitle: book.title)
            )
            return
        }
        var isEdited = false
        if case .found(let transcript) = await services.readTranscript(book) {
            isEdited = transcript.editedAt != nil
        }
        // Asked once, even when the command came twice while the
        // transcript was read.
        guard deletion == nil else { return }
        deletionLibrary = library
        deletionWindow = window
        deletion = TranscriptDeletionRequest(book: book, isEdited: isEdited)
    }

    /// Deletes the transcript the confirmation named, once the user has
    /// confirmed: off the main thread, as the library holds the book now.
    /// The row stops saying "Transcribed", an open reader of the book stops
    /// showing the text, and VoiceOver hears it; a failure says why.
    func deleteConfirmed(_ request: TranscriptDeletionRequest) async {
        guard let library = deletionLibrary else { return }
        let window = deletionWindow
        let services = services()
        if deletion?.id == request.id {
            deletion = nil
        }
        let book = library.bookByID(request.book.id) ?? request.book
        // The transcript's text goes with it: an edit of it is no longer
        // taken. An edit saved but not yet checked is taken first, and the
        // session ends; if the deletion fails, the session begins again, so
        // the user's later saves are still taken.
        let wasEditing = await services.pauseTextEdit(book)
        do {
            _ = try await OffMainWork.runThrowing { try TranscriptStore.delete(for: book) }
        } catch {
            if wasEditing { await services.resumeTextEdit(book) }
            notice = TranscriptionNotice(
                title: TranscriptionWording.deleteNoticeTitle,
                message: TranscriptionWording.deleteFailed(bookTitle: book.title, reason: error.localizedDescription)
            )
            return
        }
        services.transcribedBooks.record(book.id, isTranscribed: false)
        library.bookUpdates.transcriptReplaced(bookID: book.id, with: nil)
        services.announce(TranscriptionWording.deleted(bookTitle: book.title), window)
    }
}

/// Shows a window's transcription dialogs (FR05): the Transcribe Audio
/// sheet, the Clean Up sheet, the confirmation before Delete Transcript,
/// whose Cancel Escape presses, and the notice saying why a command did
/// nothing. A modifier of its own, so a window's body grows by one line.
struct TranscriptionPresentation: ViewModifier {
    /// The window's dialogs.
    @ObservedObject var presenter: TranscriptionPresenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.sheet) { model in
                TranscriptionSheet(model: model)
            }
            .sheet(item: $presenter.cleanup) { model in
                TranscriptCleanupSheet(model: model)
            }
            .alert(
                presenter.deletion.map { TranscriptionWording.deleteConfirmationTitle(bookTitle: $0.book.title) } ?? "",
                isPresented: isShowing(\.deletion),
                presenting: presenter.deletion
            ) { request in
                Button(TranscriptionWording.deleteButtonTitle, role: .destructive) {
                    Task {
                        await presenter.deleteConfirmed(request)
                    }
                }
                Button(TranscriptionWording.cancelTitle, role: .cancel) {}
            } message: { request in
                Text(TranscriptionWording.deleteConfirmationMessage(isEdited: request.isEdited))
            }
            .alert(
                presenter.notice?.title ?? "",
                isPresented: isShowing(\.notice),
                presenting: presenter.notice
            ) { _ in
                Button(TranscriptionWording.okTitle, role: .cancel) {}
            } message: { notice in
                Text(notice.message)
            }
    }

    /// Whether the presenter holds a dialog at `keyPath`; dismissing the
    /// dialog clears it.
    private func isShowing<Dialog>(_ keyPath: ReferenceWritableKeyPath<TranscriptionPresenter, Dialog?>) -> Binding<Bool> {
        Binding(
            get: { presenter[keyPath: keyPath] != nil },
            set: { isShowing in
                if !isShowing {
                    presenter[keyPath: keyPath] = nil
                }
            }
        )
    }
}

/// What a Library window does for transcription (FR05): shows its
/// transcription dialogs; opens the Transcribe Audio sheet for an audiobook
/// whose offer after an import the user accepted in this window; and keeps
/// the rows' notes current, looking for the books' transcripts again as the
/// window appears, as the number of books changes, and as TextMouth becomes
/// active, when another Mac sharing the library may have transcribed a book
/// (`TranscribedBooks`).
struct LibraryTranscriptionSupport: ViewModifier {
    /// The window's dialogs.
    @ObservedObject var presenter: TranscriptionPresenter
    /// The library whose books are looked at.
    let library: LibraryViewModel
    /// The Library window, which asks the questions of the imports started
    /// in it, and which announcements come from.
    let hostWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .modifier(TranscriptionPresentation(presenter: presenter))
            .onReceive(library.acceptedTranscriptionOffers) { acceptance in
                // The offer's own sheet, pressing Transcribe for the user
                // once it can: the same process as the command's.
                guard Self.asks(acceptance, in: hostWindow), let book = library.bookByID(acceptance.bookID) else { return }
                presenter.transcribe([book], library: library, window: hostWindow, startsAtOnce: true)
            }
            // The rows' facts their packages hold: which audiobooks have a
            // transcript (FR05), and which play a folder of tracks, whose
            // manifest can be edited (FR17).
            .task(id: library.library.books.count) {
                await TranscribedBooks.shared.refresh(library.library.books)
                await TrackFolderBooks.shared.refresh(library.library.books)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await TranscribedBooks.shared.refresh(library.library.books)
                    await TrackFolderBooks.shared.refresh(library.library.books)
                }
            }
    }

    /// Whether `window` is the Library window that asked the offer
    /// `acceptance` answers: the window its import started in while that is
    /// open, or else the first open Library window, as for every import
    /// question (`ImportDecisionQueue.askingWindow(for:among:)`).
    @MainActor
    static func asks(
        _ acceptance: TranscriptionOfferAcceptance,
        in window: NSWindow?,
        router: LibraryWindowRouter = .shared
    ) -> Bool {
        guard let thisWindow = ImportOrigin(window: window) else { return false }
        let openWindows = router.registeredLibraryWindows.compactMap { ImportOrigin(window: $0) }
        return ImportDecisionQueue.askingWindow(for: acceptance.origin, among: openWindows) == thisWindow
    }
}
