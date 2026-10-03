import Foundation

/// Which library a data directory holds (FR02): a small marker file in the
/// root of the data directory, `library-identity.json`, with a UUID and the
/// date the library was given it.
///
/// A library gets its identity once: when TextMouth creates it, or, for a
/// library made before identities existed, the first time it opens. The
/// marker is never overwritten, so a library keeps its identity wherever its
/// folder goes: a data-directory move copies it, a renamed drive keeps it,
/// and a sync service brings it to another Mac. This Mac's preferences
/// remember the identity it expects (`DataDirectoryPreferences`), so a folder
/// that only has the right name, such as another drive called "Backup", is
/// never taken for this library.
struct LibraryIdentity: Codable, Equatable, Sendable {
    /// The library's identifier.
    let id: UUID
    /// When the library was given this identity.
    let created: Date

    /// The marker's file name in the root of the data directory.
    static let fileName = "library-identity.json"

    /// The marker's location in the data directory at `root`.
    static func markerURL(in root: URL) -> URL {
        root.appendingPathComponent(fileName, isDirectory: false)
    }

    // MARK: - Reading

    /// The identity of the library in the data directory at `root`, or nil
    /// when it holds no marker.
    ///
    /// The marker's few bytes are read like any file: a marker only in the
    /// cloud would be downloaded first, so callers that must never wait on
    /// the network read it inside `DatalessFiles.withoutDownloading`, where
    /// such a read throws the download refusal instead.
    /// - Throws: Why an existing marker could not be read or decoded.
    static func read(in root: URL) throws -> LibraryIdentity? {
        let marker = markerURL(in: root)
        let data: Data
        do {
            data = try Data(contentsOf: marker)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try decoder.decode(LibraryIdentity.self, from: data)
    }

    // MARK: - Adopting

    /// The identity of the library in the data directory at `root`, giving
    /// it a new one first when it has none.
    ///
    /// A marker already there is never replaced, even one written by another
    /// Mac a moment ago: the new marker is created exclusively, and when
    /// another appears first, that one is read and returned instead.
    /// - Parameter now: The date a new identity records.
    /// - Returns: The identity the folder holds afterwards, and whether this
    ///   call gave it.
    /// - Throws: Why the marker could not be read or written.
    static func adopt(in root: URL, now: Date = Date()) throws -> (identity: LibraryIdentity, isNew: Bool) {
        if let existing = try read(in: root) {
            return (existing, false)
        }
        // The marker keeps the date to the second, as ISO 8601 writes it, so
        // the identity returned is the very one a later read returns.
        let wholeSeconds = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let identity = LibraryIdentity(id: UUID(), created: wholeSeconds)
        do {
            // Exclusive creation: refused when any file is already there.
            try encoder.encode(identity).write(to: markerURL(in: root), options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            // Another writer got there first; its identity stands.
            if let existing = try read(in: root) {
                return (existing, false)
            }
            throw CocoaError(.fileWriteFileExists)
        }
        return (identity, true)
    }

    // MARK: - Coding

    /// Writes the marker as people can read it: sorted keys, indented, and
    /// the date in ISO 8601.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Reads the marker as `encoder` writes it.
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
