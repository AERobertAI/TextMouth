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
            var audioMeta: AudioMetadata?
            Task {
                audioMeta = await AudioPlaybackService.extractFullMetadata(from: sourceURL)
                semaphore.signal()
            }
            semaphore.wait()
            if let meta = audioMeta {
                if !meta.title.isEmpty { title = meta.title }
                if !meta.artist.isEmpty { author = meta.artist }
                if !meta.album.isEmpty { audioAlbum = meta.album }
                if !meta.genre.isEmpty { audioGenre = meta.genre }
                if !meta.year.isEmpty { audioYear = meta.year }
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
            audioYear: audioYear
        )

        // Generate cached Markdown content (non-audio books only)
        if !format.isAudio {
            MarkdownCacheService.generateCache(for: book)
            book.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
        }

        // Write bookInfo.json (after cache generation so version is included)
        book.saveBookInfo()

        return book
    }

    /// Import a ZIP file containing supported book files.
    /// Calls the progress callback with (completed, total) counts.
    /// Pass existingHashes to skip files whose content already exists in the library,
    /// preventing orphaned .tmb packages from being created for duplicates.
    /// Returns the imported books.
    static func importZip(
        from zipURL: URL,
        toFolder folderPath: String = "",
        existingHashes: Set<String> = [],
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> [Book] {
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

        let total = supportedFiles.count
        var books: [Book] = []
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

            if let book = try? importFile(from: fileURL, toFolder: folderPath) {
                seenHashes.insert(book.md5Hash)
                books.append(book)
            }
            progress?(index + 1, total)
        }

        return books
    }

    /// Delete a book's entire .tmb package.
    /// Respects the "Move to Trash" setting — uses Trash when enabled,
    /// permanent deletion otherwise.
    static func deleteBookPackage(_ book: Book) {
        let tmbDir = book.tmbDirectory
        removeItemRespectingTrashSetting(at: tmbDir)
    }

    /// Delete just the book file from a .tmb (legacy compat - prefer deleteBookPackage)
    static func deleteBookFile(at path: String) {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.pathExtension == "tmb" {
            removeItemRespectingTrashSetting(at: parent)
        } else {
            removeItemRespectingTrashSetting(at: url)
        }
    }

    /// Remove an item from disk, using Trash if the setting is enabled.
    /// Falls back to permanent deletion if trashing fails (e.g. external volumes).
    static func removeItemRespectingTrashSetting(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if ConfigService.shared.config.moveToTrashInsteadOfDeleting {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Trash failed (external volume, permissions, etc.) — fall back to permanent delete
                try? FileManager.default.removeItem(at: url)
            }
        } else {
            try? FileManager.default.removeItem(at: url)
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

        // Generate cached Markdown content for the migrated book
        if !migrated.format.isAudio {
            MarkdownCacheService.generateCache(for: migrated)
            migrated.cacheFormatVersion = MarkdownCacheService.currentCacheVersion
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

        let tmbName = TextMouthPaths.tmbName(title: title, author: author, dateAdded: dateAdded)
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
                audioYear: info.metadata.audioYear
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
