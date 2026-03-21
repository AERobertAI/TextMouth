import Foundation

func runPlaybackTests() {
// ---- NowPlaying Service Logic Tests ----
print("\n--- NowPlaying Service Logic Tests ---")

test("NowPlaying info format") {
    // Simulate building now playing info
    let title = "Alice in Wonderland"
    let author = "Lewis Carroll"
    let isPlaying = true

    var info = [String: Any]()
    info["title"] = title
    info["artist"] = author
    info["playbackRate"] = isPlaying ? 1.0 : 0.0

    try assertEqual(info["title"] as? String, "Alice in Wonderland")
    try assertEqual(info["artist"] as? String, "Lewis Carroll")
    try assertEqual(info["playbackRate"] as? Double, 1.0)
}

test("NowPlaying clear sets nil") {
    var info: [String: Any]? = ["title": "Test"]
    info = nil
    try assertTrue(info == nil, "Should be nil after clear")
}

// ---- NowPlaying Remote Command Separation Tests ----
print("\n--- NowPlaying Remote Command Separation Tests ---")

// Simulates the NowPlayingService's play/pause/toggle separation and suppress logic.
// The actual service uses MPRemoteCommandCenter which can't be unit tested,
// so we test the logic pattern directly.

test("Play command only plays, does not toggle") {
    // Simulate the separated command handlers
    var isPlaying = false
    var playCallCount = 0
    var pauseCallCount = 0

    let onPlay = { playCallCount += 1; isPlaying = true }
    let onPause = { pauseCallCount += 1; isPlaying = false }

    // Start paused, receive play command
    onPlay()
    try assertTrue(isPlaying)
    try assertEqual(playCallCount, 1)

    // Already playing, receive another play command — should not toggle off
    onPlay()
    try assertTrue(isPlaying, "Play should keep playing, not toggle to paused")
    try assertEqual(playCallCount, 2)
    try assertEqual(pauseCallCount, 0, "Pause should never have been called")
}

test("Pause command only pauses, does not toggle") {
    var isPlaying = true
    var pauseCallCount = 0

    let onPause = { pauseCallCount += 1; isPlaying = false }

    // Playing, receive pause
    onPause()
    try assertTrue(!isPlaying)
    try assertEqual(pauseCallCount, 1)

    // Already paused, receive another pause — should not toggle to play
    onPause()
    try assertTrue(!isPlaying, "Pause should keep paused, not toggle to playing")
    try assertEqual(pauseCallCount, 2)
}

test("Suppress flag blocks next play command after device change") {
    var suppressNextPlay = false
    var playFired = false

    func simulateDeviceChange() {
        suppressNextPlay = true
    }

    func handlePlayCommand() {
        if suppressNextPlay {
            suppressNextPlay = false
            return
        }
        playFired = true
    }

    // Device changes — suppress flag is set
    simulateDeviceChange()
    try assertTrue(suppressNextPlay)

    // System sends play command — should be suppressed
    handlePlayCommand()
    try assertTrue(!playFired, "Play should be suppressed after device change")
    try assertTrue(!suppressNextPlay, "Suppress flag should be cleared after use")

    // Next deliberate play should work
    handlePlayCommand()
    try assertTrue(playFired, "Second play should not be suppressed")
}

test("Toggle command clears suppress flag") {
    var suppressNextPlay = true
    var toggleCount = 0

    func handleToggleCommand() {
        suppressNextPlay = false
        toggleCount += 1
    }

    // User presses media key (toggle) — should clear suppress and work
    handleToggleCommand()
    try assertTrue(!suppressNextPlay, "Toggle should clear suppress flag")
    try assertEqual(toggleCount, 1)
}

test("Device change pauses then suppresses play") {
    var isPlaying = true
    var suppressNextPlay = false

    func onPause() { isPlaying = false }

    func simulateDeviceChange() {
        suppressNextPlay = true
        onPause()
    }

    func handlePlayCommand() {
        if suppressNextPlay {
            suppressNextPlay = false
            return
        }
        isPlaying = true
    }

    // Simulate AirPods disconnect sequence:
    // 1. Device change triggers pause + suppress
    simulateDeviceChange()
    try assertTrue(!isPlaying, "Should be paused after device change")
    try assertTrue(suppressNextPlay)

    // 2. System sends play command to resume on new device — should be blocked
    handlePlayCommand()
    try assertTrue(!isPlaying, "Play should be suppressed, staying paused")

    // 3. User later deliberately presses play — should work
    handlePlayCommand()
    try assertTrue(isPlaying, "Manual play should work after suppress is cleared")
}

test("Multiple rapid device changes only need one suppress") {
    var suppressNextPlay = false
    var playCount = 0

    func simulateDeviceChange() {
        suppressNextPlay = true
    }

    func handlePlayCommand() {
        if suppressNextPlay {
            suppressNextPlay = false
            return
        }
        playCount += 1
    }

    // Rapid device switching
    simulateDeviceChange()
    simulateDeviceChange()  // Second change re-arms the flag

    // Only one play command comes in — should be suppressed
    handlePlayCommand()
    try assertEqual(playCount, 0, "Should still be suppressed")

    // Next play should work
    handlePlayCommand()
    try assertEqual(playCount, 1, "Should work after suppress cleared")
}

// ---- Speed Control Tests ----
print("\n--- Speed Control Tests ---")

test("Rate table interpolation for direct mode") {
    let rateTable: [(rate: Double, wpm: Double)] = [
        (0.0, 50), (0.1, 80), (0.2, 120), (0.3, 167), (0.4, 190),
        (0.5, 216), (0.6, 344), (0.7, 457), (0.8, 604), (0.9, 759), (1.0, 871),
    ]

    func rateForWPM(_ wpm: Double) -> Float {
        guard let first = rateTable.first, let last = rateTable.last else { return 0.5 }
        if wpm <= first.wpm { return Float(first.rate) }
        if wpm >= last.wpm { return Float(last.rate) }
        for i in 0..<(rateTable.count - 1) {
            let lo = rateTable[i]
            let hi = rateTable[i + 1]
            if wpm >= lo.wpm && wpm <= hi.wpm {
                let fraction = (wpm - lo.wpm) / (hi.wpm - lo.wpm)
                return Float(lo.rate + fraction * (hi.rate - lo.rate))
            }
        }
        return 0.5
    }

    // Below minimum
    let rateMin = rateForWPM(30)
    try assertEqual(rateMin, 0.0, "Below 50 WPM should return 0.0")

    // Above maximum
    let rateMax = rateForWPM(1000)
    try assertEqual(rateMax, 1.0, "Above 871 WPM should return 1.0")

    // At exact table entry
    let rate216 = rateForWPM(216)
    try assertEqual(rate216, 0.5, "216 WPM should return 0.5")

    // Interpolated value — between 216 (0.5) and 344 (0.6)
    let rateMid = rateForWPM(280)
    try assertTrue(rateMid > 0.5 && rateMid < 0.6, "280 WPM should interpolate between 0.5 and 0.6")
    print("    280 WPM -> rate \(rateMid)")
}

test("Speed clamping between min and max") {
    let minWPM = 50.0
    let maxWPM = 650.0

    func clamp(_ wpm: Double) -> Double {
        max(minWPM, min(wpm, maxWPM))
    }

    try assertEqual(clamp(200), 200, "Normal value unchanged")
    try assertEqual(clamp(0), 50, "Below min clamps to 50")
    try assertEqual(clamp(1000), 650, "Above max clamps to 650")
    try assertEqual(clamp(50), 50, "At min stays at min")
    try assertEqual(clamp(650), 650, "At max stays at max")
}

test("Audio engine speed ratio calculation") {
    let renderWPM = 457.0

    func engineRate(wpm: Double) -> Float {
        Float(max(0.25, min(wpm / renderWPM, 4.0)))
    }

    // At render speed — rate 1.0
    let rate1 = engineRate(wpm: 457)
    try assertTrue(abs(rate1 - 1.0) < 0.01, "At render WPM should be ~1.0")

    // At half render speed
    let rateHalf = engineRate(wpm: 228.5)
    try assertTrue(abs(rateHalf - 0.5) < 0.01, "At half render WPM should be ~0.5")

    // Below minimum clamp
    let rateMin = engineRate(wpm: 50)
    try assertTrue(rateMin >= 0.25, "Should not go below 0.25")

    // Above maximum clamp
    let rateMax = engineRate(wpm: 5000)
    try assertTrue(rateMax <= 4.0, "Should not exceed 4.0")
}

// ---- Generation Counter Pattern Tests ----
print("\n--- Generation Counter Pattern Tests ---")

test("Generation counter prevents stale callback execution") {
    var generation = 0
    var callbacksFired = 0

    func startOperation() -> Int {
        generation += 1
        return generation
    }

    func completeOperation(myGen: Int) {
        guard myGen == generation else { return }
        callbacksFired += 1
    }

    let gen1 = startOperation()
    let gen2 = startOperation()  // New operation invalidates gen1

    completeOperation(myGen: gen1)  // Stale — should not fire
    completeOperation(myGen: gen2)  // Current — should fire

    try assertEqual(callbacksFired, 1, "Only the current generation's callback should fire")
}

test("ignoreDirectFinishCount suppresses stale finish callbacks") {
    var ignoreCount = 0
    var finishedFired = false

    func stop() {
        ignoreCount += 1
    }

    func onDidFinish() {
        if ignoreCount > 0 {
            ignoreCount -= 1
            return
        }
        finishedFired = true
    }

    // Stop triggers a didFinish callback that should be ignored
    stop()
    onDidFinish()
    try assertTrue(!finishedFired, "Finish should be suppressed after stop")
    try assertEqual(ignoreCount, 0, "Count should be decremented")

    // Real finish should fire
    onDidFinish()
    try assertTrue(finishedFired, "Real finish should fire")
}

// ---- Playback Debounce Tests ----
print("\n--- Playback Debounce Tests ---")

test("Skip debounce rejects rapid-fire calls") {
    var lastSkipTime = Date.distantPast
    var skipCount = 0

    func skip() {
        let now = Date()
        guard now.timeIntervalSince(lastSkipTime) > 0.3 else { return }
        lastSkipTime = now
        skipCount += 1
    }

    skip()  // Should succeed
    skip()  // Should be debounced (same instant)
    skip()  // Should be debounced

    try assertEqual(skipCount, 1, "Only first skip should succeed within debounce window")
}

// ---- Rewind on Resume: Sentence Boundary ----
print("\n--- Rewind on Resume: Sentence Boundary ---")

/// Find the start of the current sentence by scanning backward for sentence-ending punctuation.
/// Mirrors ReaderViewModel.findSentenceStart(in:before:)
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

/// Find the start of the current paragraph by scanning backward for double newlines.
/// Mirrors ReaderViewModel.findParagraphStart(in:before:)
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

test("findSentenceStart: rewinds to after period") {
    let text = "First sentence. Second sentence. Third sentence."
    // Offset in the middle of "Third"
    let thirdStart = text.range(of: "Third")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: thirdStart) + 2 // "Th|ird"
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: thirdStart)
    try assertEqual(result, expected, "Should rewind to start of 'Third sentence.'")
}

