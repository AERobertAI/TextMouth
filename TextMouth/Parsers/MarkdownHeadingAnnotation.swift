import Foundation

/// A navigation destination stored separately from the words read aloud.
/// Base64 keeps arbitrary TOC labels out of Markdown/HTML syntax in content.md.
struct MarkdownHeadingAnnotation: Codable {
    var level: Int
    var text: String

    private static let prefix = "<!-- textmouth-heading: "
    private static let suffix = " -->"

    /// Emit an inert HTML comment that the cache parser can recognize.
    var markdown: String {
        guard let data = try? Self.encoder.encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString() + Self.suffix
    }

    /// Sorted keys make every encoding of an annotation identical. Without
    /// them JSONEncoder's key order can differ between encodings, so the same
    /// destination produced different markers and content.md was not
    /// reproducible. Decoding ignores key order, so existing markers still read.
    /// A fresh encoder per use, as before, keeps parallel cache workers from
    /// sharing a non-Sendable instance.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    /// Accept only our complete, well-formed annotation; ordinary source HTML
    /// comments remain invisible to both speech and the headings navigator.
    static func decode(_ comment: String) -> Self? {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix),
              let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count).dropLast(suffix.count))),
              let annotation = try? JSONDecoder().decode(Self.self, from: data),
              (1...6).contains(annotation.level), !annotation.text.isEmpty else { return nil }
        return annotation
    }
}
