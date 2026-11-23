import CBZip2
import Compression
import Foundation

/// The reader of `Strings.pack`, format version 2 (FR39): the IDs, the English, the translators' notes, and one
/// compressed blob of entries for each language, in one file.
///
/// The layout, little-endian:
/// - header, 48 bytes: the magic `TMSP`, the version (u16), flags (u16, zero), the SHA-256 of the catalog it was built
///   from (32 bytes), the number of IDs (u32), and the number of blobs (u32);
/// - directory, straight after the header, one 32-byte record for each blob: its name (12 bytes of ASCII, padded with
///   NULs: `ids`, `notes`, `en`, `es`, ...), its offset from the start of the file, its compressed size, its raw size,
///   its entry count, and its method (u32 each);
/// - the blobs, each compressed by its record's method: 0, an xz stream that Apple's `COMPRESSION_LZMA` decodes, or 1,
///   a bzip2 stream that the system's own `libbz2` decodes (`BZ2_bzBuffToBuffDecompress`). The builder keeps the
///   smaller of the two for each blob. A method this reader does not know refuses the pack.
///
/// The pack is untrusted bytes: a damaged or hostile file must give English, never a trap. So the file is mapped, and
/// nothing is read before it is checked: the magic, the version, the flags, the directory's bounds, each blob's
/// bounds, its raw size (a limit that stops a decompression bomb), and its entry count. Reads go through bounds-checked
/// loads (`loadUnaligned` on a checked range), never a pointer cast or a force unwrap on file data, and a decoded blob
/// is checked again for its size, its entry count, and UTF-8 before a byte of it is used.
///
/// Foundation, the Compression framework, and the system's libbz2 (the CBZip2 module) only; no stored state beyond the
/// mapped bytes and the directory.
struct InterfaceTextPack: InterfaceTextTables {
    /// A blob's place and sizes, from the directory.
    private struct Blob: Sendable {
        let offset: Int
        let compressedSize: Int
        let rawSize: Int
        let count: Int
        let method: Method
    }

    /// How a blob is compressed: the values of the directory record's method field.
    private enum Method: UInt32, Sendable {
        /// An xz stream (LZMA2), decoded by Apple's Compression framework.
        case lzma = 0
        /// A bzip2 stream, decoded by the system's libbz2.
        case bzip2 = 1
    }

    /// The bytes of the whole file, memory-mapped when read from a URL.
    private let data: Data
    /// The directory by blob name.
    private let blobs: [String: Blob]
    /// How many IDs the header says there are; every blob holds that many entries.
    let idCount: Int

    // MARK: - Limits

    /// The file's name inside an app's resources.
    static let resourceName = "Strings"  // l10n: no (English text for the debug log, never shown)
    static let resourceExtension = "pack"

    private static let magic: [UInt8] = Array("TMSP".utf8)
    private static let supportedVersion: UInt16 = 2
    private static let headerSize = 48
    private static let recordSize = 32
    private static let nameSize = 12
    /// The most blobs a directory may name: 25 languages, English, the IDs, and the notes come to 28, so this leaves
    /// room and stops a header that claims millions of records.
    private static let largestBlobCount = 256
    /// The most IDs the header may claim, far above the thousands the app has.
    private static let largestIDCount = 1_000_000
    /// The largest raw size of any blob: the biggest real one is under 300 KB, so this keeps a hostile size from
    /// asking for gigabytes.
    private static let largestRawSize = 16 * 1024 * 1024

    // MARK: - Opening

