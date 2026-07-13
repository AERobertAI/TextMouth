import Foundation

enum PlainTextParser {

    static func parse(text: String, title: String = "Untitled") -> DocumentContent {
        let headings = extractHeadings(from: text)

        let chapter = Chapter(title: title, text: text, headings: headings)

        return DocumentContent(
            title: title,
            author: "Unknown",
            chapters: [chapter]
        )
    }

    /// Heuristic heading detection for plain text files.
    /// Detects (mutually exclusive, in priority order):
    /// 1. Lines starting with # (markdown-style)
    /// 2. Lines followed by === (h1) or --- (h2) underlines
    /// 3. Short all-caps lines (likely section headers)
    private static func extractHeadings(from text: String) -> [Heading] {
        var headings: [Heading] = []
        let lines = text.components(separatedBy: .newlines)

        var currentOffset = 0
        var setextLines: Set<Int> = []  // Track lines consumed by setext detection

        // First pass: identify setext underline lines so we don't double-count
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" })) {
                setextLines.insert(index)
            }
        }

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var matched = false

            // Skip underline-only lines (they're part of setext headings)
            if setextLines.contains(index) {
                currentOffset += line.utf16Length + 1
                continue
            }

            // 1. Markdown-style headings
            if trimmed.hasPrefix("#") {
                let level = trimmed.prefix(while: { $0 == "#" }).count
                if level >= 1 && level <= 6 {
                    let headingText = String(trimmed.dropFirst(level))
                        .trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        .trimmingCharacters(in: .whitespaces)
                    if !headingText.isEmpty {
                        headings.append(Heading(
                            level: min(level, 6),
                            text: headingText,
                            characterOffset: currentOffset
                        ))
                        matched = true
                    }
                }
            }

            // 2. Setext-style: line followed by === (h1) or --- (h2)
            if !matched && !trimmed.isEmpty && index + 1 < lines.count && setextLines.contains(index + 1) {
                let nextLine = lines[index + 1].trimmingCharacters(in: .whitespaces)
                if nextLine.allSatisfy({ $0 == "=" }) {
                    headings.append(Heading(level: 1, text: trimmed, characterOffset: currentOffset))
                    matched = true
                } else if nextLine.allSatisfy({ $0 == "-" }) {
                    headings.append(Heading(level: 2, text: trimmed, characterOffset: currentOffset))
                    matched = true
                }
            }

            // 3. All-caps short lines (mutually exclusive with above)
            if !matched && trimmed.count >= 3 && trimmed.count <= 80
                        && trimmed.uppercased() == trimmed
                        && trimmed.rangeOfCharacter(from: .letters) != nil {
                let letters = trimmed.filter { $0.isLetter }
                if letters.count >= 3 {
                    headings.append(Heading(level: 2, text: trimmed, characterOffset: currentOffset))
                }
            }

            currentOffset += line.utf16Length + 1
        }

        return headings
    }
}
