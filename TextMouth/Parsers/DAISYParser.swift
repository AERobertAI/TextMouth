import Foundation
import ZIPFoundation
import SwiftSoup

// MARK: - Error Types

/// Errors that can occur when parsing a DAISY book
enum DAISYParserError: LocalizedError {
    case fileNotFound(String)
    case invalidArchive
    case notDAISYBook
    case missingContent(String)
    case parseError(String)
    /// A file in the package is damaged: its markup breaks off or is not
    /// well-formed, so reading on would silently yield a partial book, or
    /// it holds more than TextMouth reads from one file. `file` is the
    /// file's path inside the package; `reason` completes the sentence "The
    /// file is damaged or incomplete: …".
    case malformedXML(file: String, reason: String)
    /// A file TextMouth will not read although it is not damaged: it defines
    /// entities of its own, or is written in an encoding the guard cannot see
    /// through (`XMLInputGuard`). `file` is the file's path inside the package.
    case unsafeXML(file: String, problem: XMLInputGuard.Problem)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path): return "DAISY file not found at: \(path)"
        case .invalidArchive: return "The DAISY file could not be opened as a ZIP archive."
        case .notDAISYBook: return "Not a valid DAISY book (no OPF or ncc.html found)."
        case .missingContent(let msg): return "Missing DAISY content: \(msg)"
        case .parseError(let msg): return "DAISY parse error: \(msg)"
        case .malformedXML(let file, let reason):
            return PackageDamage.message(file: file, reason: reason, container: "this DAISY book", original: "the book")
        case .unsafeXML(let file, let problem):
            return XMLInputGuard.refusalSentence(for: problem, file: file, in: "this DAISY book", original: "the book")
        }
    }
}

// MARK: - DAISY Version Detection

/// Which version of the DAISY standard this book uses
enum DAISYVersion {
    case daisy202   // DAISY 2.02 — ncc.html entry point, XHTML content
    case daisy3     // DAISY 3 (Z39.86-2005) — OPF entry point, DTBook XML content
}

// MARK: - Metadata

/// Basic metadata extracted from a DAISY book
struct DAISYMetadata {
    var title: String
    var author: String
}

// MARK: - File Provider Protocol

/// Abstraction for reading files from either a ZIP archive or a directory
protocol DAISYFileProvider {
    /// List all file paths in the package
    func listFiles() -> [String]
    /// Read the contents of a file at the given relative path
    func readFile(at path: String) throws -> Data
    /// Copy the file at the given relative path to `destination`, where
    /// nothing is yet, holding it to the bounds `readFile(at:)` holds it to.
    /// DAISY audio conversion copies each audio file with it.
    func copyFile(at path: String, to destination: URL) throws
}

extension DAISYFileProvider {
    /// Copy the file by reading it whole and writing it out: for a provider
    /// whose files are small or already in memory. The archive and folder
    /// providers copy without holding a file whole (PERF24).
    func copyFile(at path: String, to destination: URL) throws {
        try readFile(at: path).write(to: destination)
    }
}

/// Wraps a DAISYFileProvider to cache the listFiles() result. DAISY parsing
/// calls listFiles() many times (version detection, OPF lookup, metadata, etc.)
/// and each call enumerates the ZIP archive or filesystem. Caching avoids
/// redundant I/O.
class CachingFileProvider: DAISYFileProvider {
    private let inner: DAISYFileProvider
    private var cachedFiles: [String]?

    init(wrapping provider: DAISYFileProvider) {
        self.inner = provider
    }

    func listFiles() -> [String] {
        if let cached = cachedFiles { return cached }
        let files = inner.listFiles()
        cachedFiles = files
        return files
    }

    func readFile(at path: String) throws -> Data {
        try inner.readFile(at: path)
    }

    func copyFile(at path: String, to destination: URL) throws {
        try inner.copyFile(at: path, to: destination)
    }
}

/// Reads files from a ZIPFoundation Archive, each through the shared
/// `ArchiveEntryReader`, so no file larger than the most TextMouth reads
/// from one file (audio or text, by its extension) is read into memory
/// (TODO I05).
class ArchiveFileProvider: DAISYFileProvider {
    let archive: Archive
    /// The budget of an import that extracts the book's audio, or nil when
    /// the book is only read. With one, each file is also held to the size
    /// the archive records for it, and every file refused is kept on the
    /// budget: the DAISY audio converter carries on past an audio file it
    /// cannot copy, so the import learns of the refusal from the budget.
    let budget: ArchiveBudget?
    /// The archive's entries by path, read once: a book's every navigation,
    /// SMIL, text, and audio file is looked up by path (PERF20).
    private let index: IndexedArchive

    /// A provider of `archive`'s files, read within `budget` when given.
    init(archive: Archive, budget: ArchiveBudget? = nil) {
        self.archive = archive
        self.budget = budget
        index = IndexedArchive(archive)
    }

    func listFiles() -> [String] {
        index.entries.compactMap { entry in
            // Skip directories
            guard entry.type == .file else { return nil }
            return entry.path
        }
    }

    /// The bytes of the file at `path`: the entry of exactly that path, or
    /// else the first file whose path matches it without regard to case.
    /// - Throws: `DAISYParserError.missingContent` when no entry matches,
    ///   and `DAISYParserError.malformedXML` naming the file when it holds
    ///   more than `ArchiveEntryLimits.current` allows or, within a budget,
    ///   more than the archive records for it.
    func readFile(at path: String) throws -> Data {
        let entry = try entry(at: path)
        return try withinBounds(of: entry) {
            try ArchiveEntryReader.read(entry, in: archive, holdingToDeclaredSize: budget != nil).data
        }
    }

