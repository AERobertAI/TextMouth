import Foundation

// MARK: - Reaching a Cloud Library's Files

/// How the background maintenance passes and the startup repair reach a
/// book's files, in a data directory that may be in a cloud folder (FR02).
///
/// There any of a book's files can be dataless: only its metadata is on
/// this Mac, and a read downloads it first, waiting on the network (Apple
/// TN3150, "Getting ready for dataless files"). Routine maintenance must
/// never pull the library back down, so it asks which of a book's files are
/// in the cloud before it reads the book (`fileInCloud(of:reading:)`), reads
/// through `read(_:_:)`, which leaves dataless files in the cloud, and
/// decides nothing from a check it could not make (`presence(of:)`). Every
/// "is this file dataless" question goes to `isDataless`.
///
/// The app uses `live`. Only a sync service makes dataless files, so a
/// hosted test passes an access of its own instead: one that names the
/// items it pretends are dataless, and the reads it refuses with `EDEADLK`,
/// as the system refuses the read of a dataless file inside
/// `DatalessFiles.withoutDownloading`.
struct MaintenanceFileAccess: Sendable {
    /// Whether the item at a URL is dataless. Answering reads nothing.
    let isDataless: @Sendable (URL) -> Bool
    /// Whether a read of the item at a URL is refused before it starts,
    /// as the system refuses the read of a dataless file. The app refuses
    /// nothing here: its refusals come from the system itself.
    let refusesRead: @Sendable (URL) -> Bool

    /// An access answering with `isDataless`, and refusing the reads
    /// `refusesRead` names: by default none.
    init(
        isDataless: @escaping @Sendable (URL) -> Bool,
        refusesRead: @escaping @Sendable (URL) -> Bool = { _ in false }
    ) {
        self.isDataless = isDataless
        self.refusesRead = refusesRead
    }

    /// The access the app uses: `DatalessFiles.isDataless`, and only the
    /// system's own refusals.
    static let live = MaintenanceFileAccess(isDataless: { DatalessFiles.isDataless($0) })

    // MARK: Reading

    /// Runs `body`, which reads the item at `url` or what is inside it, and
    /// returns what it returns. A read this access refuses throws first,
    /// with the error the system gives a refused read of a dataless file
    /// (`DatalessFiles.isDownloadRefusal` recognizes it).
    func read<Value>(_ url: URL, _ body: () throws -> Value) throws -> Value {
        if refusesRead(url) {
            throw Self.refusal(of: url)
        }
        return try body()
    }

    /// The error a read of the dataless file at `url` meets when dataless
    /// files are left in the cloud: `EDEADLK`, naming the file.
    static func refusal(of url: URL) -> POSIXError {
        POSIXError(.EDEADLK, userInfo: [NSFilePathErrorKey: url.path])
    }

    /// The hasher maintenance fingerprints with: MD5, as
    /// `FingerprintHasher.md5` computes it, with every file read for its
    /// digest read through `read(_:_:)`, so a dataless file is never
    /// downloaded for a digest and a refused read reaches digests too.
    var hasher: FingerprintHasher {
        FingerprintHasher(
            digestOfFile: { url in
                try read(url) { try FingerprintHasher.md5.digestOfFile(url) }
            },
            digestOfData: FingerprintHasher.md5.digestOfData
        )
    }

    // MARK: Checking Without Reading

    /// What is at `url`, following symbolic links as
    /// `FileManager.fileExists(atPath:)` does, checked with dataless files
    /// left in the cloud. An item that is there counts even when it is
    /// dataless: it is there, only not downloaded.
    ///
    /// A check that would have to look inside a dataless folder is
    /// `.inCloud`, never `.absent`, so nothing is decided from it: the
    /// system refuses such a lookup (`EDEADLK`), and an item missing from a
    /// folder this access calls dataless may only be missing from what this
    /// Mac knows of it. Any other failure is `.absent`, as
    /// `fileExists(atPath:)` has it.
    func presence(of url: URL) -> ItemPresence {
        let failure: Int32? = DatalessFiles.withoutDownloading {
            var status = stat()
            return url.withUnsafeFileSystemRepresentation { path -> Int32? in
                guard let path else { return ENOENT }
                return stat(path, &status) == 0 ? nil : errno
            }
        }
        guard let failure else { return .present }
        if failure == EDEADLK || hasDatalessFolder(above: url) {
            return .inCloud
        }
        return .absent
    }

