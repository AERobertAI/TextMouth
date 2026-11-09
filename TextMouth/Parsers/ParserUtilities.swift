import Foundation
import AVFoundation

// MARK: - Voice Quality Helpers

extension AVSpeechSynthesisVoice {
    /// Human-readable label for voice quality tier.
    /// Used in both global settings and per-book voice pickers.
    var qualityLabel: String {
        switch quality {
        case .default: return "Standard"
        case .enhanced: return "Enhanced"
        case .premium: return "Premium"
        @unknown default: return "Unknown"
        }
    }
}

// MARK: - Parser Utilities

/// Shared utilities used across multiple document parsers.
/// Centralizes common XML/text processing to avoid duplication.
enum ParserUtilities {

    /// Strip the namespace prefix from an XML element name.
    /// e.g. "dc:title" → "title", "opf:item" → "item"
    static func stripNamespacePrefix(_ elementName: String) -> String {
        elementName.components(separatedBy: ":").last ?? elementName
    }

    /// Split an archive/package reference into path and fragment parts.
    /// e.g. "chapter.html#p1" -> ("chapter.html", "p1")
    static func splitFragment(_ reference: String) -> (path: String, fragment: String) {
        let parts = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts.first ?? "")
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        return (
            path.removingPercentEncoding ?? path,
            fragment.removingPercentEncoding ?? fragment
        )
    }

    /// Resolve a package-internal reference against the file that contains it.
    ///
    /// DAISY and EPUB references are paths inside ZIP archives or extracted
    /// package directories, so URL.standardizedFileURL is the wrong tool here:
    /// it treats paths as host filesystem URLs. This keeps paths package-relative
    /// while normalizing ".", "..", duplicate slashes, percent encoding, and
    /// optional fragments.
    static func resolvedPackagePath(
        _ reference: String,
        relativeTo sourcePath: String,
        preserveFragment: Bool = true
    ) -> String {
        let split = splitFragment(reference)
        let sourceDirectory = (sourcePath as NSString).deletingLastPathComponent

        let combined: String
        if split.path.hasPrefix("/") {
            combined = String(split.path.drop(while: { $0 == "/" }))
        } else if split.path.isEmpty {
            combined = sourceDirectory
        } else if sourceDirectory.isEmpty {
            combined = split.path
        } else {
            combined = "\(sourceDirectory)/\(split.path)"
        }

        let normalizedPath = normalizePackagePath(combined)
        guard preserveFragment, !split.fragment.isEmpty else {
            return normalizedPath
        }
        return "\(normalizedPath)#\(split.fragment)"
    }

    /// Normalize whitespace in Markdown output:
    /// - Trim trailing whitespace from each line
    /// - Collapse 3+ consecutive blank lines down to 2
    /// - Trim leading/trailing whitespace from the whole string
    ///
    /// A line ends at each line feed. Its trailing whitespace is the run of
    /// Unicode White_Space scalars that ends it: exactly what the regular
    /// expression `\s+$` once removed line by line, since `\s` matches
    /// exactly those scalars, and every other scalar `$` treats as a line
    /// end is one of them. One pass over the text replaces a regular
    /// expression and a new string for every line (PERF25: 50 ms and 11 MB
    /// of memory per MB of Markdown).
    static func normalizeMarkdownWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars
        var result = ""
        result.reserveCapacity(text.utf8.count)
        // Blank lines in a row so far, and whether a line has been written,
        // after which each line kept begins with the line feed before it.
        var blankCount = 0
        var wroteLine = false
        var lineStart = scalars.startIndex
        while true {
            let lineEnd = text.utf8[lineStart...].firstIndex(of: UInt8(ascii: "\n")) ?? scalars.endIndex
            var contentEnd = lineEnd
            while contentEnd > lineStart {
                let previous = scalars.index(before: contentEnd)
                guard scalars[previous].properties.isWhitespace else { break }
                contentEnd = previous
            }
            // Collapse 3+ consecutive blank lines to 2
            blankCount = contentEnd == lineStart ? blankCount + 1 : 0
            if blankCount <= 2 {
                if wroteLine { result.append("\n") }
                result.append(contentsOf: Substring(scalars[lineStart..<contentEnd]))
                wroteLine = true
            }
            guard lineEnd < scalars.endIndex else { break }
            lineStart = scalars.index(after: lineEnd)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePackagePath(_ path: String) -> String {
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !stack.isEmpty {
                    stack.removeLast()
                }
            default:
                stack.append(String(component))
            }
        }
        return stack.joined(separator: "/")
    }
}

