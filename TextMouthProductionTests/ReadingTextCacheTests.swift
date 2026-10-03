import Darwin
import XCTest
@testable import TextMouth

/// The temporary reading-text cache (PERF22, `ReadingTextCache`): what it
/// keeps reads back exactly as it was kept, only under the key it was kept
/// for, never from a damaged or partial file, and only for a day after its
/// last use. Every file a test keeps is in a folder of the test's own inside
/// the hosted test sandbox.
final class ReadingTextCacheTests: XCTestCase {

    // MARK: - Reading Back What Was Kept

    /// Chapters kept are read back exactly: every title, every reading text
    /// byte for byte (emoji, combining marks, CR LF, other scripts, an empty
    /// chapter), and every heading with its level, label, chapter number,
    /// offset, and identity.
    func testKeptChaptersReadBackExactly() throws {
        let cache = try makeCache()
        let book = UUID()
        let key = Self.key()
        let chapters = Self.sampleChapters

        try cache.store(chapters, for: book, key: key)

        let read = try XCTUnwrap(found(cache.chapters(for: book, key: key)))
        XCTAssertEqual(read.count, chapters.count)
        for (number, (kept, original)) in zip(read, chapters).enumerated() {
            XCTAssertEqual(kept.title, original.title, "chapter \(number)")
            XCTAssertTrue(kept.text.utf8.elementsEqual(original.text.utf8), "chapter \(number)'s text")
            XCTAssertEqual(kept.headings, original.headings, "chapter \(number)'s headings")
            XCTAssertEqual(kept.headings.map(\.id), original.headings.map(\.id), "chapter \(number)'s heading IDs")
        }
    }

    /// A book is read back as often as it is asked for, and each store
    /// replaces what was kept for the book before.
    func testStoreReplacesWhatWasKept() throws {
        let cache = try makeCache()
        let book = UUID()
        let key = Self.key()
        try cache.store([Chapter(title: "Old", text: "Old words.")], for: book, key: key)

        try cache.store([Chapter(title: "New", text: "New words, more of them.")], for: book, key: key)

        XCTAssertEqual(try XCTUnwrap(found(cache.chapters(for: book, key: key))).map(\.title), ["New"])
        XCTAssertEqual(try XCTUnwrap(found(cache.chapters(for: book, key: key))).map(\.text), ["New words, more of them."])
    }

    /// A store leaves one file named by the book's ID, and no partial file.
    func testStoreLeavesOnlyTheBooksFile() throws {
        let cache = try makeCache()
        let book = UUID()

        try cache.store(Self.sampleChapters, for: book, key: Self.key())

        XCTAssertEqual(try fileNames(in: cache), ["\(book.uuidString).readingtext"])
        XCTAssertEqual(cache.url(for: book).lastPathComponent, "\(book.uuidString).readingtext")
    }

    // MARK: - What Is Kept

    /// Only the reading text of a content.md of at least the cache's
    /// minimum is kept; a smaller book is parsed at each open instead. The
    /// app keeps nothing under a megabyte.
    func testOnlyALargeEnoughContentMarkdownIsKept() throws {
        let cache = try makeCache(minimumContentByteCount: 1_000)
        let small = UUID()
        let large = UUID()
        let smallKey = Self.key(byteCount: 999)
        let largeKey = Self.key(byteCount: 1_000)

        try cache.store(Self.sampleChapters, for: small, key: smallKey)
        try cache.store(Self.sampleChapters, for: large, key: largeKey)

        XCTAssertFalse(cache.keeps(smallKey))
        XCTAssertTrue(cache.keeps(largeKey))
        XCTAssertEqual(try fileNames(in: cache), ["\(large.uuidString).readingtext"])
        XCTAssertEqual(ReadingTextCache.minimumContentByteCount, 1_048_576)
        XCTAssertEqual(ReadingTextCache.lifetime, 86_400)
    }

    // MARK: - Used Only for Its Key

