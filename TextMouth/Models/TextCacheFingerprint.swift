import CryptoKit
import Foundation

// What a book's text cache was written from and what was written, recorded
// so a load can tell when either has changed since (TODO T07). Unlike
// `ContentFingerprint`, which proves that a copy holds its original's bytes,
// these fingerprints also keep each file's modification time: comparing
// sizes and times needs no file to be read, so an unchanged book is checked
// without hashing anything.

// MARK: - File Stamp

/// What stat(2) reports about a regular file without reading it: its size
/// and when its content last changed. A file whose stamp is unchanged is
/// taken to hold the same bytes; only a stamp that differs, or a check that
/// fails for another reason, leads to reading the file for its digest.
struct FileStamp: Hashable, Sendable {
    /// The file's size in bytes.
    var byteCount: Int64
    /// When the file's content last changed, in nanoseconds since 1970. An
    /// integer keeps every digit through JSON, where bookInfo.json's ISO 8601
    /// dates would drop the fraction of a second and so never match again.
    var modificationTimeNanoseconds: Int64

    init(byteCount: Int64, modificationTimeNanoseconds: Int64) {
        self.byteCount = byteCount
        self.modificationTimeNanoseconds = modificationTimeNanoseconds
    }

    /// The stamp of the regular file at `url`, following symbolic links as
    /// reading the file does. Nil when nothing is there, when the item is a
    /// folder or anything else that is not a regular file, or when it cannot
    /// be examined.
    init?(of url: URL) {
        var status = stat()
        let examined = url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return stat(path, &status) == 0
        }
        guard examined, status.st_mode & S_IFMT == S_IFREG else { return nil }
        self.init(
            byteCount: Int64(status.st_size),
            modificationTimeNanoseconds: Self.nanoseconds(since1970: status.st_mtimespec)
        )
    }

    /// `time` in nanoseconds since 1970. A time outside what `Int64` can
    /// count (before 1678 or after 2262), which no real file has, is held at
    /// the nearest limit instead of trapping on overflow.
    private static func nanoseconds(since1970 time: timespec) -> Int64 {
        let seconds = Int64(time.tv_sec)
        let (scaled, overflowed) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflowed else { return seconds < 0 ? .min : .max }
        let (total, overflowedSum) = scaled.addingReportingOverflow(Int64(time.tv_nsec))
        return overflowedSum ? .max : total
    }
}

/// How a file's stamp now compares with the one its fingerprint recorded.
enum FileStampComparison: Equatable {
    /// The same size and modification time: the recorded bytes, taken on trust.
    case same
    /// The same size with another modification time, now `stamp`. The file
    /// was rewritten or touched; only its digest can tell whether its bytes
    /// changed.
    case redated(FileStamp)
    /// Another size: the bytes changed, which needs no digest to prove.
    case resized
    /// The file is missing, is not a regular file, or cannot be examined.
    case unexamined
    /// The file is dataless (FR02): only its metadata is on this Mac, and
    /// its content is in the cloud. The size and date it reports describe
    /// nothing a check can trust (an evicted iCloud Drive file can report 0
    /// bytes), and reading it for its digest would download it, so it is
    /// judged neither changed nor unchanged.
    case dataless
}

// MARK: - File Fingerprint

/// One file's stamp together with the digest of the bytes it held when the
/// stamp was taken.
struct FileFingerprint: Codable, Hashable, Sendable {
    /// The file's size in bytes.
    var byteCount: Int64
    /// When the file's content last changed, in nanoseconds since 1970 (see
    /// `FileStamp.modificationTimeNanoseconds`).
    var modificationTimeNanoseconds: Int64
    /// The digest of the file's bytes, from `FingerprintHasher`.
    var digest: String

    init(stamp: FileStamp, digest: String) {
        byteCount = stamp.byteCount
        modificationTimeNanoseconds = stamp.modificationTimeNanoseconds
        self.digest = digest
    }

    /// Stamps the regular file at `url` and then reads it for its digest, so
    /// a file that changes while it is read differs from the stamp next
    /// time. Nil when the file cannot be stamped or read.
    init?(of url: URL, hasher: FingerprintHasher) {
        guard let stamp = FileStamp(of: url),
              let digest = try? hasher.digestOfFile(url) else { return nil }
        self.init(stamp: stamp, digest: digest)
    }

    /// The size and modification time this fingerprint recorded.
    var stamp: FileStamp {
        FileStamp(byteCount: byteCount, modificationTimeNanoseconds: modificationTimeNanoseconds)
    }

    /// How `current`, the file's stamp now (nil when it could not be taken),
    /// compares with the stamp recorded here.
    func comparison(with current: FileStamp?) -> FileStampComparison {
        guard let current else { return .unexamined }
        if current.byteCount != byteCount { return .resized }
        if current.modificationTimeNanoseconds != modificationTimeNanoseconds { return .redated(current) }
        return .same
    }

    /// How the file compares with the stamp recorded here: `.dataless` when
    /// `isDataless` says it is (FR02), whatever its stamp, and otherwise as
    /// `comparison(with:)` has it.
    func comparison(with current: FileStamp?, isDataless: Bool) -> FileStampComparison {
        isDataless ? .dataless : comparison(with: current)
    }
}

// MARK: - Text Cache Fingerprint

/// The fingerprints of a text book's cache, recorded when content.md is
/// written: its source file as extraction read it, and content.md as it was
/// written. Book records keep it with the cache's format version, as an
/// analysis-owned field, and the content index carries it, so every path that
/// saves an analysis saves its fingerprint too.
struct TextCacheFingerprint: Codable, Hashable, Sendable {
    /// The book's own file, which the cache was extracted from.
    var source: FileFingerprint
    /// The content.md that extraction wrote.
    var cache: FileFingerprint
}

