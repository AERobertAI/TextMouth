import Foundation

@testable import TextMouth

private func parseEPUB(url: URL) throws -> DocumentContent {
    try EPUBParser.parse(url: url)
}

private func parseHTML(html: String, title: String = "Untitled") throws -> DocumentContent {
    try HTMLParser.parse(html: html, title: title)
}

private func parseMarkdown(markdown: String, title: String = "Untitled") throws -> DocumentContent {
    try MarkdownDocParser.parse(markdown: markdown, title: title)
}

private func parsePlainText(text: String, title: String = "Untitled") -> DocumentContent {
    PlainTextParser.parse(text: text, title: title)
}

/// How many headings TestData/sample.md parses to: its seven ATX headings
/// (lines 1, 5, 11, 25, 29, 33, and 37), the title's among them. The sample.md
/// scenarios check it before looping over the headings, so a parser that
/// dropped them fails instead of passing over an empty list.
private let sampleMarkdownHeadingCount = 7

@MainActor
func runIntegrationTests() {

// ============================================================
// INTEGRATION TESTS
// These tests verify that multiple components work together
// correctly, unlike unit tests which test components in isolation.
// ============================================================

// ---- Parser → DocumentContent → Navigation Pipeline ----
print("\n--- Integration: Parser → Document → Navigation ---")

test("EPUB parse → heading IDs are unique and correctly indexed") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)

    // Verify headings span multiple chapters and have correct chapterIndex
    let allHeadings = content.allHeadings
    try assertGreater(allHeadings.count, 0, "Should have headings")

    // Each heading's chapterIndex should match its position in the chapter array
    for heading in allHeadings {
        try assertTrue(heading.chapterIndex >= 0 && heading.chapterIndex < content.chapters.count,
            "Heading '\(heading.text)' chapterIndex \(heading.chapterIndex) should be valid")
    }

    // IDs should be unique across all headings
    let ids = Set(allHeadings.map { $0.id })
    try assertEqual(ids.count, allHeadings.count, "All heading IDs should be unique")
}

test("EPUB parse → chapter offsets are contiguous and non-overlapping") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)

    // Verify chapter start offsets form a monotonically increasing sequence
    var previousEnd = 0
    for (i, chapter) in content.chapters.enumerated() {
        let start = content.chapterStartOffset(i)
        try assertEqual(start, previousEnd,
            "Chapter \(i) start (\(start)) should equal previous chapter end (\(previousEnd))")
        previousEnd = start + chapter.text.count
    }

    // Total character count should equal sum of all chapter lengths
    try assertEqual(content.totalCharacterCount, previousEnd,
        "Total char count should equal sum of chapter lengths")
}

test("EPUB parse → globalOffset round-trips with chapterStartOffset") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)

    // For each chapter, verify globalOffset(chapter, 0) == chapterStartOffset(chapter)
    for i in 0..<content.chapters.count {
        let fromStart = content.chapterStartOffset(i)
        let fromGlobal = content.globalOffset(chapterIndex: i, localOffset: 0)
        try assertEqual(fromStart, fromGlobal,
            "Chapter \(i): chapterStartOffset and globalOffset(0) should match")
    }

    // Verify a mid-chapter offset
    if content.chapters.count > 1 {
        let chapterIdx = 1
        let localOff = min(100, content.chapters[chapterIdx].text.count)
        let global = content.globalOffset(chapterIndex: chapterIdx, localOffset: localOff)
        let expected = content.chapterStartOffset(chapterIdx) + localOff
        try assertEqual(global, expected)
    }
}

test("HTML parse → document metrics match content") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let content = try parseHTML(html: html, title: "Frankenstein")

    // Word count from totalWordCount should match manual count
    let manualWordCount = content.chapters.reduce(0) {
        $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count
    }
    try assertEqual(content.totalWordCount, manualWordCount,
        "totalWordCount should match sum of per-chapter word counts")

    // Reading time should scale linearly with WPM
    let time200 = content.estimatedReadingTime(wpm: 200.0)
    let time400 = content.estimatedReadingTime(wpm: 400.0)
    // At double the speed, time should be half
    try assertTrue(abs(time200 - time400 * 2.0) < 1.0,
        "Double WPM should halve reading time")
}

test("Markdown parse → headings are in document order with correct offsets") {
    let url = try requireFile("sample.md")
    let md = try String(contentsOf: url, encoding: .utf8)
    let content = try parseMarkdown(markdown: md, title: "Sample")
    try assertEqual(content.allHeadings.count, sampleMarkdownHeadingCount, "sample.md should keep exactly its headings")

    // Headings should be in order of characterOffset within each chapter
    for chapter in content.chapters {
        var lastOffset = -1
        for heading in chapter.headings {
            try assertTrue(heading.characterOffset >= lastOffset,
                "Heading '\(heading.text)' offset \(heading.characterOffset) should be >= \(lastOffset)")
            lastOffset = heading.characterOffset
        }
    }

    // Each heading's characterOffset should be within the chapter's text length
    for (chapterIdx, chapter) in content.chapters.enumerated() {
        for heading in chapter.headings {
            try assertTrue(heading.characterOffset <= chapter.text.count,
                "Ch\(chapterIdx) heading '\(heading.text)' offset \(heading.characterOffset) > text length \(chapter.text.count)")
        }
    }
}

