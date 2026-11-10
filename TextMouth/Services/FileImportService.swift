import Foundation
import CryptoKit
import UniformTypeIdentifiers
import ZIPFoundation

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
    /// A ZIP archive holds a file whose path climbs out of the folder it is
    /// extracted into, which is never extracted (TODO I05).
    case archivePathOutside
    /// A plain text, Markdown, or HTML file holds no text a listener could
    /// hear (it is empty, or only white space or markup), so importing it
    /// would add a silent, empty book. An import refuses it
    /// (`FileImportService.readableContent(of:run:refusingBlankText:)`).
    case noTextToRead
    /// An .xml file whose root element is not a DTBook's, Word 2003 XML's, or
    /// a PEF's: XML is a container for countless things, and TextMouth reads
    /// only those three kinds (`XMLDocumentSniffer`, FMT04, FMT13, and FMT20).
    case unsupportedXML

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported file format: .\(ext)"
        case .hashingFailed: return "Failed to compute file hash."
        case .importFailed(let msg): return "Import failed: \(msg)"
        case .recordNotReadBack: return "The bookInfo.json file did not read back as it was written."
        case .unplayableAudio(let failure): return failure.message
        case .unreadableArchive: return "The archive is damaged, incomplete, or not a ZIP archive."
        case .archiveLinksOutside: return "The archive holds a link to a file outside it, which is never extracted."
        case .archivePathOutside: return "The archive holds a file whose path leads outside it, which is never extracted."
        case .noTextToRead: return "This file has no text to read."
        case .unsupportedXML:
            return "This XML file is not a DTBook book, a Word 2003 XML document, or a PEF braille file, the kinds of XML file TextMouth reads."
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

/// A book an import produced, with the report of what its source could not
/// supply. The library decides from the report whether the original file
/// may be deleted and whether the reader must be warned.
struct ImportedBook {
    var book: Book
    /// The chapters the source names that could not be read and, for a PDF,
    /// the pages whose pictures OCR could not read. It reports nothing
    /// missing for a complete book and for formats that do not report yet.
    var report = ExtractionReport()
    /// Whether the book was copied from a folder of files, not from one
    /// file: a DAISY book kept as loose files (its folder, or its OPF or
    /// ncc.html inside that folder, TODO I02), a folder of audio tracks
    /// (FR17, Part B), or an RTFD, which is a folder too. A folder may hold
    /// files the import did not copy (a cover, lyrics, other books' files, a
    /// Bonus folder), so it is never deleted or offered for deletion.
    /// `deleteOriginalFile(at:)` refuses a folder too, whatever its caller
    /// decided.
    var isFromFolder = false
    /// Whether the import took only part of its original into the library,
    /// so the original is the only copy of the rest: a DAISY audio ZIP,
    /// whose audio becomes the book while its text (the DTBook a braille
    /// reader uses), its images, and anything else the archive holds stay
    /// in the archive. Such an original is never deleted or offered for
    /// deletion.
    var tookOnlyPartOfOriginal = false
    /// What a DAISY audio ZIP's import left in the archive, and the archive's
    /// name, when it took only part of its original: names the book and the
    /// archive in `originalKeptNotice`, and counts the other books the
    /// archive holds that were not imported. Nil for every other import.
    var archiveLeftovers: DAISYArchiveLeftovers?
    /// What the import tells the listener once the book is in the library,
    /// besides what is missing from it (`warning`): the entries a playlist
    /// import skipped (FMT10). Nil when there is nothing to tell. It does
    /// not keep the original: a playlist's is never deleted anyway.
    var notice: String?

    /// Whether the original file must stay exactly where it is: an import
    /// that left chapters or pages out never deletes it or offers to,
    /// whatever the "After Importing a Book" preference says.
    var keepsOriginal: Bool { !report.isComplete }

    /// Whether the "After Importing a Book" preference may delete the
    /// original, or offer to: only for a complete book copied whole from a
    /// single file. A DAISY book's or a folder of tracks' original is a
    /// folder of files, some of which may belong to other books or to
    /// nothing the import copied, so it is never deleted (TODO I02, FR17);
    /// nor is an original the import took only part of
    /// (`tookOnlyPartOfOriginal`), which holds the rest of the book.
    var mayDeleteOriginal: Bool { !keepsOriginal && !isFromFolder && !tookOnlyPartOfOriginal }

    /// What the reader is told when "After Importing a Book" would have
    /// deleted this book's original, or asked about it, but cannot: the
    /// words of every kept original, then why. An RTFD's original is a
    /// folder, which an import never deletes; an original the import took
    /// only part of is the only copy of the rest, and the only import that
    /// does that is a DAISY audio ZIP's, so the words name it. Nil for any
    /// other import, whose original is deleted, offered, or kept without a
    /// word (a DAISY folder or a folder of tracks is kept silently, as it
    /// always was).
    var originalKeptNotice: String? {
        if tookOnlyPartOfOriginal, let leftovers = archiveLeftovers {
            return DAISYArchiveWording.originalKept(bookTitle: book.title, leftovers: leftovers)
        }
        let reason: String
        if isFromFolder, book.format == .rtfd {
            reason = "it is a folder, and an import never deletes a folder"
        } else {
            return nil
        }
        return "The original file was kept: \(reason)."
    }

    /// The warning an import that left chapters or pages out presents once:
    /// what is missing, then that the original was kept. Nil for a complete
    /// import.
    var warning: String? {
        guard keepsOriginal else { return nil }
        return "\(report.message) The original file was kept."
    }

    /// All the import tells the listener once the book is in the library:
    /// what is missing from it (`warning`), then what it skipped (`notice`),
    /// as one message; nil when there is nothing to tell.
    var announcement: String? { announcement(warning: warning) }

    /// The import's message with `warning` in place of its own: the
    /// library's choice of warning (what is missing, or an RTFD's kept
    /// original), then what it skipped (`notice`), as one message; nil when
    /// there is nothing to tell.
    func announcement(warning: String?) -> String? {
        let sentences = [warning, notice].compactMap { $0 }
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}

/// What the audio import of a DAISY archive left in the archive
/// (`FileImportService.daisyArchiveLeftovers(of:archiveName:)`).
struct DAISYArchiveLeftovers: Equatable {
    /// The archive's file name.
    var archiveName: String
    /// Whether the DAISY folder holds text the audio book lacks.
    var holdsText: Bool
    /// How many other books the archive holds outside the DAISY folder.
    var otherBookCount: Int

    /// Whether the archive holds nothing the import left behind.
    var isEmpty: Bool { !holdsText && otherBookCount == 0 }
}

/// The files a SMIL document's text elements name, which tell whether a
/// DAISY book has text of its own beyond its navigation.
final class SMILTextSources: NSObject, XMLParserDelegate {
    /// The `src` of each text element read, fragments included.
    private var sources: [String] = []

    /// The `src` of each text element in `data`, in order, up to the point
    /// a damaged document stops the read; the sources found stand.
    ///
    /// A file the XML guard refuses (a tag with too many attributes, entities
    /// of its own, an encoding it cannot see through; `XMLInputGuard`) is
    /// never given to the XML parser, but it still names its text: the
    /// sources are found by `sourcesWithoutParsing(_:)`. Reading none would
    /// say a book has no text of its own, and the archive that holds the
    /// only copy of that text would be offered for deletion.
    static func scan(_ data: Data) -> [String] {
        guard XMLInputGuard.problem(with: data) == nil else { return sourcesWithoutParsing(data) }
        let scanner = SMILTextSources()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = scanner
        parser.parse()
        return scanner.sources
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        // Prefixed names ("smil:text") count; only the local name matters.
        guard elementName.split(separator: ":").last == "text", let source = attributeDict["src"] else { return }
        sources.append(source)
    }

    /// A text element's start tag, its prefix allowed (`smil:text`), up to
    /// its `src` attribute in either kind of quotation mark. The white space
    /// after the name is looked at but not consumed (`(?=\s)`), so a `src`
    /// that comes first is found by the white space before it. The tag's other
    /// attributes are passed over by `[^<>]*?`, which never crosses the start
    /// or the end of another tag, so a file made of unclosed tags is read in
    /// one pass, not once for each. Group 1 and 2 are the source.
    private static let sourcePattern =
        #"<(?:[^\s<>:/]+:)?text(?=\s)[^<>]*?\ssrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#

    /// The `src` of each text element in `data`, found as text and not as
    /// XML, for a file the guard keeps from the XML parser: no entity is
    /// expanded and no document type read, so the file costs no more than a
    /// pass over its bytes. ISO Latin 1 gives every byte a character, so
    /// markup in any ASCII-compatible encoding reads as it is written.
    private static func sourcesWithoutParsing(_ data: Data) -> [String] {
        guard let markup = String(data: data, encoding: .isoLatin1),
              let expression = try? NSRegularExpression(pattern: sourcePattern) else { return [] }
        return expression.matches(in: markup, range: NSRange(markup.startIndex..., in: markup)).compactMap { match in
            [1, 2].lazy.compactMap { Range(match.range(at: $0), in: markup) }.first.map { String(markup[$0]) }
        }
    }
}

/// What an import reads about a book from its file before copying it: the
/// title and author the book is listed under, and the format's extra
/// fields. Reading it never fails an import: a file that names no title or
/// author, or whose metadata is damaged, is listed under its file name and
/// an unknown author.
struct ImportedFileMetadata {
    /// The version of this reader, stamped on each row it reads for
    /// (`Book.metadataReaderVersion`), so the first launch after a version
    /// that reads a format's metadata better reads every older row's file
    /// again (`LibraryViewModel.refreshOutdatedMetadata`). Semantic
    /// versioning: major.minor.patch.
    /// 1.0.0: an EPUB's author is read from the creator with the author
    /// role, from a dcterms:creator meta element, or from a contributor
    /// with the author role (`EPUBParser.authorName(in:)`); rows never
    /// stamped were read by what came before.
    static let readerVersion = "1.0.0"

    /// Whether this reader opens a file of `format` at all: a plain text,
    /// Markdown, or HTML file keeps no title or author it reads.
    static func readsFile(of format: BookFormat) -> Bool {
        switch format {
        case .epub, .docx, .rtf, .rtfd, .doc, .odt, .wordml, .braille, .pdf, .daisy, .audio, .mobi, .kfx: return true
        case .txt, .markdown, .html, .webarchive, .ssml: return false
        }
    }

    var title: String
    var author = Book.unknownAuthor
    /// Everything an EPUB's package document says about the book.
    var epub: EPUBMetadata?
    /// Audio tags, for an audio file.
    var audioAlbum: String?
    var audioGenre: String?
    var audioYear: String?

    /// Reads the metadata `format` keeps inside the file at `url`, starting
    /// from `fallbackTitle`, or the file's name when that is nil, and an
    /// unknown author. A textutil format's title and author are read by
    /// converting the document, which costs a run of textutil: an import
    /// sets `readingTextutilNames` false, since the conversion that reads
    /// its text names them too (`MarkdownCacheService.GeneratedCache`), and
    /// the launch refresh leaves it true.
    static func read(
        from url: URL,
        format: BookFormat,
        fallbackTitle: String? = nil,
        readingTextutilNames: Bool = true
    ) -> ImportedFileMetadata {
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
        case .rtf, .rtfd, .doc, .odt, .wordml:
            // Title and author from the head of textutil's HTML. Reading
            // metadata never fails an import, so a refusal (a password, a
            // damaged file) leaves the defaults and the import's own
            // reading of the text fails with its sentence.
            if readingTextutilNames, let named = try? TextutilDocumentReader.readMetadata(from: url, bookFormat: format) {
                adopt(title: named.title, author: named.author)
            }
        case .braille:
            // A PEF names its title and author in its head (FMT20); a BRF
            // or a BRL names nothing, so it keeps its file's name and the
            // unknown author.
            if BrailleBookReader.kind(of: url) == .pef {
                let named = BrailleFileReader.pefMetadata(of: url)
                adopt(title: named.title ?? "", author: named.author ?? "")
            }
        case .pdf:
            // Title and author from the document's attributes.
            if let attributes = PDFTextParser.readMetadata(from: url) {
                adopt(title: attributes.title, author: attributes.author)
            }
        case .mobi:
            // Title and author from the book's EXTH records, or its header
            // (FMT42). Reading metadata never fails an import, so a book
            // that is protected or cannot be read keeps the defaults and the
            // import's own reading of the text fails with its sentence.
            if let named = try? MOBIParser.readMetadata(url: url) {
                adopt(title: named.title, author: named.author)
            }
        case .kfx:
            // Title and author from the book's metadata fragment (FMT52).
            // Reading metadata never fails an import, so a book that is
            // protected or cannot be read keeps the defaults and the
            // import's own reading of the text fails with its sentence.
            if let named = try? KFXParser.readMetadata(url: url) {
                adopt(title: named.title, author: named.author)
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
        case .txt, .markdown, .html, .webarchive, .ssml:
            break
        }
        return metadata
    }

    /// The common metadata tags of the audio file at `url`, read through
    /// AVFoundation's asynchronous loading while this thread waits, as an
    /// import runs off the main thread. Reading tags never throws, so the
    /// empty tags are only the type checker's fallback.
    private static func audioTags(of url: URL) -> AudioMetadata {
        (try? AsyncBridge.waitForResult(reading: url, timeLimit: AsyncBridge.audioTagsTimeLimit) { await AudioPlaybackService.extractFullMetadata(from: url) }) ?? AudioMetadata()
    }
}

/// A file from a ZIP import that did not import in full, with what went
/// wrong: why it failed, or what its book is missing.
struct ZipImportFailure: Equatable {
    /// What a book imported without all of its text is missing, which
    /// decides where the batch's summary lists it.
    enum Missing: Equatable {
        /// Chapters its reading order names.
        case chapters
        /// Pages of a PDF whose pictures OCR could not read.
        case pages
    }

    let fileName: String
    let message: String
    /// For a book imported without all of its text, what it is missing. A
    /// file that failed keeps the default, which nothing reads.
    var missing: Missing = .chapters
}

/// The files a ZIP batch passed over because they are in no format
/// TextMouth imports, counted by extension, so the end of a batch that
/// found no book can say what the archive held instead. Until October 13,
/// 2026 such a batch said only that it found no books, and only to
/// VoiceOver: an archive of 176 Ogg radio dramas, before TextMouth played
/// Ogg, was extracted, searched, and removed without a word on screen.
struct NonBookFiles: Equatable, Sendable {
    /// How many files have each extension, lowercased, with "" for files
    /// without one.
    var countsByExtension: [String: Int] = [:]

    /// How many files there are in all.
    var total: Int { countsByExtension.values.reduce(0, +) }

    /// Each extension with its count, most files first, and in alphabetical
    /// order among extensions with as many, so a message names the same
    /// kinds in the same order every time.
    var kinds: [(fileExtension: String, count: Int)] {
        countsByExtension
            .map { (fileExtension: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.fileExtension < $1.fileExtension }
    }

    /// Counts the file at `url` by its extension.
    mutating func add(_ url: URL) {
        countsByExtension[url.pathExtension.lowercased(), default: 0] += 1
    }

    /// Adds `other`'s counts to `files`'.
    static func += (files: inout NonBookFiles, other: NonBookFiles) {
        files.countsByExtension.merge(other.countsByExtension, uniquingKeysWith: +)
    }
}

/// Why a folder chosen to import holds no book to import as one (FR17):
/// neither a DAISY book nor audio tracks. It says what the folder holds,
/// as a ZIP without a book does (`ImportProgressWording.noBookInFolder`).
struct FolderWithoutBookError: LocalizedError, Equatable {
    /// The folder's name.
    let folderName: String
    /// The files it holds, by kind.
    let files: NonBookFiles

