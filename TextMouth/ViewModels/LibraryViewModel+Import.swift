import SwiftUI
import Combine
import ZIPFoundation

/// Serial background executor for imports. Activity callbacks are delivered on
/// the main queue, while operations always run off the UI thread.
final class SerialImportQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.textmouth.imports", qos: .userInitiated)
    private let stateLock = NSLock()
    private var activeCount = 0
    var onActivityChanged: (@MainActor @Sendable (Int) -> Void)?

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        updateCount(by: 1)
        queue.async { [weak self] in
            operation()
            self?.updateCount(by: -1)
        }
    }

    private func updateCount(by delta: Int) {
        stateLock.lock()
        activeCount += delta
        let count = activeCount
        let callback = onActivityChanged
        stateLock.unlock()
        DispatchQueue.main.async { callback?(count) }
    }
}

/// Extension for file import operations — importing from Finder, ZIP archives,
/// TMB packages, and text input.
extension LibraryViewModel {

    /// Import files and post notification to open them
    func importAndOpenFiles(urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()

            if ext == "tmb" {
                openTMBPackage(from: url)
            } else if ext == "zip" {
                importZipAsync(from: url, toFolder: "")
            } else {
                importSingleFileAsync(from: url, toFolder: "", openAfterImport: true)
            }
        }
    }

    // MARK: - TMB Package Opening

    /// Open a .tmb package — find the matching book in library or import it, then open the reader
    func openTMBPackage(from url: URL) {
        importOperationQueue.enqueue { [weak self] in
            guard let self else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let inspection = try FileImportService.inspectTMBPackage(at: url)
                let info = inspection.info
                let managedPackageBook = FileImportService.bookFromManagedPackage(
                    inspection: inspection,
                    packageURL: url
                )
                var shouldCopy = true
                DispatchQueue.main.sync {
                    if let existingIndex = self.library.books.firstIndex(where: {
                        $0.id == info.metadata.bookID
                    }) {
                        let existing = self.library.books[existingIndex]
                        if let managedPackageBook {
                            let repaired = FileImportService.reconciledLibraryBook(
                                existing,
                                with: managedPackageBook
                            )
                            self.library.books[existingIndex] = repaired
                            if repaired != existing {
                                self.save()
                                let message = "TMB_RECONCILE: book=\(existing.id.uuidString.prefix(8)) folder='\(existing.folderPath)'→'\(repaired.folderPath)' pathExists=\(FileManager.default.fileExists(atPath: repaired.filePath))"
                                TextMouthPaths.appendLog(
                                    to: TextMouthPaths.logsDir.appendingPathComponent("textmouth_debug.log"),
                                    message: message
                                )
                            }
                        }
                        shouldCopy = false
                        NotificationCenter.default.post(name: .openBookWindow, object: existing.id)
                    } else if let existing = self.library.books.first(where: {
                        $0.md5Hash == info.metadata.md5Hash
                    }) {
                        // A hash-only match can represent a deliberate second
                        // package with a different ID. Open the known book
                        // without relocating its Library record.
                        shouldCopy = false
                        NotificationCenter.default.post(name: .openBookWindow, object: existing.id)
                    }
                }
                guard shouldCopy else { return }
                let book = try FileImportService.importTMBPackage(from: url)
                DispatchQueue.main.sync {
                    self.library.addBook(book)
                    self.save()
                    NotificationCenter.default.post(name: .openBookWindow, object: book.id)
                }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    // MARK: - Async Zip Import

    /// Check if a ZIP file contains audio files (for audio book ZIP import).
    nonisolated static func isAudioZip(url: URL) -> Bool {
        guard let archive = Archive(url: url, accessMode: .read) else { return false }
        let audioExtensions = Set(BookFormat.audio.fileExtensions)
        var hasAudio = false
        var hasNonAudio = false
        for entry in archive {
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            if ext.isEmpty || ext == "json" { continue } // Skip directories and manifest
            if audioExtensions.contains(ext) {
                hasAudio = true
            } else if BookFormat.detect(from: URL(fileURLWithPath: entry.path)) != nil {
                hasNonAudio = true
            }
        }
        return hasAudio && !hasNonAudio
    }

    /// Import a zip file asynchronously with progress tracking
    func importZipAsync(from url: URL, toFolder folderPath: String) {
        importOperationQueue.enqueue { [weak self] in
            guard let self = self else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            DispatchQueue.main.async { self.beginImportProgress("Extracting archive...") }
            do {
                if DAISYParser.isDAISYZip(url: url) {
                    let book: Book
                    if let archive = try? Archive(url: url, accessMode: .read),
                       DAISYAudioConverter.hasAudio(in: ArchiveFileProvider(archive: archive)) {
                        book = try FileImportService.importDAISYAudioZip(from: url, toFolder: folderPath)
                    } else {
                        book = try FileImportService.importFile(from: url, toFolder: folderPath)
                    }
                    DispatchQueue.main.sync { self.completeSingleImportedBook(book, originalURL: url) }
                    return
                }
                if Self.isAudioZip(url: url) {
                    let book = try FileImportService.importAudioZip(from: url, toFolder: folderPath)
                    DispatchQueue.main.sync { self.completeSingleImportedBook(book, originalURL: url) }
                    return
                }

                var existingHashes: Set<String> = []
                DispatchQueue.main.sync {
                    existingHashes = Set(self.library.books.map(\.md5Hash))
                }
                let result = try FileImportService.importZip(
                    from: url,
                    toFolder: folderPath,
                    existingHashes: existingHashes,
                    progress: { completed, total in
                        DispatchQueue.main.async {
                            self.importProgressCurrent = completed
                            self.importProgressTotal = total
                            self.importProgressMessage = "Importing book \(completed) of \(total)..."
                        }
                    }
                )
                DispatchQueue.main.sync {
                    for book in result.books { self.library.addBook(book) }
                    self.save()
                    self.importProgressMessage = ""
                    if let failureSummary = result.failureSummary {
                        self.errorMessage = failureSummary
                        self.showError = true
                    }
                    self.handleOriginalFileDeletion(url: url)
                    if result.books.count > 1 {
                        self.pendingZipBooks = result.books
                        self.pendingZipFolderPath = folderPath
                        self.showZipFolderDialog = true
                    }
                }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    func importSingleFileAsync(from url: URL, toFolder folderPath: String, openAfterImport: Bool = false) {
        importOperationQueue.enqueue { [weak self] in
            guard let self else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            DispatchQueue.main.async { self.beginImportProgress("Importing \(url.lastPathComponent)...") }
            do {
                let book = try FileImportService.importFile(from: url, toFolder: folderPath)
                DispatchQueue.main.sync {
                    if self.addBookCheckingDuplicate(book, toFolder: folderPath, originalURL: url) {
                        self.save()
                        self.handleOriginalFileDeletion(url: url)
                        if openAfterImport {
                            NotificationCenter.default.post(name: .openBookWindow, object: book.id)
                        }
                    }
                    self.importProgressMessage = ""
                }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    private func beginImportProgress(_ message: String) {
        importProgressCurrent = 0
        importProgressTotal = 0
        importProgressMessage = message
    }

    private func completeSingleImportedBook(_ book: Book, originalURL: URL) {
        library.addBook(book)
        save()
        importProgressMessage = ""
        handleOriginalFileDeletion(url: originalURL)
    }

    private func presentImportError(_ error: Error) {
        importProgressMessage = ""
        errorMessage = error.localizedDescription
        showError = true
    }

    // MARK: - Import

    /// Create a new book from user-entered text (paste/type).
    func createBookFromText(title: String, author: String, text: String, toFolder folderPath: String = "") {
        importOperationQueue.enqueue { [weak self] in
            do {
                try TextMouthPaths.ensureDirectoryStructure()
                let sanitizedTitle = TextImportPolicy.resolvedTitle(title)
                let bookID = UUID()
                let dateAdded = Date()
                let tmbName = TextMouthPaths.tmbName(
                    title: sanitizedTitle,
                    author: author,
                    dateAdded: dateAdded,
                    bookID: bookID
                )
                let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
                try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

                let fileName = TextImportPolicy.textFilename(for: sanitizedTitle)
                let filePath = tmbDir.appendingPathComponent(fileName)
                try text.write(to: filePath, atomically: true, encoding: .utf8)
                let hash = (try? FileImportService.md5Hash(of: filePath)) ?? "text-\(text.count)"

                var book = Book(
                    id: bookID,
                    title: sanitizedTitle,
                    author: author.isEmpty ? "Unknown" : author,
                    format: .txt,
                    filePath: filePath.path,
                    md5Hash: hash,
                    folderPath: folderPath,
                    dateAdded: dateAdded,
                    tmbDirectoryName: tmbName
                )
                let index = MarkdownCacheService.generateCacheAnalyzeAndStamp(for: &book)
                try book.saveBookInfoThrowing(contentIndex: index)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.library.addBook(book)
                    self.save()
                }
            } catch {
                DispatchQueue.main.async { self?.presentImportError(error) }
            }
        }
    }

    /// Import one or more files from URLs into the specified folder.
    func importFiles(urls: [URL], toFolder folderPath: String = "") {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                importZipAsync(from: url, toFolder: folderPath)
            } else {
                importSingleFileAsync(from: url, toFolder: folderPath)
            }
        }
    }

    /// Listen for files opened via Finder "Open With" or drag-to-dock
    func setupFinderOpenHandler() {
        NotificationCenter.default.publisher(for: .openFilesFromFinder)
            .compactMap { $0.userInfo?["urls"] as? [URL] }
            .sink { [weak self] urls in
                self?.importAndOpenFiles(urls: urls)
            }
            .store(in: &cancellables)
    }
}
