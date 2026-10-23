import AppKit
import Combine
import Foundation

// MARK: - What the Sheet Was Asked For

/// What the Transcribe Audio command was chosen for (FR05): one audiobook,
/// or something it refuses with a sentence.
enum TranscriptionRequest: Equatable {
    /// One audiobook, to transcribe.
    case book(Book)
    /// Several books, or a book that is not an audiobook: the sheet says
    /// why, and does nothing else.
    case refused(String)

    /// The request for the books a command was chosen for: one audiobook is
    /// transcribed; several books are refused, as transcription works on one
    /// book at a time, and so is a book that is not an audiobook.
    init(books: [Book]) {
        guard books.count == 1, let book = books.first else {
            self = .refused(TranscriptionWording.oneBookAtATime)
            return
        }
        guard LibraryAudioCommand.isTranscribable(book) else {
            self = .refused(TranscriptionWording.notAnAudiobook(bookTitle: book.title))
            return
        }
        self = .book(book)
    }
}

// MARK: - What the Sheet Reaches

/// What the Transcribe Audio sheet asks of the system and the app: whether
/// this Mac can transcribe, the languages to try, each language's model,
/// downloads, the book's transcript, and the transcriptions under way. The
/// app's own, unless a test passes its own (`live`).
struct TranscriptionSheetServices {
    /// Whether this Mac's system can transcribe.
    var systemSupport: @MainActor () -> TranscriptionAvailability.SystemSupport
    /// The languages a transcription tries, in order, as the setting gives
    /// them (`TranscriptionLanguage.languagesToTry(in:)`).
    var languagesToTry: @MainActor () -> [String]
    /// Where a language's model stands; asks only, never downloads.
    var modelStatus: @Sendable (Locale) async -> TranscriptionAvailability.ModelStatus
    /// What downloads a model, when the user asks.
    var installer: any TranscriptionModelInstalling
    /// The book's transcript as transcript.json holds it, read off the main
    /// thread without downloading anything.
    var readTranscript: @Sendable (Book) async -> TranscriptStore.Lookup
    /// Whether the book's text, content.md, is only in iCloud, looked at off
    /// the main thread without reading or downloading anything. A
    /// transcription saves its transcript over that text, which TextMouth
    /// never does while the file is not on this Mac
    /// (`TranscriptStore.install`), so the sheet asks before the audio is
    /// transcribed rather than lose the finished transcription after.
    var isTextInCloud: @Sendable (Book) async -> Bool
    /// The transcriptions under way.
    var center: TranscriptionJobCenter
    /// Which books the library rows call transcribed.
    var transcribedBooks: TranscribedBooks
    /// Settles and ends the Edit Text session of a book whose transcript
    /// goes (an edit saved but not yet checked is taken first); whether the
    /// book was being edited.
    var pauseTextEdit: @MainActor (Book) async -> Bool
    /// Begins the book's Edit Text session again when the deletion failed.
    var resumeTextEdit: @MainActor (Book) async -> Void
    /// Asks VoiceOver to speak a message from a window.
    var announce: @MainActor (String, NSWindow?) -> Void

    /// Whether `book`'s text, content.md, is only in iCloud, as `isDataless`
    /// says of the file (one lstat, which reads no content). The app asks it
    /// of the real file.
    static func textIsOnlyInCloud(
        _ book: Book,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless
    ) -> Bool {
        isDataless(TextMouthPaths.contentMarkdownPath(in: book.tmbDirectory))
    }

    /// The app's own: this Mac's system and speech models, the settings in
    /// the app's preferences store, and the app's transcription center.
    @MainActor
    static var live: TranscriptionSheetServices {
        TranscriptionSheetServices(
            systemSupport: { TranscriptionAvailability.systemSupport },
            languagesToTry: { TranscriptionLanguage.languagesToTry(in: TextMouthRuntime.current.preferences) },
            modelStatus: { await TranscriptionAvailability.modelStatus(for: $0) },
            installer: SystemTranscriptionModelInstaller(),
            readTranscript: { book in
                await OffMainWork.run { TranscriptStore.read(from: book.tmbDirectory) }
            },
            isTextInCloud: { book in
                await OffMainWork.run { TranscriptionSheetServices.textIsOnlyInCloud(book) }
            },
            center: .shared,
            transcribedBooks: .shared,
            pauseTextEdit: { await BookTextEditor.shared.pauseEditing(of: $0) },
            resumeTextEdit: { await BookTextEditor.shared.resumeEditing(of: $0) },
            announce: { message, window in VoiceOverAnnouncer.announce(message, from: window) }
        )
    }
}

