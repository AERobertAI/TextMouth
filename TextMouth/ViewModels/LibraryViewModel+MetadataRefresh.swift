import Foundation

// MARK: - The Metadata Refresh

/// What the metadata refresh read of one book: the author its file names
/// now, on its way to the book's row.
struct MetadataReading: Sendable {
    let bookID: UUID
    /// The author the file names, or the placeholder when it names no one,
    /// or was not opened because its format keeps no metadata in the file.
    let author: String
}

/// The launch pass that reads a book's file again for its author when an
/// older metadata reader read it (`Book.metadataReaderVersion`).
extension LibraryViewModel {

    /// Whether the refresh reads `book`'s file again: its row was stamped by
    /// an older reader than `ImportedFileMetadata.readerVersion`, or by
    /// none, as every row was before readers were versioned.
    nonisolated static func needsMetadataRefresh(_ book: Book) -> Bool {
        SemanticVersion.isOutdated(stored: book.metadataReaderVersion, current: ImportedFileMetadata.readerVersion)
    }

    /// The author the refresh gives a row whose author is `current` when its
    /// file names `read`, or nil to keep `current`. Only the placeholder is
    /// replaced, and only by a name: an author typed by hand is never the
    /// placeholder, so the refresh never replaces one, and a file that still
    /// names no one changes nothing.
    nonisolated static func refreshedAuthor(current: String, read: String) -> String? {
        guard Book.isUnknownAuthor(current), !Book.isUnknownAuthor(read) else { return nil }
        return read
    }

    /// Reads again, off the main thread, the file of every book an older
    /// reader read (`needsMetadataRefresh(_:)`), with the reader imports use
    /// (`ImportedFileMetadata.read`), and then gives the rows what was read
    /// in one change of the library and one save
    /// (`applyMetadataReadings(_:)`): the author, where a row lists the
    /// placeholder and its file now names one, and the reader's version on
    /// every row read. Runs at launch before the text cache batch, and takes
    /// a few seconds for several hundred books.
    ///
    /// Each read is storage work (TODO S04): a data-directory move waits
    /// for the one under way and holds the rest until it has published, and
    /// a book listed before the move is then read in the new data directory.
    /// A book whose files are in the cloud is left as it is, unstamped, and
    /// counted in the pass's one `MAINTENANCE_SKIPPED_IN_CLOUD` line (FR02),
    /// to be read once its files are on this Mac.
    /// - Parameters:
    ///   - access: How the pass reaches the books' files: `live` in the app;
    ///     tests pass one that pretends files are in the cloud.
    ///   - completion: Called on the main actor once the pass has ended and
    ///     the rows have what it read.
    func refreshOutdatedMetadata(
        access: MaintenanceFileAccess = .live,
        then completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let books = library.books.filter(Self.needsMetadataRefresh)
        // A second scene must not start the same pass again: the pass under
        // way reads every row the second would have.
        guard !isRefreshingMetadata, !books.isEmpty else {
            completion?()
            return
        }
        isRefreshingMetadata = true
        DispatchQueue.global(qos: .utility).async {
            let boundary = StorageBoundary.shared
            let skips = CloudSkips(.metadataRefresh)
            var readings: [MetadataReading] = []
            for listed in books {
                let reading = autoreleasepool {
                    boundary.perform(.metadataRefresh) { _ in
                        // The book as listed when the pass began, with its
                        // paths in the data directory in use now.
                        Self.readMetadataAgain(of: boundary.rebasedToCurrent(listed), access: access, skips: skips)
                    }
                }
                if let reading {
                    readings.append(reading)
                }
            }
            skips.log()
            let read = readings
            DispatchQueue.main.async { [weak self] in
                self?.applyMetadataReadings(read)
                self?.isRefreshingMetadata = false
                completion?()
            }
        }
    }

    /// The author `book`'s file names now, read on the pass's thread with
    /// the reader imports use, or nil when the book is left as it is: its
    /// file is missing, for a launch that finds it; or its files are in the
    /// cloud, counted in `skips`, or went there while it was read, so
    /// nothing read in part is kept (FR02). A book whose format keeps no
    /// metadata in its file is not looked at and is read as naming no one,
    /// as is a book whose content is a folder of tracks, which has no tags
    /// of its own.
    nonisolated private static func readMetadataAgain(
        of book: Book,
        access: MaintenanceFileAccess,
        skips: CloudSkips
    ) -> MetadataReading? {
        guard ImportedFileMetadata.readsFile(of: book.format) else {
            return MetadataReading(bookID: book.id, author: Book.unknownAuthor)
        }
        let file = book.bookFileURL
        do {
            try access.requireOnThisMac(book, reading: .content)
            guard access.presence(of: file) == .present else { return nil }
            let author = try access.read(file) {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
                    return Book.unknownAuthor
                }
                return ImportedFileMetadata.read(from: file, format: book.format).author
            }
            // A file that went to the cloud while it was read may have been
            // read in part, so nothing read from it is kept.
            try access.requireOnThisMac(book, reading: .content)
            return MetadataReading(bookID: book.id, author: author)
        } catch {
            // Only a refusal is thrown here: reading metadata never throws.
            if DatalessFiles.isDownloadRefusal(error) {
                skips.record(book)
            }
            return nil
        }
    }

    /// Gives the rows what the pass read, in one change of the library and
    /// one save: the author read, where the row still lists the placeholder
    /// (`refreshedAuthor(current:read:)`), asked again here because an
    /// author typed while the pass ran stays; and the reader's version on
    /// every row read. A row whose author changed has its record written
    /// too, as any edit of it would; a row only stamped has not, since the
    /// stamp lives in the index alone. One `METADATA_REFRESH` line in the
    /// debug log counts both. A book no longer in the library is skipped.
    private func applyMetadataReadings(_ readings: [MetadataReading]) {
        guard !readings.isEmpty else { return }
        let latest = Dictionary(readings.map { ($0.bookID, $0) }, uniquingKeysWith: { _, later in later })
        var books = library.books
        var changed: [Book] = []
        for index in books.indices {
            guard let reading = latest[books[index].id] else { continue }
            books[index].metadataReaderVersion = ImportedFileMetadata.readerVersion
            if let author = Self.refreshedAuthor(current: books[index].author, read: reading.author) {
                books[index].author = author
                changed.append(books[index])
            }
        }
        library.books = books
        save()
        for row in changed {
            LibraryPersistenceService.saveBookInfo(for: row)
        }
        DiagnosticLog.event(
            .storage,
            "METADATA_REFRESH: read \(readings.count) books again; found the author of \(changed.count)"
        )
    }
}
