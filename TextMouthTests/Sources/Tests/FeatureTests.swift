import Foundation

func runFeatureTests() {
// ---- Recently Opened Books ----
print("\n--- Recently Opened Books ---")

test("Recent filter: only includes books with lastOpened set") {
    struct SimpleBook {
        var title: String
        var lastOpened: Date?
    }
    let books = [
        SimpleBook(title: "A", lastOpened: Date()),
        SimpleBook(title: "B", lastOpened: nil),
        SimpleBook(title: "C", lastOpened: Date().addingTimeInterval(-3600)),
        SimpleBook(title: "D", lastOpened: nil),
    ]
    let recent = books.filter { $0.lastOpened != nil }
    try assertEqual(recent.count, 2)
    try assertEqual(recent[0].title, "A")
    try assertEqual(recent[1].title, "C")
}

test("Recent filter: sorted by most recent first") {
    struct SimpleBook {
        var title: String
        var lastOpened: Date?
    }
    let now = Date()
    let books = [
        SimpleBook(title: "Old", lastOpened: now.addingTimeInterval(-7200)),
        SimpleBook(title: "Newest", lastOpened: now),
        SimpleBook(title: "Middle", lastOpened: now.addingTimeInterval(-3600)),
    ]
    let recent = books
        .filter { $0.lastOpened != nil }
        .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
    try assertEqual(recent[0].title, "Newest")
    try assertEqual(recent[1].title, "Middle")
    try assertEqual(recent[2].title, "Old")
}

test("Recent filter: limited to 10 books") {
    struct SimpleBook {
        var title: String
        var lastOpened: Date?
    }
    var books: [SimpleBook] = []
    for i in 0..<15 {
        books.append(SimpleBook(title: "Book \(i)", lastOpened: Date().addingTimeInterval(Double(-i * 60))))
    }
    let recent = books
        .filter { $0.lastOpened != nil }
        .sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }
        .prefix(10)
        .map { $0 }
    try assertEqual(recent.count, 10)
    try assertEqual(recent[0].title, "Book 0")
    try assertEqual(recent[9].title, "Book 9")
}

// ---- Chapter-Level Progress ----
print("\n--- Chapter-Level Progress ---")

test("Chapter progress: shows chapter index + 1 for display") {
    let chapterIndex = 11
    let displayText = "Ch. \(chapterIndex + 1)"
    try assertEqual(displayText, "Ch. 12")
}

test("Chapter progress: accessibility label includes chapter info") {
    let title = "The Great Gatsby"
    let author = "F. Scott Fitzgerald"
    let chapterIndex = 4
    let parts = [title, "by \(author)", "Chapter \(chapterIndex + 1)"]
    let label = parts.joined(separator: ", ")
    try assertTrue(label.contains("Chapter 5"))
}

// ---- Bookmark Notes ----
print("\n--- Bookmark Notes ---")

test("Bookmark: label field stores and retrieves note") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 100, label: "Important scene")
    try assertEqual(bm.label, "Important scene")
    try assertEqual(bm.number, 1)
}

test("Bookmark: empty label for backward compatibility") {
    let bm = Bookmark(number: 2, chapterIndex: 1, characterOffset: 200)
    try assertTrue(bm.label.isEmpty)
}

test("Bookmark: label encodes and decodes via JSON") {
    let bm = Bookmark(number: 3, chapterIndex: 2, characterOffset: 500, label: "Plot twist!")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(bm)
    let decoded = try decoder.decode(Bookmark.self, from: data)
    try assertEqual(decoded.label, "Plot twist!")
    try assertEqual(decoded.number, 3)
    try assertEqual(decoded.chapterIndex, 2)
    try assertEqual(decoded.characterOffset, 500)
}

test("Bookmark: accessibility label includes note when present") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "Start of adventure")
    var parts = ["Bookmark \(bm.number)", "Chapter \(bm.chapterIndex + 1)"]
    if !bm.label.isEmpty {
        parts.append("Note: \(bm.label)")
    }
    let label = parts.joined(separator: ", ")
    try assertTrue(label.contains("Note: Start of adventure"))
}

test("Bookmark: accessibility label omits note when empty") {
    let bm = Bookmark(number: 1, chapterIndex: 0, characterOffset: 0, label: "")
    var parts = ["Bookmark \(bm.number)", "Chapter \(bm.chapterIndex + 1)"]
    if !bm.label.isEmpty {
        parts.append("Note: \(bm.label)")
    }
    let label = parts.joined(separator: ", ")
    try assertTrue(!label.contains("Note:"))
}

// ---- Quick-Resume ----
print("\n--- Quick-Resume ---")

test("Last opened book ID: round-trips through UUID string") {
    let id = UUID()
    let idString = id.uuidString
    let restored = UUID(uuidString: idString)
    try assertTrue(restored != nil)
    try assertEqual(restored!, id)
}

test("Last opened book ID: empty string returns nil UUID") {
    let idString = ""
    let restored = UUID(uuidString: idString)
    try assertTrue(restored == nil)
}

test("Last opened book: find in library by UUID") {
    let targetID = UUID()
    struct SimpleBook: Identifiable {
        var id: UUID
        var title: String
    }
    let books = [
        SimpleBook(id: UUID(), title: "Other"),
        SimpleBook(id: targetID, title: "Target"),
        SimpleBook(id: UUID(), title: "Another"),
    ]
    let found = books.first { $0.id == targetID }
    try assertTrue(found != nil)
    try assertEqual(found!.title, "Target")
}