// MARK: - The Sheet's Model

/// The Transcribe Audio sheet of one audiobook (FR05): the book's title and
/// audio length, how long transcribing should take, the language from the
/// setting with its model's status, a Download button when the model is not
/// on this Mac, and Transcribe, which starts the transcription and shows it.
///
/// Nothing downloads unless Download is pressed, and nothing is transcribed
/// unless Transcribe is. On a system older than macOS 26, or a Mac that
/// cannot run the speech model, the sheet only says so; a request for
/// several books only says that transcription works on one at a time.
@MainActor
final class TranscriptionSheetModel: ObservableObject, Identifiable {
    /// Where the sheet is.
    enum Phase: Equatable {
        /// Finding out where the language's model stands.
        case checking
        /// Saying why nothing can be transcribed, with only OK.
        case unavailable(String)
        /// Ready to transcribe, or to download the model first.
        case ready
        /// Showing the book's transcription under way.
        case transcribing
        /// Saying why the transcription stopped, with only Close.
        case failed(String)
    }

    /// Where the language's model stands, as the language line says.
    enum ModelState: Equatable {
        /// The recognizer cannot transcribe the language.
        case unsupported
        /// The model must be downloaded first.
        case needsDownload
        /// The model is downloading: the share done, or nil before it is
        /// known.
        case downloading(Double?)
        /// The model is on this Mac.
        case installed
    }

    /// The sheet's controls that VoiceOver and keyboard focus can be moved
    /// to, each the first control of the sheet in some phase.
    enum FocusTarget: Hashable {
        /// Download the language's model.
        case download
        /// Stop the model's download.
        case cancelDownload
        /// Transcribe, or Retranscribe.
        case transcribe
        /// Cancel, closing the sheet without transcribing.
        case cancel
        /// The progress bar of the transcription under way.
        case progress
        /// Cancel, stopping the transcription under way.
        case stop
        /// OK, closing a sheet that says why nothing can be transcribed.
        case ok
        /// Close, closing a sheet that says why a transcription stopped.
        case close
    }

    /// The transcript a book has already, as the sheet names it.
    struct ExistingTranscript: Equatable {
        /// When it was made.
        let createdAt: Date
        /// The language it is in, as a locale identifier.
        let locale: String
        /// When the user last edited it, or nil when they never have.
        var editedAt: Date? = nil
        /// When the user last cleaned it up by rule (Clean Up Transcript), or
        /// nil when they never have.
        var cleanedUpAt: Date? = nil
    }

    /// A transcript the book has that this TextMouth could not read. A
    /// later TextMouth's would be replaced by transcribing again; one only in
    /// iCloud keeps the book from being transcribed again until it is
    /// downloaded (`isBookInCloud`).
    enum UnreadableTranscript: Equatable {
        /// It is only in iCloud, so it was not read.
        case inCloud
        /// A later TextMouth wrote it in a layout this one does not read.
        case laterVersion
    }

    /// Tells sheets presenting different requests apart.
    let id = UUID()
    /// What the sheet was asked for.
    let request: TranscriptionRequest
    /// Whether Transcribe is pressed for the user as soon as it can be, as
    /// when the user accepted the offer after an import.
    let startsAtOnce: Bool

    /// Where the sheet is.
    @Published private(set) var phase: Phase
    /// The language a transcription uses, as a locale identifier, once known.
    @Published private(set) var language: String?
    /// Where the language's model stands.
    @Published private(set) var modelState: ModelState = .unsupported
    /// What the last download did, when it did not install the model: it
    /// was cancelled, or why it failed.
    @Published private(set) var downloadNotice: String?
    /// The book's transcript, when it has one.
    @Published private(set) var existing: ExistingTranscript?
    /// The book's transcript when this TextMouth could not read it (it is
    /// only in iCloud, or a later TextMouth wrote it), so `existing` is nil
    /// though a transcription would replace something.
    @Published private(set) var unreadableExisting: UnreadableTranscript?
    /// Whether the book's text, content.md, is only in iCloud, whatever the
    /// state of its transcript: a transcription saves its transcript over
    /// that text, which is never done while the file is not on this Mac.
    @Published private(set) var isTextInCloud = false

