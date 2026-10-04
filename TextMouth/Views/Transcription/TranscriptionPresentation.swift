import SwiftUI

// MARK: - A Window's Transcription Dialogs

/// The transcription dialogs of one window (FR05), a Library window or a
/// book's: the Transcribe Audio sheet its commands open. The window's
/// commands ask here, and `TranscriptionPresentation` shows what is asked.
@MainActor
final class TranscriptionPresenter: ObservableObject {
    /// The Transcribe Audio sheet showing, or nil.
    @Published var sheet: TranscriptionSheetModel?

    /// What the sheets reach: the app's own, unless a test passes its own.
    private let services: @MainActor () -> TranscriptionSheetServices

    /// A presenter whose sheets reach `services`.
    init(services: @escaping @MainActor () -> TranscriptionSheetServices = { .live }) {
        self.services = services
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

    /// Runs a library row's transcription command, from its context menu
    /// or its VoiceOver actions.
    func perform(_ command: LibraryTranscriptionCommand, library: LibraryViewModel, window: NSWindow?) {
        switch command {
        case .transcribe(let books):
            transcribe(books, library: library, window: window)
        }
    }
}

/// Shows a window's transcription dialogs (FR05): the Transcribe Audio
/// sheet its presenter holds. A modifier of its own, so a window's body
/// grows by one line.
struct TranscriptionPresentation: ViewModifier {
    /// The window's dialogs.
    @ObservedObject var presenter: TranscriptionPresenter

    func body(content: Content) -> some View {
        content
            .sheet(item: $presenter.sheet) { model in
                TranscriptionSheet(model: model)
            }
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
            .task(id: library.library.books.count) {
                await TranscribedBooks.shared.refresh(library.library.books)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task {
                    await TranscribedBooks.shared.refresh(library.library.books)
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
