import Foundation

// MARK: - A Record of the Central Directory

/// One entry of a ZIP archive as its central directory records it: what
/// TextMouth needs to tell whether the entry is encrypted, and how, without
/// ZIPFoundation, which hides an encrypted entry altogether (`Entry.init?`
/// returns nil for one, and its iterator stops there; B27).
struct ZipDirectoryRecord: Equatable, Sendable {
    /// The entry's path inside the archive.
    var name: String
    /// The version that made the entry, whose high byte says which system
    /// wrote its `externalAttributes` (3 is Unix, where they hold the mode).
    var versionMadeBy: UInt16
    /// The entry's modification time and date, in MS-DOS form. A ZipCrypto
    /// entry's password check byte is the time's high byte when the entry
    /// has a data descriptor.
    var modTime: UInt16
    var modDate: UInt16
    /// The file attributes of the system that wrote the entry.
    var externalAttributes: UInt32
    /// The general purpose bit flag. Bit 0 says the entry is encrypted, bit 6
    /// that it uses PKWARE's strong encryption, bit 13 that the central
    /// directory itself is masked.
    var flags: UInt16
    /// The compression method; 99 is WinZip AES, whose real method is in the
    /// 0x9901 extra field.
    var method: UInt16
    /// The CRC-32 of the plain bytes (zero for a WinZip AE-2 entry).
    var checksum: UInt32
    /// The bytes the entry holds in the archive, encryption's added bytes included.
    var compressedSize: UInt64
    /// The bytes the entry holds once decrypted and inflated.
    var uncompressedSize: UInt64
    /// Where the entry's local header starts.
    var localHeaderOffset: UInt64
    /// The central directory's extra field for the entry, as stored.
    var extra: Data

    /// Whether the entry's data is encrypted (general purpose bit 0).
    var isEncrypted: Bool { flags & Self.encryptedBit != 0 }

    /// Whether the entry is a folder, which holds no data and so is never encrypted in a way that matters.
    var isFolder: Bool { name.hasSuffix("/") }

    /// General purpose bit 0.
    static let encryptedBit: UInt16 = 0x0001
}

// MARK: - Reading the Central Directory

/// Reads a ZIP archive's central directory straight from its file, as the
/// ZIP format lays it out (PKWARE's APPNOTE, sections 4.3.12, 4.3.16, and
/// 4.3.14 to 4.3.15 for ZIP64), bounded against hostile files: it never
/// reads more than `largestDirectory` bytes of directory, trusts no count
/// beyond what those bytes can hold, and never traps on a short or lying file.
enum ZipCentralDirectory {

    /// The most bytes of central directory the reader takes: 64 MB holds
    /// about 700,000 entries with ordinary names.
    static let largestDirectory: UInt64 = 64_000_000

    /// The end-of-central-directory record's signature, "PK\5\6".
    private static let endSignature: UInt32 = 0x0605_4B50
    /// The ZIP64 end record's locator's signature, "PK\6\7".
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    /// The ZIP64 end record's signature, "PK\6\6".
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    /// A central directory header's signature, "PK\1\2".
    private static let headerSignature: UInt32 = 0x0201_4B50

