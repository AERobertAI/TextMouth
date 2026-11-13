import Foundation

// A temporary copy of the reading text of a large book this Mac opened
// lately (PERF22's second half). Opening a text book parses its content.md:
// swift-markdown and the plain-text walk over every chapter, about 30 ms a
// megabyte in the Release app, 0.7 s for a 25 MB anthology and 0.8 to 1.3 s
// for a 20 MB book in one chapter, with a transient peak of 5 to 22 times
// the text. The reading text that parse gives is kept here, so the next open
// of the same content.md reads it in a hundredth of the time instead.

// MARK: - The Identity of content.md

/// What stat(2) says about a book's content.md that any change to the file
/// changes: its size, its modification time, its inode number, and when its
/// status last changed. The status-change time (ctime) moves with every
/// write to the file and every change to its metadata, and, unlike the
/// modification time, which `touch -r` can put back, no program can set it.
/// A content.md whose identity is unchanged is the very file a cached
/// reading text was read from, even after an edit that kept its size and
/// date, which the text cache's own fingerprints take on trust (TODO T07).
struct ContentFileIdentity: Codable, Hashable, Sendable {
    /// The file's size in bytes.
    var byteCount: Int64
    /// When its content last changed, in nanoseconds since 1970.
    var modificationTimeNanoseconds: Int64
    /// When its content or metadata last changed, in nanoseconds since 1970.
    var statusChangeTimeNanoseconds: Int64
    /// Its inode number, which a file put in its place by a rename, a copy,
    /// or a download does not share.
    var inode: UInt64

    init(byteCount: Int64, modificationTimeNanoseconds: Int64, statusChangeTimeNanoseconds: Int64, inode: UInt64) {
        self.byteCount = byteCount
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
        self.statusChangeTimeNanoseconds = statusChangeTimeNanoseconds
        self.inode = inode
    }

    /// The identity of the regular file at `url`, following symbolic links
    /// as reading it does. Nil when nothing is there, when it is not a
    /// regular file, or when it cannot be examined.
    init?(of url: URL) {
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &status) == 0
        }
        guard examined, status.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(
            byteCount: Int64(status.st_size),
            modificationTimeNanoseconds: FileStamp.nanoseconds(since1970: status.st_mtimespec),
            statusChangeTimeNanoseconds: FileStamp.nanoseconds(since1970: status.st_ctimespec),
            inode: UInt64(status.st_ino)
        )
    }
}

// MARK: - The Key

/// Everything a book's reading text depends on apart from the code that read
/// it: the content.md it was read from, named both by the digest the book's
/// record keeps of it (`TextCacheFingerprint`) and by the file's identity,
/// and the book's title, which a book of one chapter without headings gives
/// its chapter (`MarkdownCacheService.parseMultiChapterMarkdown`). A cached
/// reading text is used only for the key it was stored under.
struct ReadingTextKey: Codable, Hashable, Sendable {
    /// The digest of the content.md the reading text was read from.
    var contentDigest: String
    /// That content.md's identity as it was stamped before it was read.
    var content: ContentFileIdentity
    /// The book's title when it was read.
    var bookTitle: String
}

// MARK: - Looking a Book Up

/// What looking for a book's cached reading text found.
enum ReadingTextLookup {
    /// The book's chapters, exactly as parsing its content.md gave them:
    /// each title, reading text, heading, and page.
    case found([Chapter])
    /// Nothing that can be used, and nothing worth reporting: no file, or
    /// one stored for another content.md, another title, another file
    /// layout, or another build of the app. Such a file is removed.
    case none
    /// A file that cannot be read as a cached reading text, for the reason
    /// given, in words for the debug log, which never name the book's text.
    /// It is removed.
    case damaged(String)
}

// MARK: - The Cache

