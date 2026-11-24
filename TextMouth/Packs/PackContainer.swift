import CBZip2
import Compression
import Foundation

/// A sentence for the debug log saying why a pack, or a blob of one, cannot be used. Each pack reader turns it into its
/// own failure type, so a reader's callers never see this one.
struct PackContainerFailure: Error, CustomStringConvertible, Equatable {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

/// The container both of TextMouth's packs are written in (FR39's `Strings.pack`, FR40's `BrailleTables.pack`), and the
/// one reader of it: the header, the directory, the bounds, and the decoding of a blob by its method. What a blob holds
/// is each pack's own business. The writer is `Scripts/packs/packfile.py`.
///
/// The layout, little-endian:
/// - header, 48 bytes: the pack's magic (4 bytes), its version (u16), flags (u16, zero), a SHA-256 of what it was built
///   from (32 bytes), the pack's count (u32: the number of IDs, or of table files), and the number of blobs (u32);
/// - directory, straight after the header, one 32-byte record for each blob: its name (12 bytes of ASCII, padded with
///   NULs), its offset from the start of the file, its compressed size, its raw size, its entry count, and its method
///   (u32 each);
/// - the blobs, each compressed by its record's method: 0, an xz stream that Apple's `COMPRESSION_LZMA` decodes, or 1, a
///   bzip2 stream that the system's own `libbz2` decodes (`BZ2_bzBuffToBuffDecompress`). A method this reader does not
///   know refuses the pack.
///
/// A pack is untrusted bytes: a damaged or hostile file must fail, never trap. So the file is mapped, and nothing is
/// read before it is checked: the magic, the version, the flags, the counts, the directory's bounds, each blob's bounds,
/// and its raw size (a limit that stops a decompression bomb). Reads go through bounds-checked loads (`loadUnaligned` on
/// a checked range), never a pointer cast or a force unwrap on file data, and a decoded blob must come out at exactly its
/// raw size.
///
/// Foundation, the Compression framework, and the system's libbz2 (the CBZip2 module) only; no stored state beyond the
/// mapped bytes and the directory.
struct PackContainer: Sendable {
    /// What one pack format says of itself: how this reader recognises it, and the limits that stop a hostile header.
    struct Format: Sendable {
        /// The four bytes that begin the file.
        let magic: [UInt8]
        /// The only version this reader accepts.
        let version: UInt16
        /// The most the header's count may claim.
        let largestCount: Int
        /// The most blobs a directory may name.
        let largestBlobCount: Int
        /// The largest raw size of any blob, which keeps a hostile size from asking for gigabytes.
        let largestRawSize: Int
        /// What a pack adds to the checks of one directory record, in the order of the file: given the blob's name, the blob, and
        /// the header's count, the sentence that says what is wrong with it, or nil. It runs after the record's bounds and raw
        /// size are checked and before the next record is read, so a pack with two faults is refused for the first of them in
        /// file order, with the sentence it always got.
        let recordCheck: (@Sendable (_ name: String, _ blob: Blob, _ count: Int) -> String?)?

        init(
            magic: [UInt8], version: UInt16, largestCount: Int, largestBlobCount: Int, largestRawSize: Int,
            recordCheck: (@Sendable (_ name: String, _ blob: Blob, _ count: Int) -> String?)? = nil
        ) {
            self.magic = magic
            self.version = version
            self.largestCount = largestCount
            self.largestBlobCount = largestBlobCount
            self.largestRawSize = largestRawSize
            self.recordCheck = recordCheck
        }
    }

    /// A blob's place and sizes, from the directory.
    struct Blob: Sendable {
        let offset: Int
        let compressedSize: Int
        let rawSize: Int
        /// The entries the directory says the blob holds; the pack's reader checks it against what it expects.
        let count: Int
        let method: Method
    }

    /// How a blob is compressed: the values of the directory record's method field.
    enum Method: UInt32, Sendable {
        /// An xz stream (LZMA2), decoded by Apple's Compression framework.
        case lzma = 0
        /// A bzip2 stream, decoded by the system's libbz2.
        case bzip2 = 1
    }

