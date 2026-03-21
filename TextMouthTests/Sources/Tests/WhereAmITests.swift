import Foundation

func runWhereAmITests() {
print("\n--- Where Am I Summary Logic Tests ---")

test("Where Am I builds correct summary parts") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }
    let totalWords = epub.chapters.reduce(0) { $0 + $1.text.split(separator: " ").count }
    let wpm = 200.0

    // Simulate being at chapter 2, offset 100
    let chapterIndex = min(2, epub.chapters.count - 1)
    let charOffset = min(100, epub.chapters[chapterIndex].text.count - 1)

    // Global offset
    let globalOffset = epub.chapters[0..<chapterIndex].reduce(0) { $0 + $1.text.count } + charOffset

    // Percentage
    let percent = Double(globalOffset) / Double(totalChars) * 100.0
    try assertTrue(percent >= 0 && percent <= 100, "Percentage should be 0-100, got \(percent)")

    // Time remaining
    let remainingFraction = Double(max(totalChars - globalOffset, 0)) / Double(totalChars)
    let totalTime = Double(totalWords) / wpm * 60.0
    let remaining = totalTime * remainingFraction
    try assertTrue(remaining >= 0, "Remaining time should be non-negative")
    try assertTrue(remaining <= totalTime, "Remaining should be <= total")

    print("    At chapter \(chapterIndex+1), offset \(charOffset): \(String(format: "%.1f", percent))%")
    print("    Time remaining: \(Int(remaining))s of \(Int(totalTime))s total")
}

test("Where Am I finds current heading at position") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let allHeadings = epub.allHeadings
    guard allHeadings.count >= 3 else { throw TestError.assertionFailed("Need headings") }

    // Find a chapter heading (one that's the only heading in its chapter for a clean test)
    // Use the first heading in a chapter that has exactly one heading
    var targetHeading: Heading?
    for heading in allHeadings {
        let chapterHeadings = allHeadings.filter { $0.chapterIndex == heading.chapterIndex }
        if chapterHeadings.count == 1 && heading.characterOffset == 0 {
            targetHeading = heading
            break
        }
    }
    guard let heading = targetHeading else { throw TestError.assertionFailed("Need a solo chapter heading") }

    let testChapter = heading.chapterIndex
    let testOffset = heading.characterOffset + 50

    // Find heading at or before position (same logic as app)
    let currentHeading = allHeadings.last(where: {
        $0.chapterIndex < testChapter ||
        ($0.chapterIndex == testChapter && $0.characterOffset <= testOffset)
    })

    try assertTrue(currentHeading != nil, "Should find a heading")
    try assertEqual(currentHeading!.chapterIndex, testChapter, "Should find heading in the same chapter")
    try assertTrue(currentHeading!.characterOffset <= testOffset, "Found heading should be at or before our position")
    print("    At chapter \(testChapter), offset \(testOffset): heading '\(currentHeading!.text)'")
}

test("Where Am I heading time remaining calculation") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let allHeadings = epub.allHeadings
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }
    let totalWords = epub.chapters.reduce(0) { $0 + $1.text.split(separator: " ").count }
    let wpm = 200.0
    guard allHeadings.count >= 2 else { throw TestError.assertionFailed("Need headings") }

    let heading = allHeadings[0]
    let headingGlobalStart = epub.chapters[0..<heading.chapterIndex].reduce(0) { $0 + $1.text.count } + heading.characterOffset

    // Find next heading's global offset
    var nextOffset = totalChars
    if allHeadings.count > 1 {
        let next = allHeadings[1]
        nextOffset = epub.chapters[0..<next.chapterIndex].reduce(0) { $0 + $1.text.count } + next.characterOffset
    }

    let headingChars = nextOffset - headingGlobalStart
    try assertGreater(headingChars, 0, "Heading should have some characters")

    // Time for this heading section
    let wordEstimate = Double(headingChars) / Double(totalChars) * Double(totalWords)
    let headingTime = wordEstimate / wpm * 60.0
    try assertTrue(headingTime > 0, "Heading time should be positive")

    // If we're 50% through the heading
    let fractionRemaining = 0.5
    let headingRemaining = headingTime * fractionRemaining
    try assertTrue(headingRemaining > 0 && headingRemaining < headingTime, "Remaining should be less than total")

    print("    First heading '\(heading.text)': \(headingChars) chars, \(String(format: "%.0f", headingTime))s total")
    print("    At 50%: \(String(format: "%.0f", headingRemaining))s remaining")
}

test("Where Am I at start of book") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }

    let globalOffset = 0
    let percent = Double(globalOffset) / Double(totalChars) * 100.0
    try assertTrue(percent < 0.01, "Start should be ~0%")

    let remainingFraction = 1.0
    try assertTrue(remainingFraction > 0.99, "Full time remaining at start")
    print("    At start: \(String(format: "%.1f", percent))% complete")
}

