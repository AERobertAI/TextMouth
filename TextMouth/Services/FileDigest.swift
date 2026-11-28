import CryptoKit
import Foundation

/// The digest of a file, streamed (FR43's blobs are named by SHA-256, and
/// every import fingerprints its file by MD5). One loop reads the file for
/// both, so a read that fails does so as a Swift error, never as the
/// Objective-C exception FileHandle's legacy readers raise when a disk is
/// unplugged, a share drops, or a cloud download fails mid-read.
enum FileDigest {
    /// How much of a file one read takes: a mebibyte.
    static let chunkSize = 1024 * 1024

    /// The digest of the file at `url` under `Hash`, as lowercase hexadecimal
    /// digits, from the chunks `readChunk` reads from the open file in turn
    /// until it gives nil or an empty chunk (the end of the file).
    /// - Throws: `ContentFingerprintError.notARegularFile` for a folder (an
    ///   RTFD is one), which is never opened; the error opening the file;
    ///   or the first error `readChunk` throws.
    static func hex<Hash: HashFunction>(
        of url: URL,
        using hash: Hash.Type,
        readingChunksWith readChunk: (FileHandle) throws -> Data?
    ) throws -> String {
        // A folder is refused with its own error before it is opened.
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            throw ContentFingerprintError.notARegularFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        // A file only read from loses nothing if closing it fails, and the
        // legacy `closeFile()` would raise an exception there too.
        defer { try? handle.close() }

        var hasher = Hash()
        // Each read runs in its own autorelease pool, so what it autoreleases
        // is freed before the next read and a large file never fills memory.
        while let chunk = try autoreleasepool(invoking: { try readChunk(handle) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02hhx", $0) }.joined()
    }

    /// The digest of the file at `url` under `Hash`, read a mebibyte at a time.
    static func hex<Hash: HashFunction>(of url: URL, using hash: Hash.Type) throws -> String {
        try hex(of: url, using: hash, readingChunksWith: { handle in try handle.read(upToCount: chunkSize) })
    }

    /// The SHA-256 of the file at `url`, which names its blob in a sync folder.
    static func sha256(of url: URL) throws -> String {
        try hex(of: url, using: SHA256.self)
    }
}
