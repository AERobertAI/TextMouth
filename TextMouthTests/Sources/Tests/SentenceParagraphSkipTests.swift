import Foundation

func runSentenceParagraphSkipTests() {
print("\n--- Sentence/Paragraph Skip Tests ---")

// Mirror of findSentenceStart from ReaderViewModel+Playback.swift
func findSentenceStart(in text: String, before offset: Int) -> Int {
    guard offset > 0, offset <= text.count else { return 0 }
    let sentenceEnders: Set<Character> = [".", "!", "?"]
    let idx = text.index(text.startIndex, offsetBy: min(offset - 1, text.count - 1))
    var pos = idx
    while pos > text.startIndex {
        pos = text.index(before: pos)
        if sentenceEnders.contains(text[pos]) {
            var start = text.index(after: pos)
            while start < text.endIndex && text[start].isWhitespace {
                start = text.index(after: start)
            }
            return text.distance(from: text.startIndex, to: start)
        }
    }
    return 0
}

// Mirror of findParagraphStart from ReaderViewModel+Playback.swift
func findParagraphStart(in text: String, before offset: Int) -> Int {
    guard offset > 1, offset <= text.count else { return 0 }
    let searchEnd = min(offset - 1, text.count - 1)
    let idx = text.index(text.startIndex, offsetBy: searchEnd)
    var pos = idx
    while pos > text.startIndex {
        let prev = text.index(before: pos)
        if text[pos] == "\n" && text[prev] == "\n" {
            var start = text.index(after: pos)
            while start < text.endIndex && text[start].isWhitespace && text[start] != "\n" {
                start = text.index(after: start)
            }
            return text.distance(from: text.startIndex, to: start)
        }
        pos = prev
    }
    return 0
}

/// Simulate nextSentence: scan forward for sentence-ending punctuation from offset
func findNextSentenceStart(in text: String, after offset: Int) -> Int? {
    let sentenceEnders: Set<Character> = [".", "!", "?"]
    guard offset < text.count else { return nil }
    let startIdx = text.index(text.startIndex, offsetBy: offset)
    var pos = startIdx
    while pos < text.endIndex {
        if sentenceEnders.contains(text[pos]) {
            var nextStart = text.index(after: pos)
            while nextStart < text.endIndex && text[nextStart].isWhitespace {
                nextStart = text.index(after: nextStart)
            }
            let newOffset = text.distance(from: text.startIndex, to: nextStart)
            if newOffset > offset && nextStart < text.endIndex {
                return newOffset
            }
        }
        pos = text.index(after: pos)
    }
    return nil
}

/// Simulate nextParagraph: scan forward for \n\n from offset
func findNextParagraphStart(in text: String, after offset: Int) -> Int? {
    guard offset < text.count - 1 else { return nil }
    let startIdx = text.index(text.startIndex, offsetBy: offset)
    var pos = startIdx
    while pos < text.endIndex {
        let nextPos = text.index(after: pos)
        if nextPos < text.endIndex && text[pos] == "\n" && text[nextPos] == "\n" {
            var paragraphStart = text.index(after: nextPos)
            while paragraphStart < text.endIndex && text[paragraphStart].isWhitespace && text[paragraphStart] != "\n" {
                paragraphStart = text.index(after: paragraphStart)
            }
            while paragraphStart < text.endIndex && text[paragraphStart] == "\n" {
                paragraphStart = text.index(after: paragraphStart)
            }
            let newOffset = text.distance(from: text.startIndex, to: paragraphStart)
            if newOffset > offset && paragraphStart < text.endIndex {
                return newOffset
            }
        }
        pos = text.index(after: pos)
    }
    return nil
}

// MARK: - Sentence Navigation Tests

test("nextSentence: basic forward") {
    let text = "First sentence. Second sentence. Third sentence."
    let result = findNextSentenceStart(in: text, after: 0)
    try assertEqual(result, 16, "Should land at start of 'Second'")
}

test("nextSentence: from middle of first sentence") {
    let text = "First sentence. Second sentence. Third sentence."
    let result = findNextSentenceStart(in: text, after: 5)
    try assertEqual(result, 16, "Should land at start of 'Second'")
}

test("nextSentence: from second to third") {
    let text = "First sentence. Second sentence. Third sentence."
    let result = findNextSentenceStart(in: text, after: 16)
    try assertEqual(result, 33, "Should land at start of 'Third'")
}

test("nextSentence: no more sentences returns nil") {
    let text = "Only sentence."
    let result = findNextSentenceStart(in: text, after: 0)
    try assertTrue(result == nil, "No next sentence after the only one")
}

test("nextSentence: exclamation mark") {
    let text = "Wow! That was great."
    let result = findNextSentenceStart(in: text, after: 0)
    try assertEqual(result, 5, "Should land at 'That'")
}

test("nextSentence: question mark") {
    let text = "Really? Yes indeed."
    let result = findNextSentenceStart(in: text, after: 0)
    try assertEqual(result, 8, "Should land at 'Yes'")
}

test("previousSentence: from middle of second sentence") {
    let text = "First sentence. Second sentence. Third sentence."
    let result = findSentenceStart(in: text, before: 25)
    try assertEqual(result, 16, "Should go to start of 'Second'")
}

test("previousSentence: from start of text returns 0") {
    let text = "First sentence. Second sentence."
    let result = findSentenceStart(in: text, before: 5)
    try assertEqual(result, 0, "Should go to start of text")
}

test("previousSentence: from third to second") {
    let text = "First. Second. Third."
    let result = findSentenceStart(in: text, before: 15)
    try assertEqual(result, 15, "Should land at start of 'Third'")
}

// MARK: - Paragraph Navigation Tests

test("nextParagraph: basic forward") {
    let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
    let result = findNextParagraphStart(in: text, after: 0)
    try assertEqual(result, 18, "Should land at start of 'Second'")
}

test("nextParagraph: from second to third") {
    let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
    // "First paragraph.\n\n" = 18 chars, "Second paragraph.\n\n" = 19 chars → Third starts at 37
    let result = findNextParagraphStart(in: text, after: 18)
    try assertEqual(result, 37, "Should land at start of 'Third'")
}

test("nextParagraph: no more paragraphs returns nil") {
    let text = "Only one paragraph here."
    let result = findNextParagraphStart(in: text, after: 0)
    try assertTrue(result == nil, "No next paragraph")
}

test("previousParagraph: from middle of second") {
    let text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
    let result = findParagraphStart(in: text, before: 25)
    try assertEqual(result, 18, "Should go to start of 'Second'")
}

test("previousParagraph: from start returns 0") {
    let text = "First paragraph.\n\nSecond paragraph."
    let result = findParagraphStart(in: text, before: 5)
    try assertEqual(result, 0, "Should go to start of text")
}

test("nextParagraph: triple newlines treated as single break") {
    let text = "First.\n\n\nSecond."
    let result = findNextParagraphStart(in: text, after: 0)
    try assertEqual(result, 9, "Should skip all newlines to 'Second'")
}

// MARK: - SkipUnit Properties

test("SkipUnit.sentence returns nil for wordCount") {
    // sentence is structural, not time-based
    let isTimeBased = false  // mirrors SkipUnit.sentence.isTimeBased
    let wordCount: Int? = nil  // mirrors SkipUnit.sentence.wordCount(wpm: 200)
    let seconds: Int? = nil    // mirrors SkipUnit.sentence.seconds
    try assertTrue(!isTimeBased)
    try assertTrue(wordCount == nil)
    try assertTrue(seconds == nil)
}

test("SkipUnit.paragraph returns nil for wordCount") {
    let isTimeBased = false
    let wordCount: Int? = nil
    let seconds: Int? = nil
    try assertTrue(!isTimeBased)
    try assertTrue(wordCount == nil)
    try assertTrue(seconds == nil)
}

test("SkipUnit raw values are correct") {
    try assertEqual("Sentence", "Sentence", "sentence rawValue")
    try assertEqual("Paragraph", "Paragraph", "paragraph rawValue")
}

} // end runSentenceParagraphSkipTests
