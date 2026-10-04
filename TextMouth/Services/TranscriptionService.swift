import AVFoundation
import Foundation

// MARK: - Errors

/// Why a transcription could not run or did not finish, in words a listener
/// understands, the same on screen, in VoiceOver, and in braille.
enum TranscriptionError: LocalizedError, Equatable {
    /// The system is older than macOS 26, which transcription needs.
    case needsNewerSystem
    /// The system is new enough, but this Mac cannot run the speech model.
    case unavailableOnThisMac
    /// The recognizer cannot transcribe the language named.
    case unsupportedLanguage(String)
    /// The speech model for the language named is not on this Mac yet.
    case modelNotInstalled(String)
    /// The book titled is being transcribed already: one transcription runs
    /// at a time.
    case busy(String)
    /// The book is not an audiobook.
    case notAnAudiobook
    /// The audiobook has no audio file to transcribe.
    case noAudio
    /// The audio file named, by its place in the book, is only in the
    /// cloud, and reading it would download it.
    case fileInCloud(String)
    /// The audio file named, by its place in the book, cannot be read, for
    /// the reason given.
    case unreadableFile(file: String, reason: String)
    /// The transcription was cancelled.
    case cancelled
    /// The recognizer failed, for the reason given.
    case recognitionFailed(String)
    /// A file of the book is not the one transcribed any more, for the
    /// reason given, so the transcript was not saved.
    case audioChanged(String)
    /// The book left the library while it was being transcribed, so its
    /// transcript was not saved.
    case bookRemoved

    /// Why an audio file that the system cannot open or decode cannot be
    /// read, worded as playback words a damaged file.
    static let unreadableAudioReason = "it is damaged, unreadable, or not an audio file"

    var errorDescription: String? {
        switch self {
        case .needsNewerSystem:
            return "Transcription needs macOS 26 or later."
        case .unavailableOnThisMac:
            return "This Mac can't run the speech model that transcription uses."
        case .unsupportedLanguage(let language):
            return "Transcription doesn't support \(language)."
        case .modelNotInstalled(let language):
            return "The speech model for \(language) isn't on this Mac yet. It needs to be downloaded first."
        case .busy(let title):
            return "TextMouth is already transcribing \(title). Try again when that finishes."
        case .notAnAudiobook:
            return "Only audiobooks can be transcribed."
        case .noAudio:
            return "This audiobook has no audio to transcribe."
        case .fileInCloud(let file):
            return "“\(file)” is only in the cloud. Download the book, then transcribe it."
        case .unreadableFile(let file, let reason):
            return "“\(file)” couldn't be read: \(reason)."
        case .cancelled:
            return "Transcription was cancelled."
        case .recognitionFailed(let reason):
            return "Transcription stopped: \(reason)."
        case .audioChanged(let reason):
            return "The book's audio changed while it was being transcribed: \(reason). Transcribe it again."
        case .bookRemoved:
            return "The book left the library while it was being transcribed, so its transcript wasn't saved."
        }
    }
}

// MARK: - Progress

/// How far a transcription has come: which of the book's files it is on,
/// how much of the book's audio is transcribed, and how long it has run.
struct TranscriptionProgress: Equatable, Sendable {
    /// The file being transcribed, counting from 0, in the order the book
    /// plays its files; `fileCount` once every file is done.
    var fileIndex: Int
    /// How many audio files the book has.
    var fileCount: Int
    /// Seconds of the book's audio transcribed so far.
    var secondsDone: TimeInterval
    /// Seconds of audio the book holds in all.
    var secondsTotal: TimeInterval
    /// Seconds since the transcription began, the time the system took to
    /// load its model included.
    var elapsed: TimeInterval

    /// The share of the book's audio transcribed, from 0 to 1.
    var fractionDone: Double {
        guard secondsTotal > 0 else { return fileIndex >= fileCount ? 1 : 0 }
        return min(1, max(0, secondsDone / secondsTotal))
    }

    /// The whole percent of the book's audio transcribed, rounded down, so
    /// 100 means done.
    var percentDone: Int {
        Int((fractionDone * 100).rounded(.down))
    }
}