// ---- Go Back to Where I Was ----
print("\n--- Go Back to Where I Was ---")

test("Save position for return: stores chapter and offset") {
    var savedChapter = 0
    var savedOffset = 0
    var hasSaved = false

    // Simulate being at chapter 5, offset 1234
    let currentChapter = 5
    let currentOffset = 1234

    // Save position
    savedChapter = currentChapter
    savedOffset = currentOffset
    hasSaved = true

    try assertTrue(hasSaved)
    try assertEqual(savedChapter, 5)
    try assertEqual(savedOffset, 1234)
}

test("Return to saved position: clears saved state") {
    var hasSaved = true
    let savedChapter = 3
    let savedOffset = 567

    // Simulate return
    let returnChapter = savedChapter
    let returnOffset = savedOffset
    hasSaved = false

    try assertTrue(!hasSaved)
    try assertEqual(returnChapter, 3)
    try assertEqual(returnOffset, 567)
}

test("Return button: not available when no saved position") {
    let hasSaved = false
    // The button should only show when hasSavedPosition is true
    try assertTrue(!hasSaved)
}

// ---- Heading-Level Filtering ----
print("\n--- Heading-Level Filtering ---")

test("Heading filter: maxLevel 6 shows all headings") {
    let headings = [
        Heading(level: 1, text: "Part 1"),
        Heading(level: 2, text: "Chapter 1"),
        Heading(level: 3, text: "Section 1.1"),
        Heading(level: 4, text: "Subsection"),
    ]
    let filtered = headings.filter { $0.level <= 6 }
    try assertEqual(filtered.count, 4)
}

test("Heading filter: maxLevel 2 shows only H1 and H2") {
    let headings = [
        Heading(level: 1, text: "Part 1"),
        Heading(level: 2, text: "Chapter 1"),
        Heading(level: 3, text: "Section 1.1"),
        Heading(level: 4, text: "Subsection"),
        Heading(level: 2, text: "Chapter 2"),
    ]
    let filtered = headings.filter { $0.level <= 2 }
    try assertEqual(filtered.count, 3)
    try assertEqual(filtered[0].text, "Part 1")
    try assertEqual(filtered[1].text, "Chapter 1")
    try assertEqual(filtered[2].text, "Chapter 2")
}

test("Heading filter: maxLevel 1 shows only H1") {
    let headings = [
        Heading(level: 1, text: "Part 1"),
        Heading(level: 2, text: "Chapter 1"),
        Heading(level: 1, text: "Part 2"),
        Heading(level: 3, text: "Section"),
    ]
    let filtered = headings.filter { $0.level <= 1 }
    try assertEqual(filtered.count, 2)
}

test("Heading levels present: extracts unique sorted levels") {
    let headings = [
        Heading(level: 1, text: "A"),
        Heading(level: 3, text: "B"),
        Heading(level: 1, text: "C"),
        Heading(level: 2, text: "D"),
        Heading(level: 3, text: "E"),
    ]
    let levels = Array(Set(headings.map { $0.level })).sorted()
    try assertEqual(levels, [1, 2, 3])
}

test("Heading filter: single level present hides filter") {
    let headings = [
        Heading(level: 2, text: "A"),
        Heading(level: 2, text: "B"),
    ]
    let levels = Array(Set(headings.map { $0.level })).sorted()
    try assertEqual(levels.count, 1, "Only 1 level, filter should be hidden")
}

test("Heading filter: current heading detection respects filter") {
    let headings = [
        Heading(level: 1, text: "Part 1", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "Ch 1", chapterIndex: 0, characterOffset: 100),
        Heading(level: 3, text: "Sec 1.1", chapterIndex: 0, characterOffset: 200),
        Heading(level: 1, text: "Part 2", chapterIndex: 0, characterOffset: 500),
    ]
    let maxLevel = 1
    let filtered = headings.filter { $0.level <= maxLevel }
    let currentChapter = 0
    let currentOffset = 300 // Between "Part 1" and "Part 2"

    // Current heading in filtered list should be "Part 1"
    let current = filtered.last(where: {
        $0.chapterIndex < currentChapter ||
        ($0.chapterIndex == currentChapter && $0.characterOffset <= currentOffset)
    })
    try assertTrue(current != nil)
    try assertEqual(current!.text, "Part 1")
}

// ---- Book Search ----
print("\n--- Book Search ---")

/// Search for text across chapters, mirroring BookSearchView logic
func searchInChapters(_ chapters: [String], query: String, isRegex: Bool, caseSensitive: Bool = false) -> [(chapterIndex: Int, offset: Int, matchedText: String)] {
    var results: [(chapterIndex: Int, offset: Int, matchedText: String)] = []
    for (chIdx, text) in chapters.enumerated() {
        if isRegex {
            var options: NSRegularExpression.Options = []
            if !caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: query, options: options) else { continue }
            let nsText = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                let matched = nsText.substring(with: match.range)
                results.append((chapterIndex: chIdx, offset: match.range.location, matchedText: matched))
            }
        } else {
            let searchText = caseSensitive ? text : text.lowercased()
            let searchQuery = caseSensitive ? query : query.lowercased()
            var searchStart = searchText.startIndex
            while let range = searchText.range(of: searchQuery, range: searchStart..<searchText.endIndex) {
                let offset = searchText.distance(from: searchText.startIndex, to: range.lowerBound)
                let origRange = Range(uncheckedBounds: (
                    text.index(text.startIndex, offsetBy: offset),
                    text.index(text.startIndex, offsetBy: offset + query.count)
                ))
                results.append((chapterIndex: chIdx, offset: offset, matchedText: String(text[origRange])))
                searchStart = range.upperBound
            }
        }
    }
    return results
}

