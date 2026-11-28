import CommonCrypto
import CryptoKit
import Foundation
import ZIPFoundation

// MARK: - Opening a ZIP With a Password

/// Turns a password-protected ZIP archive into the plain ZIP archive it
/// would have been without the password, in memory (FR41, phase 1).
///
/// Both schemes in use are read: PKWARE's traditional encryption
/// ("ZipCrypto", APPNOTE 6.1) and WinZip AES (AE-1 and AE-2, method 99, with
/// the extra field 0x9901). Decrypting changes no compressed byte, so no
/// entry is recompressed: the plain archive keeps each entry's deflate data
/// and gets its real method, its checksum, and its sizes back. Every reader
/// of a ZIP (EPUB, DOCX, ODT, comic books, and the rest) then works on the
/// plain bytes unchanged, and the same bytes are what Remove Password
/// writes to the book's own file.
///
/// PKWARE's strong encryption (flag bit 6) and an encrypted central
/// directory (bit 13) are used by almost nothing and are refused.
enum ZipDecryptor {

    /// Why an archive could not be made plain.
    enum Failure: Error, Equatable {
        /// No encoding of the password opens the first encrypted entry.
        case wrongPassword
        /// The archive uses a scheme or a size this reader does not (strong
        /// encryption, an unknown compression method, ZIP64 sizes).
        case unsupported
        /// The archive's bytes do not hold together.
        case damaged
    }

    /// The largest archive held in memory for decrypting: the documents
    /// TextMouth reads are far smaller, and a comic book archive that large
    /// is refused rather than held whole.
    static let largestArchive = 512_000_000

    // MARK: Entry Point

    /// The plain archive made from the archive at `url`.
    /// - Parameter password: tried in each encoding the schemes allow
    ///   (`PasswordEncoding`) against the first encrypted entry, before it
    ///   is called wrong.
    /// - Throws: `Failure`.
    static func decrypt(archiveAt url: URL, password: Secret) throws -> Data {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= largestArchive,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let records = ZipCentralDirectory.records(ofFileAt: url) else { throw Failure.damaged }
        return try decrypt(archive: data, records: records, password: password)
    }

    /// The most entries an archive may hold to be made plain.
    static let largestEntryCount = 10_000

    /// The most bytes of names, in UTF-8, one entry may have: a name's length
    /// is kept in 16 bits in the plain archive.
    static let longestName = 0xFFFF

    /// Refuses a hostile archive before any of it is decrypted: too many
    /// entries, an entry or a total past the limits readers take (the
    /// document limit for each entry, 256 MB for audio, and
    /// `largestArchive` for the whole), a name too long to write, and
    /// entries whose data overlap each other (one set of bytes standing for
    /// two files). Every refusal is `Failure.unsupported` or `.damaged`, a
    /// sentence of its own, and none can trap.
    private static func admit(_ records: [ZipDirectoryRecord]) throws {
        guard records.count <= largestEntryCount else { throw Failure.unsupported }
        var total: UInt64 = 0
        for record in records {
            guard record.name.utf8.count <= longestName else { throw Failure.unsupported }
            let limit = UInt64(max(0, ArchiveEntryLimits.current.limit(forEntryAt: record.name)))
            guard record.uncompressedSize <= limit else { throw Failure.unsupported }
            total += record.uncompressedSize
            guard total <= UInt64(largestArchive) else { throw Failure.unsupported }
        }
        // Each entry's local header starts after the end of the one before it.
        var end: UInt64 = 0
        for record in records.sorted(by: { $0.localHeaderOffset < $1.localHeaderOffset }) {
            guard record.localHeaderOffset >= end else { throw Failure.damaged }
            let (next, overflow) = record.localHeaderOffset.addingReportingOverflow(30 + record.compressedSize)
            guard !overflow else { throw Failure.damaged }
            end = next
        }
    }

    /// The plain archive made from `archive`, whose central directory holds `records`.
    static func decrypt(archive: Data, records: [ZipDirectoryRecord], password: Secret) throws -> Data {
        try admit(records)
        // The password bytes that opened the first encrypted entry serve the rest.
        var chosen: [UInt8]?
        var plain: [PlainEntry] = []
        for record in records {
            let stored = try storedBytes(of: record, in: archive)
            guard record.isEncrypted else {
                plain.append(PlainEntry(record: record, method: record.method, checksum: record.checksum, data: stored))
                continue
            }
            // A folder holds nothing to decrypt (a writer may flag one anyway).
            guard !record.isFolder else {
                plain.append(PlainEntry(record: record, method: 0, checksum: 0, data: Data()))
                continue
            }
            // Strong encryption and a masked directory are not read.
            guard record.flags & 0x0040 == 0, record.flags & 0x2000 == 0 else { throw Failure.unsupported }
            let isAES = record.method == 99
            let scheme: PasswordEncoding.Scheme = isAES ? .utf8 : .zipCrypto
            let candidates = chosen.map { [$0] } ?? PasswordEncoding.candidates(for: password, scheme: scheme)
            var opened: PlainEntry?
            for candidate in candidates {
                if let entry = try open(record, stored: stored, password: candidate) {
                    opened = entry
                    chosen = candidate
                    break
                }
            }
            guard let opened else { throw Failure.wrongPassword }
            plain.append(opened)
        }
        return try PlainZipWriter.archive(of: plain)
    }

