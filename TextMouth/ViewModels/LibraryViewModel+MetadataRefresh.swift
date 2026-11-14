import Foundation

// MARK: - The Metadata Refresh

/// What the metadata refresh read of one book: the values its file names
/// now for the fields the refresh may replace
/// (`Book.MetadataField.refreshable`), on their way to the book's row. A
/// field the file names no value for, or that its format keeps none of, is
/// absent; the author is there only when the file names someone, never as
/// the placeholder.
struct MetadataReading: Sendable {
    let bookID: UUID
    let named: Book.MetadataValues

    /// The reading of `bookID`'s file, which names `named`, or nothing.
    init(bookID: UUID, named: Book.MetadataValues = [:]) {
        self.bookID = bookID
        self.named = named
    }

    /// What `metadata`, read from `bookID`'s file with an empty fallback
    /// title (`ImportedFileMetadata.read(from:format:fallbackTitle:)`),
    /// names: a title the file names, an author other than the
    /// placeholder, and an EPUB's publisher and publication date where
    /// they are not empty.
    init(bookID: UUID, read metadata: ImportedFileMetadata) {
        var named: Book.MetadataValues = [:]
        if !metadata.title.isEmpty {
            named[.title] = metadata.title
        }
        if !Book.isUnknownAuthor(metadata.author) {
            named[.author] = metadata.author
        }
        if let epub = metadata.epub {
            if !epub.publisher.isEmpty {
                named[.publisher] = epub.publisher
            }
            if !epub.publicationDate.isEmpty {
                named[.publicationDate] = epub.publicationDate
            }
        }
        self.init(bookID: bookID, named: named)
    }
}

/// The launch pass that reads a book's file again for its metadata when an
/// older metadata reader read it (`Book.metadataReaderVersion`).
extension LibraryViewModel {

    /// Whether the refresh reads `book`'s file again: its row was stamped by
    /// an older reader than `ImportedFileMetadata.readerVersion`, or by
    /// none, as every row was before readers were versioned. Never for a
    /// feed's item (FR11), whose title and author come from its feed.
    nonisolated static func needsMetadataRefresh(_ book: Book) -> Bool {
        !book.isFeedItem
            && SemanticVersion.isOutdated(stored: book.metadataReaderVersion, current: ImportedFileMetadata.readerVersion(for: book.format))
    }

    /// The fields of `book` the refresh replaces with what its file names
    /// (`reading`), each with its new value.
    ///
    /// A field the user edited by hand (`Book.handEdits`) is never
    /// replaced. For a row whose record of hand edits has been kept since
    /// its import (`Book.HandEdits.sinceImport`), every other refreshable
    /// field the file names a value for is replaced, so a better reading
    /// reaches every value the import read. For any other row, whose
    /// unrecorded fields may hold edits nothing recorded (every row from
    /// before October 7, 2026, with or without a record begun by an edit
    /// since), only an author at the placeholder is replaced, and only by
    /// a name: a title or an author typed by hand before then stays. A
    /// value the row already holds is not counted.
    nonisolated static func refreshedValues(of book: Book, from reading: MetadataReading) -> Book.MetadataValues {
        let record = book.handEdits
        let keptSinceImport = record?.sinceImport ?? false
        var values: Book.MetadataValues = [:]
        for field in Book.MetadataField.refreshable {
            guard let read = reading.named[field], record?.contains(field) != true else { continue }
            let current = field.value(in: book.editableMetadata)
            let replaceable = keptSinceImport || (field == .author && Book.isUnknownAuthor(current ?? ""))
            guard replaceable, read != current else { continue }
            values[field] = read
        }
        return values
    }

    /// Reads again, off the main thread, the file of every book an older
    /// reader read (`needsMetadataRefresh(_:)`), with the reader imports use
    /// (`ImportedFileMetadata.read`), and then gives the rows what was read
    /// in one change of the library and one save
    /// (`applyMetadataReadings(_:)`): the fields the file names that the
    /// row may take (`refreshedValues(of:from:)`), and the reader's version
    /// on every row read. Runs at launch before the text cache batch, and
    /// takes a few seconds for several hundred books.
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