// MARK: - The Audio of a Book

/// The audio a transcription reads: each of a book's audio files, once, in
/// the order the book first plays them, each measured and fingerprinted
/// before any is transcribed, so a file that changes while the book is
/// transcribed is noticed when the transcript is saved.
struct TranscriptionPlan: Equatable, Sendable {
    /// One audio file of the book.
    struct File: Equatable, Sendable {
        /// The file's path relative to the book's audio folder, as the
        /// book's content index names it, or, for a book of one file, its
        /// name (`TranscriptFile.path`).
        let path: String
        /// Where the file is.
        let url: URL
        /// How long the file plays, in seconds.
        let duration: TimeInterval
        /// The file's size, modification time, and digest now.
        let fingerprint: FileFingerprint
    }

    /// The book's audio files, in the order the book first plays them.
    let files: [File]

    /// Seconds of audio the book holds in all.
    var totalDuration: TimeInterval {
        files.reduce(0) { $0 + $1.duration }
    }

    /// The plan for `book`, whose audio its content index describes: the
    /// index saved in its package when that is sound, otherwise one made by
    /// analyzing the audio, as opening the book makes it. Blocks while it
    /// reads; run it off the main thread.
    /// - Throws: `TranscriptionError` for a book that is not an audiobook,
    ///   has no audio, or has a file only in the cloud or unreadable.
    static func make(
        for book: Book,
        isDataless: (URL) -> Bool = DatalessFiles.isDataless,
        measure: (URL) throws -> TimeInterval = Self.duration(ofAudioFileAt:),
        hasher: FingerprintHasher = .md5
    ) throws -> TranscriptionPlan {
        guard book.format.isAudio else { throw TranscriptionError.notAnAudiobook }
        let index = try BookContentAnalysisService.load(book: book).index
        return try make(for: book, index: index, isDataless: isDataless, measure: measure, hasher: hasher)
    }

    /// The plan for `book`, whose content index is `index`.
    static func make(
        for book: Book,
        index: BookContentIndex,
        isDataless: (URL) -> Bool,
        measure: (URL) throws -> TimeInterval,
        hasher: FingerprintHasher
    ) throws -> TranscriptionPlan {
        let locations = audioFileLocations(of: book, index: index)
        guard !locations.isEmpty else { throw TranscriptionError.noAudio }
        // Nothing is read from a file only in the cloud: every file is
        // checked before any is measured.
        if let inCloud = locations.first(where: { isDataless($0.url) }) {
            throw TranscriptionError.fileInCloud(inCloud.path)
        }
        return TranscriptionPlan(files: try locations.map { path, url in
            // Stamped and hashed before measuring: a file that changes
            // while the book is transcribed then differs from its
            // fingerprint when the transcript is saved.
            guard let fingerprint = FileFingerprint(of: url, hasher: hasher),
                  let duration = try? measure(url), duration.isFinite, duration >= 0 else {
                throw TranscriptionError.unreadableFile(file: path, reason: TranscriptionError.unreadableAudioReason)
            }
            return File(path: path, url: url, duration: duration, fingerprint: fingerprint)
        })
    }

    /// Each audio file `book` plays, once, in the order it first plays
    /// them, with the path a transcript names it by: a single-file book's
    /// own file by its name, and a folder's files by their paths inside it,
    /// as its content index records them.
    static func audioFileLocations(of book: Book, index: BookContentIndex) -> [(path: String, url: URL)] {
        guard let paths = index.audioFilesInPlayingOrder else {
            return [(path: book.bookFileURL.lastPathComponent, url: book.bookFileURL)]
        }
        let folder = URL(fileURLWithPath: book.filePath, isDirectory: true)
        return paths.map { (path: $0, url: folder.appendingPathComponent($0)) }
    }

    /// How long the audio file at `url` plays, in seconds, as AVFoundation
    /// reads it for the recognizer.
    static func duration(ofAudioFileAt url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }
}