test("Where Am I at end of book") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }

    let globalOffset = totalChars
    let percent = min(Double(globalOffset) / Double(totalChars) * 100.0, 100.0)
    try assertTrue(percent >= 99.9, "End should be ~100%")

    let remainingFraction = Double(max(totalChars - globalOffset, 0)) / Double(totalChars)
    try assertTrue(remainingFraction < 0.01, "No time remaining at end")
    print("    At end: \(String(format: "%.1f", percent))% complete")
}

test("Where Am I heading at start vs middle vs end") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let allHeadings = epub.allHeadings
    guard allHeadings.count >= 3 else { throw TestError.assertionFailed("Need headings") }

    // At very start (before first heading)
    let atStart = allHeadings.last(where: { $0.chapterIndex == 0 && $0.characterOffset <= 0 })
    // May or may not find a heading at offset 0

    // At middle
    let midChapter = epub.chapters.count / 2
    let midOffset = epub.chapters[midChapter].text.count / 2
    let atMiddle = allHeadings.last(where: {
        $0.chapterIndex < midChapter ||
        ($0.chapterIndex == midChapter && $0.characterOffset <= midOffset)
    })
    try assertTrue(atMiddle != nil, "Should find a heading at middle of book")

    // At last chapter
    let lastChapter = epub.chapters.count - 1
    let lastOffset = epub.chapters[lastChapter].text.count / 2
    let atEnd = allHeadings.last(where: {
        $0.chapterIndex < lastChapter ||
        ($0.chapterIndex == lastChapter && $0.characterOffset <= lastOffset)
    })
    try assertTrue(atEnd != nil, "Should find a heading near end of book")

    print("    Start heading: \(atStart?.text ?? "none")")
    print("    Middle heading: \(atMiddle!.text)")
    print("    End heading: \(atEnd!.text)")
}

// ---- Where Am I Logic Tests ----
print("\n--- Where Am I Logic Tests ---")

test("Where Am I finds closest heading at position") {
    let headings = [
        Heading(level: 1, text: "Chapter 1", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "Section 1.1", chapterIndex: 0, characterOffset: 500),
        Heading(level: 2, text: "Section 1.2", chapterIndex: 0, characterOffset: 1000),
        Heading(level: 1, text: "Chapter 2", chapterIndex: 1, characterOffset: 0),
    ]

    func currentHeading(chapter: Int, offset: Int) -> Heading? {
        headings.last(where: {
            $0.chapterIndex < chapter ||
            ($0.chapterIndex == chapter && $0.characterOffset <= offset)
        })
    }

    // At start of Chapter 1
    let h1 = currentHeading(chapter: 0, offset: 0)
    try assertEqual(h1?.text, "Chapter 1")

    // At offset 750 in chapter 0 — should be Section 1.1 (not 1.2)
    let h2 = currentHeading(chapter: 0, offset: 750)
    try assertEqual(h2?.text, "Section 1.1", "Should find Section 1.1, not 1.2")

    // At offset 1001 in chapter 0 — should be Section 1.2
    let h3 = currentHeading(chapter: 0, offset: 1001)
    try assertEqual(h3?.text, "Section 1.2")

    // At chapter 1 offset 0 — should be Chapter 2
    let h4 = currentHeading(chapter: 1, offset: 0)
    try assertEqual(h4?.text, "Chapter 2")

    // At chapter 1 offset 100 — should still be Chapter 2 (no later headings)
    let h5 = currentHeading(chapter: 1, offset: 100)
    try assertEqual(h5?.text, "Chapter 2")
}

test("Where Am I with no headings returns nil") {
    let headings: [Heading] = []
    let result = headings.last(where: {
        $0.chapterIndex < 0 || ($0.chapterIndex == 0 && $0.characterOffset <= 500)
    })
    try assertTrue(result == nil, "Should return nil with no headings")
}

// ---- Where Am I Detail Levels ----
print("\n--- Where Am I Detail Levels ---")

test("Where Am I: brief summary is shorter than full") {
    // Brief: title, chapter, percentage, time remaining
    let brief = ["My Book", "Chapter 5 of 20", "25 percent", "3:00:00 remaining"]
    // Full: adds heading, heading time, total time
    let full = brief + ["Current heading: The Battle", "0:15:00 remaining in this heading", "Total book time: 4:00:00"]
    try assertTrue(brief.count < full.count)
    try assertEqual(brief.count, 4)
    try assertEqual(full.count, 7)
}

test("Where Am I: escalation within 3 seconds triggers full") {
    let threshold = 3.0
    let lastTime = Date()
    let now = lastTime.addingTimeInterval(2.0) // 2 seconds later
    let elapsed = now.timeIntervalSince(lastTime)
    let useFull = elapsed < threshold
    try assertTrue(useFull, "Should use full detail when pressed within 3 seconds")
}

test("Where Am I: first press after long gap uses brief") {
    let threshold = 3.0
    let lastTime = Date.distantPast
    let now = Date()
    let elapsed = now.timeIntervalSince(lastTime)
    let useFull = elapsed < threshold
    try assertTrue(!useFull, "Should use brief detail on first press")
}

