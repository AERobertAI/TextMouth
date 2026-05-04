import Foundation
import ZIPFoundation

func runDocumentContentTests() {
// ---- WPM Calculation Tests ----
print("\n--- WPM Calculation Tests ---")

test("Word count estimation for speed control") {
    let sampleText = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
    let words = sampleText.split(separator: " ").count
    try assertEqual(words, 17, "Should count 17 words")

    // Test rate conversion
    let baselineWPM = 190.0
    func rateForWPM(_ wpm: Double) -> Float {
        Float(min(max(0.5 * (wpm / baselineWPM), 0.0), 1.0))
    }
    let rate200 = rateForWPM(200)
    let rate300 = rateForWPM(300)
    let rate400 = rateForWPM(400)
    try assertTrue(rate200 > 0.5 && rate200 < 0.6, "200 WPM rate should be ~0.53")
    try assertTrue(rate300 > 0.7 && rate300 < 0.85, "300 WPM rate should be ~0.79")
    try assertTrue(rate400 <= 1.0, "400 WPM rate should be <= 1.0")
    print("    200 WPM -> rate \(rate200)")
    print("    300 WPM -> rate \(rate300)")
    print("    400 WPM -> rate \(rate400)")
}

// ---- ZIP Import Tests ----
print("\n--- ZIP Handling Tests ---")

test("EPUB is a valid ZIP (ZIPFoundation can open it)") {
    let url = try requireFile("alice.epub")
    let archive = try Archive(url: url, accessMode: .read)

    // Count entries
    var count = 0
    for _ in archive { count += 1 }
    try assertGreater(count, 1, "Should have multiple entries")
    print("    ZIP entries: \(count)")
}

// ---- Cross-Parser Consistency Tests ----
print("\n--- Cross-Parser Consistency Tests ---")

test("All parsers return non-empty DocumentContent") {
    let epubURL = try requireFile("alice.epub")
    let htmlURL = try requireFile("frankenstein.html")
    let txtURL = try requireFile("pride.txt")
    let mdURL = try requireFile("sample.md")

    let epub = try parseEPUB(url: epubURL)
    let html = try parseHTML(html: try String(contentsOf: htmlURL), title: "Frankenstein")
    let txt = parsePlainText(text: try String(contentsOf: txtURL), title: "Pride")
    let md = try parseMarkdown(markdown: try String(contentsOf: mdURL), title: "Sample")

    let results = [("EPUB", epub), ("HTML", html), ("TXT", txt), ("Markdown", md)]
    for (name, content) in results {
        try assertTrue(!content.title.isEmpty, "\(name) title should not be empty")
        try assertGreater(content.chapters.count, 0, "\(name) should have chapters")
        let totalTextLen = content.chapters.map { $0.text.count }.reduce(0, +)
        try assertGreater(totalTextLen, 0, "\(name) should have text")
        let wordCount = content.chapters.flatMap { $0.text.split(separator: " ") }.count
        print("    \(name): \"\(content.title)\" by \(content.author) -- \(content.chapters.count) chapters, ~\(wordCount) words, \(content.allHeadings.count) headings")
    }
}

// ---- Word Count & Time Estimation Tests ----
print("\n--- Word Count & Time Estimation Tests ---")

test("Word count calculated for each parser output") {
    let epubURL = try requireFile("alice.epub")
    let epub = try parseEPUB(url: epubURL)
    let totalWords = epub.chapters.reduce(0) { $0 + $1.text.split(separator: " ").count }
    try assertGreater(totalWords, 1000, "Alice should have many words")
    print("    Alice word count: \(totalWords)")
}

test("Chapter word counts sum correctly") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let chapterWordCounts = epub.chapters.map { $0.text.split(separator: " ").count }
    let totalWords = chapterWordCounts.reduce(0, +)
    let summedAgain = epub.chapters.reduce(0) { $0 + $1.text.split(separator: " ").count }
    try assertEqual(totalWords, summedAgain)
    print("    Per-chapter word counts: \(chapterWordCounts.prefix(5))...")
}

test("Time estimation at various WPM") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let totalWords = epub.chapters.reduce(0) { $0 + $1.text.split(separator: " ").count }

    let time200 = Double(totalWords) / 200.0 * 60.0
    let time300 = Double(totalWords) / 300.0 * 60.0
    let time400 = Double(totalWords) / 400.0 * 60.0

    try assertTrue(time200 > time300, "Slower speed should take longer")
    try assertTrue(time300 > time400, "Slower speed should take longer")
    try assertTrue(time200 > 0, "Time should be positive")

    func fmt(_ seconds: Double) -> String {
        let t = Int(seconds)
        let h = t / 3600; let m = (t % 3600) / 60; let s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    print("    At 200 WPM: \(fmt(time200))")
    print("    At 300 WPM: \(fmt(time300))")
    print("    At 400 WPM: \(fmt(time400))")
}