test("Plain text parse → chapter splitting preserves all text") {
    let url = try requireFile("pride.txt")
    let text = try String(contentsOf: url, encoding: .utf8)
    let content = parsePlainText(text: text, title: "Pride")

    // Reconstructing from chapters should give back (approximately) the original text
    // Plain text parser may add chapter title lines, so check total word count instead
    let originalWords = text.split(whereSeparator: { $0.isWhitespace }).count
    let parsedWords = content.totalWordCount
    // Should preserve all words (parser shouldn't drop content)
    try assertTrue(parsedWords >= originalWords - 10,
        "Parsed word count (\(parsedWords)) should be close to original (\(originalWords))")
}


// ---- Library + Book + Folder Workflow ----
print("\n--- Integration: Library + Book + Folder Workflow ---")

test("Library: add book → move to folder → query by folder") {
    var library = Library()
    let bookID = UUID()
    let book = Book(
        id: bookID,
        title: "Test Novel",
        author: "Test Author",
        format: .txt,
        filePath: "/tmp/test.txt",
        md5Hash: "abc123"
    )

    library.addBook(book)
    try assertEqual(library.books.count, 1)
    try assertEqual(library.booksInFolder("").count, 1, "Book should be in root folder")

    // Create folder and move book into it
    let folder = library.createFolder(name: "Fiction")
    try assertTrue(folder != nil, "Should create folder")

    library.moveBook(id: bookID, toFolder: "Fiction")
    try assertEqual(library.booksInFolder("").count, 0, "Root should be empty")
    try assertEqual(library.booksInFolder("Fiction").count, 1, "Fiction folder should have 1 book")
}

test("Library: nested folders → subfolder query → delete cascade") {
    var library = Library()

    // Build folder hierarchy
    let _ = library.createFolder(name: "Genre")
    let _ = library.createFolder(name: "SciFi", parentPath: "Genre")
    let _ = library.createFolder(name: "Fantasy", parentPath: "Genre")

    // Add books into subfolders
    let book1 = Book(id: UUID(), title: "Dune", format: .txt, filePath: "/tmp/d.txt", md5Hash: "d1", folderPath: "Genre/SciFi")
    let book2 = Book(id: UUID(), title: "Hobbit", format: .txt, filePath: "/tmp/h.txt", md5Hash: "h1", folderPath: "Genre/Fantasy")
    library.addBook(book1)
    library.addBook(book2)

    try assertEqual(library.booksInFolder("Genre/SciFi").count, 1)
    try assertEqual(library.booksInFolder("Genre/Fantasy").count, 1)

    // Subfolders of "Genre" should list SciFi and Fantasy
    let subs = library.subfolders(of: "Genre")
    try assertEqual(subs.count, 2)

    // Delete parent folder → books and subfolders reparent to root (default destination)
    let genreFolder = library.folders.first { $0.name == "Genre" && $0.parentPath.isEmpty }!
    library.removeFolder(id: genreFolder.id, movingContentsTo: "")

    try assertEqual(library.folders.count, 2, "SciFi and Fantasy should be reparented to root")
    try assertEqual(library.booksInFolder("SciFi").count, 1, "Dune should be in SciFi at root")
    try assertEqual(library.booksInFolder("Fantasy").count, 1, "Hobbit should be in Fantasy at root")
}

test("Library: duplicate book rejected by MD5 hash") {
    var library = Library()

    let book1 = Book(title: "Version 1", format: .txt, filePath: "/tmp/v1.txt", md5Hash: "same_hash")
    library.addBook(book1)
    try assertEqual(library.books.count, 1)

    // Same hash, different title — should be rejected
    let book2 = Book(title: "Version 2", format: .txt, filePath: "/tmp/v2.txt", md5Hash: "same_hash")
    library.addBook(book2)
    try assertEqual(library.books.count, 1, "Duplicate should be rejected")
    try assertEqual(library.books[0].title, "Version 1", "Original should remain")
}

test("Library: bookmark operations update numbering correctly") {
    var library = Library()
    let bookID = UUID()
    let book = Book(id: bookID, title: "Bookmarked", format: .txt, filePath: "/tmp/bm.txt", md5Hash: "bm1")
    library.addBook(book)

    // Add three bookmarks
    library.addBookmark(bookID: bookID, chapterIndex: 0, characterOffset: 100, label: "First")
    library.addBookmark(bookID: bookID, chapterIndex: 1, characterOffset: 200, label: "Second")
    library.addBookmark(bookID: bookID, chapterIndex: 2, characterOffset: 300, label: "Third")

    let bookmarks = library.books.first!.bookmarks
    try assertEqual(bookmarks.count, 3)
    try assertEqual(bookmarks[0].number, 1)
    try assertEqual(bookmarks[1].number, 2)
    try assertEqual(bookmarks[2].number, 3)

    // Remove middle bookmark → remaining should renumber
    let middleID = bookmarks[1].id
    library.removeBookmark(bookID: bookID, bookmarkID: middleID)
    let updated = library.books.first!.bookmarks
    try assertEqual(updated.count, 2)
    try assertEqual(updated[0].number, 1)
    try assertEqual(updated[1].number, 2)
    try assertEqual(updated[0].label, "First")
    try assertEqual(updated[1].label, "Third")
}