/// This Mac's temporary copies of the reading text of the large books it
/// opened lately (PERF22), so that opening one again reads its chapters
/// instead of parsing its content.md.
///
/// - **What is kept:** every chapter's title, reading text, headings, and pages,
///   exactly as parsing content.md gave them, for a book whose content.md
///   holds at least `minimumContentByteCount` bytes. Smaller books parse in
///   a few tens of milliseconds and are never kept. Nothing about speech is
///   kept: substitution rules and speech settings apply after the reading
///   text, as the reader prepares each chapter, so no change to them can
///   make a kept reading text wrong.
/// - **When:** the reader stores a book's reading text, in the background,
///   after an open that parsed content.md and found it to match the record
///   of its book (`BookContentAnalysisService.load`); only the reader reads
///   and stores them, never an import or a maintenance pass.
/// - **What makes one unusable:** another content.md (another digest, or
///   the same file changed in any way since, by its `ContentFileIdentity`),
///   another book title, another layout of this file, or another build of
///   the app (`producer`), so a parser changed in a later build never serves
///   what an earlier one read. A file found unusable is removed. Redo Text
///   Extraction, and every other rewrite of content.md, removes the book's
///   file at once (`MarkdownCacheService`), as removing a book does.
/// - **How long:** a file is kept for `lifetime`, a day, after it was last
///   used: each use refreshes its modification time, and a sweep at launch
///   and after each store removes the files unused for longer.
/// - **Where:** in this Mac's Caches folder (`MachineLocalPaths.readingTextCache`),
///   one file per book named by the book's ID: never in the book's package,
///   which a cloud library would upload and download to every Mac, which
///   iCloud Drive syncs as one item, which a data-directory move copies, and
///   whose every file the File Size sort adds up. Moving a book, or the
///   whole data directory, leaves its ID and its file as they are. Nothing
///   here is ever in the cloud, so no use of the cache downloads anything.
///   Under hosted tests the folder is inside the test sandbox.
///
/// The file holds a fixed prefix (the bytes "TMRT", the file layout, and
/// the header's length, as little-endian 32-bit numbers), a JSON header
/// (who wrote it, its key, and each chapter's title, UTF-8 length,
/// headings, and pages), then every chapter's text as UTF-8, one after
/// another. It is written to a partial file and renamed into place, so a
/// reader never finds half a file under a book's name.
struct ReadingTextCache: Sendable {
    /// The app's cache, in this Mac's Caches folder.
    static let shared = ReadingTextCache(folder: MachineLocalPaths.readingTextCache)

    /// The smallest content.md, in bytes, whose reading text is kept: a
    /// megabyte, which the Release app parses in about 30 ms. Kept, the same
    /// reading text is read in under a millisecond; a smaller book, as the
    /// median book of the developer's library (0.7 MB) is, would save too
    /// little to be worth a file.
    static let minimumContentByteCount = 1_048_576

    /// How long a reading text is kept after its last use: a day, as the
    /// developer asked.
    static let lifetime: TimeInterval = 24 * 60 * 60

    /// The layout of the file this version writes. Raise it when the layout
    /// changes; a file of another layout is never read.
    /// 2: each chapter's pages (PG01).
    static let formatVersion: UInt32 = 2

    /// The extension of a book's file.
    static let fileExtension = "readingtext"

    /// The first bytes of every file.
    private static let magic = Data("TMRT".utf8)

    /// The length of the fixed prefix: the magic, the layout, and the
    /// header's length.
    private static let prefixLength = 12

    /// The longest header a file may claim, far beyond the largest book's
    /// (1,447 chapters and headings take about 150 KB), so a damaged length
    /// can never make a read allocate gigabytes.
    private static let maximumHeaderLength = 64 * 1_048_576

    /// The queue stores and sweeps run on, one at a time, below the work
    /// the user waits for.
    private static let backgroundQueue = DispatchQueue(label: "com.textmouth.reading-text-cache", qos: .utility)

    /// The folder holding the files.
    let folder: URL
    /// Who writes the files, which reads only what the same producer wrote.
    let producer: String
    /// The smallest content.md whose reading text is kept.
    let minimumContentByteCount: Int
    /// How long a file is kept after its last use.
    let lifetime: TimeInterval

    /// A cache in `folder`. Tests pass a folder, producer, size, and
    /// lifetime of their own; the app uses `shared`.
    init(
        folder: URL,
        producer: String = Self.currentProducer,
        minimumContentByteCount: Int = Self.minimumContentByteCount,
        lifetime: TimeInterval = Self.lifetime
    ) {
        self.folder = folder
        self.producer = producer
        self.minimumContentByteCount = minimumContentByteCount
        self.lifetime = lifetime
    }

    /// This build's producer: the content index's version, raised whenever
    /// the reading text a content.md gives changes, and this build of the
    /// app, so that a build whose parser changed reads nothing an earlier
    /// build kept, even if the version was not raised. A Release build
    /// carries its build number, commit, and date (`BuildIdentity`); each
    /// new installation therefore starts its cache afresh.
    static var currentProducer: String {
        "index \(BookContentIndex.currentVersion); \(BuildIdentity.current.cacheProducer)"
    }

    /// Where the reading text of the book `bookID` is kept.
    func url(for bookID: UUID) -> URL {
        folder.appendingPathComponent(bookID.uuidString, isDirectory: false)
            .appendingPathExtension(Self.fileExtension)
    }

    /// Whether a reading text read from the content.md `key` describes is
    /// large enough to keep.
    func keeps(_ key: ReadingTextKey) -> Bool {
        key.content.byteCount >= Int64(minimumContentByteCount)
    }

    // MARK: Reading