test("findSentenceStart: rewinds to after exclamation mark") {
    let text = "Hello! How are you?"
    let howStart = text.range(of: "How")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: howStart) + 1
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: howStart)
    try assertEqual(result, expected)
}

test("findSentenceStart: rewinds to after question mark") {
    let text = "Why? Because reasons."
    let becauseStart = text.range(of: "Because")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: becauseStart) + 3
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: becauseStart)
    try assertEqual(result, expected)
}

test("findSentenceStart: returns 0 when no sentence boundary before offset") {
    let text = "Just one long sentence without any end"
    let result = findSentenceStart(in: text, before: 20)
    try assertEqual(result, 0, "Should return 0 (start of text)")
}

test("findSentenceStart: offset at 0 returns 0") {
    let text = "Hello world."
    let result = findSentenceStart(in: text, before: 0)
    try assertEqual(result, 0)
}

test("findSentenceStart: offset at start of first sentence returns 0") {
    let text = "First sentence. Second sentence."
    let result = findSentenceStart(in: text, before: 3) // "Fir|st"
    try assertEqual(result, 0, "No boundary before offset 3, should go to 0")
}

test("findSentenceStart: handles multiple spaces after period") {
    let text = "End.   Next part here."
    let nextStart = text.range(of: "Next")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: nextStart) + 2
    let result = findSentenceStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: nextStart)
    try assertEqual(result, expected, "Should skip whitespace after period")
}

