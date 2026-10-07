import Foundation

extension FileImportService {
    /// Imports a recording as a new audiobook, staged like every import
    /// (`importText` is its model): the encoded audio, the original take
    /// when one is kept, and the book's origin record are copied into a
    /// hidden package, the audio is read as the reader will read it, and the
    /// package is published only once its bookInfo.json reads back. The book
    /// then plays, keeps bookmarks and checkpoints, and syncs like any other
    /// audiobook.
    ///
    /// The files given are copied, not moved, so a failure leaves them where
    /// they were, and the take is never lost; the caller removes them once
    /// the book is in the library.
    /// - Parameters:
    ///   - audio: The take encoded as an M4A file (`RecordingEncoder`).
    ///   - take: The take's PCM file, kept in the package as
    ///     `original-take.caf`; nil when the policy keeps no original.
    ///   - origin: The book's origin record, written as origin.json.
    ///   - title: The book's title, already resolved for display.
    ///   - observer: Told as each step on the staged package begins.
    /// - Throws: an `ImportFailure` naming the audio file and the step that
    ///   failed; whatever was staged is removed first.
    static func importRecording(
        audio: URL,
        take: URL?,
        origin: BookOrigin,
        title: String,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        let fileName = TextImportPolicy.fileName(for: title, extension: "m4a")
        return try ImportRun.perform(importing: fileName, observer: observer) { run in
            let bookID = UUID()
            let dateAdded = Date()
            let author = Self.recordingAuthor

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: title,
                author: author,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let stagedAudio = staging.directory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: audio, to: stagedAudio)
            if let take {
                try FileManager.default.copyItem(
                    at: take,
                    to: staging.directory.appendingPathComponent(BookOrigin.originalTakeFileName)
                )
            }
            try origin.save(toPackage: staging.directory)
            let hash = try md5Hash(of: stagedAudio)

            let staged = Book(
                id: bookID,
                title: title,
                author: author,
                format: .audio,
                filePath: stagedAudio.path,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                tmbDirectoryName: staging.name
            )
            return try publishReadableBook(staged, from: staging, run: &run)
        }
    }

    /// The author a recording is listed under: unknown, as for any book
    /// whose author no one entered, until the user edits it.
    static let recordingAuthor = Book.unknownAuthor
}
