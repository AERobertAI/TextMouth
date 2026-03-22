import Foundation
import Markdown

func runMarkdownCacheTests() {
print("\n--- Markdown Cache Service Tests ---")

test("Multi-chapter Markdown splits correctly") {
    let markdown = """
    <!-- chapter: Introduction -->
    # Introduction

    This is the introduction paragraph.

    <!-- chapter: Chapter One -->
    # Chapter One

    This is chapter one content.

    <!-- chapter: Chapter Two -->
    # Chapter Two

    Chapter two has more text here.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test Book", author: "Author")
    try assertEqual(content.chapters.count, 3, "Should have 3 chapters")
    try assertEqual(content.chapters[0].title, "Introduction")
    try assertEqual(content.chapters[1].title, "Chapter One")
    try assertEqual(content.chapters[2].title, "Chapter Two")
}

test("Single chapter without markers treated as one chapter") {
    let markdown = """
    # My Book

    This is the whole book in one chapter with no separators.

    ## Section One

    Some section content here.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "My Book", author: "Author")
    try assertEqual(content.chapters.count, 1, "Should be a single chapter")
    try assertTrue(content.chapters[0].text.contains("whole book"), "Should contain text")
}

test("Chapter markers with empty content are skipped") {
    let markdown = """
    <!-- chapter: Empty Chapter -->

    <!-- chapter: Has Content -->
    # Real Content

    This chapter has actual text.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    try assertEqual(content.chapters.count, 1, "Empty chapter should be skipped")
    try assertEqual(content.chapters[0].title, "Has Content")
}

test("Headings extracted from cached Markdown chapters") {
    let markdown = """
    <!-- chapter: Chapter One -->
    # Chapter One

    Introduction text.

    ## Section A

    Section A text.

    ## Section B

    Section B text.

    <!-- chapter: Chapter Two -->
    # Chapter Two

    ## Section C

    Section C text.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    try assertEqual(content.chapters.count, 2, "Should have 2 chapters")
    // Chapter 1 should have headings
    let ch1Headings = content.chapters[0].headings
    try assertGreater(ch1Headings.count, 0, "Chapter 1 should have headings")
    // Chapter 2 should have headings
    let ch2Headings = content.chapters[1].headings
    try assertGreater(ch2Headings.count, 0, "Chapter 2 should have headings")
    // allHeadings should have correct chapter indices
    let all = content.allHeadings
    let ch0Headings = all.filter { $0.chapterIndex == 0 }
    let ch1AllHeadings = all.filter { $0.chapterIndex == 1 }
    try assertGreater(ch0Headings.count, 0, "Should have chapter 0 headings in allHeadings")
    try assertGreater(ch1AllHeadings.count, 0, "Should have chapter 1 headings in allHeadings")
}

test("Plain text to Markdown preserves heading markers") {
    let text = """
    # Chapter One

    This is the first chapter.

    ## Section

    Section content here.
    """
    // The plain text extraction should preserve existing markdown headings
    let converted = convertPlainTextToMarkdown(text)
    try assertTrue(converted.contains("# Chapter One"), "Should preserve markdown headings")
    try assertTrue(converted.contains("## Section"), "Should preserve ## headings")
}

test("Plain text ALL-CAPS lines converted to headings") {
    let text = """
    PROLOGUE

    The story begins here.

    CHAPTER ONE

    First chapter content.
    """
    let converted = convertPlainTextToMarkdown(text)
    try assertTrue(converted.contains("## PROLOGUE"), "Should convert ALL-CAPS to ## heading")
    try assertTrue(converted.contains("## CHAPTER ONE"), "Should convert ALL-CAPS chapter title")
}

test("Roundtrip: Markdown cached and loaded produces consistent content") {
    let original = """
    <!-- chapter: Chapter 1 -->
    # Chapter 1

    The quick brown fox.

    <!-- chapter: Chapter 2 -->
    # Chapter 2

    Jumped over the lazy dog.
    """
    let content = parseMultiChapterCacheMarkdown(original, title: "Roundtrip", author: "Test")
    try assertEqual(content.chapters.count, 2)
    let ch1Text = content.chapters[0].text
    let ch2Text = content.chapters[1].text
    try assertTrue(ch1Text.contains("quick brown fox"), "Chapter 1 text preserved")
    try assertTrue(ch2Text.contains("lazy dog"), "Chapter 2 text preserved")
}

