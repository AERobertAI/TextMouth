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