    /// Copy the file at `path` to `destination` a megabyte at a time, held
    /// to the bounds `readFile(at:)` holds it to, so an audio file of up to
    /// 256 MB never sits whole in memory (PERF24). A copy that fails, the
    /// entry found too large partway included, leaves nothing behind.
    /// - Throws: as `readFile(at:)` throws, or the error writing threw
    ///   (never taken for damage in the archive: `WriteFailure`).
    func copyFile(at path: String, to destination: URL) throws {
        let entry = try entry(at: path)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            // The chunks ZIPFoundation hands over are 16 KB; a write for each
            // took longer than reading the whole file into memory had, so
            // they are gathered into batches of a megabyte first.
            var batch = Data()
            batch.reserveCapacity(Self.writeBatchSize)
            _ = try withinBounds(of: entry) {
                try ArchiveEntryReader.stream(entry, in: archive, limit: nil, holdingToDeclaredSize: budget != nil) { chunk in
                    batch.append(chunk)
                    if batch.count >= Self.writeBatchSize {
                        // A failed write (a full disk) is not the archive's damage.
                        do { try handle.write(contentsOf: batch) } catch { throw WriteFailure(underlying: error) }
                        batch.removeAll(keepingCapacity: true)
                    }
                }
            }
            try handle.write(contentsOf: batch)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// How many bytes of an entry `copyFile(at:to:)` gathers before writing.
    private static let writeBatchSize = 1_048_576

    /// The entry of the file at `path`: the entry of exactly that path, or
    /// else the first file whose path matches it without regard to case.
    /// - Throws: `DAISYParserError.missingContent` when no entry matches.
    private func entry(at path: String) throws -> Entry {
        guard let entry = index.file(at: path) else {
            throw DAISYParserError.missingContent("File not found in archive: \(path)")
        }
        return entry
    }

    /// A failure to write a file out while it is copied, which `withinBounds`
    /// passes on as it was: the error itself, not ZIP damage. Internal so that
    /// a test can throw one, since a full disk cannot be made in a test.
    struct WriteFailure: Error {
        /// The error the write threw.
        let underlying: Error
    }

    /// Run `body`, which reads `entry`, naming an entry it finds too large,
    /// or whose data cannot be unpacked, in the DAISY damage sentence and
    /// keeping that on the budget. ZIPFoundation's own error for the second
    /// is logged as `DAISY_ZIP_ERROR`, not shown. A failed write
    /// (`WriteFailure`) is the error it was.
    func withinBounds<Value>(of entry: Entry, _ body: () throws -> Value) throws -> Value {
        let reason: String
        do {
            return try body()
        } catch let failure as WriteFailure {
            throw failure.underlying
        } catch let overflow as ArchiveEntryOverflow {
            reason = overflow.reason
        } catch {
            reason = ArchiveEntryReader.unreadableReason(of: entry, error: error, tag: "DAISY_ZIP_ERROR")
        }
        let damage = DAISYParserError.malformedXML(file: entry.path, reason: reason)
        budget?.record(damage)
        throw damage
    }
}

/// Reads files from a filesystem directory
class DirectoryFileProvider: DAISYFileProvider {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Every file in the folder and the folders inside it, by its path
    /// relative to the folder. Enumerating by path yields those relative
    /// paths directly. Deriving them by deleting the folder's path from each
    /// enumerated URL failed wherever that path passed through a symbolic
    /// link, as /tmp and /var do: the URLs then start with the link's target
    /// (/private/var/…), and every file was listed under a wrong path, so no
    /// book in such a folder could be read (TODO I02).
    func listFiles() -> [String] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: baseURL.path) else {
            return []
        }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            // Following symbolic links, as before: a link to a folder is
            // not a file.
            var isDir: ObjCBool = false
            fm.fileExists(atPath: baseURL.appendingPathComponent(relative).path, isDirectory: &isDir)
            if !isDir.boolValue {
                files.append(relative)
            }
        }
        return files
    }

    func readFile(at path: String) throws -> Data {
        let fullURL = baseURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fullURL.path) else {
            throw DAISYParserError.missingContent("File not found: \(path)")
        }
        return try Data(contentsOf: fullURL)
    }

    /// Copy the file at `path` to `destination` as the file system copies a
    /// file: on APFS a clone, which shares the file's blocks rather than
    /// reading them, so an audio file costs neither time nor memory to copy
    /// (PERF24). A symbolic link is followed, as reading the file follows it.
    /// - Throws: as `readFile(at:)` throws, or the error copying threw.
    func copyFile(at path: String, to destination: URL) throws {
        let fullURL = baseURL.appendingPathComponent(path)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullURL.path, isDirectory: &isFolder) else {
            throw DAISYParserError.missingContent("File not found: \(path)")
        }
        guard !isFolder.boolValue else {
            // A folder is not a file: reading it fails, as it always has.
            try readFile(at: path).write(to: destination)
            return
        }
        try FileManager.default.copyItem(at: fullURL.resolvingSymlinksInPath(), to: destination)
    }
}

/// Reads one DTBook file kept on its own (FMT04): the provider lists that
/// file alone, so nothing beside it in its folder, which is not part of the
/// book, is ever listed, read, or copied.
final class SingleFileProvider: DAISYFileProvider {
    /// The DTBook file.
    private let fileURL: URL

