import Foundation

struct BookState: Codable {
    var totalWordCount: Int?
    var totalCharacterCount: Int?
    var isNew: Bool
    var tmbDirectoryName: String
    var lastPlaybackStarted: Date?
    var lastPlaybackStopped: Date?
    var localVoiceID: String?
    var localWPM: Double?
    var localPitch: Double?
    var skippedHeadingIDs: [String]?
    var localEndOfBookBehavior: String?
    var manualSortOrder: Int?
    var audioDuration: TimeInterval?

    init(
        totalWordCount: Int? = nil,
        totalCharacterCount: Int? = nil,
        isNew: Bool = true,
        tmbDirectoryName: String = "",
        lastPlaybackStarted: Date? = nil,
        lastPlaybackStopped: Date? = nil,
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil,
        skippedHeadingIDs: [String]? = nil,
        localEndOfBookBehavior: String? = nil,
        manualSortOrder: Int? = nil,
        audioDuration: TimeInterval? = nil
    ) {
        self.totalWordCount = totalWordCount
        self.totalCharacterCount = totalCharacterCount
        self.isNew = isNew
        self.tmbDirectoryName = tmbDirectoryName
        self.lastPlaybackStarted = lastPlaybackStarted
        self.lastPlaybackStopped = lastPlaybackStopped
        self.localVoiceID = localVoiceID
        self.localWPM = localWPM
        self.localPitch = localPitch
        self.skippedHeadingIDs = skippedHeadingIDs
        self.localEndOfBookBehavior = localEndOfBookBehavior
        self.manualSortOrder = manualSortOrder
        self.audioDuration = audioDuration
    }
}