    /// What `book`'s file names now, read on the pass's thread with the
    /// reader imports use, or nil when the book is left as it is: its file
    /// is missing, for a launch that finds it; or its files are in the
    /// cloud, counted in `skips`, or went there while it was read, so
    /// nothing read in part is kept (FR02). A book whose format keeps no
    /// metadata in its file is not looked at and is read as naming
    /// nothing, as is a book whose content is a folder of tracks, which
    /// has no tags of its own.
    nonisolated private static func readMetadataAgain(
        of book: Book,
        access: MaintenanceFileAccess,
        skips: CloudSkips
    ) -> MetadataReading? {
        guard ImportedFileMetadata.readsFile(of: book.format) else {
            return MetadataReading(bookID: book.id)
        }
        let file = book.bookFileURL
        do {
            try access.requireOnThisMac(book, reading: .content)
            guard access.presence(of: file) == .present else { return nil }
            let reading = try access.read(file) {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isFolder), !isFolder.boolValue else {
                    return MetadataReading(bookID: book.id)
                }
                // With an empty fallback title, a file that names no title
                // reads as naming none, where an import would list the
                // book under its file's name.
                // A braille book's title page is read with the table and the
                // file characters the book was imported with.
                let braille = book.brailleTable.map { (table: $0, fileCode: book.brailleFileCode) }
                let read = ImportedFileMetadata.read(
                    from: file, format: book.format, fallbackTitle: "", brailleReading: braille)
                return MetadataReading(bookID: book.id, read: read)
            }
            // A file that went to the cloud while it was read may have been
            // read in part, so nothing read from it is kept.
            try access.requireOnThisMac(book, reading: .content)
            return reading
        } catch {
            // Only a refusal is thrown here: reading metadata never throws.
            if DatalessFiles.isDownloadRefusal(error) {
                skips.record(book)
            }
            return nil
        }
    }

    /// Gives the rows what the pass read, in one change of the library and
    /// one save: the fields each row may take from what its file names
    /// (`refreshedValues(of:from:)`), asked here, of the rows as they are
    /// now, because a field edited by hand while the pass ran is recorded
    /// on its row by then and stays; and the reader's version on every row
    /// read. The refresh records no edit of its own: a row without a
    /// record of hand edits keeps none. A row with a field replaced has its
    /// record written too, as any edit of it would; a row only stamped has
    /// not, so a library of hundreds of books writes nothing for them: the
    /// stamp reaches each record with the book's next save, and a library
    /// rebuilt from its records before then reads those books again once.
    /// One `METADATA_REFRESH` line in the debug log counts the books read,
    /// the fields replaced, and the rows they were replaced on. A book no
    /// longer in the library is skipped.
    private func applyMetadataReadings(_ readings: [MetadataReading]) {
        guard !readings.isEmpty else { return }
        let latest = Dictionary(readings.map { ($0.bookID, $0) }, uniquingKeysWith: { _, later in later })
        var books = library.books
        var changed: [Book] = []
        var replaced = 0
        for index in books.indices {
            guard let reading = latest[books[index].id] else { continue }
            books[index].metadataReaderVersion = ImportedFileMetadata.readerVersion(for: books[index].format)
            let values = Self.refreshedValues(of: books[index], from: reading)
            guard !values.isEmpty else { continue }
            for (field, value) in values {
                field.set(value, in: &books[index])
            }
            changed.append(books[index])
            replaced += values.count
        }
        library.books = books
        save()
        for row in changed {
            LibraryPersistenceService.saveBookInfo(for: row)
        }
        DiagnosticLog.event(.storage, Self.metadataRefreshLogLine(read: readings.count, replaced: replaced, rows: changed.count))
    }

    /// The `METADATA_REFRESH` line: how many books were read again, and how
    /// many fields were replaced on how many of them.
    nonisolated static func metadataRefreshLogLine(read: Int, replaced: Int, rows: Int) -> String {
        "METADATA_REFRESH: read \(CountWording.books(read)) again; "
            + "replaced \(CountWording.phrase(replaced, singular: "field", plural: "fields")) of \(rows)"
    }
}