    /// The pack in the main bundle, or nil when the bundle has none (`Strings.pack` is added to the apps by a later
    /// phase). Throws when it is there and cannot be read.
    static func inMainBundle() throws -> InterfaceTextPack? {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension) else { return nil }
        return try InterfaceTextPack(contentsOf: url)
    }

    /// The pack in the file at `url`, mapped rather than read, so the 1.3 MB costs address space, not memory, until a
    /// blob is decoded.
    init(contentsOf url: URL) throws {
        let mapped: Data
        do {
            mapped = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw InterfaceTextFailure("the pack cannot be read: \(error.localizedDescription)")  // l10n: no (English text for the debug log, never shown)
        }
        try self.init(data: mapped)
    }

    /// The pack in `data`, whose header and directory are checked here; a blob is checked when it is decoded.
    init(data: Data) throws {
        let parsed = try data.withUnsafeBytes { bytes in try Self.parseDirectory(bytes) }
        self.data = data
        self.blobs = parsed.blobs
        self.idCount = parsed.idCount
    }

    /// Checks the header, and reads and checks the directory of the pack in `bytes`.
    private static func parseDirectory(_ bytes: UnsafeRawBufferPointer) throws -> (idCount: Int, blobs: [String: Blob]) {
        guard bytes.count >= headerSize else { throw InterfaceTextFailure("the pack is shorter than its header") }  // l10n: no (English text for the debug log, never shown)
        guard Array(bytes[0..<magic.count]) == magic else { throw InterfaceTextFailure("the pack's magic is wrong") }  // l10n: no (English text for the debug log, never shown)
        guard let version = bytes.littleEndian(UInt16.self, at: 4), version == supportedVersion else {
            throw InterfaceTextFailure("the pack's format version is not \(supportedVersion)")  // l10n: no (English text for the debug log, never shown)
        }
        guard bytes.littleEndian(UInt16.self, at: 6) == 0 else { throw InterfaceTextFailure("the pack sets flags this reader does not know") }  // l10n: no (English text for the debug log, never shown)
        guard let idCount = bytes.littleEndian(UInt32.self, at: 40).map(Int.init), idCount <= largestIDCount,
              let blobCount = bytes.littleEndian(UInt32.self, at: 44).map(Int.init), blobCount <= largestBlobCount
        else { throw InterfaceTextFailure("the pack's counts are out of range") }  // l10n: no (English text for the debug log, never shown)
        let directoryEnd = headerSize + blobCount * recordSize
        guard directoryEnd <= bytes.count else { throw InterfaceTextFailure("the pack's directory is cut short") }  // l10n: no (English text for the debug log, never shown)

        var blobs: [String: Blob] = [:]
        for record in 0..<blobCount {
            let at = headerSize + record * recordSize
            let name = try blobName(bytes, at: at)
            guard let offset = bytes.littleEndian(UInt32.self, at: at + nameSize).map(Int.init),
                  let compressedSize = bytes.littleEndian(UInt32.self, at: at + nameSize + 4).map(Int.init),
                  let rawSize = bytes.littleEndian(UInt32.self, at: at + nameSize + 8).map(Int.init),
                  let count = bytes.littleEndian(UInt32.self, at: at + nameSize + 12).map(Int.init),
                  let methodCode = bytes.littleEndian(UInt32.self, at: at + nameSize + 16)
            else { throw InterfaceTextFailure("the directory record of \(name) is cut short") }  // l10n: no (English text for the debug log, never shown)
            guard let method = Method(rawValue: methodCode) else {
                throw InterfaceTextFailure("the blob \(name) uses compression method \(methodCode), which this reader does not know")  // l10n: no (English text for the debug log, never shown)
            }
            // Each blob lies wholly inside the file, after the directory; a u32 offset and size cannot overflow an Int.
            guard offset >= directoryEnd, offset + compressedSize <= bytes.count else {
                throw InterfaceTextFailure("the blob \(name) lies outside the pack")  // l10n: no (English text for the debug log, never shown)
            }
            guard rawSize <= largestRawSize else { throw InterfaceTextFailure("the blob \(name) claims \(rawSize) bytes") }  // l10n: no (English text for the debug log, never shown)
            guard count == idCount else { throw InterfaceTextFailure("the blob \(name) has \(count) entries, not \(idCount)") }  // l10n: no (English text for the debug log, never shown)
            guard blobs[name] == nil else { throw InterfaceTextFailure("the blob \(name) is listed twice") }  // l10n: no (English text for the debug log, never shown)
            blobs[name] = Blob(offset: offset, compressedSize: compressedSize, rawSize: rawSize, count: count, method: method)
        }
        guard blobs["ids"] != nil else { throw InterfaceTextFailure("the pack has no ids blob") }  // l10n: no (English text for the debug log, never shown)
        return (idCount, blobs)
    }

    /// The name in the directory record at `offset`: ASCII letters, digits, and hyphens up to the first NUL, the rest
    /// NULs.
    private static func blobName(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws -> String {
        let field = Array(bytes[offset..<(offset + nameSize)])
        let length = field.firstIndex(of: 0) ?? field.count
        guard length > 0, field[length...].allSatisfy({ $0 == 0 }), field[..<length].allSatisfy(isNameByte) else {
            throw InterfaceTextFailure("a directory record has no valid name")  // l10n: no (English text for the debug log, never shown)
        }
        return String(decoding: field[..<length], as: UTF8.self)
    }

    /// Whether `byte` may appear in a blob's name: an ASCII letter, digit, or hyphen.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
    }

    // MARK: - Reading

    /// Whether the pack has a blob for `language`.
    func hasLanguage(_ language: String) -> Bool {
        language != "ids" && language != "notes" && blobs[language] != nil
    }

    func idList() throws -> InterfaceTextIDList {
        let bytes = try decodedBlob(named: "ids")
        guard let list = InterfaceTextIDList(blob: bytes, count: idCount) else {
            throw InterfaceTextFailure("the ids blob is not \(idCount) valid IDs in order")  // l10n: no (English text for the debug log, never shown)
        }
        return list
    }

    func entries(language: String) throws -> [InterfaceTextEntry] {
        guard hasLanguage(language) else { throw InterfaceTextFailure("the pack has no \(language) blob") }  // l10n: no (English text for the debug log, never shown)
        let bytes = try decodedBlob(named: language)
        do {
            return try InterfaceTextEntry.decodeAll(bytes, count: idCount, formCount: PluralRules.categories[language]?.count)
        } catch let failure as InterfaceTextFailure {
            throw InterfaceTextFailure("the \(language) blob: \(failure.description)")  // l10n: no (English text for the debug log, never shown)
        }
    }

    /// The translators' note of each ID, in the order of the IDs ("" for none); empty when the pack has no notes blob.
    /// A note is plain text, so each entry is read as one (a note never starts a plural).
    func notes() throws -> [String] {
        guard blobs["notes"] != nil else { return [] }
        let entries = try InterfaceTextEntry.decodeAll(try decodedBlob(named: "notes"), count: idCount, formCount: nil)
        return entries.map { entry in
            if case .plain(let text) = entry { return text }
            return ""
        }
    }

    /// The decoded bytes of the blob `name`: one decode into a buffer of the directory's raw size plus one byte. The
    /// extra byte tells a stream that is longer than its raw size (an LZMA decoder would stop at the buffer's end and
    /// look exact) from a right one; the size written must be the raw size, to the byte.
    private func decodedBlob(named name: String) throws -> [UInt8] {
        guard let blob = blobs[name] else { throw InterfaceTextFailure("the pack has no \(name) blob") }  // l10n: no (English text for the debug log, never shown)
        return try data.withUnsafeBytes { bytes -> [UInt8] in
            // Re-checked here, against the bytes actually in hand, though the directory was checked on opening.
            guard blob.offset >= 0, blob.compressedSize >= 0, blob.offset + blob.compressedSize <= bytes.count else {
                throw InterfaceTextFailure("the blob \(name) lies outside the pack")  // l10n: no (English text for the debug log, never shown)
            }
            if blob.rawSize == 0 { return [] }
            let source = UnsafeRawBufferPointer(rebasing: bytes[blob.offset..<(blob.offset + blob.compressedSize)])
            guard let sourceStart = source.baseAddress, source.count > 0 else {
                throw InterfaceTextFailure("the blob \(name) is empty but claims \(blob.rawSize) bytes")  // l10n: no (English text for the debug log, never shown)
            }
            var written = 0
            let decoded = [UInt8](unsafeUninitializedCapacity: blob.rawSize + 1) { buffer, count in
                guard let destination = buffer.baseAddress else { count = 0; return }
                written = Self.decode(blob.method, from: sourceStart, count: source.count, into: destination, capacity: buffer.count)
                count = written
            }
            guard written == blob.rawSize else {
                throw InterfaceTextFailure("the blob \(name) decodes to \(written) bytes, not \(blob.rawSize)")  // l10n: no (English text for the debug log, never shown)
            }
            return decoded
        }
    }

    /// Decodes the `count` bytes at `source` by `method` into the `capacity` bytes at `destination`, and returns how
    /// many bytes it wrote: 0 when the stream is damaged, cut short, or longer than `capacity`. The caller compares
    /// the result with the directory's raw size, so a wrong size of either kind is refused there.
    private static func decode(
        _ method: Method, from source: UnsafeRawPointer, count: Int, into destination: UnsafeMutablePointer<UInt8>, capacity: Int
    ) -> Int {
        switch method {
        case .lzma:
            return compression_decode_buffer(
                destination, capacity, source.assumingMemoryBound(to: UInt8.self), count, nil, COMPRESSION_LZMA
            )
        case .bzip2:
            // libbz2 takes 32-bit sizes: a count or capacity beyond that is refused rather than truncated.
            guard count <= Int(UInt32.max), capacity <= Int(UInt32.max) else { return 0 }
            var written = UInt32(capacity)
            // The one-shot call, not the streaming one: `small` 0 (the faster algorithm) and `verbosity` 0.
            let status = BZ2_bzBuffToBuffDecompress(
                UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self), &written,
                UnsafeMutableRawPointer(mutating: source).assumingMemoryBound(to: CChar.self), UInt32(count), 0, 0
            )
            // BZ_OK is 0; BZ_OUTBUFF_FULL (a stream longer than the buffer), BZ_UNEXPECTED_EOF (cut short),
            // BZ_DATA_ERROR (a failed CRC or a damaged structure), and the rest are all other values: none gives bytes.
            return status == BZ_OK ? Int(written) : 0
        }
    }
}

extension UnsafeRawBufferPointer {
    /// The little-endian integer of type `type` at `offset`, or nil when the whole of it is not inside the buffer. The
    /// only way the pack reader reads a number from the file.
    fileprivate func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else { return nil }
        return T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