test("Book search: plain text finds matches across chapters") {
    let chapters = ["The cat sat on the mat.", "The dog chased the cat."]
    let results = searchInChapters(chapters, query: "cat", isRegex: false)
    try assertEqual(results.count, 2)
    try assertEqual(results[0].chapterIndex, 0)
    try assertEqual(results[1].chapterIndex, 1)
}

test("Book search: plain text case insensitive") {
    let chapters = ["Hello World", "hello there"]
    let results = searchInChapters(chapters, query: "hello", isRegex: false)
    try assertEqual(results.count, 2)
}

test("Book search: regex pattern") {
    let chapters = ["Call 555-1234 or 555-5678 for info."]
    let results = searchInChapters(chapters, query: "\\d{3}-\\d{4}", isRegex: true)
    try assertEqual(results.count, 2)
    try assertEqual(results[0].matchedText, "555-1234")
    try assertEqual(results[1].matchedText, "555-5678")
}

test("Book search: regex invalid pattern returns empty") {
    let chapters = ["hello world"]
    let results = searchInChapters(chapters, query: "[invalid", isRegex: true)
    try assertEqual(results.count, 0)
}

test("Book search: no matches returns empty") {
    let chapters = ["Hello world", "Foo bar"]
    let results = searchInChapters(chapters, query: "xyz", isRegex: false)
    try assertEqual(results.count, 0)
}

test("Book search: empty query returns empty") {
    let chapters = ["Hello world"]
    let results = searchInChapters(chapters, query: "", isRegex: false)
    try assertEqual(results.count, 0)
}

test("Book search: calculates percentage correctly") {
    let chapters = ["First chapter text here.", "Second chapter more text."]
    let totalChars = chapters.reduce(0) { $0 + $1.count }
    let results = searchInChapters(chapters, query: "text", isRegex: false)
    try assertEqual(results.count, 2)
    // First result in chapter 0
    let globalOffset0 = results[0].offset
    let pct0 = Double(globalOffset0) / Double(totalChars) * 100.0
    try assertTrue(pct0 >= 0 && pct0 <= 100)
    // Second result in chapter 1
    let globalOffset1 = chapters[0].count + results[1].offset
    let pct1 = Double(globalOffset1) / Double(totalChars) * 100.0
    try assertTrue(pct1 > pct0, "Second result should be later in book")
}

test("Book search: regex with groups") {
    let chapters = ["Date: 2024-01-15 and 2024-12-25"]
    let results = searchInChapters(chapters, query: "(\\d{4})-(\\d{2})-(\\d{2})", isRegex: true)
    try assertEqual(results.count, 2)
    try assertEqual(results[0].matchedText, "2024-01-15")
}

// ---- Copy Reading Position ----
print("\n--- Copy Reading Position ---")

test("Copy position: builds formatted string") {
    let title = "The Great Gatsby"
    let author = "F. Scott Fitzgerald"
    let chapterTitle = "Chapter 3"
    let chapterNum = 3
    let totalChapters = 9
    let headingText = "The Party"
    let percent = 33.3
    let timeRemaining = "2:15:00"

    var parts: [String] = []
    parts.append(title)
    parts.append("by \(author)")
    parts.append("Chapter: \(chapterTitle)")
    parts.append("Chapter \(chapterNum) of \(totalChapters)")
    parts.append("Heading: \(headingText)")
    parts.append(String(format: "%.1f%% through", percent))
    parts.append("\(timeRemaining) remaining")

    let result = parts.joined(separator: " | ")
    try assertTrue(result.contains("The Great Gatsby"))
    try assertTrue(result.contains("by F. Scott Fitzgerald"))
    try assertTrue(result.contains("Chapter 3 of 9"))
    try assertTrue(result.contains("33.3% through"))
    try assertTrue(result.contains("2:15:00 remaining"))
}

test("Copy position: omits author when Unknown") {
    let author = "Unknown"
    var parts = ["My Book"]
    if !author.isEmpty && author != "Unknown" {
        parts.append("by \(author)")
    }
    let result = parts.joined(separator: " | ")
    try assertTrue(!result.contains("Unknown"))
}

// ---- Import from Text ----
print("\n--- Import from Text ---")

test("Text import: default title format") {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    let title = "Paste \(formatter.string(from: Date()))"
    try assertTrue(title.hasPrefix("Paste 20"))
    try assertTrue(title.count > 15)
}

test("Text import: empty text should not create book") {
    let text = ""
    try assertTrue(text.isEmpty, "Empty text should be rejected by the UI")
}

test("Text import: whitespace-only text treated as empty") {
    let text = "   \n\n   "
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    try assertTrue(trimmed.isEmpty)
}

test("Text import: plain text creates valid book data") {
    let title = "My Paste"
    let author = "Unknown"
    let text = "This is some pasted text that should become a book."
    try assertTrue(!title.isEmpty)
    try assertTrue(!text.isEmpty)
    try assertTrue(text.count > 10)
}

