import Foundation

func runNavigationTests() {
// ---- Keyboard Shortcut Binding Management Tests ----
print("\n--- Keyboard Shortcut Binding Management Tests ---")

test("Adding binding to action removes it from other actions") {
    var bindings = ShortcutAction.defaultBindings

    // The 'k' binding currently belongs to togglePlayback
    let kBinding = KeyBinding(key: "k")
    try assertTrue(bindings[.togglePlayback]!.contains(kBinding), "K should be in togglePlayback initially")

    // Simulate moving K to skipForward (same logic as KeyboardShortcutManager.addBinding)
    for action in ShortcutAction.allCases where action != .skipForward {
        bindings[action]?.removeAll { $0 == kBinding }
    }
    if !(bindings[.skipForward]?.contains(kBinding) ?? false) {
        bindings[.skipForward]?.append(kBinding)
    }

    try assertTrue(!(bindings[.togglePlayback]?.contains(kBinding) ?? false), "K should be removed from togglePlayback")
    try assertTrue(bindings[.skipForward]?.contains(kBinding) ?? false, "K should be in skipForward")
    print("    Moved K from togglePlayback to skipForward successfully")
}

test("Removing all bindings from action leaves empty array") {
    var bindings = ShortcutAction.defaultBindings
    let action = ShortcutAction.whereAmI
    bindings[action] = []
    try assertEqual(bindings[action]!.count, 0, "Should have zero bindings")
    print("    Removed all bindings from Where Am I")
}

test("Maximum 3 bindings per action enforced conceptually") {
    // The UI caps at 3 - verify the data model supports it
    let bindings: [KeyBinding] = [
        KeyBinding(key: "w"),
        KeyBinding(key: "i"),
        KeyBinding(key: "space", command: true),
    ]
    try assertEqual(bindings.count, 3)
    // Don't add a 4th (UI prevents this)
    print("    3 bindings per action supported")
}

test("Modifier-only display order is Control, Option, Shift, Command") {
    let binding = KeyBinding(key: "a", command: true, option: true, shift: true, control: true)
    let display = binding.displayString
    let controlIdx = display.firstIndex(of: "\u{2303}")!
    let optionIdx = display.firstIndex(of: "\u{2325}")!
    let shiftIdx = display.firstIndex(of: "\u{21E7}")!
    let commandIdx = display.firstIndex(of: "\u{2318}")!
    try assertTrue(controlIdx < optionIdx, "Control should come before Option")
    try assertTrue(optionIdx < shiftIdx, "Option should come before Shift")
    try assertTrue(shiftIdx < commandIdx, "Shift should come before Command")
    print("    Modifier order: \(display)")
}

// ---- Chapter Navigation Tests ----
print("\n--- Chapter Navigation & Cross-Chapter Skip Tests ---")

/// Simulate the skipWords cross-chapter calculation from ReaderViewModel.
/// Returns (chapterIndex, characterOffset) after the skip.
func simulateSkipWords(
    chapters: [Chapter],
    currentChapter: Int,
    currentOffset: Int,
    wordCount: Int
) -> (chapter: Int, offset: Int) {
    let charDelta = wordCount * 5  // ~5 chars per word average
    var chapIdx = currentChapter
    var charOffset = currentOffset + charDelta

    // Handle cross-chapter navigation backward
    if charOffset < 0 {
        while charOffset < 0 && chapIdx > 0 {
            chapIdx -= 1
            charOffset += chapters[chapIdx].text.count
        }
        charOffset = max(0, charOffset)
    } else {
        // Handle cross-chapter navigation forward
        while chapIdx < chapters.count && charOffset >= chapters[chapIdx].text.count {
            charOffset -= chapters[chapIdx].text.count
            chapIdx += 1
        }
        if chapIdx >= chapters.count {
            chapIdx = chapters.count - 1
            charOffset = max(0, chapters[chapIdx].text.count - 1)
        }
    }

    return (chapIdx, charOffset)
}

/// Simulate chapter advance (what onUtteranceFinished does)
func nextNonEmptyChapter(after index: Int, chapters: [Chapter]) -> Int? {
    var nextIndex = index + 1
    while nextIndex < chapters.count && chapters[nextIndex].text.isEmpty {
        nextIndex += 1
    }
    return nextIndex < chapters.count ? nextIndex : nil
}

let testChapters = [
    Chapter(title: "Ch1", text: String(repeating: "a", count: 100)),  // 0: 100 chars
    Chapter(title: "Ch2", text: String(repeating: "b", count: 200)),  // 1: 200 chars
    Chapter(title: "Ch3", text: ""),                                   // 2: empty
    Chapter(title: "Ch4", text: String(repeating: "c", count: 150)),  // 3: 150 chars
    Chapter(title: "Ch5", text: String(repeating: "d", count: 300)),  // 4: 300 chars
]

test("Skip forward within same chapter") {
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 0, currentOffset: 10, wordCount: 5)
    try assertEqual(result.chapter, 0, "Should stay in chapter 0")
    try assertEqual(result.offset, 35, "Should advance by 25 chars (5 words * 5 chars)")
}