/// Why a text cache no longer describes what it was written from. The raw
/// value is the wording of the `CACHE_STALE` log line.
enum TextCacheStaleness: String, Equatable, Sendable {
    /// The source holds other bytes than the cache was extracted from.
    case sourceChanged = "source changed"
    /// content.md holds other bytes than were written.
    case cacheChanged = "content.md changed"
}

/// What checking a text cache's files against its fingerprint found.
enum TextCacheVerification: Equatable {
    /// The files hold the recorded bytes. The fingerprint is the one to
    /// record from now on: the recorded one, or the same digests with the
    /// new stamps of a file that was rewritten without changing.
    case current(TextCacheFingerprint)
    /// The cache no longer describes what it was written from.
    case stale(TextCacheStaleness)
}

extension TextCacheFingerprint {
    /// Checks the files of the cache this fingerprint describes, as stamped
    /// now: `sourceStamp` for the book's file at `sourceURL`, and
    /// `cacheStamp` for its content.md.
    ///
    /// Only stamps are compared for a file whose stamp is unchanged, so an
    /// unchanged book is checked without reading either file. A file with
    /// another size has changed. A file with the recorded size but another
    /// modification time is read for its digest: the same digest means it
    /// was rewritten or touched without changing, and the result carries its
    /// new stamp. `cacheDigest` supplies content.md's digest when one is
    /// needed, so a caller that has its bytes in hand need not read it again.
    ///
    /// A source that cannot be examined, or cannot be read for its digest,
    /// is not a change: nothing could be extracted from it again, so the
    /// cache, now the only copy of the book's text, is kept as it is. A
    /// content.md that cannot be examined has changed.
    ///
    /// A dataless file (FR02), as `sourceIsDataless` and `cacheIsDataless`
    /// say, is never read for its digest and never judged by the size and
    /// date it reports: a dataless source is kept as one that cannot be
    /// examined, and a dataless content.md is not stale.
    func verify(
        sourceURL: URL,
        sourceStamp: FileStamp?,
        cacheStamp: FileStamp?,
        cacheDigest: () throws -> String,
        hasher: FingerprintHasher,
        sourceIsDataless: Bool = false,
        cacheIsDataless: Bool = false
    ) rethrows -> TextCacheVerification {
        var verified = self
        switch source.comparison(with: sourceStamp, isDataless: sourceIsDataless) {
        case .resized:
            return .stale(.sourceChanged)
        case .redated(let stamp):
            if let digest = try? hasher.digestOfFile(sourceURL) {
                guard digest == source.digest else { return .stale(.sourceChanged) }
                verified.source = FileFingerprint(stamp: stamp, digest: digest)
            }
        case .same, .unexamined, .dataless:
            break
        }
        switch cache.comparison(with: cacheStamp, isDataless: cacheIsDataless) {
        case .resized, .unexamined:
            return .stale(.cacheChanged)
        case .redated(let stamp):
            guard try cacheDigest() == cache.digest else { return .stale(.cacheChanged) }
            verified.cache = FileFingerprint(stamp: stamp, digest: cache.digest)
        case .same, .dataless:
            break
        }
        return .current(verified)
    }

    /// Whether the source or content.md, stamped now, has another size than
    /// recorded: a change that needs no digest to prove, so this can be
    /// asked of every book at startup. A source that cannot be examined has
    /// not been resized (see `verify`); a content.md that cannot be has. A
    /// dataless file has not been resized, whatever size it reports (FR02):
    /// an evicted iCloud Drive file reports 0 bytes.
    func hasResizedFile(
        sourceStamp: FileStamp?,
        cacheStamp: FileStamp?,
        sourceIsDataless: Bool = false,
        cacheIsDataless: Bool = false
    ) -> Bool {
        if source.comparison(with: sourceStamp, isDataless: sourceIsDataless) == .resized { return true }
        switch cache.comparison(with: cacheStamp, isDataless: cacheIsDataless) {
        case .resized, .unexamined:
            return true
        case .same, .redated, .dataless:
            return false
        }
    }
}

// MARK: - Hashing

/// Computes the digests that fingerprints record. Production uses MD5, the
/// digest duplicate detection already records for every source
/// (`FileImportService.md5Hash(of:)`), which this M3 computes at about 700 MB
/// a second: a few milliseconds for a typical EPUB. Tests substitute a hasher
/// that counts its calls, to prove which checks read files.
struct FingerprintHasher: Sendable {
    /// The digest of the regular file at a URL, read in full.
    let digestOfFile: @Sendable (URL) throws -> String
    /// The digest of bytes already in memory, such as a content.md just
    /// written or read; the same digest `digestOfFile` gives the same bytes.
    let digestOfData: @Sendable (Data) -> String

    init(
        digestOfFile: @escaping @Sendable (URL) throws -> String,
        digestOfData: @escaping @Sendable (Data) -> String
    ) {
        self.digestOfFile = digestOfFile
        self.digestOfData = digestOfData
    }

    /// Lowercase hexadecimal MD5 digests, as `FileImportService.md5Hash(of:)`
    /// spells them.
    static let md5 = FingerprintHasher(
        digestOfFile: { url in
            // FileHandle raises an Objective-C exception, which Swift cannot
            // catch, when it reads a folder: refuse anything but a file first.
            guard FileStamp(of: url) != nil else { throw ContentFingerprintError.notARegularFile }
            return try FileImportService.md5Hash(of: url)
        },
        digestOfData: { data in
            Insecure.MD5.hash(data: data).map { String(format: "%02hhx", $0) }.joined()
        }
    )
}