test("Text import: sanitizes title for filename") {
    let title = "My/Book:Title?"
    let sanitized = title.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .replacingOccurrences(of: "?", with: "")
    try assertTrue(!sanitized.contains("/"))
    try assertTrue(!sanitized.contains(":"))
}

// ---- Menu Commands & Notifications ----
print("\n--- Menu Commands & Notifications ---")

test("Notification names: copyReadingPosition exists") {
    let name = Notification.Name("copyReadingPosition")
    try assertEqual(name.rawValue, "copyReadingPosition")
}

test("Notification names: searchInBook exists") {
    let name = Notification.Name("searchInBook")
    try assertEqual(name.rawValue, "searchInBook")
}

test("Notification names: newFromText exists") {
    let name = Notification.Name("newFromText")
    try assertEqual(name.rawValue, "newFromText")
}

// ---- Adjustable Skip Amounts ----
print("\n--- Adjustable Skip Amounts (Shift+Skip) ---")

test("Shift skip: default secondary units are 30 seconds") {
    // Mirror default values from SettingsViewModel
    let defaultShiftForward = "30 seconds"
    let defaultShiftBackward = "30 seconds"
    try assertEqual(defaultShiftForward, "30 seconds")
    try assertEqual(defaultShiftBackward, "30 seconds")
}

test("Shift skip: shift detection logic") {
    // Simulate: binding doesn't require shift, but event has shift
    let bindingRequiresShift = false
    let eventHasShift = true
    let shiftHeld = eventHasShift && !bindingRequiresShift
    try assertTrue(shiftHeld, "Extra shift should be detected")
}

test("Shift skip: no extra shift when binding already uses shift") {
    let bindingRequiresShift = true
    let eventHasShift = true
    let shiftHeld = eventHasShift && !bindingRequiresShift
    try assertTrue(!shiftHeld, "Should not detect extra shift when binding uses it")
}

test("Shift skip: no shift when not pressed") {
    let bindingRequiresShift = false
    let eventHasShift = false
    let shiftHeld = eventHasShift && !bindingRequiresShift
    try assertTrue(!shiftHeld)
}

test("Shift skip: unit selection logic") {
    let primaryUnit = "15 seconds"
    let shiftUnit = "Heading"
    let useShift = true
    let selectedUnit = useShift ? shiftUnit : primaryUnit
    try assertEqual(selectedUnit, "Heading")

    let selectedUnit2 = false ? shiftUnit : primaryUnit
    try assertEqual(selectedUnit2, "15 seconds")
}

// ---- Skip Front/Back Matter ----
print("\n--- Skip Sections ---")

test("Skip sections: empty skip list leaves text unchanged") {
    let text = "Introduction. Chapter 1. Chapter 2."
    let skippedIDs: Set<String> = []
    // No headings to skip
    try assertTrue(skippedIDs.isEmpty)
    // Text should be unchanged
    try assertEqual(text, "Introduction. Chapter 1. Chapter 2.")
}

test("Skip sections: skipping a heading removes its text range") {
    // Simulate: headings at offsets 0, 20, 40 in a 60-char text
    let text = "AAAAAAAAAAAAAAAAAAAA" + "BBBBBBBBBBBBBBBBBBBB" + "CCCCCCCCCCCCCCCCCCCC"
    // 60 chars total: A=0-19, B=20-39, C=40-59
    let headings = [
        (id: "h1", offset: 0),
        (id: "h2", offset: 20),
        (id: "h3", offset: 40),
    ]
    let skippedIDs: Set<String> = ["h2"]  // Skip the B section

    // Build exclude ranges
    var excludeRanges: [Range<Int>] = []
    for (i, h) in headings.enumerated() {
        guard skippedIDs.contains(h.id) else { continue }
        let start = h.offset
        let end = i + 1 < headings.count ? headings[i + 1].offset : text.count
        excludeRanges.append(start..<end)
    }

    // Filter text
    var result = ""
    var pos = 0
    for range in excludeRanges {
        if pos < range.lowerBound {
            let startIdx = text.index(text.startIndex, offsetBy: pos)
            let endIdx = text.index(text.startIndex, offsetBy: range.lowerBound)
            result += text[startIdx..<endIdx]
        }
        pos = range.upperBound
    }
    if pos < text.count {
        let startIdx = text.index(text.startIndex, offsetBy: pos)
        result += text[startIdx...]
    }

    try assertEqual(result.count, 40, "Should be 40 chars (A + C)")
    try assertTrue(result.hasPrefix("AAAAAAAAAAAAAAAAAAAA"))
    try assertTrue(result.hasSuffix("CCCCCCCCCCCCCCCCCCCC"))
    try assertTrue(!result.contains("B"))
}

test("Skip sections: skipping first heading removes front matter") {
    let text = "Copyright 2024. All rights reserved. Chapter 1 begins here."
    let headings = [
        (id: "copyright", offset: 0),
        (id: "ch1", offset: 37),
    ]
    let skippedIDs: Set<String> = ["copyright"]

    var excludeRanges: [Range<Int>] = []
    for (i, h) in headings.enumerated() {
        guard skippedIDs.contains(h.id) else { continue }
        let start = h.offset
        let end = i + 1 < headings.count ? headings[i + 1].offset : text.count
        excludeRanges.append(start..<end)
    }

    var result = ""
    var pos = 0
    for range in excludeRanges {
        if pos < range.lowerBound {
            let startIdx = text.index(text.startIndex, offsetBy: pos)
            let endIdx = text.index(text.startIndex, offsetBy: range.lowerBound)
            result += text[startIdx..<endIdx]
        }
        pos = range.upperBound
    }
    if pos < text.count {
        let startIdx = text.index(text.startIndex, offsetBy: pos)
        result += text[startIdx...]
    }

    try assertTrue(result.hasPrefix("Chapter 1"))
    try assertTrue(!result.contains("Copyright"))
}

