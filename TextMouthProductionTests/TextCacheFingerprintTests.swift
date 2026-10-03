import XCTest
@testable import TextMouth

/// The fingerprints a text cache records of its source and content.md, and
/// the rules for comparing them with the files (TODO T07): stamps first,
/// digests only when a file kept its size but not its modification time.
final class TextCacheFingerprintTests: XCTestCase {

    // MARK: - Stamps

    /// A stamp is the file's size and its modification time to the
    /// nanosecond, exactly as stat(2) reports them.
    func testStampHoldsSizeAndNanosecondModificationTime() throws {
        let file = try scratchFile("stamp.txt", contents: "twelve bytes")
        try setModificationTime(of: file, nanoseconds: 1_790_000_000_123_456_789)

        let stamp = try XCTUnwrap(FileStamp(of: file))

        XCTAssertEqual(stamp.byteCount, 12)
        XCTAssertEqual(stamp.modificationTimeNanoseconds, 1_790_000_000_123_456_789)
    }

    /// Nothing at the path, or a folder, has no stamp: only a regular file
    /// holds bytes to fingerprint.
    func testMissingFileAndFolderHaveNoStamp() throws {
        let folder = try scratchFolder()

        XCTAssertNil(FileStamp(of: folder.appendingPathComponent("missing.txt")))
        XCTAssertNil(FileStamp(of: folder))
    }

    /// A symbolic link is stamped as the file it leads to, as reading it
    /// reads that file.
    func testStampFollowsASymbolicLink() throws {
        let file = try scratchFile("target.txt", contents: "linked bytes")
        let link = file.deletingLastPathComponent().appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        XCTAssertEqual(FileStamp(of: link), FileStamp(of: file))
    }

    // MARK: - Comparing One File

    /// The recorded stamp compared with the file's stamp now: the same, a
    /// new modification time only, another size, or no file to examine.
    func testComparisonTellsWhatChanged() {
        let recorded = FileFingerprint(stamp: FileStamp(byteCount: 10, modificationTimeNanoseconds: 5), digest: "d")
        let redated = FileStamp(byteCount: 10, modificationTimeNanoseconds: 6)

        XCTAssertEqual(recorded.comparison(with: recorded.stamp), .same)
        XCTAssertEqual(recorded.comparison(with: redated), .redated(redated))
        XCTAssertEqual(recorded.comparison(with: FileStamp(byteCount: 11, modificationTimeNanoseconds: 5)), .resized)
        XCTAssertEqual(recorded.comparison(with: nil), .unexamined)
    }

    /// A fingerprint taken of a file stamps it and digests its bytes.
    func testFingerprintOfAFileRecordsItsStampAndDigest() throws {
        let file = try scratchFile("book.md", contents: "# Title\n\nWords.")

        let fingerprint = try XCTUnwrap(FileFingerprint(of: file, hasher: .md5))

        XCTAssertEqual(fingerprint.stamp, FileStamp(of: file))
        XCTAssertEqual(fingerprint.digest, try FileImportService.md5Hash(of: file))
        XCTAssertNil(FileFingerprint(of: file.appendingPathExtension("missing"), hasher: .md5))
    }

    // MARK: - Verifying a Cache

    /// Unchanged files are verified by their stamps alone: nothing is read.
    func testUnchangedFilesAreVerifiedWithoutReadingEither() throws {
        let files = try makeCacheFiles()
        let counter = CountingFingerprintHasher()

        let verification = try files.verify(with: counter.hasher)

        XCTAssertEqual(verification, .current(files.recorded))
        XCTAssertEqual(counter.count, 0)
    }

    /// A source with another size has changed, which takes no digest.
    func testResizedSourceIsStaleWithoutReadingIt() throws {
        let files = try makeCacheFiles()
        try "A replacement source, many bytes longer than the one it replaced.".write(to: files.source, atomically: true, encoding: .utf8)
        let counter = CountingFingerprintHasher()

        XCTAssertEqual(try files.verify(with: counter.hasher), .stale(.sourceChanged))
        XCTAssertEqual(counter.count, 0)
    }

    /// A source rewritten with the same bytes is read once, found unchanged,
    /// and the result carries its new modification time.
    func testRedatedSourceWithTheSameBytesIsCurrentWithItsNewStamp() throws {
        let files = try makeCacheFiles()
        try setModificationTime(of: files.source, nanoseconds: 1_800_000_000_000_000_001)
        let counter = CountingFingerprintHasher()

        let verification = try files.verify(with: counter.hasher)

        var restamped = files.recorded
        restamped.source = FileFingerprint(stamp: try XCTUnwrap(FileStamp(of: files.source)), digest: files.recorded.source.digest)
        XCTAssertEqual(verification, .current(restamped))
        XCTAssertEqual(counter.fileCount, 1)
    }