    /// Whether the item at `url` is in the cloud: dataless itself, or behind
    /// a dataless folder, so that looking at it would download something.
    func isInCloud(_ url: URL) -> Bool {
        isDataless(url) || presence(of: url) == .inCloud
    }

    /// The first of `book`'s files that a pass reading its `files` would
    /// find in the cloud, or nil when every one it reads is on this Mac.
    /// Answering reads no file: it lists the book's package with dataless
    /// files left in the cloud and asks each item `isDataless`. A package
    /// that is itself in the cloud, or that cannot be listed without
    /// downloading, is the answer; a missing file is not in the cloud.
    func fileInCloud(of book: Book, reading files: MaintainedFiles) -> URL? {
        let source = book.bookFileURL
        guard !book.tmbDirectoryName.isEmpty else {
            // An old book without a package has only its own file to read.
            return files.contains(.content) ? itemInCloud(source) : nil
        }
        let package = book.tmbDirectory
        if isInCloud(package) {
            return package
        }
        var namedFiles: [URL] = []
        if files.contains(.record) {
            namedFiles.append(TextMouthPaths.bookInfoPath(in: package))
        }
        if files.contains(.textCache) {
            namedFiles.append(TextMouthPaths.contentMarkdownPath(in: package))
        }
        if let file = namedFiles.first(where: isInCloud) {
            return file
        }
        guard files.contains(.content) else { return nil }
        // The book's own content: its file wherever it is, and every content
        // file its package holds, which reading the book can open (a DAISY
        // book's many files, or a folder of audio tracks).
        if !Self.isItem(source, inside: package), let file = itemInCloud(source) {
            return file
        }
        return firstItemInCloud(inside: package, includingEntriesNamed: FileImportService.isPackageContentName)
    }

    /// Throws the refusal of the first of `book`'s files that a pass reading
    /// its `files` would find in the cloud (`fileInCloud(of:reading:)`), as
    /// a read of it would, so a pass stops before it reads a book, or before
    /// it commits what it read from files that went to the cloud meanwhile.
    func requireOnThisMac(_ book: Book, reading files: MaintainedFiles) throws {
        if let file = fileInCloud(of: book, reading: files) {
            throw Self.refusal(of: file)
        }
    }

    /// The item at `url` when it is in the cloud, or else the first item in
    /// the cloud inside it, when it is a folder; nil when none is. For a
    /// repair that copies or moves a whole package, every item counts.
    func itemInCloud(_ url: URL) -> URL? {
        if isInCloud(url) {
            return url
        }
        let isFolder = DatalessFiles.withoutDownloading {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        return isFolder ? firstItemInCloud(inside: url) : nil
    }

    /// The first item inside `folder`, at any depth, that is dataless, or
    /// the folder whose listing was refused; nil when there is none. Only
    /// the folder's own entries that `includes` accepts by name count, with
    /// everything inside them. Hidden items never count: no pass reads them.
    ///
    /// The folders are listed with dataless files left in the cloud, so the
    /// listing of a dataless folder is refused instead of downloaded; a
    /// folder whose reads this access refuses is refused the same way.
    private func firstItemInCloud(
        inside folder: URL,
        includingEntriesNamed includes: (String) -> Bool = { _ in true }
    ) -> URL? {
        if refusesRead(folder) {
            return folder
        }
        return DatalessFiles.withoutDownloading { () -> URL? in
            let refused = RefusedListing()
            guard let items = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    // Stop at a refused listing, which needed a download;
                    // pass over anything else, which is no cloud matter.
                    guard DatalessFiles.isDownloadRefusal(error) else { return true }
                    refused.note(url)
                    return false
                }
            ) else { return nil }
            for case let item as URL in items {
                if items.level == 1, !includes(item.lastPathComponent) {
                    items.skipDescendants()
                    continue
                }
                if isDataless(item) {
                    return item
                }
            }
            return refused.url
        }
    }

    /// Whether the item at `url` lies in a folder this access calls
    /// dataless, up to the data directory (or, for an item outside it, up to
    /// the volume's root). An item missing from such a folder may only be
    /// missing from what this Mac knows of it.
    private func hasDatalessFolder(above url: URL) -> Bool {
        let dataDirectory = TextMouthPaths.root.standardizedFileURL.path
        let stopsAtDataDirectory = Self.isItem(url, inside: TextMouthPaths.root)
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        return DatalessFiles.withoutDownloading {
            while folder.path.count > 1 {
                if isDataless(folder) {
                    return true
                }
                if stopsAtDataDirectory && folder.path == dataDirectory {
                    return false
                }
                folder.deleteLastPathComponent()
            }
            return false
        }
    }

    /// Whether `url` names an item inside the folder `folder`, comparing
    /// standardized paths.
    static func isItem(_ url: URL, inside folder: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/")
    }
}