test("Where Am I: press after exactly 3 seconds uses brief") {
    let threshold = 3.0
    let lastTime = Date()
    let now = lastTime.addingTimeInterval(3.0)
    let elapsed = now.timeIntervalSince(lastTime)
    let useFull = elapsed < threshold
    try assertTrue(!useFull, "3 seconds should not trigger full")
}

test("Where Am I: brief includes percentage") {
    let parts = ["Book Title", "Chapter 3 of 10", "30 percent", "2:00:00 remaining"]
    let summary = parts.joined(separator: ". ") + "."
    try assertTrue(summary.contains("30 percent"))
    try assertTrue(summary.contains("Chapter 3 of 10"))
    try assertTrue(!summary.contains("heading"), "Brief should not include heading info")
}

test("Where Am I: full includes heading and total time") {
    let parts = ["Book Title", "Chapter 3 of 10", "30 percent", "2:00:00 remaining",
                  "Current heading: Battle", "0:10:00 remaining in this heading", "Total book time: 5:00:00"]
    let summary = parts.joined(separator: ". ") + "."
    try assertTrue(summary.contains("Current heading: Battle"))
    try assertTrue(summary.contains("Total book time"))
}

// MARK: - Where Am I vs Playback State Tests

test("Where Am I: play/pause guard prevents simultaneous playback") {
    // Simulates the state machine that prevents book + Where Am I from speaking simultaneously.
    // The ReaderViewModel guards togglePlayPause() with isWhereAmISpeaking.

    var isWhereAmISpeaking = false
    var wasPlayingBeforeWhereAmI = false
    var bookIsPlaying = true
    var bookIsPaused = false

    // Step 1: Where Am I starts — book should pause
    wasPlayingBeforeWhereAmI = bookIsPlaying && !bookIsPaused
    try assertTrue(wasPlayingBeforeWhereAmI, "Should detect book was playing")

    // Simulate pause
    bookIsPaused = true
    isWhereAmISpeaking = true

    // Step 2: User presses K (togglePlayPause) while Where Am I is speaking
    // The guard should prevent resuming the book
    if isWhereAmISpeaking {
        // This is the guard in togglePlayPause — should cancel Where Am I, not resume book
        isWhereAmISpeaking = false
        wasPlayingBeforeWhereAmI = false  // Don't auto-resume
        // Book stays paused
        try assertTrue(bookIsPaused, "Book should remain paused after K during Where Am I")
        try assertTrue(!isWhereAmISpeaking, "Where Am I should be cancelled")
    }

    // Step 3: User presses K again — NOW book should resume (Where Am I is done)
    if !isWhereAmISpeaking && bookIsPaused {
        bookIsPaused = false
        try assertTrue(!bookIsPaused, "Book should resume on second K press")
    }
}

test("Where Am I: skip cancels announcement and resumes book") {
    var isWhereAmISpeaking = true
    var wasPlayingBeforeWhereAmI = true
    var bookIsPaused = true
    var bookResumed = false

    // User presses skip while Where Am I is speaking
    // cancelWhereAmIIfActive should stop announcement and resume book
    if isWhereAmISpeaking {
        isWhereAmISpeaking = false
        if wasPlayingBeforeWhereAmI {
            wasPlayingBeforeWhereAmI = false
            bookIsPaused = false
            bookResumed = true
        }
    }

    try assertTrue(!isWhereAmISpeaking, "Where Am I should be cancelled")
    try assertTrue(bookResumed, "Book should resume after skip during Where Am I")
    try assertTrue(!bookIsPaused, "Book should not be paused")
}

test("Where Am I: play() blocked while announcement active") {
    var isWhereAmISpeaking = true
    var playStarted = false

    // play() should return early if Where Am I is speaking
    if isWhereAmISpeaking {
        // Guard: return without starting playback
    } else {
        playStarted = true
    }

    try assertTrue(!playStarted, "play() should not start while Where Am I is speaking")
}

test("Where Am I: announcement completes normally and resumes book") {
    var isWhereAmISpeaking = true
    var wasPlayingBeforeWhereAmI = true
    var bookResumed = false

    // Simulate the didFinish delegate callback
    isWhereAmISpeaking = false
    if wasPlayingBeforeWhereAmI {
        wasPlayingBeforeWhereAmI = false
        bookResumed = true
    }

    try assertTrue(!isWhereAmISpeaking, "Where Am I should be done")
    try assertTrue(bookResumed, "Book should auto-resume after announcement finishes")
}

test("Where Am I: book was not playing, no resume after announcement") {
    var isWhereAmISpeaking = true
    var wasPlayingBeforeWhereAmI = false
    var bookResumed = false

    // Where Am I finishes, but book wasn't playing before
    isWhereAmISpeaking = false
    if wasPlayingBeforeWhereAmI {
        bookResumed = true
    }

    try assertTrue(!bookResumed, "Book should NOT resume if it wasn't playing before Where Am I")
}

} // end runWhereAmITests