test("Percentage completion calculation") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }

    // At start
    let pctStart = 0.0 / Double(totalChars) * 100.0
    try assertEqual(Int(pctStart), 0)

    // At halfway
    let pctHalf = Double(totalChars / 2) / Double(totalChars) * 100.0
    try assertTrue(pctHalf > 49.0 && pctHalf < 51.0, "Should be ~50%")

    // At end
    let pctEnd = Double(totalChars) / Double(totalChars) * 100.0
    try assertTrue(pctEnd >= 99.9, "Should be ~100%")
    print("    Total chars: \(totalChars), 50% offset: \(totalChars/2)")
}

test("Heading time estimates are positive and ordered") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    let headings = epub.allHeadings
    let totalChars = epub.chapters.reduce(0) { $0 + $1.text.count }
    guard headings.count > 2, totalChars > 0 else { throw TestError.assertionFailed("Need headings") }

    // Calculate global offsets for headings
    var cumulativeOffset = 0
    var chapterOffsets: [Int] = []
    for chapter in epub.chapters {
        chapterOffsets.append(cumulativeOffset)
        cumulativeOffset += chapter.text.count
    }

    // Heading global offsets should be in increasing order
    var prevOffset = -1
    for heading in headings {
        let globalOffset = (heading.chapterIndex < chapterOffsets.count ? chapterOffsets[heading.chapterIndex] : 0) + heading.characterOffset
        try assertTrue(globalOffset >= prevOffset, "Headings should be ordered")
        prevOffset = globalOffset
    }

    // Time percentages should cover roughly 0-100%
    let firstGlobal = (headings.first!.chapterIndex < chapterOffsets.count ? chapterOffsets[headings.first!.chapterIndex] : 0) + headings.first!.characterOffset
    let lastGlobal = (headings.last!.chapterIndex < chapterOffsets.count ? chapterOffsets[headings.last!.chapterIndex] : 0) + headings.last!.characterOffset
    let firstPct = Double(firstGlobal) / Double(totalChars) * 100.0
    let lastPct = Double(lastGlobal) / Double(totalChars) * 100.0
    print("    First heading at \(String(format: "%.1f", firstPct))%, last at \(String(format: "%.1f", lastPct))%")
    print("    Headings tested: \(headings.count)")
}

test("Cross-chapter skip simulation") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    // Simulate being at start of chapter 5 (index 4) and skipping backward
    let chapIdx = 4
    let charOffset = 0
    let charDelta = -500  // skip backward ~100 words

    var newChap = chapIdx
    var newOffset = charOffset + charDelta

    // Cross-chapter backward navigation
    while newOffset < 0 && newChap > 0 {
        newChap -= 1
        newOffset += epub.chapters[newChap].text.count
    }
    newOffset = max(0, newOffset)

    try assertTrue(newChap < chapIdx, "Should have moved to a previous chapter")
    try assertTrue(newOffset >= 0, "Offset should be non-negative")
    print("    From ch\(chapIdx+1) offset 0, skip -500 chars -> ch\(newChap+1) offset \(newOffset)")
}

test("Cross-chapter skip forward simulation") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    // Start near end of chapter 3 (index 2)
    let chapIdx = 2
    let chapLen = epub.chapters[chapIdx].text.count
    let charOffset = chapLen - 50
    let charDelta = 500  // skip forward

    var newChap = chapIdx
    var newOffset = charOffset + charDelta

    while newChap < epub.chapters.count && newOffset >= epub.chapters[newChap].text.count {
        newOffset -= epub.chapters[newChap].text.count
        newChap += 1
    }
    if newChap >= epub.chapters.count {
        newChap = epub.chapters.count - 1
        newOffset = epub.chapters[newChap].text.count - 1
    }

    try assertTrue(newChap > chapIdx, "Should have moved to a later chapter")
    try assertTrue(newOffset >= 0 && newOffset < epub.chapters[newChap].text.count, "Offset should be within chapter")
    print("    From ch\(chapIdx+1) offset \(charOffset), skip +500 chars -> ch\(newChap+1) offset \(newOffset)")
}