    /// Prepare to serve `fileURL`.
    /// - Throws: `DocumentTooLargeError` when the file, by its size in the
    ///   file system, passes the document byte limit, so a file too large
    ///   is refused in those words rather than taken for no book at all
    ///   (version detection passes over a file it cannot read).
    init(fileURL: URL) throws {
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        try DocumentByteLimit.check(byteCount: Int64(size))
        self.fileURL = fileURL
    }

    /// The file's name alone.
    func listFiles() -> [String] {
        [fileURL.lastPathComponent]
    }

    /// The file's bytes, held to the document byte limit.
    /// - Throws: `DAISYParserError.missingContent` for any other path,
    ///   and the limit's or the file system's error for the file itself.
    func readFile(at path: String) throws -> Data {
        try requireFile(at: path)
        return try DocumentByteLimit.contents(of: fileURL)
    }

    /// Copy the file to `destination`, held to the same bounds as reading it.
    /// - Throws: as `readFile(at:)` throws.
    func copyFile(at path: String, to destination: URL) throws {
        try readFile(at: path).write(to: destination)
    }

    /// Refuses every path but the file's own name.
    private func requireFile(at path: String) throws {
        guard path == fileURL.lastPathComponent else {
            throw DAISYParserError.missingContent("File not found: \(path)")
        }
    }
}

// MARK: - Main Parser

/// Parses DAISY 2.02 and DAISY 3 books, extracting text content as Markdown.
/// Handles both zipped packages and unzipped directories.
///
/// DAISY 3: Reads OPF for metadata, DTBook XML for content, NCX for navigation.
/// DAISY 2.02: Reads ncc.html for metadata/navigation, content HTML files for text.
enum DAISYParser {

    // MARK: - Public API

    /// Parse a DAISY book into DocumentContent for reading/playback.
    /// Accepts a ZIP file, a directory, or an individual .opf/.daisy file.
    static func parse(url: URL) throws -> DocumentContent {
        let markdown = try extractMarkdown(from: url)
        let metadata = try? readMetadata(from: url)
        // A name the book does not give (empty, as a DTBook on its own
        // leaves one it does not name) falls back like a missing book.
        let title = metadata.flatMap { $0.title.isEmpty ? nil : $0.title }
            ?? url.deletingPathExtension().lastPathComponent
        let author = metadata.flatMap { $0.author.isEmpty ? nil : $0.author } ?? Book.unknownAuthor

        let content = try MarkdownDocParser.parse(markdown: markdown, title: title)
        return DocumentContent(title: title, author: author, chapters: content.chapters)
    }

    /// Extract Markdown from a DAISY book. Main conversion entry point for
    /// MarkdownCacheService cache generation.
    /// - Parameter includesPages: whether page markers are written (PG08); false writes what cache format 3.0.7 wrote:
    ///   a DTBook `pagenum` as "[Page N]" on a line of its own, and a DAISY 2.02 page's number as text.
    /// - Parameter reportIncompleteContent: receives a diagnostic for each
    ///   DTBook content file that broke off after some of its text was read.
    ///   That text stays in the result; the diagnostic never enters it. The
    ///   default writes the diagnostic to the console and the debug log.
    static func extractMarkdown(
        from url: URL,
        includesPages: Bool = true,
        reportIncompleteContent: (DAISYParserError) -> Void = DAISYParser.logIncompleteContent
    ) throws -> String {
        let provider = try makeFileProvider(from: url)
        guard let version = detectVersion(in: provider) else {
            throw DAISYParserError.notDAISYBook
        }

        switch version {
        case .daisy3:
            return try extractDAISY3Markdown(
                from: provider,
                includesPages: includesPages,
                reportIncompleteContent: reportIncompleteContent
            )
        case .daisy202:
            return try extractDAISY202Markdown(from: provider, includesPages: includesPages)
        }
    }

    /// Default report for a content file that broke off after some of its
    /// text was read: one line in the console and in the debug log. The
    /// import layer has no warning channel yet, so the reader is not told;
    /// the recovered words stay readable either way.
    static func logIncompleteContent(_ diagnostic: DAISYParserError) {
        PackageDamage.log(diagnostic, tag: "DAISY_INCOMPLETE_CONTENT")
    }

    /// Read metadata (title, author) from a DAISY book
    static func readMetadata(from url: URL) throws -> DAISYMetadata? {
        let provider = try makeFileProvider(from: url)
        guard let version = detectVersion(in: provider) else {
            throw DAISYParserError.notDAISYBook
        }

        switch version {
        case .daisy3:
            return try readDAISY3Metadata(from: provider)
        case .daisy202:
            return try readDAISY202Metadata(from: provider)
        }
    }

    /// Detect whether a ZIP file contains a DAISY book.
    /// Used by the import system to identify DAISY packages in zip imports.
    /// An archive holding several DAISY books, each in a folder of its own,
    /// is not one book but a batch, whose books import one by one; an
    /// archive with a book at its top level is that book (TODO I02). An
    /// archive holding a TextMouth package is a batch too, in which the
    /// package imports with its record, even when it holds a DAISY book
    /// (`FileImportService.liesInTMBPackage(_:)`).
    static func isDAISYZip(url: URL) -> Bool {
        guard let archive = Archive.openedForReading(at: url) else { return false }
        // Cached, since detection and the count of books both list the archive.
        let provider = CachingFileProvider(wrapping: ArchiveFileProvider(archive: archive))
        guard !provider.listFiles().contains(where: FileImportService.liesInTMBPackage) else { return false }
        guard detectVersion(in: provider) != nil else { return false }
        let folders = packageFolders(inArchivePaths: provider.listFiles())
        return folders.count <= 1 || folders.contains("")
    }

