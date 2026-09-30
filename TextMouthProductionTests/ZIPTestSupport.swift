import Foundation
import ZIPFoundation

/// Write a ZIP archive holding `entries` (path inside the archive → bytes) to
/// a new file in the temporary directory whose name starts with `prefix`.
/// Entries are raw bytes, so a test can store text that is deliberately not
/// valid in its declared encoding. Callers remove the returned file.
func makeTemporaryZip(prefix: String, entries: [String: Data]) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString).zip")
    let archive = try Archive(url: url, accessMode: .create)

    for (path, data) in entries {
        try archive.addEntry(
            with: path,
            type: .file,
            uncompressedSize: Int64(data.count),
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
