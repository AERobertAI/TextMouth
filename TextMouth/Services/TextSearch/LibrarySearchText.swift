import Foundation

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
///   or another producer: the content index's version, raised whenever the
///   reading text a content.md gives changes, and the parser's own reading of
///   a fixed sample (`parserFingerprint`), so a parser changed without that
///   version being raised still reads nothing an earlier one stored. A new
///   build of the app whose parser reads as before keeps the files.
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
/// partial file and renamed into place, so a search never finds half a file.
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

    /// A store in `folder`, reading only what `producer` wrote. Tests pass a
    /// folder of their own; the app uses `shared`.
    init(folder: URL, producer: String = Self.currentProducer) {
        self.folder = folder
        self.producer = producer
    }

    /// This build's producer: the file layout, the content index's version,
    /// and the parser's reading of a fixed sample.
    static var currentProducer: String {
        "layout \(formatVersion); index \(BookContentIndex.currentVersion); parser \(parserFingerprint)"
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
    /// that is damaged, is removed, so the caller stores the book afresh.
    func open(bookID: UUID, key: LibrarySearchTextKey) -> LibrarySearchTextFile? {
        let url = url(for: bookID)
        guard let file = LibrarySearchTextFile(url: url) else { return nil }
        guard let header = file.readHeader(), header.producer == producer, header.key == key else {
            file.close()
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        file.setChapters(header.chapters.map(\.chapter))
        return file
    }

    // MARK: Storing

    /// Keeps `book`, the search text of the book `bookID` read from the
    /// content.md `key` describes, in place of anything kept for it before.
    /// The file is written in full under a partial name, then renamed into
    /// place.
    func store(_ book: LibrarySearchTextBook, for bookID: UUID, key: LibrarySearchTextKey) throws {
        let header = Header(producer: producer, key: key, chapters: book.chapters.map(ChapterEntry.init))
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
            let handle = try FileHandle(forWritingTo: partial)
            do {
                try handle.seekToEnd()
                for text in book.texts {
                    try handle.write(contentsOf: Data(text.utf8))
                }
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
    /// content.md, which holds every construct the reader's parse reads: the
    /// chapter markers, headings of both kinds, emphasis, links, escapes and
    /// entities, code, lists, quotes, a table, HTML, heading annotations and
    /// page markers. A parser that reads any of them differently gives
    /// another digest, so no search reads what an older parser stored.
    /// Worked out once a run, in about a millisecond.
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

    <!-- heading: 2 Annotated destination -->
    A paragraph that a heading annotation names, with <!-- page: 12 --> a page inside.

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
    /// begin as a search text file of this layout does.
    fileprivate func readHeader() -> LibrarySearchTextStore.Header? {
        guard let prefix = read(count: 12, at: 0), prefix.count == 12,
              prefix.prefix(4) == Data("TMLS".utf8),
              Self.number(at: 4, in: prefix) == LibrarySearchTextStore.formatVersion else { return nil }
        let headerLength = Self.number(at: 8, in: prefix)
        guard headerLength <= 64 * 1_048_576,
              let headerData = read(count: Int(headerLength), at: 12), headerData.count == Int(headerLength),
              let header = try? JSONDecoder().decode(LibrarySearchTextStore.Header.self, from: headerData) else {
            return nil
        }
        textStart = 12 + Int64(headerLength)
        return header
    }

    /// Takes `chapters`, the chapters the checked header describes, and
    /// works out where each one's text begins.
    fileprivate func setChapters(_ chapters: [LibrarySearchTextChapter]) {
        self.chapters = chapters
        var offset = textStart
        chapterOffsets = chapters.map { chapter in
            defer { offset += Int64(chapter.byteCount) }
            return offset
        }
    }

    /// The UTF-8 text of chapter `index`, read into `buffer`, which grows to
    /// hold it and is reused from chapter to chapter; false when the file is
    /// shorter than its header says.
    func readChapter(_ index: Int, into buffer: inout [UInt8]) -> Bool {
        guard chapterOffsets.indices.contains(index) else { return false }
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
    /// false when the file ends first or a read fails.
    private static func readFully(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, count: Int, at offset: Int64) -> Bool {
        guard descriptor >= 0, count <= buffer.count, let base = buffer.baseAddress else { return false }
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
