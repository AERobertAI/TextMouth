import Foundation

func runPDFEdgeCaseTests() {
print("\n--- PDF Edge Case Tests ---")

// Note: PDFKit-dependent tests run via the PDFIntegrationTests.swift file
// using xcrun swift. These tests focus on logic that doesn't require PDFKit.

// Test heading level calculation logic
test("PDF heading level: 2x body size is h1") {
    let level = testHeadingLevel(fontSize: 24, bodySize: 12)
    try assertEqual(level, 1, "2x body size should be h1")
}

test("PDF heading level: 1.5x body size is h2") {
    let level = testHeadingLevel(fontSize: 18, bodySize: 12)
    try assertEqual(level, 2, "1.5x body size should be h2")
}

test("PDF heading level: 1.2x body size is h3") {
    let level = testHeadingLevel(fontSize: 14.5, bodySize: 12)
    try assertEqual(level, 3, "1.2x body size should be h3")
}

test("PDF heading level: 1.15x body size is h4") {
    let level = testHeadingLevel(fontSize: 13.9, bodySize: 12)
    try assertEqual(level, 4, "1.15x body size should be h4")
}

test("PDF heading level: barely larger is h5") {
    let level = testHeadingLevel(fontSize: 13, bodySize: 12)
    try assertEqual(level, 5, "Barely larger should be h5")
}

test("PDF heading level: zero body size returns h2") {
    let level = testHeadingLevel(fontSize: 14, bodySize: 0)
    try assertEqual(level, 2, "Zero body size should default to h2")
}

// Test body font size detection logic
test("PDF body font detection picks most common size") {
    // Simulate character counts by font size
    let sizeCounts: [Double: Int] = [
        12.0: 5000,  // body text
        18.0: 200,   // headings
        24.0: 50,    // title
    ]
    let bodySize = testDetectBodyFontSize(sizeCounts: sizeCounts)
    try assertTrue(abs(bodySize - 12.0) < 0.1, "Should detect 12pt as body, got \(bodySize)")
}

test("PDF body font detection handles single size") {
    let sizeCounts: [Double: Int] = [11.0: 1000]
    let bodySize = testDetectBodyFontSize(sizeCounts: sizeCounts)
    try assertTrue(abs(bodySize - 11.0) < 0.1, "Should detect 11pt as body")
}

test("PDF body font detection handles empty returns default") {
    let sizeCounts: [Double: Int] = [:]
    let bodySize = testDetectBodyFontSize(sizeCounts: sizeCounts)
    try assertTrue(abs(bodySize - 12.0) < 0.1, "Empty should return default 12pt")
}

// Test heading deduplication
test("PDF heading dedup removes exact case-insensitive match") {
    let text = "PREFACE\n\nSome body text about the topic."
    let result = testRemoveHeadingDuplicate("Preface", from: text)
    try assertTrue(!result.contains("PREFACE"), "Should remove exact match")
    try assertTrue(result.contains("Some body text"), "Should keep body text")
}

test("PDF heading dedup removes substring matches") {
    let text = "Part I\n\nContent follows here."
    let result = testRemoveHeadingDuplicate("Part I: Introduction", from: text)
    try assertTrue(!result.contains("Part I"), "Should remove short substring match")
    try assertTrue(result.contains("Content follows"), "Should keep body text")
}

test("PDF heading dedup preserves long text that happens to contain heading") {
    let text = "This is a long paragraph that mentions Chapter 1 Introduction in the middle of it."
    let result = testRemoveHeadingDuplicate("Chapter 1 Introduction", from: text)
    // The line is longer than 60 chars, so it should NOT be removed as a substring match
    try assertTrue(result.contains("long paragraph"), "Should preserve long lines")
}

test("PDF heading dedup preserves unrelated text") {
    let text = "Some completely unrelated text.\n\nAnother paragraph."
    let result = testRemoveHeadingDuplicate("Chapter 1", from: text)
    try assertTrue(result.contains("unrelated"), "Should keep unrelated text")
    try assertTrue(result.contains("Another"), "Should keep all paragraphs")
}

// Test line joining heuristics
test("PDF line joining merges continuation lines") {
    let lines = [
        TestPDFLine(text: "This is the beginning of a long paragraph that", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "continues on the next line with more content.", isHeading: false, headingLevel: 0, fontSize: 12),
    ]
    let result = testJoinLines(lines)
    try assertTrue(result.contains("paragraph that continues"), "Should join continuation lines")
}

test("PDF line joining breaks at headings") {
    let lines = [
        TestPDFLine(text: "End of previous section.", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "New Section", isHeading: true, headingLevel: 2, fontSize: 18),
        TestPDFLine(text: "Beginning of new section.", isHeading: false, headingLevel: 0, fontSize: 12),
    ]
    let result = testJoinLines(lines)
    try assertTrue(result.contains("## New Section"), "Should have heading marker")
    try assertTrue(!result.contains("section.New"), "Should not join body with heading")
}

test("PDF line joining breaks at font size changes") {
    let lines = [
        TestPDFLine(text: "Normal text here.", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "Different sized text.", isHeading: false, headingLevel: 0, fontSize: 16),
    ]
    let result = testJoinLines(lines)
    try assertTrue(!result.contains("here. Different"), "Should not join across font size changes")
}

test("PDF line joining breaks at list items") {
    let lines = [
        TestPDFLine(text: "Introduction:", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "- First item", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "- Second item", isHeading: false, headingLevel: 0, fontSize: 12),
    ]
    let result = testJoinLines(lines)
    try assertTrue(result.contains("- First item"), "Should keep list items separate")
    try assertTrue(result.contains("- Second item"), "Should keep second list item")
}

test("PDF line joining breaks at numbered list items") {
    let lines = [
        TestPDFLine(text: "Steps:", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "1. Do this first", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "2. Then do that", isHeading: false, headingLevel: 0, fontSize: 12),
    ]
    let result = testJoinLines(lines)
    try assertTrue(result.contains("1. Do this first"), "Should keep numbered items separate")
}

test("PDF line joining breaks at sentence end + capital start + short line") {
    let lines = [
        TestPDFLine(text: "End of paragraph.", isHeading: false, headingLevel: 0, fontSize: 12),
        TestPDFLine(text: "New paragraph start.", isHeading: false, headingLevel: 0, fontSize: 12),
    ]
    let result = testJoinLines(lines)
    // "New paragraph start." is < 40 chars, starts with capital, previous ends with period
    try assertTrue(!result.contains("paragraph. New paragraph"),
                   "Should break between sentences ending with period + short capitalized next line")
}

// Metadata edge case
test("PDF metadata returns value when only title is set") {
    // This tests the fix: metadata should be returned even when only one field is populated
    let metadata = testPDFMetadata(title: "My Book", author: "")
    try assertTrue(metadata != nil, "Should return metadata when title is present")
    try assertEqual(metadata?.title ?? "", "My Book")
}

test("PDF metadata returns value when only author is set") {
    let metadata = testPDFMetadata(title: "", author: "Author Name")
    try assertTrue(metadata != nil, "Should return metadata when author is present")
    try assertEqual(metadata?.author ?? "", "Author Name")
}

test("PDF metadata returns nil when both empty") {
    let metadata = testPDFMetadata(title: "", author: "")
    try assertTrue(metadata == nil, "Should return nil when both fields empty")
}

}