    /// Detect whether a directory holds a DAISY book: a package file or a
    /// navigation file at its top level (`packageEntryPoints(in:)`). A
    /// folder of books, each in a folder of its own, is not itself a book,
    /// and neither is a folder whose files merely include one (TODO I02).
    static func isDAISYDirectory(url: URL) -> Bool {
        !packageEntryPoints(in: url).isEmpty
    }

    // MARK: - File Access Abstraction

    /// Create the appropriate file provider for a URL (ZIP, directory, or single file).
    /// Returns a CachingFileProvider that avoids redundant listFiles() calls during
    /// version detection, OPF lookup, and metadata extraction.
    private static func makeFileProvider(from url: URL) throws -> DAISYFileProvider {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DAISYParserError.fileNotFound(url.path)
        }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)

        let base: DAISYFileProvider

        if isDir.boolValue {
            // Unzipped DAISY directory
            base = DirectoryFileProvider(baseURL: url)
        } else {
            let ext = url.pathExtension.lowercased()

            if ext == "zip" || ext == "daisy" {
                // ZIP archive
                do {
                    let archive = try Archive(url: url, accessMode: .read)
                    base = ArchiveFileProvider(archive: archive)
                } catch {
                    throw DAISYParserError.invalidArchive
                }
            } else if ext == "xml", XMLDocumentSniffer.rootKind(ofFileAt: url) == .dtbook {
                // A DTBook file on its own (FMT04): the book is that file
                // and nothing beside it.
                base = try SingleFileProvider(fileURL: url)
            } else if isPackageEntryFile(url) {
                // A package file (.opf) or a DAISY 2.02 navigation file
                // (ncc.html): its folder holds the book. The chosen file is
                // listed first, so the reader takes it over any other
                // package file in the folder (TODO I02).
                let parentDir = url.deletingLastPathComponent()
                base = EntryFirstFileProvider(
                    entry: url.lastPathComponent,
                    wrapping: DirectoryFileProvider(baseURL: parentDir)
                )
            } else if let archive = Archive.openedForReading(at: url) {
                // Try opening as ZIP anyway (some DAISY files don't have .zip extension)
                base = ArchiveFileProvider(archive: archive)
            } else {
                throw DAISYParserError.notDAISYBook
            }
        }

        return CachingFileProvider(wrapping: base)
    }

    // MARK: - Version Detection

    /// Detect the DAISY version by checking for format-specific signatures.
    /// Returns nil when the provider contains no DAISY package structure.
    private static func detectVersion(in provider: DAISYFileProvider) -> DAISYVersion? {
        let allFiles = provider.listFiles()

        // DAISY 2.02 packages use ncc.html (or the older .htm spelling) as
        // their navigation entry point. Compare the final path component so
        // packages nested inside a directory are detected consistently.
        if allFiles.contains(where: {
            let fileName = ($0 as NSString).lastPathComponent.lowercased()
            return fileName == "ncc.html" || fileName == "ncc.htm"
        }) {
            return .daisy202
        }

        // DAISY 3: has an .opf file
        if allFiles.contains(where: { $0.lowercased().hasSuffix(".opf") }) {
            return .daisy3
        }

        // A standalone DTBook can omit the OPF package. Inspect candidate XML
        // files rather than treating every archive containing XML as DAISY.
        if findDTBookXML(in: allFiles, provider: provider) != nil {
            return .daisy3
        }

        return nil
    }

    // MARK: - DAISY 3 Extraction

    /// Extract Markdown from a DAISY 3 book (DTBook XML content)
    private static func extractDAISY3Markdown(
        from provider: DAISYFileProvider,
        includesPages: Bool,
        reportIncompleteContent: (DAISYParserError) -> Void
    ) throws -> String {
        // Find the OPF file
        let allFiles = provider.listFiles()
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            // Try to find a standalone DTBook XML
            guard let xmlPath = findDTBookXML(in: allFiles, provider: provider) else {
                throw DAISYParserError.missingContent("No OPF or DTBook XML found")
            }
            return try convertDTBook(
                at: xmlPath,
                in: provider,
                includesPages: includesPages,
                pagesBefore: 0,
                reportIncompleteContent: reportIncompleteContent
            ).markdown
        }

        // Parse OPF to find the DTBook XML file
        let opfResult = try DAISYOPFParser(path: opfPath, in: provider).parse()

        // Collect DTBook content files, using spine order when available
        let opfDir = (opfPath as NSString).deletingLastPathComponent
        var dtbookPaths: [String] = []

        if !opfResult.spineItemRefs.isEmpty {
            // Use spine order to determine reading sequence
            for idref in opfResult.spineItemRefs {
                guard let item = opfResult.manifest[idref] else { continue }
                if item.mediaType.contains("dtbook") || item.mediaType.contains("x-dtbook") {
                    let path = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                    dtbookPaths.append(path)
                }
            }
        }

        // Fall back to scanning manifest if spine didn't yield DTBook files
        if dtbookPaths.isEmpty {
            for (_, item) in opfResult.manifest {
                if item.mediaType.contains("dtbook") || item.mediaType.contains("x-dtbook") {
                    let path = opfDir.isEmpty ? item.href : "\(opfDir)/\(item.href)"
                    dtbookPaths.append(path)
                }
            }
        }

        // Last resort: find any .xml file that looks like DTBook
        if dtbookPaths.isEmpty {
            if let xmlPath = findDTBookXML(in: allFiles, provider: provider) {
                dtbookPaths.append(xmlPath)
            }
        }

        guard !dtbookPaths.isEmpty else {
            throw DAISYParserError.missingContent("No DTBook XML found in DAISY package")
        }

        // Convert each content file and concatenate in reading order
        // The pages of the files before each, so that the ordinal a page with no
        // words is labelled by counts through the whole book, not each file.
        var allMarkdown: [String] = []
        var pagesBefore = 0
        for path in dtbookPaths {
            let conversion = try convertDTBook(
                at: path,
                in: provider,
                includesPages: includesPages,
                pagesBefore: pagesBefore,
                reportIncompleteContent: reportIncompleteContent
            )
            pagesBefore = conversion.pagesRead
            if !conversion.markdown.isEmpty {
                allMarkdown.append(conversion.markdown)
            }
        }
        return allMarkdown.joined(separator: "\n\n")
    }

    /// Convert one DTBook content file to Markdown, its pages numbered after
    /// the `pagesBefore` of the files before it. Text read before any
    /// damage is kept, and the damage goes to `reportIncompleteContent`
    /// instead of into the book's text.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   damaged before any text, or the provider's error when it is missing.
    private static func convertDTBook(
        at path: String,
        in provider: DAISYFileProvider,
        includesPages: Bool,
        pagesBefore: Int,
        reportIncompleteContent: (DAISYParserError) -> Void
    ) throws -> DTBookConversion {
        let conversion = try DTBookToMarkdownConverter(
            path: path, in: provider, includesPages: includesPages, pagesBefore: pagesBefore
        ).convert()
        if let diagnostic = conversion.diagnostic {
            reportIncompleteContent(diagnostic)
        }
        return conversion
    }

    /// Find a DTBook XML file by scanning for files with a <dtbook> root
    /// element. `XMLDocumentSniffer` decides, as it decides for a loose .xml
    /// file at import, so a DTBook is found whatever its encoding (UTF-16,
    /// ISO 8859-1, any declared one), however long its prolog, and under any
    /// file name. Only the first `scanLength` bytes of each file are looked
    /// at; a file that cannot be read is passed over.
    private static func findDTBookXML(in files: [String], provider: DAISYFileProvider) -> String? {
        for path in files where path.lowercased().hasSuffix(".xml") {
            if let data = try? provider.readFile(at: path),
               XMLDocumentSniffer.rootKind(of: data) == .dtbook {
                return path
            }
        }
        return nil
    }

    /// Read metadata from a DAISY 3 OPF file
    private static func readDAISY3Metadata(from provider: DAISYFileProvider) throws -> DAISYMetadata? {
        let allFiles = provider.listFiles()
        guard let opfPath = allFiles.first(where: { $0.lowercased().hasSuffix(".opf") }) else {
            // Without an OPF, the DTBook's own head and front matter name
            // the book. A damaged DTBook gives no metadata, and the import
            // names the book by its file: the text extraction reports the
            // damage in its own words.
            guard let xmlPath = findDTBookXML(in: allFiles, provider: provider) else { return nil }
            return try? DAISYDTBookHeadParser(path: xmlPath, in: provider).parse()
        }
        let result = try DAISYOPFParser(path: opfPath, in: provider).parse()
        return DAISYMetadata(title: result.title, author: result.author)
    }

    // MARK: - DAISY 2.02 Extraction

    /// Extract Markdown from a DAISY 2.02 book (XHTML content). With
    /// `includesPages`, each page the NCC lists (PG08) becomes a page marker
    /// in place of the content fragment holding its number, which is then not
    /// read. Internal so tests can drive it with an in-memory package.
    static func extractDAISY202Markdown(from provider: DAISYFileProvider, includesPages: Bool = true) throws -> String {
        // Find ncc.html (case-insensitive)
        let allFiles = provider.listFiles()
        guard let nccPath = allFiles.first(where: {
            $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm")
        }) else {
            throw DAISYParserError.missingContent("No ncc.html found for DAISY 2.02")
        }

        // Parse NCC for metadata and navigation structure
        let nccResult = try DAISY202NCCParser(path: nccPath, in: provider).parse()

        // Collect text fragments referenced by SMIL files, preserving NCC
        // heading order. Do not collapse "book.html#p1" down to "book.html":
        // many DAISY 2.02 books repeat wrapper/title text at the file level,
        // while SMIL points at the precise spoken fragment.
        var textReferences: [String] = []
        var seenReferences: Set<String> = []
        var smilFiles = DAISY202SMILCache(provider: provider)
        for heading in nccResult.headings {
            // Heading href → SMIL file → text content file
            let smilFile = ParserUtilities.resolvedPackagePath(
                heading.href,
                relativeTo: nccPath,
                preserveFragment: false
            )

            // A missing SMIL file is skipped as before; a damaged one throws.
            if let smil = try smilFiles.references(at: smilFile) {
                for ref in smil.textReferences {
                    let textPath = ParserUtilities.resolvedPackagePath(
                        ref,
                        relativeTo: smilFile,
                        preserveFragment: true
                    )
                    if seenReferences.insert(textPath).inserted {
                        textReferences.append(textPath)
                    }
                }
            }
        }

        // The page markers, by the text reference each stands in for.
        var pageMarkers: [String: [DAISY202PageMarker]] = [:]
        if includesPages {
            pageMarkers = try pageMarkersByReference(nccResult.pages, nccPath: nccPath, smilFiles: &smilFiles)
        }

        // If we found text references, extract and convert only those fragments.
        if !textReferences.isEmpty {
            let markdown = try extractDAISY202Fragments(
                from: textReferences,
                provider: provider,
                includesPages: includesPages,
                pageMarkers: pageMarkers
            )
            if !markdown.isEmpty { return markdown }
        }

        // Fallback: build Markdown from just the NCC headings
        // (this happens for audio-only DAISY 2.02 books)
        var markdown = ""
        for heading in nccResult.headings {
            let prefix = String(repeating: "#", count: min(heading.level, 6))
            markdown += "\n\(prefix) \(heading.text)\n\n"
        }

        return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The page markers of a DAISY 2.02 book's NCC page entries (PG08), each
    /// under the resolved text reference (`file.html#id`) that holds the
    /// page's number, in NCC order. A page is labelled by its entry's words,
    /// or by its place in the NCC (1-based) when the entry has none.
    ///
    /// An entry's link names a SMIL `par` or `text` by id; that element's
    /// `text` source is the content fragment. An entry is dropped when it
    /// has no link with an id, its SMIL file is missing (a damaged SMIL file
    /// throws, as it does for a heading), the id is not in that file, or the
    /// source names a whole file: such a reference would make the marker take
    /// the place of the file's text.
    private static func pageMarkersByReference(
        _ pages: [NCCPage],
        nccPath: String,
        smilFiles: inout DAISY202SMILCache
    ) throws -> [String: [DAISY202PageMarker]] {
        var markers: [String: [DAISY202PageMarker]] = [:]
        for (index, page) in pages.enumerated() {
            let fragment = ParserUtilities.splitFragment(page.href).fragment
            guard !fragment.isEmpty else { continue }
            let smilFile = ParserUtilities.resolvedPackagePath(page.href, relativeTo: nccPath, preserveFragment: false)
            guard let smil = try smilFiles.references(at: smilFile),
                  let source = smil.textReferencesByID[fragment] else { continue }
            let reference = ParserUtilities.resolvedPackagePath(source, relativeTo: smilFile, preserveFragment: true)
            guard !ParserUtilities.splitFragment(reference).fragment.isEmpty else { continue }
            let marker = MarkdownPageMarker(label: page.label, ordinal: index + 1)
            markers[reference, default: []].append(DAISY202PageMarker(label: page.label, markdown: marker.markdown))
        }
        return markers
    }

    /// Extract DAISY 2.02 text references from their HTML fragments.
    /// Fragment-less references still convert the whole file, but SMIL
    /// references with #ids are narrowed to that element so content.md does not
    /// bake in duplicate wrapper text or unrelated file-level content.
    ///
    /// Every word is read once, even where references overlap. A reference
    /// inside a fragment already read (a sentence, then a word within it) is
    /// skipped, and a fragment enclosing one already read (the word, then its
    /// sentence) leaves the words read before out. Two different elements
    /// with the same words are both read: a repeated line is still a line.
    /// Internal so tests can drive it with an in-memory package.
    ///
    /// - Parameters:
    ///   - includesPages: passed to the HTML converter, so with false every
    ///     fragment converts exactly as before pages (PG08).
    ///   - pageMarkers: the page markers (see `pageMarkersByReference`) by the
    ///     reference each stands in for. Its markers are written as blocks
    ///     where the reference stood. If its element holds only the page
    ///     number it is not read and counts as read, so a fragment enclosing
    ///     it leaves its number out too; otherwise it is read as any
    ///     fragment is. A page whose content file cannot be read is dropped.
    static func extractDAISY202Fragments(
        from references: [String],
        provider: DAISYFileProvider,
        includesPages: Bool = true,
        pageMarkers: [String: [DAISY202PageMarker]] = [:]
    ) throws -> String {
        var documents: [String: SwiftSoup.Document] = [:]
        var htmlByPath: [String: String] = [:]
        var fragments: [String] = []
        var ledger = DAISY202ReadingLedger()

        for reference in references {
            let split = ParserUtilities.splitFragment(reference)
            guard !split.path.isEmpty else { continue }

            let doc: SwiftSoup.Document
            let html: String
            if let cachedDoc = documents[split.path], let cachedHTML = htmlByPath[split.path] {
                doc = cachedDoc
                html = cachedHTML
            } else {
                guard let data = try? provider.readFile(at: split.path),
                      let decodedHTML = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1),
                      !decodedHTML.isEmpty else {
                    continue
                }
                html = decodedHTML
                doc = try MarkupGuard.parse(decodedHTML)
                documents[split.path] = doc
                htmlByPath[split.path] = decodedHTML
            }

            // A page's marker is written where its fragment stood. When the
            // fragment holds only the page's own number, the marker stands
            // in its place and the number is not read. Any other fragment is
            // real text an NCC entry points at, such as a heading: the
            // marker goes before it and the text is read as ever, never lost.
            if let markers = pageMarkers[reference] {
                fragments.append(contentsOf: markers.map(\.markdown))
                if let element = try doc.getElementById(split.fragment),
                   markers.contains(where: { $0.isNumber(in: (try? element.text()) ?? "") }) {
                    ledger.markRead(element)
                    continue
                }
            }

            // The element a reference names, or the body for a whole file.
            // Words already read, inside an earlier fragment, are not repeated.
            let target: SwiftSoup.Element
            if split.fragment.isEmpty {
                guard let body = doc.body() else { continue }
                target = body
            } else if let element = try doc.getElementById(split.fragment) {
                target = element
            } else {
                continue
            }
            guard !ledger.isRead(target) else { continue }

            let fragmentMarkdown: String
            if split.fragment.isEmpty {
                fragmentMarkdown = convertDAISY202WholeFile(
                    html,
                    body: target,
                    ledger: ledger,
                    includesPages: includesPages
                )
            } else {
                fragmentMarkdown = try convertDAISY202FragmentElement(
                    target,
                    ledger: ledger,
                    includesPages: includesPages
                )
            }
            ledger.markRead(target)

            let normalized = ParserUtilities.normalizeMarkdownWhitespace(fragmentMarkdown)
            guard !normalized.isEmpty else { continue }
            fragments.append(normalized)
        }

        return ParserUtilities.normalizeMarkdownWhitespace(fragments.joined(separator: "\n\n"))
    }

    /// Tags DAISY 2.02 producers wrap sentences and phrases in. A fragment
    /// with one of these tags is read as plain words; see `inlineWords(of:ledger:)`.
    private static let daisy202InlineFragmentTags: Set<String> = [
        "a", "span", "strong", "em", "b", "i", "sup", "sub"
    ]

    /// Markdown for the element a SMIL reference names, without any part of
    /// it that an earlier fragment already read.
    private static func convertDAISY202FragmentElement(
        _ element: SwiftSoup.Element,
        ledger: DAISY202ReadingLedger,
        includesPages: Bool
    ) throws -> String {
        if daisy202InlineFragmentTags.contains(element.tagName().lowercased()) {
            return inlineWords(of: element, ledger: ledger)
        }

        // Block fragments keep the converter's structure: headings,
        // paragraphs, lists. A block enclosing earlier fragments is
        // converted from a copy without them.
        let source = try ledger.containsRead(element) ? ledger.unreadCopy(of: element) : element
        return try HTMLToMarkdownConverter.convert(source.outerHtml(), includesPages: includesPages)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Markdown for a whole content file. Until some fragment of it has been
    /// read, the file's source converts exactly as it always has; after that,
    /// only the part of its body not yet read.
    private static func convertDAISY202WholeFile(
        _ html: String,
        body: SwiftSoup.Element,
        ledger: DAISY202ReadingLedger,
        includesPages: Bool
    ) -> String {
        guard ledger.containsRead(body) else {
            return (try? HTMLToMarkdownConverter.convert(html, includesPages: includesPages)) ?? ""
        }
        return (try? HTMLToMarkdownConverter.convert(
            ledger.unreadCopy(of: body).outerHtml(),
            includesPages: includesPages
        )) ?? ""
    }

    /// The words of an inline fragment, each once and in source order, as
    /// plain text with whitespace collapsed.
    ///
    /// Producers wrap each sentence or phrase in a span, emphasis, or link,
    /// often with text beside nested elements, as in
    /// `<span>The <em>quick</em> brown <strong>fox</strong></span>`.
    /// Emphasis and link syntax change nothing a listener hears, yet can
    /// corrupt what they do hear: CommonMark reads `**The **`, emphasis
    /// ending in a space as DAISY text often does, as literal asterisks, and
    /// a link whose SMIL destination contains a space as literal brackets.
    /// So an inline fragment contributes its words alone. Content outside
    /// the reading flow and parts an earlier fragment read are left out.
    private static func inlineWords(of element: SwiftSoup.Element, ledger: DAISY202ReadingLedger) -> String {
        guard !PublicationSemantics.isExcludedFromReadingFlow(element) else { return "" }
        var words = ""
        appendInlineWords(of: element, to: &words, ledger: ledger)
        return words.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Append the text of `node`'s children to `words`, in source order.
    private static func appendInlineWords(of node: Node, to words: inout String, ledger: DAISY202ReadingLedger) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                words += text.getWholeText()
                continue
            }
            guard let element = child as? SwiftSoup.Element,
                  !PublicationSemantics.isExcludedFromReadingFlow(element),
                  !ledger.wasReadItself(element) else { continue }
            switch element.tagName().lowercased() {
            case "script", "style":
                continue
            case "br":
                // A line break still separates the words on either side.
                words += " "
            case "img":
                // An image reads as its description, as block conversion renders it.
                words += " \((try? element.attr("alt")) ?? "") "
            default:
                // A block nested in an inline element, invalid but seen in
                // real books, must not run its first or last word into its
                // neighbors.
                let boundary = element.isBlock() ? " " : ""
                words += boundary
                appendInlineWords(of: element, to: &words, ledger: ledger)
                words += boundary
            }
        }
    }

    /// Read metadata from a DAISY 2.02 ncc.html
    private static func readDAISY202Metadata(from provider: DAISYFileProvider) throws -> DAISYMetadata? {
        let allFiles = provider.listFiles()
        guard let nccPath = allFiles.first(where: {
            $0.lowercased().hasSuffix("ncc.html") || $0.lowercased().hasSuffix("ncc.htm")
        }) else {
            return nil
        }
        let result = try DAISY202NCCParser(path: nccPath, in: provider).parse()
        return DAISYMetadata(title: result.title, author: result.author)
    }
}

