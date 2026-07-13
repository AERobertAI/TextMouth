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

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
        case .hashingFailed: return "Failed to compute file hash."
        case .importFailed(let msg): return "Import failed: \(msg)"
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

struct ZipImportFailure: Equatable {
    let fileName: String
    let message: String
}

struct ZipImportResult {
    let books: [Book]
    let failures: [ZipImportFailure]

    var failureSummary: String? {
        guard !failures.isEmpty else { return nil }
        let details = failures
            .map { "\($0.fileName): \($0.message)" }
            .joined(separator: "\n")
        return "Imported \(books.count) book\(books.count == 1 ? "" : "s"), but \(failures.count) file\(failures.count == 1 ? "" : "s") failed:\n\(details)"
    }
}

enum FileImportService {

    /// Validate a .tmb package without trusting paths from its metadata.
    /// Package symlinks are rejected so copied content cannot continue to
    /// depend on files outside the managed library.
    static func inspectTMBPackage(at packageURL: URL) throws -> TMBPackageInspection {
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

        let info: BookInfo
        do {
            info = try BookInfo.load(from: packageURL)
        } catch {
            throw TMBPackageImportError.invalidPackage("bookInfo.json is missing or unreadable")
        }

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
            let actualHash = try md5Hash(of: contentURL)
            guard !info.metadata.md5Hash.isEmpty, actualHash == info.metadata.md5Hash else {
                throw TMBPackageImportError.invalidPackage("the content hash does not match bookInfo.json")
            }
        }

