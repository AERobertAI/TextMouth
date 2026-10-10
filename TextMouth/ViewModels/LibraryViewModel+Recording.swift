import Foundation

// MARK: - Saving a Recording (FR04)

extension LibraryViewModel {
    /// Saves a take, already encoded as `encodedAudio`, as a new audiobook
    /// titled `title` in the library folder `folderPath`, and returns the
    /// book once it is in the library.
    ///
    /// The import runs on the import queue like every other, so it waits
    /// for a data-directory move and its storage work is counted, and the
    /// import overlay names the recording by its title with the step it is
    /// at, as it names New from Text's book (FR10); it showed "Importing
    /// Books" with no book until October 10, 2026 (REV13). The overlay's
    /// line goes quietly once the save ends, however it ends, since the
    /// Recording window says how. The original take goes into the package
    /// as `original-take.caf` unless `policy` keeps none, and the book's
    /// origin record says what it is (`BookOrigin`). The files given stay
    /// where they are: the caller removes them once this returns.
    /// Afterwards the original policy is applied to every audiobook, off
    /// the main thread (`sweepAudioOriginalsInBackground`).
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
        let queue = importOperationQueue
        let progress = importProgress
        let book: Book = try await withCheckedThrowingContinuation { continuation in
            enqueueImport { [weak self] in
                do {
                    // The overlay names the recording by its title, and the
                    // step it is at, from creating its package on.
                    let imported = try FileImportService.importRecording(
                        audio: encodedAudio,
                        take: takeToKeep,
                        origin: origin,
                        title: title,
                        toFolder: folderPath,
                        observer: progress.observeBook(title, startingAt: .preparingPackage, then: queue.stepObserver)
                    )
                    // Synchronously, as every import adds its book: before
                    // the import's storage work ends (TODO S04).
                    DispatchQueue.main.sync {
                        progress.clear()
                        guard let self else { return }
                        if self.addBookCheckingDuplicate(imported.book, request: ImportRequest()) {
                            self.save()
                        }
                    }
                    continuation.resume(returning: imported.book)
                } catch {
                    // After the overlay's own updates, which went before.
                    DispatchQueue.main.async { progress.clear() }
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