test("Skip forward across chapter boundary") {
    // At offset 80 in chapter 0 (100 chars), skip 10 words (50 chars) → crosses into chapter 1
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 0, currentOffset: 80, wordCount: 10)
    try assertEqual(result.chapter, 1, "Should advance to chapter 1")
    try assertEqual(result.offset, 30, "Should be 30 chars into chapter 1 (80+50-100=30)")
}

test("Skip forward across multiple chapters including empty") {
    // At offset 180 in chapter 1 (200 chars), skip 50 words (250 chars)
    // 200-180=20 left in ch1, 250-20=230 remaining, ch2 is empty (0), ch3 is 150 → 230-150=80, ch4 has 300
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 1, currentOffset: 180, wordCount: 50)
    try assertEqual(result.chapter, 4, "Should land in chapter 4 (skipping empty ch2)")
    try assertEqual(result.offset, 80, "Should be 80 chars into chapter 4")
}

test("Skip backward within same chapter") {
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 1, currentOffset: 100, wordCount: -5)
    try assertEqual(result.chapter, 1, "Should stay in chapter 1")
    try assertEqual(result.offset, 75, "Should go back 25 chars")
}

test("Skip backward across chapter boundary") {
    // At offset 10 in chapter 1, skip back 5 words (25 chars) → 10-25=-15 → goes to chapter 0 (100 chars) → 100-15=85
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 1, currentOffset: 10, wordCount: -5)
    try assertEqual(result.chapter, 0, "Should go back to chapter 0")
    try assertEqual(result.offset, 85, "Should be 85 chars into chapter 0")
}

test("Skip backward across multiple chapters") {
    // At offset 20 in chapter 4 (300 chars), skip back 100 words (500 chars)
    // 20-500=-480, ch3 has 150 → -480+150=-330, ch2 has 0 → -330, ch1 has 200 → -330+200=-130, ch0 has 100 → -130+100=-30 → clamped to 0
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 4, currentOffset: 20, wordCount: -100)
    try assertEqual(result.chapter, 0, "Should land in chapter 0")
    try assertEqual(result.offset, 0, "Should clamp to 0")
}

test("Skip backward from start of chapter goes to previous") {
    // At offset 0 in chapter 1, skip back 1 word (5 chars)
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 1, currentOffset: 0, wordCount: -1)
    try assertEqual(result.chapter, 0, "Should go to chapter 0")
    try assertEqual(result.offset, 95, "Should be near end of chapter 0")
}

test("Skip forward past end of book clamps to last chapter") {
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 4, currentOffset: 290, wordCount: 100)
    try assertEqual(result.chapter, 4, "Should stay in last chapter")
    try assertTrue(result.offset >= 0, "Offset should be non-negative")
}

test("Chapter advance skips empty chapters") {
    let next = nextNonEmptyChapter(after: 1, chapters: testChapters)
    try assertEqual(next, 3, "Should skip empty chapter 2 and land on chapter 3")
}

test("Chapter advance from last chapter returns nil") {
    let next = nextNonEmptyChapter(after: 4, chapters: testChapters)
    try assertTrue(next == nil, "Should return nil after last chapter")
}

test("Chapter advance from second-to-last with empty last") {
    let chapters = [
        Chapter(title: "Ch1", text: "hello"),
        Chapter(title: "Ch2", text: "world"),
        Chapter(title: "Ch3", text: ""),
    ]
    let next = nextNonEmptyChapter(after: 1, chapters: chapters)
    try assertTrue(next == nil, "Should return nil since ch3 is empty")
}

