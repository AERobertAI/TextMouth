import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ZIPFoundation

private final class SynchronousResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value?

    var value: Value? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Value) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

enum FileImportError: LocalizedError {
    case unsupportedFormat(String)
    case hashingFailed
    case importFailed(String)
    /// The bookInfo.json an import wrote did not read back as the record it
    /// wrote, so the package cannot be trusted to describe its book.
    case recordNotReadBack
    /// AVFoundation could not open an audio file, which it reports in terms
    /// ("Operation Stopped") that do not tell a listener what is wrong. The
    /// file is described as playback describes such a file.
    case unplayableAudio(AudioPlaybackFailure)
    /// A ZIP archive could not be read. ZIPFoundation's own errors carry no
    /// description a listener could use ("ArchiveError error 13").
    case unreadableArchive
    /// A ZIP archive holds a link to a file outside it, which ZIPFoundation
    /// refuses to extract.
    case archiveLinksOutside

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
        case .hashingFailed: return "Failed to compute file hash."
        case .importFailed(let msg): return "Import failed: \(msg)"
        case .recordNotReadBack: return "The bookInfo.json file did not read back as it was written."
        case .unplayableAudio(let failure): return failure.message
        case .unreadableArchive: return "The archive is damaged, incomplete, or not a ZIP archive."
        case .archiveLinksOutside: return "The archive holds a link to a file outside it, which is never extracted."
        }
    }
}

enum TMBPackageImportError: LocalizedError {
    case invalidPackage(String)
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let reason):
            return "Invalid TextMouth package: \(reason)"
        case .destinationExists(let name):
            return "A managed package named \(name) already exists."
        }
    }
}

struct TMBPackageInspection {
    let info: BookInfo
    let contentURL: URL
}

/// A book an import produced, with the report of the chapters its source
/// could not supply. The library decides from the report whether the
/// original file may be deleted and whether the reader must be warned.
struct ImportedBook {
    var book: Book
    /// The chapters the source names that could not be read. It is empty
    /// for a complete book and for formats that do not report omissions yet.
    var report = ExtractionReport()
    /// Whether the book was copied from a DAISY book kept as loose files:
    /// its folder, or its OPF or ncc.html inside that folder (TODO I02).
    var isFromPackageFolder = false

    /// Whether the original file must stay exactly where it is: an import
    /// that left chapters out never deletes it or offers to, whatever the
    /// "After Importing a Book" preference says.
    var keepsOriginal: Bool { !report.isComplete }

    /// Whether the "After Importing a Book" preference may delete the
    /// original, or offer to: only for a complete book copied from a single
    /// file. A DAISY book's original is a folder of files, some of which may
    /// belong to other books or to nothing the import copied, so it is
    /// never deleted (TODO I02).
    var mayDeleteOriginal: Bool { !keepsOriginal && !isFromPackageFolder }

    /// The warning an import that left chapters out presents once: what is
    /// missing, then that the original was kept. Nil for a complete import.
    var warning: String? {
        guard keepsOriginal else { return nil }
        return "\(report.message) The original file was kept."
    }
}

/// What an import reads about a book from its file before copying it: the
/// title and author the book is listed under, and the format's extra
/// fields. Reading it never fails an import: a file that names no title or
/// author, or whose metadata is damaged, is listed under its file name and
/// an unknown author.
struct ImportedFileMetadata {
    var title: String
    var author = "Unknown"
    /// Everything an EPUB's package document says about the book.
    var epub: EPUBMetadata?
    /// Audio tags, for an audio file.
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?

    /// Reads the metadata `format` keeps inside the file at `url`, starting
    /// from `fallbackTitle`, or the file's name when that is nil, and an
    /// unknown author.
    static func read(from url: URL, format: BookFormat, fallbackTitle: String? = nil) -> ImportedFileMetadata {
        var metadata = ImportedFileMetadata(title: fallbackTitle ?? url.deletingPathExtension().lastPathComponent)
        /// Adopts the title and author a format's metadata names, keeping
        /// the defaults for any it leaves empty.
        func adopt(title: String, author: String) {
            if !title.isEmpty { metadata.title = title }
            if !author.isEmpty { metadata.author = author }
        }

        switch format {
        case .epub:
            if let epub = try? EPUBParser.readMetadata(url: url) {
                metadata.epub = epub
                adopt(title: epub.title, author: epub.author)
            }
        case .docx:
            // Title and author from the document's core properties.
            if let core = try? DOCXParser.readMetadata(from: url) {
                adopt(title: core.title, author: core.author)
            }
        case .pdf:
            // Title and author from the document's attributes.
            if let attributes = PDFTextParser.readMetadata(from: url) {
                adopt(title: attributes.title, author: attributes.author)
            }
        case .daisy:
            // Title and author from the OPF or ncc.html.
            if let daisy = try? DAISYParser.readMetadata(from: url) {
                adopt(title: daisy.title, author: daisy.author)
            }
        case .audio:
            let tags = audioTags(of: url)
            adopt(title: tags.title, author: tags.artist)
            if !tags.album.isEmpty { metadata.audioAlbum = tags.album }
            if !tags.genre.isEmpty { metadata.audioGenre = tags.genre }
            if !tags.year.isEmpty { metadata.audioYear = tags.year }
        case .txt, .markdown, .html:
            break
        }
        return metadata
    }

    /// The common metadata tags of the audio file at `url`, read through
    /// AVFoundation's asynchronous loading while this thread waits, as an
    /// import runs off the main thread.
    private static func audioTags(of url: URL) -> AudioMetadata {
        let semaphore = DispatchSemaphore(value: 0)
        let tagsBox = SynchronousResultBox<AudioMetadata>()
        Task.detached {
            tagsBox.store(await AudioPlaybackService.extractFullMetadata(from: url))
            semaphore.signal()
        }
        semaphore.wait()
        return tagsBox.value ?? AudioMetadata()
    }
}

/// A file from a ZIP import that did not import in full, with what went
/// wrong: why it failed, or what its book is missing.
struct ZipImportFailure: Equatable {
    let fileName: String
    let message: String
}

struct ZipImportResult {
    let books: [Book]
    let failures: [ZipImportFailure]
    /// Books that were imported without some of their chapters, by file,
    /// each with its extraction report's sentence. They keep the ZIP.
    var incompleteBooks: [ZipImportFailure] = []

    /// What the library's alert says about the batch: the files that failed,
    /// then the books missing chapters, which also means the original ZIP
    /// was kept. Nil when every file imported in full.
    var failureSummary: String? {
        var sections: [String] = []
        if !failures.isEmpty {
            sections.append("\(failures.count) file\(failures.count == 1 ? "" : "s") failed:\n\(Self.lines(failures))")
        }
        if !incompleteBooks.isEmpty {
            let count = incompleteBooks.count
            sections.append("\(count) book\(count == 1 ? " is" : "s are") missing chapters:\n\(Self.lines(incompleteBooks))")
        }
        guard !sections.isEmpty else { return nil }
        let kept = incompleteBooks.isEmpty ? "" : "\nThe original file was kept."
        return "Imported \(books.count) book\(books.count == 1 ? "" : "s"), but \(sections.joined(separator: "\n"))\(kept)"
    }

    /// One "file: message" line per entry.
    private static func lines(_ entries: [ZipImportFailure]) -> String {
        entries.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
    }
}

enum FileImportService {

    /// Validate a .tmb package without trusting paths from its metadata.
    /// Package symlinks are rejected so copied content cannot continue to
    /// depend on files outside the managed library.
    static func inspectTMBPackage(at packageURL: URL) throws -> TMBPackageInspection {
        try checkPackageStructure(at: packageURL)
        let info: BookInfo
        do {
            info = try BookInfo.load(from: packageURL)
        } catch {
            throw TMBPackageImportError.invalidPackage("bookInfo.json is missing or unreadable")
        }
        return try inspectContent(of: packageURL, describedBy: info)
    }

