import Foundation
import os

// MARK: - What a Book Can Export (FR05)

/// A kind of thing a book can export, in the order the Export dialog lists
/// them: the book's own content (an audiobook's audio, or a text book's own
/// file and its text, as Voice Dream offered them), then the files a
/// recording and a transcription keep beside it (the user's answer of
/// October 4, 2026).
///
/// Export lists whatever files a book's package holds, by kind
/// (`BookExportService.offer(for:access:)`), so a kind appears for every
/// book whose package holds its file, whichever feature put it there.
enum BookExportKind: String, CaseIterable, Sendable {
    /// An audiobook's audio: its one file, or every file of its folder of
    /// tracks in the order the book plays them. For a recording, the audio
    /// the book plays, which is the edited audio once the audio editor has
    /// written one.
    case audio
    /// A text book's own file as it was imported: its EPUB, Word document,
    /// PDF, HTML, Markdown, or text file, a DAISY book's ZIP, or every file
    /// of a DAISY book kept as loose files.
    case originalFile
    /// A text book's text as Markdown, written from its text cache,
    /// content.md, with only the escapes Markdown needs
    /// (`MarkdownExportWriter`); it holds no chapter marker line.
    case markdown
    /// A text book's reading text, chapter by chapter, each under its
    /// title: the words TextMouth reads aloud, as plain text.
    case plainText
    /// A recording's original take, kept beside the audio the book plays
    /// (`BookOrigin.originalTakeFileName`).
    case originalRecording
    /// An audiobook's audio as it was before its first edit, which the
    /// audio editor keeps in the package's originals folder while the
    /// original policy keeps it (`AudioEditPackage.originalFile(forAudioFile:)`):
    /// a book's file, or the files of the tracks edited in a book of several.
    case originalAudio
    /// A transcription's transcript (`TextMouthPaths.transcriptFileName`)
    /// and, for an audiobook, the text written from it, its content.md.
    case transcript

    /// The kind's place in the dialog's list.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// One file an export writes: where its bytes come from, and its name.
struct BookExportFile: Equatable, Sendable {
    /// Where an exported file's bytes come from.
    enum Source: Equatable, Sendable {
        /// A file in the book's package, copied byte for byte.
        case copy(URL)
        /// The book's reading text, made from the text cache (content.md)
        /// at the URL (`BookExportService.plainText(of:)`).
        case readingText(fromMarkdown: URL)
        /// The file at `from`, made into another by the conversion `by`, for
        /// the book `book` (FMT18): a text book's content.md, walked and
        /// written by a text writer. (Every kind is written to a scratch file
        /// and moved into place once whole, so no half-written file is ever
        /// left in the folder chosen.)
        /// An audiobook's transcript.json, written as captions, is one too
        /// (FMT23).
        case converted(from: URL, book: ExportBookDetails, by: BookExportConversion)

        /// The package file whose bytes are read.
        var url: URL {
            switch self {
            case .copy(let url), .readingText(let url), .converted(let url, _, _):
                return url
            }
        }
    }

    /// Where the file's bytes come from.
    let source: Source
    /// The file's place among its item's files: its name, after any
    /// folders it keeps inside the item's folder, with "/" between them,
    /// as in "Moby-Dick.md" or "OEBPS/chapter1.html".
    let path: String
    /// The file's size in bytes. For reading text, the size of the Markdown
    /// it is made from, which the text comes close to.
    let byteCount: Int64
}

/// One kind of thing one book can export, with the files it is made of.
struct BookExportItem: Equatable, Sendable {
    /// What the item is.
    let kind: BookExportKind
    /// The folder the item's files are exported in, named after the book,
    /// for an item that keeps its files together (an audiobook's tracks, a
    /// DAISY book's loose files); nil for an item whose files stand alone.
    let folderName: String?
    /// The files the item is made of, in order.
    let files: [BookExportFile]
    /// The first of the item's files, or the folder holding them, that is
    /// only in the cloud (FR02); nil when every one is on this Mac. Such an
    /// item is never exported, since copying it would download it.
    let fileInCloud: URL?

    /// The item's size in bytes: its files' sizes together.
    var byteCount: Int64 {
        files.reduce(0) { $0 + $1.byteCount }
    }

    /// Whether the item is only in the cloud, in part or in whole.
    var isInCloud: Bool {
        fileInCloud != nil
    }

    /// The name the item is exported under: its folder, or its first file.
    var suggestedName: String {
        folderName ?? files.first?.path ?? ""
    }
}

/// What one book can export.
struct BookExportOffer: Equatable, Sendable {
    /// The book, as the library listed it when the offer was made.
    let book: Book
    /// What the book's package holds, by kind, in the dialog's order.
    let items: [BookExportItem]
    /// Whether the book's package itself is only in the cloud (FR02), so
    /// what it holds could not be listed without downloading it.
    let isPackageInCloud: Bool

    /// The book's item of `kind`, when it has one.
    func item(_ kind: BookExportKind) -> BookExportItem? {
        items.first { $0.kind == kind }
    }
}

/// One file an export could not write, and why.
struct BookExportFailure: Equatable, Sendable {
    /// The file's name, as the export would have called it.
    let name: String
    /// Why, in the words the system gives.
    let reason: String
}

/// A book an export names: its ID, which tells books apart, and its title,
/// which the words name it by.
struct BookExportBookName: Equatable, Sendable {
    let id: UUID
    let title: String

    /// The name of `book`.
    init(_ book: Book) {
        id = book.id
        title = book.title
    }
}

/// What an export did.
struct BookExportOutcome: Equatable, Sendable {
    /// The folder the export wrote into.
    let destination: URL
    /// Every file written, in the order written.
    var exported: [URL] = []
    /// The files that could not be written, with why.
    var failures: [BookExportFailure] = []
    /// The books with chosen items only in the cloud (FR02), each once, in
    /// the order met: nothing of theirs that is in the cloud was exported.
    var booksInCloud: [BookExportBookName] = []
    /// Whether the export stopped early because it was cancelled.
    var wasCancelled = false

