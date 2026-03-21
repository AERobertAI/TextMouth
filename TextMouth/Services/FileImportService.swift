import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ZIPFoundation

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

enum FileImportService {

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

        // Extract metadata from EPUB files before creating the .tmb
        if format == .epub {
            if let metadata = try? EPUBParser.readMetadata(url: sourceURL) {
                if !metadata.title.isEmpty { title = metadata.title }
                if !metadata.author.isEmpty { author = metadata.author }
            }
        }

        // Create .tmb directory name
        let tmbName = TextMouthPaths.tmbName(title: title, author: author, dateAdded: dateAdded)

        // Create the .tmb package directory
        let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
        try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

        // Copy book file into the .tmb package
        let destFile = tmbDir.appendingPathComponent(sourceURL.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destFile.path) {
            try FileManager.default.copyItem(at: sourceURL, to: destFile)
        }

        let book = Book(
            id: bookID,
            title: title,
            author: author,
            format: format,
            filePath: destFile.path,
            md5Hash: hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            tmbDirectoryName: tmbName,
            sourceFilePath: sourceURL.path
        )

        // Write bookInfo.json
        book.saveBookInfo()

        return book
    }

    /// Import a ZIP file containing supported book files.
    /// Calls the progress callback with (completed, total) counts.
    /// Returns the imported books.
    static func importZip(
        from zipURL: URL,
        toFolder folderPath: String = "",
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [Book] {
        try TextMouthPaths.ensureDirectoryStructure()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try FileManager.default.unzipItem(at: zipURL, to: tempDir)

        // First pass: find all supported files
        var supportedFiles: [URL] = []
        let enumerator = FileManager.default.enumerator(at: tempDir, includingPropertiesForKeys: nil)
        while let fileURL = enumerator?.nextObject() as? URL {
            if BookFormat.detect(from: fileURL) != nil {
                supportedFiles.append(fileURL)
            }
        }

        let total = supportedFiles.count
        var books: [Book] = []

        // Second pass: import each file
        for (index, fileURL) in supportedFiles.enumerated() {
            if let book = try? importFile(from: fileURL, toFolder: folderPath) {
                books.append(book)
            }
            progress?(index + 1, total)
        }

        return books
    }

    /// Delete a book's entire .tmb package
    static func deleteBookPackage(_ book: Book) {
        let tmbDir = book.tmbDirectory
        try? FileManager.default.removeItem(at: tmbDir)
    }

    /// Delete just the book file from a .tmb (legacy compat - prefer deleteBookPackage)
    static func deleteBookFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.pathExtension == "tmb" {
            try? FileManager.default.removeItem(at: parent)
        } else {
            try? FileManager.default.removeItem(atPath: path)
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

        let tmbName = TextMouthPaths.tmbName(title: book.title, author: book.author, dateAdded: book.dateAdded)
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
        let tmbName = TextMouthPaths.tmbName(title: zipName, author: "Unknown", dateAdded: dateAdded)
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

    /// Rebuild the .TextMouth directory structure, migrating any books from old storage
    static func rebuildDirectoryStructure(library: inout Library) throws {
        try TextMouthPaths.ensureDirectoryStructure()

        for i in library.books.indices {
            let book = library.books[i]
            if book.tmbDirectoryName.isEmpty {
                if let migrated = try? migrateBookToTMB(book) {
                    library.books[i] = migrated
                }
            }
        }

        if let oldDir = TextMouthPaths.oldAppSupportDir,
           FileManager.default.fileExists(atPath: oldDir.path) {
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: oldDir.path)) ?? []
            if contents.isEmpty {
                try? FileManager.default.removeItem(at: oldDir)
            }
        }
    }
}