// Test generation-based stale callback prevention
test("Stale callback detection - generation counter logic") {
    var generation = 0

    // Simulate: playing chapter 5, callback queued
    let callbackGeneration = generation

    // User navigates → generation increments
    generation += 1

    // Stale callback arrives — should be ignored
    try assertTrue(callbackGeneration != generation, "Stale callback should detect generation mismatch")

    // New callback from correct chapter
    let newCallbackGeneration = generation
    try assertTrue(newCallbackGeneration == generation, "Current callback should match generation")
}

test("Cross-chapter skip then chapter-advance gives correct sequence") {
    // Simulate: at chapter 1 offset 180, skip backward to chapter 0
    let skipResult = simulateSkipWords(chapters: testChapters, currentChapter: 1, currentOffset: 180, wordCount: -40)
    try assertEqual(skipResult.chapter, 0, "Skip should land in chapter 0")

    // When chapter 0 finishes playing, advance should go to chapter 1 (not chapter 2)
    let nextChapter = nextNonEmptyChapter(after: skipResult.chapter, chapters: testChapters)
    try assertEqual(nextChapter, 1, "After chapter 0 finishes, should advance to chapter 1")
}

test("Skip backward from chapter 3 correctly handles empty chapter 2") {
    // At offset 10 in chapter 3 (150 chars), skip back 5 words (25 chars)
    // 10-25=-15, chapter 2 is empty (0 chars), skip it, chapter 1 has 200 → -15+200=185
    let result = simulateSkipWords(chapters: testChapters, currentChapter: 3, currentOffset: 10, wordCount: -5)
    // Note: the current algorithm goes chapIdx-1 and adds that chapter's length
    // ch2 has 0 chars → -15+0=-15, still negative, ch1 has 200 → -15+200=185
    try assertEqual(result.chapter, 1, "Should skip empty ch2 and land in ch1")
    try assertEqual(result.offset, 185, "Should be 185 chars into ch1")
}

// ---- Heading Navigation Tests ----
print("\n--- Heading Navigation Tests ---")

test("isCurrentHeading only marks the closest heading") {
    let headings = [
        Heading(level: 1, text: "H1", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "H2", chapterIndex: 0, characterOffset: 100),
        Heading(level: 2, text: "H3", chapterIndex: 0, characterOffset: 200),
    ]
    let currentChapter = 0
    let currentOffset = 150  // between H2 (100) and H3 (200)

    // Find the current heading (the closest one at or before position)
    let currentID = headings.last(where: {
        $0.chapterIndex < currentChapter ||
        ($0.chapterIndex == currentChapter && $0.characterOffset <= currentOffset)
    })?.id

    // Only H2 should be "current", not H1
    var currentCount = 0
    for heading in headings {
        if heading.id == currentID {
            currentCount += 1
        }
    }
    try assertEqual(currentCount, 1, "Only one heading should be marked as current")
    try assertEqual(currentID, headings[1].id, "H2 should be the current heading")
}

test("Next heading navigation") {
    let headings = [
        Heading(level: 1, text: "H1", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "H2", chapterIndex: 0, characterOffset: 500),
        Heading(level: 1, text: "H3", chapterIndex: 1, characterOffset: 0),
    ]

    // From chapter 0, offset 100
    let next = headings.first(where: {
        $0.chapterIndex > 0 ||
        ($0.chapterIndex == 0 && $0.characterOffset > 100)
    })
    try assertEqual(next?.text, "H2", "Next heading from 0:100 should be H2")

    // From chapter 0, offset 600
    let next2 = headings.first(where: {
        $0.chapterIndex > 0 ||
        ($0.chapterIndex == 0 && $0.characterOffset > 600)
    })
    try assertEqual(next2?.text, "H3", "Next heading from 0:600 should be H3")
}