    /// Notes that `book` has chosen items only in the cloud, once.
    mutating func noteInCloud(_ book: BookExportBookName) {
        if !booksInCloud.contains(where: { $0.id == book.id }) {
            booksInCloud.append(book)
        }
    }
}

/// The Cancel of an export under way: set on the main actor, read by the
/// export between files on its background thread, and, through
/// `childProcesses`, by a child process the export is waiting for.
final class BookExportCancellation: Sendable {
    /// Whether the export is to stop, guarded by the lock itself.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// What a child process the export runs listens to, so that Stop kills
    /// it at once rather than waiting for it to end (TODO 3985): the braille
    /// helper, which a BRF or PEF export's translation runs for up to a
    /// minute on a long book (`BrailleExportWriting.write(_:to:cancellation:makeData:)`
    /// binds it). It is the token every wait for a child process in
    /// TextMouth stops on (`BrailleTranslator`, `AsyncBridge.waitForResult(cancelledBy:of:)`),
    /// named for the import, whose Cancel it was made for.
    let childProcesses = ImportCancellation()

    /// Whether the export is to stop at its next file.
    var isCancelled: Bool {
        cancelled.withLock { $0 }
    }

    /// Stops the export before its next file, and kills the child process
    /// it is waiting for, if any. The flag is set first, so work that finds
    /// its child killed finds the export stopped too.
    func cancel() {
        cancelled.withLock { $0 = true }
        childProcesses.cancel()
    }

    /// Throws `CancellationError` once the export is to stop: what a
    /// conversion calls between its steps and a writer between its blocks
    /// (FMT18), so that Stop ends a book partway.
    func checkCancelled() throws {
        if isCancelled {
            throw CancellationError()
        }
    }
}

// MARK: - Converting Instead of Copying (FMT18)

extension BookExportKind {
    /// Whether the kind's file is a text book's content.md, which a text
    /// writer can convert: "Text as Markdown" alone, whose Convert to choice
    /// is Markdown, written by `MarkdownExportWriter`, unless another is
    /// chosen.
    var convertsText: Bool {
        self == .markdown
    }
}

/// How an export makes one kind's files instead of copying them (FMT18).
///
/// Text tonight: a text book's content.md, walked into an `ExportDocument`
/// and written by the writer chosen in the Convert to picker. An audio kind
/// can gain a case of its own later (FMT30, FMT43) without the job runner
/// changing shape: each case names the extension its files take and how a
/// file is made.
enum BookExportConversion: Sendable, Equatable {
    /// content.md, walked and written by a text writer with its options.
    case text(TextExportConversion)

    /// A transcript's transcript.json, written as captions in the format
    /// (FMT23): one file for the book, timed from the start of its audio
    /// (`Transcript.bookTimelineCues`).
    case timedText(TranscriptExportFormat)

    /// The Markdown an export writes of a text book (and of an audiobook's
    /// transcript): written afresh from the walk of its content.md with only
    /// the escapes Markdown needs (`MarkdownExportWriter`), where content.md
    /// itself escapes every ASCII punctuation character for TextMouth's own
    /// reader.
    static let markdown = BookExportConversion.text(TextExportConversion(MarkdownExportWriter(), options: NoTextExportOptions()))

    /// The extension, without its dot, of the files the conversion makes.
    var fileExtension: String {
        switch self {
        case .text(let conversion):
            return conversion.fileExtension
        case .timedText(let format):
            return format.fileExtension
        }
    }

    /// Whether the conversion can make the files of `kind`: a text
    /// conversion makes those of a kind whose `convertsText` is true, and
    /// is ignored for any other.
    /// A text conversion also writes a transcript's text, its Markdown
    /// (TODO 3984); captions are a transcript's alone (FMT23).
    func applies(to kind: BookExportKind) -> Bool {
        switch self {
        case .text:
            return kind.convertsText || kind == .transcript
        case .timedText:
            // Captions are made of a transcript alone.
            return kind == .transcript
        }
    }

    /// The conversion's name, as the Convert to picker says it.
    var name: String {
        switch self {
        case .text(let conversion):
            return conversion.name
        case .timedText(let format):
            return format.name
        }
    }
}

// MARK: - Listing and Exporting

/// Lists what a book can export and copies the chosen items to a folder
/// (FR05): an audiobook's audio, a recording's original take, the original
/// audio an edit kept, a transcript, and a text book's own file, its
/// Markdown, and its reading text.
///
/// Both run off the main actor, since they read and copy files that can
/// wait on a drive or the network. Neither ever downloads a file that is
/// only in the cloud (FR02): every check and read goes through a
/// `MaintenanceFileAccess`, with dataless files left in the cloud, and an
/// item with any file in the cloud is refused instead, named in the words
/// the library list uses (`LibraryCloudWording.notDownloaded(titles:)`).
enum BookExportService {
    /// The extensions of the audio files an audiobook's folder of tracks
    /// can hold: the formats TextMouth plays.
    private static let audioExtensions = Set(BookFormat.audio.fileExtensions)

    // MARK: Listing