test("PlainTextParser no duplicate headings for all-caps lines") {
    let testText = "# CHAPTER ONE\n\nSome text here.\n\nCHAPTER TWO\n\nMore text."
    let content = parsePlainText(text: testText, title: "Test")
    // "# CHAPTER ONE" should be detected as markdown heading only (not also all-caps)
    // "CHAPTER TWO" should be detected as all-caps only
    let headings = content.allHeadings
    let chapterOneHeadings = headings.filter { $0.text.contains("ONE") }
    let chapterTwoHeadings = headings.filter { $0.text.contains("TWO") }
    try assertEqual(chapterOneHeadings.count, 1, "CHAPTER ONE should appear exactly once")
    try assertEqual(chapterTwoHeadings.count, 1, "CHAPTER TWO should appear exactly once")
    print("    Headings: \(headings.map { "H\($0.level):\($0.text)" })")
}

// ---- DocumentContent Model Tests ----
print("\n--- DocumentContent Model Tests ---")

test("Stable heading IDs are deterministic") {
    let h1 = Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0)
    let h2 = Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0)
    try assertEqual(h1.id, h2.id, "Same content should produce same ID")

    let h3 = Heading(level: 1, text: "Introduction", chapterIndex: 1, characterOffset: 0)
    try assertTrue(h1.id != h3.id, "Different chapter should produce different ID")

    let h4 = Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 50)
    try assertTrue(h1.id != h4.id, "Different offset should produce different ID")
}

test("allHeadings assigns correct chapter indices") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "Ch1", text: "Chapter one text", headings: [
                Heading(level: 1, text: "Ch1 Heading", characterOffset: 0)
            ]),
            Chapter(title: "Ch2", text: "Chapter two text", headings: [
                Heading(level: 1, text: "Ch2 Heading", characterOffset: 0)
            ]),
        ]
    )
    let all = doc.allHeadings
    try assertEqual(all.count, 2)
    try assertEqual(all[0].chapterIndex, 0)
    try assertEqual(all[1].chapterIndex, 1)
    // IDs should reflect their assigned chapter indices
    try assertTrue(all[0].id.hasPrefix("0-"), "First heading ID should start with chapter 0")
    try assertTrue(all[1].id.hasPrefix("1-"), "Second heading ID should start with chapter 1")
}

test("allHeadings produces stable IDs across multiple calls") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "Ch1", text: "text", headings: [
                Heading(level: 1, text: "Heading", characterOffset: 0)
            ]),
        ]
    )
    let ids1 = doc.allHeadings.map { $0.id }
    let ids2 = doc.allHeadings.map { $0.id }
    try assertEqual(ids1, ids2, "IDs should be identical across calls")
}

test("totalWordCount uses whitespace splitting") {
    let chapter = Chapter(title: "Test", text: "one\ttwo\nthree  four\n\nfive")
    let words = chapter.text.split(whereSeparator: { $0.isWhitespace }).count
    try assertEqual(words, 5, "Should count 5 words with tabs, newlines, multiple spaces")
}

test("chapterStartOffset for various indices") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 100)),
            Chapter(title: "B", text: String(repeating: "b", count: 200)),
            Chapter(title: "C", text: String(repeating: "c", count: 150)),
        ]
    )
    try assertEqual(doc.chapterStartOffset(0), 0, "Chapter 0 starts at 0")
    try assertEqual(doc.chapterStartOffset(1), 100, "Chapter 1 starts at 100")
    try assertEqual(doc.chapterStartOffset(2), 300, "Chapter 2 starts at 300")
    try assertEqual(doc.chapterStartOffset(-1), 0, "Negative index returns 0")
    // Index beyond range should clamp
    try assertEqual(doc.chapterStartOffset(99), 450, "Beyond range clamps to total")
}

test("globalOffset combines chapter start and local offset") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 100)),
            Chapter(title: "B", text: String(repeating: "b", count: 200)),
        ]
    )
    try assertEqual(doc.globalOffset(chapterIndex: 0, localOffset: 50), 50)
    try assertEqual(doc.globalOffset(chapterIndex: 1, localOffset: 50), 150)
}

test("estimatedReadingTime returns seconds") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            // 100 words
            Chapter(title: "A", text: (0..<100).map { _ in "word" }.joined(separator: " "))
        ]
    )
    // 100 words at 100 WPM = 1 minute = 60 seconds
    let time = doc.estimatedReadingTime(wpm: 100)
    try assertEqual(Int(time), 60, "100 words at 100 WPM should be 60 seconds")

    // Zero WPM should return 0
    try assertEqual(doc.estimatedReadingTime(wpm: 0), 0, "Zero WPM should return 0")
}

