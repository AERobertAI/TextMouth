import Foundation

// MARK: - Saving a Recording (FR04)

extension LibraryViewModel {
    /// Saves a take, already encoded as `encodedAudio`, as a new audiobook
    /// titled `title` in the library folder `folderPath`, and returns the
    /// book once it is in the library.
    ///
    /// The import runs on the import queue like every other, so it waits
    /// for a data-directory move and its storage work is counted. The
    /// original take goes into the package as `original-take.caf` unless
    /// `policy` keeps none, and the book's origin record says what it is
    /// (`BookOrigin`). The files given stay where they are: the caller
    /// removes them once this returns. Afterwards the original policy is
    /// applied to every audiobook, off the main thread
    /// (`sweepAudioOriginalsInBackground`).
    /// - Throws: the import's failure, an `ImportFailure` naming the step.
    func saveRecording(
        _ take: RecordedTake,
        encodedAudio: URL,
        title: String,
        toFolder folderPath: String,
        policy: AudioOriginalPolicy,
        savedAt: Date = Date()
    ) async throws -> Book {
        let keepsTake = policy != .delete
        let origin = BookOrigin(
            kind: .recording,
            recordedAt: take.startedAt,
            duration: take.duration,
            inputDeviceName: take.deviceName,
            originalTake: keepsTake
                ? BookOrigin.OriginalTake(fileName: BookOrigin.originalTakeFileName, lastEditedAt: savedAt, policyOverride: nil)
                : nil
        )
        let takeToKeep = keepsTake ? take.url : nil
        let book: Book = try await withCheckedThrowingContinuation { continuation in
            enqueueImport { [weak self] in
                do {
                    let imported = try FileImportService.importRecording(
                        audio: encodedAudio,
                        take: takeToKeep,
                        origin: origin,
                        title: title,
                        toFolder: folderPath
                    )
                    // Synchronously, as every import adds its book: before
                    // the import's storage work ends (TODO S04).
                    DispatchQueue.main.sync {
                        guard let self else { return }
                        if self.addBookCheckingDuplicate(imported.book, request: ImportRequest()) {
                            self.save()
                        }
                    }
                    continuation.resume(returning: imported.book)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        DiagnosticLog.event(
            .import,
            "RECORDING_SAVED: \(book.title), \(String(format: "%.1f", take.duration)) seconds, original take "
                + (keepsTake ? "kept" : "not kept")
        )
        sweepAudioOriginalsInBackground()
        return book
    }
}
