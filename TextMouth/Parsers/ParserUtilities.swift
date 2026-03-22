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

    /// Normalize whitespace in Markdown output:
    /// - Trim trailing whitespace from each line
    /// - Collapse 3+ consecutive blank lines down to 2
    /// - Trim leading/trailing whitespace from the whole string
    static func normalizeMarkdownWhitespace(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")

        // Trim trailing whitespace from each line
        lines = lines.map {
            $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }

        // Collapse 3+ consecutive blank lines to 2
        var result: [String] = []
        var blankCount = 0
        for line in lines {
            if line.isEmpty {
                blankCount += 1
                if blankCount <= 2 { result.append(line) }
            } else {
                blankCount = 0
                result.append(line)
            }
        }

        return result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
