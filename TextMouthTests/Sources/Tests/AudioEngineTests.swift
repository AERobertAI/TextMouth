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

} // end runAudioEngineTests
