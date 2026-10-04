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
/// before the transcript is saved leaves the book as it was. Its end is
/// announced from the window that started it, and published
/// (`lastEnding`) for the sheet showing it.
@MainActor
final class TranscriptionJobCenter: ObservableObject {
    /// The app's center, transcribing with this Mac's engine.
    static let shared = TranscriptionJobCenter()

    /// The transcription under way, or nil.
    @Published private(set) var current: TranscriptionJob?
    /// How the latest transcription ended, or nil before any has.
    @Published private(set) var lastEnding: TranscriptionJobEndingEvent?

    /// What transcribes the books.
    private let service: TranscriptionService
    /// What saves a transcript into its book, off the main thread.
    private let install: @Sendable (Transcript, Book) throws -> TranscriptInstallation
    /// The task running the transcription under way.
    private var task: Task<Void, Never>?
    /// The window that started the transcription under way, where its end
    /// is announced from.
    private weak var announcingWindow: NSWindow?

    /// A center transcribing with `service` and saving with `install`: the
    /// app's own unless a test passes others.
    init(
        service: TranscriptionService = .shared,
        install: @escaping @Sendable (Transcript, Book) throws -> TranscriptInstallation = {
            try TranscriptStore.install($0, for: $1)
        }
    ) {
        self.service = service
        self.install = install
    }

    /// Starts transcribing `book` in `language`, a locale identifier the
    /// Transcribe Audio sheet resolved, saving the transcript into the book
    /// as `library` holds it once the audio is transcribed, and announcing
    /// the end from `window`.
    /// - Returns: Whether it started: false while another transcription is
    ///   under way, which the sheet says before Transcribe is offered.
    @discardableResult
    func start(_ book: Book, language: String, library: LibraryViewModel, window: NSWindow?) -> Bool {
        guard current == nil else { return false }
        let job = TranscriptionJob(id: UUID(), bookID: book.id, bookTitle: book.title, startedAt: Date())
        current = job
        announcingWindow = window
        let service = self.service
        let install = self.install
        task = Task { [weak self, weak library] in
            let clock = ContinuousClock()
            let started = clock.now
            let ending: TranscriptionJobEnding
            do {
                let transcript = try await service.transcribe(book, language: language)
                // The book as the library holds it now: a transcription
                // takes minutes, and the book may have moved meanwhile.
                guard let current = library?.bookByID(book.id) else { throw TranscriptionError.bookRemoved }
                guard !Task.isCancelled else { throw TranscriptionError.cancelled }
                _ = try await OffMainWork.runThrowing { try install(transcript, current) }
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

    /// Ends `job` as `ending` says: no transcription is under way any more,
    /// the end is announced, and published for the sheet showing it.
    private func finish(_ job: TranscriptionJob, _ ending: TranscriptionJobEnding) {
        guard current?.id == job.id else { return }
        current = nil
        task = nil
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