    /// What was kept is used only for the very key it was kept for: another
    /// digest of content.md, another size, modification time, inode, or
    /// status-change time of the file, or another book title finds nothing,
    /// and the file is removed, as it can no longer be used.
    func testAnyOtherKeyFindsNothingAndRemovesTheFile() throws {
        let cache = try makeCache()
        let kept = Self.key()
        let others: [(String, ReadingTextKey)] = [
            ("digest", ReadingTextKey(contentDigest: "another", content: kept.content, bookTitle: kept.bookTitle)),
            ("size", Self.key(byteCount: kept.content.byteCount + 1)),
            ("modification time", Self.key(modified: kept.content.modificationTimeNanoseconds + 1)),
            ("status-change time", Self.key(changed: kept.content.statusChangeTimeNanoseconds + 1)),
            ("inode", Self.key(inode: kept.content.inode + 1)),
            ("title", ReadingTextKey(contentDigest: kept.contentDigest, content: kept.content, bookTitle: "Another Title")),
        ]
        for (difference, other) in others {
            let book = UUID()
            try cache.store(Self.sampleChapters, for: book, key: kept)

            XCTAssertTrue(isNone(cache.chapters(for: book, key: other)), "another \(difference)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: cache.url(for: book).path), "another \(difference)")
        }
    }

    /// What another build kept (another producer), or a file of another
    /// layout, is never read, and is removed.
    func testAnotherBuildsOrLayoutsFileFindsNothing() throws {
        let folder = try makeSandboxDirectory("ReadingTextCache")
        let earlier = ReadingTextCache(folder: folder, producer: "an earlier build", minimumContentByteCount: 0)
        let later = ReadingTextCache(folder: folder, producer: "a later build", minimumContentByteCount: 0)
        let book = UUID()
        try earlier.store(Self.sampleChapters, for: book, key: Self.key())

        XCTAssertTrue(isNone(later.chapters(for: book, key: Self.key())))
        XCTAssertFalse(FileManager.default.fileExists(atPath: later.url(for: book).path))

        // The same file with its layout number raised by one.
        try earlier.store(Self.sampleChapters, for: book, key: Self.key())
        var bytes = try Data(contentsOf: earlier.url(for: book))
        bytes[4] = bytes[4] &+ 1
        try bytes.write(to: earlier.url(for: book))
        XCTAssertTrue(isNone(earlier.chapters(for: book, key: Self.key())))
    }

    /// The app's producer names the content index's version and this build,
    /// so a build whose parser changed reads nothing an earlier build kept.
    func testTheAppsProducerNamesTheIndexVersionAndTheBuild() {
        let producer = ReadingTextCache.currentProducer
        let build = BuildIdentity.current

        XCTAssertTrue(producer.contains("index \(BookContentIndex.currentVersion)"), producer)
        XCTAssertTrue(producer.contains("build \(build.buildNumber)"), producer)
        XCTAssertTrue(producer.contains("commit \(build.gitCommit)"), producer)
        XCTAssertEqual(ReadingTextCache.shared.producer, producer)
    }

    // MARK: - Damaged Files

    /// A file that cannot be what the cache wrote is reported as damaged and
    /// removed, whatever is wrong with it, and reading it never stops the
    /// app: other bytes, an empty file, a cut-short header or text, a header
    /// that claims more than the file holds, text that is not UTF-8, and
    /// more bytes than the chapters hold.
    func testDamagedFilesAreReportedAndRemoved() throws {
        let cache = try makeCache()
        let key = Self.key()
        let damages: [(String, (Data) -> Data)] = [
            ("other bytes", { _ in Data("Not a reading text file at all.".utf8) }),
            ("an empty file", { _ in Data() }),
            ("a cut-short header", { $0.prefix(20) }),
            ("a cut-short text", { $0.dropLast(3) }),
            ("a header longer than the file", { bytes in
                var damaged = bytes
                damaged.replaceSubrange(8..<12, with: [0xFF, 0xFF, 0x00, 0x00])
                return damaged
            }),
            ("text that is not UTF-8", { bytes in
                var damaged = bytes
                damaged[damaged.count - 2] = 0xFF
                return damaged
            }),
            ("bytes after the chapters", { $0 + Data("extra".utf8) }),
        ]
        for (damage, damaging) in damages {
            let book = UUID()
            try cache.store(Self.sampleChapters, for: book, key: key)
            let url = cache.url(for: book)
            try damaging(try Data(contentsOf: url)).write(to: url)

            guard case .damaged(let reason) = cache.chapters(for: book, key: key) else {
                XCTFail("\(damage) was not found damaged")
                continue
            }
            XCTAssertFalse(reason.isEmpty, damage)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "\(damage) was kept")
        }
    }

    /// Nothing kept for a book finds nothing, and reports nothing.
    func testABookWithNothingKeptFindsNothing() throws {
        let cache = try makeCache()

        XCTAssertTrue(isNone(cache.chapters(for: UUID(), key: Self.key())))
    }

    // MARK: - Expiry