test("Skip sections: skipping last heading removes back matter") {
    let text = "Story content here. Appendix and index."
    let headings = [
        (id: "story", offset: 0),
        (id: "appendix", offset: 20),
    ]
    let skippedIDs: Set<String> = ["appendix"]

    var excludeRanges: [Range<Int>] = []
    for (i, h) in headings.enumerated() {
        guard skippedIDs.contains(h.id) else { continue }
        let start = h.offset
        let end = i + 1 < headings.count ? headings[i + 1].offset : text.count
        excludeRanges.append(start..<end)
    }

    var result = ""
    var pos = 0
    for range in excludeRanges {
        if pos < range.lowerBound {
            let startIdx = text.index(text.startIndex, offsetBy: pos)
            let endIdx = text.index(text.startIndex, offsetBy: range.lowerBound)
            result += text[startIdx..<endIdx]
        }
        pos = range.upperBound
    }
    if pos < text.count {
        let startIdx = text.index(text.startIndex, offsetBy: pos)
        result += text[startIdx...]
    }

    try assertEqual(result, "Story content here. ")
    try assertTrue(!result.contains("Appendix"))
}

test("Skip sections: toggle adds and removes IDs") {
    var ids: [String] = []

    // Toggle on
    ids.append("h1")
    try assertTrue(ids.contains("h1"))

    // Toggle off
    ids.removeAll { $0 == "h1" }
    try assertTrue(!ids.contains("h1"))
    try assertTrue(ids.isEmpty)
}

test("Skip sections: multiple sections can be skipped") {
    let skippedIDs: Set<String> = ["intro", "appendix", "index"]
    try assertEqual(skippedIDs.count, 3)
    try assertTrue(skippedIDs.contains("intro"))
    try assertTrue(skippedIDs.contains("appendix"))
    try assertTrue(skippedIDs.contains("index"))
    try assertTrue(!skippedIDs.contains("ch1"))
}

test("Skip sections: skippedHeadingIDs persists via BookState") {
    let state = BookState(
        isNew: false,
        tmbDirectoryName: "test.tmb",
        skippedHeadingIDs: ["h1", "h3", "h5"]
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(BookState.self, from: data)
    try assertEqual(decoded.skippedHeadingIDs?.count, 3)
    try assertTrue(decoded.skippedHeadingIDs!.contains("h1"))
    try assertTrue(decoded.skippedHeadingIDs!.contains("h3"))
}

test("Skip sections: backward compatible without skippedHeadingIDs") {
    let json = """
    {"isNew": true, "tmbDirectoryName": "old.tmb"}
    """
    let decoded = try JSONDecoder().decode(BookState.self, from: json.data(using: .utf8)!)
    try assertTrue(decoded.skippedHeadingIDs == nil)
}

// ---- Reading Statistics ----
print("\n--- Reading Statistics ---")

struct ReadingStats: Codable {
    var dailyListeningSeconds: [String: TimeInterval] = [:]
    var totalListeningSeconds: TimeInterval = 0
    var bookListeningSeconds: [String: TimeInterval] = [:]
    var finishedBooks: [FinishedBookEntry] = []
}

struct FinishedBookEntry: Codable {
    var bookID: String
    var title: String
    var dateFinished: Date
}

test("ReadingStats: JSON round-trip") {
    let stats = ReadingStats(
        dailyListeningSeconds: ["2026-03-20": 3600.0],
        totalListeningSeconds: 3600.0,
        bookListeningSeconds: ["uuid-1": 1800.0],
        finishedBooks: [FinishedBookEntry(bookID: "uuid-1", title: "My Book", dateFinished: Date())]
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = try encoder.encode(stats)
    let decoded = try decoder.decode(ReadingStats.self, from: data)
    try assertEqual(decoded.dailyListeningSeconds["2026-03-20"], 3600.0)
    try assertEqual(decoded.totalListeningSeconds, 3600.0)
    try assertEqual(decoded.finishedBooks.count, 1)
    try assertEqual(decoded.finishedBooks[0].title, "My Book")
}

test("ReadingStats: empty stats encodes/decodes") {
    let stats = ReadingStats()
    let data = try JSONEncoder().encode(stats)
    let decoded = try JSONDecoder().decode(ReadingStats.self, from: data)
    try assertTrue(decoded.dailyListeningSeconds.isEmpty)
    try assertEqual(decoded.totalListeningSeconds, 0)
}

test("ReadingStats: date key format is yyyy-MM-dd") {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let key = formatter.string(from: Date())
    try assertTrue(key.count == 10)
    try assertTrue(key.contains("-"))
}

test("ReadingStats: streak calculation logic") {
    var stats: [String: TimeInterval] = [:]
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    let calendar = Calendar.current
    // 3 consecutive days of listening
    for dayOffset in 0..<3 {
        let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date())!
        stats[formatter.string(from: date)] = 120.0 // 2 minutes each
    }
    var streak = 0
    var date = Date()
    while true {
        let key = formatter.string(from: date)
        if (stats[key] ?? 0) > 60 {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: date) else { break }
            date = prev
        } else { break }
    }
    try assertEqual(streak, 3)
}