// MARK: - Soft Hyphens

extension ParserUtilities {

    /// `text` without its soft hyphens (U+00AD): the character itself, and
    /// every way markup spells it (`&shy;`, and a numeric reference to 173
    /// in decimal or hexadecimal with any letter case and any number of
    /// leading zeros, with or without its semicolon). A publisher puts them
    /// inside words to say where a line may break; a person reading sees none
    /// in the middle of a line, and nothing that reads the words should meet
    /// one in the middle of a word. Measured on November 9, 2026, a soft
    /// hyphen left in a word:
    /// - hides the word from Search in Book (`hyphen` does not find
    ///   `hy\u{AD}phen`, nor does a regular expression);
    /// - becomes a visible hyphen in braille (dots 3-6) and keeps the word
    ///   from contracting;
    /// - is spoken as the hyphen it is taken for, a longer word with a
    ///   break in it (`Scripts/agents/probes/speech-soft-hyphen-probe.swift`).
    ///
    /// One rule for every reader that uses it: the Kindle readers (a KF8
    /// book's markup and its contents' labels, and a MOBI 6 book's), so
    /// that a soft hyphen is left out in one place.
    static func removingSoftHyphens(_ text: String) -> String {
        let bytes = Array(text.utf8)
        // The common case, no soft hyphen at all, costs one scan and no copy.
        var first: Int?
        var position = 0
        while position < bytes.count {
            if softHyphenLength(in: bytes, at: position) != nil { first = position; break }
            position += 1
        }
        guard let start = first else { return text }
        var result = Array(bytes[..<start])
        result.reserveCapacity(bytes.count)
        position = start
        while position < bytes.count {
            if let length = softHyphenLength(in: bytes, at: position) {
                position += length
            } else {
                result.append(bytes[position])
                position += 1
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// The length in bytes of the soft hyphen that begins at `position` in
    /// UTF-8 `bytes`, or nil when none does.
    private static func softHyphenLength(in bytes: [UInt8], at position: Int) -> Int? {
        let byte = bytes[position]
        // The character: C2 AD.
        if byte == 0xC2 { return position + 1 < bytes.count && bytes[position + 1] == 0xAD ? 2 : nil }
        guard byte == UInt8(ascii: "&"), position + 1 < bytes.count else { return nil }
        // &shy; in any letter case.
        if hasASCIIName(shyName, in: bytes, at: position + 1) { return 1 + shyName.count }
        // &#173; &#xAD; and their spellings.
        guard bytes[position + 1] == UInt8(ascii: "#") else { return nil }
        var cursor = position + 2
        var radix = 10
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: "x") || bytes[cursor] == UInt8(ascii: "X") {
            radix = 16
            cursor += 1
        }
        var value = 0
        var digits = 0
        while cursor < bytes.count, digits < 12, let digit = digitValue(bytes[cursor], radix: radix) {
            value = value * radix + digit
            digits += 1
            cursor += 1
        }
        guard digits > 0, value == 0xAD else { return nil }
        if cursor < bytes.count, bytes[cursor] == UInt8(ascii: ";") { cursor += 1 }
        return cursor - position
    }

    /// The name of the entity for a soft hyphen, with its semicolon.
    private static let shyName = Array("shy;".utf8)

    /// Whether the lower-case ASCII `name` is in `bytes` at `position`, in any letter case.
    private static func hasASCIIName(_ name: [UInt8], in bytes: [UInt8], at position: Int) -> Bool {
        guard position + name.count <= bytes.count else { return false }
        for (index, expected) in name.enumerated() {
            let byte = bytes[position + index]
            let lowered = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
            if lowered != expected { return false }
        }
        return true
    }

    /// The value of the digit `byte` in `radix` (10 or 16), or nil.
    private static func digitValue(_ byte: UInt8, radix: Int) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where radix == 16: return Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F") where radix == 16: return Int(byte - UInt8(ascii: "A")) + 10
        default: return nil
        }
    }
}