/// What a check found at a path without reading what is there
/// (`MaintenanceFileAccess.presence(of:)`).
enum ItemPresence: Equatable, Sendable {
    /// Something is there, downloaded or dataless.
    case present
    /// Nothing is there.
    case absent
    /// The answer is in the cloud: the check would have had to look inside
    /// a dataless folder. Nothing may be decided from it.
    case inCloud
}

/// The listing a directory enumeration was refused, noted by its error
/// handler, which runs while the enumeration does.
private final class RefusedListing {
    /// The item whose listing was refused first, if any.
    private(set) var url: URL?

    /// Notes that the listing of `url` was refused, unless one already was.
    func note(_ url: URL) {
        if self.url == nil {
            self.url = url
        }
    }
}

// MARK: - What a Pass Reads

/// The files of a book that a maintenance pass reads (FR02), so the pass
/// can tell, before it reads anything, whether all of them are on this Mac.
struct MaintainedFiles: OptionSet, Sendable {
    let rawValue: Int

    /// The book's own content: its file, and every content file its package
    /// holds beside it, such as a DAISY book's files or a folder of audio
    /// tracks.
    static let content = MaintainedFiles(rawValue: 1 << 0)
    /// The text cache, content.md.
    static let textCache = MaintainedFiles(rawValue: 1 << 1)
    /// The book's record, bookInfo.json.
    static let record = MaintainedFiles(rawValue: 1 << 2)
    /// Everything a pass can read of a book.
    static let all: MaintainedFiles = [.content, .textCache, .record]
}

// MARK: - Books Left in the Cloud

/// The maintenance passes, as their log lines name them.
enum MaintenancePass: String, Sendable {
    /// The startup batch that brings every text cache up to date.
    case textCacheUpdate = "text cache update"
    /// Redo Text Extraction, from Storage settings.
    case textReextraction = "Redo Text Extraction"
    /// The statistics pass that follows the text caches.
    case statistics = "statistics"
    /// The startup repair of the library and its packages.
    case startupRepair = "startup repair"
}

/// The books a maintenance pass left as they are because their files are in
/// the cloud (FR02), each counted once, for the pass's one log line. A
/// skipped book is caught up the next time its files are on this Mac. The
/// workers of one pass record from several threads, so the tally is locked.
final class CloudSkips: @unchecked Sendable {
    /// The pass the tally belongs to.
    let pass: MaintenancePass
    /// Guards `items`.
    private let lock = NSLock()
    /// What was left in the cloud: books by ID, and packages no row lists by
    /// path.
    private var items: Set<String> = []

    /// An empty tally for `pass`.
    init(_ pass: MaintenancePass) {
        self.pass = pass
    }

    /// Counts `book`, once however often it is recorded.
    func record(_ book: Book) {
        record(item: book.id.uuidString)
    }

    /// Counts the package at `package`, which no library row lists, once.
    func record(package: URL) {
        record(item: package.standardizedFileURL.path)
    }

    /// How many books the pass left in the cloud.
    var count: Int {
        lock.withLock { items.count }
    }

    /// Writes the pass's one line, for example
    /// `MAINTENANCE_SKIPPED_IN_CLOUD: statistics: skipped 3 books whose
    /// files are not on this Mac`, when it left any book; nothing otherwise.
    func log() {
        let skipped = count
        guard skipped > 0 else { return }
        let books = CountWording.phrase(skipped, singular: "book whose files are", plural: "books whose files are")
        DiagnosticLog.event(
            .storage,
            "MAINTENANCE_SKIPPED_IN_CLOUD: \(pass.rawValue): skipped \(books) not on this Mac"
        )
    }

    /// Adds `item` to the tally.
    private func record(item: String) {
        lock.withLock { _ = items.insert(item) }
    }
}