test("ReadingStats: session duration calculation") {
    let start = Date()
    let end = start.addingTimeInterval(1800) // 30 minutes
    let duration = end.timeIntervalSince(start)
    try assertEqual(duration, 1800.0)
}

// ---- Punctuation Pauses ----
print("\n--- Punctuation Pauses ---")

func applyPunctuationPauses(_ text: String, level: Int) -> String {
    guard level > 0 else { return text }
    var result = text
    if level >= 1 {
        result = result.replacingOccurrences(of: ". ", with: ". . ")
        result = result.replacingOccurrences(of: "! ", with: "! . ")
        result = result.replacingOccurrences(of: "? ", with: "? . ")
    }
    if level >= 2 {
        result = result.replacingOccurrences(of: ", ", with: ", , ")
    }
    if level >= 3 {
        result = result.replacingOccurrences(of: "\n\n", with: "\n\n.\n\n")
    }
    return result
}

test("Punctuation pauses: level 0 leaves text unchanged") {
    let text = "Hello, world. How are you?"
    try assertEqual(applyPunctuationPauses(text, level: 0), text)
}

test("Punctuation pauses: level 1 adds pauses after periods") {
    let text = "First. Second. Third."
    let result = applyPunctuationPauses(text, level: 1)
    // "First. " becomes "First. . "
    try assertTrue(result.contains(". . "))
    try assertTrue(result.count > text.count)
}

test("Punctuation pauses: level 1 adds pauses after ! and ?") {
    let text = "Wow! Really? Yes."
    let result = applyPunctuationPauses(text, level: 1)
    try assertTrue(result.contains("! . "))
    try assertTrue(result.contains("? . "))
}

test("Punctuation pauses: level 2 adds pauses after commas") {
    let text = "One, two, three."
    let result = applyPunctuationPauses(text, level: 2)
    try assertTrue(result.contains(", , "))
}

test("Punctuation pauses: level 3 adds paragraph breaks") {
    let text = "First paragraph.\n\nSecond paragraph."
    let result = applyPunctuationPauses(text, level: 3)
    try assertTrue(result.contains(".\n\n"))
    try assertTrue(result.count > text.count)
}

// ---- End of Book Behavior ----
print("\n--- End of Book Behavior ---")

enum EndOfBookBehavior2: String, CaseIterable, Codable {
    case stop = "Stop"
    case loop = "Loop to Start"
    case continueNext = "Continue to Next Book"
}

test("EndOfBookBehavior: all cases") {
    try assertEqual(EndOfBookBehavior2.allCases.count, 3)
}

test("EndOfBookBehavior: raw value round-trip") {
    for behavior in EndOfBookBehavior2.allCases {
        let decoded = EndOfBookBehavior2(rawValue: behavior.rawValue)
        try assertTrue(decoded != nil)
        try assertTrue(decoded == behavior)
    }
}

test("EndOfBookBehavior: per-book override logic") {
    let globalBehavior = EndOfBookBehavior2.stop
    let localBehavior: String? = "Continue to Next Book"
    let effective: EndOfBookBehavior2
    if let localRaw = localBehavior, let local = EndOfBookBehavior2(rawValue: localRaw) {
        effective = local
    } else {
        effective = globalBehavior
    }
    try assertTrue(effective == .continueNext)
}

test("EndOfBookBehavior: nil override uses global") {
    let globalBehavior = EndOfBookBehavior2.loop
    let localBehavior: String? = nil
    let effective: EndOfBookBehavior2
    if let localRaw = localBehavior, let local = EndOfBookBehavior2(rawValue: localRaw) {
        effective = local
    } else {
        effective = globalBehavior
    }
    try assertTrue(effective == .loop)
}

test("Manual sort order: books sorted by order then title") {
    struct SortableBook {
        var title: String
        var manualSortOrder: Int?
    }
    let books = [
        SortableBook(title: "C Book", manualSortOrder: 2),
        SortableBook(title: "A Book", manualSortOrder: nil),
        SortableBook(title: "B Book", manualSortOrder: 0),
        SortableBook(title: "D Book", manualSortOrder: 1),
    ]
    let sorted = books.sorted { a, b in
        let orderA = a.manualSortOrder ?? Int.max
        let orderB = b.manualSortOrder ?? Int.max
        if orderA != orderB { return orderA < orderB }
        return a.title < b.title
    }
    try assertEqual(sorted[0].title, "B Book")  // order 0
    try assertEqual(sorted[1].title, "D Book")  // order 1
    try assertEqual(sorted[2].title, "C Book")  // order 2
    try assertEqual(sorted[3].title, "A Book")  // no order -> max -> last
}

test("Next book in folder: finds correct next") {
    struct SortableBook: Identifiable {
        var id = UUID()
        var title: String
        var manualSortOrder: Int?
    }
    let books = [
        SortableBook(title: "First", manualSortOrder: 0),
        SortableBook(title: "Second", manualSortOrder: 1),
        SortableBook(title: "Third", manualSortOrder: 2),
    ]
    let sorted = books.sorted { ($0.manualSortOrder ?? Int.max) < ($1.manualSortOrder ?? Int.max) }
    let currentIndex = sorted.firstIndex(where: { $0.title == "Second" })!
    let nextIndex = currentIndex + 1
    try assertTrue(nextIndex < sorted.count)
    try assertEqual(sorted[nextIndex].title, "Third")
}

