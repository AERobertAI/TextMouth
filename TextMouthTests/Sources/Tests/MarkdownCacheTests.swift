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

// MARK: - Heading-gap bug tests (EPUB with non-semantic headings)

test("Chapters with titles but no markdown headings get synthetic headings") {
    // Simulates an EPUB where HTML used styled <div> instead of <h1>-<h6>,
    // so the content.md has chapter markers with titles but no # headings
    let markdown = """
    <!-- chapter: LIZ: Red Pill Blue Pill -->
    It's a slow Tuesday afternoon, and you're coming to the end of your shift.

    <!-- chapter: ANWAR: Job Interview -->
    In the end, it all boils down to this: You'd do anything for your kids.

    <!-- chapter: TOYMAKER: The Leith Police -->
    The blinds are drawn in the living room of the flat.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Rule 34", author: "Stross")
    try assertEqual(content.chapters.count, 3, "Should have 3 chapters")

    // Each chapter should have a synthetic heading from its title
    let allHeadings = content.allHeadings
    try assertEqual(allHeadings.count, 3, "Should have 3 headings (one per chapter)")
    try assertEqual(allHeadings[0].text, "LIZ: Red Pill Blue Pill")
    try assertEqual(allHeadings[0].level, 1)
    try assertEqual(allHeadings[0].chapterIndex, 0)
    try assertEqual(allHeadings[1].text, "ANWAR: Job Interview")
    try assertEqual(allHeadings[1].chapterIndex, 1)
    try assertEqual(allHeadings[2].text, "TOYMAKER: The Leith Police")
    try assertEqual(allHeadings[2].chapterIndex, 2)
}

test("Chapters with existing markdown headings are not doubled") {
    // When the HTML did have proper <h1> tags, the heading should come from
    // the markdown parser, not be duplicated by synthetic injection
    let markdown = """
    <!-- chapter: Introduction -->
    # Introduction

    Welcome to the book.

    <!-- chapter: Chapter One -->
    # Chapter One

    The story begins.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    let ch1Headings = content.chapters[0].headings
    let ch2Headings = content.chapters[1].headings
    // Each chapter should have exactly 1 heading (from the markdown), not 2
    try assertEqual(ch1Headings.count, 1, "Should not duplicate headings")
    try assertEqual(ch2Headings.count, 1, "Should not duplicate headings")
}

test("Mixed chapters: some with headings, some without") {
    // Real-world EPUBs often have front matter without headings and body
    // chapters with headings (or vice versa with NCX-injected headings)
    let markdown = """
    <!-- chapter: Copyright -->
    Published by Penguin Books.

    <!-- chapter: Chapter 1 -->
    # Chapter 1

    The real content starts here.

    ## Section A

    Some section text.

    <!-- chapter: Chapter 2 -->
    More content without any heading markers in the markdown.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    try assertEqual(content.chapters.count, 3, "Should have 3 chapters")

    // Copyright: no markdown heading → synthetic heading
    try assertEqual(content.chapters[0].headings.count, 1)
    try assertEqual(content.chapters[0].headings[0].text, "Copyright")
    try assertEqual(content.chapters[0].headings[0].level, 1)

    // Chapter 1: has real headings from markdown
    try assertEqual(content.chapters[1].headings.count, 2, "Should have 2 real headings")
    try assertEqual(content.chapters[1].headings[0].text, "Chapter 1")
    try assertEqual(content.chapters[1].headings[1].text, "Section A")

    // Chapter 2: no markdown heading → synthetic heading
    try assertEqual(content.chapters[2].headings.count, 1)
    try assertEqual(content.chapters[2].headings[0].text, "Chapter 2")
}

test("Empty chapter title does not produce synthetic heading") {
    // Chapters with empty titles should not get a synthetic heading —
    // these are typically image-only or separator pages
    let markdown = """
    <!-- chapter:  -->
    Just an image page with no title.

    <!-- chapter: Real Chapter -->
    Actual content here.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Test", author: "Author")
    // The empty-titled chapter should have 0 headings
    try assertEqual(content.chapters[0].headings.count, 0, "Empty title should not produce heading")
    // The titled chapter should have 1 synthetic heading
    try assertEqual(content.chapters[1].headings.count, 1)
    try assertEqual(content.chapters[1].headings[0].text, "Real Chapter")
}

test("NCX-injected headings appear in cached markdown content") {
    // Simulates what extractFromEPUB now produces: when the NCX provides a
    // title and the HTML had no headings, a `# Title` line is prepended
    let markdown = """
    <!-- chapter: Part 1 -->
    # Part 1

    <!-- chapter: LIZ: Red Pill Blue Pill -->
    # LIZ: Red Pill Blue Pill

    It's a slow Tuesday afternoon.
    """
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Rule 34", author: "Stross")
    let allHeadings = content.allHeadings
    try assertEqual(allHeadings.count, 2)
    try assertEqual(allHeadings[0].text, "Part 1")
    try assertEqual(allHeadings[1].text, "LIZ: Red Pill Blue Pill")
    // The heading text should appear in the plain text content
    try assertTrue(content.chapters[1].text.contains("LIZ: Red Pill Blue Pill"),
                   "NCX-injected heading should be in plain text")
}

