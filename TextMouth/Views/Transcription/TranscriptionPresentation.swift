#if os(macOS)
import AppKit
#endif
import os
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

/// Asking to replace an audiobook's transcript with one from a WebVTT or
/// SubRip file (FMT23): the confirmation names the book and the file, and
/// says whether the user's own edits, or a cleanup, go too. It carries the
/// file as it was read, so Replace attaches what the listener chose
/// without reading the file again.
struct TranscriptAttachRequest: Identifiable, Equatable {
    /// Tells confirmations apart.
    let id = UUID()
    /// The book whose transcript would be replaced.
    let book: Book
    /// The file the new transcript comes from.
    let fileURL: URL
    /// What the file holds, as it was read.
    let document: TimedTextDocument
    /// Whether the user edited the transcript the book has.
    let isEdited: Bool
    /// Whether the transcript the book has was cleaned up.
    let isCleanedUp: Bool

    /// The file's name, as the confirmation and VoiceOver say it: never a
    /// path.
    var fileName: String {
        fileURL.lastPathComponent
    }
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
/// the confirmation before Delete Transcript, Attach Transcript…'s Open
/// panel and its confirmation before a transcript is replaced (FMT23), and
/// a notice saying why a command did nothing. The window's commands ask
/// here, and `TranscriptionPresentation` shows what is asked.
@MainActor
final class TranscriptionPresenter: ObservableObject {
    /// The Transcribe Audio sheet showing, or nil.
    @Published var sheet: TranscriptionSheetModel?
    /// The Clean Up sheet showing, or nil.
    @Published var cleanup: TranscriptCleanupSheetModel?
    /// The confirmation before deleting a transcript, while it shows.
    @Published var deletion: TranscriptDeletionRequest?
    /// The confirmation before a transcript from a file replaces the book's
    /// own (FMT23), while it shows. Its book is being attached to
    /// (`TranscriptAttachments`) while it shows; once it goes, by Cancel,
    /// Escape, or the alert's closing, the attaching ends, unless another
    /// confirmation shows for the same book, and Replace begins it again
    /// until the transcript is saved (`replaceConfirmed(_:)`).
    @Published var attachReplacement: TranscriptAttachRequest? {
        didSet {
            // Read here, on the main actor, and handed to the lock's closure
            // as a value.
            let askedBook = attachReplacement?.book.id
            askedBookID.withLock { $0 = askedBook }
            if let oldValue, oldValue.book.id != attachReplacement?.book.id {
                TranscriptAttachments.shared.end(oldValue.book.id)
            }
        }
    }
    /// The book `attachReplacement` asks about, kept where the presenter's
    /// deinitializer, which is not on the main actor, can read it
    /// (`attachReplacement` itself it cannot).
    private nonisolated let askedBookID = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    /// The notice showing, or nil.
    @Published var notice: TranscriptionNotice?
    /// Whether Attach Transcript…'s Open panel shows on this window (FMT23).
    @Published private(set) var isChoosingTranscriptFile = false

    /// Whether any of the dialogs shows: a sheet, a confirmation, the Open
    /// panel, or the notice. A book's window waits for none to show before
    /// it shows the report of a speech refusal
    /// (`SpeechRefusalReportPresenter`).
    var isShowingAny: Bool {
        sheet != nil || cleanup != nil || deletion != nil || attachReplacement != nil
            || isChoosingTranscriptFile || notice != nil
    }

    /// What the dialogs reach: the app's own, unless a test passes its own.
    private let services: @MainActor () -> TranscriptionSheetServices
    /// What the Clean Up sheet reaches: the app's own, unless a test passes
    /// its own.
    private let cleanupServices: @MainActor () -> TranscriptCleanupServices
    /// The library a confirmed deletion acts in.
    private weak var deletionLibrary: LibraryViewModel?
    /// The window a confirmed deletion is announced from.
    private weak var deletionWindow: PlatformWindow?
    /// The library a confirmed replacement attaches in (FMT23).
    private weak var attachLibrary: LibraryViewModel?
    /// The window a confirmed replacement is announced from.
    private weak var attachWindow: PlatformWindow?