// MARK: - DAISY 2.02 Page Marker

/// A page marker of a DAISY 2.02 book (PG08), with the label its NCC entry
/// gave, which tells whether the content fragment it points at holds a page
/// number or real text.
struct DAISY202PageMarker: Equatable {
    /// The NCC entry's words, whitespace collapsed; empty when it had none.
    let label: String
    /// The marker as written in content.md.
    let markdown: String

    /// Whether `fragmentText` is no more than this page's number: empty, or
    /// the page's own label, the NCC entry's words, once case, spaces, and a
    /// trailing period are ignored ("12" or "12." for the entry "12"), or
    /// that label's twin in the other numbering ("V" for "5", "5" for "V");
    /// for an entry without words, any text short enough to be a label. Any
    /// other fragment is words a listener must hear: a heading such as "IV"
    /// or "1984" that a page entry points at, a caption such as "Page 12", or
    /// a paragraph a faulty link names. The rule is shared with EPUB's
    /// page-break elements: `MarkdownPageMarker.isNoMoreThanLabel`.
    func isNumber(in fragmentText: String) -> Bool {
        MarkdownPageMarker.isNoMoreThanLabel(fragmentText, label: label)
    }
}

// MARK: - DAISY 2.02 SMIL Cache

/// Reads each SMIL file of a DAISY 2.02 book once, however many headings and
/// pages point into it (PG08). Headings and page entries are read from the
/// same files, so without this each page would parse its file again.
private struct DAISY202SMILCache {
    /// The package the files are read from.
    let provider: DAISYFileProvider
    /// What each file read held, by path; nil for a file that is missing.
    private var filesByPath: [String: DAISYSMILReferences?] = [:]