print("\n--- Rewind on Resume: Paragraph Boundary ---")

test("findParagraphStart: rewinds to after double newline") {
    let text = "First paragraph.\n\nSecond paragraph here."
    let secondStart = text.range(of: "Second")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: secondStart) + 5
    let result = findParagraphStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: secondStart)
    try assertEqual(result, expected)
}

test("findParagraphStart: returns 0 when no paragraph boundary") {
    let text = "Just one paragraph with no double newlines at all"
    let result = findParagraphStart(in: text, before: 30)
    try assertEqual(result, 0)
}

test("findParagraphStart: single newline is not a paragraph boundary") {
    let text = "Line one\nLine two still same paragraph"
    let result = findParagraphStart(in: text, before: 20)
    try assertEqual(result, 0, "Single newline should not be treated as paragraph break")
}

test("findParagraphStart: handles multiple paragraphs, finds nearest") {
    let text = "Para one.\n\nPara two.\n\nPara three."
    let threeStart = text.range(of: "Para three")!.lowerBound
    let offset = text.distance(from: text.startIndex, to: threeStart) + 3
    let result = findParagraphStart(in: text, before: offset)
    let expected = text.distance(from: text.startIndex, to: threeStart)
    try assertEqual(result, expected, "Should rewind to start of nearest paragraph")
}

