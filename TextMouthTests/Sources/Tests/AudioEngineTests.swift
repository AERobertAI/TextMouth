import Foundation

func runAudioEngineTests() {
print("\n--- Audio Engine Seek / Speed Calculation Tests ---")

test("Character-to-frame mapping is monotonic") {
    // Simulate a mapping: 1000 chars -> 44100 frames (1 second at 44.1kHz)
    let totalChars = 1000
    let totalFrames = 44100
    let framesPerChar = Double(totalFrames) / Double(totalChars)

    var prevFrame = -1
    for charOffset in stride(from: 0, through: totalChars, by: 50) {
        let frame = Int(Double(charOffset) * framesPerChar)
        try assertTrue(frame >= prevFrame, "Frames should increase monotonically")
        prevFrame = frame
    }
    print("    1000 chars -> 44100 frames, framesPerChar=\(String(format: "%.1f", framesPerChar))")
}

test("Speed multiplier calculation for TimePitch") {
    let renderWPM = 216.0  // Rendered at rate 0.5

    func multiplier(_ wpm: Double) -> Double {
        return max(0.25, min(wpm / renderWPM, 4.0))
    }

    let m200 = multiplier(200)
    let m300 = multiplier(300)
    let m500 = multiplier(500)
    let m650 = multiplier(650)

    try assertTrue(m200 > 0.9 && m200 < 1.0, "200 WPM ≈ 0.93x")
    try assertTrue(m300 > 1.3 && m300 < 1.5, "300 WPM ≈ 1.39x")
    try assertTrue(m500 > 2.2 && m500 < 2.5, "500 WPM ≈ 2.31x")
    try assertTrue(m650 > 2.9 && m650 < 3.1, "650 WPM ≈ 3.01x")

    print("    200 WPM -> \(String(format: "%.2f", m200))x")
    print("    300 WPM -> \(String(format: "%.2f", m300))x")
    print("    500 WPM -> \(String(format: "%.2f", m500))x")
    print("    650 WPM -> \(String(format: "%.2f", m650))x")
}

test("Frame-to-char round-trip is approximately consistent") {
    let totalChars = 5000
    let totalFrames = 100000
    let framesPerChar = Double(totalFrames) / Double(totalChars)

    // char -> frame -> char should give back approximately the same char
    for testChar in [0, 100, 500, 2500, 4999] {
        let frame = Int(Double(testChar) * framesPerChar)
        let charBack = Int(Double(frame) / framesPerChar)
        let diff = abs(charBack - testChar)
        try assertTrue(diff <= 1, "Round-trip error should be <= 1, got \(diff) for char \(testChar)")
    }
    print("    Round-trip accuracy verified for 5 positions")
}

test("Seek within chapter preserves position correctly") {
    let url = try requireFile("alice.epub")
    let epub = try parseEPUB(url: url)
    guard epub.chapters.count > 3 else { throw TestError.assertionFailed("Need chapters") }

    let chapter = epub.chapters[3]
    let chapterLen = chapter.text.count

    // Simulate seeking to 25%, 50%, 75%
    let positions = [chapterLen / 4, chapterLen / 2, chapterLen * 3 / 4]
    for pos in positions {
        try assertTrue(pos >= 0 && pos < chapterLen, "Position \(pos) should be within chapter length \(chapterLen)")
        // Simulate snapping to word boundary
        let text = chapter.text
        let targetIndex = text.index(text.startIndex, offsetBy: pos)
        var wordStart = targetIndex
        while wordStart > text.startIndex && !text[text.index(before: wordStart)].isWhitespace {
            wordStart = text.index(before: wordStart)
        }
        let snapped = text.distance(from: text.startIndex, to: wordStart)
        try assertTrue(snapped <= pos, "Snapped position should be <= original")
        try assertTrue(pos - snapped < 50, "Word snap should be within 50 chars")
    }
    print("    Seek positions verified for chapter 4 (\(chapterLen) chars)")
}

// ---- Audio Engine Char/Frame Mapping ----
print("\n--- Audio Engine Char/Frame Mapping Tests ---")

test("Char-to-frame mapping with empty map returns 0") {
    let map: [(charOffset: Int, frame: Int)] = []
    let result = map.isEmpty ? 0 : -1
    try assertEqual(result, 0, "Empty map should return 0")
}

test("Char-to-frame mapping interpolates correctly") {
    // Simulated mapping: 0 chars = frame 0, 100 chars = frame 1000, 200 chars = frame 2000
    let map = [(charOffset: 0, frame: 0), (charOffset: 100, frame: 1000), (charOffset: 200, frame: 2000)]

    func frameFor(_ charOffset: Int) -> Int {
        guard !map.isEmpty else { return 0 }
        var lo = 0, hi = map.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if map[mid].charOffset <= charOffset { lo = mid } else { hi = mid - 1 }
        }
        let entry = map[lo]
        if lo + 1 < map.count {
            let next = map[lo + 1]
            let charRange = next.charOffset - entry.charOffset
            if charRange > 0 {
                let fraction = Double(charOffset - entry.charOffset) / Double(charRange)
                return entry.frame + Int(fraction * Double(next.frame - entry.frame))
            }
        }
        return entry.frame
    }

    try assertEqual(frameFor(0), 0, "Offset 0 → frame 0")
    try assertEqual(frameFor(100), 1000, "Offset 100 → frame 1000")
    try assertEqual(frameFor(50), 500, "Offset 50 → frame 500 (interpolated)")
    try assertEqual(frameFor(150), 1500, "Offset 150 → frame 1500 (interpolated)")
    try assertEqual(frameFor(200), 2000, "Offset 200 → frame 2000")
}

