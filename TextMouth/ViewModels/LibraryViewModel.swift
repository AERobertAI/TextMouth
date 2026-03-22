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

    /// Book removal confirmation (supports single or multi-book removal)
    @Published var showRemoveBookDialog = false
    @Published var pendingRemoveBooks: [Book] = []

    /// Last folder path a book was moved to, used as default in move sheet
    @Published var lastMovedFolderPath: String = ""

    /// Folder deletion dialogs
    @Published var showDeleteFolderDialog = false
    @Published var pendingDeleteFolder: BookFolder?
    @Published var showDeleteFolderDestinationSheet = false
    @Published var showDeleteEverythingConfirm = false

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

    /// Text extraction progress tracking (for startup cache generation and re-extraction)
    @Published var isExtracting = false
    @Published var extractionProgressCurrent = 0
    @Published var extractionProgressTotal = 0
    @Published var extractionProgressMessage = ""

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
        // Extract caches first, then calculate stats (which can use the caches).
        // Both run on background queues; stats waits for extraction to finish.
        extractMissingContentCaches(then: { [weak self] in
            self?.calculateMissingBookStats()
        })
    }

    deinit {
        refreshTimer?.invalidate()
    }

    /// Migrate any books still using old storage paths to .tmb packages,
    /// and fix any stale file paths pointing to old locations.
    private func migrateOldBooksIfNeeded() {
        var needsSave = false

        // Fix stale file paths — if the file doesn't exist at the stored path,
        // search for the .tmb in the expected folder, then fall back to the root
        // Library directory (fixes a bug where folder moves updated the path
        // without physically moving the .tmb directory).
        for i in library.books.indices {
            let book = library.books[i]
            if !book.tmbDirectoryName.isEmpty &&
               !FileManager.default.fileExists(atPath: book.filePath) {
                let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent

                // First try the expected folder location
                let tmbDir = TextMouthPaths.tmbPath(folderPath: book.folderPath, tmbName: book.tmbDirectoryName)
                let correctPath = tmbDir.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: correctPath) {
                    library.books[i].filePath = correctPath
                    needsSave = true
                    continue
                }

                // Fall back: check root Library directory (the .tmb may never
                // have been physically moved when the book was assigned to a folder)
                let rootTmbDir = TextMouthPaths.tmbPath(folderPath: "", tmbName: book.tmbDirectoryName)
                let rootPath = rootTmbDir.appendingPathComponent(fileName).path
                if FileManager.default.fileExists(atPath: rootPath) {
                    // Move the .tmb to the correct folder location
                    do {
                        if !book.folderPath.isEmpty {
                            try? TextMouthPaths.ensureLibrarySubfolder(book.folderPath)
                        }
                        try FileManager.default.moveItem(at: rootTmbDir, to: tmbDir)
                        library.books[i].filePath = correctPath
                    } catch {
                        // Move failed — just update the path to where the file actually is
                        library.books[i].filePath = rootPath
                    }
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

        // Move .tmb packages that are at the root but should be in a subfolder.
        // This fixes books whose folder was assigned in the UI without physically
        // moving the directory (a bug fixed in d6c6b2c but existing books need repair).
        let relocated = FileImportService.relocateMisplacedTMBPackages(library: &library)
        if relocated > 0 { needsSave = true }

        // Adopt any .tmb packages on disk that aren't tracked in library.json.
        // This recovers books left behind by interrupted imports or crashes.
        let adopted = FileImportService.adoptOrphanedTMBPackages(library: &library)
        if adopted > 0 { needsSave = true }

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
                    // Use cached Markdown content when available (much faster)
                    let parsed: DocumentContent
                    if !book.format.isAudio && MarkdownCacheService.cacheExists(for: book) {
                        parsed = try MarkdownCacheService.loadFromCache(for: book)
                    } else {
                        parsed = try BookParser.parse(url: url, format: book.format)
                    }
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

    /// Generate content.md caches for any books that don't have one yet.
    /// Runs in the background with progress tracking so the UI stays responsive.
    /// Calls the optional completion handler when finished (on the background queue).
    private func extractMissingContentCaches(then completion: (() -> Void)? = nil) {
        let booksNeedingCache = library.books.filter { book in
            !book.format.isAudio
            && !book.tmbDirectoryName.isEmpty
            && !MarkdownCacheService.cacheExists(for: book)
        }
        guard !booksNeedingCache.isEmpty else {
            // No extraction needed — run completion immediately
            DispatchQueue.global(qos: .utility).async { completion?() }
            return
        }

        DispatchQueue.main.async {
            self.isExtracting = true
            self.extractionProgressTotal = booksNeedingCache.count
            self.extractionProgressCurrent = 0
            self.extractionProgressMessage = "Extracting text from \(booksNeedingCache.count) book\(booksNeedingCache.count == 1 ? "" : "s")..."
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (index, book) in booksNeedingCache.enumerated() {
                guard self != nil else { return }
                MarkdownCacheService.generateCache(for: book)

                DispatchQueue.main.async {
                    self?.extractionProgressCurrent = index + 1
                    self?.extractionProgressMessage = "Extracting text: \(index + 1) of \(booksNeedingCache.count)..."
                }
            }

            DispatchQueue.main.async {
                self?.isExtracting = false
                self?.extractionProgressMessage = ""
            }

            completion?()
        }
    }

    /// Re-extract content.md caches for all non-audio books.
    /// Called from the "Redo Text Extraction" button in Storage Settings.
    func redoAllTextExtraction() {
        let booksToExtract = library.books.filter { book in
            !book.format.isAudio && !book.tmbDirectoryName.isEmpty
        }
        guard !booksToExtract.isEmpty else { return }

        isExtracting = true
        extractionProgressTotal = booksToExtract.count
        extractionProgressCurrent = 0
        extractionProgressMessage = "Re-extracting text from \(booksToExtract.count) book\(booksToExtract.count == 1 ? "" : "s")..."

        DispatchQueue.global(qos: .utility).async { [weak self] in
            for (index, book) in booksToExtract.enumerated() {
                guard self != nil else { return }
                // Delete existing cache first
                MarkdownCacheService.deleteCache(for: book)
                MarkdownCacheService.generateCache(for: book)

                DispatchQueue.main.async {
                    self?.extractionProgressCurrent = index + 1
                    self?.extractionProgressMessage = "Re-extracting text: \(index + 1) of \(booksToExtract.count)..."
                }
            }

            DispatchQueue.main.async {
                self?.isExtracting = false
                self?.extractionProgressMessage = ""
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
            // Generate cached Markdown content
            MarkdownCacheService.generateCache(for: book)
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
                    // Move .tmb on disk BEFORE updating folderPath
                    moveTMBToFolder(book: &library.books[idx], newFolderPath: folder.fullPath)
                    library.books[idx].folderPath = folder.fullPath
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

    /// Request removal of a single book — shows confirmation if enabled
    func removeBook(_ book: Book) {
        removeBooks([book])
    }

    /// Request removal of one or more books — shows confirmation if enabled
    func removeBooks(_ books: [Book]) {
        guard !books.isEmpty else { return }
        if configService.config.confirmBeforeDelete {
            pendingRemoveBooks = books
            showRemoveBookDialog = true
        } else {
            // Default: remove from library and delete .tmb
            performRemoveBooks(books, deleteTMB: true)
        }
    }

    /// Remove books from the library index only, leaving .tmb files on disk.
    /// Deletes bookInfo.json from each .tmb so orphan adoption won't re-add them.
    func removeBooksFromLibraryOnly(_ books: [Book]) {
        for book in books {
            // Remove bookInfo.json so adoptOrphanedTMBPackages won't re-adopt this book.
            // The .tmb and its book file remain on disk for the user to reimport if desired.
            if !book.tmbDirectoryName.isEmpty {
                let infoURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
                try? FileManager.default.removeItem(at: infoURL)
            }
            library.removeBook(id: book.id)
        }
        save()
    }

    /// Remove books from the library and delete their .tmb packages
    func removeBooksAndDelete(_ books: [Book]) {
        performRemoveBooks(books, deleteTMB: true)
    }

    private func performRemoveBooks(_ books: [Book], deleteTMB: Bool) {
        for book in books {
            if deleteTMB {
                FileImportService.deleteBookPackage(book)
            }
            library.removeBook(id: book.id)
        }
        save()
    }

    func moveBook(_ book: Book, toFolder path: String) {
        moveBooks([book], toFolder: path)
    }

    /// Move one or more books to the specified folder path
    func moveBooks(_ books: [Book], toFolder path: String) {
        for book in books {
            guard let idx = library.books.firstIndex(where: { $0.id == book.id }) else { continue }
            // Move .tmb on disk BEFORE updating folderPath, so book.tmbDirectory
            // still points to the old location for the move source
            moveTMBToFolder(book: &library.books[idx], newFolderPath: path)
            library.books[idx].folderPath = path
        }
        lastMovedFolderPath = path
        save()
    }

    /// Move a .tmb package directory to a new library subfolder.
    /// When oldFolderPath is provided, it overrides book.folderPath for computing
    /// the source location (needed when folderPath was already updated by the model).
    private func moveTMBToFolder(book: inout Book, newFolderPath: String, oldFolderPath: String? = nil) {
        guard !book.tmbDirectoryName.isEmpty else { return }

        let sourceFolderPath = oldFolderPath ?? book.folderPath
        let oldTmbDir = TextMouthPaths.tmbPath(folderPath: sourceFolderPath, tmbName: book.tmbDirectoryName)
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

    /// Update the sort setting for a specific folder path and persist.
    func setFolderSortSetting(_ setting: FolderSortSetting, for folderPath: String) {
        library.setSortSetting(setting, for: folderPath)
        save()
    }

    /// Apply a sort setting to a folder and all its subfolders, then persist.
    func applySortToSubfolders(_ setting: FolderSortSetting, from folderPath: String) {
        library.applySortToSubfolders(setting, from: folderPath)
        save()
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

    /// Move a book up or down by one position within its folder's manual sort order.
    /// direction: -1 for up, +1 for down.
    /// Returns the new position index (0-based) or nil if the move was not possible.
    @discardableResult
    func moveBookInManualOrder(bookID: UUID, direction: Int, folderPath: String) -> Int? {
        // Get the sorted list of books in this folder (same ordering as reorderBooksInFolder)
        var folderBooks = library.booksInFolder(folderPath)
            .sorted { a, b in
                let orderA = a.manualSortOrder ?? Int.max
                let orderB = b.manualSortOrder ?? Int.max
                if orderA != orderB { return orderA < orderB }
                return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        guard let currentIndex = folderBooks.firstIndex(where: { $0.id == bookID }) else { return nil }
        let newIndex = currentIndex + direction
        guard newIndex >= 0, newIndex < folderBooks.count else { return nil }

        // Swap the two books
        folderBooks.swapAt(currentIndex, newIndex)
        // Reassign sequential sort orders
        for (i, book) in folderBooks.enumerated() {
            updateManualSortOrder(bookID: book.id, order: i)
        }
        return newIndex
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

    func updateLocalVoiceAndSpeed(bookID: UUID, voiceID: String?, wpm: Double?, pitch: Double? = nil) {
        if let index = library.books.firstIndex(where: { $0.id == bookID }) {
            library.books[index].localVoiceID = voiceID
            library.books[index].localWPM = wpm
            library.books[index].localPitch = pitch
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

    /// Remove a folder, moving its contents to the given destination path.
    /// Subfolders are reparented under the destination; books are reassigned.
    /// The folder's disk directory is removed after all contents have been moved out.
    func removeFolderMovingContents(_ folder: BookFolder, toPath destination: String) {
        // Move .tmb packages on disk for books being reassigned.
        // Capture old folder paths BEFORE the model update changes them.
        let oldPath = folder.fullPath
        let booksToReassign = library.books.filter {
            $0.folderPath == oldPath || $0.folderPath.hasPrefix(oldPath + "/")
        }
        let oldFolderPaths = Dictionary(uniqueKeysWithValues: booksToReassign.map { ($0.id, $0.folderPath) })
        library.removeFolder(id: folder.id, movingContentsTo: destination)
        // Move disk locations using the captured old paths
        for (bookID, oldBookFolderPath) in oldFolderPaths {
            if let idx = library.books.firstIndex(where: { $0.id == bookID }) {
                let newFolderPath = library.books[idx].folderPath
                moveTMBToFolder(book: &library.books[idx], newFolderPath: newFolderPath, oldFolderPath: oldBookFolderPath)
            }
        }
        // Ensure destination subfolder directories exist on disk
        for f in library.folders {
            try? TextMouthPaths.ensureLibrarySubfolder(f.fullPath)
        }
        // Remove the now-empty folder directory from disk
        let folderDiskURL = TextMouthPaths.libraryDir
            .appendingPathComponent(oldPath, isDirectory: true)
        FileImportService.removeItemRespectingTrashSetting(at: folderDiskURL)
        save()
    }

    /// Remove a folder and permanently delete all its contents (books, subfolders, .tmb files).
    func removeFolderAndEverything(_ folder: BookFolder) {
        let removedBooks = library.removeFolderAndContents(id: folder.id)
        // Delete .tmb packages from disk (respects trash setting)
        for book in removedBooks {
            FileImportService.deleteBookPackage(book)
        }
        // Remove the folder's disk directory
        let folderDiskURL = TextMouthPaths.libraryDir
            .appendingPathComponent(folder.fullPath, isDirectory: true)
        FileImportService.removeItemRespectingTrashSetting(at: folderDiskURL)
        save()
    }

    /// Move a folder to a new parent, preserving its internal structure on disk.
    func moveFolder(_ folder: BookFolder, toParent newParentPath: String) {
        let oldPath = folder.fullPath
        guard library.moveFolder(id: folder.id, toParentPath: newParentPath) else { return }
        let newPath = newParentPath.isEmpty ? folder.name : "\(newParentPath)/\(folder.name)"

        // Move the disk directory
        let oldDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(oldPath, isDirectory: true)
        try? TextMouthPaths.ensureLibrarySubfolder(newParentPath)
        let newDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(newPath, isDirectory: true)
        var diskMoveSucceeded = false
        if FileManager.default.fileExists(atPath: oldDiskURL.path), oldDiskURL != newDiskURL {
            do {
                try FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)
                diskMoveSucceeded = true
            } catch {
                print("Failed to move folder on disk: \(error)")
            }
        }

        // Only update filePath if the disk move actually succeeded, otherwise
        // the file is still at the old location and updating filePath would break it
        if diskMoveSucceeded {
            for i in library.books.indices {
                let book = library.books[i]
                if book.folderPath == newPath || book.folderPath.hasPrefix(newPath + "/") {
                    if !book.tmbDirectoryName.isEmpty {
                        let tmbDir = TextMouthPaths.tmbPath(
                            folderPath: book.folderPath,
                            tmbName: book.tmbDirectoryName
                        )
                        let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        library.books[i].filePath = tmbDir.appendingPathComponent(fileName).path
                    }
                }
            }
        }
        save()
    }

    /// Rename a folder, updating disk directory and all book file paths.
    func renameFolder(_ folder: BookFolder, to newName: String) {
        let oldPath = folder.fullPath
        guard library.renameFolder(id: folder.id, to: newName) else { return }

        // Compute the new path after the model update
        let sanitized = newName.replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let newPath = folder.parentPath.isEmpty ? sanitized : "\(folder.parentPath)/\(sanitized)"

        // Rename the disk directory
        let oldDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(oldPath, isDirectory: true)
        let newDiskURL = TextMouthPaths.libraryDir.appendingPathComponent(newPath, isDirectory: true)
        var diskRenameSucceeded = false
        if FileManager.default.fileExists(atPath: oldDiskURL.path), oldDiskURL != newDiskURL {
            do {
                try FileManager.default.moveItem(at: oldDiskURL, to: newDiskURL)
                diskRenameSucceeded = true
            } catch {
                print("Failed to rename folder on disk: \(error)")
            }
        }

        // Only update filePath if the disk rename succeeded
        if diskRenameSucceeded {
            for i in library.books.indices {
                let book = library.books[i]
                if book.folderPath == newPath || book.folderPath.hasPrefix(newPath + "/") {
                    if !book.tmbDirectoryName.isEmpty {
                        let tmbDir = TextMouthPaths.tmbPath(
                            folderPath: book.folderPath,
                            tmbName: book.tmbDirectoryName
                        )
                        let fileName = URL(fileURLWithPath: book.filePath).lastPathComponent
                        library.books[i].filePath = tmbDir.appendingPathComponent(fileName).path
                    }
                }
            }
        }
        save()
    }

    /// Check whether a folder has any books or subfolders
    func folderHasContents(_ folder: BookFolder) -> Bool {
        library.folderHasContents(folder)
    }

    /// Legacy: remove folder, moving contents to root
    func removeFolder(_ folder: BookFolder) {
        removeFolderMovingContents(folder, toPath: folder.parentPath)
    }

    // MARK: - Directory Management

    /// Rebuild the .TextMouth directory structure, migrate all books,
    /// adopt orphaned .tmb packages, and extract missing content caches.
    func rebuildDirectory() {
        do {
            try FileImportService.rebuildDirectoryStructure(library: &library)
            save()
            LibraryPersistenceService.saveAllBookInfos(library)
            // Extract content caches for any newly adopted books, then recalculate stats
            extractMissingContentCaches(then: { [weak self] in
                self?.calculateMissingBookStats()
            })
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