    /// A source of the same size with other bytes and a new modification
    /// time is read and found changed.
    func testRedatedSourceWithOtherBytesIsStale() throws {
        let files = try makeCacheFiles()
        try sameLengthReplacement(of: files.source)

        XCTAssertEqual(try files.verify(with: .md5), .stale(.sourceChanged))
    }

    /// A missing source is no reason to discard the cache: nothing could be
    /// extracted again, and the cache is the only copy of the text left.
    func testMissingSourceKeepsTheCache() throws {
        let files = try makeCacheFiles()
        try FileManager.default.removeItem(at: files.source)

        XCTAssertEqual(try files.verify(with: .md5), .current(files.recorded))
    }

    /// content.md with another size, or none at all, has changed.
    func testResizedOrMissingCacheIsStale() throws {
        let files = try makeCacheFiles()
        try "# Edited\n\nA longer cache than before.".write(to: files.cache, atomically: true, encoding: .utf8)
        XCTAssertEqual(try files.verify(with: .md5), .stale(.cacheChanged))

        try FileManager.default.removeItem(at: files.cache)
        XCTAssertEqual(try files.verify(with: .md5), .stale(.cacheChanged))
    }

    /// content.md rewritten with the same bytes is current with its new
    /// stamp; one rewritten with other bytes of the same length is stale.
    func testRedatedCacheIsCheckedByItsDigest() throws {
        let files = try makeCacheFiles()
        try setModificationTime(of: files.cache, nanoseconds: 1_800_000_000_000_000_002)
        var restamped = files.recorded
        restamped.cache = FileFingerprint(stamp: try XCTUnwrap(FileStamp(of: files.cache)), digest: files.recorded.cache.digest)
        let counter = CountingFingerprintHasher()
        XCTAssertEqual(try files.verify(with: counter.hasher), .current(restamped))
        XCTAssertEqual(counter.dataCount, 1, "content.md's digest comes from its bytes")

        try sameLengthReplacement(of: files.cache)
        XCTAssertEqual(try files.verify(with: .md5), .stale(.cacheChanged))
    }

    /// Only another size counts at startup, where nothing is read; a missing
    /// source does not, and a missing content.md does.
    func testResizedFilesAreFoundWithoutDigests() throws {
        let files = try makeCacheFiles()
        XCTAssertFalse(files.hasResizedFile())

        try setModificationTime(of: files.source, nanoseconds: 1_800_000_000_000_000_003)
        XCTAssertFalse(files.hasResizedFile(), "a new modification time alone needs a digest to judge")

        try "A replacement source, many bytes longer than the one it replaced.".write(to: files.source, atomically: true, encoding: .utf8)
        XCTAssertTrue(files.hasResizedFile())

        try FileManager.default.removeItem(at: files.source)
        XCTAssertFalse(files.hasResizedFile())

        try FileManager.default.removeItem(at: files.cache)
        XCTAssertTrue(files.hasResizedFile())
    }

    // MARK: - Hashing and Storage

    /// The production hasher spells MD5 as duplicate detection does, gives a
    /// file and its bytes the same digest, and refuses a folder instead of
    /// letting FileHandle raise an uncatchable exception on it.
    func testMD5HasherMatchesTheImportHashAndRefusesFolders() throws {
        let file = try scratchFile("hashed.txt", contents: "Bytes to hash 🙂")

        let digest = try FingerprintHasher.md5.digestOfFile(file)

        XCTAssertEqual(digest, try FileImportService.md5Hash(of: file))
        XCTAssertEqual(FingerprintHasher.md5.digestOfData(try Data(contentsOf: file)), digest)
        XCTAssertThrowsError(try FingerprintHasher.md5.digestOfFile(file.deletingLastPathComponent())) { error in
            XCTAssertEqual(error as? ContentFingerprintError, .notARegularFile)
        }
    }

    /// A fingerprint survives JSON exactly, nanoseconds included, so a book
    /// reloaded from its record still matches its unchanged files.
    func testFingerprintRoundTripsThroughJSONExactly() throws {
        let fingerprint = TextCacheFingerprint(
            source: FileFingerprint(
                stamp: FileStamp(byteCount: 524_288, modificationTimeNanoseconds: 1_790_995_242_878_781_194),
                digest: "9e107d9d372bb6826bd81d3542a419d6"
            ),
            cache: FileFingerprint(
                stamp: FileStamp(byteCount: 1_024, modificationTimeNanoseconds: -1),
                digest: "e4d909c290d0fb1ca068ffaddf22cbd0"
            )
        )

        let decoded = try JSONDecoder().decode(TextCacheFingerprint.self, from: JSONEncoder().encode(fingerprint))

        XCTAssertEqual(decoded, fingerprint)
    }