    /// The reading text kept for the book `bookID` under exactly `key`. A
    /// file found is used again from now on, so its last use moves to now;
    /// a file that cannot be used for `key` is removed.
    func chapters(for bookID: UUID, key: ReadingTextKey) -> ReadingTextLookup {
        let url = url(for: bookID)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .none }
        let lookup = Self.read(from: handle, key: key, producer: producer)
        try? handle.close()
        switch lookup {
        case .found(let chapters):
            Self.markUsed(url)
            DiagnosticLog.trace(
                .storage,
                "readingTextCache: read book=\(bookID.uuidString.prefix(8)) chapters=\(chapters.count)"
            )
        case .none, .damaged:
            try? FileManager.default.removeItem(at: url)
        }
        return lookup
    }

    /// The chapters of the file `handle` reads, from its start, when they
    /// were stored by `producer` under `key`.
    private static func read(from handle: FileHandle, key: ReadingTextKey, producer: String) -> ReadingTextLookup {
        do {
            guard let prefix = try handle.read(upToCount: prefixLength), prefix.count == prefixLength,
                  prefix.prefix(magic.count) == magic else {
                return .damaged("it does not begin as a reading text file does")
            }
            guard number(at: magic.count, in: prefix) == formatVersion else { return .none }
            let headerLength = Int(number(at: magic.count + 4, in: prefix))
            guard headerLength <= maximumHeaderLength,
                  let headerData = try handle.read(upToCount: headerLength), headerData.count == headerLength else {
                return .damaged("its header is cut short")
            }
            let header: Header
            do {
                header = try JSONDecoder().decode(Header.self, from: headerData)
            } catch {
                return .damaged("its header cannot be decoded")
            }
            guard header.producer == producer, header.key == key else { return .none }

            var chapters: [Chapter] = []
            chapters.reserveCapacity(header.chapters.count)
            for (position, entry) in header.chapters.enumerated() {
                guard let text = try readText(byteCount: entry.byteCount, from: handle) else {
                    return .damaged("chapter \(position)'s text is cut short or is not UTF-8")
                }
                chapters.append(Chapter(
                    title: entry.title,
                    text: text,
                    headings: entry.headings.map(\.heading),
                    pages: entry.pages.map(\.page)
                ))
            }
            if let extra = try handle.read(upToCount: 1), !extra.isEmpty {
                return .damaged("it holds more than its chapters")
            }
            return .found(chapters)
        } catch {
            return .damaged("it cannot be read (\(ReaderWorkingCopies.describe(error)))")
        }
    }

    /// The next `byteCount` bytes `handle` reads, as UTF-8 text, or nil when
    /// fewer are there or they are not UTF-8. Each chapter is read and
    /// decoded on its own, so a read holds at most one chapter's bytes
    /// beside the text.
    private static func readText(byteCount: Int, from handle: FileHandle) throws -> String? {
        guard byteCount > 0 else { return byteCount == 0 ? "" : nil }
        guard let bytes = try handle.read(upToCount: byteCount), bytes.count == byteCount else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        // Decoding puts U+FFFD in place of what is not UTF-8, which nearly
        // always changes the byte count; the caller's check against the
        // index (each chapter's UTF-16 length and headings) comes after.
        return text.utf8.count == byteCount ? text : nil
    }

    /// The little-endian 32-bit number at `offset` in `data`.
    private static func number(at offset: Int, in data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    /// Moves the last use of the file at `url` to now: its modification
    /// time, which the sweep reads.
    private static func markUsed(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = utimes(path, nil)
        }
    }

    // MARK: Storing

    /// Keeps `chapters`, the reading text of the book `bookID` read from the
    /// content.md `key` describes, in place of anything kept for it before,
    /// when that content.md is large enough (`keeps(_:)`); otherwise does
    /// nothing. The file is written in full under a partial name, then
    /// renamed into place.
    func store(_ chapters: [Chapter], for bookID: UUID, key: ReadingTextKey) throws {
        guard keeps(key) else { return }
        let header = Header(
            producer: producer,
            key: key,
            chapters: chapters.map { chapter in
                ChapterEntry(
                    title: chapter.title,
                    byteCount: chapter.text.utf8.count,
                    headings: chapter.headings.map(HeadingEntry.init),
                    pages: chapter.pages.map(PageEntry.init)
                )
            }
        )
        let headerData = try JSONEncoder().encode(header)
        var start = Self.magic
        Self.append(Self.formatVersion, to: &start)
        Self.append(UInt32(headerData.count), to: &start)
        start.append(headerData)

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("\(bookID.uuidString)-\(UUID().uuidString).partial")
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: start) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try Self.append(chapters, toFileAt: partial)
            try SavedFile.renameReplacing(partial, url(for: bookID))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        DiagnosticLog.trace(
            .storage,
            "readingTextCache: stored book=\(bookID.uuidString.prefix(8)) chapters=\(chapters.count)"
        )
    }

    /// `store(_:for:key:)` on the cache's own queue, followed by a sweep of
    /// the files unused for longer than `lifetime`, so the open that parsed
    /// the book never waits for the write. A store that fails leaves the
    /// book to be parsed again at its next open.
    func storeInBackground(_ chapters: [Chapter], for bookID: UUID, key: ReadingTextKey) {
        guard keeps(key) else { return }
        let cache = self
        Self.backgroundQueue.async {
            do {
                try cache.store(chapters, for: bookID, key: key)
            } catch {
                DiagnosticLog.trace(
                    .storage,
                    "readingTextCache: store failed book=\(bookID.uuidString.prefix(8)) (\(ReaderWorkingCopies.describe(error)))"
                )
            }
            cache.removeExpired()
        }
    }

    /// Appends `value` to `data` as a little-endian 32-bit number.
    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Appends every chapter's text, as UTF-8, to the file at `url`.
    private static func append(_ chapters: [Chapter], toFileAt url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            for chapter in chapters {
                try handle.write(contentsOf: Data(chapter.text.utf8))
            }
        } catch {
            try? handle.close()
            throw error
        }
        try handle.close()
    }

    // MARK: Removing

    /// Removes the reading text kept for the book `bookID`, if any.
    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: url(for: bookID))
    }

    /// Removes every file in the folder unused for `lifetime` or longer by
    /// `now`: each by its modification time, which a use moves to the time
    /// of that use. A partial file a crash left behind goes the same way;
    /// one being written now is new, and stays.
    /// - Returns: How many files were removed.
    @discardableResult
    func removeExpired(now: Date = Date()) -> Int {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys)
        ) else { return 0 }
        var removed = 0
        for item in items {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let lastUse = values.contentModificationDate,
                  now.timeIntervalSince(lastUse) >= lifetime else { continue }
            if (try? FileManager.default.removeItem(at: item)) != nil {
                removed += 1
            }
        }
        if removed > 0 {
            DiagnosticLog.event(.storage, "READING_TEXT_CACHE_SWEPT: \(removed) unused for \(Int(lifetime / 3_600)) hours")
        }
        return removed
    }

    /// `removeExpired(now:)` on the cache's own queue, as the launch sweep
    /// runs it, off the main thread.
    func removeExpiredInBackground() {
        let cache = self
        Self.backgroundQueue.async {
            cache.removeExpired()
        }
    }

    /// Waits until every store and sweep already asked of any cache has
    /// finished. Tests call it before they look at the folder.
    static func waitForBackgroundWork() {
        backgroundQueue.sync {}
    }

    // MARK: The Header

    /// The JSON header of a file: who wrote it, its key, and its chapters.
    private struct Header: Codable {
        var producer: String
        var key: ReadingTextKey
        var chapters: [ChapterEntry]
    }

    /// One chapter in the header: its title, the length of its text in
    /// UTF-8 bytes, its headings, and its pages. The text follows the header.
    private struct ChapterEntry: Codable {
        var title: String
        var byteCount: Int
        var headings: [HeadingEntry]
        var pages: [PageEntry]
    }

    /// One heading of a chapter, as parsing gave it: its level, its label,
    /// the chapter number it carries, and where it starts in the chapter,
    /// in UTF-16 units. Its identity is made again from these, as the parse
    /// made it (`Heading.init(level:text:chapterIndex:characterOffset:)`).
    private struct HeadingEntry: Codable {
        var level: Int
        var text: String
        var chapterIndex: Int
        var characterOffset: Int

        /// The entry for `heading`.
        init(_ heading: Heading) {
            level = heading.level
            text = heading.text
            chapterIndex = heading.chapterIndex
            characterOffset = heading.characterOffset
        }

        /// The heading this entry describes.
        var heading: Heading {
            Heading(level: level, text: text, chapterIndex: chapterIndex, characterOffset: characterOffset)
        }
    }

    /// One page of a chapter, as parsing gave it (PG01): its label, the
    /// chapter number it carries, and where its first word starts in the
    /// chapter, in UTF-16 units.
    private struct PageEntry: Codable {
        var label: String
        var chapterIndex: Int
        var characterOffset: Int

        /// The entry for `page`.
        init(_ page: PageBreak) {
            label = page.label
            chapterIndex = page.chapterIndex
            characterOffset = page.characterOffset
        }

        /// The page this entry describes.
        var page: PageBreak {
            PageBreak(label: label, chapterIndex: chapterIndex, characterOffset: characterOffset)
        }
    }
}