    /// The bytes of the whole file, memory-mapped when read from a URL.
    private let data: Data
    /// The directory by blob name.
    let blobs: [String: Blob]
    /// The header's count: how many IDs or files the pack says it holds.
    let count: Int
    /// The SHA-256 the header records of what the pack was built from.
    let digest: [UInt8]

    // MARK: - Limits of the directory

    private static let headerSize = 48
    private static let recordSize = 32
    private static let nameSize = 12

    // MARK: - Opening

    /// The pack in the file at `url`, mapped rather than read, so its size costs address space, not memory, until a blob
    /// is decoded.
    init(contentsOf url: URL, format: Format) throws {
        let mapped: Data
        do {
            mapped = try Data(contentsOf: url, options: .alwaysMapped)
        } catch {
            throw PackContainerFailure("the pack cannot be read: \(error.localizedDescription)")  // l10n: no (English text for the debug log, never shown)
        }
        try self.init(data: mapped, format: format)
    }

    /// The pack in `data`, whose header and directory are checked here; a blob is checked when it is decoded.
    init(data: Data, format: Format) throws {
        let parsed = try data.withUnsafeBytes { bytes in try Self.parseDirectory(bytes, format: format) }
        self.data = data
        self.blobs = parsed.blobs
        self.count = parsed.count
        self.digest = parsed.digest
    }

    /// Checks the header, and reads and checks the directory of the pack in `bytes`.
    private static func parseDirectory(
        _ bytes: UnsafeRawBufferPointer, format: Format
    ) throws -> (count: Int, digest: [UInt8], blobs: [String: Blob]) {
        guard bytes.count >= headerSize else { throw PackContainerFailure("the pack is shorter than its header") }  // l10n: no (English text for the debug log, never shown)
        guard Array(bytes[0..<format.magic.count]) == format.magic else { throw PackContainerFailure("the pack's magic is wrong") }  // l10n: no (English text for the debug log, never shown)
        guard let version = bytes.littleEndian(UInt16.self, at: 4), version == format.version else {
            throw PackContainerFailure("the pack's format version is not \(format.version)")  // l10n: no (English text for the debug log, never shown)
        }
        guard bytes.littleEndian(UInt16.self, at: 6) == 0 else { throw PackContainerFailure("the pack sets flags this reader does not know") }  // l10n: no (English text for the debug log, never shown)
        guard let count = bytes.littleEndian(UInt32.self, at: 40).map(Int.init), count <= format.largestCount,
              let blobCount = bytes.littleEndian(UInt32.self, at: 44).map(Int.init), blobCount <= format.largestBlobCount
        else { throw PackContainerFailure("the pack's counts are out of range") }  // l10n: no (English text for the debug log, never shown)
        let directoryEnd = headerSize + blobCount * recordSize
        guard directoryEnd <= bytes.count else { throw PackContainerFailure("the pack's directory is cut short") }  // l10n: no (English text for the debug log, never shown)

        var blobs: [String: Blob] = [:]
        for record in 0..<blobCount {
            let at = headerSize + record * recordSize
            let name = try blobName(bytes, at: at)
            guard let offset = bytes.littleEndian(UInt32.self, at: at + nameSize).map(Int.init),
                  let compressedSize = bytes.littleEndian(UInt32.self, at: at + nameSize + 4).map(Int.init),
                  let rawSize = bytes.littleEndian(UInt32.self, at: at + nameSize + 8).map(Int.init),
                  let entryCount = bytes.littleEndian(UInt32.self, at: at + nameSize + 12).map(Int.init),
                  let methodCode = bytes.littleEndian(UInt32.self, at: at + nameSize + 16)
            else { throw PackContainerFailure("the directory record of \(name) is cut short") }  // l10n: no (English text for the debug log, never shown)
            guard let method = Method(rawValue: methodCode) else {
                throw PackContainerFailure("the blob \(name) uses compression method \(methodCode), which this reader does not know")  // l10n: no (English text for the debug log, never shown)
            }
            // Each blob lies wholly inside the file, after the directory; a u32 offset and size cannot overflow an Int.
            guard offset >= directoryEnd, offset + compressedSize <= bytes.count else {
                throw PackContainerFailure("the blob \(name) lies outside the pack")  // l10n: no (English text for the debug log, never shown)
            }
            guard rawSize <= format.largestRawSize else { throw PackContainerFailure("the blob \(name) claims \(rawSize) bytes") }  // l10n: no (English text for the debug log, never shown)
            let blob = Blob(offset: offset, compressedSize: compressedSize, rawSize: rawSize, count: entryCount, method: method)
            if let sentence = format.recordCheck?(name, blob, count) { throw PackContainerFailure(sentence) }
            guard blobs[name] == nil else { throw PackContainerFailure("the blob \(name) is listed twice") }  // l10n: no (English text for the debug log, never shown)
            blobs[name] = blob
        }
        return (count, Array(bytes[8..<40]), blobs)
    }