extension BookContentIndex {
    /// The audio files an audiobook's chapters play, each once, in the
    /// order the book first plays them, by their paths inside its audio
    /// folder: every clip's file of a segmented book, and every chapter's
    /// file of a multi-file book. Nil for a book of one file, whose chapters
    /// name none, and for a text book.
    var audioFilesInPlayingOrder: [String]? {
        guard kind == .audio, audioLayout?.namesChapterFiles == true else { return nil }
        var seen = Set<String>()
        var files: [String] = []
        for chapter in chapters {
            let paths = chapter.audio?.clips?.compactMap(\.audioFilePath) ?? chapter.audioFilePath.map { [$0] } ?? []
            for path in paths where seen.insert(path).inserted {
                files.append(path)
            }
        }
        return files
    }
}

// MARK: - The Service

/// Transcribes audiobooks (FR05): reads a book's audio files in the order it
/// plays them, has the recognizer transcribe each, and returns the
/// `Transcript` (`transcribe`), writing nothing, or saves it as the book's
/// text once it is done (`transcribeAndSave`, through
/// `TranscriptStore.install`).
///
/// One transcription runs at a time in the app: a second asked for while
/// one runs is refused (`TranscriptionError.busy`). The work runs off the
/// main actor, on this actor, the recognizer's tasks, and a background queue
/// for the reads that block (`OffMainWork`). Progress is reported as the
/// recognizer's results arrive, every few seconds of audio. Cancelling the
/// task that awaits a transcription stops it within a moment, throwing
/// `TranscriptionError.cancelled`, and leaves nothing behind, since nothing
/// is written until the transcript is saved.
actor TranscriptionService {
    /// The app's service, transcribing with this Mac's engine.
    static let shared = TranscriptionService()

    /// What transcribes each file.
    private let engine: any TranscriptionEngine
    /// What lists and measures a book's audio files; blocks while it reads.
    private let planner: @Sendable (Book) throws -> TranscriptionPlan
    /// The languages to try for a transcription asked for in no particular
    /// language (`TranscriptionLanguage.languagesToTry(in:)`).
    private let languagesToTry: @Sendable () -> [String]
    /// The title of the book being transcribed, while one is.
    private var titleUnderWay: String?

    /// A service transcribing with `engine`, planning with `planner`, and
    /// reading the language setting through `languagesToTry`; the app's
    /// own unless a test passes others.
    init(
        engine: any TranscriptionEngine = SystemTranscriptionEngine(),
        planner: @escaping @Sendable (Book) throws -> TranscriptionPlan = { try TranscriptionPlan.make(for: $0) },
        languagesToTry: @escaping @Sendable () -> [String] = {
            TranscriptionLanguage.languagesToTry(in: TextMouthRuntime.current.preferences)
        }
    ) {
        self.engine = engine
        self.planner = planner
        self.languagesToTry = languagesToTry
    }

    /// Whether a transcription is under way.
    var isTranscribing: Bool {
        titleUnderWay != nil
    }

    /// Transcribes `book`'s audio in `language`, a locale identifier, or,
    /// when nil, in the language the setting chooses, and returns the
    /// transcript. Writes nothing.
    ///
    /// The language and its model are checked before any audio is read; a
    /// language nobody chose, the system's English, gives way to US English
    /// when the recognizer does not support it. `progress` is told where the
    /// transcription is, as it starts each file, as results arrive, and once
    /// it is done; it is called on no particular thread.
    /// - Throws: `TranscriptionError` naming why the book could not be
    ///   transcribed, `.cancelled` when the task was cancelled, and `.busy`
    ///   while another book is being transcribed.
    func transcribe(
        _ book: Book,
        language: String? = nil,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> Transcript {
        try beginTranscribing(book)
        defer { titleUnderWay = nil }
        return try await transcription(of: book, language: language, progress: progress)
    }

    /// Transcribes `book` and saves the transcript as its text: the whole
    /// job the Transcribe Audio command runs (FR05). The transcription is
    /// `transcribe(_:language:progress:)`'s. Once it is done, `currentBook`
    /// gives the book as the library holds it then, since the book may have
    /// moved meanwhile, and the transcript is saved into it off the main
    /// thread (`TranscriptStore.install`). Both happen while this service
    /// counts as busy, so no other transcription starts in between; a
    /// cancellation before the transcript is saved leaves the book as it was.
    /// - Throws: what `transcribe` throws; `.bookRemoved` when the book left
    ///   the library meanwhile (`currentBook` gives nil); and what saving the
    ///   transcript throws (`TranscriptStore.install`).
    func transcribeAndSave(
        _ book: Book,
        language: String? = nil,
        currentBook: @escaping @Sendable () async -> Book?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void = { _ in }
    ) async throws -> TranscriptInstallation {
        try beginTranscribing(book)
        defer { titleUnderWay = nil }
        let transcript = try await transcription(of: book, language: language, progress: progress)
        guard let current = await currentBook() else { throw TranscriptionError.bookRemoved }
        guard !Task.isCancelled else { throw TranscriptionError.cancelled }
        return try await OffMainWork.runThrowing { try TranscriptStore.install(transcript, for: current) }
    }

    /// Marks `book` as the one being transcribed.
    /// - Throws: `TranscriptionError.busy` while another book is.
    private func beginTranscribing(_ book: Book) throws {
        if let titleUnderWay {
            throw TranscriptionError.busy(titleUnderWay)
        }
        titleUnderWay = book.title
    }

    /// The work of `transcribe(_:language:progress:)`, once the book is
    /// marked as the one being transcribed.
    private func transcription(
        of book: Book,
        language: String?,
        progress: @escaping @Sendable (TranscriptionProgress) -> Void
    ) async throws -> Transcript {
        do {
            try Task.checkCancellation()
            let clock = ContinuousClock()
            let started = clock.now
            let model = try await preparedModel(for: language.map { [$0] } ?? languagesToTry())
            let planner = self.planner
            let plan = try await OffMainWork.runThrowing { try planner(book) }

            let total = plan.totalDuration
            var files: [TranscriptFile] = []
            var secondsBefore: TimeInterval = 0
            for (number, file) in plan.files.enumerated() {
                try Task.checkCancellation()
                let base = secondsBefore
                let report = { @Sendable (fileSeconds: TimeInterval) in
                    progress(TranscriptionProgress(
                        fileIndex: number,
                        fileCount: plan.files.count,
                        secondsDone: base + min(max(0, fileSeconds), file.duration),
                        secondsTotal: total,
                        elapsed: Self.seconds(clock.now - started)
                    ))
                }
                report(0)
                let sentences = try await engine.transcribe(
                    fileAt: file.url,
                    locale: Locale(identifier: model.locale),
                    progress: report
                )
                files.append(TranscriptFile(
                    path: file.path,
                    fingerprint: file.fingerprint,
                    durationMilliseconds: Transcript.milliseconds(file.duration),
                    sentences: sentences
                ))
                secondsBefore += file.duration
            }
            try Task.checkCancellation()
            progress(TranscriptionProgress(
                fileIndex: plan.files.count,
                fileCount: plan.files.count,
                secondsDone: total,
                secondsTotal: total,
                elapsed: Self.seconds(clock.now - started)
            ))
            return Transcript(
                version: Transcript.currentVersion,
                locale: model.locale,
                model: model.model,
                app: .current,
                // Whole seconds, as transcript.json keeps its dates.
                createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                files: files
            )
        } catch let error as TranscriptionError {
            throw error
        } catch is CancellationError {
            throw TranscriptionError.cancelled
        } catch {
            throw TranscriptionError.recognitionFailed(error.localizedDescription)
        }
    }

    /// The model of the first of `languages` the engine can transcribe
    /// now. A language the recognizer does not support gives way to the
    /// next; any other refusal, such as a model not yet installed, is
    /// reported at once, as is the last language's refusal.
    private func preparedModel(for languages: [String]) async throws -> TranscriptionModelInfo {
        for language in languages.dropLast() {
            do {
                return try await engine.prepare(locale: Locale(identifier: language))
            } catch TranscriptionError.unsupportedLanguage(_) {
                continue
            }
        }
        let last = languages.last ?? TranscriptionLanguage.defaultIdentifier
        return try await engine.prepare(locale: Locale(identifier: last))
    }

    /// `duration` in seconds.
    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