// ---- Library + ReadingPosition + Time Estimation ----
print("\n--- Integration: Reading Position + Time Estimation ---")

test("Library: update reading position → time estimation uses position") {
    var library = Library()
    let bookID = UUID()
    let book = Book(
        id: bookID,
        title: "Long Book",
        format: .txt,
        filePath: "/tmp/lb.txt",
        md5Hash: "lb1",
        totalWordCount: 50000,
        totalCharacterCount: 250000
    )
    library.addBook(book)

    // Time at beginning (no position)
    let fullTime = library.books[0].estimatedTimeRemaining(wpm: 200.0)
    try assertTrue(fullTime != nil)
    // 50000 words / 200 wpm * 60 = 15000 seconds
    try assertTrue(abs(fullTime! - 15000.0) < 1.0, "Full time should be 15000s, got \(fullTime!)")

    // Update reading position to 50% through
    let pos = ReadingPosition(chapterIndex: 5, characterOffset: 0, globalCharacterOffset: 125000)
    library.updateReadingPosition(bookID: bookID, position: pos)

    let halfTime = library.books[0].estimatedTimeRemaining(wpm: 200.0)
    try assertTrue(halfTime != nil)
    // Should be approximately half of full time
    try assertTrue(abs(halfTime! - 7500.0) < 1.0, "Half time should be 7500s, got \(halfTime!)")
}

test("Per-book WPM override affects time estimation") {
    let book = Book(
        title: "Custom Speed",
        format: .txt,
        filePath: "/tmp/cs.txt",
        md5Hash: "cs1",
        totalWordCount: 10000,
        totalCharacterCount: 50000,
        localWPM: 400.0
    )

    // With local WPM of 400 (not global 200)
    let timeWithLocal = book.estimatedTimeRemaining(wpm: 200.0)!
    // 10000 / 400 * 60 = 1500s
    try assertTrue(abs(timeWithLocal - 1500.0) < 1.0, "Should use local WPM 400, got \(timeWithLocal)")

    // Without local WPM, should use fallback
    let bookNoLocal = Book(
        title: "Default Speed",
        format: .txt,
        filePath: "/tmp/ds.txt",
        md5Hash: "ds1",
        totalWordCount: 10000,
        totalCharacterCount: 50000
    )
    let timeWithGlobal = bookNoLocal.estimatedTimeRemaining(wpm: 200.0)!
    // 10000 / 200 * 60 = 3000s
    try assertTrue(abs(timeWithGlobal - 3000.0) < 1.0, "Should use global WPM 200, got \(timeWithGlobal)")
}

test("Audio book: time estimation uses duration and speed multiplier") {
    let audioBook = Book(
        title: "Audio Story",
        format: .audio,
        filePath: "/tmp/audio.mp3",
        md5Hash: "a1",
        readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 500, globalCharacterOffset: 500),
        totalCharacterCount: 1000,
        localWPM: 1.5, // 1.5x speed for audio books
        audioDuration: 7200.0 // 2 hours
    )

    let remaining = audioBook.estimatedTimeRemaining(wpm: 200.0)
    try assertTrue(remaining != nil)
    // duration/speed = 7200/1.5 = 4800s adjusted, at 50% through = 2400s
    try assertTrue(abs(remaining! - 2400.0) < 1.0, "Audio remaining should be 2400s, got \(remaining!)")
}


// ---- Text Substitution + Offset Mapping Pipeline ----
print("\n--- Integration: Substitution + Offset Mapping ---")

