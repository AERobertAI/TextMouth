import Foundation

/// Sets general purpose bit 0, "encrypted", on each of `members` in the ZIP
/// archive at `url`, in its central directory and its local header, leaving
/// their data alone: to a reader that looks only at the flags, an archive
/// with a password (B27). The entries' bytes are not really encrypted, so
/// this serves tests of detection and refusal, never of decryption.
/// - Throws: when the archive has not exactly one of each header for a member.
func markEncrypted(_ members: [String], in url: URL) throws {
    var bytes = [UInt8](try Data(contentsOf: url))
    for member in members {
        let name = Array(member.utf8)
        // Each header: its signature, where its name's length is kept, where
        // the name starts, and where its 16-bit flags are kept.
        let headers: [(signature: [UInt8], nameLength: Int, nameStart: Int, flags: Int)] = [
            ([0x50, 0x4B, 0x01, 0x02], 28, 46, 8),
            ([0x50, 0x4B, 0x03, 0x04], 26, 30, 6)
        ]
        var marked = 0
        for header in headers {
            for start in 0..<max(0, bytes.count - header.nameStart) where bytes[start..<start + 4].elementsEqual(header.signature) {
                let length = Int(bytes[start + header.nameLength]) | Int(bytes[start + header.nameLength + 1]) << 8
                let nameEnd = start + header.nameStart + length
                guard nameEnd <= bytes.count, bytes[(start + header.nameStart)..<nameEnd].elementsEqual(name) else { continue }
                bytes[start + header.flags] |= 0x01
                marked += 1
            }
        }
        guard marked == 2 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "No headers name \(member) in \(url.path)"])
        }
    }
    try Data(bytes).write(to: url)
}
