import Foundation

/// Reading and writing the files of a sync folder (FR43, section 3 of the
/// plan): JSON with sorted keys and dates to the second, `formatVersion` 1.
/// A file of a later version is left alone, and a file that does not decode
/// is not here yet, which the caller waits for.
enum SyncFormats {
    /// The format version this TextMouth writes and reads.
    static let currentVersion = 1

    // MARK: - Writing

    /// `file` as the bytes a sync folder holds: sorted keys, dates to the
    /// second, so the same value is always the same bytes.
    static func encode<File: Encodable>(_ file: File) throws -> Data {
        try SyncValueCoding.makeEncoder().encode(file)
    }

    // MARK: - Reading

    /// Reads a `store.json`.
    /// - Throws: `SyncProblem.laterVersion` for a later format; `.damaged(file:)` for text that is no store file.
    static func decodeStoreFile(_ data: Data, named name: String = "store.json") throws -> SyncStoreFile {
        try decode(SyncStoreFile.self, from: data, named: name)
    }

    /// Reads a `device.json`.
    static func decodeDeviceFile(_ data: Data, named name: String = "device.json") throws -> SyncDeviceFile {
        try decode(SyncDeviceFile.self, from: data, named: name)
    }

    /// Reads a book's manifest.
    static func decodeManifest(_ data: Data, named name: String) throws -> StoreManifest {
        try decode(StoreManifest.self, from: data, named: name)
    }

    /// Reads a book's `.storeCopy.json`.
    static func decodePointer(_ data: Data, named name: String = StorePointer.fileName) throws -> StorePointer {
        try decode(StorePointer.self, from: data, named: name)
    }

    /// Reads a change file or a snapshot.
    ///
    /// A file that holds other than `count` entries is damaged: it is not all
    /// here yet. An entry whose key a later TextMouth added is left out of
    /// `entries`, but counts toward `count`, so that a file made by a later
    /// TextMouth in the same format version is still read.
    /// - Throws: `SyncProblem.laterVersion`, or `.damaged(file:)`.
    static func decodeChangeFile(_ data: Data, named name: String) throws -> SyncChangeFile {
        try checkVersion(of: data, named: name)
        guard let raw = try? SyncValueCoding.makeDecoder().decode(JSONValue.self, from: data),
              case .object(var members) = raw,
              case .array(let items)? = members["entries"],
              case .integer(let count)? = members["count"],
              Int64(items.count) == count else { throw SyncProblem.damaged(file: name) }
        // Entries with a key this version does not know are left out.
        members["entries"] = .array(items.filter { item in
            item["key"]?.stringValue.flatMap { SyncKey(text: $0) } != nil
        })
        guard let file = SyncValueCoding.decode(SyncChangeFile.self, from: .object(members)) else {
            throw SyncProblem.damaged(file: name)
        }
        return file
    }

    // MARK: - Common

    /// Decodes `type` from `data` after checking its format version.
    private static func decode<File: Decodable>(_ type: File.Type, from data: Data, named name: String) throws -> File {
        try checkVersion(of: data, named: name)
        do {
            return try SyncValueCoding.makeDecoder().decode(type, from: data)
        } catch {
            throw SyncProblem.damaged(file: name)
        }
    }

    /// Throws `.laterVersion` for a file whose `formatVersion` is above this one's, and
    /// `.damaged(file:)` for one that has none.
    private static func checkVersion(of data: Data, named name: String) throws {
        struct Header: Decodable { var formatVersion: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw SyncProblem.damaged(file: name) }
        if header.formatVersion > currentVersion { throw SyncProblem.laterVersion }
    }
}