    /// Whether the book's transcript or its text is only in iCloud, so the
    /// book must be downloaded before it is transcribed again: Transcribe is
    /// unavailable and `bookInCloudLine` says why. Looked at as the sheet
    /// loads, before any audio is transcribed, so the finished transcription
    /// of an hour's audio is not refused afterwards by an install that finds
    /// a file in the cloud. A file that goes there after the sheet loaded is
    /// still caught by the install itself (`TranscriptStore.install`).
    var isBookInCloud: Bool {
        unreadableExisting == .inCloud || isTextInCloud
    }

    /// Whether the book has a transcript, readable or not: what decides
    /// whether Transcribe is a first transcription or a retranscription.
    var hasTranscript: Bool {
        existing != nil || unreadableExisting != nil
    }
    /// The title of another book being transcribed, which keeps Transcribe
    /// unavailable until it finishes.
    @Published private(set) var busyTitle: String?
    /// How far the book's transcription has come, while the sheet shows
    /// it: nil until its first file begins.
    @Published private(set) var progress: TranscriptionProgress?
    /// When the book's transcription began, while the sheet shows it.
    @Published private(set) var transcriptionStartedAt: Date?

    /// The window the sheet sits on, where announcements come from.
    weak var window: NSWindow?
    /// Closes the sheet; the presenter sets it.
    var onClose: () -> Void = {}

    /// The library, which gives the book as it holds it when a
    /// transcription saves its transcript.
    private weak var library: LibraryViewModel?
    /// What the sheet asks of the system and the app.
    private let services: TranscriptionSheetServices
    /// The transcription this sheet shows, once it started one or found its
    /// book's under way.
    private var watchedJobID: UUID?
    /// The download under way.
    private var downloadTask: Task<Void, Never>?
    /// The phase whose lines VoiceOver last heard (`announceSheet()`).
    private var announcedPhase: Phase?
    /// What the sheet hears from the transcription center.
    private var subscriptions: Set<AnyCancellable> = []

    /// A sheet for `request`, transcribing through `library`, pressing
    /// Transcribe for the user once it can when `startsAtOnce`.
    init(
        request: TranscriptionRequest,
        library: LibraryViewModel?,
        startsAtOnce: Bool = false,
        services: TranscriptionSheetServices = .live
    ) {
        self.request = request
        self.library = library
        self.startsAtOnce = startsAtOnce
        self.services = services
        switch request {
        case .book:
            phase = .checking
        case .refused(let reason):
            phase = .unavailable(reason)
        }
        services.center.$current
            .sink { [weak self] job in self?.transcriptionChanged(job) }
            .store(in: &subscriptions)
        services.center.$lastEnding
            .compactMap { $0 }
            .sink { [weak self] event in self?.transcriptionEnded(event) }
            .store(in: &subscriptions)
    }

    /// The book the sheet transcribes, or nil for a refusal.
    var book: Book? {
        if case .book(let book) = request { return book }
        return nil
    }

    // MARK: Loading

    /// Finds out what the sheet shows: whether this Mac can transcribe, the
    /// language and its model, the book's transcript, and any transcription
    /// under way; then, when asked to start at once, starts.
    func load() async {
        guard let book, phase == .checking else { return }
        switch services.systemSupport() {
        case .needsNewerSystem:
            phase = .unavailable(TranscriptionWording.failed(TranscriptionError.needsNewerSystem))
            return
        case .unavailableOnThisMac:
            phase = .unavailable(TranscriptionWording.failed(TranscriptionError.unavailableOnThisMac))
            return
        case .available:
            break
        }
        let (identifier, status) = await resolvedLanguage()
        language = identifier
        modelState = Self.modelState(for: status)
        switch await services.readTranscript(book) {
        case .found(let transcript):
            existing = ExistingTranscript(
                createdAt: transcript.createdAt,
                locale: transcript.locale,
                editedAt: transcript.editedAt,
                cleanedUpAt: transcript.cleanedUp?.cleanedAt
            )
        case .inCloud:
            unreadableExisting = .inCloud
        case .unsupportedVersion:
            unreadableExisting = .laterVersion
        case .missing, .unusable:
            // An unusable transcript was set aside beside itself already,
            // so transcribing replaces nothing the user could still read.
            break
        }
        // Whatever the transcript is: a text left in the cloud by itself
        // keeps the install from saving over it all the same.
        isTextInCloud = await services.isTextInCloud(book)
        if let job = services.center.current {
            if job.bookID == book.id {
                watch(job)
                return
            }
            busyTitle = job.bookTitle
        }
        phase = .ready
        if startsAtOnce, canTranscribe {
            transcribe()
        }
    }