    // MARK: - Fixtures

    /// A source and its content.md in `folder`, with the fingerprint
    /// recorded of both as they were written.
    private struct CacheFiles {
        let source: URL
        let cache: URL
        let recorded: TextCacheFingerprint

        init(in folder: URL) throws {
            source = folder.appendingPathComponent("book.md")
            cache = folder.appendingPathComponent("content.md")
            try "# Source\n\nThe source's words.".write(to: source, atomically: true, encoding: .utf8)
            try "# Source\n\nThe cached words.".write(to: cache, atomically: true, encoding: .utf8)
            recorded = TextCacheFingerprint(
                source: try XCTUnwrap(FileFingerprint(of: source, hasher: .md5)),
                cache: try XCTUnwrap(FileFingerprint(of: cache, hasher: .md5))
            )
        }

        /// Verifies the files as a load does, reading content.md's bytes for
        /// its digest only when asked.
        func verify(with hasher: FingerprintHasher) throws -> TextCacheVerification {
            try recorded.verify(
                sourceURL: source,
                sourceStamp: FileStamp(of: source),
                cacheStamp: FileStamp(of: cache),
                cacheDigest: { hasher.digestOfData(try Data(contentsOf: cache)) },
                hasher: hasher
            )
        }

        /// Whether either file now has another size than recorded.
        func hasResizedFile() -> Bool {
            recorded.hasResizedFile(sourceStamp: FileStamp(of: source), cacheStamp: FileStamp(of: cache))
        }
    }

    /// A source and its content.md in a new scratch folder, fingerprinted.
    private func makeCacheFiles() throws -> CacheFiles {
        try CacheFiles(in: scratchFolder())
    }

    /// A file named `name` holding `contents` in a new scratch folder.
    private func scratchFile(_ name: String, contents: String) throws -> URL {
        let file = try scratchFolder().appendingPathComponent(name)
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// A new, empty folder under the temporary directory, removed when the
    /// test ends.
    private func scratchFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextCacheFingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

// MARK: - Shared Test Support

/// A fingerprint hasher that computes MD5 digests as production does and
/// counts every digest it computes, so a test can prove which checks read a
/// file and which compare stamps alone.
final class CountingFingerprintHasher: @unchecked Sendable {
    /// Guards both counts, which digests computed on any queue update.
    private let lock = NSLock()
    private var files = 0
    private var data = 0

    /// Digests computed by reading a file.
    var fileCount: Int { locked { files } }
    /// Digests computed of bytes already in memory.
    var dataCount: Int { locked { data } }
    /// Every digest computed.
    var count: Int { locked { files + data } }

    /// The hasher to pass to the code under test.
    var hasher: FingerprintHasher {
        FingerprintHasher(
            digestOfFile: { [self] url in
                locked { files += 1 }
                return try FingerprintHasher.md5.digestOfFile(url)
            },
            digestOfData: { [self] bytes in
                locked { data += 1 }
                return FingerprintHasher.md5.digestOfData(bytes)
            }
        )
    }

    /// Runs `body` while holding the lock.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Sets when the file at `url` was last modified (and accessed) to
/// `nanoseconds` since 1970, to the nanosecond, as `touch` or a copy that
/// keeps dates would.
func setModificationTime(of url: URL, nanoseconds: Int64) throws {
    let time = timespec(tv_sec: Int(nanoseconds / 1_000_000_000), tv_nsec: Int(nanoseconds % 1_000_000_000))
    var times = [time, time]
    let result = url.withUnsafeFileSystemRepresentation { path in
        utimensat(AT_FDCWD, path, &times, 0)
    }
    if result != 0 {
        throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
    }
}

/// Rewrites the file at `url` with other bytes of exactly the same length,
/// by reversing its text, and gives it a new modification time, as an edit
/// would. The text must not read the same backwards.
func sameLengthReplacement(of url: URL) throws {
    let original = try String(contentsOf: url, encoding: .utf8)
    let replacement = String(original.reversed())
    precondition(replacement != original && replacement.utf8.count == original.utf8.count)
    try replacement.write(to: url, atomically: true, encoding: .utf8)
    try setModificationTime(of: url, nanoseconds: 1_900_000_000_000_000_000)
}