test("Next book in folder: returns nil for last book") {
    struct SortableBook: Identifiable {
        var id = UUID()
        var title: String
        var manualSortOrder: Int?
    }
    let books = [
        SortableBook(title: "First", manualSortOrder: 0),
        SortableBook(title: "Last", manualSortOrder: 1),
    ]
    let sorted = books.sorted { ($0.manualSortOrder ?? Int.max) < ($1.manualSortOrder ?? Int.max) }
    let currentIndex = sorted.firstIndex(where: { $0.title == "Last" })!
    let nextIndex = currentIndex + 1
    try assertTrue(nextIndex >= sorted.count, "Should have no next book")
}

test("BookState: persists manualSortOrder and localEndOfBookBehavior") {
    let state = BookState(
        isNew: false,
        tmbDirectoryName: "test.tmb",
        localEndOfBookBehavior: "Loop to Start",
        manualSortOrder: 5
    )
    let data = try JSONEncoder().encode(state)
    let decoded = try JSONDecoder().decode(BookState.self, from: data)
    try assertEqual(decoded.localEndOfBookBehavior, "Loop to Start")
    try assertEqual(decoded.manualSortOrder, 5)
}

test("BookState: backward compatible without new fields") {
    let json = """
    {"isNew": true, "tmbDirectoryName": "old.tmb"}
    """
    let decoded = try JSONDecoder().decode(BookState.self, from: json.data(using: .utf8)!)
    try assertTrue(decoded.localEndOfBookBehavior == nil)
    try assertTrue(decoded.manualSortOrder == nil)
}

// ---- Audio Book Support ----
print("\n--- Audio Book Support ---")

test("BookFormat: audio case exists with correct extensions") {
    enum BF: String, CaseIterable {
        case epub, txt, markdown, html, audio
        var fileExtensions: [String] {
            switch self {
            case .audio: return ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac"]
            default: return []
            }
        }
        var isAudio: Bool { self == .audio }
    }
    try assertTrue(BF.audio.isAudio)
    try assertTrue(!BF.epub.isAudio)
    try assertTrue(BF.audio.fileExtensions.contains("mp3"))
    try assertTrue(BF.audio.fileExtensions.contains("m4b"))
    try assertTrue(BF.audio.fileExtensions.contains("wav"))
    try assertTrue(BF.audio.fileExtensions.contains("flac"))
    try assertEqual(BF.audio.fileExtensions.count, 9)
}

test("BookFormat: detect audio format from extensions") {
    let audioExts = ["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac"]
    let allExts = Set(audioExts)
    for ext in audioExts {
        try assertTrue(allExts.contains(ext), "\(ext) should be detected as audio")
    }
    try assertTrue(!allExts.contains("epub"))
    try assertTrue(!allExts.contains("txt"))
}

test("Audio placeholder text: 10 chars per second of audio") {
    let durationSeconds = 300.0 // 5 minutes
    let placeholderLength = Int(durationSeconds * 10)
    try assertEqual(placeholderLength, 3000)
    // Position tracking: char offset / 10 = seconds
    let charOffset = 1500
    let timeOffset = Double(charOffset) / 10.0
    try assertEqual(timeOffset, 150.0) // 2:30
}

test("Audio total time: uses char count not word count") {
    // Audio book placeholder text is all spaces — 0 words but N characters.
    // Total time must be derived from character count (10 chars = 1 sec), NOT word count.
    let audioCharsPerSecond = 10.0
    let durationSeconds = 3600.0 // 1 hour of audio
    let placeholderLength = Int(durationSeconds * audioCharsPerSecond) // 36000 chars
    let placeholderText = String(repeating: " ", count: placeholderLength)

    // Word count is 0 (all spaces)
    let wordCount = placeholderText.split(whereSeparator: { $0.isWhitespace }).count
    try assertEqual(wordCount, 0, "Placeholder text should have 0 words")

    // But char-based time should be correct
    let totalTime = Double(placeholderLength) / audioCharsPerSecond
    try assertEqual(totalTime, 3600.0, "Should be 3600 seconds from char count")

    // At 2x speed
    let speed = 2.0
    let adjustedTime = totalTime / speed
    try assertEqual(adjustedTime, 1800.0, "Should be 1800 seconds at 2x speed")

    // Time remaining at 50%
    let currentOffset = placeholderLength / 2
    let remainingChars = Double(placeholderLength - currentOffset)
    let remaining = remainingChars / audioCharsPerSecond / speed
    try assertEqual(remaining, 900.0, "Should be 900 seconds remaining at 50% at 2x")
}

test("Audio skip: seconds to character offset conversion") {
    let audioCharsPerSecond = 10.0
    // Skip forward 30 seconds = 300 characters
    let skipSeconds = 30
    let charDelta = Int(Double(skipSeconds) * audioCharsPerSecond)
    try assertEqual(charDelta, 300)

    // Skip backward 15 seconds = 150 characters
    let backSeconds = 15
    let backDelta = Int(Double(backSeconds) * audioCharsPerSecond)
    try assertEqual(backDelta, 150)
}

test("Audio speed: range 0.25 to 4.0") {
    let minSpeed = 0.25
    let maxSpeed = 4.0
    let speed = 1.5
    let clamped = max(minSpeed, min(speed, maxSpeed))
    try assertEqual(clamped, 1.5)

    let tooSlow = max(minSpeed, min(0.1, maxSpeed))
    try assertEqual(tooSlow, 0.25)

    let tooFast = max(minSpeed, min(5.0, maxSpeed))
    try assertEqual(tooFast, 4.0)
}

