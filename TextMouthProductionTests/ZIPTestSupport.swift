import Foundation
import ZIPFoundation

/// Write a ZIP archive holding `entries` (path inside the archive → bytes) to
/// a new file in the temporary directory whose name starts with `prefix`.
/// Entries are raw bytes, so a test can store text that is deliberately not
/// valid in its declared encoding. Entries are stored uncompressed unless
/// `compressionMethod` says otherwise. Callers remove the returned file.
func makeTemporaryZip(
    prefix: String,
    entries: [String: Data],
    compressionMethod: CompressionMethod = .none
) throws -> URL {
    try makeTemporaryZip(
        prefix: prefix,
        orderedEntries: entries.map { TestZIPEntry($0.key, $0.value) },
        compressionMethod: compressionMethod
    )
}

/// One entry of a test archive: its path inside the archive, its kind, and
/// its bytes. A link's bytes are the path it points to; a folder has none.
struct TestZIPEntry {
    var path: String
    var type: Entry.EntryType
    var data: Data

    /// A file entry at `path` holding `data`.
    init(_ path: String, _ data: Data) {
        self.init(path, type: .file, data: data)
    }

    /// An entry of `type` at `path` holding `data`.
    init(_ path: String, type: Entry.EntryType, data: Data = Data()) {
        self.path = path
        self.type = type
        self.data = data
    }

    /// A symbolic link at `path` pointing to `target`.
    static func link(_ path: String, to target: String) -> TestZIPEntry {
        TestZIPEntry(path, type: .symlink, data: Data(target.utf8))
    }

    /// A folder entry at `path`.
    static func folder(_ path: String) -> TestZIPEntry {
        TestZIPEntry(path, type: .directory)
    }
}

/// Write a ZIP archive holding `entries` in the order given to a new file in
/// the temporary directory whose name starts with `prefix`. ZIPFoundation's
/// own writer stores each path exactly as given, so a test can make paths
/// that lead outside the archive. Files are stored uncompressed unless
/// `compressionMethod` says otherwise. Callers remove the returned file.
func makeTemporaryZip(
    prefix: String,
    orderedEntries entries: [TestZIPEntry],
    compressionMethod: CompressionMethod = .none
) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).zip")
    let archive = try Archive(url: url, accessMode: .create)

    for entry in entries {
        let data = entry.data
        try archive.addEntry(
            with: entry.path,
            type: entry.type,
            uncompressedSize: Int64(data.count),
            // Only files are compressed; links and folders are stored.
            compressionMethod: entry.type == .file ? compressionMethod : .none,
            provider: { position, size in
                // ZIPFoundation reads the entry in chunks from `position` on.
                let start = Int(position)
                let end = min(start + size, data.count)
                return data[start..<end]
            }
        )
    }

    return url
}

/// Rewrites the uncompressed size the ZIP archive at `url` records for
/// `member`, in its central directory and its local header, to `size`,
/// leaving its data alone: an archive whose sizes lie, as a damaged or
/// deliberately crafted one can. ZIPFoundation reads sizes from the central
/// directory and never compares the two copies.
func setRecordedSize(of member: String, in url: URL, to size: UInt32) throws {
    var bytes = [UInt8](try Data(contentsOf: url))
    let name = Array(member.utf8)
    // Each header: its signature, where its name's length is kept, where the
    // name starts, and where the uncompressed size is kept, as the ZIP
    // format lays them out.
    let headers: [(signature: [UInt8], nameLength: Int, nameStart: Int, sizeField: Int)] = [
        ([0x50, 0x4B, 0x01, 0x02], 28, 46, 24),
        ([0x50, 0x4B, 0x03, 0x04], 26, 30, 22)
    ]
    var rewritten = 0
    for header in headers {
        for start in 0..<max(0, bytes.count - header.nameStart) where bytes[start..<start + 4].elementsEqual(header.signature) {
            let length = Int(bytes[start + header.nameLength]) | Int(bytes[start + header.nameLength + 1]) << 8
            let nameEnd = start + header.nameStart + length
            guard nameEnd <= bytes.count, bytes[(start + header.nameStart)..<nameEnd].elementsEqual(name) else { continue }
            for byte in 0..<4 {
                bytes[start + header.sizeField + byte] = UInt8(truncatingIfNeeded: size >> (8 * UInt32(byte)))
            }
            rewritten += 1
        }
    }
    guard rewritten == 2 else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No headers name \(member) in \(url.path)"])
    }
    try Data(bytes).write(to: url)
}
