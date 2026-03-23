import Foundation

func runDAISYChapterSplitTests() {
print("\n--- DAISY Chapter Splitting Tests ---")

test("DTBook converter emits chapter markers at level1 boundaries") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter>
    <level1><h1>Chapter One</h1>
    <p>First chapter content.</p>
    </level1>
    <level1><h1>Chapter Two</h1>
    <p>Second chapter content.</p>
    </level1>
    </bodymatter></book></dtbook>
    """
    let markdown = convertDTBookWithChapterMarkers(dtbook)
    try assertTrue(
        markdown.contains("<!-- chapter: Chapter One -->"),
        "Should emit chapter marker for Chapter One"
    )
    try assertTrue(
        markdown.contains("<!-- chapter: Chapter Two -->"),
        "Should emit chapter marker for Chapter Two"
    )
}

test("DTBook chapter marker appears before the heading") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter>
    <level1><h1>First Section</h1>
    <p>Some text.</p>
    </level1>
    </bodymatter></book></dtbook>
    """
    let markdown = convertDTBookWithChapterMarkers(dtbook)
    if let markerRange = markdown.range(of: "<!-- chapter: First Section -->"),
       let headingRange = markdown.range(of: "# First Section") {
        try assertTrue(
            markerRange.lowerBound < headingRange.lowerBound,
            "Chapter marker should appear before the heading"
        )
    } else {
        throw TestError.assertionFailed("Missing chapter marker or heading")
    }
}

test("DTBook without level1 produces no chapter markers") {
    let dtbook = """
    <?xml version="1.0" encoding="UTF-8"?>
    <dtbook xmlns="http://www.daisy.org/z3986/2005/dtbook/" version="2005-3">
    <head><meta name="dc:Title" content="Test"/></head>
    <book><bodymatter>
    <h1>Standalone Heading</h1>
    <p>Some text without level1 wrapper.</p>
    </bodymatter></book></dtbook>
    """
    let markdown = convertDTBookWithChapterMarkers(dtbook)
    try assertTrue(
        !markdown.contains("<!-- chapter:"),
        "Should not emit chapter markers without level1 elements"
    )
}

test("Oversized chapter splitting works at paragraph boundaries") {
    // Build a chapter with text exceeding 40,000 characters
    var longText = "# Big Chapter\n\n"
    let paragraph = String(repeating: "This is a test sentence. ", count: 50) + "\n\n"
    while longText.count < 60_000 {
        longText += paragraph
    }

    let chapters = [TestChapter(title: "Big Chapter", text: longText, headings: [])]
    let result = splitOversizedTestChapters(chapters, maxSize: 40_000)

    try assertGreater(result.count, 1, "Should split into multiple chapters")
    // Each chunk should be under the limit (except possibly the last one which
    // could be slightly over if a single paragraph exceeds the limit)
    for (i, ch) in result.enumerated() {
        if i < result.count - 1 {
            try assertTrue(
                ch.text.count <= 45_000,
                "Chunk \(i) should be roughly under maxSize, got \(ch.text.count)"
            )
        }
    }
    try assertEqual(result[0].title, "Big Chapter", "First chunk keeps original title")
    try assertTrue(
        result[1].title.contains("part 2"),
        "Subsequent chunks get part numbers"
    )
}

test("Small chapters are not split") {
    let chapters = [TestChapter(title: "Short", text: "Hello world", headings: [])]
    let result = splitOversizedTestChapters(chapters, maxSize: 40_000)
    try assertEqual(result.count, 1, "Should not split small chapter")
    try assertEqual(result[0].title, "Short")
}

test("Multiple chapters with one oversized splits only the large one") {
    let shortText = "Short chapter text."
    var longText = ""
    let paragraph = String(repeating: "Word ", count: 200) + "\n\n"
    while longText.count < 60_000 {
        longText += paragraph
    }

    let chapters = [
        TestChapter(title: "Intro", text: shortText, headings: []),
        TestChapter(title: "Main Content", text: longText, headings: []),
        TestChapter(title: "Epilogue", text: shortText, headings: []),
    ]
    let result = splitOversizedTestChapters(chapters, maxSize: 40_000)
    try assertGreater(result.count, 3, "Should have more than 3 chapters after splitting")
    try assertEqual(result[0].title, "Intro", "First chapter unchanged")
    try assertEqual(result.last!.title, "Epilogue", "Last chapter unchanged")
}

test("Hyperion DAISY produces multiple chapters") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdownFull(from: url)
    try assertTrue(
        markdown.contains("<!-- chapter:"),
        "Hyperion DAISY should contain chapter markers"
    )
}

test("Hyperion DAISY cache produces manageable chapter sizes") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdownFull(from: url)
    let content = parseMultiChapterMarkdownTest(
        markdown, bookTitle: "Hyperion", bookAuthor: "Dan Simmons"
    )
    try assertGreater(content.chapters.count, 2,
        "Should have more than 2 chapters after splitting (got \(content.chapters.count))")
    for (i, ch) in content.chapters.enumerated() {
        try assertTrue(
            ch.text.count <= 45_000,
            "Chapter \(i) (\(ch.title)) should be under 45k chars, got \(ch.text.count)"
        )
    }
}

test("Split chapters have headings for navigator") {
    var longText = ""
    let paragraph = String(repeating: "This is a test sentence. ", count: 50) + "\n\n"
    while longText.count < 60_000 {
        longText += paragraph
    }
    let chapters = [TestChapter(title: "Big Chapter", text: longText, headings: [])]
    let result = splitOversizedTestChapters(chapters, maxSize: 40_000)
    try assertGreater(result.count, 1, "Should split")
    for (i, ch) in result.enumerated() {
        try assertEqual(ch.headings.count, 1,
            "Split chunk \(i) should have exactly one heading")
        try assertEqual(ch.headings[0].text, ch.title,
            "Heading text should match chapter title")
        try assertEqual(ch.headings[0].level, 1,
            "Split chapter heading should be level 1")
        try assertEqual(ch.headings[0].characterOffset, 0,
            "Heading should be at offset 0")
    }
}

test("Hyperion all chapters have headings for navigation") {
    let url = try requireFile("hyperion_daisy.zip")
    let markdown = try parseDAISYToMarkdownFull(from: url)
    let content = parseMultiChapterMarkdownTest(
        markdown, bookTitle: "Hyperion", bookAuthor: "Dan Simmons"
    )
    for (i, ch) in content.chapters.enumerated() {
        try assertGreater(ch.headings.count, 0,
            "Chapter \(i) (\(ch.title)) should have at least one heading")
    }
    // Total headings should be at least as many as chapters (some may have more)
    let allHeadings = content.allHeadings
    try assertTrue(allHeadings.count >= content.chapters.count,
        "Should have at least one heading per chapter (got \(allHeadings.count) headings for \(content.chapters.count) chapters)")
}

}
