import Foundation
import Speech

/// What downloads a language's speech model for transcription (FR05): the
/// system's asset inventory on macOS 26 (`SystemTranscriptionModelInstaller`),
/// or a script in the tests, which never download anything.
///
/// TextMouth downloads a model only when the user presses Download in the
/// Transcribe Audio sheet: nothing else here, in the engine, or in the
/// settings asks for one.
protocol TranscriptionModelInstalling: Sendable {
    /// Downloads and installs the speech model for `locale`, reserving the
    /// language for TextMouth as the system does when it installs one, and
    /// tells `progress` the share done, from 0 to 1, as it goes, on no
    /// particular thread. Cancelling the task that awaits it stops the
    /// download, and nothing is installed.
    /// - Throws: `TranscriptionError.needsNewerSystem` before macOS 26,
    ///   `CancellationError` once cancelled, and the system's own error
    ///   when the download fails.
    func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// The model downloads of this Mac: the asset inventory's installation
/// request on macOS 26 and later, and on earlier systems only the refusal
/// that transcription needs macOS 26.
struct SystemTranscriptionModelInstaller: TranscriptionModelInstalling {
    func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *) else { throw TranscriptionError.needsNewerSystem }
        try await SpeechTranscriberCatalog.downloadModel(for: locale, progress: progress)
    }
}

@available(macOS 26.0, *)
extension SpeechTranscriberCatalog {
    /// Downloads and installs the model a transcriber for `locale` needs,
    /// through the asset inventory's installation request, reporting its
    /// share done to `progress`. A model already installed has no request,
    /// and is reported done at once. Cancelling the task cancels the
    /// request's progress, which stops the download.
    static func downloadModel(for locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [makeTranscriber(for: locale)])
        else {
            progress(1)
            return
        }
        // The request's progress has no size before the download starts,
        // so it is read every quarter second rather than observed: the
        // share done rises from 0 once the system knows the size.
        let reporter = Task {
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        defer { reporter.cancel() }
        try await withTaskCancellationHandler {
            try await request.downloadAndInstall()
        } onCancel: {
            request.progress.cancel()
        }
        try Task.checkCancellation()
        progress(1)
    }
}