    // MARK: One Entry

    /// An entry as the plain archive holds it.
    struct PlainEntry {
        /// The central directory's record of the entry, as it was.
        var record: ZipDirectoryRecord
        /// The compression method of `data`.
        var method: UInt16
        /// The CRC-32 of the entry's plain bytes.
        var checksum: UInt32
        /// The entry's compressed (or stored) bytes.
        var data: Data
    }

    /// The bytes `record` holds in `archive`: after its local header, name, and extra field.
    private static func storedBytes(of record: ZipDirectoryRecord, in archive: Data) throws -> Data {
        let start = Int(clamping: record.localHeaderOffset)
        guard record.compressedSize <= UInt64(archive.count), start >= 0, start <= archive.count - 30 else { throw Failure.damaged }
        let header = [UInt8](archive[(archive.startIndex + start)..<(archive.startIndex + start + 30)])
        guard header.u32(0) == 0x0403_4B50 else { throw Failure.damaged }
        let dataStart = start + 30 + Int(header.u16(26)) + Int(header.u16(28))
        let end = dataStart + Int(record.compressedSize)
        guard end <= archive.count else { throw Failure.damaged }
        return archive.subdata(in: (archive.startIndex + dataStart)..<(archive.startIndex + end))
    }

    /// `record` opened with `password`, or nil when the password does not fit.
    private static func open(_ record: ZipDirectoryRecord, stored: Data, password: [UInt8]) throws -> PlainEntry? {
        if record.method == 99 { return try openAES(record, stored: stored, password: password) }
        return try openZipCrypto(record, stored: stored, password: password)
    }

    // MARK: ZipCrypto

    /// The three-key stream cipher of PKWARE's traditional encryption.
    private struct ZipCryptoKeys {
        var key0: UInt32 = 0x1234_5678
        var key1: UInt32 = 0x2345_6789
        var key2: UInt32 = 0x3456_7890

        /// The CRC-32 table the cipher updates its keys with.
        static let table: [UInt32] = (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
            return value
        }

        /// One CRC-32 step of `byte` into `crc`.
        private static func step(_ crc: UInt32, _ byte: UInt8) -> UInt32 {
            table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }

        /// Mixes the plain `byte` into the keys.
        mutating func update(_ byte: UInt8) {
            key0 = Self.step(key0, byte)
            key1 = (key1 &+ (key0 & 0xFF)) &* 134_775_813 &+ 1
            key2 = Self.step(key2, UInt8(truncatingIfNeeded: key1 >> 24))
        }

        /// Keys made from the password.
        init(password: [UInt8]) {
            password.forEach { update($0) }
        }

        /// Decrypts one byte, and mixes the plain byte in.
        mutating func decrypt(_ byte: UInt8) -> UInt8 {
            let temp = UInt16(truncatingIfNeeded: key2 | 2)
            let plain = byte ^ UInt8(truncatingIfNeeded: (temp &* (temp ^ 1)) >> 8)
            update(plain)
            return plain
        }
    }

    /// A ZipCrypto entry opened, or nil when the check byte or the checksum disagrees.
    private static func openZipCrypto(_ record: ZipDirectoryRecord, stored: Data, password: [UInt8]) throws -> PlainEntry? {
        guard stored.count >= 12 else { throw Failure.damaged }
        var keys = ZipCryptoKeys(password: password)
        var plain = [UInt8](repeating: 0, count: stored.count)
        for (index, byte) in stored.enumerated() { plain[index] = keys.decrypt(byte) }
        // The last byte of the 12-byte header is a check: the checksum's high
        // byte, or the time's when a data descriptor holds the checksum.
        let expected = record.flags & 0x0008 != 0 ? UInt8(record.modTime >> 8) : UInt8(record.checksum >> 24)
        guard plain[11] == expected else { return nil }
        let body = Data(plain[12...])
        // One byte in 256 passes the check by chance: the checksum settles it.
        switch checksum(of: body, method: record.method, expectedSize: record.uncompressedSize) {
        case .value(let crc) where crc != record.checksum: return nil
        case .undecodable: return nil
        case .unchecked:
            // A method that cannot be inflated here cannot be checked: the
            // one byte above would let a wrong password through (and Remove
            // Password write garbage), so it is refused.
            throw Failure.unsupported
        default: break
        }
        return PlainEntry(record: record, method: record.method, checksum: record.checksum, data: body)
    }

