import Foundation

// MARK: - Plain Text Split into Lines, by Bytes

/// Splits plain text into its trimmed lines in one pass over its UTF-8 bytes
/// (the November 14, 2026 import speed-up, H4).
///
/// It makes exactly what
/// `text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }`
/// makes, which built a string for every piece of the text, then another
/// for every line it trimmed (a fifth of a plain-text import):
/// - **Where a line ends.** At each scalar of `CharacterSet.newlines` and at
///   no other: line feed, vertical tab, form feed, and carriage return
///   (U+000A to U+000D), next line (U+0085), line separator (U+2028), and
///   paragraph separator (U+2029). Each ends a line by itself, so a
///   carriage return and a line feed in a row are two endings and an empty
///   line between (the reader normalizes line endings first, so that never
///   happens in a book's text). The text always has a last line, empty when
///   the text is empty or ends with a line ending.
/// - **How a line is trimmed.** Of every scalar of `CharacterSet.whitespaces`
///   (the spaces of Unicode category Zs and the tab), at both ends. The
///   space and the tab are trimmed here, as bytes; a line with any other
///   byte at an edge after that (a no-break space, an ideographic space, a
///   combining mark, any letter beyond ASCII) is given to
///   `trimmingCharacters(in:)` as before, so the set itself is never
///   restated here.
enum PlainTextLines {

    /// The trimmed lines of `text`, as described above.
    static func trimmedLines(of text: String) -> [String] {
        // Foundation hands back strings that are not stored as UTF-8; a copy
        // made contiguous once is read in place.
        var contiguous = text
        contiguous.makeContiguousUTF8()
        let lines = contiguous.utf8.withContiguousStorageIfAvailable { split($0) }
        return lines ?? referenceLines(of: text)
    }

    /// The lines the Foundation way: what `trimmedLines(of:)` must equal. It
    /// serves a string with no contiguous UTF-8 (none after
    /// `makeContiguousUTF8()`, but the compiler cannot know it) and the tests.
    static func referenceLines(of text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Cuts `bytes`, UTF-8 text, at each line ending and trims each piece.
    private static func split(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var lines: [String] = []
        var lineStart = 0
        var position = 0
        while position < bytes.count {
            // How many bytes the line ending here takes, or 0 for none.
            let endingLength = lineEndingLength(in: bytes, at: position)
            if endingLength > 0 {
                lines.append(trimmedLine(bytes, from: lineStart, to: position))
                position += endingLength
                lineStart = position
            } else {
                position += 1
            }
        }
        // The last line, which no ending follows.
        lines.append(trimmedLine(bytes, from: lineStart, to: bytes.count))
        return lines
    }

    /// The length in bytes of the `CharacterSet.newlines` scalar that begins
    /// at `position`, or 0 when none does. UTF-8 text is read from the start
    /// of a scalar here: a byte 0xC2 or 0xE2 is always a lead byte, never the
    /// middle of another scalar.
    private static func lineEndingLength(in bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> Int {
        switch bytes[position] {
        case 0x0A...0x0D:
            return 1
        case 0xC2:
            // U+0085, next line: C2 85.
            return position + 1 < bytes.count && bytes[position + 1] == 0x85 ? 2 : 0
        case 0xE2:
            // U+2028, line separator, and U+2029, paragraph separator: E2 80 A8 and E2 80 A9.
            guard position + 2 < bytes.count, bytes[position + 1] == 0x80 else { return 0 }
            return bytes[position + 2] == 0xA8 || bytes[position + 2] == 0xA9 ? 3 : 0
        default:
            return 0
        }
    }

    /// The line held by `bytes[start..<end]`, trimmed.
    private static func trimmedLine(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String {
        var first = start
        var last = end
        // The space and the tab, the two whitespace scalars of one byte.
        while first < last, isSpaceOrTab(bytes[first]) { first += 1 }
        while last > first, isSpaceOrTab(bytes[last - 1]) { last -= 1 }
        guard first < last else { return "" }
        let line = String(decoding: UnsafeBufferPointer(rebasing: bytes[first..<last]), as: UTF8.self)
        // A byte beyond ASCII at either edge may be part of a whitespace
        // scalar (U+00A0, U+3000, and the rest of Zs): Foundation decides.
        return bytes[first] >= 0x80 || bytes[last - 1] >= 0x80 ? line.trimmingCharacters(in: .whitespaces) : line
    }

    /// Whether `byte` is a space or a tab.
    private static func isSpaceOrTab(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }
}