    /// The name in the directory record at `offset`: ASCII letters, digits, and hyphens up to the first NUL, the rest
    /// NULs.
    private static func blobName(_ bytes: UnsafeRawBufferPointer, at offset: Int) throws -> String {
        let field = Array(bytes[offset..<(offset + nameSize)])
        let length = field.firstIndex(of: 0) ?? field.count
        guard length > 0, field[length...].allSatisfy({ $0 == 0 }), field[..<length].allSatisfy(isNameByte) else {
            throw PackContainerFailure("a directory record has no valid name")  // l10n: no (English text for the debug log, never shown)
        }
        return String(decoding: field[..<length], as: UTF8.self)
    }

    /// Whether `byte` may appear in a blob's name: an ASCII letter, digit, or hyphen.
    private static func isNameByte(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-")
    }

    // MARK: - Reading

    /// The decoded bytes of the blob `name`: one decode into a buffer of the directory's raw size plus one byte. The
    /// extra byte tells a stream that is longer than its raw size (an LZMA decoder would stop at the buffer's end and
    /// look exact) from a right one; the size written must be the raw size, to the byte.
    func decodedBlob(named name: String) throws -> [UInt8] {
        guard let blob = blobs[name] else { throw PackContainerFailure("the pack has no \(name) blob") }  // l10n: no (English text for the debug log, never shown)
        return try data.withUnsafeBytes { bytes -> [UInt8] in
            // Re-checked here, against the bytes actually in hand, though the directory was checked on opening.
            guard blob.offset >= 0, blob.compressedSize >= 0, blob.offset + blob.compressedSize <= bytes.count else {
                throw PackContainerFailure("the blob \(name) lies outside the pack")  // l10n: no (English text for the debug log, never shown)
            }
            if blob.rawSize == 0 { return [] }
            let source = UnsafeRawBufferPointer(rebasing: bytes[blob.offset..<(blob.offset + blob.compressedSize)])
            guard let sourceStart = source.baseAddress, source.count > 0 else {
                throw PackContainerFailure("the blob \(name) is empty but claims \(blob.rawSize) bytes")  // l10n: no (English text for the debug log, never shown)
            }
            var written = 0
            let decoded = [UInt8](unsafeUninitializedCapacity: blob.rawSize + 1) { buffer, count in
                guard let destination = buffer.baseAddress else { count = 0; return }
                written = Self.decode(blob.method, from: sourceStart, count: source.count, into: destination, capacity: buffer.count)
                count = written
            }
            guard written == blob.rawSize else {
                throw PackContainerFailure("the blob \(name) decodes to \(written) bytes, not \(blob.rawSize)")  // l10n: no (English text for the debug log, never shown)
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
    /// only way a pack reader reads a number from the file.
    fileprivate func littleEndian<T: FixedWidthInteger>(_ type: T.Type, at offset: Int) -> T? {
        guard offset >= 0, offset <= count - MemoryLayout<T>.size else { return nil }
        return T(littleEndian: loadUnaligned(fromByteOffset: offset, as: T.self))
    }
}