    init(provider: DAISYFileProvider) {
        self.provider = provider
    }

    /// What the SMIL file at `path` points at; nil when it cannot be read
    /// (the book then goes on without it, as it always has).
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   damaged; a file is never half-read.
    mutating func references(at path: String) throws -> DAISYSMILReferences? {
        if let known = filesByPath[path] { return known }
        let references = try (try? DAISYSMILParser(path: path, in: provider))?.parseReferences()
        filesByPath[path] = .some(references)
        return references
    }
}

// MARK: - DAISY 2.02 Reading Ledger

/// Remembers which elements of the DAISY 2.02 content documents have been
/// read into the book's text, so SMIL references that overlap (a sentence,
/// then a word inside it, or the reverse) never speak the same words twice.
///
/// Elements are recorded by identity; the parsed documents stay cached, and
/// so alive, for the whole extraction. Deleting read elements from the DOM
/// would be simpler, but every deletion invalidates SwiftSoup's id index, and
/// rebuilding it for each of a long book's thousands of references is
/// quadratic.
private struct DAISY202ReadingLedger {
    /// Elements whose words are already in the text.
    private var readElements: Set<ObjectIdentifier> = []
    /// Every ancestor of a read element: converting one of these must leave
    /// out the part already read.
    private var readContainers: Set<ObjectIdentifier> = []