    /// The records of the ZIP archive at `url`, in the order its central
    /// directory lists them, or nil when the file is not a ZIP archive that
    /// can be read this way: too short, no end record, a directory that
    /// reaches outside the file, or a header that does not fit.
    static func records(ofFileAt url: URL) -> [ZipDirectoryRecord]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return nil }

        // The end record is the last 22 bytes plus a comment of up to 65,535.
        let tailLength = min(size, 22 + 65_535)
        guard let tail = read(handle, at: size - tailLength, count: Int(tailLength)),
              let endOffset = findEndRecord(in: tail) else { return nil }
        var count = UInt64(tail.u16(endOffset + 10))
        var directorySize = UInt64(tail.u32(endOffset + 12))
        var directoryOffset = UInt64(tail.u32(endOffset + 16))

        // Any field at its maximum says the real value is in the ZIP64 record.
        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            let locator = endOffset - 20
            guard locator >= 0, tail.u32(locator) == zip64LocatorSignature else { return nil }
            let zip64Offset = tail.u64(locator + 8)
            guard zip64Offset < size, let record = read(handle, at: zip64Offset, count: 56),
                  record.u32(0) == zip64EndSignature else { return nil }
            count = record.u64(32)
            directorySize = record.u64(40)
            directoryOffset = record.u64(48)
        }
        guard directorySize <= largestDirectory, directoryOffset <= size, directorySize <= size - directoryOffset,
              let directory = read(handle, at: directoryOffset, count: Int(directorySize)) else { return nil }
        return parse(directory, count: count)
    }

    /// The offset in `tail` of the last end-of-central-directory record
    /// whose comment fits inside the tail, or nil. Bytes after the comment
    /// are allowed (a downloader's padding, a signature), as archive tools allow.
    private static func findEndRecord(in tail: [UInt8]) -> Int? {
        guard tail.count >= 22 else { return nil }
        var offset = tail.count - 22
        while offset >= 0 {
            if tail.u32(offset) == endSignature, offset + 22 + Int(tail.u16(offset + 20)) <= tail.count {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    /// The records in `directory`, `count` of them at most, or nil when a
    /// header does not fit in the bytes.
    private static func parse(_ directory: [UInt8], count: UInt64) -> [ZipDirectoryRecord]? {
        var records: [ZipDirectoryRecord] = []
        var position = 0
        // Every record takes at least 46 bytes, so the bytes bound the count.
        while UInt64(records.count) < count {
            guard position + 46 <= directory.count, directory.u32(position) == headerSignature else { return nil }
            let nameLength = Int(directory.u16(position + 28))
            let extraLength = Int(directory.u16(position + 30))
            let commentLength = Int(directory.u16(position + 32))
            let end = position + 46 + nameLength + extraLength + commentLength
            guard end <= directory.count else { return nil }
            let flags = directory.u16(position + 8)
            let nameBytes = Data(directory[(position + 46)..<(position + 46 + nameLength)])
            let extra = Data(directory[(position + 46 + nameLength)..<(position + 46 + nameLength + extraLength)])

            var record = ZipDirectoryRecord(
                name: decodeName(nameBytes),
                versionMadeBy: directory.u16(position + 4),
                modTime: directory.u16(position + 12),
                modDate: directory.u16(position + 14),
                externalAttributes: directory.u32(position + 38),
                flags: flags,
                method: directory.u16(position + 10),
                checksum: directory.u32(position + 16),
                compressedSize: UInt64(directory.u32(position + 20)),
                uncompressedSize: UInt64(directory.u32(position + 24)),
                localHeaderOffset: UInt64(directory.u32(position + 42)),
                extra: extra
            )
            applyZip64Extra(to: &record)
            records.append(record)
            position = end
        }
        return records
    }

    /// Replaces the sizes and offset of `record` that sit at their maximum
    /// with the values of its ZIP64 extra field (id 0x0001), which holds
    /// only the ones that overflowed, in the order uncompressed size,
    /// compressed size, offset.
    private static func applyZip64Extra(to record: inout ZipDirectoryRecord) {
        guard let field = extraField(0x0001, in: record.extra) else { return }
        var cursor = 0
        func next() -> UInt64? {
            guard cursor + 8 <= field.count else { return nil }
            defer { cursor += 8 }
            return field.u64(cursor)
        }
        if record.uncompressedSize == 0xFFFF_FFFF, let value = next() { record.uncompressedSize = value }
        if record.compressedSize == 0xFFFF_FFFF, let value = next() { record.compressedSize = value }
        if record.localHeaderOffset == 0xFFFF_FFFF, let value = next() { record.localHeaderOffset = value }
    }

    /// The data of the extra field with `identifier` in `extra`, or nil.
    static func extraField(_ identifier: UInt16, in extra: Data) -> [UInt8]? {
        let bytes = [UInt8](extra)
        var position = 0
        while position + 4 <= bytes.count {
            let id = bytes.u16(position)
            let length = Int(bytes.u16(position + 2))
            guard position + 4 + length <= bytes.count else { return nil }
            if id == identifier { return Array(bytes[(position + 4)..<(position + 4 + length)]) }
            position += 4 + length
        }
        return nil
    }

    /// An entry name from its bytes: UTF-8 when they are valid UTF-8 (which
    /// general purpose bit 11 promises), else Latin-1, the nearest to the
    /// legacy code page older tools wrote.
    private static func decodeName(_ bytes: Data) -> String {
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(data: bytes, encoding: .isoLatin1) ?? ""
    }

    /// `count` bytes of the file at `offset`, or nil when they cannot be read.
    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }
}

// MARK: - Little-Endian Reads

extension Array where Element == UInt8 {
    /// The 16-bit little-endian number at `offset`, which must lie inside the array.
    func u16(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    /// The 32-bit little-endian number at `offset`, which must lie inside the array.
    func u32(_ offset: Int) -> UInt32 {
        UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16
    }

    /// The 64-bit little-endian number at `offset`, which must lie inside the array.
    func u64(_ offset: Int) -> UInt64 {
        UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32
    }
}
