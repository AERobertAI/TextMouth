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
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return Self.prefix + data.base64EncodedString() + Self.suffix
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
