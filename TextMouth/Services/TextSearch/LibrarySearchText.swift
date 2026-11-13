import Foundation
import os

// This Mac's copy of each book's reading text, kept for Search Library
// (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 2). Parsing content.md
// takes about 30 ms a megabyte in the Release app, so parsing a whole
// library of 677 MB at each search would take far longer than the five
// seconds a search may take; reading the reading text already parsed takes a
// fraction of that. Each book's file is made from the very parse the reader
// makes (`MarkdownCacheService.parseMultiChapterMarkdown`), so a search reads
// exactly the chapter texts Search in Book searches.

// MARK: - The Key

/// What a book's search text was read from: content.md's identity as it was
/// when it was read, and the book's title, which a book of one chapter
/// without headings gives its chapter
/// (`MarkdownCacheService.parseMultiChapterMarkdown`). A book's file is used
/// only for the key it was stored under, so any change to content.md, by Edit
/// Text, a rebuild, Redo Text Extraction, or a sync, makes it unusable.
struct LibrarySearchTextKey: Codable, Hashable, Sendable {
    /// content.md's identity: its size, its modification and status-change
    /// times, and its inode, taken before it was read.
    var content: ContentFileIdentity
    /// The book's title when it was read.
    var bookTitle: String
}

// MARK: - A Book's Chapters

/// One chapter of a book's search text, as its file's header describes it:
/// what Search Library needs to name where a match is, and where its text is.
struct LibrarySearchTextChapter: Equatable, Sendable {
    /// The chapter's title, as the reader names it.
    var title: String
    /// The length of the chapter's text in UTF-8 bytes. The texts follow
    /// the header in chapter order.
    var byteCount: Int
    /// The length of the chapter's text in UTF-16 units, TextMouth's text
    /// coordinates, so a search can say where each chapter begins in the
    /// book without counting the chapters it passes over.
    var utf16Length: Int
    /// The chapter's headings, each with this chapter's index and its UTF-16
    /// offset in the chapter's text, as the reader's heading list has them
    /// (`BookContentIndex.allHeadings`).
    var headings: [Heading]
}

/// A book's search text read into memory: what a search of a book just
/// parsed reads, and what a test compares a file with.
struct LibrarySearchTextBook: Sendable {
    /// Each chapter's title and headings, with the length of its text.
    let chapters: [LibrarySearchTextChapter]
    /// Each chapter's reading text, in order.
    let texts: [String]

    /// The search text of `chapters`, a book's chapters as parsing its
    /// content.md gave them: each heading takes its chapter's index and an
    /// offset kept within its chapter, as the reader's content index keeps
    /// it (`BookContentIndex.indexedHeadingOffset`).
    init(parsed chapters: [Chapter]) {
        texts = chapters.map(\.text)
        self.chapters = chapters.enumerated().map { index, chapter in
            let length = chapter.text.utf16Length
            return LibrarySearchTextChapter(
                title: chapter.title,
                byteCount: chapter.text.utf8.count,
                utf16Length: length,
                headings: chapter.headings.map { heading in
                    Heading(
                        level: heading.level,
                        text: heading.text,
                        chapterIndex: index,
                        characterOffset: BookContentIndex.indexedHeadingOffset(heading.characterOffset, chapterLength: length)
                    )
                }
            )
        }
    }
}

// MARK: - The Store