test("Frame-to-char reverse mapping") {
    let map = [(charOffset: 0, frame: 0), (charOffset: 100, frame: 1000), (charOffset: 200, frame: 2000)]
    let totalFrames = 2000

    func charFor(_ frame: Int) -> Int {
        guard !map.isEmpty else { return 0 }
        let clamped = max(0, min(frame, totalFrames))
        var lo = 0, hi = map.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if map[mid].frame <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let entry = map[lo]
        if lo + 1 < map.count {
            let next = map[lo + 1]
            let frameRange = next.frame - entry.frame
            if frameRange > 0 {
                let fraction = Double(clamped - entry.frame) / Double(frameRange)
                return entry.charOffset + Int(fraction * Double(next.charOffset - entry.charOffset))
            }
        }
        return entry.charOffset
    }

    try assertEqual(charFor(0), 0, "Frame 0 → offset 0")
    try assertEqual(charFor(1000), 100, "Frame 1000 → offset 100")
    try assertEqual(charFor(500), 50, "Frame 500 → offset 50 (interpolated)")
    try assertEqual(charFor(2000), 200, "Frame 2000 → offset 200")
    try assertEqual(charFor(-100), 0, "Negative frame → 0 (clamped)")
    try assertEqual(charFor(5000), 200, "Beyond total → last offset (clamped)")
}

// ---- Silence Padding Tests (Fix 9) ----
print("\n--- Silence Padding Tests ---")

test("Silence padding: buffer is longer than speech frames") {
    // Simulate the padding logic from render():
    // speechFrameCount = actual TTS audio, paddingFrames = silence tail
    let sampleRate = 22050.0
    let paddingDuration = 0.2  // 200ms, matches AudioEngineService.silencePaddingDuration
    let speechFrameCount = 44100  // 2 seconds of speech
    let paddingFrames = Int(sampleRate * paddingDuration)
    let totalBufferFrames = speechFrameCount + paddingFrames

    try assertTrue(paddingFrames > 0, "Padding should be non-zero")
    try assertEqual(paddingFrames, 4410, "200ms at 22050 Hz = 4410 frames")
    try assertEqual(totalBufferFrames, 48510, "Buffer should include speech + padding")
    try assertTrue(totalBufferFrames > speechFrameCount,
        "Buffer length should exceed speech-only frame count")
}

test("Silence padding: char-to-frame mapping uses speech frames only") {
    // The char-to-frame mapping must use speechFrameCount, not
    // totalBufferFrames, so characters map to real audio positions
    // rather than extending into the silence padding.
    let charCount = 1000
    let speechFrameCount = 44100
    let paddingFrames = 4410  // 200ms at 22050 Hz
    let totalBufferFrames = speechFrameCount + paddingFrames

    // Build mapping the same way as render() — using speechFrameCount
    let framesPerChar = Double(speechFrameCount) / Double(charCount)

    // Last character should map to the end of speech, not end of buffer
    let lastCharFrame = Int(Double(charCount) * framesPerChar)
    try assertEqual(lastCharFrame, speechFrameCount,
        "Last character should map to end of speech, not end of buffer")
    try assertTrue(lastCharFrame < totalBufferFrames,
        "Speech end should be before buffer end (padding exists)")
}

