import SwiftUI
import Combine
import ZIPFoundation

enum LibrarySortField: String, CaseIterable, Codable {
    case title = "Title"
    case author = "Author"
    case dateAdded = "Date Added"
    case lastOpened = "Last Opened"
    case fileSize = "File Size"
    case manual = "Manual Order"

    var accessibilityLabel: String { rawValue }
}

enum LibraryCategory: String, CaseIterable, Codable {
    case folders = "Folders"
    case allItems = "All Items"
    case noFolder = "No Folder"
    case recent = "Recent"
}

/// App-level library data and operations.
/// Per-window navigation state (folder path, category, search) lives in the views.
class LibraryViewModel: ObservableObject {
    @Published var library = Library()
    @Published var errorMessage: String?
    @Published var showError = false
    /// Book IDs currently open in a reader window
    @Published var openBookIDs: Set<UUID> = []
    /// Incremented periodically to force library views to refresh time estimates
    @Published var refreshTick: UInt = 0

    /// For zip import: show dialog to create a folder for imported books
    @Published var showZipFolderDialog = false
    @Published var pendingZipBooks: [Book] = []
    @Published var pendingZipFolderPath: String = ""

    /// For asking about deleting original file
    @Published var showDeleteOriginalDialog = false
    @Published var pendingOriginalURL: URL?

    /// Book removal confirmation
    @Published var showRemoveBookDialog = false
    @Published var pendingRemoveBook: Book?

    /// Duplicate import detection
    @Published var showDuplicateDialog = false
    @Published var pendingDuplicateBook: Book?
    @Published var pendingDuplicateExisting: Book?
    @Published var pendingDuplicateFolder: String = ""

    /// Import progress tracking
    @Published var isImporting = false
    @Published var importProgressCurrent = 0
    @Published var importProgressTotal = 0
    @Published var importProgressMessage = ""

    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?
    private let configService = ConfigService.shared

    init() {
        // Migrate from old sandbox container if needed (before loading library)
        migrateFromSandboxContainer()

        // Ensure directory structure exists on first launch
        try? TextMouthPaths.ensureDirectoryStructure()

        library = LibraryPersistenceService.load()
        migrateOldBooksIfNeeded()
        setupFinderOpenHandler()
        startRefreshTimer()
        calculateMissingBookStats()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    /// Migrate any books still using old storage paths to .tmb packages,
    /// and fix any stale file paths pointing to old locations.
    private func migrateOldBooksIfNeeded() {
        var needsSave = false

        // Fix stale file paths — if the file doesn't exist at the stored path
        // but the .tmb is in the current library dir, update the path
        for i in library.books.indices {
            let book = library.books[i]
            if !book.tmbDirectoryName.isEmpty &&
               !FileManager.default.fileExists(atPath: book.filePath) {
                // Try to find the file inside the .tmb at the current library location
                let tmbDir = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                let correctPath = tmbDir.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: correctPath) {
                    library.books[i].filePath = correctPath
                    needsSave = true
                }
            }
        }

        // Migrate books with no .tmb package
        for i in library.books.indices {
            if library.books[i].tmbDirectoryName.isEmpty {
                if let migrated = try? FileImportService.migrateBookToTMB(library.books[i]) {
                    library.books[i] = migrated
                    needsSave = true
                }
            }
        }

        if needsSave {
            save()
        }
    }

