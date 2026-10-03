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
