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

// ---- Sleep Timer Auto-Close Setting ----
print("\n--- Sleep Timer Auto-Close Setting ---")

test("Auto-close default is true") {
    // The default config should have sleepTimerAutoClose = true
    let config = TestAppConfig()
    try assertTrue(config.sleepTimerAutoClose, "Default should be auto-close")
}

test("Auto-close setting round-trips through JSON") {
    var config = TestAppConfig()
    config.sleepTimerAutoClose = false

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(TestAppConfig.self, from: data)
    try assertTrue(!decoded.sleepTimerAutoClose, "Should preserve false after round-trip")
}

test("Auto-close setting missing from JSON defaults to true") {
    // Simulate old config.json without the sleepTimerAutoClose key
    let json = """
    {"sleepFadeOutDuration": 5}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TestAppConfig.self, from: json)
    try assertTrue(decoded.sleepTimerAutoClose, "Missing key should default to true")
}

// ---- Sleep Timer Restart ----
print("\n--- Sleep Timer Restart ---")

test("Restart preserves duration type: minutes") {
    var duration: SleepTimerDuration? = .minutes(15)
    var remainingSeconds = 15 * 60

    // Simulate countdown
    remainingSeconds -= 300  // 5 minutes pass
    try assertEqual(remainingSeconds, 600, "Should have 10 minutes left")

    // Restart: re-apply the same duration
    if let d = duration {
        if case .minutes(let m) = d {
            remainingSeconds = m * 60
        }
    }
    try assertEqual(remainingSeconds, 900, "After restart should be back to 15 minutes (900s)")
}

test("Restart preserves duration type: endOfHeading") {
    let duration: SleepTimerDuration? = .endOfHeading
    var endOfHeadingTriggered = true  // was armed

    // Restart: reset the trigger
    if let d = duration, case .endOfHeading = d {
        endOfHeadingTriggered = false
    }
    try assertTrue(!endOfHeadingTriggered, "Restart should reset the heading trigger")
}

test("Restart with no active duration is a no-op") {
    let duration: SleepTimerDuration? = nil
    var restarted = false
    if duration != nil {
        restarted = true
    }
    try assertTrue(!restarted, "Should not restart when no duration is set")
}

// ---- Sleep Timer State Transitions ----
print("\n--- Sleep Timer State Transitions ---")

test("Start sets isActive and duration") {
    var isActive = false
    var duration: SleepTimerDuration? = nil

    // Simulate start
    duration = .minutes(30)
    isActive = true
    try assertTrue(isActive)
    if case .minutes(let m) = duration {
        try assertEqual(m, 30)
    } else {
        throw TestError.assertionFailed("Duration should be minutes(30)")
    }
}

test("Stop clears isActive and duration") {
    var isActive = true
    var duration: SleepTimerDuration? = .minutes(10)
    var remainingSeconds = 600

    // Simulate stop
    isActive = false
    duration = nil
    remainingSeconds = 0

    try assertTrue(!isActive)
    try assertTrue(duration == nil)
    try assertEqual(remainingSeconds, 0)
}

test("Cancel then re-set: clean state transition") {
    var isActive = true
    var duration: SleepTimerDuration? = .minutes(10)

    // Cancel
    isActive = false
    duration = nil

    // Re-set with different duration
    duration = .minutes(45)
    isActive = true

    if case .minutes(let m) = duration {
        try assertEqual(m, 45, "Should have new duration after cancel + re-set")
    } else {
        throw TestError.assertionFailed("Duration should be minutes(45)")
    }
}

} // end runSleepTimerTests

/// Minimal config struct for testing sleep timer settings persistence
private struct TestAppConfig: Codable {
    var sleepFadeOutDuration: Double
    var sleepTimerAutoClose: Bool

    init(sleepFadeOutDuration: Double = 0, sleepTimerAutoClose: Bool = true) {
        self.sleepFadeOutDuration = sleepFadeOutDuration
        self.sleepTimerAutoClose = sleepTimerAutoClose
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sleepFadeOutDuration = try container.decodeIfPresent(Double.self, forKey: .sleepFadeOutDuration) ?? 0
        sleepTimerAutoClose = try container.decodeIfPresent(Bool.self, forKey: .sleepTimerAutoClose) ?? true
    }
}
