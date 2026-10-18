import AVFoundation
import Foundation
import Speech

// MARK: - The Engine

/// The language a transcription will use and the model behind it, as the
/// engine resolved them before reading any audio.
struct TranscriptionModelInfo: Equatable, Sendable {
    /// The locale the model serves, as a BCP 47 identifier ("en-GB").
    var locale: String
    /// The recognizer and what the system reported about its model.
    var model: TranscriptSpeechModel
}

/// What turns audio files into transcript sentences: SpeechAnalyzer's
/// SpeechTranscriber on macOS 26 (`SystemTranscriptionEngine`), or a script
/// in the tests.
protocol TranscriptionEngine: Sendable {
    /// Checks that `locale` can be transcribed now, without downloading or
    /// reserving anything, and names the locale and model that will be used.
    /// - Throws: `TranscriptionError` saying why not: a system older than
    ///   macOS 26, a Mac that cannot run the model, a language the
    ///   recognizer does not support, or a model not yet on this Mac.
    func prepare(locale: Locale) async throws -> TranscriptionModelInfo

    /// The sentences spoken in the audio file at `url`, in `locale` (as
    /// `prepare(locale:)` resolved it), in order, timed from the file's
    /// start. `progress` is told, as results arrive, how many seconds of
    /// the file are transcribed. Cancelling the task stops the work within
    /// a moment, throwing `TranscriptionError.cancelled`.
    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscriptSentence]
}

/// The engine of this Mac: SpeechAnalyzer's SpeechTranscriber on macOS 26
/// and later, and on earlier systems only the refusal that transcription
/// needs macOS 26.
struct SystemTranscriptionEngine: TranscriptionEngine {
    func prepare(locale: Locale) async throws -> TranscriptionModelInfo {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsNewerSystem }
        return try await SpeechAnalyzerEngine().prepare(locale: locale)
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscriptSentence] {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsNewerSystem }
        return try await SpeechAnalyzerEngine().transcribe(fileAt: url, locale: locale, progress: progress)
    }
}

// MARK: - SpeechAnalyzer

/// Transcription with SpeechAnalyzer and its SpeechTranscriber module, the
/// recognizer macOS 26 made for long-form narration. The model runs in a
/// system service, outside TextMouth's memory, and no permission is asked:
/// Apple's permission covers SFSpeechRecognizer only.
///
/// Each file is handed to the analyzer as an `AVAudioFile`, which the
/// analyzer reads and converts to its model's format itself, so no audio
/// buffer crosses between tasks here. Results are gathered on a task of
/// their own while the file is analyzed, and only final results are asked
/// for. The model is kept loaded a while after each file (`lingering`), so
/// the next file of the book does not wait for it again.
@available(macOS 26.0, *)
struct SpeechAnalyzerEngine: TranscriptionEngine {
    /// The name transcript.json gives the recognizer.
    static let engineName = "SpeechTranscriber"

