import SwiftUI
import Combine
import ZIPFoundation

/// Extension for file import operations — importing from Finder, ZIP archives,
/// TMB packages, and text input.
extension LibraryViewModel {

    /// Import files and post notification to open them
    func importAndOpenFiles(urls: [URL]) {
        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

            let ext = url.pathExtension.lowercased()

            if ext == "tmb" {
                // Opening a .tmb package — find and open the book
                openTMBPackage(from: url)
            } else if ext == "zip" {
                // Async zip import with progress
                importZipAsync(from: url, toFolder: "")
            } else {
                // Single file import
                do {
                    let book = try FileImportService.importFile(from: url)
                    if addBookCheckingDuplicate(book, toFolder: "") {
                        save()
                        if let added = library.books.first(where: { $0.md5Hash == book.md5Hash }) {
                            NotificationCenter.default.post(name: .openBookWindow, object: added.id)
                        }
                    }
                    handleOriginalFileDeletion(url: url)
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }

    // MARK: - TMB Package Opening

    /// Open a .tmb package — find the matching book in library or import it, then open the reader
    func openTMBPackage(from url: URL) {
        // First check if we already have this book by matching the tmb directory name
        let tmbName = url.lastPathComponent
        if let existing = library.books.first(where: { $0.tmbDirectoryName == tmbName }) {
            NotificationCenter.default.post(name: .openBookWindow, object: existing.id)
            return
        }

        // Also try matching by bookInfo.json contents
        if let info = try? BookInfo.load(from: url) {
            // Check by book ID
            if let existing = library.books.first(where: { $0.id == info.metadata.bookID }) {
                NotificationCenter.default.post(name: .openBookWindow, object: existing.id)
                return
            }
            // Check by hash
            if let existing = library.books.first(where: { $0.md5Hash == info.metadata.md5Hash }) {
                NotificationCenter.default.post(name: .openBookWindow, object: existing.id)
                return
            }

            // Not in library — add it
            let bookFilePath = url.appendingPathComponent(info.metadata.originalFileName).path
            guard FileManager.default.fileExists(atPath: bookFilePath) else { return }

            let book = Book(
                id: info.metadata.bookID,
                title: info.metadata.title,
                author: info.metadata.author,
                format: info.metadata.format,
                filePath: bookFilePath,
                md5Hash: info.metadata.md5Hash,
                folderPath: info.metadata.folderPath,
                dateAdded: info.metadata.dateAdded,
                lastOpened: info.metadata.lastOpened,
                readingPosition: info.state.readingPosition,
                bookmarks: info.bookmarks,
                totalWordCount: info.state.totalWordCount,
                totalCharacterCount: info.state.totalCharacterCount,
                tmbDirectoryName: tmbName
            )

            library.addBook(book)
            save()
            NotificationCenter.default.post(name: .openBookWindow, object: book.id)
        }
    }

    // MARK: - Async Zip Import

    /// Check if a ZIP file contains audio files (for audio book ZIP import).
    func isAudioZip(url: URL) -> Bool {
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
        isImporting = true
        importProgressCurrent = 0
        importProgressTotal = 0
        importProgressMessage = "Extracting archive..."

        // Check if this is a DAISY ZIP (contains OPF or ncc.html)
        if DAISYParser.isDAISYZip(url: url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let book: Book
                    // Check if the DAISY package has audio content
                    if let archive = try? Archive(url: url, accessMode: .read) {
                        let provider = ArchiveFileProvider(archive: archive)
                        if DAISYAudioConverter.hasAudio(in: provider) {
                            book = try FileImportService.importDAISYAudioZip(
                                from: url, toFolder: folderPath
                            )
                        } else {
                            book = try FileImportService.importFile(
                                from: url, toFolder: folderPath
                            )
                        }
                    } else {
                        book = try FileImportService.importFile(
                            from: url, toFolder: folderPath
                        )
                    }
                    DispatchQueue.main.async {
                        self.library.addBook(book)
                        self.save()
                        self.isImporting = false
                        self.importProgressMessage = ""
                        self.handleOriginalFileDeletion(url: url)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isImporting = false
                        self.errorMessage = error.localizedDescription
                        self.showError = true
                    }
                }
            }
            return
        }

        // Check if this is an audio ZIP
        if isAudioZip(url: url) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                do {
                    let book = try FileImportService.importAudioZip(from: url, toFolder: folderPath)
                    DispatchQueue.main.async {
                        self.library.addBook(book)
                        self.save()
                        self.isImporting = false
                        self.importProgressMessage = ""
                        self.handleOriginalFileDeletion(url: url)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isImporting = false
                        self.errorMessage = error.localizedDescription
                        self.showError = true
                    }
                }
            }
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            do {
                // Pass existing library hashes so zip import can skip duplicates
                // instead of creating orphaned .tmb packages
                let existingHashes = Set(self.library.books.map { $0.md5Hash })
                let books = try FileImportService.importZip(
                    from: url,
                    toFolder: folderPath,
                    existingHashes: existingHashes
                ) { completed, total in
                    DispatchQueue.main.async {
                        self.importProgressCurrent = completed
                        self.importProgressTotal = total
                        self.importProgressMessage = "Importing book \(completed) of \(total)..."
                    }
                }

                DispatchQueue.main.async {
                    for book in books {
                        self.library.addBook(book)
                    }
                    self.save()
                    self.isImporting = false
                    self.importProgressMessage = ""

                    self.handleOriginalFileDeletion(url: url)

                    // Offer to create a folder for zip contents
                    if books.count > 1 {
                        self.pendingZipBooks = books
                        self.pendingZipFolderPath = folderPath
                        self.showZipFolderDialog = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isImporting = false
                    self.importProgressMessage = ""
                    self.errorMessage = error.localizedDescription
                    self.showError = true
                }
            }
        }
    }

    // MARK: - Import

    /// Create a new book from user-entered text (paste/type).
    func createBookFromText(title: String, author: String, text: String, toFolder folderPath: String = "") {
        do {
            try TextMouthPaths.ensureDirectoryStructure()

            // Write text to a temp file
            let sanitizedTitle = title.isEmpty ? "Untitled" : title
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

            let fileName = "\(sanitizedTitle).txt"
            let filePath = tmbDir.appendingPathComponent(fileName)
            try text.write(to: filePath, atomically: true, encoding: .utf8)

            // Compute hash from the written file
            let hash = (try? FileImportService.md5Hash(of: filePath)) ?? "text-\(text.count)"

            let book = Book(
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
            library.addBook(book)
            // Generate cached Markdown content and stamp version
            MarkdownCacheService.generateCache(for: book)
            if let idx = library.books.firstIndex(where: { $0.id == book.id }) {
                library.books[idx].cacheFormatVersion = MarkdownCacheService.currentCacheVersion
            }
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books.first(where: { $0.id == book.id }) ?? book)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

    /// Import one or more files from URLs into the specified folder.
    func importFiles(urls: [URL], toFolder folderPath: String = "") {
        for url in urls {
            guard url.startAccessingSecurityScopedResource() else { continue }
            defer { url.stopAccessingSecurityScopedResource() }

            let ext = url.pathExtension.lowercased()

            if ext == "zip" {
                importZipAsync(from: url, toFolder: folderPath)
            } else {
                do {
                    let book = try FileImportService.importFile(from: url, toFolder: folderPath)
                    addBookCheckingDuplicate(book, toFolder: folderPath)
                    handleOriginalFileDeletion(url: url)
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
        save()
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