    /// Whether `element`'s words are already in the text, because it or an
    /// element enclosing it was read.
    func isRead(_ element: SwiftSoup.Element) -> Bool {
        var candidate: SwiftSoup.Element? = element
        while let current = candidate {
            if readElements.contains(ObjectIdentifier(current)) { return true }
            candidate = current.parent()
        }
        return false
    }

    /// Whether `element` itself was read. Inside a fragment being converted,
    /// no enclosing element was read, so this is the only check needed.
    func wasReadItself(_ element: SwiftSoup.Element) -> Bool {
        readElements.contains(ObjectIdentifier(element))
    }

    /// Whether some element inside `element` was already read.
    func containsRead(_ element: SwiftSoup.Element) -> Bool {
        readContainers.contains(ObjectIdentifier(element))
    }

    /// Record that `element`'s words are now in the text.
    mutating func markRead(_ element: SwiftSoup.Element) {
        readElements.insert(ObjectIdentifier(element))
        var ancestor = element.parent()
        while let container = ancestor {
            // A container already recorded has had all its ancestors recorded.
            guard readContainers.insert(ObjectIdentifier(container)).inserted else { break }
            ancestor = container.parent()
        }
    }

    /// A detached deep copy of `element` without the elements already read.
    /// Only the copy changes: the cached document keeps serving later lookups.
    func unreadCopy(of element: SwiftSoup.Element) throws -> SwiftSoup.Element {
        // `copy()` is SwiftSoup's deep copy. `copy(parent:)` would share the
        // original children, and removing one would edit the document itself.
        // An element's copy is always an element; the cast only satisfies the
        // compiler, since `copy()` is typed `Any`.
        guard let copy = element.copy() as? SwiftSoup.Element else { return element }
        try removeReadElements(correspondingTo: element, from: copy)
        return copy
    }

    /// Remove from `copy` the counterparts of the read elements inside
    /// `original`. A deep copy's child lists line up with the original's.
    private func removeReadElements(correspondingTo original: Node, from copy: Node) throws {
        let originals = original.getChildNodes()
        let copies = copy.getChildNodes()
        // Work back to front, so no removal shifts an index still to visit.
        for index in originals.indices.reversed() {
            guard let element = originals[index] as? SwiftSoup.Element else { continue }
            if wasReadItself(element) {
                try copies[index].remove()
            } else if containsRead(element) {
                try removeReadElements(correspondingTo: element, from: copies[index])
            }
        }
    }
}
