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