    // MARK: WinZip AES

    /// A WinZip AES entry opened, or nil when its password check disagrees.
    /// The layout (WinZip's AE-x specification): salt, a two-byte password
    /// verifier, the encrypted bytes, and a ten-byte HMAC-SHA1 of them. The
    /// keys come from PBKDF2-HMAC-SHA1 at 1000 rounds, and the cipher is AES
    /// in counter mode with a little-endian counter starting at 1.
    private static func openAES(_ record: ZipDirectoryRecord, stored: Data, password: [UInt8]) throws -> PlainEntry? {
        guard let field = ZipCentralDirectory.extraField(0x9901, in: record.extra), field.count >= 7 else { throw Failure.damaged }
        let vendorVersion = field.u16(0)
        guard vendorVersion == 1 || vendorVersion == 2 else { throw Failure.unsupported }
        let strength = Int(field[4])
        guard (1...3).contains(strength) else { throw Failure.unsupported }
        let saltLength = [8, 12, 16][strength - 1]
        let keyLength = [16, 24, 32][strength - 1]
        let realMethod = field.u16(5)
        guard stored.count >= saltLength + 2 + 10 else { throw Failure.damaged }

        let bytes = [UInt8](stored)
        let salt = Array(bytes[0..<saltLength])
        let verifier = Array(bytes[saltLength..<(saltLength + 2)])
        let cipherText = Array(bytes[(saltLength + 2)..<(bytes.count - 10)])
        let authentication = Array(bytes[(bytes.count - 10)...])

        // Two keys and the two verifier bytes, in one derivation.
        var derived = [UInt8](repeating: 0, count: 2 * keyLength + 2)
        let status = derived.withUnsafeMutableBufferPointer { out in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
                salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1000, out.baseAddress, out.count
            )
        }
        guard status == kCCSuccess else { throw Failure.damaged }
        let encryptionKey = Array(derived[0..<keyLength])
        let authenticationKey = Array(derived[keyLength..<(2 * keyLength)])
        guard Array(derived[(2 * keyLength)...]) == verifier else { return nil }
        derived.removeAll()

        // The HMAC of the encrypted bytes, first ten bytes.
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: cipherText, using: SymmetricKey(data: authenticationKey))
        // The password's check passed, so a failed authentication is damage to
        // the entry, not a wrong password.
        guard Array(mac.prefix(10)) == authentication else { throw Failure.damaged }

        let plain = try counterModeLittleEndian(cipherText, key: encryptionKey)
        let body = Data(plain)
        // AE-2 stores a checksum of zero, so it is made here for the plain archive.
        switch checksum(of: body, method: realMethod, expectedSize: record.uncompressedSize) {
        case .value(let computed):
            // The HMAC vouched for the bytes, so a checksum that disagrees is damage.
            if vendorVersion == 1, computed != record.checksum { throw Failure.damaged }
            return PlainEntry(record: record, method: realMethod, checksum: computed, data: body)
        case .undecodable:
            throw Failure.damaged
        case .unchecked:
            // A method this reader cannot inflate: keep what the record says.
            return PlainEntry(record: record, method: realMethod, checksum: record.checksum, data: body)
        }
    }

    /// `input` run through AES in counter mode with WinZip's little-endian
    /// counter (starting at 1). CommonCrypto's counter mode is big-endian
    /// only, so the key stream is made by encrypting the counter blocks in
    /// ECB mode, a chunk at a time, and XORed in.
    private static func counterModeLittleEndian(_ input: [UInt8], key: [UInt8]) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: input.count)
        var counter: UInt64 = 1
        let blocksPerChunk = 4096
        var offset = 0
        while offset < input.count {
            let chunkLength = min(blocksPerChunk * 16, input.count - offset)
            let blocks = (chunkLength + 15) / 16
            // Counter blocks: the counter as 16 little-endian bytes.
            var counters = [UInt8](repeating: 0, count: blocks * 16)
            for block in 0..<blocks {
                var value = counter
                for byte in 0..<8 {
                    counters[block * 16 + byte] = UInt8(truncatingIfNeeded: value)
                    value >>= 8
                }
                counter += 1
            }
            var keyStream = [UInt8](repeating: 0, count: counters.count + kCCBlockSizeAES128)
            var produced = 0
            let status = CCCrypt(
                CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                key, key.count, nil, counters, counters.count, &keyStream, keyStream.count, &produced
            )
            guard status == kCCSuccess, produced >= chunkLength else { throw Failure.damaged }
            for index in 0..<chunkLength { output[offset + index] = input[offset + index] ^ keyStream[index] }
            offset += chunkLength
        }
        return output
    }

    // MARK: Checksums

    /// What the plain bytes of an entry came to.
    private enum PlainChecksum: Equatable {
        /// The CRC-32 of the plain bytes.
        case value(CRC32)
        /// The bytes do not inflate (or inflate past the size recorded), as
        /// bytes decrypted with the wrong key do not.
        case undecodable
        /// A compression method this reader does not inflate.
        case unchecked
    }

    /// The CRC-32 of `body` once it is plain: of the bytes themselves for a
    /// stored entry, of the inflated bytes for a deflated one (held to
    /// `expectedSize`, so a lying entry cannot swell).
    private static func checksum(of body: Data, method: UInt16, expectedSize: UInt64) -> PlainChecksum {
        switch method {
        case 0:
            return .value(body.crc32(checksum: 0))
        case 8:
            var produced: UInt64 = 0
            do {
                let crc = try Data.decompress(
                    size: Int64(body.count), bufferSize: 65_536, skipCRC32: false,
                    provider: { position, size in
                        body.subdata(in: Int(position)..<min(Int(position) + size, body.count))
                    },
                    consumer: { chunk in
                        produced += UInt64(chunk.count)
                        guard produced <= expectedSize else { throw Failure.damaged }
                    }
                )
                return .value(crc)
            } catch {
                return .undecodable
            }
        default:
            return .unchecked
        }
    }
}