    /// What `book` can export, read from its package as it is now.
    ///
    /// Reads only what the file system says about the package's files,
    /// plus, for an audiobook of several files, its saved content index,
    /// for the chapter names its files are exported under, and, for a DAISY
    /// book kept as loose files, its navigation or package file, which
    /// lists its files. Nothing is downloaded: a package only in the cloud
    /// is offered as such, with nothing listed, and an item with a file in
    /// the cloud names it (`BookExportItem.fileInCloud`). Call it off the
    /// main thread.
    static func offer(for book: Book, access: MaintenanceFileAccess = .live) -> BookExportOffer {
        let stem = fileNameStem(for: book.title)
        // A book from the earliest releases, without a package, has only
        // its own file to export.
        guard !book.tmbDirectoryName.isEmpty else {
            return BookExportOffer(
                book: book,
                items: [ownFileItem(of: book, stem: stem, access: access)].compactMap { $0 },
                isPackageInCloud: false
            )
        }
        let package = book.tmbDirectory
        guard !access.isInCloud(package) else {
            return BookExportOffer(book: book, items: [], isPackageInCloud: true)
        }

        var items: [BookExportItem] = []
        if let own = ownFileItem(of: book, stem: stem, access: access) {
            items.append(own)
        }
        let take = package.appendingPathComponent(BookOrigin.originalTakeFileName)
        if access.presence(of: take) == .present {
            let name = "\(stem) - Original Recording.\(take.pathExtension)"
            items.append(standaloneItem(.originalRecording, files: [copy(take, as: name)], access: access))
        }
        if let originals = originalAudioItem(of: book, stem: stem, access: access) {
            items.append(originals)
        }
        if let converted = convertedOriginalItem(of: book, stem: stem, access: access) {
            items.append(converted)
        }
        let markdown = MarkdownCacheService.cacheURL(for: book)
        let hasMarkdown = access.presence(of: markdown) == .present
        if let transcript = transcriptItem(of: book, stem: stem, markdown: hasMarkdown ? markdown : nil, access: access) {
            items.append(transcript)
        }
        // An audiobook's content.md, when it has one, is its transcript's
        // text, exported with the transcript above.
        if hasMarkdown && !book.format.isAudio {
            items.append(standaloneItem(
                .markdown,
                files: [markdownFile(of: book, from: markdown, as: "\(stem) - Text.md")],
                access: access
            ))
            let readingText = BookExportFile(
                source: .readingText(fromMarkdown: markdown),
                path: "\(stem) - Text.txt",
                byteCount: byteCount(of: markdown)
            )
            items.append(standaloneItem(.plainText, files: [readingText], access: access))
        }
        return BookExportOffer(
            book: book,
            items: items.sorted { $0.kind.order < $1.kind.order },
            isPackageInCloud: false
        )
    }

    /// The book's own content: an audiobook's audio, or a text book's own
    /// file. Nil when the file is gone.
    private static func ownFileItem(of book: Book, stem: String, access: MaintenanceFileAccess) -> BookExportItem? {
        let file = book.bookFileURL
        guard access.presence(of: file) != .absent else { return nil }
        if book.format.isAudio {
            return audioItem(at: file, of: book, stem: stem, access: access)
        }
        if isLooseDAISYEntry(file, of: book) {
            return looseDAISYItem(entry: file, of: book, stem: stem, access: access)
        }
        return standaloneItem(.originalFile, files: [copy(file, as: file.lastPathComponent)], access: access)
    }

    /// The transcript: its transcript.json and, for an audiobook, the text
    /// written from it, `markdown`, each when the package holds it. Nil
    /// when it holds neither.
    private static func transcriptItem(
        of book: Book,
        stem: String,
        markdown: URL?,
        access: MaintenanceFileAccess
    ) -> BookExportItem? {
        var files: [BookExportFile] = []
        let transcript = TextMouthPaths.transcriptPath(in: book.tmbDirectory)
        if access.presence(of: transcript) == .present {
            files.append(copy(transcript, as: "\(stem) - Transcript.json"))
        }
        if book.format.isAudio, let markdown {
            files.append(markdownFile(of: book, from: markdown, as: "\(stem) - Transcript.md"))
        }
        guard !files.isEmpty else { return nil }
        return standaloneItem(.transcript, files: files, access: access)
    }

    /// An item of `kind` whose `files` are exported each as itself, in the
    /// cloud when any of them is.
    private static func standaloneItem(
        _ kind: BookExportKind,
        files: [BookExportFile],
        access: MaintenanceFileAccess
    ) -> BookExportItem {
        BookExportItem(
            kind: kind,
            folderName: nil,
            files: files,
            fileInCloud: files.lazy.compactMap { access.itemInCloud($0.source.url) }.first
        )
    }

    /// The Markdown of `book`'s text, written under the name `name` from the
    /// walk of its content.md at `markdown` (`BookExportConversion.markdown`),
    /// where content.md itself would be copied with a backslash before every
    /// punctuation character. Its size is content.md's, which it comes close
    /// to.
    private static func markdownFile(of book: Book, from markdown: URL, as name: String) -> BookExportFile {
        BookExportFile(
            source: .converted(from: markdown, book: ExportBookDetails(book), by: .markdown),
            path: name,
            byteCount: byteCount(of: markdown)
        )
    }

    /// The file at `url`, copied byte for byte under the name `name`.
    private static func copy(_ url: URL, as name: String) -> BookExportFile {
        BookExportFile(source: .copy(url), path: name, byteCount: byteCount(of: url))
    }

    /// The size of the regular file at `url` from its metadata alone, or 0
    /// when it cannot be read: a size that only labels the dialog.
    private static func byteCount(of url: URL) -> Int64 {
        FileStamp(of: url)?.byteCount ?? 0
    }

    // MARK: Audio

    /// An audiobook's audio at `file`, its one file or its folder of
    /// tracks. A folder's files are exported together in a folder named
    /// after the book, in the order the book plays them, each named for the
    /// first chapter that plays it (`audioFileOrder(listed:index:)`), as in
    /// "01 - The Harbour.mp3".
    private static func audioItem(at file: URL, of book: Book, stem: String, access: MaintenanceFileAccess) -> BookExportItem? {
        guard isFolder(file) else {
            return standaloneItem(.audio, files: [copy(file, as: file.lastPathComponent)], access: access)
        }
        // A folder whose listing is refused, being only in the cloud, is
        // offered as such, with nothing listed.
        guard let listed = try? access.read(file, { try audioFiles(in: file) }) else {
            return BookExportItem(kind: .audio, folderName: stem, files: [], fileInCloud: file)
        }
        let index = savedContentIndex(of: book, access: access)
        let ordered = audioFileOrder(listed: listed, index: index)
        guard !ordered.isEmpty else { return nil }
        let width = max(2, String(ordered.count).count)
        let files = ordered.enumerated().map { number, entry -> BookExportFile in
            let url = file.appendingPathComponent(entry.path)
            let base = (entry.path as NSString).lastPathComponent
            let title = entry.title?.nonBlank ?? (base as NSString).deletingPathExtension
            let numberText = String(repeating: "0", count: max(0, width - String(number + 1).count)) + String(number + 1)
            let name = "\(numberText) - \(safeFileName(title, fallback: numberText))"
            let ext = url.pathExtension
            return copy(url, as: ext.isEmpty ? name : "\(name).\(ext)")
        }
        return BookExportItem(
            kind: .audio,
            folderName: stem,
            files: files,
            fileInCloud: files.lazy.compactMap { access.itemInCloud($0.source.url) }.first
        )
    }