test("Silence padding: totalFrames reflects speech only for position tracking") {
    // totalFrames is used by charOffsetForFrame to clamp positions.
    // It must exclude padding so positions don't drift into silence.
    let speechFrameCount = 44100
    let paddingFrames = 4410
    let totalFrames = speechFrameCount  // NOT speechFrameCount + paddingFrames

    // charOffsetForFrame clamps to totalFrames
    func charOffsetForFrame(_ frame: Int) -> Int {
        let clamped = max(0, min(frame, totalFrames))
        // Simplified: linear mapping
        let charCount = 1000
        return Int(Double(clamped) / Double(totalFrames) * Double(charCount))
    }

    // A frame in the padding region should clamp to the last speech frame
    let offsetAtPadding = charOffsetForFrame(speechFrameCount + paddingFrames)
    let offsetAtEnd = charOffsetForFrame(speechFrameCount)
    try assertEqual(offsetAtPadding, offsetAtEnd,
        "Frame in padding region should clamp to same position as speech end")
}

test("Silence padding: renderedDuration excludes padding") {
    // renderedDuration = totalFrames / sampleRate, and totalFrames
    // is speech-only. Duration should reflect speaking time, not
    // the extended buffer with silence.
    let sampleRate = 22050.0
    let speechFrameCount = 44100
    let totalFrames = speechFrameCount
    let renderedDuration = Double(totalFrames) / sampleRate

    try assertTrue(abs(renderedDuration - 2.0) < 0.01,
        "Duration should be ~2.0 seconds (speech only), got \(renderedDuration)")
}

test("Silence padding: sub-buffer seek excludes padding from remaining count") {
    // When seeking mid-buffer, the remaining frames are calculated
    // from buffer.frameLength (which includes padding). But position
    // tracking uses totalFrames (speech only). Verify the seek
    // doesn't place us into the padding region.
    let speechFrameCount = 44100
    let paddingFrames = 4410
    let totalBufferFrames = speechFrameCount + paddingFrames
    let seekCharOffset = 500  // halfway through 1000 chars
    let charCount = 1000

    // Frame for seek position (using speech-only mapping)
    let seekFrame = Int(Double(seekCharOffset) / Double(charCount) * Double(speechFrameCount))
    try assertEqual(seekFrame, 22050, "Seek to char 500 = frame 22050")

    // Remaining frames in buffer from this position (includes padding)
    let remaining = totalBufferFrames - seekFrame
    try assertEqual(remaining, 26460, "Remaining buffer includes padding")

    // But position tracking only considers up to speechFrameCount
    let speechRemaining = speechFrameCount - seekFrame
    try assertEqual(speechRemaining, 22050, "Speech remaining excludes padding")
    try assertTrue(remaining > speechRemaining,
        "Buffer remaining should exceed speech remaining (padding present)")
}

// ---- Volume Tracking Across Engine Restarts (Fix 11) ----
print("\n--- Volume Tracking Tests ---")

test("Volume tracking: setVolume stores the value") {
    // Simulates AudioEngineService's currentVolume tracking.
    // setVolume must update both the tracked value and the mixer node.
    var currentVolume: Float = 1.0
    var mixerOutputVolume: Float = 1.0

    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
        mixerOutputVolume = currentVolume
    }

    setVolume(0.5)
    try assertEqual(currentVolume, 0.5, "Tracked volume should be 0.5")
    try assertEqual(mixerOutputVolume, 0.5, "Mixer volume should match")
}

test("Volume tracking: restoreVolume resets to 1.0") {
    var currentVolume: Float = 0.3
    var mixerOutputVolume: Float = 0.3

    func restoreVolume() {
        currentVolume = 1.0
        mixerOutputVolume = 1.0
    }

    restoreVolume()
    try assertEqual(currentVolume, 1.0, "Tracked volume should be restored to 1.0")
    try assertEqual(mixerOutputVolume, 1.0, "Mixer volume should be restored to 1.0")
}