    /// The first of the languages to try that the recognizer supports, as
    /// the locale its model serves, with the model's status; the last one
    /// tried, unsupported, when none is. A transcription tries them in the
    /// same order (`TranscriptionService`), so the sheet names the language
    /// it will use.
    private func resolvedLanguage() async -> (String, TranscriptionAvailability.ModelStatus) {
        let languages = services.languagesToTry()
        for identifier in languages {
            let status = await services.modelStatus(Locale(identifier: identifier))
            switch status {
            case .unsupported:
                continue
            case .needsDownload(let locale), .downloading(let locale), .installed(let locale):
                return (locale.identifier(.bcp47), status)
            }
        }
        return (languages.last ?? TranscriptionLanguage.defaultIdentifier, .unsupported)
    }

    /// How the language line words `status`.
    private static func modelState(for status: TranscriptionAvailability.ModelStatus) -> ModelState {
        switch status {
        case .unsupported: return .unsupported
        case .needsDownload: return .needsDownload
        case .downloading: return .downloading(nil)
        case .installed: return .installed
        }
    }

    // MARK: What the Sheet Shows

    /// The sheet's heading.
    var heading: String {
        guard let book else { return TranscriptionWording.unavailableTitle }
        if phase == .transcribing {
            return TranscriptionWording.progressTitle(bookTitle: book.title)
        }
        // A book with a transcript is transcribed again, as Transcribe's
        // title decides (`transcribeTitle`).
        return hasTranscript
            ? TranscriptionWording.retranscribeSheetTitle(bookTitle: book.title)
            : TranscriptionWording.sheetTitle(bookTitle: book.title)
    }

    /// The audio line: "Audio: 6 hours, 12 minutes."
    var audioLine: String {
        TranscriptionWording.audioLength(book?.audioDuration)
    }

    /// The estimate line: "Time to transcribe: about 6 minutes."
    var estimateLine: String {
        TranscriptionWording.estimateLine(forAudio: book?.audioDuration)
    }

    /// The name of the language a transcription uses, in the user's own
    /// language: "English (United States)".
    var languageName: String {
        language.map(TranscriptionLanguage.name(of:)) ?? ""
    }

    /// The name the language's model goes by: "English".
    var modelLanguageName: String {
        language.map(TranscriptionWording.modelLanguageName(of:)) ?? ""
    }

    /// The language line: "Language: English (United States), installed."
    var languageLine: String {
        let status: String
        switch modelState {
        case .unsupported: status = TranscriptionWording.modelUnsupported
        case .needsDownload: status = TranscriptionWording.modelNeedsDownload
        case .downloading: status = TranscriptionWording.modelDownloading
        case .installed: status = TranscriptionWording.modelInstalled
        }
        return TranscriptionWording.languageLine(name: languageName, status: status)
    }

    /// The line naming the book's transcript, when it has one: as it was
    /// made, or, for one a later TextMouth wrote, who wrote it. One only in
    /// iCloud is named by `bookInCloudLine` instead, which says what to do.
    var existingLine: String? {
        if let existing {
            return TranscriptionWording.alreadyTranscribed(
                on: existing.createdAt,
                languageName: TranscriptionLanguage.name(of: existing.locale)
            )
        }
        switch unreadableExisting {
        case .laterVersion: return TranscriptionWording.transcriptFromLaterVersion
        case .inCloud, nil: return nil
        }
    }

    /// The line saying the book must be downloaded before it is transcribed
    /// again, while its transcript or its text is only in iCloud (the
    /// transcript's first, as the lines are kept to one): nil otherwise.
    var bookInCloudLine: String? {
        if unreadableExisting == .inCloud { return TranscriptionWording.transcriptInCloud }
        return isTextInCloud ? TranscriptionWording.textInCloud : nil
    }

