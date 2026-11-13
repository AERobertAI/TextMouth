import Foundation
import XCTest
@testable import TextMouth

/// Search Library's search texts (`LibrarySearchTextStore`): what is kept
/// reads back exactly as the reader's parse gave it, only under the key and
/// producer it was kept for, never from a damaged or partial file, and the
/// sweep keeps only the files of the books the library holds. Every file a
/// test makes is in a folder of the test's own inside the hosted test
/// sandbox; none is in the user's library.
final class LibrarySearchTextStoreTests: XCTestCase {

    // MARK: - Fixtures

    /// A content.md of three chapters holding what the reader's parse reads:
    /// chapter markers, headings of both kinds, emphasis, a link, a table,
    /// and Unicode that makes UTF-16 offsets differ from characters and
    /// bytes: precomposed and combining accents, emoji with a skin-tone
    /// modifier, a ZWJ family, a flag, and a ligature.
    private static let contentMarkdown = [
        "<!-- chapter: The First Chapter -->",
        "# Opening Heading",
        "",
        "A paragraph with **strong** words, _emphasis_, and a [link](https://example.com/a).",
        "",
        "## Second Level",
        "",
        "| Name | Value |",
        "|------|------:|",
        "| one  | 1     |",
        "| two  | 2     |",
        "",
        "<!-- chapter: Caf\u{E9} and e\u{301}clair \u{1F44D}\u{1F3FD} -->",
        "Plain words: caf\u{E9}, cafe\u{301}, \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467} family, \u{1F1E8}\u{1F1E6} flag, \u{FB01}ne print.",
        "",
        "### A Heading After Emoji \u{1F642}",
        "",
        "More text under it.",
        "",
        "<!-- chapter: Third -->",
        "Just one more line of text.",
        "",
    ].joined(separator: "\n")

    /// The chapters the reader's parse makes of `contentMarkdown`.
    private func parsedChapters() -> [Chapter] {
        MarkdownCacheService.parseMultiChapterMarkdown(
            Self.contentMarkdown, bookTitle: "The Salt Ledger", bookAuthor: "Test Author"
        ).chapters
    }

    /// A key for content.md with the given parts, made up but consistent.
    private static func key(
        byteCount: Int64 = 4_096,
        modified: Int64 = 1_759_500_000_000_000_000,
        changed: Int64 = 1_759_500_000_500_000_000,
        inode: UInt64 = 42_424_242,
        title: String = "The Salt Ledger"
    ) -> LibrarySearchTextKey {
        LibrarySearchTextKey(
            content: ContentFileIdentity(
                byteCount: byteCount,
                modificationTimeNanoseconds: modified,
                statusChangeTimeNanoseconds: changed,
                inode: inode
            ),
            bookTitle: title
        )
    }

    /// A store of the test's own, in a sandbox folder removed when the test
    /// ends, writing and reading `producer`'s files (this build's by
    /// default).
    private func makeStore(producer: String = LibrarySearchTextStore.currentProducer) throws -> LibrarySearchTextStore {
        LibrarySearchTextStore(folder: try makeSandboxDirectory("LibrarySearchText"), producer: producer)
    }

    /// Two short chapters, for tests that need a file and not a parse.
    private static let shortChapters = [
        Chapter(title: "One", text: "Alpha beta."),
        Chapter(title: "Two", text: "Gamma delta."),
    ]

