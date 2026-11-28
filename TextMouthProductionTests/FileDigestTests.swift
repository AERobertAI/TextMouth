import CryptoKit
import XCTest
@testable import TextMouth

/// The streamed digest of a file (FR43): SHA-256 for a sync folder's blobs, and
/// the MD5 every import fingerprints by, from one loop.
final class FileDigestTests: XCTestCase {
    /// A folder of the test's own in the temporary folder, removed afterwards.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FileDigestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The SHA-256 and MD5 of "abc", the standard test text.
    func testKnownDigests() throws {
        let file = try makeFolder().appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try FileDigest.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try FileImportService.md5Hash(of: file), "900150983cd24fb0d6963f7d28e17f72")
    }

    /// A file of several chunks gives the digest of its whole.
    func testFileOfSeveralChunks() throws {
        let file = try makeFolder().appendingPathComponent("big.bin")
        let data = Data((0..<(FileDigest.chunkSize * 2 + 123)).map { UInt8(truncatingIfNeeded: $0) })
        try data.write(to: file)
        let expected = SHA256.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
        XCTAssertEqual(try FileDigest.sha256(of: file), expected)
    }

    /// An empty file has the digest of no bytes.
    func testEmptyFile() throws {
        let file = try makeFolder().appendingPathComponent("empty")
        try Data().write(to: file)
        XCTAssertEqual(try FileDigest.sha256(of: file), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    /// A folder is refused with its own error, never opened.
    func testFolderIsRefused() throws {
        let folder = try makeFolder()
        XCTAssertThrowsError(try FileDigest.sha256(of: folder)) {
            XCTAssertEqual($0 as? ContentFingerprintError, .notARegularFile)
        }
    }

    /// A file that is not there throws, and a failing read reaches the caller as an error.
    func testMissingFileAndFailingReadThrow() throws {
        let folder = try makeFolder()
        XCTAssertThrowsError(try FileDigest.sha256(of: folder.appendingPathComponent("none")))
        let file = folder.appendingPathComponent("f")
        try Data("x".utf8).write(to: file)
        struct Failure: Error {}
        XCTAssertThrowsError(try FileDigest.hex(of: file, using: SHA256.self, readingChunksWith: { _ in throw Failure() })) {
            XCTAssertTrue($0 is Failure)
        }
    }
}