    func prepare(locale: Locale) async throws -> TranscriptionModelInfo {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailableOnThisMac }
        switch await TranscriptionAvailability.modelStatus(for: locale) {
        case .unsupported:
            throw TranscriptionError.unsupportedLanguage(TranscriptionLanguage.name(of: locale.identifier(.bcp47)))
        case .needsDownload(let supported), .downloading(let supported):
            throw TranscriptionError.modelNotInstalled(TranscriptionLanguage.name(of: supported.identifier(.bcp47)))
        case .installed(let supported):
            let status = await SpeechTranscriberCatalog.assetStatus(for: supported)
            return TranscriptionModelInfo(
                locale: supported.identifier(.bcp47),
                model: TranscriptSpeechModel(
                    engine: Self.engineName,
                    assetStatus: SpeechTranscriberCatalog.describe(status),
                    systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
                )
            )
        }
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscriptSentence] {
        do {
            return try await transcribeOnce(fileAt: url, locale: locale, progress: progress)
        } catch let error as SFSpeechError where error.code == .assetLocaleNotAllocated {
            // The system wants the language reserved for TextMouth before
            // its installed model is used, as macOS 26 warns it will: the
            // reservation downloads nothing, and the file is tried once more.
            _ = try? await AssetInventory.reserve(locale: locale)
            do {
                return try await transcribeOnce(fileAt: url, locale: locale, progress: progress)
            } catch {
                throw Self.transcriptionError(for: error, fileName: url.lastPathComponent)
            }
        } catch {
            throw Self.transcriptionError(for: error, fileName: url.lastPathComponent)
        }
    }

    /// Transcribes the file at `url` once, as `transcribe` describes,
    /// throwing whatever stopped it as it came.
    private func transcribeOnce(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscriptSentence] {
        try Task.checkCancellation()
        let transcriber = SpeechTranscriberCatalog.makeTranscriber(for: locale)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        let languageCode = locale.language.languageCode?.identifier

        // Results arrive on their own sequence while the file is analyzed,
        // so a task of their own gathers them until the analyzer finishes.
        let gatherer = Task { () throws -> [TranscriptSentence] in
            var builder = TranscriptSentenceBuilder(languageCode: languageCode)
            for try await result in transcriber.results where result.isFinal {
                let transcribed = TranscribedResult(result)
                builder.add(transcribed)
                progress(transcribed.end)
            }
            return builder.sentences
        }

        do {
            try await withTaskCancellationHandler {
                try await Self.analyze(fileAt: url, with: analyzer)
            } onCancel: {
                // Stops the analysis at once; its results end with it.
                Task { await analyzer.cancelAndFinishNow() }
            }
            let sentences = try await gatherer.value
            try Task.checkCancellation()
            return sentences
        } catch {
            // The analysis stopped early: finish it, so its results end,
            // and let the gatherer end with them before passing on why.
            await analyzer.cancelAndFinishNow()
            gatherer.cancel()
            _ = try? await gatherer.value
            throw error
        }
    }

    /// Hands the file at `url` to `analyzer` and ends the analysis at its
    /// last sample, so its final results are reported and its results end.
    private static func analyze(fileAt url: URL, with analyzer: SpeechAnalyzer) async throws {
        let audioFile: AVAudioFile
        do {
            // Never decode a format the import converts (B09, FMT09): Apple's
            // Vorbis decoder once spun forever. Such audio is converted in a
            // child process first.
            guard !ImportAudioConverter.isNeverDecodedInApp(url) else { throw CocoaError(.fileReadCorruptFile) }
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            throw TranscriptionError.unreadableFile(file: url.lastPathComponent, reason: TranscriptionError.unreadableAudioReason)
        }
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            // The file holds no audio at all: there is nothing to finalize.
            await analyzer.cancelAndFinishNow()
        }
    }

    /// `error`, from transcribing the file named `fileName`, as the error
    /// a transcription reports: a cancellation, a reason of its own, or
    /// the recognizer's failure in plain words.
    private static func transcriptionError(for error: Error, fileName: String) -> TranscriptionError {
        if let transcriptionError = error as? TranscriptionError {
            return transcriptionError
        }
        if error is CancellationError || Task.isCancelled {
            return .cancelled
        }
        if let speechError = error as? SFSpeechError {
            // The codes macOS 26 added are values of the code, not cases of
            // it, so they are compared rather than switched on.
            let code = speechError.code
            if code == .noModel {
                return .recognitionFailed("the speech model for the language is not on this Mac")
            }
            if code == .insufficientResources {
                return .recognitionFailed("the speech recognizer is busy with other work; try again in a moment")
            }
            if code == .assetLocaleNotAllocated || code == .tooManyAssetLocalesAllocated {
                return .recognitionFailed("the system did not let TextMouth use the language's speech model")
            }
            if [.audioDisordered, .unexpectedAudioFormat, .incompatibleAudioFormats].contains(code) {
                return .unreadableFile(file: fileName, reason: TranscriptionError.unreadableAudioReason)
            }
            return .recognitionFailed("the speech recognizer stopped with error \(code.rawValue)")
        }
        let nsError = error as NSError
        return .recognitionFailed("the speech recognizer stopped with error \(nsError.code) in \(nsError.domain)")
    }
}

@available(macOS 26.0, *)
extension TranscribedResult {
    /// The result `result` holds: its stretch of the file and each run of
    /// its text, with the run's stretch of the audio when the recognizer
    /// gave one that is valid and numeric, and its confidence.
    init(_ result: SpeechTranscriber.Result) {
        let text = result.text
        let pieces = text.runs.map { run -> TranscribedPiece in
            var piece = TranscribedPiece(
                text: String(text[run.range].characters),
                confidence: run.transcriptionConfidence
            )
            if let range = run.audioTimeRange, range.isValid, range.start.isNumeric, range.duration.isNumeric {
                piece.start = range.start.seconds
                piece.end = range.end.seconds
            }
            return piece
        }
        let range = result.range
        let isNumeric = range.isValid && range.start.isNumeric && range.duration.isNumeric
        self.init(
            start: isNumeric ? range.start.seconds : (pieces.compactMap(\.start).first ?? 0),
            end: isNumeric ? range.end.seconds : (pieces.compactMap(\.end).last ?? 0),
            pieces: pieces
        )
    }
}