    /// The names of the files in `store`'s folder, sorted.
    private func fileNames(in store: LibrarySearchTextStore) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: store.folder.path).sorted()
    }

    /// Whether a file is at `url`.
    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Sets when the file at `url` was last modified.
    private func setModificationDate(of url: URL, to date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// The header's length a file's prefix claims, as its little-endian
    /// 32-bit number at byte 8.
    private func headerLength(in file: Data) -> Int {
        guard file.count >= 12 else { return 0 }
        return (8..<12).reversed().reduce(0) { $0 << 8 | Int(file[file.startIndex + $1]) }
    }

    // MARK: - Reading Back What Was Stored

    /// A book stored reads back exactly: every chapter's title, headings
    /// (level, text, chapter index, offset), UTF-8 and UTF-16 lengths, and
    /// the bytes of its text, whatever order the chapters are read in.
    func testStoredBookReadsBackExactlyAsParsed() throws {
        let store = try makeStore()
        let bookID = UUID()
        let key = Self.key()
        let parsed = parsedChapters()
        XCTAssertEqual(parsed.count, 3, "The fixture should parse into its three chapters; actual: \(parsed.map(\.title))")
        XCTAssertTrue(parsed.contains { !$0.headings.isEmpty }, "The fixture should hold headings")

        try store.store(LibrarySearchTextBook(parsed: parsed), for: bookID, key: key)

        let file = try XCTUnwrap(store.open(bookID: bookID, key: key), "A file stored under a key opens under it")
        defer { file.close() }
        XCTAssertEqual(file.chapters.count, parsed.count)
        var buffer: [UInt8] = []
        // Out of order, with one buffer reused, as workers read.
        for index in [2, 0, 1] {
            guard let expected = parsed[safe: index], let chapter = file.chapters[safe: index] else {
                XCTFail("Chapter \(index) is missing: the file has \(file.chapters.count), the parse \(parsed.count)")
                continue
            }
            XCTAssertEqual(chapter.title, expected.title, "chapter \(index)'s title")
            XCTAssertEqual(chapter.byteCount, expected.text.utf8.count, "chapter \(index)'s UTF-8 length")
            XCTAssertEqual(chapter.utf16Length, expected.text.utf16.count, "chapter \(index)'s UTF-16 length")
            XCTAssertEqual(
                chapter.headings.map(\.level), expected.headings.map(\.level), "chapter \(index)'s heading levels"
            )
            XCTAssertEqual(
                chapter.headings.map(\.text), expected.headings.map(\.text), "chapter \(index)'s heading texts"
            )
            XCTAssertEqual(
                chapter.headings.map(\.characterOffset), expected.headings.map(\.characterOffset),
                "chapter \(index)'s heading offsets"
            )
            XCTAssertEqual(
                chapter.headings.map(\.chapterIndex), expected.headings.map { _ in index },
                "chapter \(index)'s headings name their chapter"
            )
            XCTAssertTrue(file.readChapter(index, into: &buffer), "chapter \(index) should read")
            XCTAssertEqual(
                Array(buffer.prefix(chapter.byteCount)), Array(expected.text.utf8), "chapter \(index)'s bytes"
            )
            XCTAssertEqual(
                String(decoding: buffer.prefix(chapter.byteCount), as: UTF8.self), expected.text,
                "chapter \(index)'s text"
            )
        }
        XCTAssertEqual(
            file.chapters.flatMap(\.headings).count, parsed.flatMap(\.headings).count,
            "Every heading of the book is kept"
        )
    }

    /// The model the file is made from keeps each heading's offset within
    /// its chapter, as the reader's content index does.
    func testHeadingOffsetsStayWithinTheirChapter() {
        let chapters = [
            Chapter(title: "One", text: "Short", headings: [
                Heading(level: 1, text: "Past the end", chapterIndex: 0, characterOffset: 99),
                Heading(level: 2, text: "Before the start", chapterIndex: 0, characterOffset: -4),
                Heading(level: 2, text: "Inside", chapterIndex: 0, characterOffset: 2),
            ]),
        ]

        let book = LibrarySearchTextBook(parsed: chapters)

        XCTAssertEqual(book.chapters.first?.headings.map(\.characterOffset), [5, 0, 2], "Actual: \(String(describing: book.chapters.first?.headings.map(\.characterOffset)))")
        XCTAssertEqual(book.texts, ["Short"])
    }

    /// Storing again replaces what was kept, leaves no partial file behind,
    /// and makes a folder that is not there yet.
    func testStoringReplacesAndLeavesNoPartialFile() throws {
        let store = try makeStore()
        let nested = LibrarySearchTextStore(
            folder: store.folder.appendingPathComponent("a/b", isDirectory: true), producer: store.producer
        )
        let bookID = UUID()
        let key = Self.key()

        try nested.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: bookID, key: key)
        try nested.store(LibrarySearchTextBook(parsed: [Chapter(title: "Only", text: "Replaced text.")]), for: bookID, key: key)

        XCTAssertEqual(try fileNames(in: nested), ["\(bookID.uuidString).searchtext"], "One file, no partial file")
        XCTAssertEqual(nested.url(for: bookID).lastPathComponent, "\(bookID.uuidString).searchtext")
        let file = try XCTUnwrap(nested.open(bookID: bookID, key: key))
        defer { file.close() }
        XCTAssertEqual(file.chapters.map(\.title), ["Only"], "The second store replaced the first")
        var buffer: [UInt8] = []
        XCTAssertTrue(file.readChapter(0, into: &buffer))
        XCTAssertEqual(String(decoding: buffer.prefix(file.chapters.first?.byteCount ?? 0), as: UTF8.self), "Replaced text.")
    }

    /// Nothing stored for a book opens as nothing, with no error.
    func testABookNeverStoredOpensAsNothing() throws {
        let store = try makeStore()

        XCTAssertNil(store.open(bookID: UUID(), key: Self.key()))
    }

    /// An empty chapter reads, even into a buffer that has never held
    /// anything, as the search reads the first chapter of a book whose cover
    /// chapter has no text; an empty chapter must not end the search of the
    /// chapters after it.
    func testAnEmptyChapterReadsIntoAnEmptyBuffer() throws {
        let store = try makeStore()
        let bookID = UUID()
        let key = Self.key()
        let chapters = [Chapter(title: "Cover", text: ""), Chapter(title: "Text", text: "Words."), Chapter(title: "Blank", text: "")]
        try store.store(LibrarySearchTextBook(parsed: chapters), for: bookID, key: key)
        let file = try XCTUnwrap(store.open(bookID: bookID, key: key))
        defer { file.close() }

        var buffer: [UInt8] = []
        XCTAssertTrue(file.readChapter(0, into: &buffer), "An empty first chapter should read into a new buffer")
        XCTAssertTrue(file.readChapter(1, into: &buffer))
        XCTAssertEqual(String(decoding: buffer.prefix(6), as: UTF8.self), "Words.")
        XCTAssertTrue(file.readChapter(2, into: &buffer), "An empty last chapter should read")
        var fresh: [UInt8] = []
        XCTAssertTrue(file.readChapter(2, into: &fresh), "An empty chapter should read into a new buffer")
    }

    // MARK: - Files That Are Not Used

    /// A file is not used, and is removed, when asked for under another
    /// content.md identity or another title, or by another producer.
    func testAFileIsNotUsedForAnotherKeyOrProducer() throws {
        let book = LibrarySearchTextBook(parsed: Self.shortChapters)
        let key = Self.key()
        let otherProducer = "LibrarySearchTextStoreTests other producer"
        let cases: [(name: String, open: (LibrarySearchTextStore, UUID) -> LibrarySearchTextFile?)] = [
            ("another size", { $0.open(bookID: $1, key: Self.key(byteCount: key.content.byteCount + 1)) }),
            ("another modification time", { $0.open(bookID: $1, key: Self.key(modified: key.content.modificationTimeNanoseconds + 1)) }),
            ("another status-change time", { $0.open(bookID: $1, key: Self.key(changed: key.content.statusChangeTimeNanoseconds + 1)) }),
            ("another inode", { $0.open(bookID: $1, key: Self.key(inode: key.content.inode + 1)) }),
            ("another title", { $0.open(bookID: $1, key: Self.key(title: "A Different Title")) }),
            ("another producer", { store, id in
                LibrarySearchTextStore(folder: store.folder, producer: otherProducer).open(bookID: id, key: key)
            }),
        ]

        for (name, attempt) in cases {
            let store = try makeStore()
            let bookID = UUID()
            try store.store(book, for: bookID, key: key)
            XCTAssertTrue(exists(store.url(for: bookID)), "\(name): the file should be there before it is asked for")

            let file = attempt(store, bookID)

            XCTAssertNil(file, "\(name): a file kept for another key or producer must not open")
            XCTAssertFalse(exists(store.url(for: bookID)), "\(name): the unusable file should be removed")
        }
    }

    /// A file that cannot be what the store wrote is not used and is
    /// removed: another layout, a damaged prefix, a header cut short or too
    /// long to be true, a header that is not JSON, and files cut inside the
    /// prefix or empty.
    func testADamagedFileIsNotUsedAndIsRemoved() throws {
        let key = Self.key()
        let damages: [(name: String, damage: (Data) -> Data)] = [
            ("a damaged magic", { var file = $0; file[file.startIndex] = UInt8(ascii: "X"); return file }),
            ("another layout", { var file = $0; file.replaceSubrange(4..<8, with: [2, 0, 0, 0]); return file }),
            ("a header length no file may claim", { var file = $0; file.replaceSubrange(8..<12, with: [0xFF, 0xFF, 0xFF, 0xFF]); return file }),
            ("a header cut short", { file in file.prefix(12 + self.headerLength(in: file) / 2) }),
            ("a prefix cut short", { $0.prefix(7) }),
            ("an empty file", { _ in Data() }),
            ("a header that is not JSON", { file in
                let length = self.headerLength(in: file)
                var damaged = Data(file.prefix(12))
                damaged.append(Data(repeating: UInt8(ascii: "x"), count: length))
                damaged.append(file.dropFirst(12 + length))
                return damaged
            }),
            ("a header of JSON of another shape", { file in
                let length = self.headerLength(in: file)
                var damaged = Data(file.prefix(12))
                // The same length, so the prefix still tells the truth.
                damaged.append(Data("[1,2,3]".utf8) + Data(repeating: UInt8(ascii: " "), count: max(0, length - 7)))
                damaged.append(file.dropFirst(12 + length))
                return damaged
            }),
        ]

        for (name, damage) in damages {
            let store = try makeStore()
            let bookID = UUID()
            try store.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: bookID, key: key)
            let url = store.url(for: bookID)
            let original = try Data(contentsOf: url)
            XCTAssertGreaterThan(headerLength(in: original), 8, "\(name): the stored header should be readable to damage")
            try damage(original).write(to: url)

            let file = store.open(bookID: bookID, key: key)

            XCTAssertNil(file, "\(name): a damaged file must not open")
            XCTAssertFalse(exists(url), "\(name): a damaged file should be removed")
        }
    }

    /// A file whose header is intact but whose texts are shorter or longer
    /// than the header says is not used, and is removed: its lengths must add
    /// up to its size when it is opened (the review of November 13, finding
    /// 7), so a file cut short by a full disk or a crash is made again
    /// rather than searched as far as it goes.
    func testAFileShorterOrLongerThanItsHeaderSaysIsNotUsed() throws {
        let key = Self.key()
        let changes: [(name: String, change: (Data) -> Data)] = [
            ("cut five bytes short", { Data($0.dropLast(5)) }),
            ("five bytes too long", { $0 + Data("extra".utf8) }),
        ]
        for (name, change) in changes {
            let store = try makeStore()
            let bookID = UUID()
            try store.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: bookID, key: key)
            let url = store.url(for: bookID)
            try change(try Data(contentsOf: url)).write(to: url)

            XCTAssertNil(store.open(bookID: bookID, key: key), "\(name): the file opened")
            XCTAssertFalse(exists(url), "\(name): the file should be removed")
        }
    }

    /// A file cut short after it was opened, as another process could cut
    /// it, reads false for the chapters it can no longer give whole, so the
    /// search makes the book again; the chapters before stay readable.
    func testAChapterCutShortAfterTheFileOpenedReadsFalse() throws {
        let store = try makeStore()
        let bookID = UUID()
        let key = Self.key()
        try store.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: bookID, key: key)
        let url = store.url(for: bookID)
        let file = try XCTUnwrap(store.open(bookID: bookID, key: key), "the whole file should open")
        defer { file.close() }
        // The last chapter, "Gamma delta.", loses its final five bytes.
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size - 5))
        try handle.close()
        var buffer: [UInt8] = []

        XCTAssertTrue(file.readChapter(0, into: &buffer), "The first chapter is whole")
        XCTAssertEqual(String(decoding: buffer.prefix(file.chapters.first?.byteCount ?? 0), as: UTF8.self), "Alpha beta.")
        XCTAssertFalse(file.readChapter(1, into: &buffer), "The last chapter is cut short")
        XCTAssertFalse(file.readChapter(2, into: &buffer), "There is no third chapter")
        XCTAssertFalse(file.readChapter(-1, into: &buffer), "There is no chapter before the first")
    }

    /// A file whose header decodes but gives a length no file can hold is
    /// not used, and is removed, never read: a negative UTF-8 or UTF-16
    /// length (a negative byte count trapped in the search until November
    /// 13, the review's finding 7), a UTF-16 length above the UTF-8 one, a
    /// count so large that adding it overflows, counts adding up to more than
    /// the file, and a heading of another chapter or past its chapter's end.
    /// The same rewrite with nothing changed opens, so it is the change each
    /// time that the store refuses.
    func testAHeaderWithLengthsNoFileCanHoldIsNotUsedAndIsRemoved() throws {
        let key = Self.key()
        let book = LibrarySearchTextBook(parsed: parsedChapters())
        let headed = try XCTUnwrap(book.chapters.firstIndex { !$0.headings.isEmpty }, "the fixture has no heading")
        let damages: [(name: String, damage: (inout [[String: Any]]) -> Void)] = [
            ("a negative byte count", { $0[0]["byteCount"] = -1 }),
            ("a negative UTF-16 length", { $0[0]["utf16Length"] = -1 }),
            ("a UTF-16 length above the byte count", { $0[0]["utf16Length"] = (($0[0]["byteCount"] as? Int) ?? 0) + 1 }),
            ("a byte count that overflows", { $0[0]["byteCount"] = Int.max }),
            ("byte counts adding up past the file", { $0[0]["byteCount"] = (($0[0]["byteCount"] as? Int) ?? 0) + 1 }),
            ("a heading of another chapter", { chapters in
                Self.changeFirstHeading(of: &chapters[headed]) { $0["chapterIndex"] = headed + 1 }
            }),
            ("a heading past its chapter's end", { chapters in
                let length = (chapters[headed]["utf16Length"] as? Int) ?? 0
                Self.changeFirstHeading(of: &chapters[headed]) { $0["characterOffset"] = length + 1 }
            }),
            ("a heading before its chapter's start", { chapters in
                Self.changeFirstHeading(of: &chapters[headed]) { $0["characterOffset"] = -1 }
            }),
        ]

        // The rewrite itself keeps a file whole.
        let control = try makeStore()
        let controlID = UUID()
        try control.store(book, for: controlID, key: key)
        try rewriteChapters(of: control.url(for: controlID)) { _ in }
        let opened = control.open(bookID: controlID, key: key)
        XCTAssertNotNil(opened, "a file whose header was rewritten unchanged should open")
        opened?.close()

        for (name, damage) in damages {
            let store = try makeStore()
            let bookID = UUID()
            try store.store(book, for: bookID, key: key)
            let url = store.url(for: bookID)
            try rewriteChapters(of: url, damage)

            let file = store.open(bookID: bookID, key: key)

            XCTAssertNil(file, "\(name): the file opened")
            file?.close()
            XCTAssertFalse(exists(url), "\(name): the file should be removed")
        }
    }

    /// Rewrites the chapters of the header of the store file at `url` as
    /// `change` makes them, keeping the texts after the header, and the
    /// prefix's header length true to the new header.
    private func rewriteChapters(of url: URL, _ change: (inout [[String: Any]]) -> Void) throws {
        let file = try Data(contentsOf: url)
        let length = headerLength(in: file)
        var header = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: file.subdata(in: 12..<(12 + length))) as? [String: Any],
            "the header is not a JSON object"
        )
        var chapters = try XCTUnwrap(header["chapters"] as? [[String: Any]], "the header has no chapters")
        change(&chapters)
        header["chapters"] = chapters
        let newHeader = try JSONSerialization.data(withJSONObject: header)
        var rewritten = Data(file.prefix(8))
        withUnsafeBytes(of: UInt32(newHeader.count).littleEndian) { rewritten.append(contentsOf: $0) }
        rewritten.append(newHeader)
        rewritten.append(file.dropFirst(12 + length))
        try rewritten.write(to: url)
    }

    /// Changes the first heading of `chapter`, a chapter of a header as JSON,
    /// as `change` says.
    private static func changeFirstHeading(of chapter: inout [String: Any], _ change: (inout [String: Any]) -> Void) {
        guard var headings = chapter["headings"] as? [[String: Any]], !headings.isEmpty else { return }
        change(&headings[0])
        chapter["headings"] = headings
    }

    /// A file closed reads nothing.
    func testAClosedFileReadsNothing() throws {
        let store = try makeStore()
        let bookID = UUID()
        let key = Self.key()
        try store.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: bookID, key: key)
        let file = try XCTUnwrap(store.open(bookID: bookID, key: key))
        var buffer: [UInt8] = []
        XCTAssertTrue(file.readChapter(0, into: &buffer))

        file.close()

        XCTAssertFalse(file.readChapter(0, into: &buffer), "A closed file has nothing to read")
        file.close()
    }

    // MARK: - Sweeping

    /// The sweep removes the files of books the library no longer holds and
    /// the partial files a stopped search left, and keeps the files of the
    /// books it holds, however old, and a partial file younger than the age.
    func testSweepRemovesOnlyFilesOfOtherBooksAndOldPartialFiles() throws {
        let store = try makeStore()
        let kept = UUID()
        let alsoKept = UUID()
        let gone = UUID()
        let key = Self.key()
        let book = LibrarySearchTextBook(parsed: Self.shortChapters)
        for id in [kept, alsoKept, gone] {
            try store.store(book, for: id, key: key)
        }
        let now = Date()
        let oldPartial = store.folder.appendingPathComponent("\(kept.uuidString)-\(UUID().uuidString).partial")
        let youngPartial = store.folder.appendingPathComponent("\(gone.uuidString)-\(UUID().uuidString).partial")
        try Data("half a file".utf8).write(to: oldPartial)
        try Data("half a file".utf8).write(to: youngPartial)
        try setModificationDate(of: oldPartial, to: now.addingTimeInterval(-3_600))
        try setModificationDate(of: youngPartial, to: now.addingTimeInterval(-30))
        // A kept book's file is kept however long ago it was written.
        try setModificationDate(of: store.url(for: kept), to: now.addingTimeInterval(-30 * 86_400))

        let removed = store.removeFiles(notFor: [kept, alsoKept], now: now, partialFileAge: 600)

        XCTAssertEqual(removed, 2, "The gone book's file and the old partial file; actual: \(removed)")
        XCTAssertEqual(
            try fileNames(in: store),
            ([alsoKept, kept].map { "\($0.uuidString).searchtext" } + [youngPartial.lastPathComponent]).sorted(),
            "Only the kept books' files and the young partial file should remain"
        )
        XCTAssertEqual(store.removeFiles(notFor: [kept, alsoKept], now: now, partialFileAge: 600), 0, "Nothing more to sweep")

        // Ten minutes on, the young partial file is old too.
        let later = now.addingTimeInterval(601)
        XCTAssertEqual(store.removeFiles(notFor: [kept, alsoKept], now: later, partialFileAge: 600), 1)
        XCTAssertEqual(try fileNames(in: store), [alsoKept, kept].map { "\($0.uuidString).searchtext" }.sorted())
    }

    /// A library that holds no book keeps no file, and a folder not made yet
    /// has nothing to sweep.
    func testSweepOfAnEmptyLibraryAndOfNoFolder() throws {
        let store = try makeStore()
        let first = UUID()
        let second = UUID()
        let key = Self.key()
        for id in [first, second] {
            try store.store(LibrarySearchTextBook(parsed: Self.shortChapters), for: id, key: key)
        }

        XCTAssertEqual(store.removeFiles(notFor: []), 2)
        XCTAssertEqual(try fileNames(in: store), [])

        let missing = LibrarySearchTextStore(
            folder: store.folder.appendingPathComponent("not-made-yet", isDirectory: true), producer: store.producer
        )
        XCTAssertEqual(missing.removeFiles(notFor: []), 0, "A folder that is not there has nothing to remove")
    }

    // MARK: - The Producer

    /// The parser's fingerprint is the same each time it is read and is 16
    /// hexadecimal digits.
    func testParserFingerprintIsStableAndSixteenHexDigits() {
        let first = LibrarySearchTextStore.parserFingerprint
        let second = LibrarySearchTextStore.parserFingerprint

        XCTAssertEqual(first, second, "The fingerprint should not change between reads")
        XCTAssertEqual(first.count, 16, "Actual: \(first)")
        XCTAssertNotNil(first.range(of: "^[0-9a-f]{16}$", options: .regularExpression), "Actual: \(first)")
        XCTAssertFalse(LibrarySearchTextStore.parserSample.isEmpty)
    }

    /// The producer names the file layout, the content index's version, this
    /// build of the app, and the parser's fingerprint, and a store made
    /// without one uses it. Keyed on the build as the reader's own cache is,
    /// so no parser change a new build makes serves text an earlier build
    /// stored, whatever the sample misses (the review of November 13,
    /// finding 2: the index's version was never raised for a parser change).
    func testCurrentProducerNamesTheLayoutTheIndexTheBuildAndTheParser() throws {
        let producer = LibrarySearchTextStore.currentProducer
        let build = BuildIdentity.current

        XCTAssertTrue(producer.contains("layout \(LibrarySearchTextStore.formatVersion)"), "Actual: \(producer)")
        XCTAssertTrue(producer.contains("index \(BookContentIndex.currentVersion)"), "Actual: \(producer)")
        XCTAssertTrue(producer.contains("build \(build.buildNumber)"), "Actual: \(producer)")
        XCTAssertTrue(producer.contains("commit \(build.gitCommit)"), "Actual: \(producer)")
        XCTAssertTrue(producer.contains("built \(build.buildDate)"), "Actual: \(producer)")
        XCTAssertTrue(producer.hasSuffix("parser \(LibrarySearchTextStore.parserFingerprint)"), "Actual: \(producer)")
        XCTAssertEqual(
            producer,
            "layout \(LibrarySearchTextStore.formatVersion); index \(BookContentIndex.currentVersion); "
                + "\(build.cacheProducer); parser \(LibrarySearchTextStore.parserFingerprint)"
        )
        XCTAssertEqual(try makeStore().producer, producer)
        XCTAssertEqual(LibrarySearchTextStore(folder: try makeSandboxDirectory("LibrarySearchText")).producer, producer)
    }

    /// A build is named by its version, build number, commit, and date, the
    /// one description both of this Mac's reading-text caches key on, so
    /// two Release builds never share a producer.
    func testABuildIsNamedByItsVersionNumberCommitAndDate() {
        let info = [
            "CFBundleShortVersionString": "9.8.7",
            "CFBundleVersion": "654",
            "TextMouthGitCommit": "0123abcd",
            "TextMouthBuildDate": "2026-12-01T08:00:00Z",
        ]
        let build = BuildIdentity(info: info, executablePath: nil)
        var later = info
        later["TextMouthGitCommit"] = "4567ef01"

        XCTAssertEqual(build.cacheProducer, "app 9.8.7 build 654 commit 0123abcd built 2026-12-01T08:00:00Z")
        XCTAssertNotEqual(build.cacheProducer, BuildIdentity(info: later, executablePath: nil).cacheProducer)
        XCTAssertTrue(
            ReadingTextCache.currentProducer.hasSuffix(BuildIdentity.current.cacheProducer),
            "the reader's cache keys on the same description: \(ReadingTextCache.currentProducer)"
        )
    }

    /// The sample the parser's fingerprint reads holds what ST05 changed the
    /// reading of, which the sample missed until November 13 (the review's
    /// finding 2): words after a page marker and after a heading annotation
    /// at the start of their line, a quote led by a page marker, and a page
    /// label written escaped. Each is read here as the parser reads it, so a
    /// sample that loses one fails rather than fingerprinting less.
    func testTheParserSampleHoldsTheConstructsAParserChangeReadsDifferently() {
        let chapters = MarkdownCacheService.parseMultiChapterMarkdown(
            LibrarySearchTextStore.parserSample, bookTitle: "Sample", bookAuthor: "Sample"
        ).chapters
        let text = chapters.map(\.text).joined(separator: "\n")
        let pages = chapters.flatMap(\.pages).map(\.label)
        let headings = chapters.flatMap(\.headings).map(\.text)

        XCTAssertEqual(chapters.count, 2, "chapters of the sample")
        XCTAssertTrue(text.contains("Words after a page marker at the start of their line."), "words after a leading page marker")
        XCTAssertTrue(text.contains("words after a heading annotation."), "words after a leading heading annotation")
        XCTAssertTrue(text.contains("A quoted line led by a page marker."), "a quote led by a page marker")
        for label in ["12", "13", "14", "A--3>"] {
            XCTAssertTrue(pages.contains(label), "page \(label) of the sample; pages: \(pages)")
        }
        for heading in ["Annotated destination", "Led by its marker"] {
            XCTAssertTrue(headings.contains(heading), "heading \(heading) of the sample; headings: \(headings)")
        }
    }
}