    /// The audio files inside `folder`, at any depth, by their paths inside
    /// it ("Disc 1/01.mp3"): every file TextMouth can play, hidden ones
    /// left out. Lists with dataless files left in the cloud when the
    /// caller runs it so (`MaintenanceFileAccess.read`): a listing that
    /// would download throws.
    private static func audioFiles(in folder: URL) throws -> [String] {
        try regularFiles(in: folder).filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// The files inside `folder`, at any depth, by their paths inside it, in
    /// Finder's order: no folder, and nothing hidden or inside a hidden
    /// folder. Lists as `audioFiles(in:)` does.
    private static func regularFiles(in folder: URL) throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: folder.path)
            .filter { path in
                !path.split(separator: "/").contains { $0.hasPrefix(".") } && !isFolder(folder.appendingPathComponent(path))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// `listed`, an audiobook folder's audio files by their paths inside
    /// it, in the order the book plays them, each with the title of the
    /// first chapter that plays any of it, as `index`, the book's saved
    /// content index, records them. A chapter plays its own file, or each
    /// file its clips name, for a book whose sections run across files.
    /// Files the index does not name follow, in Finder's order of their
    /// paths, with no title; with no index, every file does. A file the
    /// index names that is not listed, being gone, is left out.
    static func audioFileOrder(listed: [String], index: BookContentIndex?) -> [(path: String, title: String?)] {
        // Paths are compared in one Unicode form, as the file system does.
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }
        let listedByKey = Dictionary(listed.map { (key($0), $0) }, uniquingKeysWith: { first, _ in first })

        var ordered: [(path: String, title: String?)] = []
        var placed: Set<String> = []
        for chapter in index?.chapters ?? [] {
            let paths = [chapter.audioFilePath].compactMap { $0 }
                + (chapter.audio?.clips?.compactMap(\.audioFilePath) ?? [])
            for path in paths {
                let pathKey = key(path)
                guard let found = listedByKey[pathKey], placed.insert(pathKey).inserted else { continue }
                ordered.append((path: found, title: chapter.title))
            }
        }
        let rest = listed
            .filter { !placed.contains(key($0)) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ordered + rest.map { (path: $0, title: nil) }
    }

    /// The content index saved in `book`'s package, read with dataless
    /// files left in the cloud; nil when there is none, or it cannot be
    /// read here.
    private static func savedContentIndex(of book: Book, access: MaintenanceFileAccess) -> BookContentIndex? {
        let package = book.tmbDirectory
        return (try? access.read(package) { try BookInfo.load(from: package) })?.contentIndex
    }

    // MARK: Originals an Edit Kept

    /// The audio as it was before its first edit (FR04): every file in the
    /// package's originals folder, where the audio editor keeps a book's
    /// original while the original policy keeps it, named as the engine
    /// names that folder (`AudioEditPackage`). The files are copied as they
    /// are; Export never makes an original of its own from the book's audio,
    /// and a recording's take, which stays at the package root, is its
    /// Original recording. The original of a book of one file is exported as
    /// "<title> - Original Audio" with its own extension; the originals of a
    /// book of tracks, or of one file kept more than once, together in a
    /// folder of that name, each under its path inside the book's audio
    /// folder. Nil when no original is kept. A folder that can't be listed
    /// without downloading it is offered as in the cloud, with nothing
    /// listed.
    private static func originalAudioItem(of book: Book, stem: String, access: MaintenanceFileAccess) -> BookExportItem? {
        let package = book.tmbDirectory
        let folder = AudioEditPackage.folder(in: package)
            .appendingPathComponent(AudioEditPackage.originalsFolderName, isDirectory: true)
        let name = "\(stem) - Original Audio"
        let inCloud = BookExportItem(kind: .originalAudio, folderName: name, files: [], fileInCloud: folder)
        switch access.presence(of: folder) {
        case .absent:
            return nil
        case .inCloud:
            return inCloud
        case .present:
            break
        }
        let listed: [String]
        do {
            listed = try access.read(folder) { try regularFiles(in: folder) }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return inCloud
        } catch {
            return nil
        }
        guard !listed.isEmpty else { return nil }
        if listed.count == 1, let only = listed.first, !isFolder(book.bookFileURL) {
            let ext = (only as NSString).pathExtension
            let file = copy(folder.appendingPathComponent(only), as: ext.isEmpty ? name : "\(name).\(ext)")
            return standaloneItem(.originalAudio, files: [file], access: access)
        }
        // An original is kept at its file's path inside the package; in the
        // exported folder it keeps its path inside the book's audio folder.
        let audioFolder = AudioEditPackage.path(of: book.bookFileURL, in: package).map { $0 + "/" }
        let files = listed.map { path -> BookExportFile in
            let inside = audioFolder.flatMap { path.hasPrefix($0) ? String(path.dropFirst($0.count)) : nil }
            return copy(folder.appendingPathComponent(path), as: inside ?? path)
        }
        return BookExportItem(
            kind: .originalAudio,
            folderName: name,
            files: files,
            fileInCloud: files.lazy.compactMap { access.itemInCloud($0.source.url) }.first
        )
    }

    // MARK: Originals an Import Kept

    /// The audio files as they were before the import converted them (the
    /// "Keep originals of converted audio" setting): every file in the
    /// package's hidden kept originals folder, which only an audiobook's
    /// import fills. They are copied as bytes and never opened, so a kept
    /// Ogg file is never decoded (the October 14 rule). The original of a
    /// book of one file is exported under its own name, as a text book's
    /// Original file is; the originals of a book of tracks, in a folder
    /// named "<title> - Original Files", each under its path inside the
    /// book's folder of tracks. Nil when the book is not an audiobook or
    /// keeps none. A folder that can't be listed without downloading it is
    /// offered as in the cloud, with nothing listed.
    private static func convertedOriginalItem(of book: Book, stem: String, access: MaintenanceFileAccess) -> BookExportItem? {
        guard book.format.isAudio else { return nil }
        let folder = book.tmbDirectory
            .appendingPathComponent(ImportAudioConverter.keptOriginalsFolderName, isDirectory: true)
        let name = "\(stem) - Original Files"
        let inCloud = BookExportItem(kind: .originalFile, folderName: name, files: [], fileInCloud: folder)
        switch access.presence(of: folder) {
        case .absent:
            return nil
        case .inCloud:
            return inCloud
        case .present:
            break
        }
        let listed: [String]
        do {
            listed = try access.read(folder) { try regularFiles(in: folder) }
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return inCloud
        } catch {
            return nil
        }
        guard !listed.isEmpty else { return nil }
        // A book of one file keeps one original, which is exported alone.
        // A book of tracks is exported as a folder, even for a single kept
        // original, so the folder tells which tracks it belongs to.
        if listed.count == 1, let only = listed.first, !isFolder(book.bookFileURL) {
            return standaloneItem(.originalFile, files: [copy(folder.appendingPathComponent(only), as: only)], access: access)
        }
        let files = listed.map { copy(folder.appendingPathComponent($0), as: $0) }
        return BookExportItem(
            kind: .originalFile,
            folderName: name,
            files: files,
            fileInCloud: files.lazy.compactMap { access.itemInCloud($0.source.url) }.first
        )
    }

    // MARK: DAISY Books Kept as Loose Files

    /// Whether `file`, `book`'s own file, is the navigation or package file
    /// of a DAISY book kept as loose files, laid out at the top of its
    /// package as in its own folder (TODO I02).
    private static func isLooseDAISYEntry(_ file: URL, of book: Book) -> Bool {
        book.format == .daisy
            && DAISYParser.isPackageEntryFile(file)
            && file.deletingLastPathComponent().standardizedFileURL.path == book.tmbDirectory.standardizedFileURL.path
    }

    /// A DAISY book kept as loose files: every file of the book, laid out
    /// as in its own folder, in a folder named after the book. The files
    /// are those its navigation or package file lists
    /// (`DAISYPackageInventory`), which never includes the files TextMouth
    /// keeps beside them; when they cannot be listed, every file of the
    /// package that can be the book's is. A package with a file in the
    /// cloud is offered as such, since listing it would read that file.
    private static func looseDAISYItem(
        entry: URL,
        of book: Book,
        stem: String,
        access: MaintenanceFileAccess
    ) -> BookExportItem {
        if let inCloud = access.fileInCloud(of: book, reading: .content) {
            return BookExportItem(kind: .originalFile, folderName: stem, files: [], fileInCloud: inCloud)
        }
        let listed: [BookExportFile]
        if let inventory = try? access.read(entry, { try DAISYPackageInventory.make(for: entry) }) {
            listed = inventory.files.map {
                BookExportFile(source: .copy($0.source), path: $0.path, byteCount: Int64($0.size))
            }
        } else {
            listed = packageBookFiles(in: book.tmbDirectory)
        }
        return BookExportItem(kind: .originalFile, folderName: stem, files: listed, fileInCloud: nil)
    }

    /// Every file in `package` that can be part of the book itself, by its
    /// path inside the package: none of TextMouth's own files, and none
    /// hidden (`DAISYPackageInventory.isBookPath`).
    private static func packageBookFiles(in package: URL) -> [BookExportFile] {
        let ownFiles: Set<String> = [BookOrigin.originalTakeFileName, TextMouthPaths.transcriptFileName]
        let paths = (try? FileManager.default.subpathsOfDirectory(atPath: package.path)) ?? []
        return paths
            .filter { path in
                DAISYPackageInventory.isBookPath(path)
                    && !ownFiles.contains(path)
                    && !isFolder(package.appendingPathComponent(path))
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { copy(package.appendingPathComponent($0), as: $0) }
    }

    // MARK: Exporting

    /// One file an export will write: the file, where it goes, and whose.
    struct PlannedFile: Equatable, Sendable {
        /// The book it belongs to.
        let book: BookExportBookName
        /// What to write.
        let file: BookExportFile
        /// Where to write it.
        let target: URL
    }

    /// Where each file of the `kinds` chosen of `offers` goes in
    /// `destination`, and the titles of the books with chosen items only in
    /// the cloud, which are left out.
    ///
    /// - With one book, its items go into `destination` itself, an item that
    ///   keeps its files together in a folder named after the book.
    /// - With several books chosen, each book's items go into a folder of its
    ///   own, named after the book, whatever they are.
    ///
    /// No name already taken in a folder is used again: a name `fileExists`
    /// finds, or one planned before, is followed by a number, as in
    /// "Moby-Dick 2.md", so an export never writes over anything.
    ///
    /// A kind with a conversion in `conversions` (FMT18) is converted, not
    /// copied: each of its files becomes a `.converted` file whose name has
    /// the conversion's extension in place of its own, as "Moby-Dick -
    /// Text.md" becoming "Moby-Dick - Text.html", and is then named uniquely
    /// like any other. A conversion given for a kind it cannot make
    /// (`BookExportConversion.applies(to:)`) is ignored.
    static func plan(
        _ offers: [BookExportOffer],
        kinds: Set<BookExportKind>,
        conversions: [BookExportKind: BookExportConversion] = [:],
        in destination: URL,
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> (files: [PlannedFile], booksInCloud: [BookExportBookName]) {
        var cloud = BookExportOutcome(destination: destination)
        // Each book with something on this Mac to export, with those items.
        var exporting: [(book: Book, items: [BookExportItem])] = []
        for offer in offers where !kinds.isEmpty {
            let chosen = offer.items.filter { kinds.contains($0.kind) }
            if offer.isPackageInCloud || chosen.contains(where: \.isInCloud) {
                cloud.noteInCloud(BookExportBookName(offer.book))
            }
            let onThisMac = chosen.filter { !$0.isInCloud && !$0.files.isEmpty }
            if !onThisMac.isEmpty {
                exporting.append((offer.book, onThisMac))
            }
        }

        var names = UniqueNames(fileExists: fileExists)
        var planned: [PlannedFile] = []
        let foldersPerBook = offers.count > 1
        for (book, items) in exporting {
            let stem = fileNameStem(for: book.title)
            let bookFolder = foldersPerBook ? names.claim(stem, in: destination) : destination
            for item in items {
                var folder = bookFolder
                if !foldersPerBook, let folderName = item.folderName {
                    folder = names.claim(folderName, in: destination)
                }
                for file in files(of: item, for: book, conversions: conversions) {
                    // A file inside folders of its own keeps them, below a
                    // folder that is new; a name of its own is made unique.
                    let target = file.path.contains("/")
                        ? folder.appendingPathComponent(file.path)
                        : names.claim(file.path, in: folder)
                    planned.append(PlannedFile(book: BookExportBookName(book), file: file, target: target))
                }
            }
        }
        return (planned, cloud.booksInCloud)
    }

    /// The files of `item` of `book` to write: as they are, unless the item's
    /// kind has a conversion in `conversions` that applies to it, when each
    /// copied or already converted file (the Markdown the offer lists, made
    /// from content.md) becomes one converted by it instead, named with the
    /// conversion's extension (FMT18). Files made any other way are left as
    /// they are.
    /// Captions (FMT23) are made of the transcript's transcript.json alone,
    /// "Moby-Dick - Transcript.json" becoming "Moby-Dick - Transcript.vtt":
    /// the Markdown written from it is not exported with them. A text
    /// writer, the other way about, writes the transcript's text alone (TODO
    /// 3984), "Moby-Dick - Transcript.md" becoming "Moby-Dick -
    /// Transcript.html", and its transcript.json is not exported.
    private static func files(
        of item: BookExportItem,
        for book: Book,
        conversions: [BookExportKind: BookExportConversion]
    ) -> [BookExportFile] {
        guard let conversion = conversions[item.kind], conversion.applies(to: item.kind) else {
            return item.files
        }
        let details = ExportBookDetails(book)
        var toConvert = item.files
        // Captions are made of the transcript.json alone (FMT23).
        if case .timedText = conversion {
            toConvert = item.files.filter(isTranscriptFile)
        }
        // A text writer writes the transcript's text alone (TODO 3984).
        if case .text = conversion, item.kind == .transcript {
            toConvert = item.files.filter { !isTranscriptFile($0) }
        }
        return toConvert.map { file in
            let url: URL
            switch file.source {
            case .copy(let source), .converted(let source, _, _):
                url = source
            case .readingText:
                return file
            }
            // The name keeps any folders and swaps only the last extension.
            let path = (file.path as NSString).deletingPathExtension + "." + conversion.fileExtension
            return BookExportFile(
                source: .converted(from: url, book: details, by: conversion),
                path: path,
                byteCount: file.byteCount
            )
        }
    }

    /// Whether `file` is made from a transcript's transcript.json, which
    /// captions are made of and a text writer leaves out (FMT23).
    private static func isTranscriptFile(_ file: BookExportFile) -> Bool {
        file.source.url.lastPathComponent == TextMouthPaths.transcriptFileName
    }

    /// Exports the `kinds` chosen of `offers` into `destination`, as `plan`
    /// lays them out, and says what it did.
    ///
    /// `conversions` (FMT18) makes a kind's files by converting them instead of
    /// copying (`plan`): each converted file is written by its writer.
    /// Every file, converted or copied, is made in a scratch folder and moved
    /// into place once whole, so Stop or a failure partway leaves nothing of
    /// it in `destination`.
    ///
    /// Each file is checked just before it is written: one that is only in
    /// the cloud by then is not written, and its book is named among those
    /// in the cloud. Every copy and read runs with dataless files left in
    /// the cloud (`MaintenanceFileAccess.read`), so a file that goes to the
    /// cloud while it is copied fails rather than downloading. A file that
    /// cannot be written is named with the reason; the others are still
    /// written. Nothing already in `destination` is ever written over, and
    /// nothing in it is ever removed, not even a file that appeared there
    /// since the plan.
    ///
    /// `cancellation` stops the export before its next file, or partway
    /// through a file, which is then not written at all; `progress`
    /// hears how many files are done after each one, out of how many. Runs
    /// on the caller's thread: call it off the main thread.
    static func export(
        _ offers: [BookExportOffer],
        kinds: Set<BookExportKind>,
        conversions: [BookExportKind: BookExportConversion] = [:],
        to destination: URL,
        access: MaintenanceFileAccess = .live,
        cancellation: BookExportCancellation? = nil,
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) -> BookExportOutcome {
        let (files, booksInCloud) = plan(offers, kinds: kinds, conversions: conversions, in: destination)
        var outcome = BookExportOutcome(destination: destination, booksInCloud: booksInCloud)
        // One token for the whole export, so a conversion has one to check
        // even when the caller passed none.
        let token = cancellation ?? BookExportCancellation()
        for (number, planned) in files.enumerated() {
            if token.isCancelled {
                outcome.wasCancelled = true
                break
            }
            write(planned, access: access, cancellation: token, into: &outcome)
            // A Stop pressed during this file ended it, and the export too.
            if outcome.wasCancelled { break }
            progress?(number + 1, files.count)
        }
        logOutcome(outcome, offers: offers)
        return outcome
    }

    /// Writes one planned file, recording in `outcome` that it was written,
    /// that its book is in the cloud, or why it failed. A Stop pressed while a
    /// file is written (`CancellationError`) sets `outcome.wasCancelled`: the
    /// file is then neither exported nor a failure. Whatever fails, nothing is
    /// removed from the folder chosen: the file is made in a scratch folder
    /// and only moved in whole.
    private static func write(
        _ planned: PlannedFile,
        access: MaintenanceFileAccess,
        cancellation: BookExportCancellation,
        into outcome: inout BookExportOutcome
    ) {
        let source = planned.file.source.url
        guard access.itemInCloud(source) == nil else {
            outcome.noteInCloud(planned.book)
            return
        }
        // Every file is made at a scratch URL and moved to the target, which
        // is refused if a file is there by then (`writeThroughScratchFile`),
        // so a failure or Stop leaves nothing in the folder chosen and the
        // export never removes anything from it.
        do {
            switch planned.file.source {
            case .copy(let url):
                // A file, or a folder such as an RTFD package.
                try writeThroughScratchFile(to: planned.target, cancellation: cancellation) { scratch in
                    try access.read(url) { try FileManager.default.copyItem(at: url, to: scratch) }
                }
            case .readingText(let markdown):
                try writeThroughScratchFile(to: planned.target, cancellation: cancellation) { scratch in
                    let bytes = try access.read(markdown) { try Data(contentsOf: markdown) }
                    let text = try plainText(fromMarkdown: bytes, at: markdown, title: planned.book.title)
                    try Data(text.utf8).write(to: scratch, options: .withoutOverwriting)
                }
            case .converted(let url, let book, let conversion):
                try writeConverted(url, book: book, by: conversion, to: planned.target, access: access, cancellation: cancellation)
            }
            outcome.exported.append(planned.target)
        } catch is CancellationError {
            // Stop: nothing of this file is left, and it is not a failure.
            outcome.wasCancelled = true
        } catch where DatalessFiles.isDownloadRefusal(error) {
            outcome.noteInCloud(planned.book)
        } catch {
            outcome.failures.append(BookExportFailure(name: planned.target.lastPathComponent, reason: error.localizedDescription))
        }
    }

    /// Makes the folder that holds `target`, and any above it that are
    /// missing.
    private static func makeFolder(of target: URL) throws {
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    /// Writes the file at `source`, converted by `conversion` for `book`, to
    /// `target`: its bytes are read as the reading text's are (a file in the
    /// cloud is not downloaded), walked into a document, and written by the
    /// conversion into a scratch file that `writeThroughScratchFile` moves to
    /// `target` once whole. Stop is checked after the read, during the walk
    /// and the writing, and once more before the move.
    /// A transcript's captions (FMT23) are made of the transcript its bytes
    /// hold instead of a walk (`Transcript.exportable(from:)`), which throws
    /// `TranscriptExportError.unusable` for one that can't be read.
    /// - Throws: `CancellationError` when stopped, the walk's or the
    ///   writer's error, and the move's, which fails rather than replace a
    ///   file that appeared since the plan.
    private static func writeConverted(
        _ source: URL,
        book: ExportBookDetails,
        by conversion: BookExportConversion,
        to target: URL,
        access: MaintenanceFileAccess,
        cancellation: BookExportCancellation
    ) throws {
        let bytes = try access.read(source) { try Data(contentsOf: source) }
        try cancellation.checkCancelled()
        switch conversion {
        case .text(let text):
            let document = try ExportDocumentWalker.document(
                fromContentBytes: bytes,
                at: source,
                book: book,
                cancellation: cancellation
            )
            try writeThroughScratchFile(to: target, cancellation: cancellation) { scratch in
                try text.write(document, to: scratch, cancellation: cancellation)
            }
        case .timedText(let format):
            let transcript = try Transcript.exportable(from: bytes)
            try cancellation.checkCancelled()
            try writeThroughScratchFile(to: target, cancellation: cancellation) { scratch in
                try format.fileBytes(of: transcript.bookTimelineCues).write(to: scratch, options: .withoutOverwriting)
            }
        }
    }

    /// Makes `target` whole or not at all: `write` makes the file (or folder,
    /// such as an RTFD package) at a scratch URL of the target's name in a new
    /// scratch folder, and once Stop has not been pressed it is moved to
    /// `target` by `moveExclusively`, which fails rather than replace a file
    /// that appeared since the plan, atomically on one volume and by
    /// exclusive creation across volumes. The folder of `target` is made only
    /// then, so a stopped export leaves none. The scratch folder is removed
    /// in every case, so a stopped or failed file leaves nothing behind, and
    /// nothing is ever removed from the folder chosen. Every source kind goes
    /// through it: a copy and the reading text as well as a conversion, an
    /// audio one (FMT30, FMT43) as well as a text one.
    private static func writeThroughScratchFile(
        to target: URL,
        cancellation: BookExportCancellation,
        write: (_ scratch: URL) throws -> Void
    ) throws {
        let scratchFolder = try makeScratchFolder(near: target)
        defer { try? FileManager.default.removeItem(at: scratchFolder) }
        let scratch = scratchFolder.appendingPathComponent(target.lastPathComponent)
        try write(scratch)
        try cancellation.checkCancelled()
        try makeFolder(of: target)
        try moveExclusively(scratch, to: target)
    }

    /// Moves `source` (a file, or a folder such as an RTFD package) to
    /// `target`, which must not exist: if anything is there, even something
    /// that appeared an instant ago, it throws `CocoaError.fileWriteFileExists`
    /// and leaves both as they are. `FileManager.moveItem` checks and then
    /// renames, so a file made between the two is replaced (a reviewer's race
    /// replaced 2,995 of 3,000); this renames with `RENAME_EXCL`, which the
    /// file system makes atomic.
    ///
    /// Where that cannot be done (`EXDEV`: the scratch folder is on another
    /// volume than `target`; `ENOTSUP` and `EINVAL`: a volume without
    /// exclusive rename) the source is copied with exclusive creation and
    /// then removed; a copy that fails other than for an existing target
    /// removes only what it created itself.
    ///
    /// `rename` stands for `renamex_np(RENAME_EXCL)` and returns 0, or -1
    /// with `errno` set; it exists only so a test can make it report
    /// `EXDEV` and so check the copy on one volume.
    static func moveExclusively(
        _ source: URL,
        to target: URL,
        rename: (_ source: URL, _ target: URL) -> Int32 = renameWithoutReplacing
    ) throws {
        guard rename(source, target) != 0 else { return }
        // Read at once: anything that follows may change errno.
        let code = errno
        switch code {
        case EEXIST:
            throw targetExistsError(target)
        case EXDEV, ENOTSUP, EINVAL:
            try copyExclusively(source, to: target)
            try FileManager.default.removeItem(at: source)
        default:
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Renames `source` to `target` unless something is already there
    /// (`RENAME_EXCL`), atomically. 0 when done, else -1 with `errno` set.
    private static func renameWithoutReplacing(_ source: URL, _ target: URL) -> Int32 {
        renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
    }

    /// Copies `source`, a file or a folder with all it holds, to `target`,
    /// which is created exclusively: if anything is there, nothing is
    /// written and it throws `CocoaError.fileWriteFileExists`. When the copy
    /// fails for another reason, what it made at `target` (which was made by
    /// the copy, since it did not exist) is removed, and the error thrown.
    private static func copyExclusively(_ source: URL, to target: URL) throws {
        var flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_EXCL)
        if isFolder(source) {
            flags |= copyfile_flags_t(COPYFILE_RECURSIVE)
        }
        guard copyfile(source.path, target.path, nil, flags) != 0 else { return }
        let code = errno
        if code == EEXIST {
            throw targetExistsError(target)
        }
        // Not EEXIST, so the exclusive creation of `target` was ours.
        try? FileManager.default.removeItem(at: target)
        throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    /// The error for a move or copy onto a name that is taken.
    private static func targetExistsError(_ target: URL) -> CocoaError {
        CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: target.path, NSURLErrorKey: target])
    }

    /// A new, empty scratch folder: one the system keeps on the volume of the
    /// nearest folder above `target` that exists, so that the move is a
    /// rename, or, when the system makes none, a new folder "TextMouth Export
    /// <UUID>" in the temporary directory.
    private static func makeScratchFolder(near target: URL) throws -> URL {
        // The target's folder may not exist yet: its first folder that does.
        var existing = target.deletingLastPathComponent()
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            existing = existing.deletingLastPathComponent()
        }
        if let replacement = try? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: existing,
            create: true
        ) {
            return replacement
        }
        let fallback = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextMouth Export \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    /// Records in the debug log how an export ended: one line saying how
    /// many items were written, and one for each failure, naming the book.
    private static func logOutcome(_ outcome: BookExportOutcome, offers: [BookExportOffer]) {
        DiagnosticLog.event(
            .storage,
            "BOOK_EXPORT: exported \(outcome.exported.count) of the items chosen from \(offers.count) book(s) "
                + "to \(DiagnosticLog.loggablePath(outcome.destination)); \(outcome.failures.count) failed, "
                + "\(outcome.booksInCloud.count) book(s) in the cloud\(outcome.wasCancelled ? ", cancelled" : "")"
        )
        for failure in outcome.failures {
            DiagnosticLog.event(.storage, "BOOK_EXPORT_FAILED: \(failure.name): \(failure.reason)")
        }
    }

    // MARK: Reading Text

    /// The reading text of the book `title` whose text cache holds `bytes`,
    /// read from `url`, as plain text (`plainText(of:)`): its chapters as
    /// the reader parses them, a book without chapter markers being one
    /// chapter named after the book.
    /// - Throws: the error reading content.md as text throws, for bytes
    ///   that are not UTF-8.
    static func plainText(fromMarkdown bytes: Data, at url: URL, title: String) throws -> String {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: title, bookAuthor: "")
        return plainText(of: content.chapters)
    }

    /// `chapters` as plain text, as TextMouth reads them: each chapter's
    /// text under its title, the chapters apart by two blank lines, ending
    /// with a line break. A chapter whose text already begins with its
    /// title, as one opening with its heading does, is not given it again,
    /// and a chapter with no words is left out.
    static func plainText(of chapters: [Chapter]) -> String {
        let blocks = chapters.compactMap { chapter -> String? in
            let text = chapter.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard !title.isEmpty, !text.hasPrefix(title) else { return text }
            return "\(title)\n\n\(text)"
        }
        return blocks.isEmpty ? "" : blocks.joined(separator: "\n\n\n") + "\n"
    }

    // MARK: Names

    /// The longest name, in UTF-8 bytes, this export gives a book: room
    /// beside it, within the 255 bytes a file name may have, for the words
    /// and extension added after it and a number making it unique.
    static let maximumStemByteCount = 180

    /// `title` as the start of an exported file's or folder's name
    /// (`safeFileName(_:fallback:)`), "Untitled" for a title with nothing
    /// left.
    static func fileNameStem(for title: String) -> String {
        safeFileName(title, fallback: "Untitled")
    }

    /// `name` made safe as one file or folder name: a slash or colon
    /// becomes a hyphen (Finder shows a colon as a slash), a control
    /// character becomes a space, runs of spaces become one, leading dots,
    /// which would hide the file, and white space (any Unicode White_Space,
    /// mixed with the dots in any order) go from the start, white space
    /// from the end, and the result is cut, between characters, to
    /// `maximumStemByteCount` bytes of UTF-8. `fallback` stands for a name
    /// with nothing left.
    static func safeFileName(_ name: String, fallback: String) -> String {
        var safe = ""
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                safe.unicodeScalars.append("-")
            } else if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
                safe.unicodeScalars.append(" ")
            } else {
                safe.unicodeScalars.append(scalar)
            }
        }
        safe = safe.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // Leading dots and white space go together, in whatever order they
        // come, so that ". .config" or "\u{00A0}.config" cannot leave a name
        // that begins with a dot (and is hidden in Finder).
        while let first = safe.first,
              first == "." || first.unicodeScalars.allSatisfy(\.properties.isWhitespace) {
            safe.removeFirst()
        }
        var cut = ""
        for character in safe {
            guard cut.utf8.count + String(character).utf8.count <= maximumStemByteCount else { break }
            cut.append(character)
        }
        cut = cut.trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? fallback : cut
    }

    /// Whether `url` is a folder, following a symbolic link to one.
    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

// MARK: - Unique Names

/// The names an export plan has taken in each folder, so no two files, and
/// no file and anything already there, share a name.
private struct UniqueNames {
    /// Whether something is already at a URL.
    let fileExists: (URL) -> Bool
    /// The names taken in each folder, by the folder's path, lowercased:
    /// the Mac's file systems ignore case in names by default.
    private var taken: [String: Set<String>] = [:]

    init(fileExists: @escaping (URL) -> Bool) {
        self.fileExists = fileExists
    }

    /// The first of `name`, "name 2", "name 3", and so on, before any
    /// extension, that is free in `folder`, taken from now on; its URL.
    mutating func claim(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var number = 1
        while true {
            let candidate = number == 1 ? name : (ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            let url = folder.appendingPathComponent(candidate)
            let key = candidate.lowercased()
            if !taken[folder.path, default: []].contains(key) && !fileExists(url) {
                taken[folder.path, default: []].insert(key)
                return url
            }
            number += 1
        }
    }
}