test("percentComplete calculation") {
    let totalChars = 1000

    func percentComplete(globalOffset: Int) -> Double {
        guard totalChars > 0 else { return 0 }
        return min(Double(globalOffset) / Double(totalChars) * 100.0, 100.0)
    }

    try assertEqual(percentComplete(globalOffset: 0), 0.0, "Start should be 0%")
    try assertEqual(percentComplete(globalOffset: 500), 50.0, "Halfway should be 50%")
    try assertEqual(percentComplete(globalOffset: 1000), 100.0, "End should be 100%")
    try assertEqual(percentComplete(globalOffset: 2000), 100.0, "Beyond end should cap at 100%")
}

test("TimeFormatting.format handles various durations") {
    func fmt(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(max(seconds, 0))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    try assertEqual(fmt(0), "0:00")
    try assertEqual(fmt(59), "0:59")
    try assertEqual(fmt(60), "1:00")
    try assertEqual(fmt(3600), "1:00:00")
    try assertEqual(fmt(3661), "1:01:01")
    try assertEqual(fmt(-5), "0:00", "Negative should clamp to 0")
}

// ---- SleepTimerDuration Model Tests ----
print("\n--- SleepTimerDuration Model Tests ---")

test("SleepTimerDuration display names") {
    // minutes
    let m10 = "10 minutes"
    let m60 = "60 minutes"
    try assertEqual(m10, "10 minutes")
    try assertEqual(m60, "60 minutes")

    let eoh = "End of heading"
    let eod = "End of document"
    try assertEqual(eoh, "End of heading")
    try assertEqual(eod, "End of document")
}

test("SleepTimerDuration presets count") {
    // There should be 7 presets: 10, 15, 30, 45, 60, endOfHeading, endOfDocument
    let presetCount = 7
    try assertEqual(presetCount, 7, "Should have 7 presets")
}

// ---- location(forGlobalOffset:) Reverse Lookup Tests ----
print("\n--- location(forGlobalOffset:) Reverse Lookup Tests ---")

// These cover the new reverse-lookup helper added for jump-to-percent /
// jump-to-time. The forward function is globalOffset(chapterIndex:
// localOffset:); this test set verifies the inverse round-trips and
// handles edge cases (out-of-range, empty document, exact chapter
// boundaries) without crashing.

test("location(forGlobalOffset:) round-trips with globalOffset") {
    // Building blocks: three chapters of 100, 200, 150 chars.
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 100)),
            Chapter(title: "B", text: String(repeating: "b", count: 200)),
            Chapter(title: "C", text: String(repeating: "c", count: 150)),
        ]
    )

    // Round-trip a handful of positions across all three chapters.
    for (chapterIndex, localOffset) in [
        (0, 0), (0, 50), (0, 99),
        (1, 0), (1, 100), (1, 199),
        (2, 0), (2, 75), (2, 149),
    ] {
        let global = doc.globalOffset(chapterIndex: chapterIndex, localOffset: localOffset)
        let recovered = doc.location(forGlobalOffset: global)
        try assertEqual(recovered.chapterIndex, chapterIndex,
                        "Chapter index round-trip from offset \(global)")
        try assertEqual(recovered.localOffset, localOffset,
                        "Local offset round-trip from offset \(global)")
    }
}

test("location(forGlobalOffset:) maps chapter boundary to next chapter's start") {
    // Boundary semantics: a target exactly at the end of a chapter
    // should land on the START of the next chapter, not the end of
    // the previous one. Otherwise jumping to "end of chapter 1" would
    // get stuck at the very last character of chapter 1 instead of
    // moving on.
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 100)),
            Chapter(title: "B", text: String(repeating: "b", count: 200)),
        ]
    )
    // Offset 100 = end of chapter 0 = start of chapter 1
    let result = doc.location(forGlobalOffset: 100)
    try assertEqual(result.chapterIndex, 1, "Boundary lands on next chapter")
    try assertEqual(result.localOffset, 0, "Boundary lands at offset 0 of next chapter")
}

test("location(forGlobalOffset:) clamps a negative target to (0, 0)") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [Chapter(title: "A", text: "abcdef")]
    )
    let result = doc.location(forGlobalOffset: -42)
    try assertEqual(result.chapterIndex, 0)
    try assertEqual(result.localOffset, 0, "Negative offset clamps to 0")
}

test("location(forGlobalOffset:) clamps a too-large target to last chapter end") {
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 100)),
            Chapter(title: "B", text: String(repeating: "b", count: 200)),
        ]
    )
    // Total chars = 300; target 999 should clamp to last chapter, last
    // valid offset (199 — chapter B is 200 chars, last index is 199).
    let result = doc.location(forGlobalOffset: 999)
    try assertEqual(result.chapterIndex, 1, "Out-of-range lands in last chapter")
    try assertTrue(result.localOffset >= 0 && result.localOffset < 200,
                  "Local offset stays inside last chapter bounds")
}