    var errorDescription: String? {
        ImportProgressWording.noBookInFolder(named: folderName, holding: files)
    }
}

struct ZipImportResult {
    let books: [Book]
    let failures: [ZipImportFailure]
    /// Books that were imported without all of their text (some chapters,
    /// or pages of a PDF whose pictures OCR could not read), by file, each
    /// with its extraction report's sentence. They keep the ZIP.
    var incompleteBooks: [ZipImportFailure] = []
    /// Where the batch stopped when the reader cancelled it (TODO I05); nil
    /// when it ran to its end. A cancelled batch keeps the ZIP.
    var cancellation: ZipImportCancellation?
    /// How many of the books found were skipped as duplicates, already in
    /// the library or found earlier in the archive: none of them is
    /// imported, and none is a failure.
    var skippedDuplicates = 0
    /// The files the batch passed over as no book TextMouth imports, which
    /// the alert of a batch that found no book names by kind.
    var nonBookFiles = NonBookFiles()

    /// Whether the batch ran to its end without bringing a book into the
    /// library and without anything in it failing: every book it found was
    /// already in the library, or it found none. `failureSummary` is nil for
    /// such a batch and no question follows it, so the library's alert says
    /// what it found instead (`ImportProgressWording.nothingImported`).
    var foundNoNewBook: Bool {
        books.isEmpty && failures.isEmpty && cancellation == nil
    }

    /// Whether the original ZIP must be kept whatever the "After Importing
    /// a Book" preference says: a file in it failed, a book from it is
    /// missing chapters or pages, or the batch was cancelled before every
    /// book was imported, so the ZIP is still the only complete copy of
    /// something.
    var keepsOriginal: Bool {
        !failures.isEmpty || !incompleteBooks.isEmpty || cancellation != nil
    }

    /// What the library's alert says about the batch: where it stopped, when
    /// it was cancelled; the files that failed; the books missing chapters;
    /// then the PDFs with pages that could not be read. A cancelled batch,
    /// or one with books missing chapters or pages, also says the original
    /// ZIP was kept. Nil when every file imported in full and the batch ran
    /// to its end.
    var failureSummary: String? {
        var sections: [String] = []
        if !failures.isEmpty {
            sections.append("\(failures.count) file\(failures.count == 1 ? "" : "s") failed:\n\(Self.lines(failures))")
        }
        let missingChapters = incompleteBooks.filter { $0.missing == .chapters }
        if !missingChapters.isEmpty {
            let books = CountWording.phrase(missingChapters.count, singular: "book is", plural: "books are")
            sections.append("\(books) missing chapters:\n\(Self.lines(missingChapters))")
        }
        let missingPages = incompleteBooks.filter { $0.missing == .pages }
        if !missingPages.isEmpty {
            let books = CountWording.phrase(missingPages.count, singular: "book has", plural: "books have")
            sections.append("\(books) pages that could not be read:\n\(Self.lines(missingPages))")
        }
        guard !sections.isEmpty || cancellation != nil else { return nil }

        let imported = "Imported \(books.count) book\(books.count == 1 ? "" : "s")"
        var sentences: [String] = []
        if let cancellation {
            sentences.append(cancellation.sentence)
        }
        if !sections.isEmpty {
            sentences.append("\(imported), but \(sections.joined(separator: "\n"))")
        } else if cancellation != .whileExtracting {
            // A cancellation alone: say what came of the books before it.
            sentences.append("\(imported).")
        }
        let kept = incompleteBooks.isEmpty && cancellation == nil ? "" : "\nThe original file was kept."
        return sentences.joined(separator: " ") + kept
    }

    /// One "file: message" line per entry.
    private static func lines(_ entries: [ZipImportFailure]) -> String {
        entries.map { "\($0.fileName): \($0.message)" }.joined(separator: "\n")
    }

    /// The tag that starts the debug-log line recording how a ZIP batch
    /// ended; tooling searches for it, so it never changes.
    static let finishedLogTag = "ZIP_IMPORT_FINISHED"

    /// The debug-log line recording how the batch of the archive named
    /// `archiveName` ended, whatever it brought: its counts, whether a
    /// cancel stopped it, and the files it passed over, by kind, as in
    /// `ZIP_IMPORT_FINISHED: Radio.zip: imported=0 duplicates=0 failed=0
    /// incomplete=0 cancelled=false notBooks=176 (ogg 176)`. Until
    /// October 13, 2026 a batch that failed nowhere logged nothing, so a
    /// batch that found no book left no trace to diagnose.
    func logLine(archiveName: String) -> String {
        let counts = "imported=\(books.count) duplicates=\(skippedDuplicates) failed=\(failures.count) "
            + "incomplete=\(incompleteBooks.count) cancelled=\(cancellation != nil) notBooks=\(nonBookFiles.total)"
        let kinds = nonBookFiles.kinds.map { kind in
            "\(kind.fileExtension.isEmpty ? "no extension" : kind.fileExtension) \(kind.count)"
        }
        let passedOver = kinds.isEmpty ? "" : " (\(kinds.joined(separator: ", ")))"
        return "\(Self.finishedLogTag): \(archiveName): \(counts)\(passedOver)"
    }
}

/// How far a ZIP batch has got, told to the library's import overlay
/// (TODO I05), so it moves before the first book imports, and names each
/// book as it imports and the step it is at (FR10).
enum ZipImportProgress: Equatable, Sendable {
    /// The archive named `archive` (the archive imported, or one found
    /// inside it) has extracted as much as `progress` says: its entries,
    /// and the bytes they declare (FR10).
    case extracting(archive: String, progress: ArchiveExtractionProgress)
    /// The batch found its books, `sizes.count` of them, each by the size
    /// the estimate of the time left times it by (`timedSize(of:)`), in the
    /// order they import; told once, before the first book begins (FR10).
    case foundBooks(sizes: [Int64?])
    /// The book numbered `number` of the `total` found in the archive, the
    /// item named `book` there (its file, or a DAISY book's folder), began
    /// `step`, one of the steps a failure names (FR10). Each book begins by
    /// reading its file, whose checksum tells a duplicate, and then each
    /// step its import takes on its package.
    case importingBook(number: Int, total: Int, book: String, step: ImportStep)
    /// `done` of the `total` books found in the archive are imported,
    /// failed, or skipped as duplicates; `skippedDuplicate` when the book
    /// just done was skipped as one, which takes next to no time, so the
    /// estimate of the time left does not count it (FR10).
    case importing(done: Int, total: Int, skippedDuplicate: Bool = false)
}

/// Where a ZIP batch the reader cancelled stopped (TODO I05).
enum ZipImportCancellation: Equatable, Sendable {
    /// While extracting the archive, or an archive inside it, before any
    /// book was imported.
    case whileExtracting
    /// After `completed` of the `total` books found in the archive were
    /// imported, failed, or skipped as duplicates.
    case afterBooks(completed: Int, total: Int)

    /// The sentence the batch's summary starts with.
    var sentence: String {
        switch self {
        case .whileExtracting:
            return "Import cancelled while extracting the archive, before any book was imported."
        case let .afterBooks(completed, total):
            return "Import cancelled after \(completed) of \(total) book\(total == 1 ? "" : "s")."
        }
    }

    /// Where the batch stopped, for its `IMPORT_CANCELLED` log line.
    var logDetail: String {
        switch self {
        case .whileExtracting:
            return "while extracting the archive"
        case let .afterBooks(completed, total):
            return "after \(completed) of \(total) books"
        }
    }
}

/// What a ZIP batch found in its archive (TODO I05): the books to import,
/// each listed once, and the archives inside it that could not be searched,
/// each with why. The batch lists those among its failures, so the original
/// archive, the only complete copy of their books, is kept.
struct ImportCandidates: Equatable {
    /// The books to import.
    var books: [URL] = []
    /// The archives inside that could not be searched.
    var failures: [ZipImportFailure] = []
    /// The files passed over as no book TextMouth imports.
    var nonBookFiles = NonBookFiles()

    /// Adds `other`'s books, failures, and files passed over to
    /// `candidates`'.
    static func += (candidates: inout ImportCandidates, other: ImportCandidates) {
        candidates.books += other.books
        candidates.failures += other.failures
        candidates.nonBookFiles += other.nonBookFiles
    }
}

/// How a ZIP batch unpacks the archives it finds inside its archive (TODO
/// I05): each into a folder of its own in `directory`, within the batch's
/// budget, so archives inside count toward the same limits as the archive
/// itself, and no deeper than `ArchiveLimits.maximumNestingDepth`: one
/// found deeper is reported, not unpacked, since an archive can hold itself.
struct NestedArchiveUnpacking {
    /// Where each archive is unpacked, in a folder of its own.
    let directory: URL
    /// The batch's budget, shared by every archive it extracts.
    let budget: ArchiveBudget
    /// How deep the archives this unpacking opens lie: 1 for those inside
    /// the archive being imported.
    let depth: Int
    /// The batch's cancellation check, asked between entries and chunks.
    let isCancelled: ImportCancellationCheck
    /// Told how far each archive's extraction has got, under its name.
    let progress: ((ZipImportProgress) -> Void)?

    /// The books in `archive`, unpacked within the budget and searched like
    /// the archive itself, with whatever inside it could not be searched;
    /// or a failure naming `archive` when it cannot be searched at all,
    /// because it lies deeper than the batch unpacks, is damaged, or holds
    /// paths or sizes that cannot be trusted. Its books are then not
    /// imported, and the batch's other books still are.
    /// - Throws: `ArchiveBudgetError` when the budget refuses `archive`,
    ///   and `ImportCancelled` when the reader cancels while it is unpacked;
    ///   either stops the whole batch.
    func candidates(inArchive archive: URL) throws -> ImportCandidates {
        let name = archive.lastPathComponent
        let maximumDepth = budget.limits.maximumNestingDepth
        guard depth <= maximumDepth else {
            return ImportCandidates(failures: [ZipImportFailure(fileName: name, message: Self.tooDeep(maximumDepth))])
        }
        let destination = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try ArchiveExtractor.extract(
                archiveAt: archive,
                into: destination,
                budget: budget,
                nestedArchive: name,
                isCancelled: isCancelled,
                progress: Self.extractionProgress(of: name, to: progress)
            )
        } catch let stop where stop is ArchiveBudgetError || stop is ImportCancelled {
            throw stop
        } catch {
            // None of it will be imported, so its space is freed now.
            try? FileManager.default.removeItem(at: destination)
            let reason = ImportFailure(fileName: name, step: .extractingArchive, underlying: error).reason
            return ImportCandidates(failures: [ZipImportFailure(fileName: name, message: reason)])
        }
        return try FileImportService.importCandidates(
            in: destination,
            unpacking: NestedArchiveUnpacking(
                directory: directory,
                budget: budget,
                depth: depth + 1,
                isCancelled: isCancelled,
                progress: progress
            )
        )
    }

    /// `progress`, told how far the extraction of the archive named
    /// `archive` has got; nil when no one is told.
    static func extractionProgress(
        of archive: String,
        to progress: ((ZipImportProgress) -> Void)?
    ) -> ((ArchiveExtractionProgress) -> Void)? {
        guard let progress else { return nil }
        return { extraction in progress(.extracting(archive: archive, progress: extraction)) }
    }