    /// Checks that `packageURL` is a .tmb directory that neither is nor
    /// holds a symbolic link, so nothing copied from it can depend on files
    /// outside the package.
    static func checkPackageStructure(at packageURL: URL) throws {
        var isDirectory: ObjCBool = false
        guard packageURL.pathExtension.lowercased() == "tmb",
              FileManager.default.fileExists(atPath: packageURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw TMBPackageImportError.invalidPackage("the selected item is not a .tmb directory")
        }

        let packageValues = try packageURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard packageValues.isSymbolicLink != true else {
            throw TMBPackageImportError.invalidPackage("the package directory is a symbolic link")
        }
        if let enumerator = FileManager.default.enumerator(
            at: packageURL,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) {
            for case let child as URL in enumerator {
                if try child.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    throw TMBPackageImportError.invalidPackage("symbolic links are not allowed")
                }
            }
        }
    }

    /// Checks the content `info` names inside `packageURL`: a safe file name
    /// that exists, in the format `info` records, and, for a file, with the
    /// checksum it records (`content(at:hasChecksum:)`). Only an audio
    /// book's content may be a folder.
    static func inspectContent(
        of packageURL: URL,
        describedBy info: BookInfo
    ) throws -> TMBPackageInspection {
        let fileName = info.metadata.originalFileName
        guard !fileName.isEmpty,
              URL(fileURLWithPath: fileName).lastPathComponent == fileName,
              !fileName.contains("/") else {
            throw TMBPackageImportError.invalidPackage("the content filename is unsafe")
        }
        let contentURL = packageURL.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: contentURL.path) else {
            throw TMBPackageImportError.invalidPackage("the referenced content file is missing")
        }

        var contentIsDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: contentURL.path, isDirectory: &contentIsDirectory)
        if contentIsDirectory.boolValue {
            guard info.metadata.format.isAudio else {
                throw TMBPackageImportError.invalidPackage("only audiobook content may be a directory")
            }
        } else {
            guard BookFormat.detect(from: contentURL) == info.metadata.format else {
                throw TMBPackageImportError.invalidPackage("the content format does not match bookInfo.json")
            }
            guard !info.metadata.md5Hash.isEmpty,
                  try content(at: contentURL, of: info.metadata.format, hasChecksum: info.metadata.md5Hash) else {
                throw TMBPackageImportError.invalidPackage("the content hash does not match bookInfo.json")
            }
        }

        return TMBPackageInspection(info: info, contentURL: contentURL)
    }

    /// Whether the book of `format` whose file in its package is
    /// `contentURL` still has the checksum `recorded`: the MD5 of that file,
    /// or, for a DAISY book kept as its package's files, those files'
    /// checksum (`DAISYPackageInventory.contentHash()`), which the record of
    /// a loose DAISY book's import holds (TODO I02).
    private static func content(at contentURL: URL, of format: BookFormat, hasChecksum recorded: String) throws -> Bool {
        if try md5Hash(of: contentURL) == recorded {
            return true
        }
        guard let package = try? daisyPackage(of: contentURL, format: format) else { return false }
        return (try? package.contentHash()) == recorded
    }

    /// Copy a validated external package into the managed library and return a
    /// Book whose paths refer only to the managed copy.
    static func importTMBPackage(from sourceURL: URL) throws -> Book {
        try importTMBPackageWithReport(from: sourceURL).book
    }

    /// Imports the .tmb package at `sourceURL`, staged like every import.
    ///
    /// When the managed library holds the package Remove from Library Only
    /// retained for the same book (the chosen package itself, or another
    /// with the same book ID or the same content), that package is taken
    /// back where it is instead of copied a second time. Otherwise the
    /// package is copied into the library's top level with its reading
    /// position, bookmarks, and settings, and loses any removal marker it
    /// carried. Either way the book's content is read as the reader will,
    /// and the book is published only once its bookInfo.json reads back.
    /// See `importTMBPackage(_:observer:)`.
    /// - Parameter observer: told as each step on the package begins.
    /// - Throws: an `ImportFailure` naming the package and the step that
    ///   failed. Whatever was staged is removed, and the chosen package is
    ///   never changed unless it is the retained package being taken back.
    static func importTMBPackageWithReport(
        from sourceURL: URL,
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try importTMBPackage(try identifyTMBPackage(at: sourceURL), observer: observer)
    }

    /// Builds a Book from validated package metadata and a trusted package
    /// location. Callers must validate the package before using this helper.
    static func bookFromPackageInfo(
        _ info: BookInfo,
        packageURL: URL,
        folderPath: String,
        tmbName: String
    ) -> Book {
        let bookFilePath = packageURL.appendingPathComponent(info.metadata.originalFileName).path
        return Book(
            id: info.metadata.bookID,
            title: info.metadata.title,
            author: info.metadata.author,
            format: info.metadata.format,
            filePath: bookFilePath,
            md5Hash: info.metadata.md5Hash,
            folderPath: folderPath,
            dateAdded: info.metadata.dateAdded,
            lastOpened: info.metadata.lastOpened,
            readingPosition: info.state.readingPosition,
            bookmarks: info.bookmarks,
            totalWordCount: info.state.totalWordCount,
            totalCharacterCount: info.state.totalCharacterCount,
            tmbDirectoryName: tmbName,
            sourceFilePath: info.metadata.sourceFilePath,
            lastPlaybackStarted: info.state.lastPlaybackStarted,
            lastPlaybackStopped: info.state.lastPlaybackStopped,
            localVoiceID: info.state.localVoiceID,
            localWPM: info.state.localWPM,
            localPitch: info.state.localPitch,
            skippedHeadingIDs: info.state.skippedHeadingIDs,
            localEndOfBookBehavior: info.state.localEndOfBookBehavior,
            localSkipForwardUnit: info.state.localSkipForwardUnit,
            localSkipBackwardUnit: info.state.localSkipBackwardUnit,
            manualSortOrder: info.state.manualSortOrder,
            audioDuration: info.state.audioDuration,
            audioAlbum: info.metadata.audioAlbum,
            audioGenre: info.metadata.audioGenre,
            audioYear: info.metadata.audioYear,
            epubPublisher: info.metadata.publisher,
            epubPublicationDate: info.metadata.publicationDate,
            epubISBN: info.metadata.isbn,
            epubLanguage: info.metadata.language,
            epubIdentifier: info.metadata.epubIdentifier,
            epubVersion: info.metadata.epubVersion,
            cacheFormatVersion: info.state.cacheFormatVersion,
            contentIndexVersion: info.state.contentIndexVersion
        )
    }

    /// Reconstructs a Book for a package that already resides under the
    /// managed Library directory. The folder is derived from the package's
    /// actual parent path rather than trusting potentially stale metadata.
    static func bookFromManagedPackage(
        inspection: TMBPackageInspection,
        packageURL: URL,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> Book? {
        guard let folderPath = managedFolderPath(of: packageURL, libraryDirectory: libraryDirectory) else {
            return nil
        }
        return bookFromPackageInfo(
            inspection.info,
            packageURL: packageURL,
            folderPath: folderPath,
            tmbName: packageURL.lastPathComponent
        )
    }

    /// The library folder a package lies in, taken from where it actually is
    /// rather than from any metadata: "" at the library's top level, or the
    /// folder's path inside the library. Nil for a package outside the
    /// managed library, or for something not named as a package. Symbolic
    /// links are resolved first, so /tmp and /private/tmp spellings agree.
    static func managedFolderPath(
        of packageURL: URL,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> String? {
        let resolvedLibrary = libraryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedPackage = packageURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let libraryPrefix = resolvedLibrary.path + "/"

        guard resolvedPackage.pathExtension.lowercased() == "tmb",
              resolvedPackage.path.hasPrefix(libraryPrefix) else {
            return nil
        }

        let resolvedParentPath = resolvedPackage.deletingLastPathComponent().path
        if resolvedParentPath == resolvedLibrary.path {
            return ""
        }
        guard resolvedParentPath.hasPrefix(libraryPrefix) else { return nil }
        return String(resolvedParentPath.dropFirst(libraryPrefix.count))
    }

    /// Repairs storage fields from a validated managed package. Package state
    /// is adopted only when it is demonstrably newer, so a delayed package
    /// write cannot roll back the active Library reading position.
    static func reconciledLibraryBook(
        _ existing: Book,
        with managedPackageBook: Book
    ) -> Book {
        guard existing.id == managedPackageBook.id else { return existing }

        var repaired = existing
        repaired.filePath = managedPackageBook.filePath
        repaired.folderPath = managedPackageBook.folderPath
        repaired.tmbDirectoryName = managedPackageBook.tmbDirectoryName

        let existingPositionDate = existing.readingPosition?.lastUpdated ?? .distantPast
        let packagePositionDate = managedPackageBook.readingPosition?.lastUpdated ?? .distantPast
        if packagePositionDate > existingPositionDate {
            repaired.readingPosition = managedPackageBook.readingPosition
        }

        // Restore package-backed fields only when the Library snapshot lacks
        // them. User edits already present in the active Library remain intact.
        if repaired.sourceFilePath == nil {
            repaired.sourceFilePath = managedPackageBook.sourceFilePath
        }
        if repaired.totalWordCount == nil {
            repaired.totalWordCount = managedPackageBook.totalWordCount
        }
        if repaired.totalCharacterCount == nil {
            repaired.totalCharacterCount = managedPackageBook.totalCharacterCount
        }
        if repaired.bookmarks.isEmpty && !managedPackageBook.bookmarks.isEmpty {
            repaired.bookmarks = managedPackageBook.bookmarks
        }
        if repaired.cacheFormatVersion == nil {
            repaired.cacheFormatVersion = managedPackageBook.cacheFormatVersion
        }
        if repaired.contentIndexVersion == nil {
            repaired.contentIndexVersion = managedPackageBook.contentIndexVersion
        }
        if repaired.localSkipForwardUnit == nil {
            repaired.localSkipForwardUnit = managedPackageBook.localSkipForwardUnit
        }
        if repaired.localSkipBackwardUnit == nil {
            repaired.localSkipBackwardUnit = managedPackageBook.localSkipBackwardUnit
        }

        return repaired
    }

    /// Import a single file into a .tmb package, returning a Book model.
    /// Extracts EPUB metadata if available. Callers that must know which
    /// chapters could not be read use `importFileWithReport` instead.
    static func importFile(from sourceURL: URL, toFolder folderPath: String = "") throws -> Book {
        try importFileWithReport(from: sourceURL, toFolder: folderPath).book
    }

    /// Import a single file into a .tmb package, returning the Book with the
    /// report of the chapters its source could not supply.
    ///
    /// The package is built under a hidden name (`ImportStaging`) and is
    /// published only once every step that can fail has succeeded: copying
    /// the file, reading its text or audio as the reader will, and writing
    /// its bookInfo.json and reading it back. A book that could not be read,
    /// or whose record could not be saved, is never published.
    ///
    /// A DAISY book kept as loose files (its folder, or its OPF or ncc.html
    /// inside that folder) is imported with every file it needs, laid out
    /// in the package as in its folder (`DAISYPackageInventory`), and its
    /// book file is its OPF or ncc.html there (TODO I02).
    /// - Parameter observer: told as each step on the staged package begins;
    ///   tests use it to make a step fail.
    /// - Throws: an `ImportFailure` naming the file and the step that failed,
    ///   for example an EPUB with no readable chapter, a document whose text
    ///   cannot be extracted, or a DAISY book referring to a file outside
    ///   its folder. Whatever was staged is removed first, and the source
    ///   file is never touched.
    static func importFileWithReport(
        from sourceURL: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: sourceURL.lastPathComponent, observer: observer) { run in
            guard let format = BookFormat.detect(from: sourceURL) else {
                throw unsupportedSourceError(for: sourceURL)
            }

            try run.begin(.readingSource)
            let package = try daisyPackage(of: sourceURL, format: format)
            let hash = try importHash(of: sourceURL, package: package)
            let metadata = ImportedFileMetadata.read(
                from: package?.entryURL ?? sourceURL,
                format: format,
                fallbackTitle: package?.untitledName
            )
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: metadata.title,
                author: metadata.author,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let stagedFile = try stageContent(of: sourceURL, package: package, in: staging.directory)

            let staged = Book(
                id: bookID,
                title: metadata.title,
                author: metadata.author,
                format: format,
                filePath: stagedFile.path,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                tmbDirectoryName: staging.name,
                sourceFilePath: sourceURL.path,
                audioAlbum: metadata.audioAlbum,
                audioGenre: metadata.audioGenre,
                audioYear: metadata.audioYear,
                epubPublisher: metadata.epub?.publisher,
                epubPublicationDate: metadata.epub?.publicationDate,
                epubISBN: metadata.epub?.isbn,
                epubLanguage: metadata.epub?.language,
                epubIdentifier: metadata.epub?.identifier,
                epubVersion: metadata.epub?.epubVersion
            )
            var imported = try publishReadableBook(staged, from: staging, run: &run)
            imported.isFromPackageFolder = package != nil
            return imported
        }
    }

    // MARK: - Loose DAISY Packages

    /// The checksum a book imported from `source` is known by, which
    /// duplicate detection compares before anything is copied: a DAISY book
    /// kept as loose files has its package's checksum
    /// (`DAISYPackageInventory.contentHash()`), and any other source the
    /// MD5 of its file (TODO I02).
    /// - Throws: when the source cannot be read, or is a folder that is not
    ///   one DAISY book.
    static func importHash(of source: URL) throws -> String {
        try importHash(of: source, package: daisyPackage(of: source, format: BookFormat.detect(from: source)))
    }

    /// The checksum a book imported from `source` is known by, when
    /// `package` is the DAISY package `source` is, or nil when it is none.
    private static func importHash(of source: URL, package: DAISYPackageInventory?) throws -> String {
        try package?.contentHash() ?? md5Hash(of: source)
    }

    /// The DAISY package `source`, a book of `format`, is: for a DAISY book
    /// kept as loose files (its folder, or its OPF or ncc.html), the files
    /// it needs (`DAISYPackageInventory.ofSource(_:)`). Nil for any other
    /// source, a DAISY ZIP included, and for any source in another format,
    /// such as an unpacked EPUB that also has a package file.
    private static func daisyPackage(of source: URL, format: BookFormat?) throws -> DAISYPackageInventory? {
        guard format == .daisy else { return nil }
        return try DAISYPackageInventory.ofSource(source)
    }

    /// Copies what an import of `source` reads into the staged package
    /// `directory`, and returns the book's own file there: every file of
    /// `package`, laid out as in its folder, when `source` is a DAISY book
    /// kept as loose files; otherwise the source file itself.
    private static func stageContent(
        of source: URL,
        package: DAISYPackageInventory?,
        in directory: URL
    ) throws -> URL {
        guard let package else {
            let stagedFile = directory.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: stagedFile)
            return stagedFile
        }
        logShortfalls(of: package)
        return try package.copyFiles(into: directory)
    }

    /// Records in the console and the debug log what a DAISY package import
    /// copies other than as the book's references list it: the files they
    /// name that do not exist, and the whole folder, when the references
    /// could not be read. Reading the copied book as the reader will then
    /// decides whether the import succeeds.
    private static func logShortfalls(of package: DAISYPackageInventory) {
        var lines: [String] = []
        if !package.missingPaths.isEmpty {
            lines.append(
                "DAISY_PACKAGE_MISSING: \(package.entryURL.path): refers to \(package.missingPaths.count) "
                    + "file(s) that do not exist: \(package.missingPaths.joined(separator: ", "))"
            )
        }
        if let reason = package.wholeFolderReason {
            lines.append(
                "DAISY_PACKAGE_WHOLE_FOLDER: \(package.root.path): copied every file, since the book's "
                    + "files could not be listed: \(reason)"
            )
        }
        for line in lines {
            // One line per entry, whatever the reason holds.
            let entry = line.components(separatedBy: .newlines).joined(separator: " ")
            print(entry)
            TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: entry)
        }
    }

    /// Why `source` cannot be imported when no format reads it: a folder
    /// that is not a DAISY book is told so, in words; any other item's
    /// extension is not supported. A TextMouth package is not a folder of
    /// a book here: it is imported as a package, not as a file.
    private static func unsupportedSourceError(for source: URL) -> Error {
        let ext = source.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        if ext != "tmb",
           FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return DAISYPackageError.notAPackage
        }
        return FileImportError.unsupportedFormat(ext)
    }

    /// Imports text the reader typed or pasted as a plain-text book, staged
    /// like every import: the text is written into a hidden package as
    /// `fileName`, read as the reader will, and the package is published
    /// only once its bookInfo.json reads back.
    /// - Parameters:
    ///   - title: The book's title, already resolved for display.
    ///   - author: The author as entered; an empty one is listed as unknown.
    ///   - fileName: The name of the text file inside the package.
    ///   - observer: told as each step on the staged package begins.
    /// - Throws: an `ImportFailure` naming `fileName` and the step that
    ///   failed; whatever was staged is removed first.
    static func importText(
        _ text: String,
        title: String,
        author: String,
        fileName: String,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: fileName, observer: observer) { run in
            let bookID = UUID()
            let dateAdded = Date()

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
            let file = staging.directory.appendingPathComponent(fileName)
            try text.write(to: file, atomically: true, encoding: .utf8)
            let hash = try md5Hash(of: file)

            let staged = Book(
                id: bookID,
                title: title,
                author: author.isEmpty ? "Unknown" : author,
                format: .txt,
                filePath: file.path,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                tmbDirectoryName: staging.name
            )
            return try publishReadableBook(staged, from: staging, run: &run)
        }
    }

    // MARK: - Staged Imports

    /// Where an import publishes a book's package: in the library folder
    /// `folderPath`, whose directory is created first if needed, under the
    /// name the book's title, author, date added, and ID give it, which no
    /// other book's package shares.
    static func destinationPackageURL(
        title: String,
        author: String,
        dateAdded: Date,
        bookID: UUID,
        folderPath: String
    ) throws -> URL {
        try TextMouthPaths.ensureDirectoryStructure()
        if !folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        }
        let name = TextMouthPaths.tmbName(title: title, author: author, dateAdded: dateAdded, bookID: bookID)
        return TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: name)
    }

    /// Finishes an import whose book is complete inside `staging`: reads its
    /// content as the reader will, saves its record and reads it back, and
    /// publishes the package under its final name. `staged` describes the
    /// book inside the staged package; the book returned describes it where
    /// it was published.
    static func publishReadableBook(
        _ staged: Book,
        from staging: ImportStaging,
        run: inout ImportRun
    ) throws -> ImportedBook {
        var staged = staged
        let content = try readableContent(of: &staged, run: &run)
        let book = staging.published(staged)

        try run.begin(.savingRecord, in: staging.directory)
        try writeVerifiedRecord(of: book, contentIndex: content.index, into: staging.directory)

        try run.begin(.publishing, in: staging.directory)
        try staging.publish()
        return ImportedBook(book: book, report: content.report)
    }

    /// What reading a book's content as the reader will produced: the index
    /// to save with the book, and the report of the chapters its source could
    /// not supply (always complete for audio and for formats that do not
    /// report omissions).
    struct ReadableContent {
        var index: BookContentIndex
        var report = ExtractionReport()
    }

    /// Reads `book`'s content as the reader will, so that no import publishes
    /// a book that cannot be opened. A text book's content.md is written into
    /// its package, and an extraction that fails, in any format, fails with
    /// the extraction's error. An audio book is analyzed, and one without a
    /// playable chapter fails. `book` receives the cache version and the
    /// index's counts.
    static func readableContent(of book: inout Book, run: inout ImportRun) throws -> ReadableContent {
        if book.format.isAudio {
            try run.begin(.readingAudio, in: book.tmbDirectory)
            let analysis: BookContentAnalysisService.Result
            do {
                analysis = try BookContentAnalysisService.load(book: book)
            } catch {
                throw describedAudioFailure(error, of: book)
            }
            guard !analysis.content.chapters.isEmpty else { throw AudioParseError.noAudioFiles }
            book.applyContentIndexSummary(analysis.index)
            return ReadableContent(index: analysis.index)
        }

        try run.begin(.readingText, in: book.tmbDirectory)
        guard let generated = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &book) else {
            // Only a book without a package gets no cache, and every
            // import gives its book one before reading it.
            throw FileImportError.importFailed("The book has no package to hold its text.")
        }
        return ReadableContent(index: generated.content.contentIndex, report: generated.report)
    }

    /// `error`, from analyzing `book`'s audio, in terms a listener
    /// understands. A single file that cannot be analyzed is described as
    /// playback describes it ("is damaged, unreadable, or not an audio
    /// file"), because AVFoundation's own words ("Operation Stopped") do not
    /// say what is wrong. A folder's errors already name its problem.
    private static func describedAudioFailure(_ error: any Error, of book: Book) -> any Error {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: book.filePath, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return error }
        return FileImportError.unplayableAudio(
            AudioPlaybackFailure(reason: .fileUnreadable, url: book.bookFileURL, underlyingError: error)
        )
    }

    /// Writes `book`'s bookInfo.json, holding `contentIndex`, into `package`
    /// and reads it back, so that a package is published only with a record
    /// that is on disk and names its book. `package` is where the record goes
    /// now, which for a staged package is not yet the book's own location.
    static func writeVerifiedRecord(of book: Book, contentIndex: BookContentIndex, into package: URL) throws {
        var info = book.makeBookInfo()
        info.contentIndex = contentIndex
        try info.save(to: package)

        let saved = try BookInfo.load(from: package)
        guard saved.metadata.bookID == book.id,
              saved.metadata.md5Hash == book.md5Hash,
              saved.metadata.format == book.format,
              saved.metadata.originalFileName == info.metadata.originalFileName,
              saved.contentIndex != nil else {
            throw FileImportError.recordNotReadBack
        }
    }

    /// Import a ZIP file containing supported book files.
    /// Calls the progress callback with (completed, total) counts.
    /// Pass existingHashes to skip files whose content already exists in the library,
    /// preventing orphaned .tmb packages from being created for duplicates.
    /// Returns imported books together with any per-file failures.
    /// - Throws: an `ImportFailure` naming the archive when it cannot be
    ///   extracted at all. A book inside it that fails is listed in the
    ///   result's failures instead, and the others still import.
    static func importZip(
        from zipURL: URL,
        toFolder folderPath: String = "",
        existingHashes: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> ZipImportResult {
        // The archive is extracted into one folder, and any archive inside
        // it into another, so the search of the first never meets the second.
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let extracted = workDirectory.appendingPathComponent("archive", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        // Extraction is the one archive-wide step that can fail; each book
        // in the archive then imports, or fails, on its own.
        try ImportRun.perform(importing: zipURL.lastPathComponent) { run in
            try run.begin(.extractingArchive)
            try TextMouthPaths.ensureDirectoryStructure()
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
            try extractArchive(zipURL, into: extracted)
        }

        // First pass: every book in the archive, each once, those in the
        // archives it holds included.
        let books = importCandidates(
            in: extracted,
            unpackingNestedArchivesInto: workDirectory.appendingPathComponent("nested", isDirectory: true)
        )

        return importSupportedFiles(
            books,
            toFolder: folderPath,
            existingHashes: existingHashes,
            progress: progress
        )
    }

    /// The books in `directory`, an extracted archive, each listed once and
    /// in path order, for a batch import to import one by one (TODO I02):
    ///
    /// - A DAISY book kept as loose files in a folder of its own is one
    ///   book, listed as that folder, and none of the files inside counts
    ///   on its own. A folder with several books' package files lists each
    ///   package file instead, as does a TextMouth package holding a DAISY
    ///   book, since neither folder names one book.
    /// - An archive whose own top level holds a DAISY book is that book.
    /// - A DAISY ZIP inside is one book. Any other archive inside is
    ///   unpacked into `nestedDirectory` and searched the same way, one
    ///   level deep only, since an archive can hold itself; with
    ///   `nestedDirectory` nil, other archives are passed over.
    /// - Any other file in a format TextMouth reads is a book. Hidden files
    ///   and the `__MACOSX` folder macOS adds to archives are passed over:
    ///   they hold copies of the archive's files that are not books.
    static func importCandidates(in directory: URL, unpackingNestedArchivesInto nestedDirectory: URL?) -> [URL] {
        let topLevelBooks = DAISYParser.packageEntryPoints(in: directory)
        guard topLevelBooks.isEmpty else { return topLevelBooks }
        guard let entries = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [URL] = []
        for case let url as URL in entries {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                guard url.lastPathComponent != "__MACOSX" else {
                    entries.skipDescendants()
                    continue
                }
                let packageFiles = DAISYParser.packageEntryPoints(in: url)
                guard !packageFiles.isEmpty else { continue }
                entries.skipDescendants()
                let isOneBooksFolder = packageFiles.count == 1 && url.pathExtension.lowercased() != "tmb"
                candidates += isOneBooksFolder ? [url] : packageFiles
            } else if url.pathExtension.lowercased() == "zip" {
                if DAISYParser.isDAISYZip(url: url) {
                    candidates.append(url)
                } else if let nestedDirectory, let unpacked = unpackNestedArchive(url, into: nestedDirectory) {
                    candidates += importCandidates(in: unpacked, unpackingNestedArchivesInto: nil)
                }
            } else if BookFormat.detect(from: url) != nil {
                candidates.append(url)
            }
        }
        return candidates.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Unpacks `archive`, an archive found inside the one being imported,
    /// into a new folder inside `parent`, and returns that folder; nil when
    /// it cannot be unpacked, as it then holds no book the import can find,
    /// and the archive's other books still import.
    private static func unpackNestedArchive(_ archive: URL, into parent: URL) -> URL? {
        let destination = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archive, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Import files discovered inside a ZIP while retaining individual errors
    /// and the books imported without some of their chapters.
    /// This is separate from archive discovery so partial-import behavior is
    /// deterministic and independently testable.
    static func importSupportedFiles(
        _ supportedFiles: [URL],
        toFolder folderPath: String,
        existingHashes: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil,
        importer: (URL, String) throws -> ImportedBook = { url, folder in
            try importFileWithReport(from: url, toFolder: folder)
        }
    ) -> ZipImportResult {
        let total = supportedFiles.count
        var books: [Book] = []
        var failures: [ZipImportFailure] = []
        var incompleteBooks: [ZipImportFailure] = []
        // Track hashes from this batch to avoid creating duplicate .tmbs
        // when the same file appears multiple times in a single zip
        var seenHashes = existingHashes

        // Second pass: import each file, skipping duplicates
        for (index, fileURL) in supportedFiles.enumerated() {
            // Compute hash before creating .tmb to avoid orphaning on
            // duplicate; a DAISY book in a folder has its package's.
            if let hash = try? importHash(of: fileURL), seenHashes.contains(hash) {
                progress?(index + 1, total)
                continue
            }

            do {
                let imported = try importer(fileURL, folderPath)
                seenHashes.insert(imported.book.md5Hash)
                books.append(imported.book)
                if !imported.report.isComplete {
                    incompleteBooks.append(
                        ZipImportFailure(fileName: fileURL.lastPathComponent, message: imported.report.message)
                    )
                }
            } catch {
                // The summary names the file, so the message is the reason
                // alone: the step that failed and why.
                failures.append(
                    ZipImportFailure(
                        fileName: fileURL.lastPathComponent,
                        message: ImportFailure.reason(for: error)
                    )
                )
            }
            progress?(index + 1, total)
        }

        return ZipImportResult(books: books, failures: failures, incompleteBooks: incompleteBooks)
    }

    /// Delete a book's entire .tmb package.
    /// Respects the "Move to Trash" setting — uses Trash when enabled,
    /// permanent deletion otherwise.
    @MainActor
    static func deleteBookPackage(_ book: Book) throws {
        let tmbDir = try managedPackageURLForDeletion(book)
        try removeItemRespectingTrashSetting(at: tmbDir)
    }

    /// Validate the deletion target independently of filesystem mutation. A
    /// missing legacy package name otherwise resolves to the entire folder.
    /// Resolve symlinks as well as dot components before checking containment.
    static func managedPackageURLForDeletion(
        _ book: Book,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) throws -> URL {
        let name = book.tmbDirectoryName
        guard !name.isEmpty,
              (name as NSString).lastPathComponent == name,
              name.lowercased().hasSuffix(".tmb"),
              BookFolder.isValidLibraryPath(book.folderPath) else {
            throw FileImportError.importFailed(
                "This book has no valid managed package. Remove it from the library only, or repair its storage before deleting it."
            )
        }
        let libraryRoot = libraryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let requestedPackage = libraryRoot.appendingPathComponent(book.folderPath, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
        // Deleting a package alias must not delete the other book it points
        // to, even when both happen to live inside the managed library.
        guard (try? requestedPackage.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true else {
            throw FileImportError.importFailed("A symbolic link cannot be deleted as a managed book package.")
        }
        let package = requestedPackage.resolvingSymlinksInPath()
        guard package.path.hasPrefix(libraryRoot.path + "/"),
              !book.filePath.isEmpty,
              URL(fileURLWithPath: book.filePath).standardizedFileURL.resolvingSymlinksInPath()
                .path.hasPrefix(package.path + "/") else {
            throw FileImportError.importFailed("The book's package and content paths do not match a managed library location.")
        }
        return package
    }

    /// Delete just the book file from a .tmb (legacy compat - prefer deleteBookPackage)
    @MainActor
    static func deleteBookFile(at path: String) throws {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.pathExtension == "tmb" {
            try removeItemRespectingTrashSetting(at: parent)
        } else {
            try removeItemRespectingTrashSetting(at: url)
        }
    }

    /// Remove an item from disk, using Trash if the setting is enabled.
    /// A Trash failure is surfaced to the caller and never converted into an
    /// unconfirmed permanent deletion.
    @MainActor
    static func removeItemRespectingTrashSetting(
        at url: URL,
        trashItem: (URL) throws -> Void = { item in
            try FileManager.default.trashItem(at: item, resultingItemURL: nil)
        },
        removeItem: (URL) throws -> Void = { item in
            try FileManager.default.removeItem(at: item)
        }
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if ConfigService.shared.config.moveToTrashInsteadOfDeleting {
            try trashItem(url)
        } else {
            try removeItem(url)
        }
    }

    /// Delete the original source file after import (if the user chose that
    /// option), to the Trash or permanently as "Move to Trash instead of
    /// deleting" chooses, like every other deletion. Throws when the file
    /// could not be removed, so the caller can say so (TODO S09); a file
    /// that is already gone counts as removed.
    @MainActor
    static func deleteOriginalFile(at url: URL) throws {
        try removeItemRespectingTrashSetting(at: url)
    }

    /// Compute MD5 hash of a file (streaming for large files)
    static func md5Hash(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        var hasher = Insecure.MD5()
        let bufferSize = 1024 * 1024

        while autoreleasepool(invoking: {
            let chunk = handle.readData(ofLength: bufferSize)
            guard !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02hhx", $0) }.joined()
    }

    /// Import a DAISY audio ZIP as a multi-chapter audio book.
    /// Extracts audio files, parses SMIL timing for chapter segments,
    /// and generates a manifest.json with segment data.
    static func importDAISYAudioZip(from zipURL: URL, toFolder folderPath: String = "") throws -> Book {
        try importDAISYAudioZipWithReport(from: zipURL, toFolder: folderPath).book
    }

    /// Import a DAISY audio ZIP as a multi-chapter audio book, staged like
    /// every import: the audio is converted into a hidden package and read
    /// as the reader will, and the package is published only once its
    /// bookInfo.json is on disk.
    /// - Parameter observer: told as each step on the staged package begins.
    /// - Throws: an `ImportFailure` naming the archive and the step that
    ///   failed; whatever was staged is removed first.
    static func importDAISYAudioZipWithReport(
        from zipURL: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: zipURL.lastPathComponent, observer: observer) { run in
            try run.begin(.readingSource)
            let hash = try md5Hash(of: zipURL)
            let provider = ArchiveFileProvider(archive: try Archive(url: zipURL, accessMode: .read))
            let metadata = ImportedFileMetadata.read(from: zipURL, format: .daisy)
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: metadata.title,
                author: metadata.author,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.convertingAudio, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            // DAISY 2.02 books are navigated by ncc.html, DAISY 3 by an OPF.
            let isDAISY202 = provider.listFiles().contains { path in
                let lowercased = path.lowercased()
                return lowercased.hasSuffix("ncc.html") || lowercased.hasSuffix("ncc.htm")
            }
            let manifest = try DAISYAudioConverter.convertToAudioBook(
                from: provider,
                version: isDAISY202 ? .daisy202 : .daisy3,
                toDirectory: audioDirectory
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: audioDirectory.appendingPathComponent("manifest.json"))

            let staged = stagedAudioBook(
                id: bookID,
                title: metadata.title,
                author: metadata.author,
                audioDirectory: audioDirectory,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                staging: staging,
                source: zipURL
            )
            return try publishReadableBook(staged, from: staging, run: &run)
        }
    }

    /// Import a ZIP of audio files as a single multi-chapter audio book.
    /// Returns a single Book where each audio file is a chapter.
    static func importAudioZip(from zipURL: URL, toFolder folderPath: String = "") throws -> Book {
        try importAudioZipWithReport(from: zipURL, toFolder: folderPath).book
    }

    /// Import a ZIP of audio files as one audio book, staged like every
    /// import: the archive is extracted into a hidden package and its audio
    /// read as the reader will, so an archive without one playable track is
    /// never published, and the package is published only once its
    /// bookInfo.json is on disk.
    /// - Parameter observer: told as each step on the staged package begins.
    /// - Throws: an `ImportFailure` naming the archive and the step that
    ///   failed; whatever was staged is removed first.
    static func importAudioZipWithReport(
        from zipURL: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: zipURL.lastPathComponent, observer: observer) { run in
            try run.begin(.readingSource)
            let hash = try md5Hash(of: zipURL)
            let zipName = zipURL.deletingPathExtension().lastPathComponent
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: zipName,
                author: "Unknown",
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.extractingArchive, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            try extractArchive(zipURL, into: audioDirectory)

            // A manifest beside the audio can name the book and its author.
            var title = zipName
            var author = "Unknown"
            let manifestURL = audioDirectory.appendingPathComponent("manifest.json")
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(AudioManifest.self, from: data) {
                if let manifestTitle = manifest.title { title = manifestTitle }
                if let manifestAuthor = manifest.author { author = manifestAuthor }
            }

            // Reading the audio uses the reader's discovery rules (wrapper
            // folders count; Finder metadata named like audio does not), so
            // an archive with no playable track fails there.
            let staged = stagedAudioBook(
                id: bookID,
                title: title,
                author: author,
                audioDirectory: audioDirectory,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                staging: staging,
                source: zipURL
            )
            return try publishReadableBook(staged, from: staging, run: &run)
        }
    }

    /// Extracts the ZIP archive at `archive` into `directory`. ZIPFoundation's
    /// own errors have no description a listener could use, so they are
    /// told in plain words; other errors, such as a missing archive or a
    /// full disk, already describe themselves.
    private static func extractArchive(_ archive: URL, into directory: URL) throws {
        do {
            try FileManager.default.unzipItem(at: archive, to: directory)
        } catch Archive.ArchiveError.uncontainedSymlink {
            throw FileImportError.archiveLinksOutside
        } catch is Archive.ArchiveError {
            throw FileImportError.unreadableArchive
        }
    }

    /// Creates the folder an audio archive's tracks go in, inside `staging`.
    private static func makeAudioDirectory(in staging: ImportStaging) throws -> URL {
        let audioDirectory = staging.directory.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: false)
        return audioDirectory
    }

    /// The book an audio archive becomes: one audio book whose file path is
    /// its folder of tracks inside the staged package, imported from `source`.
    private static func stagedAudioBook(
        id: UUID,
        title: String,
        author: String,
        audioDirectory: URL,
        md5Hash: String,
        folderPath: String,
        dateAdded: Date,
        staging: ImportStaging,
        source: URL
    ) -> Book {
        Book(
            id: id,
            title: title,
            author: author,
            format: .audio,
            filePath: audioDirectory.path,
            md5Hash: md5Hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: staging.name,
            sourceFilePath: source.path
        )
    }

    /// Supported UTTypes for file import dialogs
    static var supportedTypes: [UTType] {
        var types: [UTType] = [.plainText, .html]
        if let epub = UTType("org.idpf.epub-container") {
            types.append(epub)
        }
        if let md = UTType("net.daringfireball.markdown") {
            types.append(md)
        }
        // Office Open XML Word documents. Legacy binary .doc files are not
        // ZIP-based DOCX documents and are not supported by DOCXParser.
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        // PDF documents
        types.append(.pdf)
        // DAISY books (OPF files and .daisy extension)
        // Use custom UTIs matching Info.plist imported type declarations
        if let opf = UTType("com.textmouth.opf-package") {
            types.append(opf)
        }
        if let daisy = UTType("com.textmouth.daisy-book") {
            types.append(daisy)
        }
        // A DAISY book kept as loose files can be chosen as its folder, as
        // well as by its .opf or its ncc.html (an HTML file, allowed above).
        // A folder that holds no DAISY book is refused when imported, saying
        // why (TODO I02).
        types.append(.folder)
        types.append(.zip)
        types.append(contentsOf: [UTType("public.text")].compactMap { $0 })
        if let tmb = UTType("com.textmouth.book-package") {
            types.append(tmb)
        }
        // Audio formats
        types.append(.mp3)
        types.append(.wav)
        types.append(.aiff)
        types.append(contentsOf: [
            UTType("public.mpeg-4-audio"),       // m4a
            UTType("com.apple.m4a-audio"),       // m4a alt
            UTType("com.apple.protected-mpeg-4-audio"), // m4b
            UTType("org.xiph.flac"),             // flac
            UTType("public.aac-audio"),          // aac
        ].compactMap { $0 })
        return types
    }

    /// Rebuild the .TextMouth directory structure, keeping books removed with Remove
    /// from Library Only out, migrating any books from old storage, moving misplaced
    /// .tmb packages to their correct folders, and adopting orphans.
    /// Returns what the legacy migration did: a book that could not move keeps
    /// its record and original and is listed with the reason, for the caller
    /// to show. This throws only when the data directory itself cannot be made.
    @discardableResult
    static func rebuildDirectoryStructure(library: inout Library) throws -> LegacyMigrationReport {
        try TextMouthPaths.ensureDirectoryStructure()

        // Books taken out with Remove from Library Only stay out, as at
        // startup, before any step below touches their packages.
        RemovedFromLibraryMarker.removeRetiredBooks(from: &library)

        // Migrate books that don't have .tmb packages yet. Each copy is
        // verified before its original is removed, and a failure for one
        // book does not stop the others.
        let migration = migrateLegacyBooks(in: &library)

        // Older package names only used title/author/timestamp and could collide
        // when several books were imported together. Split those references
        // before any cache or metadata maintenance writes into the shared path.
        separateSharedTMBPackages(library: &library)

        // Move .tmb packages that are at the wrong location on disk
        // (e.g. sitting at root when they should be in a subfolder)
        relocateMisplacedTMBPackages(library: &library)

        // Adopt any orphaned .tmb packages found on disk
        adoptOrphanedTMBPackages(library: &library)

        // Clean up empty subdirectories left behind by folder removal
        removeEmptyLibrarySubdirectories(library: library)

        if let oldDir = TextMouthPaths.oldAppSupportDir,
           FileManager.default.fileExists(atPath: oldDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
        return migration
    }

    /// Give every library book its own package when legacy records point at the
    /// same `.tmb` directory. The package whose bookInfo owns the directory is
    /// retained in place. Other records receive a complete recovery copy under
    /// the current UUID-based name, with derived content invalidated so startup
    /// analysis rebuilds it from that record's own source file.
    @discardableResult
    static func separateSharedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> Int {
        let fm = FileManager.default
        var packageReferences: [String: [Int]] = [:]
        for index in library.books.indices {
            let book = library.books[index]
            guard !book.tmbDirectoryName.isEmpty else { continue }
            let key = book.folderPath + "\u{0}" + book.tmbDirectoryName
            packageReferences[key, default: []].append(index)
        }

        var separated = 0
        for indices in packageReferences.values where indices.count > 1 {
            let firstBook = library.books[indices[0]]
            let sharedPackage = libraryDirectory
                .appendingPathComponent(firstBook.folderPath, isDirectory: true)
                .appendingPathComponent(firstBook.tmbDirectoryName, isDirectory: true)
            guard fm.fileExists(atPath: sharedPackage.path) else { continue }

            let storedBookID = (try? BookInfo.load(from: sharedPackage))?.metadata.bookID
            let keeper = indices.first { library.books[$0].id == storedBookID } ?? indices[0]

            for index in indices where index != keeper {
                let book = library.books[index]
                let packageName = TextMouthPaths.tmbName(
                    title: book.title,
                    author: book.author,
                    dateAdded: book.dateAdded,
                    bookID: book.id
                )
                let parent = libraryDirectory.appendingPathComponent(
                    book.folderPath,
                    isDirectory: true
                )
                let destination = parent.appendingPathComponent(packageName, isDirectory: true)
                guard !fm.fileExists(atPath: destination.path) else { continue }

                let staging = parent.appendingPathComponent(
                    ".textmouth-split-\(UUID().uuidString)",
                    isDirectory: true
                )
                do {
                    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                    try fm.copyItem(at: sharedPackage, to: staging)

                    var repaired = book
                    repaired.tmbDirectoryName = packageName
                    let sourceURL = URL(fileURLWithPath: book.filePath).standardizedFileURL
                    let sharedPath = sharedPackage.standardizedFileURL.path + "/"
                    if sourceURL.path.hasPrefix(sharedPath) {
                        let relativePath = String(sourceURL.path.dropFirst(sharedPath.count))
                        repaired.filePath = staging.appendingPathComponent(relativePath).path
                    } else {
                        let copiedSource = staging.appendingPathComponent(sourceURL.lastPathComponent)
                        if !fm.fileExists(atPath: copiedSource.path) {
                            try fm.copyItem(at: sourceURL, to: copiedSource)
                        }
                        repaired.filePath = copiedSource.path
                    }
                    repaired.cacheFormatVersion = nil
                    repaired.contentIndexVersion = nil
                    repaired.totalWordCount = nil
                    repaired.totalCharacterCount = nil
                    repaired.audioDuration = nil

                    let copiedCache = TextMouthPaths.contentMarkdownPath(in: staging)
                    if fm.fileExists(atPath: copiedCache.path) {
                        try fm.removeItem(at: copiedCache)
                    }
                    var info = repaired.makeBookInfo()
                    info.contentIndex = nil
                    try info.save(to: staging)
                    try fm.moveItem(at: staging, to: destination)

                    // Replace the staging prefix only after the package is
                    // published at its final location.
                    repaired.filePath = repaired.filePath.replacingOccurrences(
                        of: staging.path + "/",
                        with: destination.path + "/"
                    )
                    library.books[index] = repaired
                    separated += 1
                } catch {
                    try? fm.removeItem(at: staging)
                    print("Failed to separate shared package for \(book.title): \(error)")
                }
            }

            // If the existing metadata did not belong to any referencing book,
            // force the selected keeper through the same normal cache rebuild.
            if storedBookID == nil || !indices.contains(where: { library.books[$0].id == storedBookID }) {
                var repaired = library.books[keeper]
                repaired.cacheFormatVersion = nil
                repaired.contentIndexVersion = nil
                repaired.totalWordCount = nil
                repaired.totalCharacterCount = nil
                repaired.audioDuration = nil
                var info = repaired.makeBookInfo()
                info.contentIndex = nil
                do {
                    try info.save(to: sharedPackage)
                    library.books[keeper] = repaired
                    let cache = TextMouthPaths.contentMarkdownPath(in: sharedPackage)
                    if fm.fileExists(atPath: cache.path) {
                        try fm.removeItem(at: cache)
                    }
                } catch {
                    print("Failed to invalidate unowned shared package for \(repaired.title): \(error)")
                }
            }
        }

        if separated > 0 {
            print("Separated \(separated) book(s) from shared legacy .tmb packages")
        }
        return separated
    }

    /// Move .tmb packages that exist on disk but aren't in the folder their
    /// book's folderPath says they should be in. Updates filePath to match.
    /// This fixes books whose folder assignment was updated in library.json
    /// without the physical .tmb directory being moved.
    @discardableResult
    static func relocateMisplacedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> Int {
        let fm = FileManager.default
        var relocated = 0

        for i in library.books.indices {
            let book = library.books[i]
            // Only care about books that have a .tmb and a folder assignment
            guard !book.tmbDirectoryName.isEmpty,
                  !book.folderPath.isEmpty
            else { continue }

            let expectedDir = libraryDirectory
                .appendingPathComponent(book.folderPath, isDirectory: true)
                .appendingPathComponent(book.tmbDirectoryName, isDirectory: true)
            let rootDir = libraryDirectory
                .appendingPathComponent(book.tmbDirectoryName, isDirectory: true)

            // If the .tmb is already in the right place, nothing to do
            if fm.fileExists(atPath: expectedDir.path) { continue }

            // If the .tmb is at root, move it to the correct folder
            guard fm.fileExists(atPath: rootDir.path) else { continue }

            do {
                try fm.createDirectory(
                    at: libraryDirectory.appendingPathComponent(book.folderPath, isDirectory: true),
                    withIntermediateDirectories: true
                )
                try fm.moveItem(at: rootDir, to: expectedDir)

                // Update the filePath to point to the new location
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                library.books[i].filePath = expectedDir
                    .appendingPathComponent(fileName).path
                relocated += 1
            } catch {
                // Move failed — leave the book where it is
                print("Failed to relocate \(book.tmbDirectoryName): \(error)")
            }
        }

        if relocated > 0 {
            print("Relocated \(relocated) misplaced .tmb package(s) to correct folders")
        }
        return relocated
    }

    /// Remove empty subdirectories from the library that aren't tracked as folders.
    /// These are left behind when folders are removed from the library model but
    /// the disk directory isn't cleaned up. Directory names are matched to
    /// folders with the volume's equivalence rule: where case is ignored, a
    /// directory spelled `reports` *is* the folder `Reports` and must stay.
    static func removeEmptyLibrarySubdirectories(
        library: Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir,
        equivalence: FolderPathEquivalence? = nil
    ) {
        let fm = FileManager.default
        let libraryDir = libraryDirectory
        let rule = equivalence ?? .forVolume(containing: libraryDirectory)
        let knownFolderKeys = Set(library.folders.map { rule.comparisonKey(for: $0.fullPath) })
        /// Whether a directory path relative to the library names a folder.
        func isKnownFolder(_ relativePath: String) -> Bool {
            knownFolderKeys.contains(rule.comparisonKey(for: relativePath))
        }

        // Walk the library directory looking for non-.tmb subdirectories
        guard let enumerator = fm.enumerator(
            at: libraryDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var candidatesForRemoval: [URL] = []

        while let url = enumerator.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            // Skip .tmb directories — those are book packages, not folders
            if url.pathExtension == "tmb" {
                enumerator.skipDescendants()
                continue
            }

            // Compute the relative path from the library root
            let resolvedLibrary = libraryDir.resolvingSymlinksInPath().path
            let resolvedURL = url.resolvingSymlinksInPath().path
            let relativePath = resolvedURL
                .replacingOccurrences(of: resolvedLibrary, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            guard !relativePath.isEmpty else { continue }

            // If this directory is a known folder, keep it
            if isKnownFolder(relativePath) { continue }

            // Check if the directory is empty (no files or subdirectories)
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.isEmpty {
                candidatesForRemoval.append(url)
            }
        }

        // Remove empty directories (deepest first so parents become empty too)
        let sorted = candidatesForRemoval.sorted {
            $0.pathComponents.count > $1.pathComponents.count
        }
        for url in sorted {
            let contents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }

        // After removing leaf directories, walk up and remove any newly empty parents
        let resolvedLibrary = libraryDir.resolvingSymlinksInPath().path
        for url in sorted {
            var parent = url.deletingLastPathComponent()
            while parent.resolvingSymlinksInPath().path != resolvedLibrary {
                let relativePath = parent.resolvingSymlinksInPath().path
                    .replacingOccurrences(of: resolvedLibrary, with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if relativePath.isEmpty || isKnownFolder(relativePath) { break }
                let contents = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
                guard contents.isEmpty else { break }
                try? fm.removeItem(at: parent)
                parent = parent.deletingLastPathComponent()
            }
        }
    }

    /// Scan the library directory for .tmb packages that exist on disk but are not
    /// tracked in the library. Reconstructs Book objects from their bookInfo.json
    /// and adds them to the library. Returns the number of adopted books.
    ///
    /// This handles cases where the app was quit or crashed during import before
    /// the book could be saved to library.json, leaving orphaned .tmb packages.
    ///
    /// A package whose book was taken out with Remove from Library Only is not
    /// an orphan: its `RemovedFromLibraryMarker` keeps it out at startup,
    /// during index recovery, and on rebuild alike, even when a late write has
    /// left a readable bookInfo.json in it. Such a package is left untouched
    /// on disk for a deliberate re-import.
    @discardableResult
    static func adoptOrphanedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> Int {
        let fm = FileManager.default
        let libraryDir = libraryDirectory

        // Collect all .tmb directory names currently tracked in the library
        let knownTMBNames = Set(library.books.map { $0.tmbDirectoryName })

        // Walk the library directory tree to find all .tmb packages on disk
        var adopted = 0
        guard let enumerator = fm.enumerator(
            at: libraryDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        while let url = enumerator.nextObject() as? URL {
            // Only look at .tmb directories
            guard url.pathExtension == "tmb",
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }

            // Don't recurse into .tmb packages
            enumerator.skipDescendants()

            let tmbName = url.lastPathComponent
            // Skip if already tracked in the library
            if knownTMBNames.contains(tmbName) { continue }

            // Try to load bookInfo.json from the orphaned .tmb
            guard let info = try? BookInfo.load(from: url) else { continue }

            // The user removed this book from the library; it stays out.
            if RemovedFromLibraryMarker.retires(info.metadata.bookID, in: url) { continue }

            // Find the actual book file inside the .tmb: the one its record
            // names, since a DAISY book's package holds many files (TODO
            // I02); for a record naming none there, the first entry that is
            // not metadata or cache (a removal marker naming some other book
            // included)
            let tmbContents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let recordedName = info.metadata.originalFileName
            let bookFileName = tmbContents.contains(recordedName) && isPackageContentName(recordedName)
                ? recordedName
                : tmbContents.first(where: isPackageContentName)

            guard let fileName = bookFileName else { continue }
            let bookFilePath = url.appendingPathComponent(fileName).path
            guard fm.fileExists(atPath: bookFilePath) else { continue }

            // Determine the folder path relative to the library directory.
            // e.g. Library/Science Fiction/Author/Book.tmb → "Science Fiction/Author"
            // Resolve symlinks so /tmp vs /private/tmp paths match consistently.
            let resolvedLibrary = libraryDir.resolvingSymlinksInPath().path
            let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
            let relativePath = resolvedParent
                .replacingOccurrences(of: resolvedLibrary, with: "")
            let folderPath = relativePath
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Build the Book from bookInfo.json metadata and state
            let book = Book(
                id: info.metadata.bookID,
                title: info.metadata.title,
                author: info.metadata.author,
                format: info.metadata.format,
                filePath: bookFilePath,
                md5Hash: info.metadata.md5Hash,
                folderPath: folderPath,
                dateAdded: info.metadata.dateAdded,
                lastOpened: info.metadata.lastOpened,
                readingPosition: info.state.readingPosition,
                bookmarks: info.bookmarks,
                totalWordCount: info.state.totalWordCount,
                totalCharacterCount: info.state.totalCharacterCount,
                tmbDirectoryName: tmbName,
                sourceFilePath: info.metadata.sourceFilePath,
                lastPlaybackStarted: info.state.lastPlaybackStarted,
                lastPlaybackStopped: info.state.lastPlaybackStopped,
                localVoiceID: info.state.localVoiceID,
                localWPM: info.state.localWPM,
                localPitch: info.state.localPitch,
                skippedHeadingIDs: info.state.skippedHeadingIDs,
                localEndOfBookBehavior: info.state.localEndOfBookBehavior,
                localSkipForwardUnit: info.state.localSkipForwardUnit,
                localSkipBackwardUnit: info.state.localSkipBackwardUnit,
                manualSortOrder: info.state.manualSortOrder,
                audioDuration: info.state.audioDuration,
                audioAlbum: info.metadata.audioAlbum,
                audioGenre: info.metadata.audioGenre,
                audioYear: info.metadata.audioYear,
                epubPublisher: info.metadata.publisher,
                epubPublicationDate: info.metadata.publicationDate,
                epubISBN: info.metadata.isbn,
                epubLanguage: info.metadata.language,
                epubIdentifier: info.metadata.epubIdentifier,
                epubVersion: info.metadata.epubVersion,
                cacheFormatVersion: info.state.cacheFormatVersion,
                contentIndexVersion: info.state.contentIndexVersion
            )

            // addBook guards against duplicate hashes — only truly new books get added
            let countBefore = library.books.count
            library.addBook(book)
            if library.books.count > countBefore {
                adopted += 1

                // Update the bookInfo.json folderPath if it was empty but the .tmb
                // lives inside a subfolder (common with orphans from zip imports)
                if info.metadata.folderPath != folderPath {
                    var updatedBook = book
                    updatedBook.folderPath = folderPath
                    library.books[library.books.count - 1] = updatedBook
                    try? updatedBook.saveBookInfoThrowing()
                }
            }
        }

        if adopted > 0 {
            print("Adopted \(adopted) orphaned .tmb package(s) into library")
        }
        return adopted
    }

    /// Recreates folder rows for the folders on disk and for every folder a
    /// book lives in. Only the library index records folder rows, so when it
    /// cannot be read, the directories under the library directory are the
    /// best remaining evidence of the user's folders. Without rows, books in
    /// folders would be unreachable from the Folders view, and Rebuild Library
    /// Index would save a library whose folders had vanished.
    ///
    /// Package directories, their contents, and hidden entries are skipped.
    /// Paths deeper than `BookFolder.maxDepth`, names folder creation refuses,
    /// and folders equivalent to an existing row are left out. Returns the
    /// number of rows added; running it again adds none.
    @discardableResult
    static func adoptLibraryFolders(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) -> Int {
        var paths = folderDirectoryPaths(in: libraryDirectory)
        for book in library.books where !book.folderPath.isEmpty {
            let components = book.folderPath.components(separatedBy: "/")
            for depth in 1...components.count {
                paths.insert(components.prefix(depth).joined(separator: "/"))
            }
        }

        // Parents first, so every row's parent already exists when it is added.
        let parentsFirst = paths.sorted { lhs, rhs in
            let lhsDepth = lhs.components(separatedBy: "/").count
            let rhsDepth = rhs.components(separatedBy: "/").count
            return lhsDepth == rhsDepth ? lhs < rhs : lhsDepth < rhsDepth
        }
        var added = 0
        for path in parentsFirst where library.existingFolder(equivalentTo: path) == nil {
            var components = path.components(separatedBy: "/")
            let name = components.removeLast()
            let parentPath = components.joined(separator: "/")
            if (try? library.createFolderThrowing(name: name, parentPath: parentPath)) != nil {
                added += 1
            }
        }
        return added
    }

    /// Relative paths of the folder directories under `libraryDirectory`:
    /// directories that are not packages, not inside a package, not hidden,
    /// and no deeper than a folder row can be.
    private static func folderDirectoryPaths(in libraryDirectory: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: libraryDirectory.path) else {
            return []
        }
        var paths = Set<String>()
        while let relativePath = enumerator.nextObject() as? String {
            // Attributes come from lstat, so a symbolic link is never followed.
            guard (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory else {
                continue
            }
            let name = (relativePath as NSString).lastPathComponent
            let depth = relativePath.components(separatedBy: "/").count
            if name.hasPrefix(".") || name.lowercased().hasSuffix(".tmb") || depth > BookFolder.maxDepth {
                enumerator.skipDescendants()
                continue
            }
            paths.insert(relativePath)
        }
        return paths
    }
}