// MARK: - Writing the Plain Archive

/// Writes a ZIP archive from entries whose compressed bytes are already
/// made, with no compression of its own, no ZIP64, and no extra fields.
enum PlainZipWriter {

    /// The archive holding `entries`, in order.
    /// - Throws: `ZipDecryptor.Failure.unsupported` for a size past 4 GB.
    static func archive(of entries: [ZipDecryptor.PlainEntry]) throws -> Data {
        var output = Data()
        var central = Data()
        for entry in entries {
            let record = entry.record
            let name = Array(record.name.utf8)
            // Nothing may pass 4 GB, headers included, or fill more than 16 bits.
            guard name.count <= ZipDecryptor.longestName, record.uncompressedSize < 0xFFFF_FFFF,
                  output.count + central.count + entry.data.count + 2 * name.count + 120 < 0xFFFF_FFFF else {
                throw ZipDecryptor.Failure.unsupported
            }
            // Encryption's flags and the data descriptor go; UTF-8 names stay marked.
            let flags: UInt16 = record.flags & ~0x2049 | 0x0800
            let offset = UInt32(output.count)
            output.appendLE(UInt32(0x0403_4B50))
            output.appendLE(UInt16(20))
            output.appendLE(flags)
            output.appendLE(entry.method)
            output.appendLE(record.modTime)
            output.appendLE(record.modDate)
            output.appendLE(entry.checksum)
            output.appendLE(UInt32(entry.data.count))
            output.appendLE(UInt32(record.uncompressedSize))
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))
            output.append(contentsOf: name)
            output.append(entry.data)

            central.appendLE(UInt32(0x0201_4B50))
            central.appendLE(record.versionMadeBy)
            central.appendLE(UInt16(20))
            central.appendLE(flags)
            central.appendLE(entry.method)
            central.appendLE(record.modTime)
            central.appendLE(record.modDate)
            central.appendLE(entry.checksum)
            central.appendLE(UInt32(entry.data.count))
            central.appendLE(UInt32(record.uncompressedSize))
            central.appendLE(UInt16(name.count))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(UInt16(0))
            central.appendLE(record.externalAttributes)
            central.appendLE(offset)
            central.append(contentsOf: name)
        }
        let directoryOffset = UInt32(output.count)
        output.append(central)
        output.appendLE(UInt32(0x0605_4B50))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt16(entries.count))
        output.appendLE(UInt32(central.count))
        output.appendLE(directoryOffset)
        output.appendLE(UInt16(0))
        return output
    }
}

extension Data {
    /// Appends `value` as two little-endian bytes.
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    /// Appends `value` as four little-endian bytes.
    mutating func appendLE(_ value: UInt32) {
        appendLE(UInt16(truncatingIfNeeded: value))
        appendLE(UInt16(truncatingIfNeeded: value >> 16))
    }
}