test("Substitution: offset mapping preserves position tracking through multiple rules") {
    // The full pipeline: text → substitutions → offset mapping → original position
    let originalText = "Dr. Smith went to St. Paul's for the e.g. meeting vs. the other one."

    let rules: [SubstitutionRule] = [
        SubstitutionRule(name: "Dr.", pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true),
        SubstitutionRule(name: "St.", pattern: "\\bSt\\.", replacement: "Saint", isRegex: true),
        SubstitutionRule(name: "e.g.", pattern: "\\be\\.g\\.", replacement: "for example", isRegex: true),
        SubstitutionRule(name: "vs.", pattern: "\\bvs\\.", replacement: "versus", isRegex: true),
    ]

    // The service's whole transformation: the spoken text and its offset map.
    // (Scenarios run on the main actor, the service's, so it is called directly.)
    let transformation = TextSubstitutionService(rules: rules).transform(originalText)
    let transformed = transformation.modifiedText

    // Verify all substitutions happened
    try assertTrue(transformed.contains("Doctor"), "Should replace Dr. with Doctor")
    try assertTrue(transformed.contains("Saint"), "Should replace St. with Saint")
    try assertTrue(transformed.contains("for example"), "Should replace e.g. with for example")
    try assertTrue(transformed.contains("versus"), "Should replace vs. with versus")
    try assertTrue(!transformed.contains("Dr."), "Dr. should be gone")
    try assertTrue(!transformed.contains("St."), "St. should be gone")

    // Map a position back through the rules, as position tracking does: three
    // longer replacements come before "meeting", so it starts later in the
    // spoken text than in the book's, and the map must undo that shift.
    // Offsets are UTF-16, as the app keeps them.
    guard let spokenMeeting = transformed.range(of: "meeting"),
          let bookMeeting = originalText.range(of: "meeting") else {
        throw TestError.assertionFailed("\"meeting\" should be in the text before and after the substitutions")
    }
    let spokenOffset = transformed.utf16Offset(of: spokenMeeting.lowerBound)
    let bookOffset = originalText.utf16Offset(of: bookMeeting.lowerBound)
    try assertTrue(spokenOffset > bookOffset, "The longer replacements should move \"meeting\" later")
    try assertEqual(transformation.offsetMap.toOriginal(spokenOffset), bookOffset,
        "The offset map should take \"meeting\" back to where it starts in the original text")
}

test("Substitution: disabled rules are skipped in pipeline") {
    let text = "Mr. Johnson and Mrs. Johnson"
    let rules: [SubstitutionRule] = [
        SubstitutionRule(name: "Mr.", pattern: "\\bMr\\.", replacement: "Mister", isRegex: true, isEnabled: true),
        SubstitutionRule(name: "Mrs.", pattern: "\\bMrs\\.", replacement: "Missus", isRegex: true, isEnabled: false),
    ]
    let result = applyRules(rules, to: text)
    try assertTrue(result.contains("Mister"), "Enabled rule should apply")
    try assertTrue(result.contains("Mrs."), "Disabled rule should NOT apply")
}