test("findParagraphStart: offset at 0 returns 0") {
    let text = "Hello\n\nWorld"
    let result = findParagraphStart(in: text, before: 0)
    try assertEqual(result, 0)
}

test("findParagraphStart: offset at 1 returns 0") {
    let text = "Hello\n\nWorld"
    let result = findParagraphStart(in: text, before: 1)
    try assertEqual(result, 0)
}

print("\n--- Rewind on Resume: RewindUnit Enum ---")

enum RewindUnit: String, CaseIterable, Codable {
    case none = "None"
    case sentence = "Sentence"
    case paragraph = "Paragraph"
    case heading = "Heading"
}

test("RewindUnit: all cases exist") {
    try assertEqual(RewindUnit.allCases.count, 4)
}

test("RewindUnit: raw values round-trip") {
    for unit in RewindUnit.allCases {
        let decoded = RewindUnit(rawValue: unit.rawValue)
        try assertTrue(decoded != nil, "Should decode \(unit.rawValue)")
        try assertTrue(decoded == unit)
    }
}

test("RewindUnit: none is default") {
    let unit = RewindUnit(rawValue: "None")
    try assertTrue(unit == RewindUnit.none)
}

// ---- Sleep Timer Fade-Out ----
print("\n--- Sleep Timer Fade-Out ---")

/// Minimal sleep timer for testing fade-out logic
class TestSleepTimer {
    var isActive = false
    var isFadingOut = false
    var fadeOutDuration: TimeInterval = 0
    var onTimerExpired: (() -> Void)?
    var onFadeStep: ((Float) -> Void)?
    var fadeSteps: [Float] = []

    func expire() {
        if fadeOutDuration > 0 {
            isFadingOut = true
            let totalSteps = max(1, Int(fadeOutDuration * 10))
            for step in 1...totalSteps {
                let volume = Float(max(0, 1.0 - Double(step) / Double(totalSteps)))
                fadeSteps.append(volume)
                onFadeStep?(volume)
            }
            isFadingOut = false
            isActive = false
            onTimerExpired?()
        } else {
            isActive = false
            onTimerExpired?()
        }
    }
}

test("Fade-out: 0 duration fires onTimerExpired immediately with no fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 0
    timer.isActive = true
    var expired = false
    timer.onTimerExpired = { expired = true }
    var fadeStepsCalled = 0
    timer.onFadeStep = { _ in fadeStepsCalled += 1 }

    timer.expire()
    try assertTrue(expired, "Should have called onTimerExpired")
    try assertEqual(fadeStepsCalled, 0, "No fade steps for 0 duration")
    try assertTrue(!timer.isActive)
}

test("Fade-out: 1 second duration produces 10 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 1.0
    timer.isActive = true
    var expired = false
    timer.onTimerExpired = { expired = true }

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 10)
    try assertTrue(expired, "Should have called onTimerExpired after fade")
    try assertTrue(!timer.isActive)
}

test("Fade-out: volume decreases monotonically to 0") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 2.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    // Check monotonically decreasing
    for i in 1..<timer.fadeSteps.count {
        try assertTrue(timer.fadeSteps[i] <= timer.fadeSteps[i - 1],
            "Volume should decrease: step \(i) = \(timer.fadeSteps[i]) should be <= step \(i-1) = \(timer.fadeSteps[i-1])")
    }
    // Last step should be 0
    try assertEqual(timer.fadeSteps.last!, Float(0.0), "Final volume should be 0")
}

test("Fade-out: 5 second duration produces 50 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 5.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 50)
}

test("Fade-out: 10 second duration produces 100 fade steps") {
    let timer = TestSleepTimer()
    timer.fadeOutDuration = 10.0
    timer.isActive = true
    timer.onTimerExpired = {}

    timer.expire()
    try assertEqual(timer.fadeSteps.count, 100)
    // First step should be close to 1.0 but less
    try assertTrue(timer.fadeSteps.first! > 0.0 && timer.fadeSteps.first! < 1.0)
}

} // end runPlaybackTests