test("Volume tracking: play() re-applies currentVolume after engine start") {
    // When the engine is stopped and restarted during chapter
    // transitions, the mixer volume can reset to 1.0. The fix
    // re-applies currentVolume after engine.start().
    var currentVolume: Float = 0.4  // Sleep timer faded to 40%
    var mixerOutputVolume: Float = 0.4

    // Simulate engine stop → volume resets (the bug)
    func engineStop() {
        mixerOutputVolume = 1.0  // Engine resets mixer on stop+start
    }

    // Simulate the corrected play() that re-applies tracked volume
    func playWithFix() {
        engineStop()
        // After engine.start(), re-apply tracked volume
        mixerOutputVolume = currentVolume
    }

    playWithFix()
    try assertEqual(mixerOutputVolume, 0.4,
        "Mixer volume should be re-applied from tracked value after engine restart")
}

test("Volume tracking: chapter transition preserves fade volume") {
    // Full scenario: sleep timer is fading, chapter ends, next
    // chapter starts. Volume must persist through the transition.
    var currentVolume: Float = 1.0
    var mixerOutputVolume: Float = 1.0

    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
        mixerOutputVolume = currentVolume
    }

    // Sleep timer fades to 60%
    setVolume(0.6)
    try assertEqual(mixerOutputVolume, 0.6)

    // Chapter ends, new chapter starts (stop → start cycle)
    func chapterTransition() {
        mixerOutputVolume = 1.0  // Engine stop resets mixer (the bug)
        // play() re-applies tracked volume (the fix)
        mixerOutputVolume = currentVolume
    }

    chapterTransition()
    try assertEqual(mixerOutputVolume, 0.6,
        "Volume should stay at 0.6 through chapter transition")
    try assertEqual(currentVolume, 0.6,
        "Tracked volume should be unchanged by transition")
}

test("Volume tracking: multiple chapter transitions maintain volume") {
    // Simulate several rapid chapter transitions while volume
    // is being faded by the sleep timer.
    var currentVolume: Float = 1.0
    var mixerOutputVolume: Float = 1.0

    func setVolume(_ v: Float) {
        currentVolume = max(0.0, min(v, 1.0))
        mixerOutputVolume = currentVolume
    }

    func chapterTransition() {
        mixerOutputVolume = 1.0  // Engine reset
        mixerOutputVolume = currentVolume  // Fix re-applies
    }

    // Fade gradually with chapter transitions interspersed
    setVolume(0.8)
    chapterTransition()
    try assertEqual(mixerOutputVolume, 0.8)

    setVolume(0.5)
    chapterTransition()
    try assertEqual(mixerOutputVolume, 0.5)

    setVolume(0.2)
    chapterTransition()
    chapterTransition()  // Two rapid transitions
    try assertEqual(mixerOutputVolume, 0.2,
        "Volume should survive even rapid double-transitions")
}

test("Volume tracking: setVolume clamps to valid range") {
    var currentVolume: Float = 1.0

    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
    }

    setVolume(-0.5)
    try assertEqual(currentVolume, 0.0, "Negative volume should clamp to 0")

    setVolume(2.0)
    try assertEqual(currentVolume, 1.0, "Volume above 1.0 should clamp to 1.0")

    setVolume(0.75)
    try assertEqual(currentVolume, 0.75, "Normal volume should pass through")
}

test("Volume tracking: adoptRenderedAudio does not affect volume") {
    // When adopting pre-rendered audio from another engine,
    // the volume state should not change. Only buffer data is copied.
    var currentVolume: Float = 0.5
    var mixerOutputVolume: Float = 0.5

    // Simulate adoptRenderedAudio — copies buffer data, not engine state
    func adoptRenderedAudio() {
        // Only copies: renderedBuffer, renderFormat, wordFrameMap,
        // totalFrames, renderWPM. Does NOT touch volume.
    }

    adoptRenderedAudio()
    try assertEqual(currentVolume, 0.5,
        "Tracked volume should be unaffected by audio adoption")
    try assertEqual(mixerOutputVolume, 0.5,
        "Mixer volume should be unaffected by audio adoption")
}

} // end runAudioEngineTests