    /// Why an archive lying deeper than `maximumDepth` levels is not searched.
    static func tooDeep(_ maximumDepth: Int) -> String {
        "Not extracted: TextMouth extracts archives within an archive only "
            + "\(maximumDepth) level\(maximumDepth == 1 ? "" : "s") deep."
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
    /// that exists, in the format `info` records, and with the checksum it
    /// records (`content(at:of:hasChecksum:)`). The only content that may be
    /// a folder is an audio book's folder of tracks, which has no checksum
    /// of its own to check, and an RTFD book's package, which is a folder
    /// checked as a file is: its format and its folder checksum
    /// (`contentChecksum(of:format:)`) must be the record's.
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
        // A folder is a folder of tracks unless it is an RTFD, a document
        // that happens to be a folder: that is checked below like a file.
        if contentIsDirectory.boolValue && !isRTFDFolder(contentURL) {
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
        if try contentChecksum(of: contentURL, format: format) == recorded {
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
    /// location: every field the record keeps, its text cache's
    /// fingerprints included, as `Book(record:filePath:folderPath:tmbDirectoryName:)`
    /// builds it, with the book's file where the record names it in the
    /// package. Callers must validate the package before using this helper.
    /// Every caller places the book in the Library folder, so the book is a
    /// library book, without the feed link its record may hold (FR11).
    static func bookFromPackageInfo(
        _ info: BookInfo,
        packageURL: URL,
        folderPath: String,
        tmbName: String
    ) -> Book {
        Book(
            record: info,
            filePath: packageURL.appendingPathComponent(info.metadata.originalFileName).path,
            folderPath: folderPath,
            tmbDirectoryName: tmbName
        ).placedInLibraryFolder()
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
        try importFileWithReport(from: sourceURL, checksum: nil, toFolder: folderPath, observer: observer)
    }

    /// Imports the file at `sourceURL` as `importFileWithReport(from:toFolder:observer:)`
    /// does, knowing it by `checksum` when the caller has already read it,
    /// as a ZIP batch has for its duplicate check (`importHash(of:)`), so
    /// the file's bytes are read once for it rather than twice; nil reads
    /// it here.
    static func importFileWithReport(
        from sourceURL: URL,
        checksum: String?,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        // A symbolic link to a folder is the folder it leads to, from here on:
        // every walk of the folder below (its tracks, a DAISY book beneath it,
        // the files it holds) would otherwise start at the link, which the
        // file manager's enumerator does not enter.
        let sourceURL = resolvingLinkedFolder(sourceURL)
        // A playlist imports as one audiobook of the files it lists (FMT10).
        if isPlaylistFile(sourceURL) {
            return try importPlaylistWithReport(from: sourceURL, toFolder: folderPath, observer: observer)
        }
        // A folder of audio tracks that is no DAISY book imports as one
        // audiobook, as a ZIP of the same tracks does (FR17, Part B).
        if isFolderOfTracks(sourceURL) {
            return try importAudioFolderWithReport(from: sourceURL, toFolder: folderPath, observer: observer)
        }
        return try ImportRun.perform(importing: sourceURL.lastPathComponent, observer: observer) { run in
            guard let format = BookFormat.detect(from: sourceURL) else {
                throw unsupportedSourceError(for: sourceURL)
            }

            try run.begin(.readingSource)
            let package = try daisyPackage(of: sourceURL, format: format)
            let hash = try checksum ?? importHash(of: sourceURL, package: package)
            // A textutil format is listed by its file's name until its text
            // is read: that one conversion names its title and author
            // (`publishReadableBook`), so none is run here.
            let metadata = ImportedFileMetadata.read(
                from: package?.entryURL ?? sourceURL,
                format: format,
                fallbackTitle: package?.untitledName,
                readingTextutilNames: false
            )
            let bookID = UUID()
            let dateAdded = Date()
            try refuseProtectedKindleBook(at: sourceURL, format: format)

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
            let stagedFile = try stageContent(of: sourceURL, format: format, package: package, in: staging.directory)

            // A braille book's table, read from the setting once, so the
            // version recorded with it is that table's (review R2).
            let brailleTable = format == .braille ? BraillePreferences.importTable() : nil
            // And its braille file characters, decided once: those its bytes
            // name for certain, else the setting's (braillecodes).
            let brailleFileCode = format == .braille ? Self.brailleFileCode(ofImported: stagedFile) : nil
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
                epubVersion: metadata.epub?.epubVersion,
                metadataReaderVersion: ImportedFileMetadata.readerVersion,
                // The book's record of hand edits begins here, empty (#1291):
                // its title and author are what the metadata reader stamped
                // above read in this very file, so a launch refresh by a
                // later reader may bring every field the file names up to
                // date (`LibraryViewModel.refreshedValues(of:from:)`). No
                // other import begins one: a feed's download, a recording,
                // New from Text, and an audio or DAISY archive take their
                // names from elsewhere than the file the refresh reads, and
                // a package keeps the record it carries.
                handEdits: .noneSinceImport,
                // A braille book keeps the table it is read with (FMT21): the
                // Braille setting's, as it stands for this import. Every
                // later reading of the book uses this one, and one of this
                // Mac's tables keeps the Mac's liblouis version too (review R2).
                // A BRF or BRL keeps the braille file characters it is read in
                // the same way (braillecodes), by an explicit id, North
                // American Braille ASCII's included; a PEF keeps none.
                brailleTable: brailleTable,
                brailleTableVersion: brailleTable.flatMap(BrailleTableCatalog.versionToRecord(forTable:)),
                brailleFileCode: brailleFileCode
            )
            // The one import that guesses (FMT16): a file the user chose, whose
            // bytes may name no encoding, is read in the encoding the guesser
            // finds, and the book records it. Every other way a book comes to
            // the library (a package, a feed, a recording, text typed in) reads
            // as it always did, and so does every later reading of this book.
            // An audio file's transcript beside it is attached (FMT23).
            var imported = try publishReadableBook(
                staged, from: staging, run: &run, refusingBlankText: true, adoptingDocumentNames: true,
                guessingEncoding: true, pairingTranscripts: format.isAudio ? .besideFile(sourceURL) : nil
            )
            // A DAISY package is copied file by file from its folder; an RTFD
            // is a folder, whole, which no import deletes.
            imported.isFromFolder = package != nil || isRTFDFolder(sourceURL)
            return imported
        }
    }

    /// The braille file characters the import of the braille book whose file
    /// is staged at `url` records, by the code's id (braillecodes,
    /// BRAILLE-CODES-RESEARCH-2026-10-25.md, sections 8.3 and 8.5). A PEF
    /// records none (`BrailleBookReader.kind(of:)`): its rows are always
    /// Unicode braille patterns. A BRF or BRL records Unicode braille
    /// patterns when its bytes say so for certain
    /// (`BrailleFileReader.certainCode(ofFileAt:)`), and the Braille
    /// setting's code otherwise (`BraillePreferences.importFileCode()`). No
    /// other code is ever guessed: the seven-bit codes write their cells with
    /// the same printable characters, so no byte tells them apart for
    /// certain. The id is explicit, North American Braille ASCII's included,
    /// as the table is, so a later change of the setting never changes how
    /// the book is read.
    static func brailleFileCode(ofImported url: URL) -> String? {
        guard BrailleBookReader.kind(of: url) != .pef else { return nil }
        return BrailleFileReader.certainCode(ofFileAt: url)?.id ?? BraillePreferences.importFileCode()
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
        try package?.contentHash() ?? contentChecksum(of: source, format: BookFormat.detect(from: source))
    }

    /// The checksum of a book's own file, `url`, a book of `format`: the MD5
    /// of its bytes, except for an RTFD, which is a folder, not a file,
    /// whose checksum is that of the regular files anywhere inside it
    /// (`folderHash(of:in:)`). A plain file named .rtfd is hashed as a file.
    /// Internal so a book's fingerprint digests its RTFD with the very same
    /// walk the import used (`FingerprintHasher.md5`), and a package holding
    /// an RTFD is checked by it (`inspectContent`, `reconstructedBook`).
    static func contentChecksum(of url: URL, format: BookFormat?) throws -> String {
        guard format == .rtfd, isFolder(url) else { return try md5Hash(of: url) }
        return try folderHash(of: regularFilePaths(in: url), in: url)
    }

    /// Whether the item at `url` is an RTFD: a folder named .rtfd, the one
    /// kind of folder, besides a folder of audio tracks, that a book's
    /// content can be. A plain file with that name is not (it is read and
    /// measured as a file), and no other folder is.
    static func isRTFDFolder(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "rtfd" && isFolder(url)
    }

    /// `url` as the folder it leads to when it is a symbolic link to a folder,
    /// so that a link is imported as choosing the folder itself is. Any other
    /// item, a link to a file included, is returned as it is. The one place a
    /// top-level link is resolved for an import.
    static func resolvingLinkedFolder(_ url: URL) -> URL {
        let resolved = AudioBookParser.resolvingALinkedFolder(url)
        return resolved != url && isFolder(resolved) ? resolved : url
    }

    /// Whether the item at `url` is a folder (a package such as an .rtfd
    /// included).
    private static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// The paths, inside `folder`, of the regular files anywhere in it, by
    /// their relative paths. A symbolic link is never followed (the
    /// enumerator reports it as a link, which is not a regular file), and a
    /// hidden file or folder (a Finder's .DS_Store) is passed over, so
    /// browsing a folder in Finder never changes its checksum. Internal so
    /// an RTFD's stamp measures exactly the files its checksum reads
    /// (`FileStamp`).
    static func regularFilePaths(in folder: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: folder.path) else { return [] }
        var paths: [String] = []
        while let path = walk.nextObject() as? String {
            if (path as NSString).lastPathComponent.hasPrefix(".") {
                walk.skipDescendants()
                continue
            }
            if (walk.fileAttributes?[.type] as? FileAttributeType) == .typeRegular {
                paths.append(path)
            }
        }
        return paths
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

    /// The name the book's own file `source` is copied into its package
    /// under: its own name, unless that is the name of the package's text
    /// cache (`TextMouthPaths.contentMarkdownFileName`), compared without
    /// regard to case as the Mac's volumes compare names, when it is
    /// "content (book)" with the source's own extension, spelled as the
    /// source spells it. Otherwise the cache, written beside the book's
    /// file, would replace it, and with it the exact bytes (line endings,
    /// encoding, anything the reading drops) that Redo Text Extraction or a
    /// re-read in another encoding reads again. The book's record names the
    /// file by the name it was staged under (`Book.filePath`), so nothing
    /// else needs to know.
    static func stagedFileName(for source: URL) -> String {
        let name = source.lastPathComponent
        let cacheName = TextMouthPaths.contentMarkdownFileName
        guard name.caseInsensitiveCompare(cacheName) == .orderedSame else { return name }
        let cacheBaseName = (cacheName as NSString).deletingPathExtension
        return "\(cacheBaseName) (book).\(source.pathExtension)"
    }

    /// Refuses a Kindle KFX book that is protected by what sits beside it: a
    /// voucher, or a protected file in its `.sdr` folder. Only the book's file
    /// is copied into the library, and the text is read from that copy, where
    /// nothing stands beside it, so the refusal is made here, on the source
    /// (an `.azw` that holds KFX is one, as Kindle's apps name KFX books).
    /// - Throws: `MOBIError.copyProtected`.
    private static func refuseProtectedKindleBook(at source: URL, format: BookFormat) throws {
        var holdsKFX = format == .kfx
        if format == .mobi, let kind = try? KFXSignature.kind(ofFileAt: source) {
            holdsKFX = kind == .container || kind == .protected
        }
        if holdsKFX, KFXParser.isProtected(near: source) { throw MOBIError.copyProtected }
    }

    /// Copies what an import of `source`, a book of `format`, reads into the
    /// staged package `directory`, and returns the book's own file there:
    /// every file of `package`, laid out as in its folder, when `source` is
    /// a DAISY book kept as loose files; otherwise the source file itself,
    /// under the name `stagedFileName(for:)` gives it.
    ///
    /// A text document that is a symbolic link is copied as what it points
    /// to, a real file or folder named as the link was: a link copied as a
    /// link would point out of the package, to a place that may change or
    /// vanish. An audio file keeps today's handling (team audiofmt owns it).
    private static func stageContent(
        of source: URL,
        format: BookFormat,
        package: DAISYPackageInventory?,
        in directory: URL
    ) throws -> URL {
        guard let package else {
            let stagedFile = directory.appendingPathComponent(stagedFileName(for: source))
            let isText = format != .audio
            try FileManager.default.copyItem(at: isText ? source.resolvingSymlinksInPath() : source, to: stagedFile)
            if isText { try removeSymbolicLinks(in: stagedFile) }
            return stagedFile
        }
        logShortfalls(of: package)
        return try package.copyFiles(into: directory)
    }

    /// Removes every symbolic link anywhere inside the folder `item` (an
    /// RTFD's staged copy), hidden ones included; a file or an empty folder
    /// is left as it is. A copy keeps the links of its original, and an
    /// attachment's link may point anywhere on the disk: left in the
    /// package, it would let the book read, and a later copy carry, a file
    /// outside it. Nothing is followed, only removed.
    private static func removeSymbolicLinks(in item: URL) throws {
        let walk = FileManager.default.enumerator(
            at: item,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        )
        // Collect before removing, so the walk is not changed under itself.
        var links: [URL] = []
        while let entry = walk?.nextObject() as? URL {
            if try entry.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                links.append(entry)
            }
        }
        for link in links { try FileManager.default.removeItem(at: link) }
    }

    /// Records as import events, in the console and the debug log, what a
    /// DAISY package import copies other than as the book's references list
    /// it: the files they name that do not exist, and the whole folder, when
    /// the references could not be read. Reading the copied book as the
    /// reader will then decides whether the import succeeds. The book's
    /// folder is named by its name, and its files by their paths inside it,
    /// never by where the folder is on disk.
    private static func logShortfalls(of package: DAISYPackageInventory) {
        let folder = package.root.lastPathComponent
        if !package.missingPaths.isEmpty {
            DiagnosticLog.event(
                .import,
                "DAISY_PACKAGE_MISSING: \(folder)/\(package.entryPath): refers to \(package.missingPaths.count) "
                    + "file(s) that do not exist: \(package.missingPaths.joined(separator: ", "))"
            )
        }
        if let reason = package.wholeFolderReason {
            DiagnosticLog.event(
                .import,
                "DAISY_PACKAGE_WHOLE_FOLDER: \(folder): copied every file, since the book's "
                    + "files could not be listed: \(reason)"
            )
        }
    }

    /// Why `source` cannot be imported when no format reads it: a folder
    /// that is neither a DAISY book nor a folder of audio tracks is told so,
    /// with what it holds, as a ZIP without a book is (FR17); an .xml file
    /// that is no DTBook is told so (`FileImportError.unsupportedXML`), unless
    /// it is empty or blank, when it is told it has no text; any
    /// other item's extension is not supported. A TextMouth package is not a
    /// folder of a book here: it is imported as a package, not as a file.
    private static func unsupportedSourceError(for source: URL) -> Error {
        let ext = source.pathExtension.lowercased()
        var isDirectory: ObjCBool = false
        if ext != "tmb",
           FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return FolderWithoutBookError(folderName: source.lastPathComponent, files: filesHeld(by: source))
        }
        if ext == "xml" {
            // An .xml file with no bytes, or only white space, has no text to
            // read: say so, rather than that it is some other kind of XML.
            if XMLDocumentSniffer.holdsNoText(fileAt: source) {
                return FileImportError.noTextToRead
            }
            // An .xml file no format claimed is some other kind of XML.
            return FileImportError.unsupportedXML
        }
        return FileImportError.unsupportedFormat(ext)
    }

