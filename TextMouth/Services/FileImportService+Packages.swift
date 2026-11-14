import Foundation

/// A .tmb package offered for import, identified before anything is copied:
/// by its bookInfo.json, validated against its content, or, when Remove from
/// Library Only deleted that record, by the removal marker it left behind.
struct TMBImportSource {
    /// The package as it was chosen.
    let packageURL: URL
    /// The book's own content inside it: its document, or its folder of
    /// audio tracks.
    let contentURL: URL
    /// The validated record, when the package has a readable bookInfo.json.
    let inspection: TMBPackageInspection?
    /// The removal marker the package holds, when one can be read.
    let marker: RemovedFromLibraryMarker?
    /// The book the package holds: the record's, or the one the marker names.
    let bookID: UUID
    /// The checksum the book is known by: the record's, or for a package
    /// identified by its marker, one computed from its content.
    let md5Hash: String
    /// The title and author the book is listed under: the record's, or the
    /// marker's, which keep any edits made before the removal.
    let title: String
    let author: String
    /// When the book was added: the record's date, or, for a package
    /// identified by its marker, when the package was made.
    let dateAdded: Date
}

extension FileImportService {

    // MARK: - Identifying a Package

    /// Identifies the .tmb package at `packageURL` for import, copying
    /// nothing. It must be a .tmb directory with no symbolic links, whose
    /// bookInfo.json is valid for its content. A package whose record is
    /// missing or unreadable is identified by its removal marker instead:
    /// Remove from Library Only deletes the record but keeps the marker
    /// (naming the book, its title, and its author), the content, and the
    /// text cache, and the content is then the one entry that is not
    /// package metadata.
    /// - Throws: an `ImportFailure` at the step of checking the package.
    static func identifyTMBPackage(at packageURL: URL) throws -> TMBImportSource {
        try ImportRun.perform(importing: packageURL.lastPathComponent) { run in
            try run.begin(.checkingPackage)
            try checkPackageStructure(at: packageURL)
            let marker = try? RemovedFromLibraryMarker.read(in: packageURL)

            if let info = try? BookInfo.load(from: packageURL) {
                let inspection = try inspectContent(of: packageURL, describedBy: info)
                return TMBImportSource(
                    packageURL: packageURL,
                    contentURL: inspection.contentURL,
                    inspection: inspection,
                    marker: marker,
                    bookID: info.metadata.bookID,
                    md5Hash: info.metadata.md5Hash,
                    title: info.metadata.title,
                    author: info.metadata.author,
                    dateAdded: info.metadata.dateAdded
                )
            }

            guard let marker else {
                throw TMBPackageImportError.invalidPackage("bookInfo.json is missing or unreadable")
            }
            let content = try retainedContentURL(in: packageURL)
            return TMBImportSource(
                packageURL: packageURL,
                contentURL: content,
                inspection: nil,
                marker: marker,
                bookID: marker.bookID,
                md5Hash: try contentHash(of: content, bookID: marker.bookID),
                title: marker.title,
                author: marker.author,
                dateAdded: creationDate(of: packageURL)
            )
        }
    }

    // MARK: - Importing an Identified Package

