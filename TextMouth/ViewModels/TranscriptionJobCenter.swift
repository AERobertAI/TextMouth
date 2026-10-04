import AppKit
import Combine
import Foundation

// MARK: - A Transcription Under Way

/// The transcription the app is running (FR05), as the Transcribe Audio
/// sheet and the library show it.
struct TranscriptionJob: Equatable, Sendable {
    /// Tells this transcription from every other.
    let id: UUID
    /// The book being transcribed.
    let bookID: UUID
    /// Its title when the transcription began, for what VoiceOver hears.
    let bookTitle: String
    /// When the transcription began.
    let startedAt: Date
    /// How far it has come, as last shown: nil until the first file begins,
    /// while the system loads its speech model.
    var progress: TranscriptionProgress?
}

/// How a transcription ended (FR05).
enum TranscriptionJobEnding: Equatable, Sendable {
    /// The transcript was saved: so many words, in so many seconds.
    case finished(wordCount: Int, seconds: TimeInterval)
    /// It was cancelled, and the book is as it was.
    case cancelled
    /// It stopped, for the reason given, in plain words.
    case failed(String)

    /// What VoiceOver hears as a transcription of the book titled
    /// `bookTitle` ends this way.
    func announcement(bookTitle: String) -> String {
        switch self {
        case .finished(let wordCount, let seconds):
            return TranscriptionWording.finished(bookTitle: bookTitle, wordCount: wordCount, seconds: seconds)
        case .cancelled:
            return TranscriptionWording.failed(TranscriptionError.cancelled)
        case .failed(let reason):
            return reason
        }
    }

    /// The ending `error` stopped a transcription with: a cancellation, or
    /// a failure in the words `TranscriptionError` gives it.
    static func ending(for error: Error) -> TranscriptionJobEnding {
        if error is CancellationError || error as? TranscriptionError == .cancelled {
            return .cancelled
        }
        return .failed(TranscriptionWording.failed(error))
    }
}

/// One transcription's end, as the center publishes it.
struct TranscriptionJobEndingEvent: Equatable, Sendable {
    /// The transcription that ended.
    let job: TranscriptionJob
    /// How it ended.
    let ending: TranscriptionJobEnding
}

// MARK: - The Center

/// Runs the app's transcriptions (FR05), one at a time, for every window:
/// the Transcribe Audio sheet starts one here and shows it, and a sheet
/// opened later for the same book shows it too.
///
/// A transcription transcribes the book's audio off the main thread
/// (`TranscriptionService.transcribe`), writing nothing, and then saves the
/// transcript into the book as the library holds it by then
/// (`TranscriptStore.install`), off the main thread too. Cancelling it
/// before the transcript is saved leaves the book as it was; quitting
/// TextMouth cancels it, asking nothing.
///
/// VoiceOver hears it start, pass each quarter, and end, from the window
/// that started it. Its progress is shown at most four times a second, and
/// whenever it moves to another file. Once its transcript is saved, the
/// book's open readers show the text, and its library row says it is
/// transcribed (`TranscribedBooks`).
@MainActor
final class TranscriptionJobCenter: ObservableObject {
    /// The app's center, transcribing with this Mac's engine.
    static let shared = TranscriptionJobCenter()

    /// The shortest time between two showings of a transcription's
    /// progress: results arrive many times a second, faster than anyone
    /// reads them.
    static let progressInterval: Duration = .milliseconds(250)

    /// The transcription under way, or nil.
    @Published private(set) var current: TranscriptionJob?
    /// How the latest transcription ended, or nil before any has.
    @Published private(set) var lastEnding: TranscriptionJobEndingEvent?

    /// What transcribes the books.
    private let service: TranscriptionService
    /// What saves a transcript into its book, off the main thread.
    private let install: @Sendable (Transcript, Book) throws -> TranscriptInstallation
    /// Which books the library rows call transcribed.
    private let transcribedBooks: TranscribedBooks
    /// The task running the transcription under way.
    private var task: Task<Void, Never>?
    /// The window that started the transcription under way, where what
    /// VoiceOver hears of it is announced from.
    private weak var announcingWindow: NSWindow?
    /// The quarters of the transcription under way already announced.
    private var announcedMilestones: Set<Int> = []
    /// When the transcription's progress was last shown.
    private var progressShownAt: ContinuousClock.Instant?

    /// A center transcribing with `service`, saving with `install`, and
    /// recording transcribed books in `transcribedBooks`: the app's own
    /// unless a test passes others.
    init(
        service: TranscriptionService = .shared,
        install: @escaping @Sendable (Transcript, Book) throws -> TranscriptInstallation = {
            try TranscriptStore.install($0, for: $1)
        },
        transcribedBooks: TranscribedBooks = .shared
    ) {
        self.service = service
        self.install = install
        self.transcribedBooks = transcribedBooks
    }