    /// The visible files anywhere in `folder`, counted by kind: hidden
    /// files, Finder's __MACOSX folder, and symbolic links are passed over,
    /// as the tracks' discovery passes over them. A link is no regular
    /// file, so it is never counted.
    private static func filesHeld(by folder: URL) -> NonBookFiles {
        var files = NonBookFiles()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return files }
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: keys)
            if enumerator.skipFinderMetadataFolder(item, isDirectory: values?.isDirectory) { continue }
            if values?.isRegularFile == true {
                files.add(item)
            }
        }
        return files
    }

    // MARK: Folders of Tracks (FR17, Part B)

    /// Whether `source` is a folder holding audio tracks and no book any
    /// format reads, a DAISY book's folder above all: the folder imports
    /// as one audiobook (`importAudioFolderWithReport`). A TextMouth
    /// package is never one. Neither is a folder with a DAISY book in a
    /// folder beneath it: such a folder is not itself a book, and its
    /// tracks belong to the books beneath it.
    static func isFolderOfTracks(_ linkOrFolder: URL) -> Bool {
        let source = resolvingLinkedFolder(linkOrFolder)
        guard source.pathExtension.lowercased() != "tmb", BookFormat.detect(from: source) == nil else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        // The folder is searched for DAISY books only once it is known to hold audio.
        guard !((try? AudioBookParser.audioFiles(in: source, scan: .importing)) ?? []).isEmpty else { return false }
        return !holdsDAISYBookBeneath(source)
    }

    /// Whether a folder inside `folder`, at any depth, holds a DAISY book at
    /// its top level (`DAISYParser.isDAISYDirectory(url:)`). `folder`'s own
    /// top level is not checked: `BookFormat.detect` has done that. Finder's
    /// __MACOSX folder, hidden items, and symbolic links are passed over, as
    /// `filesHeld(by:)` and the tracks' discovery pass over them. A link is
    /// no folder to the enumerator, so it is never entered.
    private static func holdsDAISYBookBeneath(_ folder: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: keys)
            if enumerator.skipFinderMetadataFolder(item, isDirectory: values?.isDirectory) { continue }
            if values?.isDirectory == true, DAISYParser.isDAISYDirectory(url: item) {
                return true
            }
        }
        return false
    }

    /// Imports the folder of audio tracks `folder` as one audiobook, as a
    /// ZIP of the same tracks imports (FR17, Part B): its tracks, and its
    /// manifest wherever the reader finds it, are copied into the book's
    /// package, laid out as in the folder; the manifest is checked as an
    /// import checks one, and names the book, which otherwise takes the
    /// folder's name; and the book is read as the reader will before it is
    /// published. The folder itself is never changed. The book is known by
    /// a checksum of its tracks' names and bytes and its manifest's
    /// (`folderHash(of:in:)`), so the same folder imported twice is a
    /// duplicate.
    /// - Throws: an `ImportFailure` naming the folder and the step that
    ///   failed; whatever was staged is removed first.
    static func importAudioFolderWithReport(
        from folder: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: folder.lastPathComponent, observer: observer) { run in
            try run.begin(.readingSource)
            var paths = try AudioBookParser.trackPaths(in: folder, scan: .importing)
            if let location = AudioManifestLocation.find(in: folder) {
                paths.append(location.prefix + AudioManifest.fileName)
            }
            let hash = try folderHash(of: paths, in: folder)
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: folder.lastPathComponent,
                author: Book.unknownAuthor,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            for path in paths {
                let destination = audioDirectory.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: folder.appendingPathComponent(path), to: destination)
            }
            var imported = try publishTracks(
                titled: folder.lastPathComponent,
                in: audioDirectory,
                of: staging,
                id: bookID,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                source: folder,
                pairingIn: folder,
                run: &run
            )
            // The folder holds files that were not copied (a cover, lyrics,
            // a Bonus folder), so it is never deleted or offered for deletion.
            imported.isFromFolder = true
            return imported
        }
    }

    /// Whether `source` is a playlist file (`M3UPlaylist.isPlaylist`): a
    /// folder that happens to be named like one is not.
    static func isPlaylistFile(_ source: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let isFolder = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return M3UPlaylist.isPlaylist(source) && !isFolder
    }

    /// Imports the audio files the playlist `playlist` (M3U or M3U8) lists
    /// as one audiobook (FMT10), as a folder of the same tracks imports
    /// (`importAudioFolderWithReport`): through the same staging, copying,
    /// manifest check, conversion of formats Apple's players must not read,
    /// and read-back before publishing. Only files inside the playlist's own
    /// folder are used (`M3UPlaylist.resolve(inFolder:)`); each is copied to
    /// the same path in the book's package. A `manifest.json` written there
    /// names the book (the playlist's `#PLAYLIST` name, else its file's name
    /// without the extension) and lists the tracks in the playlist's order
    /// with the titles its `#EXTINF` lines gave. The book is known by a
    /// checksum of its tracks' paths and bytes and the playlist's own name
    /// and bytes (`folderHash(of:in:)`), so the same playlist imported twice
    /// is a duplicate. The entries skipped are told in the result's `notice`.
    /// Nothing is deleted or offered for deletion afterwards: the tracks
    /// belong to the listener's music folders.
    /// - Throws: an `ImportFailure` naming the playlist and the step that
    ///   failed, with a `PlaylistImportError` when it is a stream, lists only
    ///   web addresses, or names no usable file; whatever was staged is
    ///   removed first, and the playlist and its tracks are never changed.
    static func importPlaylistWithReport(
        from playlist: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try ImportRun.perform(importing: playlist.lastPathComponent, observer: observer) { run in
            try run.begin(.readingSource)
            let folder = playlist.deletingLastPathComponent()
            let parsed = try M3UPlaylist.read(at: playlist)
            guard !parsed.isStreaming else { throw PlaylistImportError.streaming }
            guard !parsed.listsOnlyWebAddresses else { throw PlaylistImportError.onlyWebAddresses }
            let (tracks, skipped) = distinctTracks(of: parsed.resolve(inFolder: folder))
            guard !tracks.isEmpty else { throw PlaylistImportError.noTrack(skipped: skipped) }

            let bookTitle = parsed.title ?? playlist.deletingPathExtension().lastPathComponent
            let hash = try folderHash(of: tracks.map(\.path) + [playlist.lastPathComponent], in: folder)
            let bookID = UUID()
            let dateAdded = Date()

            try run.begin(.preparingPackage)
            let staging = try ImportStaging.makeEmpty(publishingTo: try destinationPackageURL(
                title: bookTitle,
                author: Book.unknownAuthor,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.copying, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            for track in tracks {
                let destination = audioDirectory.appendingPathComponent(track.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: track.url, to: destination)
            }
            // The manifest gives the playlist's order and titles; the check
            // and the format conversion that follow treat it as any other.
            var manifest = AudioManifest()
            manifest.title = bookTitle
            manifest.tracks = tracks.map { .track(AudioManifestTrack(file: $0.path, title: $0.title)) }
            try BookManifestFile.encoded(manifest)
                .write(to: audioDirectory.appendingPathComponent(AudioManifest.fileName))

            var imported = try publishTracks(
                titled: bookTitle,
                in: audioDirectory,
                of: staging,
                id: bookID,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                source: playlist,
                pairingIn: folder,
                run: &run
            )
            // The tracks and the playlist belong to the listener's music
            // folders, so none is deleted or offered for deletion, whatever
            // "After Importing a Book" says.
            imported.isFromFolder = true
            // The transcripts not attached (FMT23), then the entries skipped,
            // as one message; nil when neither has anything to tell.
            let notices = [
                imported.notice,
                PlaylistImportWording.notice(playlistName: playlist.lastPathComponent, skipped: skipped),
            ].compactMap { $0 }
            imported.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
            return imported
        }
    }

    /// `resolution`'s tracks, without a second spelling of one file (the
    /// same name in another case, which a Mac's disk takes for the file
    /// itself, would copy over the first), and its skipped entries with
    /// each such spelling added as listed before.
    static func distinctTracks(
        of resolution: M3UPlaylist.Resolution
    ) -> (tracks: [M3UPlaylist.Track], skipped: [M3UPlaylist.Skipped]) {
        var seen = Set<String>()
        var tracks: [M3UPlaylist.Track] = []
        var skipped = resolution.skipped
        for track in resolution.tracks {
            let key = track.path.precomposedStringWithCanonicalMapping.lowercased()
            if seen.insert(key).inserted {
                tracks.append(track)
            } else {
                skipped.append(M3UPlaylist.Skipped(location: track.path, reason: .listedBefore))
            }
        }
        return (tracks, skipped)
    }

    /// The checksum a folder of tracks is known by: the MD5 of each file's
    /// path in the folder, `paths`, sorted, with the MD5 of its bytes, so a
    /// folder holding the same files under the same names has the same one.
    private static func folderHash(of paths: [String], in folder: URL) throws -> String {
        var listing = ""
        for path in paths.sorted() {
            listing += "\(path)\n\(try md5Hash(of: folder.appendingPathComponent(path)))\n"
        }
        return FingerprintHasher.md5.digestOfData(Data(listing.utf8))
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
                author: Book.isUnknownAuthor(author) ? Book.unknownAuthor : author,
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
    /// it was published. A feed download names the feed item the book comes
    /// from in `feedLink`, which its record keeps (FR03). A download of a
    /// feed item whose package was kept after an earlier download's file
    /// went (FR11, branch A2) gives the state of the record it replaces in
    /// `replacing` (`writeVerifiedRecord`), and puts the package in place of
    /// the kept one with `publish`, which otherwise renames the staged
    /// package to its destination (`ImportStaging.publish()`). Audio the
    /// import converts is converted first, so no book is read or played
    /// from it (`convertImportedAudio(of:in:keepingOriginals:run:)`, B06,
    /// FMT09). `refusingBlankText` is passed on to
    /// `readableContent(of:run:refusingBlankText:)`: only the import of a
    /// file chosen by the user sets it, to refuse a text file with no text, and
    /// so does `adoptingDocumentNames`, which gives the book the title and
    /// author a textutil document names (`MarkdownCacheService`): the import
    /// of a file lists it by its file name until its text is read.
    /// `guessingEncoding` is passed on to
    /// `readableContent(of:run:refusingBlankText:adoptingDocumentNames:guessingEncoding:)`
    /// and set by that import alone (FMT16). With `pairingTranscripts`, which
    /// the imports of a file, a folder of tracks, a playlist, and an audio
    /// ZIP give, an audiobook's transcript files found beside its audio are
    /// attached once its content reads (`TranscriptPairing.attach`, FMT23),
    /// and the book returned carries the notice of those that were not.
    static func publishReadableBook(
        _ staged: Book,
        from staging: ImportStaging,
        run: inout ImportRun,
        feedLink: FeedBookLink? = nil,
        replacing replaced: BookState? = nil,
        refusingBlankText: Bool = false,
        adoptingDocumentNames: Bool = false,
        guessingEncoding: Bool = false,
        pairingTranscripts pairing: TranscriptPairing? = nil,
        publish: (ImportStaging) throws -> Void = { try $0.publish() }
    ) throws -> ImportedBook {
        var staged = staged
        try convertImportedAudio(
            of: &staged,
            in: staging,
            keepingOriginals: keepsOriginalsOfConvertedAudio(feedLink: feedLink),
            run: &run
        )
        let content = try readableContent(
            of: &staged, run: &run, refusingBlankText: refusingBlankText, adoptingDocumentNames: adoptingDocumentNames,
            guessingEncoding: guessingEncoding
        )
        // A transcript beside the audio goes into the staged package before
        // its record is written; attaching one never fails the import.
        let notice = pairing.flatMap { TranscriptPairing.attach($0, to: staged, index: content.index) }
        let book = staging.published(staged)

        try run.begin(.savingRecord, in: staging.directory)
        try writeVerifiedRecord(of: book, contentIndex: content.index, into: staging.directory, feedLink: feedLink, replacing: replaced)

        try run.begin(.publishing, in: staging.directory)
        try publish(staging)
        return ImportedBook(book: book, report: content.report, notice: notice)
    }

    /// What reading a book's content as the reader will produced: the index
    /// to save with the book, and the report of the chapters or pages its
    /// source could not supply (always complete for audio and for formats
    /// that do not report omissions).
    struct ReadableContent {
        var index: BookContentIndex
        var report = ExtractionReport()
    }

    /// The formats whose import is refused when the file holds no text
    /// (`FileImportError.noTextToRead`): the plain ones, and the five that
    /// textutil reads, and braille books (FMT20), whose reading already
    /// refuses a file with no blocks, and this refuses a book whose blocks
    /// translate to nothing but white space. A rich text, Word, or
    /// OpenDocument file whose text is only white space (a few empty
    /// paragraphs) converts without error, so without this it would be added
    /// as a silent book. EPUB, DOCX, DAISY, and PDF have their own refusals
    /// or none.
    private static let formatsRefusedWhenBlank: Set<BookFormat> = [
        .txt, .markdown, .html, .webarchive, .ssml, .rtf, .rtfd, .doc, .odt, .wordml, .braille,
    ]

    /// Whether an import of `book` is refused when the book holds no text:
    /// a book in one of `formatsRefusedWhenBlank`, or a DTBook kept as a
    /// loose .xml file. A DAISY package or archive is not refused: a book
    /// whose audio carries no text is a real book, and it imports as it
    /// always has. A DAISY book's own file is an .xml file only when it is
    /// a DTBook on its own (a package's is its OPF or navigation file, an
    /// archive's the archive).
    private static func refusesBlankText(_ book: Book) -> Bool {
        if formatsRefusedWhenBlank.contains(book.format) { return true }
        return book.format == .daisy && book.bookFileURL.pathExtension.lowercased() == "xml"
    }

    /// Reads `book`'s content as the reader will, so that no import publishes
    /// a book that cannot be opened. A text book's content.md is written into
    /// its package, and an extraction that fails, in any format, fails with
    /// the extraction's error. An audio book is analyzed, and one without a
    /// playable chapter fails. `book` receives the cache version and the
    /// index's counts.
    ///
    /// With `refusingBlankText` set, a plain text, Markdown, HTML, or
    /// textutil book (`formatsRefusedWhenBlank`), or a DTBook on its own
    /// (`refusesBlankText(_:)`), none of whose chapters holds a character
    /// other than white space fails with `FileImportError.noTextToRead`, so a blank
    /// file is not imported as a silent, empty book. The check is here, not
    /// in `MarkdownCacheService`, because every rebuild of an existing book's
    /// text goes through that, and a book already in the library must never
    /// become unreadable.
    ///
    /// With `adoptingDocumentNames`, `book` also takes the title and author
    /// the document names, read by the one conversion that reads its text
    /// (`MarkdownCacheService.generateReportedCacheAnalyzeAndStamp`).
    ///
    /// With `guessingEncoding`, a text file whose bytes name no encoding is
    /// read in the encoding `TextEncodingGuesser` finds, and `book` records
    /// it (`Book.textEncoding`, FMT16). Only the import of a file the user
    /// chose sets it: the other callers re-read a book that already exists
    /// (a package added back, a reinstated one), whose text must not change.
    ///
    /// A text book whose content.md holds the edit the user took with Edit
    /// Text keeps it (B12): the extraction will not read the book's file over
    /// it (`EditedTextKept`), so content.md is read as it is and indexed as
    /// the reader indexes a book whose edit stands
    /// (`BookContentAnalysisService.load`), and `book` keeps the record of
    /// the edit (`Book.editedText`) with the fingerprints that describe it
    /// (`Book.textCacheFingerprint`). Only a package that already holds a
    /// book meets this: one opened from Finder (a backup, another Mac's
    /// copy) and one that Remove from Library Only retained. It needs no
    /// parameter, since it is safe for every caller: an edit is recorded
    /// only by a book that already exists, in its row or its package's
    /// bookInfo.json (`BookTextEditSessions.holdsTakenEdit`), and every other
    /// import (a file the user chose, New from Text, a feed's download, a
    /// recording) reads into a newly staged package holding no record and no
    /// content.md, for a row recording no edit, so its text is always read
    /// from its file.
    static func readableContent(
        of book: inout Book,
        run: inout ImportRun,
        refusingBlankText: Bool = false,
        adoptingDocumentNames: Bool = false,
        guessingEncoding: Bool = false
    ) throws -> ReadableContent {
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
        let generated: MarkdownCacheService.GeneratedCache
        do {
            guard let written = try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(
                for: &book, adoptingDocumentNames: adoptingDocumentNames, decidingEncoding: guessingEncoding
            ) else {
                // Only a book without a package gets no cache, and every
                // import gives its book one before reading it.
                throw FileImportError.importFailed("The book has no package to hold its text.")
            }
            generated = written
        } catch is EditedTextKept {
            // The user's edit stands, and nothing was written: content.md is
            // indexed as it is, as the reader indexes it, checked against the
            // record the package holds.
            var index = try BookContentAnalysisService.load(book: book).index
            // A package with no record to check content.md against (Remove
            // from Library Only deleted it) gets no fingerprints from the
            // load: the book's own stand while they describe the edit, so
            // that Redo Text Extraction still keeps a copy of the edit before
            // it reads the book's file over it.
            if index.textCacheFingerprint == nil, let kept = book.textCacheFingerprint,
               kept.cache.digest == book.editedText?.cacheDigest {
                index.textCacheFingerprint = kept
            }
            book.applyContentIndexSummary(index)
            return ReadableContent(index: index)
        }
        if refusingBlankText, refusesBlankText(book),
           !generated.content.chapters.contains(where: { chapter in chapter.text.contains { !$0.isWhitespace } }) {
            throw FileImportError.noTextToRead
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
    /// `feedLink` names the feed item a downloaded book comes from (FR03).
    ///
    /// The record's note of a transcript follows `contentIndex`, as every
    /// record write carrying an index makes it follow
    /// (`Book.bookInfo(replacing:contentIndex:revisionFloor:)`). An index
    /// read from a new file holds no transcript layer, so a download of a
    /// kept feed item notes no transcript, though its package keeps one,
    /// until the episode opens and its text is laid over its index again
    /// (`TranscriptTextLoader`), which the record then notes; a transcript
    /// of other audio is found stale then, and stays unnoted. `replacing` is
    /// the state of the record such a download replaces (FR11, branch A2):
    /// the new record's revision rises above its own.
    static func writeVerifiedRecord(
        of book: Book,
        contentIndex: BookContentIndex,
        into package: URL,
        feedLink: FeedBookLink? = nil,
        replacing replaced: BookState? = nil
    ) throws {
        var info = book.makeBookInfo()
        info.contentIndex = contentIndex
        info.metadata.feedLink = feedLink
        info.state.transcript = contentIndex.transcript?.transcript
        if let replaced {
            info.state.revision = BookState.revision(after: replaced.revision ?? 0)
        }
        try info.save(to: package)

        let saved = try BookInfo.load(from: package)
        guard saved.metadata.bookID == book.id,
              saved.metadata.md5Hash == book.md5Hash,
              saved.metadata.format == book.format,
              saved.metadata.originalFileName == info.metadata.originalFileName,
              saved.metadata.feedLink == feedLink,
              saved.contentIndex != nil else {
            throw FileImportError.recordNotReadBack
        }
    }

    /// Import a ZIP file containing supported book files.
    /// Pass existingHashes to skip files whose content already exists in the library,
    /// preventing orphaned .tmb packages from being created for duplicates.
    /// Returns imported books together with any per-file failures.
    ///
    /// A TextMouth package in the archive (a .tmb folder) is one book,
    /// imported with its record as a package opened from the Finder is
    /// (`importTMBPackage(_:observer:)`): at the library's top level,
    /// whatever `folderPath` says, or, when the library holds the package
    /// Remove from Library Only retained for the book, by taking that one
    /// back where it is. One whose book the library already lists, by its
    /// ID (`existingBookIDs`) or its checksum, is skipped as a duplicate.
    ///
    /// The archive and the archives found inside it are extracted within one
    /// budget (`ArchiveLimits`, TODO I05): each is refused before anything of
    /// it is written when its declared size, its entries, or the free space it
    /// needs pass their limits, and each file is held to its recorded size as
    /// it is written. Everything goes into one extraction directory
    /// (`ArchiveExtractionDirectory`), on this Mac while the data directory
    /// shares its volume and in the data directory otherwise (FR02), removed
    /// on every exit.
    /// - Parameters:
    ///   - existingBookIDs: the books the library lists, feed items
    ///     included: a package whose record names one of them is skipped as
    ///     a duplicate, so no two of the library's rows ever share an ID.
    ///   - progress: told the entries extracted and the bytes written of each
    ///     archive's totals, then each book as it begins and as it begins
    ///     each step, and the books done of the total found, so the overlay
    ///     moves before the first book imports and while each one does
    ///     (FR10).
    ///   - isCancelled: asked between entries (and the chunks of a large
    ///     one) while extracting and between books while importing. Once it
    ///     says to stop, the batch stops, keeps the books already imported,
    ///     and returns a result saying where it stopped.
    /// - Throws: an `ImportFailure` naming the archive when it cannot be
    ///   extracted at all, or the budget refuses it or an archive inside it.
    ///   A book inside it that fails is listed in the result's failures
    ///   instead, as is an archive inside it that cannot be searched, and the
    ///   others still import.
    static func importZip(
        from zipURL: URL,
        toFolder folderPath: String = "",
        existingHashes: Set<String> = [],
        existingBookIDs: Set<UUID> = [],
        progress: ((ZipImportProgress) -> Void)? = nil,
        isCancelled: @escaping ImportCancellationCheck = { false }
    ) throws -> ZipImportResult {
        // Every exit, returned or thrown, removes what was extracted; the
        // books are copied out of it as they import.
        var extraction: ArchiveExtractionDirectory?
        defer { extraction?.remove() }

        // Extraction, of the archive and of the archives inside it, is the
        // one archive-wide step that can fail; each book in the archive then
        // imports, or fails, on its own.
        let search: ArchiveSearch = try ImportRun.perform(importing: zipURL.lastPathComponent) { run in
            try run.begin(.extractingArchive)
            try TextMouthPaths.ensureDirectoryStructure()
            let directory = try ArchiveExtractionDirectory.make()
            extraction = directory
            let budget = ArchiveBudget()
            do {
                try ArchiveExtractor.extract(
                    archiveAt: zipURL,
                    into: directory.archiveDirectory,
                    budget: budget,
                    isCancelled: isCancelled,
                    progress: NestedArchiveUnpacking.extractionProgress(of: zipURL.lastPathComponent, to: progress)
                )
                // Every book in the archive, each once, those in the archives
                // it holds included. They are extracted into another folder,
                // so the search of the archive never meets them.
                return .found(try importCandidates(
                    in: directory.archiveDirectory,
                    unpacking: NestedArchiveUnpacking(
                        directory: directory.nestedDirectory,
                        budget: budget,
                        depth: 1,
                        isCancelled: isCancelled,
                        progress: progress
                    )
                ))
            } catch is ImportCancelled {
                // The reader's choice, not a failure: nothing is logged as one.
                return .cancelled
            }
        }

        let result: ZipImportResult
        switch search {
        case .cancelled:
            result = ZipImportResult(books: [], failures: [], cancellation: .whileExtracting)
        case .found(let candidates):
            let imported = importSupportedFiles(
                candidates.books,
                toFolder: folderPath,
                existingHashes: existingHashes,
                existingBookIDs: existingBookIDs,
                progress: progress,
                isCancelled: isCancelled
            )
            // An archive inside that could not be searched is a failure too,
            // so the original, the only complete copy of its books, is kept.
            result = ZipImportResult(
                books: imported.books,
                failures: candidates.failures + imported.failures,
                incompleteBooks: imported.incompleteBooks,
                cancellation: imported.cancellation,
                skippedDuplicates: imported.skippedDuplicates,
                nonBookFiles: candidates.nonBookFiles
            )
        }
        if let cancellation = result.cancellation {
            ImportCancellation.log(zipURL.lastPathComponent, stopped: cancellation.logDetail)
        }
        DiagnosticLog.event(.import, result.logLine(archiveName: zipURL.lastPathComponent))
        return result
    }

    /// What extracting a ZIP batch's archives came to: the books found, or a
    /// stop because the reader cancelled.
    private enum ArchiveSearch {
        case found(ImportCandidates)
        case cancelled
    }

    /// The books in `directory`, an extracted archive, each listed once and
    /// in path order, for a batch import to import one by one (TODO I02),
    /// with the archives inside it that could not be searched (TODO I05):
    ///
    /// - A DAISY book kept as loose files in a folder of its own is one
    ///   book, listed as that folder, and none of the files inside counts
    ///   on its own. A folder with several books' package files lists each
    ///   package file instead, since it names no one book.
    /// - An archive whose own top level holds a DAISY book is that book.
    /// - A folder that is a Rich Text with Attachments document (an .rtfd,
    ///   a package the Finder shows as one file) is one book, listed as
    ///   that folder. Its files (the TXT.rtf and the attachments) are never
    ///   books or files passed over.
    /// - A TextMouth package (a .tmb folder, `isTMBPackageFolder(_:)`) is
    ///   one book, listed as that folder, which the batch imports as a
    ///   package with its record. Its files (the book's own file, its text
    ///   cache, its record, its tracks, a DAISY book inside it) are never
    ///   books or files passed over.
    /// - A DAISY ZIP inside is one book. Any other archive inside is
    ///   unpacked through `nested`, within the batch's budget, and searched
    ///   the same way; one that cannot be unpacked, or lies deeper than the
    ///   batch unpacks (an archive can hold itself), is listed among the
    ///   failures instead of being passed over in silence.
    /// - Any other file in a format TextMouth reads is a book. Hidden files
    ///   and the `__MACOSX` folder macOS adds to archives are passed over:
    ///   they hold copies of the archive's files that are not books.
    /// - Every other file is counted by its extension among the files
    ///   passed over, which the end of a batch that found no book names.
    /// - Throws: `ArchiveBudgetError` when the batch's budget refuses an
    ///   archive inside, and `ImportCancelled` when the reader cancels while
    ///   one is unpacked.
    static func importCandidates(in directory: URL, unpacking nested: NestedArchiveUnpacking) throws -> ImportCandidates {
        let topLevelBooks = DAISYParser.packageEntryPoints(in: directory)
        guard topLevelBooks.isEmpty else { return ImportCandidates(books: topLevelBooks) }
        guard let entries = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return ImportCandidates() }

        var found = ImportCandidates()
        for case let url as URL in entries {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if entries.skipFinderMetadataFolder(url, isDirectory: true) { continue }
                // An RTFD is a folder that stands for one document, and a
                // TextMouth package a folder holding one book with its
                // record: each is the book, never what is inside it (an
                // RTFD's TXT.rtf and attachments; a package's book file,
                // text cache, and tracks).
                if BookFormat.detect(from: url) == .rtfd || isTMBPackageFolder(url) {
                    entries.skipDescendants()
                    found.books.append(url)
                    continue
                }
                let packageFiles = DAISYParser.packageEntryPoints(in: url)
                guard !packageFiles.isEmpty else { continue }
                entries.skipDescendants()
                found.books += packageFiles.count == 1 ? [url] : packageFiles
            } else if url.pathExtension.lowercased() == "zip" {
                if DAISYParser.isDAISYZip(url: url) {
                    found.books.append(url)
                } else {
                    found += try nested.candidates(inArchive: url)
                }
            } else if BookFormat.detect(from: url) != nil {
                found.books.append(url)
            } else {
                found.nonBookFiles.add(url)
            }
        }
        found.books.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        found.failures.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        return found
    }

    /// Whether the item at `url` is a TextMouth package: a folder named
    /// .tmb, in any capitals. A ZIP batch lists one as a single book
    /// (`importCandidates(in:unpacking:)`) and imports it as a package, with
    /// its record (`importSupportedFiles`). A plain file with that name is
    /// not one.
    static func isTMBPackageFolder(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "tmb" && isFolder(url)
    }

    /// Whether the entry at `path` in an archive lies inside a TextMouth
    /// package: whether a folder on its path is named .tmb, in any capitals.
    /// An archive holding a package is a batch (`importZip`), in which the
    /// package imports with its record, so it is neither an audiobook's
    /// tracks (`LibraryViewModel.isAudioZip(url:)`) nor one DAISY book
    /// (`DAISYParser.isDAISYZip(url:)`), whatever the package holds. A file
    /// named like a package is not a folder on any path.
    static func liesInTMBPackage(_ path: String) -> Bool {
        // Every part but the last names a folder; a folder entry's path
        // ends in "/", so its own name is a part before the last, "".
        path.split(separator: "/", omittingEmptySubsequences: false)
            .dropLast()
            .contains { (String($0) as NSString).pathExtension.lowercased() == "tmb" }
    }

    /// The bytes a ZIP batch's book is timed by, which the estimate of the
    /// time left weighs it by (`TimeLeftEstimate`, FR10): the size of a text
    /// book's file (EPUB, PDF, Word, plain text, Markdown, or HTML), whose
    /// text is read whole as it imports. Nil for an audiobook's file, whose
    /// import reads its chapters rather than its every byte, so its size says
    /// little of its time; for a DAISY book's package file, folder, or ZIP,
    /// which may hold its audio; and for a file whose size can't be read. A
    /// book without a size is counted at the average time of the books
    /// timed without one.
    static func timedSize(of book: URL) -> Int64? {
        // The file's own attributes first: a folder, or a ZIP, which in a
        // batch is a DAISY book's, is never opened to be sized.
        guard let values = try? book.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0,
              book.pathExtension.lowercased() != "zip",
              let format = BookFormat.detect(from: book), format != .audio, format != .daisy else { return nil }
        return Int64(size)
    }

    /// Import files discovered inside a ZIP while retaining individual errors
    /// and the books imported without some of their chapters.
    /// This is separate from archive discovery so partial-import behavior is
    /// deterministic and independently testable.
    ///
    /// A TextMouth package (`isTMBPackageFolder(_:)`) is identified once, by
    /// its record or its removal marker (`identifyTMBPackage(at:)`), whose
    /// checksum and book ID the duplicate check compares, and imported as a
    /// package opened from the Finder is (`importTMBPackage(_:observer:)`),
    /// never through `checksum` or `importer`: at the library's top level,
    /// whatever `folderPath` says, or, for a book whose package Remove from
    /// Library Only retained, by taking that one back where it is. A package
    /// that cannot be identified is listed among the failures.
    /// - Parameters:
    ///   - existingHashes: the checksums of the books the library holds; a
    ///     file known by one of them is skipped as a duplicate.
    ///   - existingBookIDs: the books the library lists; a package whose
    ///     record names one of them, or a book this batch imported, is
    ///     skipped as a duplicate, so no two rows ever share an ID.
    ///   - progress: told first the size each file is timed by
    ///     (`ZipImportProgress.foundBooks`), then, for each file, that it
    ///     begins by reading the file, or a package by checking it
    ///     (`ZipImportProgress.importingBook`), each step its import then
    ///     begins on its package, and the files done of the total once it is
    ///     imported, fails, or is skipped as a duplicate (FR10).
    ///   - isCancelled: asked before each file. Once it says to stop, the
    ///     files not yet imported are left alone, the books already imported
    ///     are kept, and the result says after how many of how many files
    ///     the batch stopped (TODO I05).
    ///   - checksum: reads the checksum a file is known by, which the
    ///     duplicate check compares (`importHash(of:)`); tests count its
    ///     reads.
    ///   - importer: imports one file into a library folder, given the
    ///     checksum the duplicate check read, nil when it could not, so the
    ///     file's bytes are read once for it, and telling the observer it is
    ///     given as each step on the book's package begins.
    static func importSupportedFiles(
        _ supportedFiles: [URL],
        toFolder folderPath: String,
        existingHashes: Set<String> = [],
        existingBookIDs: Set<UUID> = [],
        progress: ((ZipImportProgress) -> Void)? = nil,
        isCancelled: ImportCancellationCheck = { false },
        checksum: (URL) throws -> String = { try importHash(of: $0) },
        importer: (URL, String, String?, ImportStepObserver?) throws -> ImportedBook = { url, folder, known, observer in
            try importFileWithReport(from: url, checksum: known, toFolder: folder, observer: observer)
        }
    ) -> ZipImportResult {
        let total = supportedFiles.count
        var books: [Book] = []
        var failures: [ZipImportFailure] = []
        var incompleteBooks: [ZipImportFailure] = []
        // The books skipped as duplicates, which the batch's end says when
        // it brings no new book (FR10).
        var skippedDuplicates = 0
        // Track hashes from this batch to avoid creating duplicate .tmbs
        // when the same file appears multiple times in a single zip
        var seenHashes = existingHashes
        // The books listed or imported so far, by ID, so that a package
        // naming one of them never becomes a second row of it.
        var seenBookIDs = existingBookIDs

        // The size each book is timed by, which the estimate of the time
        // left weighs it by, read once for those who listen (FR10).
        if let progress {
            progress(.foundBooks(sizes: supportedFiles.map(timedSize(of:))))
        }

        // Second pass: import each file, skipping duplicates
        for (index, fileURL) in supportedFiles.enumerated() {
            // A cancelled batch stops before its next book. Each book is
            // published or discarded by its own import, so nothing is staged.
            if isCancelled() {
                return ZipImportResult(
                    books: books,
                    failures: failures,
                    incompleteBooks: incompleteBooks,
                    cancellation: .afterBooks(completed: index, total: total),
                    skippedDuplicates: skippedDuplicates
                )
            }

            // Tells the overlay that this book, numbered from 1, began
            // `step` (FR10).
            let number = index + 1
            let beganStep = { (step: ImportStep) in
                progress?(.importingBook(number: number, total: total, book: fileURL.lastPathComponent, step: step))
            }

            // A TextMouth package is identified once, by its record or its
            // removal marker, which gives the checksum and the book the
            // duplicate check compares; its import takes the package so
            // identified. Any other book's hash is computed before creating
            // its .tmb to avoid orphaning on duplicate; a DAISY book in a
            // folder has its package's. The import is given it, so the
            // book's bytes are read once for it.
            let package: Result<TMBImportSource, Error>?
            let hash: String?
            if isTMBPackageFolder(fileURL) {
                beganStep(.checkingPackage)
                package = Result { try identifyTMBPackage(at: fileURL) }
                hash = try? package?.get().md5Hash
            } else {
                beganStep(.readingSource)
                package = nil
                hash = try? checksum(fileURL)
            }
            let isKnownChecksum = hash.map { seenHashes.contains($0) } ?? false
            let isListedBook = (try? package?.get().bookID).map { seenBookIDs.contains($0) } ?? false
            if isKnownChecksum || isListedBook {
                skippedDuplicates += 1
                progress?(.importing(done: number, total: total, skippedDuplicate: true))
                continue
            }

            do {
                // Each step the import begins on the book's package is told
                // as it begins.
                let observer: ImportStepObserver = { step, _ in beganStep(step) }
                let imported: ImportedBook
                if let package {
                    // A package that could not be identified throws here,
                    // and is listed among the failures by its name.
                    imported = try importTMBPackage(try package.get(), observer: observer)
                } else {
                    imported = try importer(fileURL, folderPath, hash, observer)
                }
                seenHashes.insert(imported.book.md5Hash)
                seenBookIDs.insert(imported.book.id)
                books.append(imported.book)
                if !imported.report.isComplete {
                    // A PDF whose pictures OCR could not read is missing
                    // pages; any other incomplete book is missing chapters.
                    incompleteBooks.append(
                        ZipImportFailure(
                            fileName: fileURL.lastPathComponent,
                            message: imported.report.message,
                            missing: imported.report.pdf?.isComplete == false ? .pages : .chapters
                        )
                    )
                }
            } catch is ImportCancelled {
                // The reader cancelled while this book converted (a textutil
                // child was killed): the batch stops here as it does between
                // books, and this book, staged and removed, is no failure.
                return ZipImportResult(
                    books: books,
                    failures: failures,
                    incompleteBooks: incompleteBooks,
                    cancellation: .afterBooks(completed: index, total: total),
                    skippedDuplicates: skippedDuplicates
                )
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
            progress?(.importing(done: number, total: total))
        }

        return ZipImportResult(
            books: books,
            failures: failures,
            incompleteBooks: incompleteBooks,
            skippedDuplicates: skippedDuplicates
        )
    }

    /// Delete a book's entire .tmb package.
    /// Respects the "Move to Trash" setting — uses Trash when enabled,
    /// permanent deletion otherwise.
    @MainActor
    static func deleteBookPackage(_ book: Book) throws {
        let tmbDir = try managedPackageURLForDeletion(book)
        try removeItemRespectingTrashSetting(at: tmbDir)
    }

    /// Whether `book`'s row names a package the library manages, by its
    /// spelling alone, before anything on disk is looked at: a package name
    /// that is a single path component ending in ".tmb", in a library folder
    /// path without traversal (`BookFolder.isValidLibraryPath(_:)`).
    ///
    /// A row failing it must never have its package deleted or moved: a
    /// missing package name (a row without that key reads as "") makes the
    /// "package" the row's whole folder, and a folder path holding ".." can
    /// make it every folder of the library, or the data directory itself.
    /// The deletion guard (`managedPackageURLForDeletion(_:libraryDirectory:)`)
    /// and the first launch's move of downloads into their feeds' folders
    /// (FR11, `LibraryViewModel.downloadsToMoveIntoTheirFeeds(records:)`)
    /// both refuse such a row.
    static func namesManagedPackage(_ book: Book) -> Bool {
        isManagedPackageName(book.tmbDirectoryName) && BookFolder.isValidLibraryPath(book.folderPath)
    }

    /// Whether `name` names a package as the library manages one, by its
    /// spelling alone: a single path component, not empty, ending in
    /// ".tmb", so it can never name the folder it is in, or one above it.
    /// A library book's package (`namesManagedPackage(_:)`) and a feed
    /// item's (`FeedItemPackage.isPackageName(_:)`) are both named so.
    static func isManagedPackageName(_ name: String) -> Bool {
        !name.isEmpty
            && (name as NSString).lastPathComponent == name
            && name.lowercased().hasSuffix(".tmb")
    }

    /// Whether the item at `url` is a symbolic link, which a deletion must
    /// never take for the package it points to: a link in a library folder,
    /// or in a feed's, could lead to another book's package, or anywhere.
    /// An item whose metadata cannot be read counts as none.
    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// Validate the deletion target independently of filesystem mutation. A
    /// missing legacy package name otherwise resolves to the entire folder.
    /// Resolve symlinks as well as dot components before checking containment.
    static func managedPackageURLForDeletion(
        _ book: Book,
        libraryDirectory: URL = TextMouthPaths.libraryDir
    ) throws -> URL {
        let name = book.tmbDirectoryName
        guard namesManagedPackage(book) else {
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
        guard !isSymbolicLink(requestedPackage) else {
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

    /// Moves the item at `url` to the Trash, whatever the Trash setting says:
    /// the removal for what no one chose to delete (a duplicate's new copy
    /// whose question was never answered), and the default of
    /// `removeItemRespectingTrashSetting`.
    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Remove an item from disk, using Trash if the setting is enabled.
    /// A Trash failure is surfaced to the caller and never converted into an
    /// unconfirmed permanent deletion.
    @MainActor
    static func removeItemRespectingTrashSetting(
        at url: URL,
        trashItem: (URL) throws -> Void = FileImportService.moveToTrash,
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

    /// Whether `url` names a TextMouth book package: its extension is .tmb,
    /// in any case. Open Book… and Finder open such a package as the book
    /// it holds rather than import it as a file
    /// (`LibraryViewModel.openTMBPackage(from:)`), and no import's original
    /// that lies inside one is ever deleted (`reasonToKeepOriginal(at:)`).
    static func isBookPackage(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "tmb"
    }

    /// Why the item at `url`, an import's original, is never deleted, in the
    /// words of the log line that says so; nil when it may be deleted.
    ///
    /// - A folder, or a symbolic link to one: a folder import (a DAISY book
    ///   kept as loose files, a folder of audio tracks) leaves files the
    ///   import did not copy in it, such as a cover, lyrics, or other books.
    /// - A file inside a book package: a book's own file, or a track of its
    ///   audio, opened from inside the package in Finder (Show Package
    ///   Contents), which its deletion would take from that book.
    /// - A file inside `dataDirectory`, the data directory, which holds the
    ///   library and everything else TextMouth keeps.
    ///
    /// Where the item lies is read with symbolic links resolved, on the item
    /// and on the data directory alike (`lies(_:inside:)`), so neither a
    /// link nor a folder whose name merely begins like the data
    /// directory's (Library2 beside Library) can mislead it.
    static func reasonToKeepOriginal(at url: URL, dataDirectory: URL = TextMouthPaths.root) -> String? {
        // `fileExists(atPath:isDirectory:)` follows a symbolic link, so a link
        // to a folder counts as a folder, which is wanted.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return "is a folder, which an import never deletes"
        }
        let item = url.resolvingSymlinksInPath()
        // The names of the folders that hold the item, its own name left
        // out: a package is known by its name alone, as Open Book… and
        // Finder know it.
        let folderNames = item.pathComponents.dropLast()
        if folderNames.contains(where: { isBookPackage(URL(fileURLWithPath: $0, isDirectory: true)) }) {
            return "is inside a book package, whose files an import never deletes"
        }
        if lies(item, inside: dataDirectory.resolvingSymlinksInPath()) {
            return "is inside the data directory, whose files an import never deletes"
        }
        return nil
    }

    /// Whether `item` lies inside `folder`, somewhere below it, compared path
    /// component by path component, so a folder whose name merely begins
    /// with `folder`'s (Library2 beside Library) is not taken for it, and
    /// without regard to case, as the Mac's volumes compare names: on a
    /// volume that tells case apart, the worst a mismatch can do is keep a
    /// file. Neither path is resolved here.
    private static func lies(_ item: URL, inside folder: URL) -> Bool {
        let itemPath = item.pathComponents.map { $0.lowercased() }
        let folderPath = folder.pathComponents.map { $0.lowercased() }
        return itemPath.count > folderPath.count && itemPath.starts(with: folderPath)
    }

    /// Delete the original source file after import (if the user chose that
    /// option), to the Trash or permanently as "Move to Trash instead of
    /// deleting" chooses, like every other deletion. Throws when the file
    /// could not be removed, so the caller can say so (TODO S09); a file
    /// that is already gone counts as removed.
    ///
    /// Some originals are never deleted, whatever the caller decided
    /// (`reasonToKeepOriginal(at:)`): a folder, which a folder import
    /// leaves holding files it did not copy, and any file inside a book
    /// package or inside the data directory, which belongs to a book or to
    /// TextMouth. The library already never offers the deletion of a
    /// folder (`ImportedBook.mayDeleteOriginal`); this refuses one too, so
    /// a caller that is ever given a folder (or a symbolic link to one)
    /// still cannot remove it. A refusal removes nothing, sends nothing to
    /// the Trash, and does not throw, since nothing failed: it writes one
    /// log line naming the item, never its path, and saying why.
    @MainActor
    static func deleteOriginalFile(at url: URL) throws {
        if let reason = reasonToKeepOriginal(at: url) {
            DiagnosticLog.event(.import, "ORIGINAL_KEPT: \(url.lastPathComponent): \(reason)")
            return
        }
        try removeItemRespectingTrashSetting(at: url)
    }

    /// Compute MD5 hash of a file (streaming for large files), reading it a
    /// mebibyte at a time with `FileHandle.read(upToCount:)`, which throws
    /// a Swift error when a read fails (see
    /// `md5Hash(of:readingChunksWith:)`).
    static func md5Hash(of url: URL) throws -> String {
        try md5Hash(of: url, readingChunksWith: { handle in try handle.read(upToCount: 1024 * 1024) })
    }

    /// The MD5 digest of the file at `url`, as 32 lowercase hexadecimal
    /// digits, from the chunks `readChunk` reads from the open file in turn
    /// until it gives nil or an empty chunk (the end of the file).
    /// `md5Hash(of:)` reads with `FileHandle.read(upToCount:)`; a test
    /// stands in for it to make a read fail.
    ///
    /// Every import, ZIP batch, folder, and text-cache fingerprint hashes
    /// through here, so a read must fail as a Swift error: FileHandle's
    /// legacy `readData(ofLength:)` raises an Objective-C exception, which
    /// Swift cannot catch and which ends TextMouth, when a disk is
    /// unplugged, a network share drops, or a cloud download fails
    /// mid-read. A thrown error reaches the import's own report instead.
    /// - Throws: `ContentFingerprintError.notARegularFile` for a folder (an
    ///   RTFD is one), which is never opened; the error opening the file;
    ///   or the first error `readChunk` throws.
    static func md5Hash(of url: URL, readingChunksWith readChunk: (FileHandle) throws -> Data?) throws -> String {
        // A folder (an RTFD is one) is refused with its own error before it
        // is opened.
        guard !isFolder(url) else { throw ContentFingerprintError.notARegularFile }
        let handle = try FileHandle(forReadingFrom: url)
        // A file only read from loses nothing if closing it fails, and the
        // legacy `closeFile()` would raise an exception there too.
        defer { try? handle.close() }

        var hasher = Insecure.MD5()
        // Each read runs in its own autorelease pool, so what it autoreleases
        // is freed before the next read and a large file never fills memory.
        while let chunk = try autoreleasepool(invoking: { try readChunk(handle) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }

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
    /// bookInfo.json is on disk. The book is its audio alone, so what this
    /// returns says the import took only part of its original
    /// (`ImportedBook.tookOnlyPartOfOriginal`): the archive, the only copy
    /// of the book's text, is never deleted after the import.
    ///
    /// The archive is admitted to a budget (`ArchiveLimits`, TODO I05) before
    /// any audio is converted, and every file the converter reads is held to
    /// the size the archive records for it. The converter carries on past an
    /// audio file it cannot copy, so a file refused for its size is kept on
    /// the budget and fails the import once conversion ends.
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
            let archive = try ArchiveExtractor.open(zipURL)
            let budget = ArchiveBudget()
            let provider = ArchiveFileProvider(archive: archive, budget: budget)
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
            try budget.admit(ArchiveInspection(of: archive), extractingInto: audioDirectory)
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
            if let violation = budget.violation {
                throw violation
            }
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
            var imported = try publishReadableBook(staged, from: staging, run: &run)
            // Only the audio and its manifest were staged. Text the package
            // leaves out, or other books the archive holds, stay in the
            // archive, which is then their only copy, so it is never
            // deleted. An audio-only talking book in an archive of its own
            // leaves nothing behind, so the preference stands.
            let leftovers = daisyArchiveLeftovers(
                of: ArchiveFileProvider(archive: archive), archiveName: zipURL.lastPathComponent
            )
            imported.tookOnlyPartOfOriginal = !leftovers.isEmpty
            imported.archiveLeftovers = leftovers
            return imported
        }
    }

    /// The most SMIL files and XML files `daisyArchiveLeftovers` reads
    /// looking for text: an archive is untrusted, and one text file settles
    /// the question.
    private static let leftoverScanLimit = 2_000

    /// What the audio import of a DAISY archive leaves in the archive that
    /// `provider` reads: whether the DAISY folder holds text the audio book
    /// lacks (a DTBook, or a text document a SMIL file points to, other than
    /// the navigation file, which a talking book's SMIL files point to for
    /// its headings), and how many other books lie outside that folder: DAISY
    /// books in folders of their own, and files of the formats TextMouth
    /// imports (audio not counted, since loose tracks are no book).
    ///
    /// The DAISY folder is the one holding the package or navigation file
    /// (`DAISYParser.packageFolders(inArchivePaths:)`), the archive's top
    /// level when the book lies there. Hidden entries and `__MACOSX` hold
    /// nothing. Nothing is extracted: files are read as the parser reads
    /// them, within its bounds, and a file that cannot be read counts as no
    /// text.
    static func daisyArchiveLeftovers(of provider: DAISYFileProvider, archiveName: String) -> DAISYArchiveLeftovers {
        let paths = provider.listFiles().filter { path in
            !path.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__MACOSX" }
        }
        let folders = DAISYParser.packageFolders(inArchivePaths: paths)
        let bookFolder = folders.contains("") ? "" : (folders.sorted().first ?? "")
        /// Whether `path` lies in `folder`, "" being the whole archive.
        func lies(_ path: String, in folder: String) -> Bool {
            folder.isEmpty || path.hasPrefix(folder + "/")
        }
        let inBook = paths.filter { lies($0, in: bookFolder) }

        // Other DAISY books in folders of their own count once each, and
        // every other file of a book format counts as one book, unless it
        // lies in a folder that is a DAISY book itself.
        let otherFolders = folders.subtracting([bookFolder])
        var otherBooks = bookFolder.isEmpty ? 0 : otherFolders.count
        if !bookFolder.isEmpty {
            for path in paths where !lies(path, in: bookFolder) && !otherFolders.contains(where: { lies(path, in: $0) }) {
                if let format = BookFormat.detect(from: URL(fileURLWithPath: path)), !format.isAudio {
                    otherBooks += 1
                }
            }
        }
        return DAISYArchiveLeftovers(
            archiveName: archiveName,
            holdsText: holdsText(among: inBook, provider: provider),
            otherBookCount: otherBooks
        )
    }

    /// Whether the DAISY book whose files are `paths` has text outside its
    /// navigation: a file with a DTBook root, or a document that a SMIL
    /// file's text element names and the book holds.
    private static func holdsText(among paths: [String], provider: DAISYFileProvider) -> Bool {
        for path in paths.filter({ $0.lowercased().hasSuffix(".xml") }).prefix(leftoverScanLimit) {
            if let data = try? provider.readFile(at: path), XMLDocumentSniffer.rootKind(of: data) == .dtbook {
                return true
            }
        }
        let held = Set(paths.map { $0.lowercased() })
        for smil in paths.filter({ $0.lowercased().hasSuffix(".smil") }).prefix(leftoverScanLimit) {
            guard let data = try? provider.readFile(at: smil) else { continue }
            for source in SMILTextSources.scan(data) {
                let target = ParserUtilities.resolvedPackagePath(source, relativeTo: smil, preserveFragment: false)
                let name = (target as NSString).lastPathComponent
                if !target.isEmpty, !DAISYParser.isNCCFileName(name), held.contains(target.lowercased()) {
                    return true
                }
            }
        }
        return false
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
    /// bookInfo.json is on disk. The archive is extracted entry by entry
    /// within a budget (`ArchiveLimits`, TODO I05): one past the limits is
    /// refused before anything is written, and one whose sizes lie stops at
    /// its first excess byte. A manifest.json in the archive is checked
    /// before the book is read by it, and one with a mistake fails the
    /// import at `.readingManifest`, saying what is wrong and where
    /// (`AudioManifestCheck`).
    /// - Parameter observer: told as each step on the staged package begins.
    /// - Throws: an `ImportFailure` naming the archive and the step that
    ///   failed; whatever was staged is removed first.
    static func importAudioZipWithReport(
        from zipURL: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil
    ) throws -> ImportedBook {
        try importAudioZipWithReport(from: zipURL, toFolder: folderPath, observer: observer, extraction: nil)
    }

    /// Imports the ZIP of audio files at `zipURL` as one audio book, as
    /// `importAudioZipWithReport(from:toFolder:observer:)` does, telling
    /// `extraction` how far the archive's extraction has got, its entries
    /// and bytes, as the extractor counts them (FR10): the import overlay
    /// shows them on the book's line, so a large audiobook's archive is
    /// seen to move while it is extracted.
    static func importAudioZipWithReport(
        from zipURL: URL,
        toFolder folderPath: String = "",
        observer: ImportStepObserver? = nil,
        extraction: ((ArchiveExtractionProgress) -> Void)?
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
                author: Book.unknownAuthor,
                dateAdded: dateAdded,
                bookID: bookID,
                folderPath: folderPath
            ))
            defer { staging.discard() }

            try run.begin(.extractingArchive, in: staging.directory)
            let audioDirectory = try makeAudioDirectory(in: staging)
            try ArchiveExtractor.extract(
                archiveAt: zipURL,
                into: audioDirectory,
                budget: ArchiveBudget(),
                progress: extraction
            )

            // A transcript file in the archive lies beside its track.
            return try publishTracks(
                titled: zipName,
                in: audioDirectory,
                of: staging,
                id: bookID,
                md5Hash: hash,
                folderPath: folderPath,
                dateAdded: dateAdded,
                source: zipURL,
                pairingIn: audioDirectory,
                run: &run
            )
        }
    }

    /// The last steps of every import of a folder of tracks, from a ZIP or
    /// from a folder (FR17), once the tracks lie in `audioDirectory` of
    /// `staging`: a manifest beside them, or inside their one folder, found
    /// where the book's reading finds it, can name the book (`title`
    /// otherwise) and its author, and arranges its tracks. One with a
    /// mistake stops the import here, before the book is read, saying what
    /// is wrong and where (`AudioManifestCheck`). Reading the audio uses the
    /// reader's discovery rules (wrapper folders count; Finder metadata
    /// named like audio does not), so a folder with no playable track fails
    /// there, and the book is published once it reads as the reader will.
    /// A WebVTT or SubRip file named as a track is, found in
    /// `transcriptFolder`, the folder the tracks' paths lead from (the
    /// archive's extraction, the folder chosen, or the playlist's own
    /// folder), becomes the book's transcript (`TranscriptPairing.inFolder`,
    /// FMT23).
    private static func publishTracks(
        titled title: String,
        in audioDirectory: URL,
        of staging: ImportStaging,
        id bookID: UUID,
        md5Hash hash: String,
        folderPath: String,
        dateAdded: Date,
        source: URL,
        pairingIn transcriptFolder: URL,
        run: inout ImportRun
    ) throws -> ImportedBook {
        var title = title
        var author = Book.unknownAuthor
        if let location = AudioManifestLocation.find(in: audioDirectory) {
            try run.begin(.readingManifest, in: staging.directory)
            let manifest = try AudioManifestCheck.checkedManifest(at: location, audioFolder: audioDirectory, scan: .importing)
            // A blank title or author falls back as a missing one does.
            if let manifestTitle = manifest.bookTitle { title = manifestTitle }
            if let manifestAuthor = manifest.bookAuthor { author = manifestAuthor }
        }
        let staged = stagedAudioBook(
            id: bookID,
            title: title,
            author: author,
            audioDirectory: audioDirectory,
            md5Hash: hash,
            folderPath: folderPath,
            dateAdded: dateAdded,
            staging: staging,
            source: source
        )
        return try publishReadableBook(staged, from: staging, run: &run, pairingTranscripts: .inFolder(transcriptFolder))
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
        // Office Open XML Word documents. Legacy binary .doc and .dot files
        // are not ZIP-based DOCX documents: they go to textutil (see below),
        // never to DOCXParser.
        if let docx = UTType("org.openxmlformats.wordprocessingml.document") {
            types.append(docx)
        }
        // Word templates and macro-enabled documents are the same package,
        // read by the same reader (macro projects are never opened).
        for identifier in [
            "org.openxmlformats.wordprocessingml.template",
            "org.openxmlformats.wordprocessingml.document.macroenabled",
            "org.openxmlformats.wordprocessingml.template.macroenabled"
        ] {
            if let type = UTType(identifier) {
                types.append(type)
            }
        }
        // Safari web archives, read as their main page (FMT03), and SSML
        // files, read as text (FMT07). macOS declares no SSML type; the app
        // imports one in Info.plist. `importedAs` returns that declared type
        // whether or not the system has registered it yet, so the panel
        // always offers .ssml.
        types.append(.webArchive)
        types.append(UTType(importedAs: "org.w3.ssml", conformingTo: .xml))
        // Kindle books (FMT42, FMT48): .mobi, .prc, .azw, and .azw3, for which macOS
        // declares no type; the app imports one in Info.plist.
        types.append(UTType(importedAs: "com.textmouth.mobi", conformingTo: .data))
        // Kindle KFX books (FMT52): .kfx, .kfx-zip, .azw8, and .kpf, the same.
        types.append(UTType(importedAs: "com.textmouth.kfx", conformingTo: .data))
        // Braille files (FMT20): BRF and BRL, which macOS declares no type
        // for, and PEF, which macOS takes for a Pentax raw photo by its
        // extension; the import tells them apart by their contents.
        types.append(UTType(importedAs: "com.textmouth.brf", conformingTo: .plainText))
        types.append(UTType(importedAs: "com.textmouth.brl", conformingTo: .plainText))
        let pefType = UTType(importedAs: "org.daisy.pef", conformingTo: .xml)
        types.append(pefType)
        // Whatever type the system gives a .pef, so one can be chosen.
        if let systemPEF = UTType(filenameExtension: "pef"), systemPEF != pefType {
            types.append(systemPEF)
        }
        // Rich text, read by textutil (FMT13).
        types.append(.rtf)
        // Rich text with attachments: a package, which the panel shows as a
        // single file.
        types.append(.rtfd)
        // Word 97-2003 documents and templates, read by textutil.
        types.append(contentsOf: ["com.microsoft.word.doc", "com.microsoft.word.dot"].compactMap { UTType($0) })
        // OpenDocument text documents and templates, read by textutil.
        types.append(contentsOf: [
            "org.oasis-open.opendocument.text",
            "org.oasis-open.opendocument.text-template",
        ].compactMap { UTType($0) })
        // XML files: Word 2003 XML (WordML) documents and DTBook files,
        // which the import tells apart by their root element
        // (`XMLDocumentSniffer`); any other XML file is refused by name.
        types.append(.xml)
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
            UTType("org.xiph.ogg-audio"),        // ogg, oga, opus
        ].compactMap { $0 })
        // The formats macOS decodes that the import converts (FMT09), by
        // their extensions' system types where they have one.
        types.append(contentsOf: ImportAudioConverter.coreAudioExtensions.sorted().compactMap {
            UTType(filenameExtension: $0)
        })
        // Video, imported as an audiobook whose sound alone plays (FR03).
        types.append(.mpeg4Movie)                // mp4
        types.append(.quickTimeMovie)            // mov
        if let m4v = UTType("com.apple.m4v-video") {
            types.append(m4v)
        }
        // M3U and M3U8 playlists, imported as an audiobook of the files they
        // list (FMT10).
        if let playlist = UTType("public.m3u-playlist") {
            types.append(playlist)
        }
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
    ///
    /// A shared package any of whose items is in the cloud is left as it is
    /// (FR02): the copy would download it, and its record, which decides
    /// which row keeps the package, may not be read without downloading
    /// either. A record whose read is refused is the same: guessing its
    /// owner would separate the wrong row and invalidate the record. Every
    /// row sharing such a package keeps its row as it is, counted in
    /// `skips`, until all of the package is on this Mac. `access` is how the
    /// repair reaches the packages' files.
    @discardableResult
    static func separateSharedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir,
        access: MaintenanceFileAccess = .live,
        skips: CloudSkips? = nil
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
            guard access.presence(of: sharedPackage) != .absent else { continue }

            // The package's owner, as its record names it; nil when the record
            // cannot be read for a reason other than the cloud.
            let storedBookID: UUID?
            do {
                guard access.itemInCloud(sharedPackage) == nil else {
                    throw MaintenanceFileAccess.refusal(of: sharedPackage)
                }
                storedBookID = try access.read(TextMouthPaths.bookInfoPath(in: sharedPackage)) {
                    try BookInfo.load(from: sharedPackage)
                }.metadata.bookID
            } catch where DatalessFiles.isDownloadRefusal(error) {
                for index in indices {
                    skips?.record(library.books[index])
                }
                continue
            } catch {
                storedBookID = nil
            }
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
                switch access.presence(of: destination) {
                case .absent:
                    break
                case .present:
                    continue
                case .inCloud:
                    skips?.record(book)
                    continue
                }

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
                    if DatalessFiles.isDownloadRefusal(error) {
                        // A file went to the cloud while the package was
                        // copied: the book waits for it, as it is.
                        skips?.record(book)
                    } else {
                        print("Failed to separate shared package for \(book.title): \(error)")
                    }
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
    ///
    /// Only a package found missing from its folder is moved (FR02): a check
    /// that met a dataless folder decides nothing, and a package that is
    /// itself in the cloud stays where it is. Such a book keeps its row as it
    /// is, counted in `skips`. `access` is how the repair reaches the
    /// packages.
    @discardableResult
    static func relocateMisplacedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir,
        access: MaintenanceFileAccess = .live,
        skips: CloudSkips? = nil
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

            // If the .tmb is already in the right place, nothing to do; and
            // nothing is done when only the cloud knows whether it is.
            switch access.presence(of: expectedDir) {
            case .absent:
                break
            case .present:
                continue
            case .inCloud:
                skips?.record(book)
                continue
            }

            // If the .tmb is at root, move it to the correct folder, unless
            // it is itself in the cloud.
            switch access.presence(of: rootDir) {
            case .absent:
                continue
            case .inCloud:
                skips?.record(book)
                continue
            case .present:
                guard !access.isDataless(rootDir) else {
                    skips?.record(book)
                    continue
                }
            }

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

    // MARK: - Delete Everything and Kept Rows (stable020 review, finding 1)

    /// Deletes the library folder at `folderPath`, whose directory is
    /// `folderURL`, and everything in it, as Delete Folder's Delete
    /// Everything does, except what the kept rows of library.json own (V03),
    /// books a newer TextMouth added: a package `kept` owns stays where it
    /// is, and so does every folder holding one at any depth, or named by
    /// `keptFolders` (the kept rows' folders in this tree,
    /// `Library.keptRowFolders(inFolderTree:)`), the folder itself included.
    ///
    /// A folder holding nothing kept goes as one item, as the whole folder
    /// always went. When something stays, each other item beside it goes on
    /// its own: a subfolder holding nothing kept, a package no kept row
    /// owns, or a file. Every item goes through `removeItem`, by default to
    /// the Trash or permanently as the preference chooses
    /// (`removeItemRespectingTrashSetting(at:trashItem:removeItem:)`); a test
    /// passes its own. A hidden item, such as Finder's .DS_Store, stays in a
    /// folder that stays, and a symbolic link is removed as a link, never
    /// followed.
    ///
    /// - Returns: The paths, relative to the library, of the folders that
    ///   stay, the folder itself first; empty when the whole folder went.
    ///   Each is spelled as on disk, or as its kept row spells it when no
    ///   directory of it is on disk, its package missing.
    /// - Throws: the first error `removeItem` throws; what went before it
    ///   stays gone.
    @MainActor
    static func removeLibraryFolder(
        at folderURL: URL,
        folderPath: String,
        keepingPackagesOf kept: KeptRowPackages,
        keptFolders: [String],
        removeItem: ((URL) throws -> Void)? = nil
    ) throws -> [String] {
        let removeItem = removeItem ?? { item in
            try removeItemRespectingTrashSetting(at: item)
        }
        // Folders are compared as `KeptRowPackages` compares them.
        let equivalence = FolderPathEquivalence.caseInsensitive
        let keptFolderKeys = keptFolders.map { equivalence.comparisonKey(for: $0) }

        /// The items in `directory`, hidden ones included, each with whether
        /// it is a directory itself (a symbolic link to one is not).
        func items(in directory: URL) -> [(url: URL, isDirectory: Bool)] {
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(keys)
            )) ?? []
            return contents.map { item in
                let values = try? item.resourceValues(forKeys: keys)
                return (url: item, isDirectory: values?.isDirectory == true && values?.isSymbolicLink != true)
            }
        }

        /// Whether anything in the folder `directory`, at `path`, stays: it
        /// is a kept row's folder or holds one, or a package in it, at any
        /// depth, is one a kept row owns.
        func holdsSomethingKept(_ directory: URL, at path: String) -> Bool {
            let key = equivalence.comparisonKey(for: path)
            if keptFolderKeys.contains(where: { $0 == key || $0.hasPrefix(key + "/") }) { return true }
            return items(in: directory).contains { item in
                guard item.isDirectory else { return false }
                let name = item.url.lastPathComponent
                return isManagedPackageName(name)
                    ? kept.owns(folderPath: path, tmbDirectoryName: name)
                    : holdsSomethingKept(item.url, at: path + "/" + name)
            }
        }

        // A library without kept rows, the usual one, is never walked.
        guard !(kept.isEmpty && keptFolders.isEmpty), holdsSomethingKept(folderURL, at: folderPath) else {
            try removeItem(folderURL)
            return []
        }
        // Each folder that stays, from this one down, loses every item that
        // does not: a kept package and a folder holding something kept stay,
        // and the latter is pruned in turn.
        var stayed: [String] = []
        var foldersToPrune: [(url: URL, path: String)] = [(url: folderURL, path: folderPath)]
        while let folder = foldersToPrune.popLast() {
            stayed.append(folder.path)
            for item in items(in: folder.url) where !item.url.lastPathComponent.hasPrefix(".") {
                let name = item.url.lastPathComponent
                let path = folder.path + "/" + name
                if item.isDirectory {
                    if isManagedPackageName(name) {
                        if kept.owns(folderPath: folder.path, tmbDirectoryName: name) { continue }
                    } else if holdsSomethingKept(item.url, at: path) {
                        foldersToPrune.append((url: item.url, path: path))
                        continue
                    }
                }
                try removeItem(item.url)
            }
        }
        // A kept row's folder stays even with no directory on disk (its
        // package is missing), as do the folders between it and this one:
        // its row still names it.
        for keptFolder in keptFolders {
            var path = keptFolder
            while equivalence.isPath(path, inSubtreeOf: folderPath) {
                if !stayed.contains(where: { equivalence.areEquivalent($0, path) }) {
                    stayed.append(path)
                }
                guard let slash = path.lastIndex(of: "/") else { break }
                path = String(path[..<slash])
            }
        }
        return stayed
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
    ///
    /// A package a kept row of library.json owns (`Library.keptRowPackages`,
    /// V03), a book a later TextMouth wrote that this one does not show, is
    /// no orphan either: it is passed over before its record is read, so it
    /// is never adopted as a second book of the same package.
    ///
    /// Nor is a duplicate's new copy whose question waits for the listener's
    /// answer, or waited when a quit or a crash ended the session that asked
    /// it: its package holds a `DuplicateQuestionMarker`. It is passed over
    /// before its record is read, whoever runs the walk, so it never becomes
    /// a book the listener did not choose to keep, and it is recorded in
    /// `unanswered` when one is given: the launch's repair gives one, and
    /// discards those no question waits for any more
    /// (`LibraryViewModel.adoptOrphanedPackages`). A walk run while a question
    /// waits (a rebuild, a recovery) gives none, and leaves every such
    /// package as it is. A package the library lists, or a kept row owns, is
    /// never looked at for the marker: it is a book.
    ///
    /// An orphan whose record names a book the library already lists, under
    /// that book's ID, is another copy of it: the old copy Replace Existing
    /// sent to the Trash names its replacement's ID once Finder puts it
    /// back, and an old package a stop or a failed removal left beside its
    /// replacement names it too (ST04). It is left as it is, unadopted and
    /// unwritten, with one ORPHAN_ID_LISTED line, so no two rows ever share
    /// an ID and no record is rewritten on a guess: during an index
    /// recovery, which writes nothing, and in a cloud library whose
    /// library.json, listing the book at that very package, may arrive
    /// after the package does. Of two orphans naming one book that no row
    /// listed before the walk, as an index rebuilt from the packages finds
    /// an old copy put back beside its replacement, the one whose record was
    /// written later becomes the book, whichever the folder lists first: the
    /// replacement, whose record Replace Existing wrote after the old copy's
    /// last one. The other is left as it is, its record never rewritten.
    ///
    /// The walk and every check run with dataless files left in the cloud
    /// (FR02). A folder that cannot be listed without downloading is passed
    /// over, and a package whose folder, record, removal marker, or book file
    /// is in the cloud is neither adopted nor rewritten: it is counted in
    /// `skips`, and adopted at a launch that finds it on this Mac. A package
    /// holding a duplicate question's marker is likewise counted, and not
    /// recorded in `unanswered`, while its folder or the marker is in the
    /// cloud, where another Mac sharing the library may still be asking its
    /// question. `access` is how the repair reaches the packages' files.
    @discardableResult
    static func adoptOrphanedTMBPackages(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir,
        access: MaintenanceFileAccess = .live,
        skips: CloudSkips? = nil,
        unanswered: UnansweredDuplicates? = nil
    ) -> Int {
        let fm = FileManager.default
        let libraryDir = libraryDirectory

        // Collect all .tmb directory names currently tracked in the library
        let knownTMBNames = Set(library.books.map { $0.tmbDirectoryName })
        // The packages of the rows kept unshown (V03), owned by those rows.
        let keptPackages = library.keptRowPackages

        return DatalessFiles.withoutDownloading { () -> Int in
            // Walk the library directory tree to find all .tmb packages on disk
            var adopted = 0
            // The books this walk adopted, by ID: the package each came from
            // and when its record was written.
            var adoptedHere: [UUID: (package: String, recordWritten: Int64)] = [:]
            // The records given their folder path once the walk ends, by ID:
            // only the package each book is adopted from in the end, so a
            // package another one took the place of is never written.
            var folderPathFixes: [UUID: Book] = [:]
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

                // Skip if already tracked in the library
                if knownTMBNames.contains(url.lastPathComponent) { continue }

                // Skip if a kept row owns it: adopting it would show the
                // book twice once a newer TextMouth reads that row.
                if !keptPackages.isEmpty, keptPackages.owns(
                    folderPath: libraryFolderPath(ofPackageAt: url, libraryDirectory: libraryDir),
                    tmbDirectoryName: url.lastPathComponent
                ) { continue }

                // Skip a duplicate's new copy whose question waits, or was
                // never answered: adopting it would keep a copy the listener
                // never chose to keep. The launch's repair discards it once no
                // question waits for it; one in the cloud decides nothing.
                if passesOverUnansweredDuplicate(at: url, access: access, skips: skips, unanswered: unanswered) {
                    continue
                }

                let orphan: (book: Book, recordedFolderPath: String)
                do {
                    guard let found = try orphanedBook(in: url, libraryDirectory: libraryDir, access: access) else {
                        continue
                    }
                    orphan = found
                } catch {
                    // Only a refusal: part of the package is in the cloud.
                    skips?.record(package: url)
                    continue
                }

                // A second copy of a book the library lists by this ID is
                // left as it is (ST04). Of two packages naming a book only
                // this walk adopted, the one whose record was written later
                // is the book, whichever the folder lists first, as when an
                // index rebuilt from the packages finds Replace Existing's
                // old copy put back beside its replacement.
                if let row = library.books.firstIndex(where: { $0.id == orphan.book.id }) {
                    let written = recordWrittenTime(inPackageAt: url)
                    var left = url.lastPathComponent
                    if let earlier = adoptedHere[orphan.book.id], written > earlier.recordWritten {
                        left = earlier.package
                        library.books[row] = orphan.book
                        adoptedHere[orphan.book.id] = (package: url.lastPathComponent, recordWritten: written)
                        let needsFix = orphan.recordedFolderPath != orphan.book.folderPath
                        folderPathFixes[orphan.book.id] = needsFix ? orphan.book : nil
                    }
                    DiagnosticLog.event(
                        .storage,
                        "ORPHAN_ID_LISTED: \(left): its record names a book the library lists "
                            + "in another package, so it was left as it is"
                    )
                    continue
                }

                // addBook guards against duplicate hashes — only truly new books get added
                let countBefore = library.books.count
                library.addBook(orphan.book)
                if library.books.count > countBefore {
                    adopted += 1
                    adoptedHere[orphan.book.id] = (
                        package: url.lastPathComponent,
                        recordWritten: recordWrittenTime(inPackageAt: url)
                    )

                    // Update the bookInfo.json folderPath if it was empty but the .tmb
                    // lives inside a subfolder (common with orphans from zip imports)
                    if orphan.recordedFolderPath != orphan.book.folderPath {
                        folderPathFixes[orphan.book.id] = orphan.book
                    }
                }
            }
            for book in folderPathFixes.values {
                try? book.saveBookInfoThrowing()
            }

            if adopted > 0 {
                print("Adopted \(adopted) orphaned .tmb package(s) into library")
            }
            return adopted
        }
    }

    /// Whether the adoption passes over the package at `url` because it
    /// holds a duplicate question's marker (`DuplicateQuestionMarker`): a
    /// new copy whose question waits, or was never answered. Such a package
    /// is recorded in `unanswered`, for the launch's repair to discard, only
    /// when its folder and the marker are both on this Mac. When either is in
    /// the cloud, another Mac sharing the library may still be asking that
    /// question, so it is counted in `skips` instead and decided at a launch
    /// that finds it here (FR02); a marker that cannot be looked for without
    /// a download counts so too, as the record would.
    private static func passesOverUnansweredDuplicate(
        at url: URL,
        access: MaintenanceFileAccess,
        skips: CloudSkips?,
        unanswered: UnansweredDuplicates?
    ) -> Bool {
        let marker = DuplicateQuestionMarker.url(in: url)
        guard access.presence(of: marker) != .absent else { return false }
        if access.isInCloud(url) || access.isInCloud(marker) {
            skips?.record(package: url)
        } else {
            unanswered?.record(url)
        }
        return true
    }

    /// When the record in the package at `url` was last written, in
    /// nanoseconds since 1970 (`FileStamp`); the earliest time there is when
    /// it cannot be examined.
    private static func recordWrittenTime(inPackageAt url: URL) -> Int64 {
        FileStamp(of: TextMouthPaths.bookInfoPath(in: url))?.modificationTimeNanoseconds ?? .min
    }

    /// The library folder the package at `url` is in, relative to
    /// `libraryDir`: "" at the top of the library, "Science Fiction/Author"
    /// for Library/Science Fiction/Author/Book.tmb. Symbolic links are
    /// resolved so /tmp and /private/tmp paths match consistently.
    private static func libraryFolderPath(ofPackageAt url: URL, libraryDirectory libraryDir: URL) -> String {
        let resolvedLibrary = libraryDir.resolvingSymlinksInPath().path
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return resolvedParent
            .replacingOccurrences(of: resolvedLibrary, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// The book the orphaned package at `url` holds, as its bookInfo.json
    /// describes it and placed in the library folder the package is in, with
    /// the folder path the record names; nil when it holds none to adopt: its
    /// record cannot be read, its book was taken out with Remove from Library
    /// Only, or it has no book file.
    /// - Throws: a download refusal (`DatalessFiles.isDownloadRefusal`) when
    ///   the package, its record, its removal marker, or its book file is in
    ///   the cloud (FR02), so nothing is decided about the package.
    private static func orphanedBook(
        in url: URL,
        libraryDirectory libraryDir: URL,
        access: MaintenanceFileAccess
    ) throws -> (book: Book, recordedFolderPath: String)? {
        let record = TextMouthPaths.bookInfoPath(in: url)
        let marker = TextMouthPaths.removedFromLibraryMarkerPath(in: url)
        if let inCloud = [url, record, marker].first(where: access.isInCloud) {
            throw MaintenanceFileAccess.refusal(of: inCloud)
        }

        // Try to load bookInfo.json from the orphaned .tmb
        let info: BookInfo
        do {
            info = try access.read(record) { try BookInfo.load(from: url) }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            return nil
        }

        // The user removed this book from the library; it stays out.
        if RemovedFromLibraryMarker.retires(info.metadata.bookID, in: url) { return nil }

        // Find the actual book file inside the .tmb: the one its record
        // names, since a DAISY book's package holds many files (TODO
        // I02); for a record naming none there, the first entry that is
        // not metadata or cache (a removal marker naming some other book
        // included)
        let tmbContents: [String]
        do {
            tmbContents = try access.read(url) { try FileManager.default.contentsOfDirectory(atPath: url.path) }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            throw error
        } catch {
            tmbContents = []
        }
        let recordedName = info.metadata.originalFileName
        let bookFileName = tmbContents.contains(recordedName) && isPackageContentName(recordedName)
            ? recordedName
            : tmbContents.first(where: isPackageContentName)

        guard let fileName = bookFileName else { return nil }
        let bookFile = url.appendingPathComponent(fileName)
        switch access.presence(of: bookFile) {
        case .absent:
            return nil
        case .inCloud:
            throw MaintenanceFileAccess.refusal(of: bookFile)
        case .present:
            break
        }

        let folderPath = libraryFolderPath(ofPackageAt: url, libraryDirectory: libraryDir)

        // Build the Book from bookInfo.json metadata and state, every field
        // the record holds included, its text cache's fingerprints too. A
        // package in the Library folder is a library book, whatever feed its
        // record names (FR11).
        let book = Book(
            record: info,
            filePath: bookFile.path,
            folderPath: folderPath,
            tmbDirectoryName: url.lastPathComponent
        ).placedInLibraryFolder()
        return (book, info.metadata.folderPath)
    }

    /// Recreates folder rows for every folder a book lives in, its ancestors
    /// included, and, when `includingFoldersOnDisk`, for the folders on disk
    /// as well. Only the library index records folder rows, so when it holds
    /// none to go by, the directories under the library directory are the
    /// best remaining evidence of the user's folders. Without rows, books in
    /// folders would be unreachable from the Folders view, and Rebuild Library
    /// Index would save a library whose folders had vanished.
    ///
    /// Which folders count is the caller's choice:
    /// - The folders on disk too (the default), when there is no index to go
    ///   by: the provisional library shown while the index cannot be read
    ///   (`LibraryViewModel.buildProvisionalLibrary()`), and the startup
    ///   repair of a library that began with no books and no folders, its
    ///   library.json missing or empty.
    /// - Only the folders books name, for the startup repair of every other
    ///   library, whose index records the user's folders: a book never lies
    ///   in a folder with no row, while a directory with no row, such as one
    ///   a deleted folder left behind, stays out. The disk is not walked.
    ///
    /// Package directories, their contents, and hidden entries are skipped.
    /// Paths deeper than `BookFolder.maxDepth`, names folder creation refuses,
    /// and folders equivalent to an existing row are left out. Returns the
    /// number of rows added; running it again adds none.
    @discardableResult
    static func adoptLibraryFolders(
        library: inout Library,
        libraryDirectory: URL = TextMouthPaths.libraryDir,
        includingFoldersOnDisk: Bool = true
    ) -> Int {
        var paths = includingFoldersOnDisk ? folderDirectoryPaths(in: libraryDirectory) : []
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
    ///
    /// The walk leaves dataless folders in the cloud (FR02): a folder that
    /// cannot be listed without downloading is still found by its parent's
    /// listing, and only the folders inside it wait until it is on this Mac.
    private static func folderDirectoryPaths(in libraryDirectory: URL) -> Set<String> {
        DatalessFiles.withoutDownloading {
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
}

// MARK: - Walking Folders

extension FileManager.DirectoryEnumerator {
    /// Finder's metadata folder, which it adds to the archives it makes.
    static let finderMetadataFolderName = "__MACOSX"

    /// Skips the contents of `item`, the item this enumerator returned last,
    /// when it is Finder's metadata folder, and says whether it did.
    ///
    /// Only a folder is skipped. `skipDescendants()` is for the folder just
    /// returned, but on a file or a symbolic link it skips the contents of
    /// the next folder listed beside it (found on this Mac with a link
    /// listed before "Disc 2": the folder was listed, its tracks never
    /// were), so a walk that calls it for anything else loses the books or
    /// tracks beneath that folder.
    ///
    /// - Parameters:
    ///   - item: The item just returned.
    ///   - isDirectory: Whether it is a folder, as its resource values say;
    ///     nil (not known) counts as not a folder.
    @discardableResult
    func skipFinderMetadataFolder(_ item: URL, isDirectory: Bool?) -> Bool {
        guard isDirectory == true, item.lastPathComponent == Self.finderMetadataFolderName else { return false }
        skipDescendants()
        return true
    }
}