    /// A presenter whose dialogs reach `services`, and whose Clean Up sheet
    /// reaches `cleanupServices`.
    init(
        services: @escaping @MainActor () -> TranscriptionSheetServices = { .live },
        cleanupServices: @escaping @MainActor () -> TranscriptCleanupServices = { .live }
    ) {
        self.services = services
        self.cleanupServices = cleanupServices
    }

    /// A window that closes while its confirmation to replace a transcript
    /// shows takes the presenter with it, and the alert's own dismissal may
    /// never reach `attachReplacement` then, so the book would stay "being
    /// attached to" for good: Attach Transcript… dimmed for it in every
    /// window until TextMouth quits. A presenter going away with a
    /// confirmation showing ends that book's attaching itself.
    ///
    /// A deinitializer is not on the main actor, so the ending is handed to
    /// it with the book's ID alone, which is all it needs and is safe to
    /// send. (Replace has its own task, which holds the presenter until the
    /// transcript is saved, so a presenter is never released mid-save.)
    deinit {
        guard let bookID = askedBookID.withLock({ $0 }) else { return }
        Task { @MainActor in
            TranscriptAttachments.shared.end(bookID)
        }
    }

    /// Opens the Transcribe Audio sheet for `books`, the books a command was
    /// chosen for, transcribing through `library` and announcing from
    /// `window`: one audiobook's sheet, or, for several books or a book that
    /// is not an audiobook, the sheet saying why, unless a sheet is open
    /// already. With `startsAtOnce`, the sheet presses Transcribe for the
    /// user as soon as it can.
    ///
    /// When a transcript is being attached to any of `books`
    /// (`TranscriptAttachments`), a notice naming the first such book says to
    /// wait instead, whether the request is for one book or for several, and
    /// from whichever way the command came: the reader's Book menu dims it
    /// for one book, and a library row, a selection of rows, or a VoiceOver
    /// action reaches here (follow-up 7). A request for several books
    /// that includes such a book gets the same notice, not the sheet.
    func transcribe(_ books: [Book], library: LibraryViewModel, window: PlatformWindow?, startsAtOnce: Bool = false) {
        guard sheet == nil else { return }
        if let book = books.first(where: { TranscriptAttachments.shared.bookIDs.contains($0.id) }) {
            notice = TranscriptionNotice(
                title: TranscriptionWording.transcribeNoticeTitle,
                message: TranscriptionWording.transcribeWhileAttaching(bookTitle: book.title)
            )
            return
        }
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
    func perform(_ command: LibraryAudioCommand, library: LibraryViewModel, window: PlatformWindow?) {
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
    func cleanUp(_ book: Book, library: LibraryViewModel, window: PlatformWindow?) {
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
    func confirmDeletion(of book: Book, library: LibraryViewModel, window: PlatformWindow?) async {
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

    // MARK: Attach Transcript

    /// Book > Attach Transcript… (FMT23): asks for a WebVTT or SubRip file
    /// to make `book`'s transcript, in an Open panel as a sheet on `window`
    /// (on its own without one), and attaches the file chosen through
    /// `library` (`attachTranscript(fileAt:to:library:window:)`). The panel
    /// starts in the folder the book was imported from, where its
    /// transcript most likely lies, when that is still there
    /// (`TranscriptAttachments.startingFolder(for:)`).
    ///
    /// While the same book is being transcribed, a notice says to wait
    /// instead. Nothing opens for a book the command is never offered for,
    /// or one a transcript is being attached to
    /// (`TranscriptAttachments.canAttach`), the menu's own rule, so every
    /// path through here agrees with it; nor while this window's Open panel
    /// or confirmation shows already, so a second panel never waits behind
    /// the first. The iPhone has no Book menu yet, and no Open panel: nothing
    /// there asks for this, and nothing opens.
    func chooseTranscriptFile(for book: Book, library: LibraryViewModel, window: PlatformWindow?) {
        guard !isChoosingTranscriptFile, attachReplacement == nil,
              TranscriptAttachments.canAttach(book, attaching: TranscriptAttachments.shared.bookIDs) else { return }
        if let busy = Self.transcribingNotice(for: book, center: services().center) {
            notice = busy
            return
        }
        #if os(macOS)
        // Taken at once, before the folder is looked for, so a second
        // command asked meanwhile opens no second panel.
        isChoosingTranscriptFile = true
        let sourcePath = book.sourceFilePath
        Task { [weak self] in
            // The starting folder is looked for off the main thread: the
            // folder may be on a share or cloud drive that does not answer.
            let folder = await OffMainWork.run { TranscriptAttachments.startingFolder(forSource: sourcePath) }
            self?.presentTranscriptPanel(startingIn: folder, for: book, library: library, window: window)
        }
        #endif
    }

    #if os(macOS)
    /// Shows the Open panel that Attach Transcript… asks for a file with
    /// (`chooseTranscriptFile(for:library:window:)`), as a sheet on `window`
    /// (on its own without one), starting in `folder` when there is one, and
    /// attaches the file chosen to `book` through `library`. Ends
    /// `isChoosingTranscriptFile` when the panel closes.
    private func presentTranscriptPanel(startingIn folder: URL?, for book: Book, library: LibraryViewModel, window: PlatformWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = TranscriptAttachments.fileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = TranscriptionWording.attachPanelMessage(bookTitle: book.title)
        panel.prompt = TranscriptionWording.attachPanelPrompt
        if let folder {
            panel.directoryURL = folder
        }
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            self.isChoosingTranscriptFile = false
            guard response == .OK, let url = panel.url else { return }
            Task {
                await self.attachTranscript(fileAt: url, to: book, library: library, window: window)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }
    #endif

    /// Attaches the WebVTT or SubRip file at `url` to `book` as its
    /// transcript (FMT23), timed on the book's audio from its start, through
    /// `library`, announcing from `window`. The file is read off the main
    /// thread. When the book has a transcript, or one of a later layout this
    /// TextMouth cannot read, the listener is asked first
    /// (`attachReplacement`); otherwise the transcript is saved at once
    /// (`saveAttachment`).
    ///
    /// A book being transcribed, a file of another kind, one that cannot be
    /// read, and a book whose transcript or text is only in iCloud each give
    /// a notice saying why, and change nothing. The book is being attached
    /// to (`TranscriptAttachments`) from now until its transcript is saved
    /// or refused, or the confirmation goes.
    func attachTranscript(fileAt url: URL, to book: Book, library: LibraryViewModel, window: PlatformWindow?) async {
        let attachments = TranscriptAttachments.shared
        attachments.begin(book.id)
        // Every way out ends the attaching but the confirmation's: while the
        // confirmation shows, the book is still being attached to, and its
        // answer ends the attaching (`attachReplacement`).
        var isAsking = false
        defer {
            if !isAsking {
                attachments.end(book.id)
            }
        }
        let services = services()
        // A transcription that began while the Open panel showed is said
        // before the file is read or a replacement is asked about.
        if let busy = Self.transcribingNotice(for: book, center: services.center) {
            notice = busy
            return
        }
        guard let format = TimedTextFormat.cueFileFormat(forExtension: url.pathExtension) else {
            showAttachFailure(TranscriptionWording.attachUnknownFormat, fileAt: url, to: book)
            return
        }
        // Nothing is opened that is not a regular file (a named pipe would
        // wait for ever).
        guard TranscriptAttachments.isReadableFile(at: url) else {
            showAttachFailure(TranscriptionWording.attachNotAFile, fileAt: url, to: book)
            return
        }
        let document: TimedTextDocument
        do {
            document = try await OffMainWork.runThrowing { try TimedTextReader.read(fileAt: url, as: format) }
        } catch {
            showAttachFailure(error.localizedDescription, fileAt: url, to: book)
            return
        }
        // What the book has: a transcript only in iCloud is neither read nor
        // replaced unseen, and a text only there is never written over
        // (`TranscriptStore.install`), so each waits for the book's download.
        let lookup = await services.readTranscript(book)
        let found: Transcript?
        let asksFirst: Bool
        switch lookup {
        case .inCloud:
            showAttachFailure(TranscriptionWording.transcriptInCloud, fileAt: url, to: book)
            return
        case .found(let transcript):
            found = transcript
            asksFirst = true
        case .unsupportedVersion:
            // A later TextMouth's transcript, which this one cannot read,
            // and so cannot say was edited or cleaned up.
            found = nil
            asksFirst = true
        case .missing, .unusable:
            // No transcript, or one set aside as unusable: nothing the
            // listener would lose.
            found = nil
            asksFirst = false
        }
        if await services.isTextInCloud(book) {
            showAttachFailure(TranscriptionWording.textInCloud, fileAt: url, to: book)
            return
        }
        guard asksFirst else {
            await saveAttachment(document, from: url, to: book, library: library, window: window)
            return
        }
        attachLibrary = library
        attachWindow = window
        attachReplacement = TranscriptAttachRequest(
            book: book,
            fileURL: url,
            document: document,
            isEdited: found?.editedAt != nil,
            isCleanedUp: found?.cleanedUp != nil
        )
        isAsking = true
    }

    /// Replaces the book's transcript with the file's once the listener has
    /// confirmed `request` (FMT23), saving it as `saveAttachment` does,
    /// through the library and from the window the request was made in.
    /// The book is being attached to until its transcript is saved or
    /// refused.
    func replaceConfirmed(_ request: TranscriptAttachRequest) async {
        let attachments = TranscriptAttachments.shared
        if attachReplacement?.id == request.id {
            attachReplacement = nil
        }
        // The confirmation's going ended the attaching, here or as the alert
        // closed before this ran: it goes on until the transcript is saved
        // or refused.
        attachments.begin(request.book.id)
        defer { attachments.end(request.book.id) }
        guard let library = attachLibrary else { return }
        await saveAttachment(request.document, from: request.fileURL, to: request.book, library: library, window: attachWindow)
    }

    /// Saves `document`, read from the file at `url`, as the transcript of
    /// `requested` as the library holds the book now, through `library`,
    /// announcing from `window`, off the main thread: timed on the book's
    /// audio from its start, so a book of several tracks takes one file for
    /// the whole book, its times running on across the tracks
    /// (`OutsideTranscript.transcript(bookTimeline:plan:source:now:hasher:)`).
    ///
    /// A transcription of the same book begun meanwhile gives the notice
    /// saying to wait, and a transcript that cannot be made or saved a notice
    /// saying why; neither changes anything. The book's Edit Text session is
    /// settled and ended before the text it edits is replaced, and begun
    /// again if the save fails, as Delete Transcript does. Once saved, the
    /// library row says the book is transcribed, an open reader shows the
    /// text, and VoiceOver hears how many words it holds.
    private func saveAttachment(
        _ document: TimedTextDocument,
        from url: URL,
        to requested: Book,
        library: LibraryViewModel,
        window: PlatformWindow?
    ) async {
        let services = services()
        // A transcription begun while the file was read, or while the
        // confirmation showed, would save its own transcript over this one.
        if let busy = Self.transcribingNotice(for: requested, center: services.center) {
            notice = busy
            return
        }
        // What follows reads every audio file whole, which takes seconds for
        // a long book: VoiceOver hears it begin, as a transcription's start
        // is heard, so the wait is never silent (follow-up 6).
        services.announce(
            TranscriptionWording.attaching(fileName: url.lastPathComponent, bookTitle: requested.title),
            window
        )
        let book = library.bookByID(requested.id) ?? requested
        let sentences = document.sentences
        let source = TranscriptSource(origin: .attached, format: document.format, fileName: url.lastPathComponent)
        let transcript: Transcript
        do {
            // Measuring and fingerprinting the audio reads each file whole.
            transcript = try await OffMainWork.runThrowing { () throws -> Transcript in
                let plan = try TranscriptionPlan.make(for: book)
                return try OutsideTranscript.transcript(bookTimeline: sentences, plan: plan, source: source)
            }
        } catch {
            showAttachFailure(error.localizedDescription, fileAt: url, to: book)
            return
        }
        // The new transcript replaces the text the listener may be editing:
        // an edit saved but not yet taken is taken first, and the session
        // ends; if the save fails, the session begins again, so the
        // listener's later saves are still taken.
        let wasEditing = await services.pauseTextEdit(book)
        let installation: TranscriptInstallation
        do {
            installation = try await OffMainWork.runThrowing { try TranscriptStore.install(transcript, for: book) }
        } catch {
            if wasEditing { await services.resumeTextEdit(book) }
            showAttachFailure(error.localizedDescription, fileAt: url, to: book)
            return
        }
        services.transcribedBooks.record(book.id, isTranscribed: true)
        library.bookUpdates.transcriptReplaced(bookID: book.id, with: installation.text)
        services.announce(
            TranscriptionWording.attached(
                fileName: url.lastPathComponent,
                bookTitle: book.title,
                wordCount: transcript.wordCount,
                skipped: document.skippedCueCount,
                cut: document.cutCueCount
            ),
            window
        )
        // Counts and the format alone: never the transcript's words, nor a path.
        let sentenceCount = transcript.files.reduce(0) { $0 + $1.sentences.count }
        DiagnosticLog.event(
            .storage,
            "TRANSCRIPT_ATTACHED: \(book.title): \(document.format.name) file, \(sentenceCount) sentences, "
                + "\(document.skippedCueCount) passages left out, \(document.cutCueCount) cut short"
        )
    }

    /// The notice saying `book` is being transcribed, while `center`
    /// transcribes it, or nil (FMT23): a transcript is never attached while
    /// the book's own transcription would save another over it.
    private static func transcribingNotice(for book: Book, center: TranscriptionJobCenter) -> TranscriptionNotice? {
        guard center.current?.bookID == book.id else { return nil }
        return TranscriptionNotice(
            title: TranscriptionWording.attachNoticeTitle,
            message: TranscriptionWording.attachWhileTranscribing(bookTitle: book.title)
        )
    }

    /// Shows why the file at `url` was not attached to `book` (FMT23):
    /// `reason`, a sentence of its own, in the Attach Transcript notice.
    private func showAttachFailure(_ reason: String, fileAt url: URL, to book: Book) {
        notice = TranscriptionNotice(
            title: TranscriptionWording.attachNoticeTitle,
            message: TranscriptionWording.attachFailed(fileName: url.lastPathComponent, bookTitle: book.title, reason: reason)
        )
    }
}

/// Shows a window's transcription dialogs (FR05): the Transcribe Audio
/// sheet, the Clean Up sheet, the confirmation before Delete Transcript and
/// the one before a transcript from a file replaces the book's own (FMT23),
/// each a standard alert whose Cancel Escape presses, and the notice saying
/// why a command did nothing. A modifier of its own, so a window's body
/// grows by one line.
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
            // Cancel, Escape, or the alert's closing ends the book's
            // attaching (`TranscriptionPresenter.attachReplacement`).
            .alert(
                presenter.attachReplacement.map { TranscriptionWording.replaceConfirmationTitle(bookTitle: $0.book.title) } ?? "",
                isPresented: isShowing(\.attachReplacement),
                presenting: presenter.attachReplacement
            ) { request in
                Button(TranscriptionWording.replaceButtonTitle, role: .destructive) {
                    Task {
                        await presenter.replaceConfirmed(request)
                    }
                }
                Button(TranscriptionWording.cancelTitle, role: .cancel) {}
            } message: { request in
                Text(TranscriptionWording.replaceConfirmationMessage(
                    fileName: request.fileName,
                    isEdited: request.isEdited,
                    isCleanedUp: request.isCleanedUp
                ))
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
    let hostWindow: PlatformWindow?

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
            .onReceive(NotificationCenter.default.publisher(for: PlatformApplication.didBecomeActiveNotification)) { _ in
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
        in window: PlatformWindow?,
        router: LibraryWindowRouter = .shared
    ) -> Bool {
        guard let thisWindow = ImportOrigin(window: window) else { return false }
        let openWindows = router.registeredLibraryWindows.compactMap { ImportOrigin(window: $0) }
        return ImportDecisionQueue.askingWindow(for: acceptance.origin, among: openWindows) == thisWindow
    }
}