    /// Starts transcribing `book` in `language`, a locale identifier the
    /// Transcribe Audio sheet resolved, saving the transcript into the book
    /// as `library` holds it once the audio is transcribed, and announcing
    /// from `window`.
    /// - Returns: Whether it started: false while another transcription is
    ///   under way, which the sheet says before Transcribe is offered.
    @discardableResult
    func start(_ book: Book, language: String, library: LibraryViewModel, window: NSWindow?) -> Bool {
        guard current == nil else { return false }
        let job = TranscriptionJob(id: UUID(), bookID: book.id, bookTitle: book.title, startedAt: Date())
        current = job
        announcingWindow = window
        announcedMilestones = []
        progressShownAt = nil
        transcribedBooks.setTranscribing(book.id)
        VoiceOverAnnouncer.announce(
            TranscriptionWording.started(bookTitle: book.title, audioSeconds: book.audioDuration),
            from: window
        )
        let service = self.service
        let install = self.install
        // Each report is shown on the main actor, as it arrives.
        let report: @Sendable (TranscriptionProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                self?.receive(progress, for: job.id)
            }
        }
        task = Task { [weak self, weak library] in
            let clock = ContinuousClock()
            let started = clock.now
            let ending: TranscriptionJobEnding
            do {
                let transcript = try await service.transcribe(book, language: language, progress: report)
                // The book as the library holds it now: a transcription
                // takes minutes, and the book may have moved meanwhile.
                guard let current = library?.bookByID(book.id) else { throw TranscriptionError.bookRemoved }
                guard !Task.isCancelled else { throw TranscriptionError.cancelled }
                let installation = try await OffMainWork.runThrowing { try install(transcript, current) }
                self?.saved(installation, of: book.id, in: library)
                ending = .finished(wordCount: transcript.wordCount, seconds: Self.seconds(clock.now - started))
            } catch {
                ending = .ending(for: error)
            }
            self?.finish(job, ending)
        }
        return true
    }

    /// Cancels the transcription under way, if any. It stops within a
    /// moment, and the book stays as it was unless its transcript was being
    /// saved already.
    func cancel() {
        task?.cancel()
    }

    // MARK: Progress

    /// Takes `progress`, reported by the transcription `jobID`: announces
    /// each quarter it passes, once, the highest when it passes several at
    /// once, and shows it when enough time has passed since the last
    /// showing, when it moves to another file, or when it is done. A report
    /// arriving after its transcription ended changes nothing.
    private func receive(_ progress: TranscriptionProgress, for jobID: UUID) {
        guard let job = current, job.id == jobID else { return }
        let passed = TranscriptionWording.milestones.filter {
            progress.percentDone >= $0 && !announcedMilestones.contains($0)
        }
        if let highest = passed.max() {
            announcedMilestones.formUnion(passed)
            VoiceOverAnnouncer.announce(
                TranscriptionWording.milestone(bookTitle: job.bookTitle, percent: highest),
                from: announcingWindow,
                priority: .medium
            )
        }
        let now = ContinuousClock.now
        let isDue = progressShownAt.map { now - $0 >= Self.progressInterval } ?? true
        let changesFile = job.progress?.fileIndex != progress.fileIndex
        guard isDue || changesFile || progress.fractionDone >= 1 else { return }
        progressShownAt = now
        current?.progress = progress
    }

    // MARK: The End

    /// Shows the transcript just saved for the book `bookID`, as
    /// `installation` describes it: the library row says the book is
    /// transcribed, and the book's open readers show the text.
    private func saved(_ installation: TranscriptInstallation, of bookID: UUID, in library: LibraryViewModel?) {
        transcribedBooks.record(bookID, isTranscribed: true)
        library?.bookUpdates.transcriptReplaced(bookID: bookID, with: installation.text)
    }

    /// Ends `job` as `ending` says: no transcription is under way any more,
    /// the end is announced, and published for the sheet showing it.
    private func finish(_ job: TranscriptionJob, _ ending: TranscriptionJobEnding) {
        guard current?.id == job.id else { return }
        current = nil
        task = nil
        transcribedBooks.setTranscribing(nil)
        VoiceOverAnnouncer.announce(ending.announcement(bookTitle: job.bookTitle), from: announcingWindow)
        announcingWindow = nil
        lastEnding = TranscriptionJobEndingEvent(job: job, ending: ending)
    }

    /// `duration` in seconds.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
