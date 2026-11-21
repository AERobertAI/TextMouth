import Foundation

/// A window onto a KFX container's bytes, every read of which is checked
/// against the window. A KFX file is untrusted input: each offset, length,
/// and count in it is read through here, so a field that points outside the
/// data throws `MOBIError.damaged` (the one wording of a damaged Kindle book)
/// instead of trapping on an index.
///
/// KFX integers are little-endian (KFX-FORMAT-NOTES-2026-11-05.md, part 4).
/// The window shares the file's storage (arrays copy on write), so a part
/// of the file is a range, never a copy.
struct KFXView {
    /// The whole file, shared by every window onto it.
    let bytes: [UInt8]
    /// The part of `bytes` this window shows.
    let range: Range<Int>

    /// A window onto all of `bytes`.
    init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.range = 0..<bytes.count
    }

    /// A window onto `range` of `bytes`, which the caller has checked.
    private init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        self.range = range
    }

    /// How many bytes the window shows.
    var count: Int { range.count }

    /// Throws unless the `length` bytes from `offset` lie inside the window.
    /// - Parameter what: Names the field read, for the error's detail.
    func require(_ offset: Int, _ length: Int, _ what: String) throws {
        // Written without adding, so no value from the file can overflow.
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw MOBIError.damaged("\(what) lies outside the book's data")
        }
    }

    /// The byte at `offset`.
    func uint8(_ offset: Int, _ what: String) throws -> Int {
        try require(offset, 1, what)
        return Int(bytes[range.lowerBound + offset])
    }

    /// The little-endian 16-bit number at `offset`.
    func uint16(_ offset: Int, _ what: String) throws -> Int {
        Int(try unsigned(offset, 2, what))
    }

    /// The little-endian 32-bit number at `offset`.
    func uint32(_ offset: Int, _ what: String) throws -> Int {
        Int(try unsigned(offset, 4, what))
    }

    /// The little-endian 64-bit number at `offset`, as an `Int`. A value
    /// past `Int.max` is no offset or length any file holds, so it is
    /// damage.
    func uint64(_ offset: Int, _ what: String) throws -> Int {
        let value = try unsigned(offset, 8, what)
        guard value <= UInt64(Int.max) else {
            throw MOBIError.damaged("\(what) is larger than any file")
        }
        return Int(value)
    }

    /// The little-endian unsigned number of `width` bytes (up to 8) at `offset`.
    private func unsigned(_ offset: Int, _ width: Int, _ what: String) throws -> UInt64 {
        try require(offset, width, what)
        let start = range.lowerBound + offset
        var value: UInt64 = 0
        for index in (0..<width).reversed() { value = value << 8 | UInt64(bytes[start + index]) }
        return value
    }

    /// A window onto the `length` bytes from `offset`.
    func slice(_ offset: Int, _ length: Int, _ what: String) throws -> KFXView {
        try require(offset, length, what)
        let start = range.lowerBound + offset
        return KFXView(bytes: bytes, range: start..<(start + length))
    }

    /// Whether the bytes from `offset` begin with `magic`.
    func hasPrefix(_ magic: [UInt8], at offset: Int) -> Bool {
        guard (try? require(offset, magic.count, "")) != nil else { return false }
        let start = range.lowerBound + offset
        return bytes[start..<(start + magic.count)].elementsEqual(magic)
    }
}