test("Heading count matches between chapters and allHeadings") {
    // Regression: the user saw 50 chapters but 0 headings. After the fix,
    // the heading count should match the number of titled chapters.
    let markdown = (1...50).map { i in
        "<!-- chapter: Chapter \(i) -->\nContent of chapter \(i)."
    }.joined(separator: "\n\n")
    let content = parseMultiChapterCacheMarkdown(markdown, title: "Big Book", author: "Author")
    try assertEqual(content.chapters.count, 50, "Should have 50 chapters")
    try assertEqual(content.allHeadings.count, 50, "Should have 50 headings (one per chapter)")
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

// MARK: - Cache version system tests (semantic versioning)

test("Book with nil cacheFormatVersion is considered outdated") {
    let book = Book(title: "Old Book", format: .epub, filePath: "", md5Hash: "abc",
                    cacheFormatVersion: nil)
    try assertTrue(isCacheOutdated(stored: book.cacheFormatVersion, current: "2.0.0"),
                   "nil version should be outdated")
}

test("Book with version 1.0.0 is outdated when current is 2.0.0") {
    let book = Book(title: "Old Book", format: .epub, filePath: "", md5Hash: "abc",
                    cacheFormatVersion: "1.0.0")
    try assertTrue(isCacheOutdated(stored: book.cacheFormatVersion, current: "2.0.0"),
                   "1.0.0 should be outdated when current is 2.0.0")
}

test("Book with current version does not need regeneration") {
    let book = Book(title: "Current Book", format: .epub, filePath: "", md5Hash: "abc",
                    cacheFormatVersion: "2.0.0")
    try assertTrue(!isCacheOutdated(stored: book.cacheFormatVersion, current: "2.0.0"),
                   "Current version should not need regeneration")
}

test("Semantic version comparison: minor version bump triggers regeneration") {
    try assertTrue(isCacheOutdated(stored: "2.0.0", current: "2.1.0"),
                   "2.0.0 should be outdated when current is 2.1.0")
    try assertTrue(!isCacheOutdated(stored: "2.1.0", current: "2.1.0"),
                   "Equal versions should not be outdated")
}

test("Semantic version comparison: patch version bump triggers regeneration") {
    try assertTrue(isCacheOutdated(stored: "2.0.0", current: "2.0.1"),
                   "2.0.0 should be outdated when current is 2.0.1")
}

test("Semantic version comparison: higher stored version is not outdated") {
    try assertTrue(!isCacheOutdated(stored: "3.0.0", current: "2.0.0"),
                   "3.0.0 should not be outdated when current is 2.0.0")
}

test("Audio books are never flagged for cache regeneration") {
    let book = Book(title: "Audio Book", format: .audio, filePath: "", md5Hash: "abc",
                    cacheFormatVersion: nil)
    // Audio books should be filtered out before the version check
    let needsCache = !book.format.isAudio
        && isCacheOutdated(stored: book.cacheFormatVersion, current: "2.0.0")
    try assertTrue(!needsCache, "Audio books should never need cache regeneration")
}

test("Cache version stamps correctly on Book struct") {
    var book = Book(title: "Test", format: .epub, filePath: "", md5Hash: "abc")
    try assertTrue(book.cacheFormatVersion == nil, "Should start with nil version")
    book.cacheFormatVersion = "2.0.0"
    try assertEqual(book.cacheFormatVersion!, "2.0.0", "Should be stamped with version 2.0.0")
}

test("Empty string cacheFormatVersion is considered outdated") {
    try assertTrue(isCacheOutdated(stored: "", current: "2.0.0"),
                   "Empty string should be treated as outdated")
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

            // Synthetic heading injection: if the chapter has a title but the
            // Markdown parser found no headings, create a level-1 heading at
            // offset 0 so the heading list always reflects the chapter structure.
            if ch.headings.isEmpty && !ch.title.isEmpty {
                ch.headings = [Heading(level: 1, text: ch.title, characterOffset: 0)]
            }

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

/// Compare two semantic version strings — returns true if stored is older than current
func isCacheOutdated(stored: String?, current: String) -> Bool {
    guard let stored = stored, !stored.isEmpty else { return true }
    let storedParts = stored.split(separator: ".").compactMap { Int($0) }
    let currentParts = current.split(separator: ".").compactMap { Int($0) }
    let s = storedParts + Array(repeating: 0, count: max(0, 3 - storedParts.count))
    let c = currentParts + Array(repeating: 0, count: max(0, 3 - currentParts.count))
    for i in 0..<3 {
        if s[i] < c[i] { return true }
        if s[i] > c[i] { return false }
    }
    return false
}