test("Chapter title extracted from first heading") {
    let heading = extractFirstMarkdownHeading("# Introduction\n\nSome text here.\n\n## Section")
    try assertEqual(heading, "Introduction", "Should extract first heading text")
}

test("No heading returns empty string") {
    let heading = extractFirstMarkdownHeading("Just some plain text without any headings.")
    try assertEqual(heading, "", "Should return empty for no headings")
}

test("Global offsets are consistent across cached chapters") {
    let markdown = """
    <!-- chapter: Chapter 1 -->
    # Chapter 1

    First chapter text.

    <!-- chapter: Chapter 2 -->
    # Chapter 2

    Second chapter text.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    let ch1Start = content.chapterStartOffset(0)
    let ch2Start = content.chapterStartOffset(1)
    try assertEqual(ch1Start, 0, "Chapter 1 starts at 0")
    try assertGreater(ch2Start, 0, "Chapter 2 starts after chapter 1")
    try assertEqual(ch2Start, content.chapters[0].text.count, "Chapter 2 start equals chapter 1 length")
}

} // end runMarkdownCacheTests

// MARK: - Cache Service Helpers (test implementations)

/// Parse multi-chapter Markdown with chapter markers into DocumentContent
func parseMultiChapterCacheMarkdown(_ markdown: String, title: String, author: String) -> DocumentContent {
    let chapterMarkerPrefix = "<!-- chapter: "
    let chapterMarkerSuffix = " -->"

    let lines = markdown.components(separatedBy: "\n")
    var sections: [(title: String, content: String)] = []
    var currentTitle = ""
    var currentLines: [String] = []
    var foundMarker = false

    for line in lines {
        if line.hasPrefix(chapterMarkerPrefix) && line.hasSuffix(chapterMarkerSuffix) {
            if foundMarker {
                let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    sections.append((title: currentTitle, content: content))
                }
            }
            let titleStart = line.index(line.startIndex, offsetBy: chapterMarkerPrefix.count)
            let titleEnd = line.index(line.endIndex, offsetBy: -chapterMarkerSuffix.count)
            currentTitle = String(line[titleStart..<titleEnd])
            currentLines = []
            foundMarker = true
        } else {
            currentLines.append(line)
        }
    }

    if foundMarker {
        let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            sections.append((title: currentTitle, content: content))
        }
    }

    if sections.isEmpty {
        let content = (try? parseMarkdown(markdown: markdown, title: title))
            ?? DocumentContent(title: title, author: author, chapters: [Chapter(title: title, text: markdown, headings: [])])
        return DocumentContent(title: content.title.isEmpty ? title : content.title,
                               author: author, chapters: content.chapters)
    }

    var chapters: [Chapter] = []
    for section in sections {
        if let parsed = try? parseMarkdown(markdown: section.content, title: section.title),
           let chapter = parsed.chapters.first {
            var ch = chapter
            if !section.title.isEmpty { ch.title = section.title }
            chapters.append(ch)
        }
    }

    let docTitle = chapters.first?.title.isEmpty == false ? chapters.first!.title : title
    return DocumentContent(title: docTitle, author: author, chapters: chapters)
}

/// Convert plain text to Markdown with heading detection
func convertPlainTextToMarkdown(_ text: String) -> String {
    let lines = text.components(separatedBy: .newlines)
    var result: [String] = []
    var setextLines: Set<Int> = []

    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 3 && (trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" })) {
            setextLines.insert(index)
        }
    }

    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if setextLines.contains(index) { result.append(line); continue }
        if trimmed.hasPrefix("#") { result.append(line); continue }
        if !trimmed.isEmpty && index + 1 < lines.count && setextLines.contains(index + 1) {
            result.append(line); continue
        }
        if trimmed.count >= 3 && trimmed.count <= 80
            && trimmed.uppercased() == trimmed
            && trimmed.rangeOfCharacter(from: .letters) != nil {
            let letters = trimmed.filter { $0.isLetter }
            if letters.count >= 3 {
                result.append("## \(trimmed)")
                continue
            }
        }
        result.append(line)
    }
    return result.joined(separator: "\n")
}

/// Extract first heading text from Markdown
func extractFirstMarkdownHeading(_ markdown: String) -> String {
    for line in markdown.components(separatedBy: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            if level >= 1 && level <= 6 {
                return String(trimmed.dropFirst(level))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces)
            }
        }
    }
    return ""
}