test("Previous heading navigation with 10-char grace zone") {
    let headings = [
        Heading(level: 1, text: "H1", chapterIndex: 0, characterOffset: 0),
        Heading(level: 2, text: "H2", chapterIndex: 0, characterOffset: 500),
        Heading(level: 1, text: "H3", chapterIndex: 1, characterOffset: 0),
    ]

    let currentChapter0 = 0
    let currentOffset505 = 505

    // From chapter 0, offset 505 — H2 is at 500, within 10 chars, so "previous" should go to H1
    let prev = headings.last(where: {
        $0.chapterIndex < currentChapter0 ||
        ($0.chapterIndex == currentChapter0 && $0.characterOffset < currentOffset505 - 10)
    })
    try assertEqual(prev?.text, "H1", "Previous from 505 (10-char grace) should be H1")

    let currentChapter1 = 1
    let currentOffset100 = 100

    // From chapter 1, offset 100 — H3 is at ch1:0, within 10 chars? No, 100-10=90 > 0
    // So H3 (ch1:0) has offset < 90 → true. But H2 (ch0:500) also matches via chapterIndex < 1.
    // .last(where:) returns the LAST match in array order. H3 is last match.
    // The app uses the same logic and previousHeading returns the last match.
    let prev2 = headings.last(where: {
        $0.chapterIndex < currentChapter1 ||
        ($0.chapterIndex == currentChapter1 && $0.characterOffset < currentOffset100 - 10)
    })
    // H3 at ch1:0 has characterOffset 0 < 90, so it matches. It's last in array → result is H3.
    try assertEqual(prev2?.text, "H3", "Previous from ch1:100 should be H3 (it's at ch1:0)")
}

// ---- Skip Logic Edge Cases ----
print("\n--- Skip Logic Edge Cases ---")

test("Skip forward past end of all chapters clamps to last chapter") {
    let chapterTexts = [
        String(repeating: "a", count: 100),
        String(repeating: "b", count: 100),
    ]
    var chapIdx = 1
    var charOffset = 50 + 200  // 250, way past end

    while chapIdx < chapterTexts.count && charOffset >= chapterTexts[chapIdx].count {
        charOffset -= chapterTexts[chapIdx].count
        chapIdx += 1
    }
    if chapIdx >= chapterTexts.count {
        chapIdx = chapterTexts.count - 1
        charOffset = max(0, chapterTexts[chapIdx].count - 1)
    }

    try assertEqual(chapIdx, 1, "Should clamp to last chapter")
    try assertEqual(charOffset, 99, "Should clamp to end of last chapter")
}

test("Skip backward past start of all chapters clamps to 0") {
    let chapterTexts = [
        String(repeating: "a", count: 100),
        String(repeating: "b", count: 100),
    ]
    var chapIdx = 0
    var charOffset = -50  // before start

    while charOffset < 0 && chapIdx > 0 {
        chapIdx -= 1
        charOffset += chapterTexts[chapIdx].count
    }
    charOffset = max(0, charOffset)

    try assertEqual(chapIdx, 0)
    try assertEqual(charOffset, 0, "Should clamp to start")
}

test("Skip within same chapter preserves chapter index") {
    let chapterText = String(repeating: "a", count: 1000)
    let currentOffset = 500
    let charDelta = 100  // forward 100

    let newOffset = currentOffset + charDelta
    try assertTrue(newOffset >= 0 && newOffset < chapterText.count, "Should stay in same chapter")
    try assertEqual(newOffset, 600)
}

// ---- Word Boundary Snapping Tests ----
print("\n--- Word Boundary Snapping Tests ---")

test("Snap to word boundary finds start of word") {
    let text = "Hello world this is a test"
    let targetOffset = 7  // middle of "world"

    var idx = text.index(text.startIndex, offsetBy: targetOffset)
    while idx > text.startIndex && !text[text.index(before: idx)].isWhitespace {
        idx = text.index(before: idx)
    }
    let snappedOffset = text.distance(from: text.startIndex, to: idx)

    try assertEqual(snappedOffset, 6, "Should snap to start of 'world' at offset 6")
}

test("Snap at start of text stays at 0") {
    let _ = "Hello world"
    let targetOffset = 0

    // No need to snap — already at start
    try assertEqual(targetOffset, 0)
}

test("Snap at exact word boundary stays put") {
    let text = "Hello world"
    let targetOffset = 6  // start of "world"

    var idx = text.index(text.startIndex, offsetBy: targetOffset)
    while idx > text.startIndex && !text[text.index(before: idx)].isWhitespace {
        idx = text.index(before: idx)
    }
    let snappedOffset = text.distance(from: text.startIndex, to: idx)

    try assertEqual(snappedOffset, 6, "Should stay at word boundary")
}