    /// The line warning that transcribing again replaces the user's own
    /// edits, whenever the book's transcript was edited, so Transcribe
    /// Again never replaces an edit unannounced (FR05).
    var editedLine: String? {
        existing?.editedAt.map(TranscriptionWording.editedTranscript(on:))
    }

    /// The line warning that transcribing again replaces the user's cleanup
    /// of the transcript, whenever it was cleaned up, so Retranscribe never
    /// replaces a cleanup unannounced.
    var cleanedLine: String? {
        existing?.cleanedUpAt.map(TranscriptionWording.cleanedUpTranscript(on:))
    }

    /// The line saying another book is being transcribed, while one is.
    var busyLine: String? {
        busyTitle.map(TranscriptionWording.busy(bookTitle:))
    }

    /// The transcription's progress lines, shown above its progress bar:
    /// the file being transcribed, then how much of the audio is done; or,
    /// before the first file begins, that it is starting.
    var progressLines: [String] {
        guard let progress else { return [TranscriptionWording.starting] }
        return [TranscriptionWording.fileLine(progress), TranscriptionWording.secondsLine(progress)]
    }

    /// The progress bar's value, which VoiceOver reads: "40 percent, file 3
    /// of 12".
    var progressValue: String {
        TranscriptionWording.progressValue(progress)
    }

    /// The download's progress line, while the model downloads.
    var downloadLine: String? {
        guard case .downloading(let fraction) = modelState else { return nil }
        return TranscriptionWording.downloading(languageName: modelLanguageName, fraction: fraction)
    }

    /// Whether the Download button is offered: the model must be
    /// downloaded, and nothing is being transcribed meanwhile.
    var offersDownload: Bool {
        phase == .ready && modelState == .needsDownload
    }

    /// Whether Transcribe can be pressed now: the sheet is ready, the
    /// language's model is on this Mac, no other book is being transcribed,
    /// and the book is not waiting in iCloud to be downloaded.
    var canTranscribe: Bool {
        phase == .ready && modelState == .installed && busyTitle == nil && !isBookInCloud
    }

    /// Transcribe's title: Retranscribe for a book transcribed already.
    var transcribeTitle: String {
        hasTranscript ? TranscriptionWording.transcribeAgainTitle : TranscriptionWording.transcribeTitle
    }

    /// What Transcribe does.
    var transcribeHint: String {
        hasTranscript ? TranscriptionWording.transcribeAgainHint : TranscriptionWording.transcribeHint
    }

    /// The lines under the language that only some sheets show: the book's
    /// transcript, that the book must be downloaded first, another
    /// transcription under way, and how the last download ended.
    var noticeLines: [String] {
        [existingLine, editedLine, cleanedLine, bookInCloudLine, busyLine, downloadNotice].compactMap { $0 }
    }

    /// Every line the ready sheet shows, in order, as VoiceOver hears them
    /// together once its focus lands.
    var readyLines: [String] {
        [heading, audioLine, estimateLine, languageLine] + noticeLines
    }

    /// The control VoiceOver and keyboard focus move to: the first control
    /// of the sheet as it is now, which does what the sheet is there for.
    /// Download while the model is missing, Cancel Download while it
    /// downloads, Transcribe once it can be pressed and Cancel until then,
    /// the progress bar while a transcription runs, and the one button of a
    /// sheet that says why. Nil while the sheet checks the model.
    var focusTarget: FocusTarget? {
        switch phase {
        case .checking:
            return nil
        case .unavailable:
            return .ok
        case .failed:
            return .close
        case .transcribing:
            return .progress
        case .ready:
            if offersDownload { return .download }
            if downloadLine != nil { return .cancelDownload }
            return canTranscribe ? .transcribe : .cancel
        }
    }

    /// What VoiceOver hears once its focus has landed on the sheet's first
    /// control; nil while the sheet checks or transcribes, which say nothing
    /// of their own here.
    var announcement: String? {
        switch phase {
        case .checking, .transcribing:
            return nil
        case .unavailable(let reason):
            return reason
        case .ready:
            return TranscriptionWording.sheetAnnouncement(lines: readyLines)
        case .failed:
            // The transcription center announced why it stopped.
            return nil
        }
    }

    /// Announces the sheet's lines (`announcement`), once for each phase,
    /// so a download ending or another transcription finishing, which move
    /// focus within the same phase, never repeats them.
    func announceSheet() {
        guard let announcement, announcedPhase != phase else { return }
        announcedPhase = phase
        services.announce(announcement, window)
    }

