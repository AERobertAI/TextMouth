import Foundation

// Moving books recorded in the layout that predates `.tmb` packages into
// packages, and the fingerprint that proves a copy matches its original
// before that original may be removed.

// MARK: - Content Fingerprint

/// The size and MD5 hash of a regular file. Two files with equal
/// fingerprints hold the same bytes for every purpose TextMouth has, so a
/// copy whose fingerprint matches its original's can stand in for it.
struct ContentFingerprint: Equatable {
    /// The file's size in bytes.
    let byteCount: UInt64
    /// The hex MD5 digest from `FileImportService.md5Hash(of:)`, the same
    /// hash duplicate detection uses.
    let md5Hash: String

    /// Reads the fingerprint of the regular file at `url`. A folder, a
    /// symbolic link, or any other kind of item throws
    /// `ContentFingerprintError.notARegularFile` instead of being hashed.
    init(of url: URL) throws {
        byteCount = try Self.regularFileSize(at: url)
        md5Hash = try FileImportService.md5Hash(of: url)
    }

    /// Whether the item at `url` is a regular file holding exactly these
    /// bytes. Sizes are compared first, so a partial copy is rejected
    /// without being hashed. Anything that cannot be read counts as
    /// different, never as a match.
    func matchesFile(at url: URL) -> Bool {
        guard (try? Self.regularFileSize(at: url)) == byteCount else { return false }
        return (try? FileImportService.md5Hash(of: url)) == md5Hash
    }

    /// The size of the regular file at `url`. The attributes come from
    /// lstat, so a symbolic link is never followed, and a folder is refused
    /// before it can reach `FileHandle`, whose legacy read raises an
    /// Objective-C exception on one.
    private static func regularFileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else {
            throw ContentFingerprintError.notARegularFile
        }
        return size.uint64Value
    }
}

/// Why an item has no content fingerprint.
enum ContentFingerprintError: LocalizedError, Equatable {
    /// The item is a folder, a symbolic link, or something else that is not
    /// a regular file.
    case notARegularFile

    var errorDescription: String? {
        switch self {
        case .notARegularFile:
            return "The item is a folder or link rather than a file."
        }
    }
}