    /// Each use of a kept reading text moves its last use, the file's
    /// modification time, to now.
    func testUseMovesTheLastUseToNow() throws {
        let cache = try makeCache()
        let book = UUID()
        try cache.store(Self.sampleChapters, for: book, key: Self.key())
        try setModificationTime(of: cache.url(for: book), nanoseconds: Self.nanoseconds(hoursAgo: 20))

        XCTAssertNotNil(found(cache.chapters(for: book, key: Self.key())))

        let lastUse = try XCTUnwrap(modificationDate(of: cache.url(for: book)))
        XCTAssertLessThan(abs(lastUse.timeIntervalSinceNow), 60)
    }

    /// The sweep removes every file unused for a day or more, partial files
    /// a crash left included, and keeps the files used since.
    func testSweepRemovesOnlyFilesUnusedForADay() throws {
        let cache = try makeCache()
        let stale = UUID()
        let fresh = UUID()
        try cache.store(Self.sampleChapters, for: stale, key: Self.key())
        try cache.store(Self.sampleChapters, for: fresh, key: Self.key())
        let leftover = cache.folder.appendingPathComponent("\(stale.uuidString)-\(UUID().uuidString).partial")
        try Data("half a file".utf8).write(to: leftover)
        try setModificationTime(of: cache.url(for: stale), nanoseconds: Self.nanoseconds(hoursAgo: 25))
        try setModificationTime(of: leftover, nanoseconds: Self.nanoseconds(hoursAgo: 30))
        try setModificationTime(of: cache.url(for: fresh), nanoseconds: Self.nanoseconds(hoursAgo: 23))

        XCTAssertEqual(cache.removeExpired(), 2)

        XCTAssertEqual(try fileNames(in: cache), ["\(fresh.uuidString).readingtext"])
        XCTAssertEqual(cache.removeExpired(), 0, "nothing more to sweep")
    }

    /// The sweep at launch runs off the main thread, on the cache's queue,
    /// and removes what went unused for a day.
    func testSweepInBackgroundRemovesFilesUnusedForADay() throws {
        let cache = try makeCache()
        let stale = UUID()
        let fresh = UUID()
        try cache.store(Self.sampleChapters, for: stale, key: Self.key())
        try cache.store(Self.sampleChapters, for: fresh, key: Self.key())
        try setModificationTime(of: cache.url(for: stale), nanoseconds: Self.nanoseconds(hoursAgo: 26))

        cache.removeExpiredInBackground()
        ReadingTextCache.waitForBackgroundWork()

        XCTAssertEqual(try fileNames(in: cache), ["\(fresh.uuidString).readingtext"])
    }

    /// A sweep of a folder that was never made finds nothing to remove.
    func testSweepOfAMissingFolderRemovesNothing() throws {
        let folder = try makeSandboxDirectory("ReadingTextCache").appendingPathComponent("Never Made", isDirectory: true)

        XCTAssertEqual(ReadingTextCache(folder: folder).removeExpired(), 0)
    }

    /// A store in the background is written once the cache's queue has
    /// finished, and sweeps the files unused for a day as it goes.
    func testStoreInBackgroundWritesAndSweeps() throws {
        let cache = try makeCache()
        let stale = UUID()
        let book = UUID()
        try cache.store(Self.sampleChapters, for: stale, key: Self.key())
        try setModificationTime(of: cache.url(for: stale), nanoseconds: Self.nanoseconds(hoursAgo: 48))

        cache.storeInBackground(Self.sampleChapters, for: book, key: Self.key())
        ReadingTextCache.waitForBackgroundWork()

        XCTAssertEqual(try fileNames(in: cache), ["\(book.uuidString).readingtext"])
    }

    /// Removing a book's reading text removes its file, and removing one
    /// that was never kept does nothing.
    func testRemoveDeletesTheBooksFile() throws {
        let cache = try makeCache()
        let book = UUID()
        let other = UUID()
        try cache.store(Self.sampleChapters, for: book, key: Self.key())
        try cache.store(Self.sampleChapters, for: other, key: Self.key())

        cache.remove(bookID: book)
        cache.remove(bookID: UUID())

        XCTAssertEqual(try fileNames(in: cache), ["\(other.uuidString).readingtext"])
    }

    // MARK: - Where It Lives

    /// The app's cache is in this Mac's Caches folder, which under hosted
    /// tests is inside the test sandbox, never in the data directory.
    func testTheAppsCacheIsInThisMacsCachesFolder() {
        let folder = ReadingTextCache.shared.folder

        XCTAssertEqual(folder, MachineLocalPaths.readingTextCache)
        XCTAssertTrue(folder.path.hasPrefix(HostedTestSandbox.home.path + "/"))
        XCTAssertFalse(folder.path.hasPrefix(TextMouthPaths.root.path + "/"))
    }

    // MARK: - content.md's Identity