// ---- Word Boundary Scanning Tests ----
print("\n--- Word Boundary Scanning Tests ---")

/// Mirror of ReaderViewModel.offsetAfterSkippingWords for testing
func offsetAfterSkippingWords(in text: String, from startOffset: Int, wordCount: Int) -> Int {
    guard !text.isEmpty else { return 0 }
    let clampedStart = max(0, min(startOffset, text.count))

    if wordCount > 0 {
        var idx = text.index(text.startIndex, offsetBy: clampedStart)
        var wordsFound = 0
        while idx < text.endIndex && !text[idx].isWhitespace { idx = text.index(after: idx) }
        while wordsFound < wordCount && idx < text.endIndex {
            while idx < text.endIndex && text[idx].isWhitespace { idx = text.index(after: idx) }
            if idx < text.endIndex { wordsFound += 1 }
            if wordsFound < wordCount {
                while idx < text.endIndex && !text[idx].isWhitespace { idx = text.index(after: idx) }
            }
        }
        return text.distance(from: text.startIndex, to: idx)
    } else {
        let targetWords = abs(wordCount)
        var idx = text.index(text.startIndex, offsetBy: clampedStart)
        var wordsFound = 0
        while wordsFound < targetWords && idx > text.startIndex {
            while idx > text.startIndex && text[text.index(before: idx)].isWhitespace { idx = text.index(before: idx) }
            while idx > text.startIndex && !text[text.index(before: idx)].isWhitespace { idx = text.index(before: idx) }
            wordsFound += 1
        }
        return text.distance(from: text.startIndex, to: idx)
    }
}

/// Mirror of ReaderViewModel.countWordsBetween for testing
func countWordsBetween(in text: String, from startOffset: Int, to endOffset: Int) -> Int {
    guard !text.isEmpty, startOffset < endOffset else { return 0 }
    let start = text.index(text.startIndex, offsetBy: max(0, min(startOffset, text.count)))
    let end = text.index(text.startIndex, offsetBy: max(0, min(endOffset, text.count)))
    guard start < end else { return 0 }
    var count = 0
    var inWhitespace = true
    var idx = start
    while idx < end {
        if text[idx].isWhitespace { inWhitespace = true }
        else if inWhitespace { count += 1; inWhitespace = false }
        idx = text.index(after: idx)
    }
    return count
}

test("Skip forward 1 word from start") {
    let text = "Hello world test"
    let result = offsetAfterSkippingWords(in: text, from: 0, wordCount: 1)
    try assertEqual(result, 6, "Should land at start of 'world'")
}

test("Skip forward 3 words from start") {
    let text = "one two three four five"
    let result = offsetAfterSkippingWords(in: text, from: 0, wordCount: 3)
    try assertEqual(result, 14, "Should land at start of 'four'")
}

test("Skip forward past end of text clamps") {
    let text = "Hello world"
    let result = offsetAfterSkippingWords(in: text, from: 0, wordCount: 10)
    try assertEqual(result, text.count, "Should reach end of text")
}

test("Skip backward 1 word") {
    let text = "Hello world test"
    let result = offsetAfterSkippingWords(in: text, from: 16, wordCount: -1)
    try assertEqual(result, 12, "Should land at start of 'test'")
}

test("Skip backward 2 words from middle") {
    let text = "one two three four five"
    // From offset 18 (start of 'five'), skip back 2 words
    let result = offsetAfterSkippingWords(in: text, from: 18, wordCount: -2)
    try assertEqual(result, 8, "Should land at start of 'three'")
}

test("Skip backward past start clamps to 0") {
    let text = "Hello world"
    let result = offsetAfterSkippingWords(in: text, from: 6, wordCount: -10)
    try assertEqual(result, 0, "Should clamp to start of text")
}

test("Skip forward from middle of word") {
    let text = "Hello world test"
    // From offset 3 (middle of "Hello"), skip 1 word → should go to "world"
    let result = offsetAfterSkippingWords(in: text, from: 3, wordCount: 1)
    try assertEqual(result, 6, "Should skip to start of 'world'")
}

test("Skip in empty text returns 0") {
    let result = offsetAfterSkippingWords(in: "", from: 0, wordCount: 5)
    try assertEqual(result, 0, "Empty text always returns 0")
}