/// This Mac's search texts, one file for each book, named by the book's ID.
///
/// - **What is kept:** each chapter's title, headings, and reading text,
///   exactly as parsing the book's content.md gives them. Nothing is kept
///   about speech, which applies after the reading text.
/// - **When:** a search that finds a book's file missing or unusable parses
///   the book's content.md and stores its text (`LibrarySearchEngine`);
///   nothing else writes here.
/// - **What makes one unusable:** another content.md, by its identity, or
///   another title (`LibrarySearchTextKey`); another layout of this file;
///   or another producer (`currentProducer`): another content index version,
///   another build of the app, or another reading of a fixed sample by the
///   parser. The build is keyed on as the reader's `ReadingTextCache` keys on
///   it, since no version is raised for every change to what the parser
///   reads (the content index's stayed 1.0.0 through eleven parser changes
///   from September 1 to November 13, 2026), so no parser change can serve
///   text an earlier build stored: each new installation prepares the
///   library again, in the background (`LibrarySearchPreparer`). A
///   development build carries no commit or date, so there the sample's
///   reading (`parserFingerprint`) is what tells one parser from another.
/// - **Where:** in this Mac's Caches folder (`MachineLocalPaths.librarySearchText`),
///   never in the data directory: a cloud library would upload every file,
///   a data-directory move would copy them, and the File Size sort would
///   count them. macOS may empty the Caches folder when the disk runs low,
///   and Time Machine leaves it out; a search makes again what it lacks.
///   Under hosted tests the folder is inside the test sandbox.
///
/// A file holds a fixed prefix (the bytes "TMLS", the layout, and the
/// header's length, as little-endian 32-bit numbers), a JSON header (who
/// wrote it, its key, and each chapter's title, UTF-8 length, and headings),
/// then every chapter's text as UTF-8, one after another. It is written to a
/// partial file, synchronized to the disk, and renamed into place, so a
/// search never finds half a file; and a file is used only when the lengths
/// its header gives add up to its size, so a damaged one is made again,
/// never read past its end.
struct LibrarySearchTextStore: Sendable {
    /// The app's store, in this Mac's Caches folder.
    static var shared: LibrarySearchTextStore {
        LibrarySearchTextStore(folder: MachineLocalPaths.librarySearchText)
    }

    /// The layout of the file this version writes. Raise it when the layout
    /// changes; a file of another layout is never read.
    static let formatVersion: UInt32 = 1

    /// The extension of a book's file.
    static let fileExtension = "searchtext"

    /// The first bytes of every file.
    private static let magic = Data("TMLS".utf8)

    /// The length of the fixed prefix: the magic, the layout, and the
    /// header's length.
    private static let prefixLength = 12

    /// The longest header a file may claim, far beyond the largest book's,
    /// so a damaged length can never make a read allocate gigabytes.
    private static let maximumHeaderLength: UInt32 = 64 * 1_048_576

    /// The folder holding the files.
    let folder: URL
    /// Who writes the files, which reads only what the same producer wrote.
    let producer: String
    /// The room the store may take on the disk holding it, the app's
    /// free-space reserve kept.
    let space: LibrarySearchTextSpace

    /// A store in `folder`, reading only what `producer` wrote, and keeping
    /// a text only while `space` has room for it. Tests pass a folder of
    /// their own, and a space of their own to try a full disk; the app uses
    /// `shared`.
    init(folder: URL, producer: String = Self.currentProducer, space: LibrarySearchTextSpace = LibrarySearchTextSpace()) {
        self.folder = folder
        self.producer = producer
        self.space = space
    }

    /// Why a text was not kept.
    enum StoreError: Error, Equatable {
        /// Keeping it would leave less free on the disk than the app's
        /// reserve (`LibrarySearchTextSpace`); `needed` is the file's size.
        case notEnoughSpace(needed: Int64)
    }

    /// Whether a text of about `bytes` would be kept now: what a pass that
    /// prepares books ahead of a search asks before it parses one, so a full
    /// disk costs it no parse it could not keep.
    func hasRoom(forAbout bytes: Int64) -> Bool {
        space.hasRoom(for: bytes, in: folder)
    }

    /// This build's producer: the file layout, the content index's version,
    /// this build of the app (`BuildIdentity.cacheProducer`: a Release
    /// build's version, build number, commit, and date), and the parser's
    /// reading of a fixed sample.
    static var currentProducer: String {
        "layout \(formatVersion); index \(BookContentIndex.currentVersion); "
            + "\(BuildIdentity.current.cacheProducer); parser \(parserFingerprint)"
    }

    /// Where the search text of the book `bookID` is kept.
    func url(for bookID: UUID) -> URL {
        folder.appendingPathComponent(bookID.uuidString, isDirectory: false)
            .appendingPathExtension(Self.fileExtension)
    }

    // MARK: Reading