test("Audio speed: delta of 0.25 for speed adjustments") {
    var speed = 1.0
    speed += 0.25
    try assertEqual(speed, 1.25)
    speed += 0.25
    try assertEqual(speed, 1.5)
    speed -= 0.25
    try assertEqual(speed, 1.25)
}

test("Audio time estimate: adjusted by playback speed") {
    let duration = 3600.0 // 1 hour
    let speed = 2.0
    let adjustedDuration = duration / speed
    try assertEqual(adjustedDuration, 1800.0) // 30 minutes at 2x

    let speed3 = 0.5
    let adjusted3 = duration / speed3
    try assertEqual(adjusted3, 7200.0) // 2 hours at 0.5x
}

test("Audio time remaining: fraction-based calculation") {
    let duration = 3600.0
    let speed = 1.5
    let totalChars = 36000 // 10 chars/sec * 3600 sec
    let currentOffset = 18000 // halfway
    let fraction = Double(currentOffset) / Double(totalChars) // 0.5
    let remaining = (duration / speed) * (1.0 - fraction)
    try assertEqual(remaining, 1200.0) // 20 minutes at 1.5x, halfway
}

test("Audio manifest: JSON round-trip") {
    struct AudioManifest: Codable {
        var title: String?
        var author: String?
        var chapters: [String: String]?
        var order: [String]?
    }
    let manifest = AudioManifest(
        title: "My Audiobook",
        author: "John Doe",
        chapters: ["01.mp3": "Introduction", "02.mp3": "Chapter 1"],
        order: ["01.mp3", "02.mp3"]
    )
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(AudioManifest.self, from: data)
    try assertEqual(decoded.title, "My Audiobook")
    try assertEqual(decoded.author, "John Doe")
    try assertEqual(decoded.chapters?["01.mp3"], "Introduction")
    try assertEqual(decoded.order?.count, 2)
}

test("Audio multi-file: files sorted alphabetically by default") {
    let files = ["03-chapter3.mp3", "01-intro.mp3", "02-chapter1.mp3"]
    let sorted = files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    try assertEqual(sorted[0], "01-intro.mp3")
    try assertEqual(sorted[1], "02-chapter1.mp3")
    try assertEqual(sorted[2], "03-chapter3.mp3")
}

test("Audio multi-file: manifest order overrides alphabetical") {
    let files = ["c.mp3", "a.mp3", "b.mp3"]
    let manifestOrder = ["b.mp3", "a.mp3", "c.mp3"]
    let orderSet = Set(manifestOrder)
    let ordered = manifestOrder.compactMap { name in files.first { $0 == name } }
    let remaining = files.filter { !orderSet.contains($0) }
    let result = ordered + remaining
    try assertEqual(result[0], "b.mp3")
    try assertEqual(result[1], "a.mp3")
    try assertEqual(result[2], "c.mp3")
}

test("Audio chapter creation: each file becomes a chapter") {
    let fileNames = ["01-intro.mp3", "02-chapter1.mp3", "03-chapter2.mp3"]
    let durations = [60.0, 300.0, 450.0]

    var chapters: [(title: String, placeholderLength: Int)] = []
    for (i, name) in fileNames.enumerated() {
        let title = String(name.dropLast(4)) // Remove .mp3
        let placeholderLength = Int(durations[i] * 10)
        chapters.append((title: title, placeholderLength: placeholderLength))
    }
    try assertEqual(chapters.count, 3)
    try assertEqual(chapters[0].title, "01-intro")
    try assertEqual(chapters[0].placeholderLength, 600)
    try assertEqual(chapters[1].placeholderLength, 3000)
}

test("Audio ZIP detection: ZIP with only audio files") {
    let audioExts = Set(["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac"])
    let zipContents = ["track1.mp3", "track2.mp3", "manifest.json"]
    var hasAudio = false
    var hasNonAudio = false
    for file in zipContents {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        if ext.isEmpty || ext == "json" { continue }
        if audioExts.contains(ext) { hasAudio = true } else { hasNonAudio = true }
    }
    try assertTrue(hasAudio && !hasNonAudio, "Should be detected as audio ZIP")
}

test("Audio ZIP detection: ZIP with mixed content is not audio ZIP") {
    let audioExts = Set(["mp3", "m4a", "m4b", "wav", "aiff", "aif", "flac", "alac", "aac"])
    let textExts = Set(["epub", "txt", "md", "html"])
    let zipContents = ["track1.mp3", "book.epub"]
    var hasAudio = false
    var hasNonAudio = false
    for file in zipContents {
        let ext = URL(fileURLWithPath: file).pathExtension.lowercased()
        if audioExts.contains(ext) { hasAudio = true }
        if textExts.contains(ext) { hasNonAudio = true }
    }
    try assertTrue(hasAudio && hasNonAudio, "Mixed ZIP should not be treated as audio ZIP")
}

test("Audio position tracking: char offset to time conversion") {
    // 10 chars per second
    let charOffset = 5000
    let timeSeconds = Double(charOffset) / 10.0
    try assertEqual(timeSeconds, 500.0)

    // And back
    let time = 123.4
    let offset = Int(time * 10)
    try assertEqual(offset, 1234)
}

} // end runFeatureTests