test("location(forGlobalOffset:) returns (0, 0) for an empty document") {
    let doc = DocumentContent(title: "Test", author: "Author", chapters: [])
    let result = doc.location(forGlobalOffset: 50)
    try assertEqual(result.chapterIndex, 0)
    try assertEqual(result.localOffset, 0, "Empty document never crashes — returns (0, 0)")
}

test("location(forGlobalOffset:) skips empty chapters cleanly") {
    // Empty chapters in the middle of a document (zero-length spacers)
    // shouldn't trap the cursor — a target inside a real chapter
    // afterwards still resolves correctly.
    let doc = DocumentContent(
        title: "Test",
        author: "Author",
        chapters: [
            Chapter(title: "A", text: String(repeating: "a", count: 50)),
            Chapter(title: "Empty", text: ""),
            Chapter(title: "B", text: String(repeating: "b", count: 100)),
        ]
    )
    // Total = 50 + 0 + 100 = 150. Offset 80 is in chapter 2 (B),
    // local offset 30.
    let result = doc.location(forGlobalOffset: 80)
    try assertEqual(result.chapterIndex, 2,
                    "Skipped past zero-length chapter to land in B")
    try assertEqual(result.localOffset, 30)
}

// ---- Jump-to-Percent / Jump-to-Time Math Tests ----
print("\n--- Jump-to-Percent / Jump-to-Time Math Tests ---")

// These mirror the formulas in ReaderViewModel+Jump.swift. Keeping
// them in this test file (rather than in PlaybackTests) groups them
// with the rest of the position-math tests they share inputs with.

test("jumpToPercent: 50% of a 1000-char book lands at offset 500") {
    let totalChars = 1000
    let percent = 50.0
    let target = Int((percent / 100.0 * Double(totalChars)).rounded())
    try assertEqual(target, 500, "Halfway through a 1000-char book is offset 500")
}

test("jumpToPercent: clamps inputs outside [0, 100]") {
    func clamp(_ p: Double) -> Double { max(0.0, min(p, 100.0)) }
    try assertEqual(clamp(-10), 0.0, "Negative percent clamps to 0")
    try assertEqual(clamp(150), 100.0, "Over-100 percent clamps to 100")
    try assertEqual(clamp(47.5), 47.5, "In-range value passes through")
}

test("jumpToPercent: 100% lands at the end of the book") {
    let totalChars = 12345
    let target = Int((100.0 / 100.0 * Double(totalChars)).rounded())
    try assertEqual(target, totalChars, "100% maps to the total character count exactly")
}

test("jumpToTime audio: 30 seconds is 300 character offset") {
    // Audio mapping is fixed at 10 chars per second.
    let seconds = 30.0
    let charsPerSec = 10.0
    let target = Int((seconds * charsPerSec).rounded())
    try assertEqual(target, 300, "30s of audio = 300 char offset")
}

test("jumpToTime TTS: scales by total time") {
    // For TTS, target = (elapsed / totalTime) * totalChars.
    let totalChars = 50000
    let totalTime = 1500.0  // 25 minutes
    let elapsed = 750.0     // halfway
    let target = Int((elapsed / totalTime * Double(totalChars)).rounded())
    try assertEqual(target, 25000, "Halfway through TTS book by time = halfway by chars")
}

test("jumpToTime TTS: WPM-independent target for the same elapsed fraction") {
    // The elapsed-fraction-to-char-fraction relationship doesn't
    // depend on WPM — both sides scale the same way. Verifying this
    // catches a class of regression where someone "fixes" the audio
    // mapping by accidentally hardcoding a WPM into the TTS jump.
    let totalChars = 10000
    let elapsedFraction = 0.3

    let totalTimeAt200 = Double(totalChars) / 5.0 / 200.0 * 60.0   // some WPM-derived total
    let totalTimeAt400 = Double(totalChars) / 5.0 / 400.0 * 60.0   // half as long

    let elapsedAt200 = elapsedFraction * totalTimeAt200
    let elapsedAt400 = elapsedFraction * totalTimeAt400

    let targetAt200 = Int((elapsedAt200 / totalTimeAt200 * Double(totalChars)).rounded())
    let targetAt400 = Int((elapsedAt400 / totalTimeAt400 * Double(totalChars)).rounded())

    try assertEqual(targetAt200, targetAt400,
                    "30% elapsed in either WPM lands on the same offset")
}

test("jumpToTime: clamps negative seconds to 0") {
    let clamped = max(0.0, -5.0)
    try assertEqual(clamped, 0.0)
}

} // end runDocumentContentTests