        return TMBPackageInspection(info: info, contentURL: contentURL)
    }

    /// Copy a validated external package into the managed library and return a
    /// Book whose paths refer only to the managed copy.
    static func importTMBPackage(from sourceURL: URL) throws -> Book {
        let inspection = try inspectTMBPackage(at: sourceURL)
        try TextMouthPaths.ensureDirectoryStructure()

        let info = inspection.info
        let tmbName = TextMouthPaths.tmbName(
            title: info.metadata.title,
            author: info.metadata.author,
            dateAdded: info.metadata.dateAdded,
            bookID: info.metadata.bookID
        )
        let destination = TextMouthPaths.tmbPath(folderPath: "", tmbName: tmbName)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw TMBPackageImportError.destinationExists(tmbName)
        }

        let staging = TextMouthPaths.libraryDir
            .appendingPathComponent(".import-\(UUID().uuidString).tmb", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: sourceURL, to: staging)

        // Revalidate the copy to ensure all subsequent paths and metadata come
        // from the exact package that will be adopted.
        let copiedInspection = try inspectTMBPackage(at: staging)
        try FileManager.default.moveItem(at: staging, to: destination)

        let book = bookFromPackageInfo(
            copiedInspection.info,
            packageURL: destination,
            folderPath: "",
            tmbName: tmbName
        )
        do {
            try bookInfo(for: book).save(to: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return book
    }

    private static func bookFromPackageInfo(
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
            cacheFormatVersion: info.state.cacheFormatVersion
        )
    }

    private static func bookInfo(for book: Book) -> BookInfo {
        BookInfo(
            metadata: BookMetadata(
                title: book.title,
                author: book.author,
                format: book.format,
                md5Hash: book.md5Hash,
                dateAdded: book.dateAdded,
                lastOpened: book.lastOpened,
                originalFileName: book.bookFileURL.lastPathComponent,
                folderPath: book.folderPath,
                bookID: book.id,
                sourceFilePath: book.sourceFilePath,
                publisher: book.epubPublisher,
                publicationDate: book.epubPublicationDate,
                isbn: book.epubISBN,
                language: book.epubLanguage,
                epubIdentifier: book.epubIdentifier,
                epubVersion: book.epubVersion,
                audioAlbum: book.audioAlbum,
                audioGenre: book.audioGenre,
                audioYear: book.audioYear
            ),
            state: BookState(
                readingPosition: book.readingPosition,
                totalWordCount: book.totalWordCount,
                totalCharacterCount: book.totalCharacterCount,
                isNew: book.lastOpened == nil,
                tmbDirectoryName: book.tmbDirectoryName,
                lastPlaybackStarted: book.lastPlaybackStarted,
                lastPlaybackStopped: book.lastPlaybackStopped,
                localVoiceID: book.localVoiceID,
                localWPM: book.localWPM,
                localPitch: book.localPitch,
                skippedHeadingIDs: book.skippedHeadingIDs,
                localEndOfBookBehavior: book.localEndOfBookBehavior,
                manualSortOrder: book.manualSortOrder,
                audioDuration: book.audioDuration,
                cacheFormatVersion: book.cacheFormatVersion
            ),
            bookmarks: book.bookmarks
        )
    }

    /// Import a single file into a .tmb package, returning a Book model.
    /// Extracts EPUB metadata if available.
    static func importFile(from sourceURL: URL, toFolder folderPath: String = "") throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        if !folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        }

        let ext = sourceURL.pathExtension.lowercased()
        guard let format = BookFormat.detect(from: sourceURL) else {
            throw FileImportError.unsupportedFormat(ext)
        }

        let hash = try md5Hash(of: sourceURL)
        var title = sourceURL.deletingPathExtension().lastPathComponent
        var author = "Unknown"
        let dateAdded = Date()
        let bookID = UUID()
        var epubMetadata: EPUBMetadata?

        // Extract metadata from EPUB files before creating the .tmb
        if format == .epub {
            if let metadata = try? EPUBParser.readMetadata(url: sourceURL) {
                epubMetadata = metadata
                if !metadata.title.isEmpty { title = metadata.title }
                if !metadata.author.isEmpty { author = metadata.author }
            }
        }

        // Extract metadata from DOCX files (title and author from core properties)
        if format == .docx {
            if let metadata = try? DOCXParser.readMetadata(from: sourceURL) {
                if !metadata.title.isEmpty { title = metadata.title }
                if !metadata.author.isEmpty { author = metadata.author }
            }
        }

        // Extract metadata from PDF files (title and author from document attributes)
        if format == .pdf {
            if let metadata = PDFTextParser.readMetadata(from: sourceURL) {
                if !metadata.title.isEmpty { title = metadata.title }
                if !metadata.author.isEmpty { author = metadata.author }
            }
        }

        // Extract metadata from DAISY books (title and author from OPF or ncc.html)
        if format == .daisy {
            if let metadata = try? DAISYParser.readMetadata(from: sourceURL) {
                if !metadata.title.isEmpty { title = metadata.title }
                if !metadata.author.isEmpty { author = metadata.author }
            }
        }

        // Extract metadata from audio files using AVAsset common metadata tags
        var audioAlbum: String?
        var audioGenre: String?
        var audioYear: String?
        if format.isAudio {
            let semaphore = DispatchSemaphore(value: 0)
            let metadataBox = SynchronousResultBox<AudioMetadata>()
            Task.detached {
                let metadata = await AudioPlaybackService.extractFullMetadata(from: sourceURL)
                metadataBox.store(metadata)
                semaphore.signal()
            }
            semaphore.wait()
            if let meta = metadataBox.value {
                if !meta.title.isEmpty { title = meta.title }
                if !meta.artist.isEmpty { author = meta.artist }
                if !meta.album.isEmpty { audioAlbum = meta.album }
                if !meta.genre.isEmpty { audioGenre = meta.genre }
                if !meta.year.isEmpty { audioYear = meta.year }
            }
        }

        // Create .tmb directory name
        let tmbName = TextMouthPaths.tmbName(
            title: title,
            author: author,
            dateAdded: dateAdded,
            bookID: bookID
        )

        // Create the .tmb package directory
        let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
        try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Copy book file into the .tmb package
        let destFile = tmbDir.appendingPathComponent(sourceURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destFile)
        }

        var book = Book(
            id: bookID,
            title: title,
            author: author,
            format: format,
            filePath: destFile.path,
            md5Hash: hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: tmbName,
            sourceFilePath: sourceURL.path,
            audioAlbum: audioAlbum,
            audioGenre: audioGenre,
            audioYear: audioYear,
            epubPublisher: epubMetadata?.publisher,
            epubPublicationDate: epubMetadata?.publicationDate,
            epubISBN: epubMetadata?.isbn,
            epubLanguage: epubMetadata?.language,
            epubIdentifier: epubMetadata?.identifier,
            epubVersion: epubMetadata?.epubVersion
        )

        // Generate cached Markdown content (non-audio books only)
        if !format.isAudio {
            MarkdownCacheService.generateCacheAndStampVersion(for: &book)
        }

        // Write bookInfo.json (after cache generation so version is included)
        book.saveBookInfo()

        return book
    }

    /// Import a ZIP file containing supported book files.
    /// Calls the progress callback with (completed, total) counts.
    /// Pass existingHashes to skip files whose content already exists in the library,
    /// preventing orphaned .tmb packages from being created for duplicates.
    /// Returns imported books together with any per-file failures.
    static func importZip(
        from zipURL: URL,
        toFolder folderPath: String = "",
        existingHashes: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> ZipImportResult {
        try TextMouthPaths.ensureDirectoryStructure()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.unzipItem(at: zipURL, to: tempDir)

        // First pass: find all supported files, including nested ZIP files
        // that contain DAISY packages
        var supportedFiles: [URL] = []
        let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            let ext = fileURL.pathExtension.lowercased()
            // Check nested ZIPs — they may be DAISY or audio packages
            if ext == "zip" {
                if DAISYParser.isDAISYZip(url: fileURL) {
                    supportedFiles.append(fileURL)
                    continue
                }
                // Could also be a nested zip of regular books — extract and scan
                let nestedTemp = tempDir.appendingPathComponent("nested_\(UUID().uuidString)")
                if let _ = try? FileManager.default.createDirectory(at: nestedTemp, withIntermediateDirectories: true),
                   let _ = try? FileManager.default.unzipItem(at: fileURL, to: nestedTemp) {
                    let nestedEnum = FileManager.default.enumerator(at: nestedTemp, includingPropertiesForKeys: nil)
                    while let nestedURL = nestedEnum?.nextObject() as? URL {
                        if BookFormat.detect(from: nestedURL) != nil {
                            supportedFiles.append(nestedURL)
                        }
                    }
                }
                continue
            }
            // Check directories for DAISY packages (unzipped DAISY in a folder)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                if DAISYParser.isDAISYDirectory(url: fileURL) {
                    // Import the directory as a DAISY book by finding its OPF/ncc.html
                    let dirFiles = (try? FileManager.default.contentsOfDirectory(atPath: fileURL.path)) ?? []
                    if let opf = dirFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) {
                        supportedFiles.append(fileURL.appendingPathComponent(opf))
                    } else if let ncc = dirFiles.first(where: { $0.lowercased() == "ncc.html" || $0.lowercased() == "ncc.htm" }) {
                        supportedFiles.append(fileURL.appendingPathComponent(ncc))
                    }
                }
                continue
            }
            if BookFormat.detect(from: fileURL) != nil {
                supportedFiles.append(fileURL)
            }
        }

        return importSupportedFiles(
            supportedFiles,
            toFolder: folderPath,
            existingHashes: existingHashes,
            progress: progress
        )
    }

    /// Import files discovered inside a ZIP while retaining individual errors.
    /// This is separate from archive discovery so partial-import behavior is
    /// deterministic and independently testable.
    static func importSupportedFiles(
        _ supportedFiles: [URL],
        toFolder folderPath: String,
        existingHashes: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil,
        importer: (URL, String) throws -> Book = { url, folder in
            try importFile(from: url, toFolder: folder)
        }
    ) -> ZipImportResult {
        let total = supportedFiles.count
        var books: [Book] = []
        var failures: [ZipImportFailure] = []
        // Track hashes from this batch to avoid creating duplicate .tmbs
        // when the same file appears multiple times in a single zip
        var seenHashes = existingHashes

        // Second pass: import each file, skipping duplicates
        for (index, fileURL) in supportedFiles.enumerated() {
            // Compute hash before creating .tmb to avoid orphaning on duplicate
            if let hash = try? md5Hash(of: fileURL), seenHashes.contains(hash) {
                progress?(index + 1, total)
                continue
            }

            do {
                let book = try importer(fileURL, folderPath)
                seenHashes.insert(book.md5Hash)
                books.append(book)
            } catch {
                failures.append(
                    ZipImportFailure(
                        fileName: fileURL.lastPathComponent,
                        message: error.localizedDescription
                    )
                )
            }
            progress?(index + 1, total)
        }

        return ZipImportResult(books: books, failures: failures)
    }

    /// Delete a book's entire .tmb package.
    /// Respects the "Move to Trash" setting — uses Trash when enabled,
    /// permanent deletion otherwise.
    @MainActor
    static func deleteBookPackage(_ book: Book) throws {
        let tmbDir = book.tmbDirectory
        try removeItemRespectingTrashSetting(at: tmbDir)
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

    /// Migrate a book from the old storage format to a .tmb package
    static func migrateBookToTMB(_ book: Book) throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        if !book.folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
        }

        let sourceURL = URL(fileURLWithPath: book.filePath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw FileImportError.importFailed("Original file not found at \(book.filePath)")
        }

        let tmbName = TextMouthPaths.tmbName(
            title: book.title,
            author: book.author,
            dateAdded: book.dateAdded,
            bookID: book.id
        )
        let tmbDir = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: tmbName)
        try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        let destFile = tmbDir.appendingPathComponent(sourceURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destFile)
        }

        try? FileManager.default.removeItem(at: sourceURL)

        var migrated = book
        migrated.filePath = destFile.path
        migrated.tmbDirectoryName = tmbName

        migrated.saveBookInfo()

        // Generate cached Markdown content for the migrated book
        if !migrated.format.isAudio {
            MarkdownCacheService.generateCacheAndStampVersion(for: &migrated)
            migrated.saveBookInfo()
        }

        return migrated
    }

    /// Delete the original source file after import (if the user chose that option)
    static func deleteOriginalFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
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
        try TextMouthPaths.ensureDirectoryStructure()
        if !folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        }

        let hash = try md5Hash(of: zipURL)
        let dateAdded = Date()
        let bookID = UUID()

        // Open the ZIP and detect DAISY version
        let archive = try Archive(url: zipURL, accessMode: .read)
        let provider = ArchiveFileProvider(archive: archive)

        // Read metadata
        var title = zipURL.deletingPathExtension().lastPathComponent
        var author = "Unknown"
        if let metadata = try? DAISYParser.readMetadata(from: zipURL) {
            if !metadata.title.isEmpty { title = metadata.title }
            if !metadata.author.isEmpty { author = metadata.author }
        }

        let tmbName = TextMouthPaths.tmbName(
            title: title,
            author: author,
            dateAdded: dateAdded,
            bookID: bookID
        )
        let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
        try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Create audio directory
        let audioDir = tmbDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        // Detect version and convert
        let allFiles = provider.listFiles()
        let version: DAISYVersion
        if allFiles.contains(where: { $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm") }) {
            version = .daisy202
        } else {
            version = .daisy3
        }

        let manifest = try DAISYAudioConverter.convertToAudioBook(
            from: provider,
            version: version,
            toDirectory: audioDir
        )

        // Write manifest.json
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: audioDir.appendingPathComponent("manifest.json"))

        let book = Book(
            id: bookID,
            title: title,
            author: author,
            format: .audio,
            filePath: audioDir.path,
            md5Hash: hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: tmbName,
            sourceFilePath: zipURL.path
        )

        book.saveBookInfo()
        return book
    }

    /// Import a ZIP of audio files as a single multi-chapter audio book.
    /// Returns a single Book where each audio file is a chapter.
    static func importAudioZip(from zipURL: URL, toFolder folderPath: String = "") throws -> Book {
        try TextMouthPaths.ensureDirectoryStructure()
        if !folderPath.isEmpty {
            try TextMouthPaths.ensureLibrarySubfolder(folderPath)
        }

        let hash = try md5Hash(of: zipURL)
        let zipName = zipURL.deletingPathExtension().lastPathComponent
        let dateAdded = Date()
        let bookID = UUID()
        let tmbName = TextMouthPaths.tmbName(
            title: zipName,
            author: "Unknown",
            dateAdded: dateAdded,
            bookID: bookID
        )
        let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
        try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Extract ZIP into the .tmb directory
        let audioDir = tmbDir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipURL, to: audioDir)

        // Find audio files
        let audioExtensions = Set(BookFormat.audio.fileExtensions)
        let enumerator = FileManager.default.enumerator(at: audioDir, includingPropertiesForKeys: nil)
        var audioFiles: [URL] = []
        while let fileURL = enumerator?.nextObject() as? URL {
            if audioExtensions.contains(fileURL.pathExtension.lowercased()) {
                audioFiles.append(fileURL)
            }
        }
        audioFiles.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        guard !audioFiles.isEmpty else {
            throw FileImportError.importFailed("No audio files found in ZIP")
        }

        // Check for manifest
        let manifestURL = audioDir.appendingPathComponent("manifest.json")
        var title = zipName
        var author = "Unknown"
        if FileManager.default.fileExists(atPath: manifestURL.path),
           let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(AudioManifest.self, from: data) {
            if let t = manifest.title { title = t }
            if let a = manifest.author { author = a }
        }

        // Use the first audio file as the "main" file path
        let book = Book(
            id: bookID,
            title: title,
            author: author,
            format: .audio,
            filePath: audioDir.path,  // Points to the audio directory
            md5Hash: hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: tmbName,
            sourceFilePath: zipURL.path
        )

        book.saveBookInfo()
        return book
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

    /// Rebuild the .TextMouth directory structure, migrating any books from old storage,
    /// moving misplaced .tmb packages to their correct folders, and adopting orphans.
    static func rebuildDirectoryStructure(library: inout Library) throws {
        try TextMouthPaths.ensureDirectoryStructure()

        // Migrate books that don't have .tmb packages yet
        for i in library.books.indices {
            let book = library.books[i]
            if book.tmbDirectoryName.isEmpty {
                if let migrated = try? migrateBookToTMB(book) {
                    library.books[i] = migrated
                }
            }
        }

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
    }

    /// Move .tmb packages that exist on disk but aren't in the folder their
    /// book's folderPath says they should be in. Updates filePath to match.
    /// This fixes books whose folder assignment was updated in library.json
    /// without the physical .tmb directory being moved.
    @discardableResult
    static func relocateMisplacedTMBPackages(library: inout Library) -> Int {
        let fm = FileManager.default
        var relocated = 0

        for i in library.books.indices {
            let book = library.books[i]
            // Only care about books that have a .tmb and a folder assignment
            guard !book.tmbDirectoryName.isEmpty,
                  !book.folderPath.isEmpty
            else { continue }

            let expectedDir = TextMouthPaths.tmbPath(
                folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
            let rootDir = TextMouthPaths.tmbPath(
                folderPath: "", tmbName: book.tmbDirectoryName)

            // If the .tmb is already in the right place, nothing to do
            if fm.fileExists(atPath: expectedDir.path) { continue }

            // If the .tmb is at root, move it to the correct folder
            guard fm.fileExists(atPath: rootDir.path) else { continue }

            do {
                try TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
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
    /// the disk directory isn't cleaned up.
    static func removeEmptyLibrarySubdirectories(library: Library) {
        let fm = FileManager.default
        let libraryDir = TextMouthPaths.libraryDir
        let knownFolderPaths = Set(library.folders.map { $0.fullPath })

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
            if knownFolderPaths.contains(relativePath) { continue }

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
                if relativePath.isEmpty || knownFolderPaths.contains(relativePath) { break }
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
    @discardableResult
    static func adoptOrphanedTMBPackages(library: inout Library) -> Int {
        let fm = FileManager.default
        let libraryDir = TextMouthPaths.libraryDir

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

            // Find the actual book file inside the .tmb (skip metadata/cache files)
            let tmbContents = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            let bookFileName = tmbContents.first { name in
                !name.hasPrefix(".")
                && name != "bookInfo.json"
                && name != "content.md"
                && name != "cachedAudio"
            }

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
                cacheFormatVersion: info.state.cacheFormatVersion
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
                    updatedBook.saveBookInfo()
                }
            }
        }

        if adopted > 0 {
            print("Adopted \(adopted) orphaned .tmb package(s) into library")
        }
        return adopted
    }
}