    /// The search text kept for the book `bookID` under exactly `key`, opened
    /// for reading, or nil when there is none that can be used. A file
    /// stored for another key, another layout, or another producer, or one
    /// that is damaged, its header unreadable or its lengths not adding up
    /// to its size (`LibrarySearchTextFile.setChapters(_:)`), is removed, so
    /// the caller stores the book afresh.
    func open(bookID: UUID, key: LibrarySearchTextKey) -> LibrarySearchTextFile? {
        let url = url(for: bookID)
        guard let file = LibrarySearchTextFile(url: url) else { return nil }
        guard let header = file.readHeader(), header.producer == producer, header.key == key,
              file.setChapters(header.chapters.map(\.chapter)) else {
            file.close()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return file
    }

    // MARK: Storing

    /// Keeps `book`, the search text of the book `bookID` read from the
    /// content.md `key` describes, in place of anything kept for it before.
    /// The file is written in full under a partial name, then renamed into
    /// place. Throws `StoreError.notEnoughSpace`, writing nothing, when the
    /// file would leave the disk with less free than the app's reserve: the
    /// search goes on from the text it parsed, and keeps nothing.
    func store(_ book: LibrarySearchTextBook, for bookID: UUID, key: LibrarySearchTextKey) throws {
        let header = Header(producer: producer, key: key, chapters: book.chapters.map(ChapterEntry.init))
        let headerData = try JSONEncoder().encode(header)
        var start = Self.magic
        Self.append(Self.formatVersion, to: &start)
        Self.append(UInt32(headerData.count), to: &start)
        start.append(headerData)

        let size = book.texts.reduce(Int64(start.count)) { $0 + Int64($1.utf8.count) }
        guard space.take(size, in: folder) else { throw StoreError.notEnoughSpace(needed: size) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("\(bookID.uuidString)-\(UUID().uuidString).partial")
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: start) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: partial)
            do {
                try handle.seekToEnd()
                for text in book.texts {
                    try handle.write(contentsOf: Data(text.utf8))
                }
                // On the disk before the rename puts it in place, so a power
                // loss cannot leave a whole header over texts never written
                // (the review of November 13, finding 7).
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try SavedFile.renameReplacing(partial, url(for: bookID))
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
    }

    /// Appends `value` to `data` as a little-endian 32-bit number.
    private static func append(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Removing

    /// Removes the search text kept for the book `bookID`, if any: a file
    /// found damaged while it was read.
    func remove(bookID: UUID) {
        try? FileManager.default.removeItem(at: url(for: bookID))
    }

    /// Removes the file of every book not in `bookIDs`, the books the library
    /// holds now, and every partial file a search that stopped left behind,
    /// unless it was written in the last `partialFileAge` seconds by a search
    /// still under way.
    /// - Returns: How many files were removed.
    @discardableResult
    func removeFiles(notFor bookIDs: Set<UUID>, now: Date = Date(), partialFileAge: TimeInterval = 600) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var removed = 0
        for item in items {
            let name = item.deletingPathExtension().lastPathComponent
            let isBookFile = item.pathExtension == Self.fileExtension
            if isBookFile, let id = UUID(uuidString: name), bookIDs.contains(id) { continue }
            if !isBookFile {
                // A partial file, or anything else: only once it is old.
                let modified = (try? item.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                guard now.timeIntervalSince(modified) >= partialFileAge else { continue }
            }
            if (try? FileManager.default.removeItem(at: item)) != nil {
                removed += 1
            }
        }
        return removed
    }

    // MARK: The Header

    /// The JSON header of a file: who wrote it, its key, and its chapters.
    fileprivate struct Header: Codable {
        var producer: String
        var key: LibrarySearchTextKey
        var chapters: [ChapterEntry]
    }

    /// One chapter in the header: its title, the length of its text in UTF-8
    /// bytes and in UTF-16 units, and its headings. The text follows the
    /// header.
    fileprivate struct ChapterEntry: Codable {
        var title: String
        var byteCount: Int
        var utf16Length: Int
        var headings: [HeadingEntry]

        /// The entry for `chapter`.
        init(_ chapter: LibrarySearchTextChapter) {
            title = chapter.title
            byteCount = chapter.byteCount
            utf16Length = chapter.utf16Length
            headings = chapter.headings.map(HeadingEntry.init)
        }

        /// The chapter this entry describes.
        var chapter: LibrarySearchTextChapter {
            LibrarySearchTextChapter(
                title: title, byteCount: byteCount, utf16Length: utf16Length, headings: headings.map(\.heading)
            )
        }
    }

    /// One heading of a chapter: its level, its label, its chapter's index,
    /// and where it starts in the chapter, in UTF-16 units. Its identity is
    /// made again from these, as the parse made it.
    fileprivate struct HeadingEntry: Codable {
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

    // MARK: The Parser's Fingerprint

    /// A digest of the reading text the parser gives a fixed sample of
    /// content.md, which holds the constructs the reader's parse reads: the
    /// chapter markers, headings of both kinds, emphasis, links, escapes and
    /// entities, code, lists, quotes, a table, HTML, heading annotations and
    /// page markers, a line led by a marker and followed by words (ST05), a
    /// quote led by one, and a page label written escaped. A parser that
    /// reads any of them differently gives another digest. It is what tells
    /// one parser from another where the build cannot (a development build);
    /// a parser change it misses is still caught by the build's identity
    /// (`currentProducer`). Worked out once a run, in about a millisecond.
    static let parserFingerprint: String = {
        let chapters = MarkdownCacheService.parseMultiChapterMarkdown(
            parserSample, bookTitle: "Sample", bookAuthor: "Sample"
        ).chapters
        var digest = FNV1a64()
        for chapter in chapters {
            digest.add(chapter.title)
            digest.add(chapter.text)
            for heading in chapter.headings {
                digest.add("\(heading.level) \(heading.characterOffset) \(heading.text)")
            }
            for page in chapter.pages {
                digest.add("\(page.characterOffset) \(page.label)")
            }
        }
        return digest.hex
    }()

    /// The sample `parserFingerprint` parses: two chapters of the constructs
    /// content.md holds.
    static let parserSample = """
    <!-- chapter: The First Chapter -->
    # A Heading with *emphasis* and `code`

    A paragraph with **strong** words, _emphasis_, a [link](https://example.com/a) and an ![image](a.png),
    an escaped \\*star\\*, an entity &amp; &eacute; &#x263A;, and a hard break\\
    after a backslash.

    Setext Heading
    --------------

    > A quoted line,
    > and another.

    1. One item
    2. Another, with a <span>tag</span> inside

    - A bullet
      continued

    | Name | Value |
    |------|------:|
    | one  | 1     |
    | two  |       |

        indented code
        block

    ```swift
    let fenced = "code"
    ```

    <div>An HTML block</div>

    <!-- textmouth-heading: eyJsZXZlbCI6MiwidGV4dCI6IkFubm90YXRlZCBkZXN0aW5hdGlvbiJ9 -->
    A paragraph that a heading annotation names, with <!-- page: 12 --> a page inside.

    <!-- page: 13 --> Words after a page marker at the start of their line.
    <!-- textmouth-heading: eyJsZXZlbCI6MywidGV4dCI6IkxlZCBieSBpdHMgbWFya2VyIn0= --> words after a heading annotation.

    > <!-- page: 14 --> A quoted line led by a page marker.

    A page whose label is written escaped, <!-- page: A-%2D3%3E --> in a paragraph.

    ***

    <!-- chapter: Second, with words after the marker --> and words on its line
    Café, naïve, Straße, ﬁne, 👍🏽, e\u{301}clair; tabs\tand  spaces.
    """
}

// MARK: - An Open File

/// One book's search text file, open for reading: its chapters, and their
/// texts read one at a time. Used by one search worker at a time, and closed
/// when the worker is done with the book.
final class LibrarySearchTextFile {
    /// The file's chapters, set once its header has been checked.
    private(set) var chapters: [LibrarySearchTextChapter] = []
    /// Where each chapter's text begins, in bytes from the file's start.
    private var chapterOffsets: [Int64] = []
    /// The file descriptor, or -1 once closed.
    private var descriptor: Int32
    /// Where the chapter texts begin, in bytes from the file's start.
    private var textStart: Int64 = 0

    /// Opens the file at `url` for reading; nil when it cannot be opened.
    init?(url: URL) {
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return nil }
        self.descriptor = descriptor
    }

    deinit {
        close()
    }

    /// Closes the file; reading anything afterwards finds nothing.
    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    /// The file's header, read from its start, or nil when the file does not
    /// begin as a search text file of this layout does, or claims a header
    /// longer than the file.
    fileprivate func readHeader() -> LibrarySearchTextStore.Header? {
        guard let prefix = read(count: 12, at: 0), prefix.count == 12,
              prefix.prefix(4) == Data("TMLS".utf8),
              Self.number(at: 4, in: prefix) == LibrarySearchTextStore.formatVersion else { return nil }
        let headerLength = Self.number(at: 8, in: prefix)
        // A damaged length is never read, however large: the file must hold it.
        guard headerLength <= 64 * 1_048_576, let size = fileSize(), 12 + Int64(headerLength) <= size,
              let headerData = read(count: Int(headerLength), at: 12), headerData.count == Int(headerLength),
              let header = try? JSONDecoder().decode(LibrarySearchTextStore.Header.self, from: headerData) else {
            return nil
        }
        textStart = 12 + Int64(headerLength)
        return header
    }

    /// Takes `chapters`, the chapters the checked header describes, and
    /// works out where each one's text begins, when every length they give
    /// is one the file can hold: no length below zero, no UTF-16 length above
    /// its UTF-8 length (each UTF-16 unit takes at least one byte of UTF-8),
    /// every heading within its own chapter, and the prefix, the header, and
    /// the texts adding up to the file's size exactly. Otherwise it takes
    /// nothing and returns false: such a file is damaged, cut short by a full
    /// disk or a crash, or holding a length a later read would trap on or
    /// allocate without bound for (the review of November 13, finding 7).
    fileprivate func setChapters(_ chapters: [LibrarySearchTextChapter]) -> Bool {
        guard let size = fileSize() else { return false }
        var end = textStart
        var offsets: [Int64] = []
        offsets.reserveCapacity(chapters.count)
        for (index, chapter) in chapters.enumerated() {
            guard chapter.byteCount >= 0, chapter.utf16Length >= 0, chapter.utf16Length <= chapter.byteCount,
                  chapter.headings.allSatisfy({
                      $0.chapterIndex == index && $0.characterOffset >= 0 && $0.characterOffset <= chapter.utf16Length
                  }) else { return false }
            offsets.append(end)
            let (next, overflowed) = end.addingReportingOverflow(Int64(chapter.byteCount))
            guard !overflowed, next <= size else { return false }
            end = next
        }
        guard end == size else { return false }
        self.chapters = chapters
        chapterOffsets = offsets
        return true
    }

    /// The size of the open file in bytes, or nil when it is closed or the
    /// system cannot tell.
    private func fileSize() -> Int64? {
        guard descriptor >= 0 else { return nil }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { return nil }
        return Int64(status.st_size)
    }

    /// The UTF-8 text of chapter `index`, read into `buffer`, which grows to
    /// hold it and is reused from chapter to chapter; false when the file
    /// holds less than its header says, as it can once cut short after it
    /// was opened.
    func readChapter(_ index: Int, into buffer: inout [UInt8]) -> Bool {
        guard chapterOffsets.indices.contains(index), chapters[index].byteCount >= 0 else { return false }
        let offset = chapterOffsets[index]
        let count = chapters[index].byteCount
        if buffer.count < count {
            buffer = [UInt8](repeating: 0, count: count)
        }
        return buffer.withUnsafeMutableBytes { raw -> Bool in
            Self.readFully(descriptor, into: raw, count: count, at: offset)
        }
    }

    /// `count` bytes at `offset`, or nil when fewer are there.
    private func read(count: Int, at offset: Int64) -> Data? {
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { raw -> Bool in
            Self.readFully(descriptor, into: raw, count: count, at: offset)
        }
        return complete ? data : nil
    }

    /// Reads exactly `count` bytes at `offset` of `descriptor` into the start
    /// of `buffer`, retrying a read that was interrupted or came back short;
    /// false when the file ends first or a read fails. Reading nothing, as
    /// for an empty chapter, succeeds at once, whatever the buffer: an empty
    /// buffer may have no address at all.
    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64) -> Bool {
        guard descriptor >= 0 else { return false }
        guard count > 0 else { return true }
        guard count <= buffer.count, let base = buffer.baseAddress else { return false }
        var done = 0
        while done < count {
            let got = pread(descriptor, base + done, count - done, off_t(offset + Int64(done)))
            if got > 0 {
                done += got
            } else if got < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    /// The little-endian 32-bit number at `offset` in `data`.
    private static func number(at offset: Int, in data: Data) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }
}

// MARK: - Room on the Disk

/// Whether the disk holding the search texts has room for one more, the
/// app's free-space reserve kept (`ArchiveLimits.freeSpaceReserve`, 1 GB, as
/// an import keeps it): the texts take about the size of the library's text
/// (650 MB for the user's), on the disk the system and the library also
/// write to, so on a nearly full disk a search keeps nothing and works from
/// what it parsed (the review of November 13, finding 10).
///
/// Asking the system for the free space can take milliseconds, too long to
/// ask for each of hundreds of books, so a reading is kept for
/// `readingLifetime` seconds, and what the store keeps meanwhile is counted
/// against it. When the system cannot tell, a text is kept, as an import
/// goes ahead.
final class LibrarySearchTextSpace: Sendable {
    /// What is known of the disk: its free space when last read (nil when the
    /// system could not tell), when that was, and the bytes kept since.
    private struct Reading: Sendable {
        var available: Int64?
        var takenAt: Date
        var keptSince: Int64 = 0
    }

    /// The bytes left free on the disk.
    let reserve: Int64
    /// How long a reading of the free space is used, in seconds.
    let readingLifetime: TimeInterval
    /// The free bytes on the disk holding a folder, or nil when the system
    /// cannot tell.
    private let freeSpace: @Sendable (URL) -> Int64?
    /// The time now.
    private let now: @Sendable () -> Date
    /// The latest reading, under its lock; nil before the first.
    private let reading = OSAllocatedUnfairLock<Reading?>(initialState: nil)

    /// A space keeping `reserve` bytes free, reading the free space with
    /// `freeSpace` at most once in each `readingLifetime` seconds of `now`.
    /// The app's are the defaults; tests pass a disk and a clock of their own.
    init(
        reserve: Int64 = ArchiveLimits.standard.freeSpaceReserve,
        readingLifetime: TimeInterval = 5,
        freeSpace: @escaping @Sendable (URL) -> Int64? = { ArchiveLimits.volumeFreeSpace(at: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.reserve = reserve
        self.readingLifetime = readingLifetime
        self.freeSpace = freeSpace
        self.now = now
    }

    /// Whether `bytes` more fit on the disk holding `folder` with the
    /// reserve kept; when they do, they are counted as kept.
    func take(_ bytes: Int64, in folder: URL) -> Bool {
        admits(bytes, in: folder, counting: true)
    }

    /// Whether `bytes` more would fit now, counting nothing.
    func hasRoom(for bytes: Int64, in folder: URL) -> Bool {
        admits(bytes, in: folder, counting: false)
    }

    /// Whether `bytes` more fit, from a reading no older than
    /// `readingLifetime`, taken afresh when there is none; counts them in
    /// when `counting` and they fit.
    private func admits(_ bytes: Int64, in folder: URL, counting: Bool) -> Bool {
        let time = now()
        let isFresh = reading.withLock { reading in
            reading.map { time.timeIntervalSince($0.takenAt) < readingLifetime } ?? false
        }
        if !isFresh {
            // Read outside the lock: the system can take a while to answer.
            let available = freeSpace(folder)
            reading.withLock { $0 = Reading(available: available, takenAt: time) }
        }
        return reading.withLock { reading in
            guard var current = reading, let available = current.available else { return true }
            guard available - reserve - current.keptSince >= bytes else { return false }
            if counting {
                current.keptSince += bytes
                reading = current
            }
            return true
        }
    }
}

// MARK: - A Small Digest

/// The 64-bit FNV-1a digest of a sequence of strings, each followed by a
/// zero byte so that no two sequences run together: enough to tell one
/// parser's output from another's, not a cryptographic hash.
private struct FNV1a64 {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325

    /// Adds `text`'s UTF-8 bytes and a separator.
    mutating func add(_ text: String) {
        for byte in text.utf8 {
            value = (value ^ UInt64(byte)) &* 0x0000_0100_0000_01B3
        }
        value = (value ^ 0) &* 0x0000_0100_0000_01B3
    }

    /// The digest, as 16 hexadecimal digits.
    var hex: String {
        String(format: "%016llx", value)
    }
}
