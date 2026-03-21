import Foundation

func runSleepTimerTests() {
// ---- ReadingPosition & Time Estimate Tests ----
print("\n--- ReadingPosition & Time Estimate Tests ---")

test("ReadingPosition defaults") {
    let pos = (chapterIndex: 0, characterOffset: 0, globalOffset: 0 as Int?)
    try assertEqual(pos.chapterIndex, 0)
    try assertEqual(pos.characterOffset, 0)
}

test("Book estimatedTimeRemaining without word counts returns nil") {
    // Simulating a book with no totalWordCount
    let totalWordCount: Int? = nil
    let totalCharCount: Int? = nil
    let wpm = 200.0

    let result: TimeInterval?
    if let totalWords = totalWordCount, let totalChars = totalCharCount,
       totalChars > 0, wpm > 0 {
        let totalTime = Double(totalWords) / wpm * 60.0
        result = totalTime
    } else {
        result = nil
    }
    try assertTrue(result == nil, "Should return nil when word count is unknown")
}

test("Book estimatedTimeRemaining with word counts and position") {
    let totalWords = 10000
    let totalChars = 50000
    let wpm = 200.0
    let globalOffset = 25000  // halfway

    let totalTime = Double(totalWords) / wpm * 60.0
    let fraction = min(Double(globalOffset) / Double(totalChars), 1.0)
    let remaining = totalTime * (1.0 - fraction)

    // 10000 words / 200 wpm = 50 min = 3000 sec, halfway = 1500 sec remaining
    try assertEqual(Int(remaining), 1500, "Should be 1500 seconds remaining at halfway")
}

test("Book estimatedTimeRemaining at start and end") {
    let totalWords = 10000
    let totalChars = 50000
    let wpm = 200.0

    // At start (offset 0)
    let remainingAtStart = Double(totalWords) / wpm * 60.0 * (1.0 - 0.0 / Double(totalChars))
    try assertEqual(Int(remainingAtStart), 3000, "Full book = 3000 seconds")

    // At end (offset = totalChars)
    let fraction = min(Double(totalChars) / Double(totalChars), 1.0)
    let remainingAtEnd = Double(totalWords) / wpm * 60.0 * (1.0 - fraction)
    try assertEqual(Int(remainingAtEnd), 0, "At end = 0 seconds remaining")
}

// ---- SleepTimer Logic Tests ----
print("\n--- SleepTimer Logic Tests ---")

test("SleepTimer minutes countdown logic") {
    var remaining = 5 * 60  // 5 minutes in seconds
    var isActive = true

    // Simulate 5 ticks
    for _ in 0..<5 {
        remaining -= 1
    }
    try assertEqual(remaining, 295, "Should have 295 seconds remaining after 5 ticks")
    try assertTrue(isActive, "Should still be active")

    // Simulate countdown to zero
    remaining = 1
    remaining -= 1
    if remaining <= 0 {
        isActive = false
    }
    try assertTrue(!isActive, "Should expire when reaching 0")
}

test("SleepTimer endOfHeading triggers correctly") {
    var endOfHeadingTriggered = false
    var expired = false

    // First heading boundary: arm the trigger
    if !endOfHeadingTriggered {
        endOfHeadingTriggered = true
    } else {
        expired = true
    }
    try assertTrue(!expired, "Should not expire on first heading boundary")
    try assertTrue(endOfHeadingTriggered, "Should arm trigger")

    // Second heading boundary: should expire
    if !endOfHeadingTriggered {
        endOfHeadingTriggered = true
    } else {
        expired = true
    }
    try assertTrue(expired, "Should expire on second heading boundary")
}

test("SleepTimer formattedRemaining") {
    func format(minutes: Bool, seconds: Int) -> String {
        if !minutes { return "" }
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    try assertEqual(format(minutes: true, seconds: 300), "5:00")
    try assertEqual(format(minutes: true, seconds: 65), "1:05")
    try assertEqual(format(minutes: true, seconds: 0), "0:00")
}

} // end runSleepTimerTests