    /// Parse any books that don't have word/char counts yet so the library
    /// can show time estimates without requiring each book to be opened first.
    private func calculateMissingBookStats() {
        let booksNeedingStats = library.books.filter { book in
            if book.format.isAudio {
                return book.audioDuration == nil
            }
            return book.totalWordCount == nil || book.totalCharacterCount == nil
        }
        guard !booksNeedingStats.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for book in booksNeedingStats {
                guard let self = self else { return }
                let url = URL(fileURLWithPath: book.filePath)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                do {
                    let parsed = try BookParser.parse(url: url, format: book.format)
                    let wordCount = parsed.totalWordCount
                    let charCount = parsed.totalCharacterCount

                    DispatchQueue.main.async {
                        self.library.updateWordCounts(bookID: book.id, wordCount: wordCount, charCount: charCount)

                        if book.format.isAudio {
                            if let index = self.library.books.firstIndex(where: { $0.id == book.id }) {
                                self.library.books[index].audioDuration = Double(charCount) / 10.0
                            }
                        }

                        self.save()
                        LibraryPersistenceService.saveBookInfo(for: self.library.books.first(where: { $0.id == book.id }) ?? book)
                    }
                } catch {
                    // Silently skip books that fail to parse — they'll be parsed when opened
                }
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshTick &+= 1
            }
        }
    }

    func registerOpenBook(_ id: UUID) {
        openBookIDs.insert(id)
        // Track last opened book for quick-resume
        let config = ConfigService.shared
        config.config.lastOpenedBookID = id.uuidString
        config.saveToDisk()
    }

    /// The most recently opened book (for quick-resume on launch)
    var lastOpenedBook: Book? {
        let idString = ConfigService.shared.config.lastOpenedBookID
        guard !idString.isEmpty, let uuid = UUID(uuidString: idString) else { return nil }
        return library.books.first { $0.id == uuid }
    }

    func unregisterOpenBook(_ id: UUID) {
        openBookIDs.remove(id)
    }

    /// Listen for files opened via Finder "Open With" or drag-to-dock
    private func setupFinderOpenHandler() {
        NotificationCenter.default.publisher(for: .openFilesFromFinder)
            .compactMap { $0.userInfo?["urls"] as? [URL] }
            .sink { [weak self] urls in
                self?.importAndOpenFiles(urls: urls)
            }
            .store(in: &cancellables)
    }

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
    private func openTMBPackage(from url: URL) {
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

    /// Import a zip file asynchronously with progress tracking
    /// Check if a ZIP file contains audio files (for audio book ZIP import).
    private func isAudioZip(url: URL) -> Bool {
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

    private func importZipAsync(from url: URL, toFolder folderPath: String) {
        isImporting = true
        importProgressCurrent = 0
        importProgressTotal = 0
        importProgressMessage = "Extracting archive..."

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
                let books = try FileImportService.importZip(from: url, toFolder: folderPath) { completed, total in
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
            let tmbName = TextMouthPaths.tmbName(title: sanitizedTitle, author: author, dateAdded: Date())
            let tmbDir = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: tmbName)
            try FileManager.default.createDirectory(at: tmbDir, withIntermediateDirectories: true)

            let fileName = "\(sanitizedTitle).txt"
            let filePath = tmbDir.appendingPathComponent(fileName)
            try text.write(to: filePath, atomically: true, encoding: .utf8)

            // Compute hash from the written file
            let hash = (try? FileImportService.md5Hash(of: filePath)) ?? "text-\(text.count)"

            let book = Book(
                title: sanitizedTitle,
                author: author.isEmpty ? "Unknown" : author,
                format: .txt,
                filePath: filePath.path,
                md5Hash: hash,
                folderPath: folderPath,
                tmbDirectoryName: tmbName
            )
            library.addBook(book)
            save()
            LibraryPersistenceService.saveBookInfo(for: book)
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }

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

    // MARK: - Duplicate Detection

    /// Add a book, checking for duplicates by hash or source path.
    /// Returns true if added immediately, false if a duplicate dialog is shown.
    @discardableResult
    private func addBookCheckingDuplicate(_ book: Book, toFolder folderPath: String) -> Bool {
        // Check for existing book with same hash
        if let existing = library.books.first(where: { $0.md5Hash == book.md5Hash }) {
            // Same file content — show replace/duplicate dialog
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
            showDuplicateDialog = true
            return false
        }

        // Check for existing book imported from the same source path
        if let sourcePath = book.sourceFilePath, !sourcePath.isEmpty,
           let existing = library.books.first(where: { $0.sourceFilePath == sourcePath }) {
            pendingDuplicateBook = book
            pendingDuplicateExisting = existing
            pendingDuplicateFolder = folderPath
            showDuplicateDialog = true
            return false
        }

        library.addBook(book)
        return true
    }

    /// Replace the existing book with the new duplicate (updates .tmb, refreshes timestamp)
    func replaceDuplicate() {
        guard let newBook = pendingDuplicateBook,
              let existing = pendingDuplicateExisting else { return }

        // Delete old .tmb
        FileImportService.deleteBookPackage(existing)
        library.removeBook(id: existing.id)

        // Add new book (already has its own .tmb from import)
        library.addBook(newBook)
        save()

        clearDuplicateState()
    }

    /// Keep both the existing and the new book as separate entries
    func keepDuplicate() {
        guard var newBook = pendingDuplicateBook else { return }

        // The new book was already imported to its .tmb by importFile,
        // but Library.addBook won't add it because the hash matches.
        // Force-add by appending directly.
        library.books.append(newBook)
        save()

        clearDuplicateState()
    }

    /// Cancel the duplicate import — remove the newly created .tmb
    func cancelDuplicate() {
        if let newBook = pendingDuplicateBook {
            FileImportService.deleteBookPackage(newBook)
        }
        clearDuplicateState()
    }

    private func clearDuplicateState() {
        pendingDuplicateBook = nil
        pendingDuplicateExisting = nil
        pendingDuplicateFolder = ""
        showDuplicateDialog = false
    }

    /// Move zip-imported books into a newly created folder
    func moveZipBooksToFolder(folderName: String) {
        guard !folderName.isEmpty else { return }
        let parentPath = pendingZipFolderPath
        if let folder = library.createFolder(name: folderName, parentPath: parentPath) {
            for book in pendingZipBooks {
                if let idx = library.books.firstIndex(where: { $0.md5Hash == book.md5Hash }) {
                    library.books[idx].folderPath = folder.fullPath
                    moveTMBToFolder(book: &library.books[idx], newFolderPath: folder.fullPath)
                }
            }
        }
        pendingZipBooks = []
        save()
    }

    /// Handle deleting the original file based on user preference
    private func handleOriginalFileDeletion(url: URL) {
        let behavior = configService.config.importDeleteBehavior
        switch behavior {
        case .keepOriginal:
            break
        case .deleteAfterImport:
            FileImportService.deleteOriginalFile(at: url)
        case .askEachTime:
            pendingOriginalURL = url
            showDeleteOriginalDialog = true
        }
    }

    // MARK: - Book Operations

    func markBookOpened(_ bookID: UUID) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].lastOpened = Date()
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    /// Request removal of a book — shows confirmation if enabled
    func removeBook(_ book: Book) {
        if configService.config.confirmBeforeDelete {
            pendingRemoveBook = book
            showRemoveBookDialog = true
        } else {
            // Default: remove from library and delete .tmb
            performRemoveBook(book, deleteTMB: true)
        }
    }

    /// Remove a book from the library index only, leaving the .tmb on disk
    func removeBookFromLibraryOnly(_ book: Book) {
        library.removeBook(id: book.id)
        save()
    }

    /// Remove a book from the library and delete its .tmb package
    func removeBookAndDelete(_ book: Book) {
        performRemoveBook(book, deleteTMB: true)
    }

    private func performRemoveBook(_ book: Book, deleteTMB: Bool) {
        if deleteTMB {
            FileImportService.deleteBookPackage(book)
        }
        library.removeBook(id: book.id)
        save()
    }

    func moveBook(_ book: Book, toFolder path: String) {
        guard let idx = library.books.firstIndex(where: { $0.id == book.id }) else { return }
        library.books[idx].folderPath = path
        moveTMBToFolder(book: &library.books[idx], newFolderPath: path)
        save()
    }

    /// Move a .tmb package directory to a new library subfolder
    private func moveTMBToFolder(book: inout Book, newFolderPath: String) {
        guard !book.tmbDirectoryName.isEmpty else { return }

        let oldTmbDir = book.tmbDirectory
        try? TextMouthPaths.ensureLibrarySubfolder(newFolderPath)
        let newTmbDir = TextMouthPaths.tmbPath(folderPath: newFolderPath, tmbName: book.tmbDirectoryName)

        guard oldTmbDir != newTmbDir else { return }

        do {
            if FileManager.default.fileExists(atPath: oldTmbDir.path) {
                try FileManager.default.moveItem(at: oldTmbDir, to: newTmbDir)
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                book.filePath = newTmbDir.appendingPathComponent(fileName).path
            }
        } catch {
            print("Failed to move .tmb package: \(error)")
        }
    }

    func updateReadingPosition(bookID: UUID, position: ReadingPosition) {
        library.updateReadingPosition(bookID: bookID, position: position)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func updateBookMetadata(_ updatedBook: Book) {
        if let index = library.books.firstIndex(where: { $0.id == updatedBook.id }) {
            library.books[index].title = updatedBook.title
            library.books[index].author = updatedBook.author
            library.books[index].md5Hash = updatedBook.md5Hash
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    func updatePlaybackTimestamps(bookID: UUID, started: Date?, stopped: Date?) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].lastPlaybackStarted = started
            library.books[index].lastPlaybackStopped = stopped
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    /// Get the next book in the same folder, sorted by manual order then title.
    func nextBookInFolder(after book: Book) -> Book? {
        let folderBooks = library.booksInFolder(book.folderPath)
            .sorted { a, b in
                let orderA = a.manualSortOrder ?? Int.max
                let orderB = b.manualSortOrder ?? Int.max
                if orderA != orderB { return orderA < orderB }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == book.id }) else { return nil }
        let nextIndex = currentIndex + 1
        guard nextIndex < folderBooks.count else { return nil }
        return folderBooks[nextIndex]
    }

    /// Update manual sort order for a book within its folder.
    func updateManualSortOrder(bookID: UUID, order: Int) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].manualSortOrder = order
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    /// Reorder books in a folder by moving from source indices to destination.
    func reorderBooksInFolder(folderPath: String, from source: IndexSet, to destination: Int) {
        var folderBooks = library.booksInFolder(folderPath)
            .sorted { a, b in
                let orderA = a.manualSortOrder ?? Int.max
                let orderB = b.manualSortOrder ?? Int.max
                if orderA != orderB { return orderA < orderB }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        folderBooks.move(fromOffsets: source, toOffset: destination)
        // Assign new sort orders
        for (i, book) in folderBooks.enumerated() {
            updateManualSortOrder(bookID: book.id, order: i)
        }
    }

    func updateEndOfBookBehavior(bookID: UUID, behavior: String?) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].localEndOfBookBehavior = behavior
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    func updateSkippedHeadings(bookID: UUID, skippedIDs: [String]) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].skippedHeadingIDs = skippedIDs.isEmpty ? nil : skippedIDs
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    func updateLocalVoiceAndSpeed(bookID: UUID, voiceID: String?, wpm: Double?) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].localVoiceID = voiceID
            library.books[index].localWPM = wpm
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    func updateWordCounts(bookID: UUID, wordCount: Int, charCount: Int) {
        library.updateWordCounts(bookID: bookID, wordCount: wordCount, charCount: charCount)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func updateAudioDuration(bookID: UUID, duration: TimeInterval) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].audioDuration = duration
            save()
            LibraryPersistenceService.saveBookInfo(for: library.books[index])
        }
    }

    func bookByID(_ id: UUID) -> Book? {
        library.books.first { $0.id == id }
    }

    // MARK: - Bookmark Operations

    func addBookmark(bookID: UUID, chapterIndex: Int, characterOffset: Int, label: String = "") {
        library.addBookmark(bookID: bookID, chapterIndex: chapterIndex, characterOffset: characterOffset, label: label)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func updateBookmarkLabel(bookID: UUID, bookmarkID: UUID, label: String) {
        guard let bookIndex = library.books.firstIndex(where: { $0.id == bookID }),
              let bmIndex = library.books[bookIndex].bookmarks.firstIndex(where: { $0.id == bookmarkID }) else { return }
        library.books[bookIndex].bookmarks[bmIndex].label = label
        save()
        LibraryPersistenceService.saveBookInfo(for: library.books[bookIndex])
    }

    func removeBookmark(bookID: UUID, bookmarkID: UUID) {
        library.removeBookmark(bookID: bookID, bookmarkID: bookmarkID)
        save()
        if let book = library.books.first(where: { $0.id == bookID }) {
            LibraryPersistenceService.saveBookInfo(for: book)
        }
    }

    func bookmarksForBook(_ bookID: UUID) -> [Bookmark] {
        library.books.first(where: { $0.id == bookID })?.bookmarks ?? []
    }

    // MARK: - Book Queries (sorted)

    func sortedBooks(_ books: [Book], by field: LibrarySortField, ascending: Bool) -> [Book] {
        // Pre-compute file sizes to avoid O(N log N) disk I/O in the sort comparator
        var sizeCache: [UUID: Int] = [:]
        if field == .fileSize {
            for book in books {
                sizeCache[book.id] = (try? FileManager.default.attributesOfItem(atPath: book.filePath)[.size] as? Int) ?? 0
            }
        }

        return books.sorted { a, b in
            let result: Bool
            switch field {
            case .title:
                result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            case .author:
                result = a.author.localizedCaseInsensitiveCompare(b.author) == .orderedAscending
            case .dateAdded:
                result = a.dateAdded < b.dateAdded
            case .lastOpened:
                let aDate = a.lastOpened ?? Date.distantPast
                let bDate = b.lastOpened ?? Date.distantPast
                result = aDate < bDate
            case .fileSize:
                result = (sizeCache[a.id] ?? 0) < (sizeCache[b.id] ?? 0)
            case .manual:
                let orderA = a.manualSortOrder ?? Int.max
                let orderB = b.manualSortOrder ?? Int.max
                if orderA != orderB {
                    result = orderA < orderB
                } else {
                    result = a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
            }
            return ascending ? result : !result
        }
    }

    func booksForCategory(_ category: LibraryCategory, folderPath: String) -> [Book] {
        switch category {
        case .folders:
            return library.booksInFolder(folderPath)
        case .allItems:
            return library.books
        case .noFolder:
            return library.booksWithNoFolder()
        case .recent:
            return library.books
                .filter { $0.lastOpened != nil }
                .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
                .prefix(10)
                .map { $0 }
        }
    }

    func subfoldersOf(_ path: String) -> [BookFolder] {
        library.subfolders(of: path)
    }

    // MARK: - Folder Operations

    func createFolder(name: String, parentPath: String) {
        // Strip filesystem-unsafe characters (/ is used as internal path separator)
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }
        if let folder = library.createFolder(name: sanitized, parentPath: parentPath) {
            try? TextMouthPaths.ensureLibrarySubfolder(folder.fullPath)
        }
        save()
    }

    func removeFolder(_ folder: BookFolder) {
        library.removeFolder(id: folder.id)
        save()
    }

    // MARK: - Directory Management

    /// Rebuild the .TextMouth directory structure and migrate all books
    func rebuildDirectory() {
        do {
            try FileImportService.rebuildDirectoryStructure(library: &library)
            save()
            LibraryPersistenceService.saveAllBookInfos(library)
        } catch {
            errorMessage = "Failed to rebuild directory: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Rebuild to the default location (~/.TextMouth), moving data there
    func rebuildToDefault() {
        do {
            let defaultRoot = TextMouthPaths.defaultRoot
            if TextMouthPaths.root.path != defaultRoot.path {
                try TextMouthPaths.moveDataDirectory(to: defaultRoot, library: &library)
            }
            try TextMouthPaths.ensureDirectoryStructure()
            try FileImportService.rebuildDirectoryStructure(library: &library)
            configService.config.dataDirectoryPath = ""
            configService.saveToDisk()
            save()
        } catch {
            errorMessage = "Failed to rebuild to default: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Move the data directory to a new location
    func moveDataDirectory(to newURL: URL) {
        do {
            try TextMouthPaths.moveDataDirectory(to: newURL, library: &library)
            configService.config.dataDirectoryPath = newURL.path
            configService.saveToDisk()
            save()
        } catch {
            errorMessage = "Failed to move directory: \(error.localizedDescription)"
            showError = true
        }
    }

    /// Migrate data from the old sandbox container to the real ~/.TextMouth
    /// and clean up old container directories.
    private func migrateFromSandboxContainer() {
        let fm = FileManager.default
        let realDefault = TextMouthPaths.defaultRoot

        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = NSHomeDirectory()
        }

        let containerBase = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Containers/com.textmouth.TextMouth/Data", isDirectory: true)
        let containerTextMouth = containerBase.appendingPathComponent(".TextMouth", isDirectory: true)

        // Migrate .TextMouth dir from container if it exists and real one doesn't
        if fm.fileExists(atPath: containerTextMouth.path) && !fm.fileExists(atPath: realDefault.path) {
            do {
                try fm.createDirectory(at: realDefault, withIntermediateDirectories: true)
                let contents = try fm.contentsOfDirectory(at: containerTextMouth, includingPropertiesForKeys: nil)
                for item in contents {
                    let dest = realDefault.appendingPathComponent(item.lastPathComponent)
                    try fm.moveItem(at: item, to: dest)
                }

                // Rewrite ALL container paths in library.json to real paths
                let libraryFile = realDefault.appendingPathComponent("library.json")
                if fm.fileExists(atPath: libraryFile.path) {
                    if var json = try? String(contentsOf: libraryFile, encoding: .utf8) {
                        // Replace the container data base path with real home
                        json = json.replacingOccurrences(
                            of: containerBase.path,
                            with: home
                        )
                        try? json.data(using: .utf8)?.write(to: libraryFile, options: .atomic)
                    }
                }

                try? fm.removeItem(at: containerTextMouth)
                print("Migrated .TextMouth from sandbox container to \(realDefault.path)")
            } catch {
                print("Failed to migrate from sandbox container: \(error)")
            }
        }

        // Clean up old container directories (Books dir, logs, etc.)
        let oldContainerAppSupport = containerBase
            .appendingPathComponent("Library/Application Support/TextMouth", isDirectory: true)
        if fm.fileExists(atPath: oldContainerAppSupport.path) {
            try? fm.removeItem(at: oldContainerAppSupport)
            print("Cleaned up old container app support dir")
        }

        // Clean up stale log files in container root
        for file in ["textmouth_debug.log", "textmouth_transition.log"] {
            let path = containerBase.appendingPathComponent(file)
            if fm.fileExists(atPath: path.path) {
                try? fm.removeItem(at: path)
            }
        }
    }

    // MARK: - Time Estimation

    func totalTimeRemaining(books: [Book], wpm: Double) -> (time: TimeInterval, knownCount: Int, unknownCount: Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    // MARK: - Persistence

    private var saveWorkItem: DispatchWorkItem?

    /// Save the library index, debounced to avoid rapid repeated writes.
    /// Position updates happen very frequently; this coalesces them.
    private func save() {
        saveWorkItem?.cancel()
        let lib = library
        let workItem = DispatchWorkItem {
            LibraryPersistenceService.save(lib)
        }
        saveWorkItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Save immediately (for critical operations like import/delete).
    private func saveNow() {
        saveWorkItem?.cancel()
        let lib = library
        DispatchQueue.global(qos: .utility).async {
            LibraryPersistenceService.save(lib)
        }
    }
}

extension Notification.Name {
    static let openBookWindow = Notification.Name("openBookWindow")
}