test("countWordsBetween basic") {
    let text = "one two three four"
    let count = countWordsBetween(in: text, from: 0, to: 18)
    try assertEqual(count, 4, "Should count 4 words")
}

test("countWordsBetween partial range") {
    let text = "one two three four"
    // From offset 4 (start of 'two') to 13 (start of 'four')
    let count = countWordsBetween(in: text, from: 4, to: 14)
    try assertEqual(count, 2, "Should count 'two' and 'three'")
}

test("Skip forward with multiple spaces between words") {
    let text = "Hello   world   test"
    let result = offsetAfterSkippingWords(in: text, from: 0, wordCount: 1)
    try assertEqual(result, 8, "Should handle multiple spaces")
}

// ---- Time-Based Skip Consistency Tests ----
print("\n--- Time-Based Skip Consistency Tests ---")

/// Simulate skipByTime character delta calculation (mirrors ReaderViewModel.skipByTime)
func timeSkipCharDelta(seconds: Double, totalChars: Int, totalWordCount: Int, wpm: Double) -> Int {
    let totalTime = Double(totalWordCount) / wpm * 60.0
    guard totalTime > 0 else { return 0 }
    return Int(seconds / totalTime * Double(totalChars))
}

/// Simulate time remaining calculation (mirrors DocumentContent.estimatedTimeRemaining)
func timeRemaining(globalOffset: Int, totalChars: Int, totalWordCount: Int, wpm: Double) -> Double {
    guard wpm > 0, totalChars > 0 else { return 0 }
    let totalTime = Double(totalWordCount) / wpm * 60.0
    let remainingFraction = Double(max(totalChars - globalOffset, 0)) / Double(totalChars)
    return totalTime * remainingFraction
}

test("skipByTime: 15-second skip changes time display by exactly 15 seconds") {
    // Book with uniform word density (5 chars/word avg)
    let totalChars = 10000
    let totalWords = 2000
    let wpm = 200.0
    let startOffset = 5000

    let timeBefore = timeRemaining(globalOffset: startOffset, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)
    let charDelta = timeSkipCharDelta(seconds: 15.0, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)
    let timeAfter = timeRemaining(globalOffset: startOffset - charDelta, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)

    let displayedChange = timeAfter - timeBefore
    // Should be exactly 15 seconds (within floating point tolerance)
    try assertTrue(abs(displayedChange - 15.0) < 0.01, "Time change should be 15s, got \(displayedChange)")
}

test("skipByTime: 30-second skip is consistent regardless of position in book") {
    let totalChars = 50000
    let totalWords = 10000
    let wpm = 250.0

    // Skip from different positions — time change should always be 30 seconds
    let charDelta = timeSkipCharDelta(seconds: 30.0, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)

    for startOffset in stride(from: 5000, through: 40000, by: 5000) {
        let timeBefore = timeRemaining(globalOffset: startOffset, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)
        let timeAfter = timeRemaining(globalOffset: startOffset - charDelta, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)
        let change = timeAfter - timeBefore
        try assertTrue(abs(change - 30.0) < 0.01,
            "30s skip from offset \(startOffset): expected 30s change, got \(change)")
    }
}

test("skipByTime: forward and backward are symmetric") {
    let totalChars = 20000
    let totalWords = 4000
    let wpm = 200.0

    let fwdDelta = timeSkipCharDelta(seconds: 15.0, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)
    let bwdDelta = timeSkipCharDelta(seconds: -15.0, totalChars: totalChars, totalWordCount: totalWords, wpm: wpm)

    try assertEqual(fwdDelta, -bwdDelta, "Forward and backward deltas should be symmetric")
}

test("skipByTime: different WPM produces different char deltas") {
    let totalChars = 10000
    let totalWords = 2000

    let delta200 = timeSkipCharDelta(seconds: 15.0, totalChars: totalChars, totalWordCount: totalWords, wpm: 200.0)
    let delta400 = timeSkipCharDelta(seconds: 15.0, totalChars: totalChars, totalWordCount: totalWords, wpm: 400.0)

    // At higher WPM, total time is shorter, so 15 seconds is a larger fraction of the book
    try assertTrue(delta400 > delta200, "Higher WPM should skip more chars for same time delta")
}

} // end runNavigationTests
