import SwiftUI
import Combine
import ZIPFoundation

/// Serial background executor for imports. Activity callbacks are delivered on
/// the main queue, while operations always run off the UI thread.
final class SerialImportQueue: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.textmouth.imports", qos: .userInitiated)
    private let stateLock = NSLock()
    private var activeCount = 0
    /// The cancellation the imports enqueued since the last
    /// `cancelEnqueued()` share (TODO I05).
    private var cancellation = ImportCancellation()
    var onActivityChanged: (@MainActor @Sendable (Int) -> Void)?

    /// The cancellation an import enqueued now shares with every import
    /// already waiting or running: `cancelEnqueued()` cancels it.
    var currentCancellation: ImportCancellation {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cancellation
    }

    /// Cancels every import enqueued so far, running or waiting, and gives
    /// the imports enqueued afterwards a cancellation of their own, which
    /// this cancel never reaches (TODO I05).
    func cancelEnqueued() {
        stateLock.lock()
        let cancelled = cancellation
        cancellation = ImportCancellation()
        stateLock.unlock()
        cancelled.cancel()
    }

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

    /// Imports the items opened from Finder and opens each book once it is
    /// in the library and its questions are answered. The Library window the
    /// router chooses for the items calls this (TODO A05), and asks their
    /// questions (TODO I01).
    ///
    /// - Parameter origin: The Library window importing the items.
    func importAndOpenFiles(urls: [URL], from origin: ImportOrigin? = nil) {
        for url in urls {
            let ext = url.pathExtension.lowercased()

            if ext == "tmb" {
                openTMBPackage(from: url)
            } else if ext == "zip" {
                importZipAsync(from: url, toFolder: "", origin: origin)
            } else {
                importBooks(in: url, toFolder: "", origin: origin, openAfterImport: true)
            }
        }
    }

    /// What the item `url`, chosen with Import DAISY Folder… or in the
    /// Open Book... panel, or opened from Finder, is imported from, each
    /// source one book: a folder whose top level holds several DAISY
    /// books' package files gives each of those files; any other item is
    /// imported as itself. A folder holding one DAISY book is imported as
    /// that book's package with every file it needs, and a folder holding
    /// none is refused, saying why (`FileImportService.importFileWithReport`)
    /// (TODO I02).
    nonisolated static func importSources(for url: URL) -> [URL] {
        let packageFiles = DAISYParser.packageEntryPoints(in: url)
        return packageFiles.count > 1 ? packageFiles : [url]
    }

    /// Imports `item`, one item chosen or opened in the Library window
    /// `origin`, as the book or books it holds (`importSources(for:)`), each
    /// on the import queue.
    private func importBooks(
        in item: URL,
        toFolder folderPath: String,
        origin: ImportOrigin?,
        openAfterImport: Bool = false
    ) {
        for source in Self.importSources(for: item) {
            importSingleFileAsync(from: source, toFolder: folderPath, openAfterImport: openAfterImport, origin: origin)
        }
    }

    /// The request for an import queued now from the Library window
    /// `origin`: it joins the batch of every import queued so far, which the
    /// overlay's Cancel stops along with the batch's questions (TODO I05,
    /// I01).
    private func importRequest(from origin: ImportOrigin?, opensAfterImport: Bool = false) -> ImportRequest {
        ImportRequest(
            origin: origin,
            opensAfterImport: opensAfterImport,
            batch: importOperationQueue.currentCancellation
        )
    }

    // MARK: - Import DAISY Folder…

    /// The panel the Import DAISY Folder… command presents (TODO I02): it
    /// chooses folders, several at once, and no files, since a DAISY book
    /// kept as loose files is imported by its folder. Here Return on a
    /// folder chooses it; the standard Open Book... panel offers files only,
    /// so Return on a folder there keeps opening the folder. A TextMouth
    /// package counts as a file, so it cannot be chosen here.
    static func makeDAISYFolderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Import DAISY Folder"
        panel.message = "Choose the folder of each DAISY book to import: the folder that holds its ncc.html or .opf file."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        return panel
    }

    /// Imports the folders chosen with Import DAISY Folder… into the library
    /// folder `folderPath`, each as the book or books it holds: a folder
    /// holding one DAISY book as that book with every file it needs, a
    /// folder holding several books' package files as each of them, and a
    /// folder holding none is refused through the library's alert, which
    /// says why (TODO I02). The Library window `origin` that presented the
    /// panel asks the imports' questions (TODO I01).
    func importDAISYFolders(_ folders: [URL], toFolder folderPath: String, from origin: ImportOrigin? = nil) {
        for folder in folders {
            importBooks(in: folder, toFolder: folderPath, origin: origin)
        }
    }

    // MARK: - TMB Package Opening

    /// Open a .tmb package — find the matching book in library or import it, then open the reader.
    /// A package the library does not list is imported: a package Remove
    /// from Library Only retained is taken back where it is, and any other
    /// is copied into the library (`FileImportService.importTMBPackage`).
    func openTMBPackage(from url: URL) {
        importOperationQueue.enqueue { [weak self] in
            guard let self else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            do {
                let source = try FileImportService.identifyTMBPackage(at: url)
                var isListed = false
                // On the main thread: the library is read there, and the
                // window opens there.
                DispatchQueue.main.sync {
                    if let listedBookID = self.listedBookID(for: source) {
                        isListed = true
                        self.readerOpener(listedBookID)
                    }
                }
                guard !isListed else { return }
                let imported = try FileImportService.importTMBPackage(source)
                DispatchQueue.main.sync { self.completePackageImport(imported, openAfterImport: true) }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    /// The library's own listing of the book `source` holds, found by book
    /// ID or, failing that, by content, for the caller to open; nil when the
    /// library does not list the book, which must then be imported.
    ///
    /// When the package is the listed book's own managed package, the
    /// listing's storage fields are first repaired from it. A package that
    /// Remove from Library Only retired never counts as the listed book's
    /// own: that book lives in another package now, and repairing its
    /// listing toward the retired one would point it at a package the next
    /// launch takes out of the library.
    func listedBookID(for source: TMBImportSource) -> UUID? {
        if let existingIndex = library.books.firstIndex(where: { $0.id == source.bookID }) {
            let existing = library.books[existingIndex]
            if let inspection = source.inspection,
               !RemovedFromLibraryMarker.retires(source.bookID, in: source.packageURL),
               let managedPackageBook = FileImportService.bookFromManagedPackage(
                   inspection: inspection,
                   packageURL: source.packageURL
               ) {
                let repaired = FileImportService.reconciledLibraryBook(existing, with: managedPackageBook)
                library.books[existingIndex] = repaired
                if repaired != existing {
                    save()
                    // The line says whether the book's file exists, never where it is.
                    let pathExists = FileManager.default.fileExists(atPath: repaired.filePath)
                    DiagnosticLog.event(
                        .import,
                        "TMB_RECONCILE: book=\(existing.id.uuidString.prefix(8)) "
                            + "folder='\(existing.folderPath)'→'\(repaired.folderPath)' pathExists=\(pathExists)"
                    )
                }
            }
            return existing.id
        }
        // A hash-only match can represent a deliberate second package with
        // a different ID. Open the known book without relocating its
        // Library record.
        return library.books.first(where: { $0.md5Hash == source.md5Hash })?.id
    }

    /// Publish the book a package import produced, and with
    /// `openAfterImport` open it. A book that is missing chapters is
    /// announced through the library's alert instead of opened, so its
    /// reader window does not take focus from the warning. The package the
    /// user chose is never deleted.
    func completePackageImport(_ imported: ImportedBook, openAfterImport: Bool) {
        importProgressMessage = ""
        library.addBook(imported.book)
        save()
        if let warning = imported.warning {
            presentImportMessage(warning)
        } else if openAfterImport {
            readerOpener(imported.book.id)
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

    /// Removes, off the main thread, the extraction directories that ZIP
    /// imports interrupted by a crash or a forced quit left in the data
    /// directory (TODO I05), which can hold gigabytes nothing else removes.
    /// Startup calls it once; a directory an import of this process is
    /// using, or another running copy of TextMouth's, is never removed
    /// (`ArchiveExtractionDirectory.removeLeftovers`).
    func removeLeftoverArchiveExtractions() {
        DispatchQueue.global(qos: .utility).async {
            ArchiveExtractionDirectory.removeLeftovers()
        }
    }

    /// Stops the ZIP imports under way and those waiting behind them (TODO
    /// I05): a running batch stops before its next entry or book, keeps the
    /// books it already imported, and its summary says where it stopped; a
    /// waiting ZIP import never starts. The import overlay's Cancel button
    /// calls this. Every question the stopped imports raised is withdrawn
    /// with them, and one they raise later is never asked (TODO I01): a
    /// duplicate's new copy is discarded, an original file is kept, and a
    /// ZIP archive's books stay where they are. Imports started afterwards,
    /// and their questions, are not affected.
    func cancelImports() {
        importOperationQueue.cancelEnqueued()
        withdrawCancelledImportDecisions()
    }

    /// Import a zip file asynchronously with progress tracking. The import
    /// takes the queue's cancellation as it is enqueued, so `cancelImports()`
    /// stops it while it waits as well as while it runs (TODO I05). The
    /// Library window `origin` that started it asks its questions (TODO I01).
    func importZipAsync(from url: URL, toFolder folderPath: String, origin: ImportOrigin? = nil) {
        let request = importRequest(from: origin)
        let cancellation = request.batch
        importOperationQueue.enqueue { [weak self] in
            guard let self = self else { return }
            // A ZIP import cancelled while it waited never starts, and says
            // nothing: the batch that was running reports the cancel.
            guard !cancellation.isCancelled else {
                ImportCancellation.log(url.lastPathComponent, stopped: "before it started")
                return
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            DispatchQueue.main.async { self.beginImportProgress("Extracting archive...") }
            do {
                if DAISYParser.isDAISYZip(url: url) {
                    let imported: ImportedBook
                    if let archive = try? Archive(url: url, accessMode: .read),
                       DAISYAudioConverter.hasAudio(in: ArchiveFileProvider(archive: archive)) {
                        imported = try FileImportService.importDAISYAudioZipWithReport(from: url, toFolder: folderPath)
                    } else {
                        imported = try FileImportService.importFileWithReport(from: url, toFolder: folderPath)
                    }
                    DispatchQueue.main.sync {
                        self.completeSingleImportedBook(imported, originalURL: url, request: request)
                    }
                    return
                }
                if Self.isAudioZip(url: url) {
                    let imported = try FileImportService.importAudioZipWithReport(from: url, toFolder: folderPath)
                    DispatchQueue.main.sync {
                        self.completeSingleImportedBook(imported, originalURL: url, request: request)
                    }
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
                    progress: { progress in
                        DispatchQueue.main.async { self.showZipImportProgress(progress) }
                    },
                    isCancelled: cancellation.check
                )
                DispatchQueue.main.sync {
                    self.completeZIPImport(result, originalURL: url, folderPath: folderPath, request: request)
                }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    /// Shows how far a ZIP batch has got in the import overlay (TODO I05).
    private func showZipImportProgress(_ progress: ZipImportProgress) {
        let shown = Self.overlayProgress(for: progress)
        importProgressCurrent = shown.current
        importProgressTotal = shown.total
        importProgressMessage = shown.message
    }

    /// What the import overlay shows for a ZIP batch's progress. Its bar and
    /// count speak of books, so while the archive is extracted the bar is
    /// left indeterminate and the message counts the archive's items
    /// extracted, so the overlay moves before the first book imports; once
    /// books import, the bar and the message count them, as before.
    nonisolated static func overlayProgress(for progress: ZipImportProgress) -> (current: Int, total: Int, message: String) {
        switch progress {
        case let .extracting(archive, done, total):
            return (0, 0, "Extracting “\(archive)”: \(done) of \(total) items...")
        case let .importing(done, total):
            return (done, total, "Importing book \(done) of \(total)...")
        }
    }

    /// Imports one file on the import queue, as the Library window `origin`
    /// asked, and with `openAfterImport` opens its book once the book is in
    /// the library and its questions are answered (TODO I01). Other files
    /// import meanwhile; their questions wait their turn.
    func importSingleFileAsync(
        from url: URL,
        toFolder folderPath: String,
        openAfterImport: Bool = false,
        origin: ImportOrigin? = nil
    ) {
        let request = importRequest(from: origin, opensAfterImport: openAfterImport)
        importOperationQueue.enqueue { [weak self] in
            guard let self else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            DispatchQueue.main.async { self.beginImportProgress("Importing \(url.lastPathComponent)...") }
            do {
                let imported = try FileImportService.importFileWithReport(from: url, toFolder: folderPath)
                DispatchQueue.main.sync {
                    self.completeSingleImportedBook(imported, originalURL: url, request: request)
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

    /// Publish one imported book, a document or a DAISY or audio ZIP, through
    /// the same duplicate question. A duplicate's question is queued behind
    /// any already waiting, holding the book, its original, and `request`, so
    /// the answer acts on this book whatever imports finish meanwhile (TODO
    /// I01). The original is handled, and the book opened when `request`
    /// asks, once the book is in the library: a question about the original
    /// comes first, and the book opens once it is answered.
    ///
    /// An import that left chapters out still adds its book, but announces
    /// what is missing once through the library's alert (or, for a duplicate,
    /// with the duplicate question, so the two never compete), and its
    /// original is never deleted or offered for deletion, whatever the
    /// preference. Such a book is not opened automatically either: the
    /// reader window would take focus from the warning in the library window.
    /// A DAISY book copied from its folder of files never has its original
    /// deleted or offered for deletion either (`ImportedBook.mayDeleteOriginal`).
    func completeSingleImportedBook(
        _ imported: ImportedBook,
        originalURL: URL,
        request: ImportRequest = ImportRequest()
    ) {
        importProgressMessage = ""
        let book = imported.book
        // Without an original to offer, a later duplicate answer cannot
        // delete it either.
        let deletableOriginal = imported.mayDeleteOriginal ? originalURL : nil
        var request = request
        if imported.warning != nil {
            request.opensAfterImport = false
        }
        guard addBookCheckingDuplicate(
            book, originalURL: deletableOriginal, warning: imported.warning, request: request
        ) else {
            return
        }
        save()
        if let warning = imported.warning {
            presentImportMessage(warning)
        }
        finishAddedBook(book, originalURL: deletableOriginal, request: request)
    }

    /// Publish a batch result while retaining an archive that still contains
    /// failed or unimported content, a book imported without some of its
    /// chapters, or books a cancel left unimported (`ZipImportResult
    /// .keepsOriginal`). This also covers empty/duplicate-only ZIPs.
    ///
    /// The batch's questions, whether to delete the archive and whether to
    /// put several books in a folder of their own, are queued in that order
    /// behind any already waiting, each holding this archive and these books
    /// and `request` (TODO I01).
    func completeZIPImport(
        _ result: ZipImportResult,
        originalURL: URL,
        folderPath: String,
        request: ImportRequest = ImportRequest()
    ) {
        let priorIDs = Set(library.books.map(\.id))
        for book in result.books { library.addBook(book) }
        let acceptedBooks = result.books.filter { book in
            !priorIDs.contains(book.id) && library.books.contains { $0.id == book.id }
        }
        save()
        importProgressMessage = ""
        if let failureSummary = result.failureSummary {
            presentImportMessage(failureSummary)
        }
        if !result.keepsOriginal, !acceptedBooks.isEmpty, acceptedBooks.count == result.books.count,
           let question = originalFileQuestion(for: originalURL, of: nil, request: request) {
            ask(question)
        }
        if acceptedBooks.count > 1 {
            let batch = ImportDecision.ZipBatch(archiveURL: originalURL, books: acceptedBooks, folderPath: folderPath)
            ask(ImportDecision(kind: .zipFolder(batch), request: request))
        }
    }

    private func presentImportError(_ error: Error) {
        presentImportMessage(error.localizedDescription)
    }

    /// Tell the reader about an import through the library's alert: why it
    /// failed, or what a completed import is missing.
    private func presentImportMessage(_ message: String) {
        importProgressMessage = ""
        errorMessage = message
        showError = true
    }

    // MARK: - Import

    /// Create a new book from user-entered text (paste/type). The package is
    /// staged and published like every import's, so a failure leaves nothing
    /// in the library and is told through the same alert. The Library window
    /// `origin` asks the duplicate question, if one arises (TODO I01).
    func createBookFromText(
        title: String,
        author: String,
        text: String,
        toFolder folderPath: String = "",
        from origin: ImportOrigin? = nil
    ) {
        let bookTitle = TextImportPolicy.resolvedTitle(title)
        let fileName = TextImportPolicy.textFilename(for: bookTitle)
        let request = importRequest(from: origin)
        importOperationQueue.enqueue { [weak self] in
            guard let self else { return }
            do {
                let imported = try FileImportService.importText(
                    text,
                    title: bookTitle,
                    author: author,
                    fileName: fileName,
                    toFolder: folderPath
                )
                DispatchQueue.main.async {
                    if self.addBookCheckingDuplicate(imported.book, request: request) {
                        self.save()
                    }
                }
            } catch {
                DispatchQueue.main.async { self.presentImportError(error) }
            }
        }
    }

    /// Import one or more files from URLs into the specified folder. A
    /// DAISY book's folder is imported as that book (`importSources(for:)`).
    /// The Library window `origin` that chose them asks their questions
    /// (TODO I01).
    func importFiles(urls: [URL], toFolder folderPath: String = "", from origin: ImportOrigin? = nil) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "zip" {
                importZipAsync(from: url, toFolder: folderPath, origin: origin)
            } else {
                importBooks(in: url, toFolder: folderPath, origin: origin)
            }
        }
    }
}