    /// Imports the identified package `source`. When the managed library
    /// holds the package Remove from Library Only retained for the same book
    /// (`source` itself, or another package retiring the same book ID or
    /// holding the same content), that package is taken back where it is
    /// (`reinstate`) instead of copied again. Otherwise `source` is imported
    /// as a staged copy (`importPackageCopy`).
    /// - Parameter observer: told as each step on the package begins.
    /// - Throws: an `ImportFailure` naming the package and the step that
    ///   failed.
    static func importTMBPackage(
        _ source: TMBImportSource,
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: source.packageURL.lastPathComponent, observer: observer) { run in
            if let retained = retainedPackage(matching: source),
               let reinstated = try reinstate(retained, for: source, run: &run) {
                return reinstated
            }
            return try importPackageCopy(source, run: &run)
        }
    }

    /// Imports `source` as a new package in the library's top level, staged
    /// like every import. The staged copy is checked again, so every later
    /// path and value comes from the exact package being published, and
    /// loses any removal marker, which would otherwise retire the book again
    /// at the next launch. Its content is then read as the reader will, and
    /// it is published only once its bookInfo.json reads back.
    ///
    /// The copy keeps its record's reading position, bookmarks, and
    /// settings. A package without a record (a copy taken of a retained
    /// package) is rebuilt from its removal marker (`reconstructedBook`).
    private static func importPackageCopy(
        _ source: TMBImportSource,
        run: inout ImportRun
    ) throws -> ImportedBook {
        try run.begin(.preparingPackage)
        let destination = try destinationPackageURL(
            title: source.title,
            author: source.author,
            dateAdded: source.dateAdded,
            bookID: source.bookID,
            folderPath: ""
        )
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TMBPackageImportError.destinationExists(destination.lastPathComponent)
        }

        let staging = try ImportStaging.makeEmpty(publishingTo: destination)
        defer { staging.discard() }

        // A step on the staged package, as every import's copy is, so the
        // import overlay says the package is being copied while it is; it
        // said "checking the package" throughout the copy (REV13).
        try run.begin(.copying, in: staging.directory)
        try staging.copyContents(of: source.packageURL)

        try run.begin(.checkingPackage, in: staging.directory)
        let staged: Book
        if source.inspection != nil {
            let copied = try inspectTMBPackage(at: staging.directory)
            staged = bookFromPackageInfo(
                copied.info,
                packageURL: staging.directory,
                folderPath: "",
                tmbName: staging.name
            )
        } else {
            staged = try reconstructedBook(
                inPackage: staging.directory,
                marker: try RemovedFromLibraryMarker.read(in: staging.directory),
                folderPath: "",
                dateAdded: source.dateAdded
            )
        }
        try RemovedFromLibraryMarker.remove(from: staging.directory)
        // A copy of a duplicate's package that a Cancel, or the launch's
        // discard, sent to the Trash still holds the marker saying it waits
        // for an answer (`DuplicateQuestionMarker`). Imported, it is a book
        // of the library like any other: kept with the marker, a provisional
        // library would pass it over while the index cannot be read, and the
        // next launch would discard it.
        try DuplicateQuestionMarker.remove(from: staging.directory)
        return try publishReadableBook(staged, from: staging, run: &run)
    }

    // MARK: - Retained Packages

    /// A package in the managed library that Remove from Library Only
    /// retired, as an import compares it with the package being imported.
    private struct RetainedPackage {
        /// The package.
        let url: URL
        /// The book it holds: its record's, or the one its marker names.
        let bookID: UUID
        /// The checksum its record keeps, when it still has a record.
        let recordedHash: String?
    }

    /// The package Remove from Library Only retained for the book `source`
    /// holds, when the managed library has one: `source` itself, when it
    /// lies in the library and its marker retires its book; otherwise a
    /// retained package for the same book ID, or failing that, one holding
    /// the same content.
    static func retainedPackage(
        matching source: TMBImportSource,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> URL? {
        if managedFolderPath(of: source.packageURL, libraryDirectory: libraryDirectory) != nil,
           RemovedFromLibraryMarker.retires(source.bookID, in: source.packageURL) {
            return source.packageURL
        }
        let candidates = retainedPackages(in: libraryDirectory).filter { !isSameItem($0.url, source.packageURL) }
        if let sameBook = candidates.first(where: { $0.bookID == source.bookID }) {
            return sameBook.url
        }
        return candidates.first { holdsSameContent($0, as: source) }?.url
    }

    /// Every package in the managed library whose removal marker retires its
    /// own book. A marker naming another book (left in a legacy package once
    /// shared by two records) does not make its package retained. Hidden
    /// entries and the insides of packages are not searched.
    private static func retainedPackages(in libraryDirectory: URL) -> [RetainedPackage] {
        guard let entries = FileManager.default.enumerator(
            at: libraryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var retained: [RetainedPackage] = []
        for case let url as URL in entries {
            guard url.pathExtension.lowercased() == "tmb", isDirectory(url) else { continue }
            entries.skipDescendants()
            let markerPath = TextMouthPaths.removedFromLibraryMarkerPath(in: url).path
            guard FileManager.default.fileExists(atPath: markerPath) else { continue }
            let record = try? BookInfo.load(from: url)
            guard let bookID = record?.metadata.bookID ?? (try? RemovedFromLibraryMarker.read(in: url))?.bookID,
                  RemovedFromLibraryMarker.retires(bookID, in: url) else { continue }
            retained.append(RetainedPackage(url: url, bookID: bookID, recordedHash: record?.metadata.md5Hash))
        }
        return retained
    }

    /// Whether `candidate` holds the same content as `source`: by the
    /// checksum its record keeps, or, without a record, by comparing its one
    /// content file with `source`'s, sizes first, so that no unrelated file
    /// is read in full. An RTFD book's folder is compared by its folder
    /// checksum (`contentChecksum(of:format:)`), the checksum its record
    /// would keep, and a folder of audio tracks is matched by book ID only.
    private static func holdsSameContent(_ candidate: RetainedPackage, as source: TMBImportSource) -> Bool {
        if let recordedHash = candidate.recordedHash {
            return recordedHash == source.md5Hash
        }
        guard let content = try? retainedContentURL(in: candidate.url) else { return false }
        // An RTFD is a folder of regular files with no size of its own to
        // compare, so its checksum is compared outright.
        if isRTFDFolder(content) {
            return (try? contentChecksum(of: content, format: .rtfd)) == source.md5Hash
        }
        guard !isDirectory(content),
              let size = fileSize(of: content),
              size == fileSize(of: source.contentURL) else { return false }
        return (try? md5Hash(of: content)) == source.md5Hash
    }

    // MARK: - Reinstating a Retained Package

    /// Takes `package`, which Remove from Library Only retained in the
    /// library, back into the library where it is, for an import of
    /// `source`, so the book is not copied a second time.
    ///
    /// Nothing is published until everything that can fail has succeeded,
    /// as with every import. While its removal marker is in place the
    /// package stays out of the library, so its content is read as the
    /// reader will and its bookInfo.json written and read back where it is,
    /// and deleting the marker through
    /// `LibraryPersistenceService.reinstatePackage(of:)` is what publishes
    /// it. A failure puts the record and content.md back as they were and
    /// leaves the marker, so the package stays retired, with any text the
    /// user changed in it.
    ///
    /// The book's record is, by preference: the package's own bookInfo.json,
    /// when it still has a valid one, so its reading position, bookmarks,
    /// and settings return; for another package of the same book, that
    /// package's record, when it describes exactly this content; otherwise
    /// one rebuilt from the removal marker (`reconstructedBook`).
    /// - Returns: nil when `package` is not `source` and cannot take the
    ///   book as `source` describes it; `source` is then imported as a copy.
    private static func reinstate(
        _ package: URL,
        for source: TMBImportSource,
        run: inout ImportRun
    ) throws -> ImportedBook? {
        try run.begin(.checkingPackage)
        guard let folderPath = managedFolderPath(of: package) else { return nil }
        // The package as the library names it, which is how its
        // retirement was recorded.
        let location = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: package.lastPathComponent)
        let isSource = isSameItem(package, source.packageURL)
        guard var book = try bookToReinstate(at: location, folderPath: folderPath, for: source, isSource: isSource) else {
            return nil
        }

        // The files a reinstatement writes, as they are now: content.md,
        // which reading the book's text may write again, and the record's
        // files, bookInfo.json and the content index beside it. Each is put
        // back should the reinstatement fail, at whatever step; one it did
        // not change is left alone.
        let previousText = PackageFileSnapshot(of: TextMouthPaths.contentMarkdownPath(in: location))
        let previousFiles = [previousText] + [
            TextMouthPaths.bookInfoPath(in: location),
            TextMouthPaths.contentIndexPath(in: location),
        ].map(PackageFileSnapshot.init(of:))
        // A book recording no fingerprint of its text (the marker of a book
        // removed before markers carried an edit, with no record to say)
        // cannot tell whether content.md holds an edit, so what content.md
        // holds is kept below should reading the book's file replace it.
        let textIsUnrecorded = !book.format.isAudio && book.textCacheFingerprint == nil
        do {
            let content = try readableContent(of: &book, run: &run)
            let keptNotice = try keepingUnrecordedText(of: book, held: textIsUnrecorded ? previousText : nil)
            try run.begin(.savingRecord, in: location)
            try writeVerifiedRecord(of: book, contentIndex: content.index, into: location)
            try run.begin(.reinstating, in: location)
            try LibraryPersistenceService.reinstatePackage(of: book)
            var imported = ImportedBook(book: book, report: content.report)
            imported.notice = keptNotice
            return imported
        } catch {
            previousFiles.forEach { $0.restore() }
            throw error
        }
    }

    /// Keeps the text content.md held before a reinstatement read the book's
    /// file, as a `content.md.edited-` copy, when reading it wrote other
    /// text there. This is the second safeguard for a book whose marker
    /// records no fingerprint (`reinstate`): an edit saved with Edit Text
    /// before this build's markers carried one would otherwise be lost
    /// without a word.
    /// - Parameters:
    ///   - book: The book reinstated, its text now read.
    ///   - held: content.md as it was before the read, or nil when the book
    ///     records a fingerprint, so the read's own safeguards apply.
    /// - Returns: What to tell the listener (`BookTextEditWording.replaced`),
    ///   or nil when nothing was replaced.
    /// - Throws: `FileImportError.importFailed` when the copy could not be
    ///   kept, so the reinstatement puts content.md back and the package
    ///   stays retired.
    private static func keepingUnrecordedText(of book: Book, held: PackageFileSnapshot?) throws -> String? {
        guard let held, let before = held.bytes,
              let now = try? Data(contentsOf: held.url), now != before else { return nil }
        guard let copy = BookTextEditSessions.keepCopy(of: held.url, bytes: before) else {
            throw FileImportError.importFailed(BookTextEditWording.addBackNoCopyKept(bookTitle: book.title))
        }
        BookTextEditSessions.logAddBackKeptText(of: book, copy: copy)
        return BookTextEditWording.replaced(bookTitle: book.title, keptCopy: copy)
    }

    /// The book a retained package is reinstated as (see `reinstate`), or
    /// nil when the package is not `source` and can take neither its own
    /// record, `source`'s, nor one rebuilt from its marker. A package that
    /// is not safe to read (one holding symbolic links) is never
    /// reinstated.
    private static func bookToReinstate(
        at location: URL,
        folderPath: String,
        for source: TMBImportSource,
        isSource: Bool
    ) throws -> Book? {
        let tmbName = location.lastPathComponent
        do {
            try checkPackageStructure(at: location)
        } catch {
            if isSource { throw error }
            return nil
        }

        // Its own record, still valid for its content.
        if let own = try? inspectTMBPackage(at: location) {
            return bookFromPackageInfo(own.info, packageURL: location, folderPath: folderPath, tmbName: tmbName)
        }
        // The record of another package of the book, which serves only if
        // it describes exactly the content this package holds.
        if !isSource, let info = source.inspection?.info {
            guard (try? inspectContent(of: location, describedBy: info)) != nil else { return nil }
            return bookFromPackageInfo(info, packageURL: location, folderPath: folderPath, tmbName: tmbName)
        }
        // Rebuilt from the removal marker.
        guard let marker = try? RemovedFromLibraryMarker.read(in: location) else {
            if isSource {
                throw TMBPackageImportError.invalidPackage("bookInfo.json is missing or unreadable")
            }
            return nil
        }
        return try reconstructedBook(
            inPackage: location,
            marker: marker,
            folderPath: folderPath,
            dateAdded: creationDate(of: location)
        )
    }

    /// One file of a retained package that a reinstatement writes (content.md,
    /// bookInfo.json, or the content index beside it) as it was before, so a
    /// failed reinstatement can put it back.
    private struct PackageFileSnapshot {
        /// Where the file is.
        let url: URL
        /// Whether anything was there.
        let existed: Bool
        /// Its bytes, or nil when there was none or it could not be read.
        let bytes: Data?

        /// The file at `url` as it is now.
        init(of url: URL) {
            self.url = url
            existed = FileManager.default.fileExists(atPath: url.path)
            bytes = existed ? try? Data(contentsOf: url) : nil
        }

        /// Puts the file back as it was: its earlier bytes, or no file when
        /// there was none. A file that still holds its earlier bytes is left
        /// alone, so content.md keeps the date its fingerprints record. A
        /// file that existed but could not be read cannot be put back, and
        /// is left as the failed reinstatement wrote it; the removal marker
        /// keeps the package retired either way.
        func restore() {
            if !existed {
                try? FileManager.default.removeItem(at: url)
            } else if let bytes, (try? Data(contentsOf: url)) != bytes {
                try? bytes.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: - Rebuilding a Record

    /// The book a retained package holds, rebuilt for a package whose
    /// bookInfo.json is gone, as Remove from Library Only deletes it. The
    /// book keeps its ID, title, author, braille table, and text encoding
    /// from the removal marker, and, for a text book, the record of an edit
    /// of its text (B12) with the fingerprints of its text cache; its format
    /// and checksum come from its one content entry, and the rest of its
    /// metadata is read from that file as an import reads it. Its reading
    /// position, bookmarks, and per-book settings lived only in the deleted
    /// record, so the book returns at its beginning.
    static func reconstructedBook(
        inPackage package: URL,
        marker: RemovedFromLibraryMarker,
        folderPath: String,
        dateAdded: Date
    ) throws -> Book {
        let content = try retainedContentURL(in: package)
        // An audio book keeps its content as a folder (of tracks), which has
        // no tags of its own to read; an RTFD book keeps its document as a
        // folder too, but it is a document, read as any RTFD is.
        let isTracksFolder = isDirectory(content) && !isRTFDFolder(content)
        let format: BookFormat
        if isTracksFolder {
            format = .audio
        } else if let detected = BookFormat.detect(from: content) {
            format = detected
        } else {
            throw FileImportError.unsupportedFormat(content.pathExtension.lowercased())
        }
        let metadata = isTracksFolder ? nil : ImportedFileMetadata.read(from: content, format: format)

        return Book(
            id: marker.bookID,
            title: marker.title,
            author: marker.author,
            format: format,
            filePath: content.path,
            md5Hash: try contentHash(of: content, bookID: marker.bookID),
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: package.lastPathComponent,
            audioAlbum: metadata?.audioAlbum,
            audioGenre: metadata?.audioGenre,
            audioYear: metadata?.audioYear,
            epubPublisher: metadata?.epub?.publisher,
            epubPublicationDate: metadata?.epub?.publicationDate,
            epubISBN: metadata?.epub?.isbn,
            epubLanguage: metadata?.epub?.language,
            epubIdentifier: metadata?.epub?.identifier,
            epubVersion: metadata?.epub?.epubVersion,
            // The text the user changed with Edit Text stays in content.md,
            // which the removal kept (B12): with the record of the edit, the
            // book's file is not read over it, and with the fingerprints, a
            // re-read that does replace content.md (Redo Text Extraction)
            // keeps a copy of what it held. Only a text book's content.md is
            // its text.
            textCacheFingerprint: format.isAudio ? nil : marker.textCacheFingerprint,
            editedText: format.isAudio ? nil : marker.editedText,
            // A braille book is read with the table it was imported with
            // (FMT21), in the braille file characters it was last read in
            // (braillecodes). The record that held both is gone, so the
            // marker carries them; without them the text would be read again
            // with the default table, as North American Braille ASCII. Only
            // a braille book has either.
            brailleTable: format == .braille ? marker.brailleTable : nil,
            brailleTableVersion: format == .braille ? marker.brailleTableVersion : nil,
            brailleFileCode: format == .braille ? marker.brailleFileCode : nil,
            // A text book is read in the encoding it was guessed to be in
            // (FMT16), or chosen in (encodingchoice), which the deleted
            // record held as well. Without it the book would be read by the
            // fallback, and its text would change.
            textEncoding: format.usesTextFileDecoder ? marker.textEncoding : nil,
            textEncodingSource: format.usesTextFileDecoder ? marker.textEncodingSource : nil,
            // Who chose the braille table goes with it (brfguess).
            brailleTableOrigin: format == .braille ? marker.brailleTableOrigin : nil
        )
    }

    /// The book's own content in a package whose record is gone: the one
    /// entry that is neither hidden nor package metadata (see
    /// `isPackageContentName`).
    /// - Throws: when the package has no such entry, or more than one, since
    ///   nothing then says which one is the book.
    static func retainedContentURL(in package: URL) throws -> URL {
        let names = try FileManager.default.contentsOfDirectory(atPath: package.path)
            .filter(isPackageContentName)
        guard names.count == 1, let name = names.first else {
            throw TMBPackageImportError.invalidPackage(
                names.isEmpty
                    ? "the package holds no book file"
                    : "the package holds more than one file that could be the book"
            )
        }
        return package.appendingPathComponent(name)
    }

    /// Whether the entry `name` in a package can be the book's own content:
    /// anything that is not hidden and is not one of the files TextMouth
    /// keeps beside the content (bookInfo.json and the content index beside
    /// it, the content.md text cache and the copies Edit Text keeps of it, a
    /// recording's origin record and its original take (`BookOrigin`), the
    /// audio edit history's folder (`AudioEditPackage`), an audiobook's
    /// transcript and the copies kept of an unusable one
    /// (`TextMouthPaths.isTranscriptFile`), a podcast episode's chapters
    /// (`TextMouthPaths.podcastChaptersFileName`), the cachedAudio folder,
    /// and the removal marker).
    static func isPackageContentName(_ name: String) -> Bool {
        !name.hasPrefix(".")
            && name != TextMouthPaths.bookInfoFileName
            && name != TextMouthPaths.contentIndexFileName
            && name != TextMouthPaths.contentMarkdownFileName
            && name != BookOrigin.fileName
            && name != BookOrigin.originalTakeFileName
            && name != AudioEditPackage.folderName
            && name != TextMouthPaths.cachedAudioFolderName
            && name != TextMouthPaths.removedFromLibraryMarkerName
            && name != TextMouthPaths.podcastChaptersFileName
            && !TextMouthPaths.isKeptTextCopy(name)
            && !TextMouthPaths.isTranscriptFile(name)
    }

    /// The checksum a book rebuilt from its content is known by: the MD5 of
    /// its document, as an import computes it. An audio book kept as a
    /// folder of tracks was known by the checksum of the archive it came
    /// from, which is gone, so it gets a value made from its book ID, which
    /// no other book shares and which stays the same if it is taken back
    /// again. An RTFD, a folder that is a document, is known by its folder
    /// checksum (`contentChecksum(of:format:)`), as an import computes it.
    static func contentHash(of content: URL, bookID: UUID) throws -> String {
        if isRTFDFolder(content) { return try contentChecksum(of: content, format: .rtfd) }
        guard isDirectory(content) else { return try md5Hash(of: content) }
        return "package-\(bookID.uuidString.lowercased())"
    }

    // MARK: - File Facts

    /// Whether `url` is a directory, not a file or a symbolic link to one.
    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// The size in bytes of the file at `url`, or nil when it cannot be read.
    private static func fileSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// When the package at `url` was made, which for a package in the
    /// library is when its book was first imported; now, when that cannot be
    /// read.
    private static func creationDate(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
    }

    /// Whether `first` and `second` name the same item, however their paths
    /// are spelled. Resolving an existing item's path also gives each part
    /// the capitals it has on disk, so two spellings of one item on a volume
    /// that ignores case agree. Internal so the library's check of a package
    /// it opens compares as an import does (`LibraryViewModel.listedBookID(for:)`).
    static func isSameItem(_ first: URL, _ second: URL) -> Bool {
        first.standardizedFileURL.resolvingSymlinksInPath().path
            == second.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