// MARK: - Test Helper Types and Functions

struct TestPDFLine {
    var text: String
    var isHeading: Bool
    var headingLevel: Int
    var fontSize: Double
}

struct TestPDFMetadataResult {
    var title: String
    var author: String
}

/// Mirrors PDFTextParser.headingLevelFromFontSize
func testHeadingLevel(fontSize: Double, bodySize: Double) -> Int {
    guard bodySize > 0 else { return 2 }
    let ratio = fontSize / bodySize
    if ratio >= 1.9 { return 1 }
    if ratio >= 1.5 { return 2 }
    if ratio >= 1.2 { return 3 }
    if ratio >= 1.15 { return 4 }
    return 5
}

/// Mirrors PDFTextParser.detectBodyFontSize logic
func testDetectBodyFontSize(sizeCounts: [Double: Int]) -> Double {
    return sizeCounts.max(by: { $0.value < $1.value })?.key ?? 12.0
}

/// Mirrors PDFTextParser.removeHeadingDuplicate
func testRemoveHeadingDuplicate(_ heading: String, from text: String) -> String {
    let headingLower = heading.lowercased()
    let lines = text.components(separatedBy: "\n")
    var result: [String] = []
    for line in lines {
        let trimmedLower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmedLower == headingLower { continue }
        if !trimmedLower.isEmpty && trimmedLower.count <= headingLower.count
            && headingLower.contains(trimmedLower) && trimmedLower.count < 60 {
            continue
        }
        result.append(line)
    }
    return result.joined(separator: "\n")
}

/// Mirrors PDFTextParser.joinLinesIntoParagraphs
func testJoinLines(_ lines: [TestPDFLine]) -> String {
    var markdown = ""
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if line.isHeading {
            let prefix = String(repeating: "#", count: max(1, min(line.headingLevel, 6)))
            markdown += "\n\(prefix) \(line.text)\n\n"
            i += 1; continue
        }
        var paragraph = line.text
        while i + 1 < lines.count {
            let nextLine = lines[i + 1]
            if nextLine.isHeading { break }
            if abs(nextLine.fontSize - line.fontSize) > 1.0 { break }
            let endsWithTerminator = paragraph.hasSuffix(".") || paragraph.hasSuffix("!")
                || paragraph.hasSuffix("?") || paragraph.hasSuffix(":") || paragraph.hasSuffix(";")
            let nextIsShort = nextLine.text.count < 40
            let nextStartsCapital = nextLine.text.first?.isUppercase ?? false
            if endsWithTerminator && nextStartsCapital && nextIsShort { break }
            if nextLine.text.hasPrefix("•") || nextLine.text.hasPrefix("-")
                || nextLine.text.hasPrefix("–") { break }
            let nextTrimmed = nextLine.text.trimmingCharacters(in: .whitespaces)
            if let firstChar = nextTrimmed.first, firstChar.isNumber {
                let prefix = nextTrimmed.prefix(while: { $0.isNumber })
                if nextTrimmed.dropFirst(prefix.count).hasPrefix(".") { break }
            }
            paragraph += " " + nextLine.text
            i += 1
        }
        markdown += "\n\(paragraph)\n"
        i += 1
    }
    return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Mirrors PDF metadata logic (with fix)
func testPDFMetadata(title: String, author: String) -> TestPDFMetadataResult? {
    guard !title.isEmpty || !author.isEmpty else { return nil }
    return TestPDFMetadataResult(title: title, author: author)
}