    /// A file's identity changes with any change to the file, even an edit
    /// that keeps its size and modification time, which only its
    /// status-change time then shows; and a file put in its place has
    /// another inode.
    func testContentIdentityChangesWithEveryChange() throws {
        let folder = try makeSandboxDirectory("ReadingTextIdentity")
        let file = folder.appendingPathComponent("content.md")
        try Data("# One\n\nThe words.".utf8).write(to: file)
        let original = try XCTUnwrap(ContentFileIdentity(of: file))
        let stamp = try XCTUnwrap(FileStamp(of: file))
        XCTAssertEqual(original.byteCount, stamp.byteCount)
        XCTAssertEqual(original.modificationTimeNanoseconds, stamp.modificationTimeNanoseconds)
        XCTAssertEqual(ContentFileIdentity(of: file), original, "unchanged")

        // The same size, with the modification time put back.
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("#".utf8))
        try handle.close()
        try setModificationTime(of: file, nanoseconds: original.modificationTimeNanoseconds)
        let edited = try XCTUnwrap(ContentFileIdentity(of: file))
        XCTAssertEqual(edited.byteCount, original.byteCount)
        XCTAssertEqual(edited.modificationTimeNanoseconds, original.modificationTimeNanoseconds)
        XCTAssertNotEqual(edited, original, "the status-change time shows the edit")

        // Another file put in its place.
        let replacement = folder.appendingPathComponent("replacement.md")
        try Data("# One\n\nThe words.".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: replacement, to: file)
        XCTAssertNotEqual(ContentFileIdentity(of: file)?.inode, original.inode)

        XCTAssertNil(ContentFileIdentity(of: folder), "a folder")
        XCTAssertNil(ContentFileIdentity(of: folder.appendingPathComponent("missing.md")), "nothing there")
    }

    // MARK: - Fixtures

    /// Chapters that exercise every part of the file: titles, an empty
    /// chapter, text in several scripts with emoji, combining marks, and
    /// CR LF, and headings of several levels, one carrying a chapter number.
    private static let sampleChapters: [Chapter] = [
        Chapter(
            title: "Opening — the Ferry",
            text: "The ferry left at noon.\r\nCafe\u{301} 👍🏽 한국어 مرحبا\n\nA second paragraph.",
            headings: [
                Heading(level: 1, text: "Opening — the Ferry", characterOffset: 0),
                Heading(level: 3, text: "A Café", chapterIndex: 4, characterOffset: 25),
            ]
        ),
        Chapter(title: "", text: "", headings: []),
        Chapter(title: "Third", text: String(repeating: "Lines of prose. ", count: 500), headings: [
            Heading(level: 2, text: "Third", characterOffset: 0),
        ]),
    ]

    /// A key for content.md with the given parts, made up but consistent.
    private static func key(
        byteCount: Int64 = 4_096,
        modified: Int64 = 1_759_500_000_000_000_000,
        changed: Int64 = 1_759_500_000_500_000_000,
        inode: UInt64 = 42_424_242
    ) -> ReadingTextKey {
        ReadingTextKey(
            contentDigest: "0123456789abcdef0123456789abcdef",
            content: ContentFileIdentity(
                byteCount: byteCount,
                modificationTimeNanoseconds: modified,
                statusChangeTimeNanoseconds: changed,
                inode: inode
            ),
            bookTitle: "The Salt Ledger"
        )
    }

    /// A cache of the test's own, in a sandbox folder removed when the test
    /// ends, keeping a book of any size unless told otherwise.
    private func makeCache(minimumContentByteCount: Int = 0) throws -> ReadingTextCache {
        ReadingTextCache(
            folder: try makeSandboxDirectory("ReadingTextCache"),
            producer: "ReadingTextCacheTests",
            minimumContentByteCount: minimumContentByteCount
        )
    }

    /// The chapters `lookup` found, or nil.
    private func found(_ lookup: ReadingTextLookup) -> [Chapter]? {
        if case .found(let chapters) = lookup { return chapters }
        return nil
    }

    /// Whether `lookup` found nothing worth reporting.
    private func isNone(_ lookup: ReadingTextLookup) -> Bool {
        if case .none = lookup { return true }
        return false
    }

    /// The names of the files in `cache`'s folder, sorted.
    private func fileNames(in cache: ReadingTextCache) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: cache.folder.path).sorted()
    }

    /// When the file at `url` was last modified.
    private func modificationDate(of url: URL) throws -> Date? {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    /// The time `hours` hours ago, in nanoseconds since 1970.
    private static func nanoseconds(hoursAgo hours: Double) -> Int64 {
        Int64((Date().timeIntervalSince1970 - hours * 3_600) * 1_000_000_000)
    }
}
