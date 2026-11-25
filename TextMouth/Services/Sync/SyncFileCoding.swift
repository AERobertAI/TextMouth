import Foundation

// MARK: - How Sync Files Are Written (FR43)

/// The one JSON form of every file sync writes: sorted keys, so the same
/// value writes the same bytes, and dates to the second as ISO 8601, so a
/// date reads back equal on every device.
enum SyncFileCoding {
    /// The encoder every sync file is written with.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The decoder every sync file is read with.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `value` as bytes in the sync form.
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    /// A value of `type` read from `data`, or nil when it doesn't decode.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder().decode(type, from: data)
    }

    /// The highest `formatVersion` this TextMouth reads; a file with a
    /// higher one is left alone, and "a later TextMouth" is said.
    static let supportedFormatVersion = 1
}

/// The names of the files and folders of a sync folder, pinned by
/// `OnDiskContractTests` (section 3): lower-case UUIDs and digests, 12-digit
/// `seq`, extensions of 1 to 8 `a-z0-9`, plain folders.
enum SyncNames {
    static let folderName = "TextMouth Sync" // l10n: no (a folder's name on disk)
    static let storeFile = "store.json"
    static let booksFolder = "Books"
    static let devicesFolder = "Devices"
    static let deviceFile = "device.json"

    /// `000000000042.changes.json`, or `.snapshot.json`.
    static func changeFile(seq: Int, kind: SyncChangeFile.Kind) -> String {
        String(format: "%012d.%@.json", seq, kind.rawValue)
    }

    /// The `seq` and kind a change file's name holds, or nil for any other name.
    static func parseChangeFile(_ name: String) -> (seq: Int, kind: SyncChangeFile.Kind)? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "json", parts[0].count == 12,
              parts[0].allSatisfy(isDigit), let seq = Int(parts[0]),
              let kind = SyncChangeFile.Kind(rawValue: String(parts[1])) else { return nil }
        return (seq, kind)
    }

    /// `<sha256>.<ext>`: a book's blob; the extension is 1 to 8 of `a-z0-9`, else `bin`.
    static func blobName(sha256: String, pathExtension: String) -> String {
        let ext = pathExtension.lowercased()
        let valid = (1...8).contains(ext.count) && ext.allSatisfy { isDigit($0) || isLowerLetter($0) }
        return sha256 + "." + (valid ? ext : "bin")
    }

    /// `<sha256>.manifest.json`.
    static func manifestName(sha256: String) -> String { sha256 + ".manifest.json" }

    /// Whether `text` is a lower-case SHA-256 digest.
    static func isDigest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { isDigit($0) || ("a"..."f").contains($0) }
    }

    /// A UUID in the lower case the folder's names use.
    static func id(_ uuid: UUID) -> String { uuid.uuidString.lowercased() }

    /// Whether `character` is `0` to `9`.
    private static func isDigit(_ character: Character) -> Bool { ("0"..."9").contains(character) }

    /// Whether `character` is `a` to `z`.
    private static func isLowerLetter(_ character: Character) -> Bool { ("a"..."z").contains(character) }
}