test("Substitution: URL and email rules work with surrounding text") {
    let text = "Visit https://example.com/page?q=1 or email user@example.com for info."
    let rules: [SubstitutionRule] = [
        SubstitutionRule(name: "URLs", pattern: "https?://\\S+", replacement: "link", isRegex: true),
        SubstitutionRule(name: "Emails", pattern: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b", replacement: "email address", isRegex: true),
    ]
    let result = applyRules(rules, to: text)
    try assertEqual(result, "Visit link or email email address for info.")
}

test("Substitution: empty replacement deletes matched text") {
    let text = "This has [1] footnote [2] markers [3] embedded."
    let rules: [SubstitutionRule] = [
        SubstitutionRule(name: "Footnotes", pattern: "\\[\\d+\\]", replacement: "", isRegex: true),
    ]
    let result = applyRules(rules, to: text)
    try assertEqual(result, "This has  footnote  markers  embedded.")
}

test("Substitution: offset map correctly tracks position through length changes") {
    // Build offset mapping manually to verify the pipeline
    // Original: "Dr. Smith"
    // After substitution: "Doctor Smith"
    // "Dr." (3 chars) → "Doctor" (6 chars), delta = -3 (original is shorter)

    let map = TestOffsetMap(points: [(modifiedPos: 6, cumulativeDelta: -3)])

    // Position 0 in modified = position 0 in original (before substitution)
    try assertEqual(map.toOriginal(0), 0)
    // Position 7 in modified ("S" in "Smith") = position 4 in original ("S" in "Smith")
    try assertEqual(map.toOriginal(7), 4)
    // Position 6 in modified (space after "Doctor") = position 3 in original (space after "Dr.")
    try assertEqual(map.toOriginal(6), 3)
}


// ---- BookInfo Persistence Round-Trip ----
print("\n--- Integration: BookInfo Persistence Round-Trip ---")

test("BookInfo: Book → BookInfo → JSON → BookInfo preserves all fields") {
    let now = Date()
    let bookID = UUID()
    let metadata = BookMetadata(
        title: "Round-Trip Test",
        author: "Test Author",
        format: .epub,
        md5Hash: "rt123",
        dateAdded: now,
        lastOpened: now,
        originalFileName: "test.epub",
        folderPath: "Fiction/Mystery",
        bookID: bookID,
        sourceFilePath: "/original/path/test.epub",
        publisher: "Test Press",
        publicationDate: "2025-01-15",
        isbn: "978-3-16-148410-0",
        language: "en",
        audioAlbum: nil,
        audioGenre: nil,
        audioYear: nil
    )
    let state = BookState(
        totalWordCount: 75000,
        totalCharacterCount: 375000,
        isNew: false,
        tmbDirectoryName: "RoundTripTest-TestAuthor-abc123.tmb",
        lastPlaybackStarted: now.addingTimeInterval(-600),
        lastPlaybackStopped: now.addingTimeInterval(-300),
        localVoiceID: "com.apple.voice.premium.en-US.Ava",
        localWPM: 275.0,
        skippedHeadingIDs: ["0-0-1-Introduction", "2-500-2-Appendix"],
        localEndOfBookBehavior: "stop",
        manualSortOrder: 3,
        audioDuration: nil
    )
    let bookmarks = [
        Bookmark(number: 1, chapterIndex: 0, characterOffset: 100, label: "Key scene"),
        Bookmark(number: 2, chapterIndex: 5, characterOffset: 2000, label: "Plot twist"),
    ]

    let info = BookInfo(metadata: metadata, state: state, bookmarks: bookmarks)

    // Encode
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(info)

    // Decode
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(BookInfo.self, from: data)

    // Verify metadata fields
    try assertEqual(restored.metadata.title, "Round-Trip Test")
    try assertEqual(restored.metadata.author, "Test Author")
    try assertEqual(restored.metadata.format, .epub)
    try assertEqual(restored.metadata.md5Hash, "rt123")
    try assertEqual(restored.metadata.folderPath, "Fiction/Mystery")
    try assertEqual(restored.metadata.bookID, bookID)
    try assertEqual(restored.metadata.publisher, "Test Press")
    try assertEqual(restored.metadata.isbn, "978-3-16-148410-0")
    try assertEqual(restored.metadata.language, "en")
    try assertEqual(restored.metadata.sourceFilePath, "/original/path/test.epub")

    // Verify state fields
    try assertEqual(restored.state.totalWordCount, 75000)
    try assertEqual(restored.state.totalCharacterCount, 375000)
    try assertEqual(restored.state.isNew, false)
    try assertEqual(restored.state.localVoiceID, "com.apple.voice.premium.en-US.Ava")
    try assertEqual(restored.state.localWPM, 275.0)
    try assertEqual(restored.state.skippedHeadingIDs?.count, 2)
    try assertEqual(restored.state.localEndOfBookBehavior, "stop")
    try assertEqual(restored.state.manualSortOrder, 3)

    // Verify bookmarks
    try assertEqual(restored.bookmarks.count, 2)
    try assertEqual(restored.bookmarks[0].label, "Key scene")
    try assertEqual(restored.bookmarks[1].label, "Plot twist")
    try assertEqual(restored.bookmarks[0].chapterIndex, 0)
    try assertEqual(restored.bookmarks[1].chapterIndex, 5)
}

test("BookInfo: backward-compatible decode from minimal JSON") {
    // Simulate an older bookInfo.json that lacks newer fields
    let json = """
    {
        "metadata": {
            "title": "Old Book",
            "author": "Old Author",
            "format": "txt",
            "md5Hash": "old123",
            "dateAdded": "2024-01-01T00:00:00Z",
            "originalFileName": "old.txt",
            "folderPath": "",
            "bookID": "12345678-1234-1234-1234-123456789012"
        },
        "state": {
            "isNew": true,
            "tmbDirectoryName": "OldBook.tmb"
        },
        "bookmarks": []
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let info = try decoder.decode(BookInfo.self, from: data)

    try assertEqual(info.metadata.title, "Old Book")
    try assertTrue(info.state.localVoiceID == nil, "Missing fields should be nil")
    try assertTrue(info.state.localWPM == nil)
    try assertTrue(info.state.skippedHeadingIDs == nil)
    try assertTrue(info.state.audioDuration == nil)
    try assertEqual(info.bookmarks.count, 0)
}


// ---- Library Serialization Round-Trip ----
print("\n--- Integration: Library Serialization Round-Trip ---")

test("Library: full serialize → deserialize preserves books and folders") {
    var library = Library()

    // Add folders
    let _ = library.createFolder(name: "Nonfiction")
    let _ = library.createFolder(name: "History", parentPath: "Nonfiction")

    // Add books with various states
    let book1 = Book(
        title: "Book One",
        author: "Author A",
        format: .epub,
        filePath: "/books/one.epub",
        md5Hash: "hash1",
        folderPath: "Nonfiction/History",
        dateAdded: Date(),
        readingPosition: ReadingPosition(chapterIndex: 3, characterOffset: 500, globalCharacterOffset: 2500),
        bookmarks: [Bookmark(number: 1, chapterIndex: 1, characterOffset: 100, label: "Important")],
        totalWordCount: 80000,
        totalCharacterCount: 400000,
        tmbDirectoryName: "BookOne-AuthorA.tmb"
    )
    let book2 = Book(
        title: "Book Two",
        author: "Author B",
        format: .markdown,
        filePath: "/books/two.md",
        md5Hash: "hash2",
        tmbDirectoryName: "BookTwo-AuthorB.tmb"
    )
    library.addBook(book1)
    library.addBook(book2)

    // Encode
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted]
    let data = try encoder.encode(library)

    // Decode
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(Library.self, from: data)

    // Verify structure
    try assertEqual(restored.books.count, 2)
    try assertEqual(restored.folders.count, 2)

    // Verify book details survived
    let restoredBook1 = restored.books.first { $0.md5Hash == "hash1" }!
    try assertEqual(restoredBook1.title, "Book One")
    try assertEqual(restoredBook1.folderPath, "Nonfiction/History")
    try assertEqual(restoredBook1.readingPosition?.chapterIndex, 3)
    try assertEqual(restoredBook1.readingPosition?.globalCharacterOffset, 2500)
    try assertEqual(restoredBook1.bookmarks.count, 1)
    try assertEqual(restoredBook1.bookmarks[0].label, "Important")
    try assertEqual(restoredBook1.totalWordCount, 80000)

    // Verify folder hierarchy
    let historyFolder = restored.folders.first { $0.name == "History" }!
    try assertEqual(historyFolder.parentPath, "Nonfiction")
    try assertEqual(historyFolder.fullPath, "Nonfiction/History")
    try assertEqual(historyFolder.depth, 2)

    // Verify querying works on restored library
    try assertEqual(restored.booksInFolder("Nonfiction/History").count, 1)
    try assertEqual(restored.booksInFolder("").count, 1) // Book Two in root
}


// ---- Parser → Document → Where Am I Context ----
print("\n--- Integration: Parser → Where Am I Context ---")

test("EPUB parse → heading lookup finds correct heading for position") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)

    // A parser that lost the book's headings must fail here, not pass by skipping.
    let allHeadings = content.allHeadings
    try assertGreater(allHeadings.count, 1, "alice.epub lost its headings")

    // Ask the app's own "where am I" lookup, which the headings panel, the
    // reader header, and Where Am I share, about a position slightly past the
    // second heading's start: still inside that heading's section, since the
    // third heading starts later.
    let secondHeading = allHeadings[1]
    let currentHeading = ReaderViewModel.currentHeading(
        in: allHeadings,
        chapterIndex: secondHeading.chapterIndex,
        characterOffset: secondHeading.characterOffset + 10
    )

    // Compare IDs, not labels: an ID names one heading even where two share a label.
    try assertEqual(currentHeading?.id, secondHeading.id, "Should be at the second heading")
}

test("Where Am I: percent complete matches global offset") {
    let content = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "Ch1", text: String(repeating: "a", count: 500)),
            Chapter(title: "Ch2", text: String(repeating: "b", count: 500)),
        ]
    )

    // At chapter 0, offset 0 → 0%
    let pct0 = content.percentComplete(globalOffset: 0)
    try assertTrue(abs(pct0 - 0.0) < 0.1)

    // At chapter 0, offset 250 → 25%
    let pct25 = content.percentComplete(globalOffset: 250)
    try assertTrue(abs(pct25 - 25.0) < 0.1)

    // At chapter 1, offset 0 → 50%
    let pct50 = content.percentComplete(globalOffset: 500)
    try assertTrue(abs(pct50 - 50.0) < 0.1)

    // At end → 100%
    let pct100 = content.percentComplete(globalOffset: 1000)
    try assertTrue(abs(pct100 - 100.0) < 0.1)
}

test("Reading time remaining decreases as position advances") {
    let content = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "Ch1", text: String(repeating: "word ", count: 1000)),
            Chapter(title: "Ch2", text: String(repeating: "word ", count: 1000)),
        ]
    )

    let wpm = 200.0
    let fullTime = content.estimatedReadingTime(wpm: wpm)

    // At 25% through
    let offset25 = content.totalCharacterCount / 4
    let time75 = content.estimatedTimeRemaining(fromGlobalOffset: offset25, wpm: wpm)

    // At 75% through
    let offset75 = content.totalCharacterCount * 3 / 4
    let time25 = content.estimatedTimeRemaining(fromGlobalOffset: offset75, wpm: wpm)

    try assertTrue(fullTime > time75, "Full time should exceed 75% remaining")
    try assertTrue(time75 > time25, "75% remaining should exceed 25% remaining")
    try assertTrue(time25 > 0, "25% remaining should be > 0")

    // Fractions should be approximately correct
    try assertTrue(abs(time75 / fullTime - 0.75) < 0.01, "75% remaining ratio should be ~0.75")
    try assertTrue(abs(time25 / fullTime - 0.25) < 0.01, "25% remaining ratio should be ~0.25")
}


// ---- Cross-Chapter Navigation + Bookmarks ----
print("\n--- Integration: Cross-Chapter Navigation + Bookmarks ---")

test("Bookmarks across chapters are numbered in the order added") {
    var library = Library()
    let bookID = UUID()
    let book = Book(id: bookID, title: "Multi-Chapter", format: .txt,
                    filePath: "/tmp/mc.txt", md5Hash: "mc1")
    library.addBook(book)

    // Add bookmarks in different chapters
    library.addBookmark(bookID: bookID, chapterIndex: 2, characterOffset: 100, label: "Late chapter")
    library.addBookmark(bookID: bookID, chapterIndex: 0, characterOffset: 50, label: "Early chapter")
    library.addBookmark(bookID: bookID, chapterIndex: 1, characterOffset: 200, label: "Middle chapter")

    // A library that lost the book, or one of its bookmarks, fails here
    // instead of stopping the test host at a subscript below.
    guard let bookmarks = library.books.first?.bookmarks else {
        throw TestError.assertionFailed("The library should keep the book it was given")
    }
    try assertEqual(bookmarks.count, 3, "addBookmark should keep every bookmark added")

    // Verify numbering is based on insertion order, not chapter order
    try assertEqual(bookmarks[0].number, 1)
    try assertEqual(bookmarks[0].label, "Late chapter")
    try assertEqual(bookmarks[1].number, 2)
    try assertEqual(bookmarks[1].label, "Early chapter")
}

test("Navigation: chapter skip respects chapter boundaries") {
    let chapters = [
        Chapter(title: "Ch1", text: String(repeating: "a", count: 100)),
        Chapter(title: "Ch2", text: String(repeating: "b", count: 200)),
        Chapter(title: "Ch3", text: String(repeating: "c", count: 150)),
    ]

    // Forward skip: chapter 0 → chapter 1
    var nextChapter = min(0 + 1, chapters.count - 1)
    try assertEqual(nextChapter, 1)

    // Forward skip from last chapter: stays at last
    nextChapter = min(2 + 1, chapters.count - 1)
    try assertEqual(nextChapter, 2, "Should clamp to last chapter")

    // Backward skip: chapter 2 → chapter 1
    var prevChapter = max(2 - 1, 0)
    try assertEqual(prevChapter, 1)

    // Backward skip from first chapter: stays at first
    prevChapter = max(0 - 1, 0)
    try assertEqual(prevChapter, 0, "Should clamp to first chapter")
}


// ---- Sleep Timer + Heading Boundary ----
print("\n--- Integration: Sleep Timer + Heading Boundary ---")

test("Sleep timer: end-of-heading ends at its owner's first heading end") {
    // Never exercise the production singleton in hosted tests: its reset
    // helper clears persisted timer history. A disposable defaults suite keeps
    // the scenario hermetic and protects the user's restart-timer duration.
    let timerDefaults = SandboxedPreferences("integration-timer")
    let timer = SleepTimerService(userDefaults: timerDefaults.defaults)
    timer._resetForTesting()
    defer {
        timer._resetForTesting()
        timerDefaults.discard()
    }

    let ownerID = UUID()
    var expiryCallbacks = 0
    timer.start(duration: .endOfHeading, ownerID: ownerID) {
        expiryCallbacks += 1
    }

    // Finding #787: another reader's heading end changes nothing, and the
    // owner's first one ends the timer; the owner stops playback there and
    // says so itself, so the expiry callback never runs.
    try assertTrue(!timer.expireAtHeadingEnd(by: UUID()), "Another reader's heading end should not end the timer")
    try assertTrue(timer.isActive, "Another reader's heading end should leave the timer active")
    try assertTrue(timer.expireAtHeadingEnd(by: ownerID), "The owner's first heading end should end the timer")
    try assertTrue(!timer.isActive, "The ended timer should be inactive")
    try assertTrue(!timer.expireAtHeadingEnd(by: ownerID), "An ended timer should not end again")
    try assertEqual(expiryCallbacks, 0)
}

test("Sleep timer: formatted output matches duration state") {
    // Use a separate disposable suite for this scenario as well; sharing the
    // app singleton would couple the test to live application preferences.
    let timerDefaults = SandboxedPreferences("integration-timer")
    let timer = SleepTimerService(userDefaults: timerDefaults.defaults)
    timer._resetForTesting()
    defer {
        timer._resetForTesting()
        timerDefaults.discard()
    }

    try assertEqual(timer.formattedRemaining, "")

    timer.start(duration: .endOfHeading, onExpire: {})
    try assertEqual(timer.formattedRemaining, "End of heading")

    timer.start(duration: .endOfBook, onExpire: {})
    try assertEqual(timer.formattedRemaining, "End of book")

    timer.start(duration: .minutes(15), onExpire: {})
    timer.remainingSeconds = 905
    try assertEqual(timer.formattedRemaining, "15:05")

    timer.remainingSeconds = 59
    try assertEqual(timer.formattedRemaining, "0:59")
}


// ---- Reading Stats: Finished Books ----
print("\n--- Integration: Reading Stats Finished Books ---")

test("Reading stats: finished books tracked with metadata") {
    var stats = ReadingStats()
    let bookID = UUID()
    let entry = FinishedBookEntry(bookID: bookID.uuidString, title: "Completed Book", dateFinished: Date())
    stats.finishedBooks.append(entry)

    try assertEqual(stats.finishedBooks.count, 1)
    try assertEqual(stats.finishedBooks[0].title, "Completed Book")
    try assertEqual(stats.finishedBooks[0].bookID, bookID.uuidString)

    // Round-trip through JSON
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(stats)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let restored = try decoder.decode(ReadingStats.self, from: data)
    try assertEqual(restored.finishedBooks.count, 1)
    try assertEqual(restored.finishedBooks[0].title, "Completed Book")
}


// ---- Full Pipeline: Parse → Build Document → Compute Metrics → Navigate ----
print("\n--- Integration: Full Parse → Metrics → Navigation Pipeline ---")

test("Full pipeline: EPUB → document metrics → navigation → percent tracking") {
    let url = try requireFile("alice.epub")
    let content = try parseEPUB(url: url)

    // Verify we got a real document
    try assertGreater(content.chapters.count, 0, "Should have chapters")
    try assertGreater(content.totalWordCount, 1000, "Should have substantial word count")
    try assertGreater(content.totalCharacterCount, 5000, "Should have substantial char count")

    // Compute reading time
    let readingTime = content.estimatedReadingTime(wpm: 200.0)
    try assertTrue(readingTime > 0, "Reading time should be positive")

    // Navigate to middle of the document
    let midChapter = content.chapters.count / 2
    let midOffset = content.chapters[midChapter].text.count / 2
    let globalMid = content.globalOffset(chapterIndex: midChapter, localOffset: midOffset)

    // Percent complete should be roughly 50% (depends on chapter distribution)
    let percent = content.percentComplete(globalOffset: globalMid)
    try assertTrue(percent > 20 && percent < 80,
        "Mid-document percent should be roughly 20-80%, got \(percent)%")

    // Time remaining should be less than total
    let remaining = content.estimatedTimeRemaining(fromGlobalOffset: globalMid, wpm: 200.0)
    try assertTrue(remaining < readingTime, "Remaining should be less than total time")
    try assertTrue(remaining > 0, "Remaining should be positive")
}

test("Full pipeline: HTML → parse → headings → chapter navigation") {
    let url = try requireFile("frankenstein.html")
    let html = try String(contentsOf: url, encoding: .utf8)
    let content = try parseHTML(html: html, title: "Frankenstein")

    // Navigate through chapters sequentially
    var totalCharsVisited = 0
    for (i, chapter) in content.chapters.enumerated() {
        let startOffset = content.chapterStartOffset(i)
        try assertEqual(startOffset, totalCharsVisited,
            "Chapter \(i) start should be \(totalCharsVisited), got \(startOffset)")
        totalCharsVisited += chapter.text.count
    }
    try assertEqual(totalCharsVisited, content.totalCharacterCount)
}

test("Full pipeline: Markdown → parse → heading hierarchy → global offsets") {
    let url = try requireFile("sample.md")
    let md = try String(contentsOf: url, encoding: .utf8)
    let content = try parseMarkdown(markdown: md, title: "Sample")

    // Verify headings are accessible globally
    let globalHeadings = content.allHeadings
    try assertEqual(globalHeadings.count, sampleMarkdownHeadingCount, "sample.md should keep exactly its headings")
    for heading in globalHeadings {
        // Each heading's global offset should be within document bounds
        let globalOffset = content.globalOffset(chapterIndex: heading.chapterIndex, localOffset: heading.characterOffset)
        try assertTrue(globalOffset >= 0 && globalOffset <= content.totalCharacterCount,
            "Heading '\(heading.text)' global offset \(globalOffset) out of bounds [0, \(content.totalCharacterCount)]")
    }
}


// ---- Book Format Detection + Parser Dispatch ----
print("\n--- Integration: Format Detection + Parser Dispatch ---")

test("BookFormat detection matches parser availability for each test file") {
    // Verify that format detection routes to the correct parser
    let testFiles: [(name: String, expectedFormat: String)] = [
        ("alice.epub", "epub"),
        ("frankenstein.html", "html"),
        ("pride.txt", "txt"),
        ("sample.md", "markdown"),
    ]

    for (name, expected) in testFiles {
        let detected = BookFormat.detect(from: URL(fileURLWithPath: name))?.rawValue
        try assertEqual(detected, expected, "File \(name) should detect as \(expected)")
    }
}

test("All test files parse without errors") {
    // Parse every test file through the appropriate parser and verify basic sanity
    let epubURL = try requireFile("alice.epub")
    let epubContent = try parseEPUB(url: epubURL)
    try assertGreater(epubContent.chapters.count, 0, "EPUB should have chapters")
    try assertGreater(epubContent.totalWordCount, 0, "EPUB should have words")

    let htmlURL = try requireFile("frankenstein.html")
    let htmlText = try String(contentsOf: htmlURL, encoding: .utf8)
    let htmlContent = try parseHTML(html: htmlText, title: "Frankenstein")
    try assertGreater(htmlContent.chapters.count, 0, "HTML should have chapters")
    try assertGreater(htmlContent.totalWordCount, 0, "HTML should have words")

    let txtURL = try requireFile("pride.txt")
    let txtText = try String(contentsOf: txtURL, encoding: .utf8)
    let txtContent = parsePlainText(text: txtText, title: "Pride")
    try assertGreater(txtContent.chapters.count, 0, "TXT should have chapters")
    try assertGreater(txtContent.totalWordCount, 0, "TXT should have words")

    let mdURL = try requireFile("sample.md")
    let mdText = try String(contentsOf: mdURL, encoding: .utf8)
    let mdContent = try parseMarkdown(markdown: mdText, title: "Sample")
    try assertGreater(mdContent.chapters.count, 0, "MD should have chapters")
    try assertGreater(mdContent.totalWordCount, 0, "MD should have words")
}

} // end runIntegrationTests
