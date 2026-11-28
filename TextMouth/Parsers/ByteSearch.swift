import Foundation

// MARK: - Searching for One Byte

/// Searches for one byte in text or data with the C library's `memchr`, which
/// reads many bytes at a time, instead of walking the bytes one by one through
/// Swift's generic iterator (the November 14, 2026 import speed-up, H2 and H3).
///
/// The answer is the one the plain walk gives: whether the byte is among the
/// bytes, nothing more. Text that is not held as contiguous UTF-8 (a string
/// bridged from Foundation, say) is searched by the walk, so the answer never
/// depends on how the text is stored.
enum ByteSearch {
    /// Whether `byte` is one of the `count` bytes at `start`. A buffer with no
    /// bytes holds none.
    static func contains(_ byte: UInt8, in start: UnsafeRawPointer?, count: Int) -> Bool {
        guard let start, count > 0 else { return false }
        return memchr(start, Int32(byte), count) != nil
    }
}

extension String {
    /// Whether the UTF-8 form of this string holds `byte`: the same answer as
    /// `utf8.contains(byte)`, found by `memchr` when the string is stored as
    /// contiguous UTF-8.
    func containsUTF8Byte(_ byte: UInt8) -> Bool {
        let found = utf8.withContiguousStorageIfAvailable {
            ByteSearch.contains(byte, in: $0.baseAddress, count: $0.count)
        }
        return found ?? utf8.contains(byte)
    }

    /// The lines of this string, split at each line feed Character and keeping
    /// the empty ones: exactly `split(separator: "\n", omittingEmptySubsequences: false)`.
    ///
    /// That split reads every Character of the string. A line feed Character
    /// is a line feed byte (0x0A) that no carriage return directly precedes
    /// (CR LF is one Character, which is not a line feed), so a string with
    /// no such byte has none, and is the one line it is: the answer for
    /// nearly every run of a Word document, found by `memchr`. A string with
    /// the byte is split the long way, so the answer never depends on the
    /// shortcut. An empty string gives one empty line, as the split does.
    func splitAtLineFeeds() -> [Substring] {
        guard containsUTF8Byte(0x0A) else { return [self[...]] }
        return split(separator: "\n", omittingEmptySubsequences: false)
    }
}

extension Data {
    /// Whether this data holds `byte`: the same answer as `contains(byte)`,
    /// found by `memchr`.
    func containsByte(_ byte: UInt8) -> Bool {
        withUnsafeBytes { ByteSearch.contains(byte, in: $0.baseAddress, count: $0.count) }
    }
}