    // MARK: Transcribing

    /// Starts transcribing the book, when Transcribe can be pressed.
    func transcribe() {
        guard canTranscribe, let book, let language, let library else { return }
        let started = services.center.start(book, language: language, library: library, window: window)
        if started, let job = services.center.current {
            watch(job)
        } else {
            busyTitle = services.center.current?.bookTitle
        }
    }

    /// Shows `job`, the book's transcription under way, until it ends.
    private func watch(_ job: TranscriptionJob) {
        watchedJobID = job.id
        transcriptionStartedAt = job.startedAt
        progress = job.progress
        phase = .transcribing
    }

    /// Cancels the book's transcription under way. The sheet closes once it
    /// has stopped.
    func cancelTranscription() {
        guard phase == .transcribing, services.center.current?.id == watchedJobID else { return }
        services.center.cancel()
    }

    /// Follows the transcription under way: the book's own moves the
    /// progress shown, and another book's finishing frees Transcribe for
    /// this one.
    private func transcriptionChanged(_ job: TranscriptionJob?) {
        if let job, job.id == watchedJobID, progress != job.progress {
            progress = job.progress
        }
        if job == nil, busyTitle != nil {
            busyTitle = nil
        }
    }

    /// Acts on the end of the transcription this sheet shows: one that saved
    /// its transcript, or was cancelled, closes the sheet, which the center
    /// announced; one that failed shows why, with Close.
    private func transcriptionEnded(_ event: TranscriptionJobEndingEvent) {
        guard event.job.id == watchedJobID else { return }
        watchedJobID = nil
        switch event.ending {
        case .finished, .cancelled:
            close()
        case .failed(let reason):
            phase = .failed(reason)
        }
    }

    // MARK: Downloading the Model

    /// Downloads the language's model, which the user asked for by pressing
    /// Download: the line shows its progress, Cancel Download stops it, and
    /// VoiceOver hears how it ended. Once installed, the book can be
    /// transcribed.
    func downloadModel() {
        guard offersDownload, let language, downloadTask == nil else { return }
        modelState = .downloading(nil)
        downloadNotice = nil
        let installer = services.installer
        // Each share done is shown on the main actor, as it is reported.
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.showDownload(fraction)
            }
        }
        downloadTask = Task { [weak self] in
            let failure: Error?
            do {
                try await installer.install(locale: Locale(identifier: language), progress: report)
                failure = nil
            } catch {
                failure = error
            }
            await self?.downloadEnded(failure)
        }
    }

    /// Stops the download under way.
    func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Shows that `fraction` of the download is done, while it runs.
    private func showDownload(_ fraction: Double) {
        guard case .downloading = modelState, fraction.isFinite else { return }
        modelState = .downloading(min(1, max(0, fraction)))
    }

    /// Ends the download: one that finished has the model's status read
    /// again, so the line and Transcribe follow what the system installed;
    /// one cancelled or failed says so.
    private func downloadEnded(_ error: Error?) async {
        downloadTask = nil
        let name = modelLanguageName
        if let error {
            modelState = .needsDownload
            let notice = error is CancellationError
                ? TranscriptionWording.downloadCancelled(languageName: name)
                : TranscriptionWording.downloadFailed(languageName: name, reason: error.localizedDescription)
            downloadNotice = notice
            services.announce(notice, window)
            return
        }
        guard let language else { return }
        let status = await services.modelStatus(Locale(identifier: language))
        modelState = Self.modelState(for: status)
        if modelState == .installed {
            services.announce(TranscriptionWording.downloaded(languageName: name), window)
        }
    }

    // MARK: Closing

    /// Closes the sheet, stopping a download under way. A transcription
    /// under way goes on, and a sheet opened again for the book shows it.
    func close() {
        downloadTask?.cancel()
        onClose()
    }

    /// The sheet went away however it was closed: a download under way
    /// stops.
    func sheetClosed() {
        downloadTask?.cancel()
    }

    /// Escape in a sheet without a Cancel button, one that only says why
    /// nothing was or can be transcribed, closes it; elsewhere Cancel
    /// takes Escape itself.
    func escape() {
        switch phase {
        case .unavailable, .failed:
            close()
        case .checking, .ready, .transcribing:
            break
        }
    }
}
