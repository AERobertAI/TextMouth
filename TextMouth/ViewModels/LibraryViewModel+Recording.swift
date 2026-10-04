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
    /// removes them once this returns. Afterwards the original-take policy
    /// is applied to every recording, off the main thread.
    /// - Throws: the import's failure, an `ImportFailure` naming the step.
    func saveRecording(
        _ take: RecordedTake,
        encodedAudio: URL,
        title: String,
        toFolder folderPath: String,
        policy: RecordingOriginalPolicy,
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
        sweepRecordingTakesInBackground()
        return book
    }

    // MARK: - The Original-Take Policy

    /// Applies the original-take policy to every recording in the library
    /// (`RecordingTakeSweep`), at `now`, on a background queue as storage
    /// work, and hands what it did to `completion` there. Does nothing
    /// while the data directory can't be used. The library runs it at
    /// launch and after each recording is saved; tests call it with a clock
    /// of their own.
    func sweepRecordingTakesInBackground(
        now: Date = Date(),
        completion: (@Sendable (RecordingTakeSweep.Result) -> Void)? = nil
    ) {
        guard dataDirectoryUnavailability == nil else { return }
        // Where each audiobook's package is, by folder and package name:
        // its full path is taken inside the storage work, under the data
        // directory current then, which a move may have changed meanwhile.
        let places = library.books
            .filter { $0.format.isAudio && !$0.tmbDirectoryName.isEmpty }
            .map { RecordingPackagePlace(folderPath: $0.folderPath, tmbDirectoryName: $0.tmbDirectoryName) }
        let global = RecordingOriginalPolicy.global(in: TextMouthRuntime.current.preferences)
        DispatchQueue.global(qos: .utility).async {
            let result = StorageBoundary.shared.perform(.recordingTakes) { _ in
                RecordingTakeSweep.sweep(
                    packages: places.map { TextMouthPaths.tmbPath(folderPath: $0.folderPath, tmbName: $0.tmbDirectoryName) },
                    global: global,
                    now: now
                )
            }
            completion?(result)
        }
    }
}

/// Where an audiobook's package is in the library: its folder and its
/// package's name, the two parts that do not change with the data
/// directory's location.
private struct RecordingPackagePlace: Sendable {
    let folderPath: String
    let tmbDirectoryName: String
}