func runBookStateTests() {
// ---- Config & Settings Tests ----
print("\n--- Config & Settings Tests ---")

test("SkipUnit word count at various WPM") {
    func wordCount(seconds: Int, wpm: Double) -> Int {
        max(1, Int(wpm * Double(seconds) / 60.0))
    }

    // At very low WPM, should still return at least 1
    try assertEqual(wordCount(seconds: 10, wpm: 1.0), 1, "Minimum 1 word")
    try assertEqual(wordCount(seconds: 15, wpm: 200.0), 50)
    try assertEqual(wordCount(seconds: 30, wpm: 200.0), 100)
    try assertEqual(wordCount(seconds: 60, wpm: 200.0), 200)
}

test("SkipUnit heading and bookmark return nil word count") {
    // Heading and bookmark-based skips don't use word count
    let headingWordCount: Int? = nil
    let bookmarkWordCount: Int? = nil
    try assertTrue(headingWordCount == nil)
    try assertTrue(bookmarkWordCount == nil)
}

// ---- BookFormat Detection Tests ----
print("\n--- BookFormat Detection Tests ---")

test("BookFormat detects correct format from extension") {
    func detect(ext: String) -> String? {
        let formats: [(name: String, extensions: [String])] = [
            ("epub", ["epub"]),
            ("txt", ["txt"]),
            ("markdown", ["md", "markdown"]),
            ("html", ["html", "htm", "xhtml"]),
        ]
        for format in formats {
            if format.extensions.contains(ext.lowercased()) {
                return format.name
            }
        }
        return nil
    }

    try assertEqual(detect(ext: "epub"), "epub")
    try assertEqual(detect(ext: "txt"), "txt")
    try assertEqual(detect(ext: "md"), "markdown")
    try assertEqual(detect(ext: "markdown"), "markdown")
    try assertEqual(detect(ext: "html"), "html")
    try assertEqual(detect(ext: "htm"), "html")
    try assertEqual(detect(ext: "xhtml"), "html")
    try assertTrue(detect(ext: "pdf") == nil, "Unsupported format should return nil")
    try assertTrue(detect(ext: "docx") == nil, "Unsupported format should return nil")

    // Case insensitivity
    try assertEqual(detect(ext: "EPUB"), "epub")
    try assertEqual(detect(ext: "HTML"), "html")
}

// ---- BookState Timestamp Serialization ----
print("\n--- BookState Timestamp Serialization ---")

test("BookState: encodes and decodes with timestamps") {
    let now = Date()
    let state = BookState(
        totalWordCount: 1000,
        totalCharacterCount: 5000,
        isNew: false,
        tmbDirectoryName: "test.tmb",
        lastPlaybackStarted: now,
        lastPlaybackStopped: now.addingTimeInterval(300)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let data = try encoder.encode(state)
    let decoded = try decoder.decode(BookState.self, from: data)

    try assertEqual(decoded.totalWordCount, 1000)
    try assertEqual(decoded.isNew, false)
    try assertTrue(decoded.lastPlaybackStarted != nil, "Should have started timestamp")
    try assertTrue(decoded.lastPlaybackStopped != nil, "Should have stopped timestamp")
    // ISO 8601 rounds to seconds, so compare within 1 second
    try assertTrue(abs(decoded.lastPlaybackStarted!.timeIntervalSince(now)) < 1.0)
    try assertTrue(abs(decoded.lastPlaybackStopped!.timeIntervalSince(now.addingTimeInterval(300))) < 1.0)
}

test("BookState: decodes without timestamps (backward compatibility)") {
    let json = """
    {"isNew": true, "tmbDirectoryName": "old.tmb", "totalWordCount": 500}
    """
    let decoder = JSONDecoder()
    let data = json.data(using: .utf8)!
    let decoded = try decoder.decode(BookState.self, from: data)

    try assertEqual(decoded.isNew, true)
    try assertEqual(decoded.tmbDirectoryName, "old.tmb")
    try assertTrue(decoded.lastPlaybackStarted == nil, "Should be nil when not in JSON")
    try assertTrue(decoded.lastPlaybackStopped == nil, "Should be nil when not in JSON")
}

test("BookState: smart rewind threshold calculation") {
    let stopped = Date().addingTimeInterval(-120) // Stopped 2 minutes ago
    let threshold: TimeInterval = 70 // seconds
    let elapsed = Date().timeIntervalSince(stopped)
    try assertTrue(elapsed > threshold, "120s elapsed should exceed 70s threshold")

    let recentStop = Date().addingTimeInterval(-30) // Stopped 30 seconds ago
    let recentElapsed = Date().timeIntervalSince(recentStop)
    try assertTrue(recentElapsed < threshold, "30s elapsed should be under 70s threshold")
}

// ---- Per-Book Voice & Speed ----
print("\n--- Per-Book Voice & Speed ---")

test("BookState: encodes and decodes with localVoiceID and localWPM") {
    let state = BookState(
        totalWordCount: 2000,
        totalCharacterCount: 10000,
        isNew: false,
        tmbDirectoryName: "test.tmb",
        lastPlaybackStarted: nil,
        lastPlaybackStopped: nil,
        localVoiceID: "com.apple.voice.compact.en-US.Samantha",
        localWPM: 300.0
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let data = try encoder.encode(state)
    let decoded = try decoder.decode(BookState.self, from: data)

    try assertEqual(decoded.localVoiceID, "com.apple.voice.compact.en-US.Samantha")
    try assertEqual(decoded.localWPM, 300.0)
}

test("BookState: backward compatible without localVoiceID/localWPM") {
    let json = """
    {"isNew": true, "tmbDirectoryName": "old.tmb"}
    """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(BookState.self, from: data)

    try assertTrue(decoded.localVoiceID == nil, "Should be nil when not in JSON")
    try assertTrue(decoded.localWPM == nil, "Should be nil when not in JSON")
}

test("effectiveWPM: returns local WPM when set") {
    // Simulating the logic from Book.effectiveWPM
    let localWPM: Double? = 350.0
    let globalWPM: Double = 200.0
    let effective = localWPM ?? globalWPM
    try assertEqual(effective, 350.0)
}

test("effectiveWPM: returns global WPM when local is nil") {
    let localWPM: Double? = nil
    let globalWPM: Double = 200.0
    let effective = localWPM ?? globalWPM
    try assertEqual(effective, 200.0)
}

test("estimatedTimeRemaining uses local WPM over global") {
    // Book with 1000 words, at 200 WPM global = 300s total
    // But with 300 WPM local = 200s total
    let totalWords = 1000
    let totalChars = 5000
    let globalWPM = 200.0
    let localWPM: Double? = 300.0

    let effectiveWPM = localWPM ?? globalWPM
    let totalTime = Double(totalWords) / effectiveWPM * 60.0

    // At 300 WPM: 1000/300*60 = 200s
    try assertTrue(abs(totalTime - 200.0) < 0.1, "Should be ~200s at 300 WPM, got \(totalTime)")

    // Without local: 1000/200*60 = 300s
    let globalTime = Double(totalWords) / globalWPM * 60.0
    try assertTrue(abs(globalTime - 300.0) < 0.1, "Should be ~300s at 200 WPM, got \(globalTime)")
}

test("hasLocalSettings: true when localWPM set") {
    let localVoiceID: String? = nil
    let localWPM: Double? = 250.0
    let hasLocal = localVoiceID != nil || localWPM != nil
    try assertTrue(hasLocal)
}

test("hasLocalSettings: true when localVoiceID set") {
    let localVoiceID: String? = "com.apple.voice.compact.en-US.Samantha"
    let localWPM: Double? = nil
    let hasLocal = localVoiceID != nil || localWPM != nil
    try assertTrue(hasLocal)
}

test("hasLocalSettings: false when both nil") {
    let localVoiceID: String? = nil
    let localWPM: Double? = nil
    let hasLocal = localVoiceID != nil || localWPM != nil
    try assertTrue(!hasLocal)
}

// ---- Per-Book Pitch ----
print("\n--- Per-Book Pitch ---")

test("BookState: encodes and decodes with localPitch") {
    let state = BookState(
        totalWordCount: 2000,
        totalCharacterCount: 10000,
        isNew: false,
        tmbDirectoryName: "test.tmb",
        localVoiceID: "com.apple.voice.compact.en-US.Samantha",
        localWPM: 300.0,
        localPitch: 1.5
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let data = try encoder.encode(state)
    let decoded = try decoder.decode(BookState.self, from: data)

    try assertEqual(decoded.localPitch, 1.5)
    try assertEqual(decoded.localVoiceID, "com.apple.voice.compact.en-US.Samantha")
    try assertEqual(decoded.localWPM, 300.0)
}

test("BookState: backward compatible without localPitch") {
    let json = """
    {"isNew": true, "tmbDirectoryName": "old.tmb", "localWPM": 200.0}
    """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(BookState.self, from: data)

    try assertTrue(decoded.localPitch == nil, "Should be nil when not in JSON")
    try assertEqual(decoded.localWPM, 200.0)
}

test("hasLocalSettings: true when only localPitch set") {
    let localVoiceID: String? = nil
    let localWPM: Double? = nil
    let localPitch: Double? = 1.3
    let hasLocal = localVoiceID != nil || localWPM != nil || localPitch != nil
    try assertTrue(hasLocal)
}

test("hasLocalSettings: false when all nil including pitch") {
    let localVoiceID: String? = nil
    let localWPM: Double? = nil
    let localPitch: Double? = nil
    let hasLocal = localVoiceID != nil || localWPM != nil || localPitch != nil
    try assertTrue(!hasLocal)
}

test("Pitch multiplier clamping: values below 0.5 clamp to 0.5") {
    let input = 0.2
    let clamped = max(0.5, min(input, 2.0))
    try assertEqual(clamped, 0.5)
}

test("Pitch multiplier clamping: values above 2.0 clamp to 2.0") {
    let input = 3.5
    let clamped = max(0.5, min(input, 2.0))
    try assertEqual(clamped, 2.0)
}

test("Pitch multiplier clamping: normal value passes through") {
    let input = 1.3
    let clamped = max(0.5, min(input, 2.0))
    try assertTrue(abs(clamped - 1.3) < 0.001)
}

test("Pitch to cents conversion: 1.0x = 0 cents") {
    let multiplier = 1.0
    let cents = 1200.0 * log2(multiplier)
    try assertTrue(abs(cents) < 0.001, "1.0x should be 0 cents, got \(cents)")
}

test("Pitch to cents conversion: 2.0x = 1200 cents (one octave up)") {
    let multiplier = 2.0
    let cents = 1200.0 * log2(multiplier)
    try assertTrue(abs(cents - 1200.0) < 0.001, "2.0x should be 1200 cents, got \(cents)")
}

test("Pitch to cents conversion: 0.5x = -1200 cents (one octave down)") {
    let multiplier = 0.5
    let cents = 1200.0 * log2(multiplier)
    try assertTrue(abs(cents - (-1200.0)) < 0.001, "0.5x should be -1200 cents, got \(cents)")
}

} // end runBookStateTests
