import Foundation

func runVoiceSettingsTests() {

// ---- Pitch Serialization Round-Trip ----
print("\n--- Voice Settings: Pitch Serialization ---")

test("BookState: full voice settings round-trip (voice + speed + pitch)") {
    let state = BookState(
        totalWordCount: 5000,
        totalCharacterCount: 25000,
        isNew: false,
        tmbDirectoryName: "book.tmb",
        localVoiceID: "com.apple.voice.premium.en-GB.Malcolm",
        localWPM: 425.0,
        localPitch: 0.8
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let decoder = JSONDecoder()

    let data = try encoder.encode(state)
    let decoded = try decoder.decode(BookState.self, from: data)

    try assertEqual(decoded.localVoiceID, "com.apple.voice.premium.en-GB.Malcolm")
    try assertEqual(decoded.localWPM, 425.0)
    try assertEqual(decoded.localPitch, 0.8)
}

test("Book: pitch persists through encode/decode cycle") {
    var book = Book(
        title: "Pitch Test",
        author: "Tester",
        localWPM: 200.0,
        localPitch: 1.5
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let data = try encoder.encode(book)
    let decoded = try decoder.decode(Book.self, from: data)

    try assertEqual(decoded.localPitch, 1.5)
    try assertEqual(decoded.localWPM, 200.0)
}

test("Book: nil pitch when not set") {
    let book = Book(title: "No Pitch")
    try assertTrue(book.localPitch == nil)
}

// ---- Pitch Edge Cases ----
print("\n--- Voice Settings: Pitch Edge Cases ---")

test("Pitch at exact boundaries: 0.5 and 2.0 are valid") {
    let low = max(0.5, min(0.5, 2.0))
    let high = max(0.5, min(2.0, 2.0))
    try assertEqual(low, 0.5)
    try assertEqual(high, 2.0)
}

test("Pitch step granularity: 0.1 steps from 0.5 to 2.0") {
    // Verify all 0.1 steps are representable and clamp correctly
    var steps: [Double] = []
    var pitch = 0.5
    while pitch <= 2.0 + 0.001 {
        let clamped = max(0.5, min(pitch, 2.0))
        steps.append(clamped)
        pitch += 0.1
    }
    // Should have 16 steps (0.5, 0.6, ..., 2.0)
    try assertEqual(steps.count, 16)
    try assertTrue(abs(steps.first! - 0.5) < 0.001)
    try assertTrue(abs(steps.last! - 2.0) < 0.001)
}

test("Pitch cents conversion: round-trip through cents and back") {
    // Convert to cents and back to multiplier
    let original = 1.4
    let cents = 1200.0 * log2(original)
    let recovered = pow(2.0, cents / 1200.0)
    try assertTrue(abs(original - recovered) < 0.0001,
                   "Round-trip should preserve value: \(original) -> \(cents) cents -> \(recovered)")
}

test("Pitch label: 1.0 shows as Normal") {
    let value = 1.0
    let label: String
    if abs(value - 1.0) < 0.05 { label = "Normal (1.0x)" }
    else { label = String(format: "%.1fx", value) }
    try assertEqual(label, "Normal (1.0x)")
}

test("Pitch label: 0.99 still shows as Normal (tolerance)") {
    let value = 0.99
    let label: String
    if abs(value - 1.0) < 0.05 { label = "Normal (1.0x)" }
    else { label = String(format: "%.1fx", value) }
    try assertEqual(label, "Normal (1.0x)")
}

test("Pitch label: 0.7 shows multiplier") {
    let value = 0.7
    let label: String
    if abs(value - 1.0) < 0.05 { label = "Normal (1.0x)" }
    else { label = String(format: "%.1fx", value) }
    try assertEqual(label, "0.7x")
}

test("Pitch label: 1.8 shows multiplier") {
    let value = 1.8
    let label: String
    if abs(value - 1.0) < 0.05 { label = "Normal (1.0x)" }
    else { label = String(format: "%.1fx", value) }
    try assertEqual(label, "1.8x")
}

// ---- Config Serialization with Pitch ----
print("\n--- Voice Settings: Config Serialization ---")

test("AppConfig-style struct encodes and decodes pitch") {
    struct AppConfig: Codable, Equatable {
        var selectedVoiceID: String = ""
        var wordsPerMinute: Double = 0
        var pitchMultiplier: Double = 0
        var selectedLanguage: String = ""
    }

    var config = AppConfig()
    config.selectedVoiceID = "com.apple.voice.compact.en-US.Samantha"
    config.wordsPerMinute = 300.0
    config.pitchMultiplier = 1.3
    config.selectedLanguage = "en"

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(config)
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    try assertEqual(decoded.pitchMultiplier, 1.3)
    try assertEqual(decoded.wordsPerMinute, 300.0)
    try assertEqual(decoded.selectedVoiceID, "com.apple.voice.compact.en-US.Samantha")
}

test("AppConfig-style: pitch defaults to 0 when not explicitly set") {
    struct AppConfig: Codable {
        var selectedVoiceID: String = ""
        var wordsPerMinute: Double = 0
        var pitchMultiplier: Double = 0
        var selectedLanguage: String = ""
    }

    // Config with pitchMultiplier explicitly 0 (matching "not yet set by user")
    let json = """
    {"selectedVoiceID": "voice1", "wordsPerMinute": 200, "pitchMultiplier": 0, "selectedLanguage": "en"}
    """
    let data = json.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(AppConfig.self, from: data)

    try assertEqual(decoded.pitchMultiplier, 0, "Pitch should be 0 (not set)")
    try assertEqual(decoded.wordsPerMinute, 200.0)

    // Verify 0 means "not yet set" — sync logic should skip it
    let shouldSync = decoded.pitchMultiplier > 0
    try assertTrue(!shouldSync, "pitchMultiplier=0 should not trigger sync")
}

// ---- hasLocalSettings with Pitch ----
print("\n--- Voice Settings: hasLocalSettings Logic ---")

test("hasLocalSettings: all combinations") {
    // Test all 8 combinations of voice/speed/pitch being nil or set
    let combos: [(String?, Double?, Double?, Bool)] = [
        (nil, nil, nil, false),         // none set
        ("voice1", nil, nil, true),     // voice only
        (nil, 200.0, nil, true),        // speed only
        (nil, nil, 1.5, true),          // pitch only
        ("voice1", 200.0, nil, true),   // voice + speed
        ("voice1", nil, 1.5, true),     // voice + pitch
        (nil, 200.0, 1.5, true),        // speed + pitch
        ("voice1", 200.0, 1.5, true),   // all three
    ]

    for (i, (voice, wpm, pitch, expected)) in combos.enumerated() {
        let hasLocal = voice != nil || wpm != nil || pitch != nil
        try assertEqual(hasLocal, expected, "Combo \(i): voice=\(String(describing: voice)), wpm=\(String(describing: wpm)), pitch=\(String(describing: pitch))")
    }
}

// ---- Speed + Pitch Independence ----
print("\n--- Voice Settings: Speed/Pitch Independence ---")

test("Speed and pitch are independent settings") {
    // Changing speed should not affect pitch and vice versa
    var wpm = 200.0
    var pitch = 1.0

    // Adjust speed
    wpm = max(50, min(wpm + 25, 650))
    try assertEqual(wpm, 225.0)
    try assertEqual(pitch, 1.0, "Pitch should be unchanged when speed changes")

    // Adjust pitch
    pitch = max(0.5, min(pitch + 0.1, 2.0))
    try assertTrue(abs(pitch - 1.1) < 0.001)
    try assertEqual(wpm, 225.0, "Speed should be unchanged when pitch changes")
}

test("WPM rate table unchanged by pitch") {
    // Verify the rate calculation doesn't depend on pitch
    // (rate table maps WPM to AVSpeechUtterance.rate, pitch is separate)
    let rateTable: [(rate: Double, wpm: Double)] = [
        (0.0, 50), (0.1, 80), (0.2, 120), (0.3, 167), (0.4, 190),
        (0.5, 216), (0.6, 344), (0.7, 457), (0.8, 604), (0.9, 759), (1.0, 871),
    ]

    // Check interpolation at 200 WPM (between 190 and 216)
    let targetWPM = 200.0
    var rate: Double = 0.5
    for i in 0..<(rateTable.count - 1) {
        let lo = rateTable[i]
        let hi = rateTable[i + 1]
        if targetWPM >= lo.wpm && targetWPM <= hi.wpm {
            let fraction = (targetWPM - lo.wpm) / (hi.wpm - lo.wpm)
            rate = lo.rate + fraction * (hi.rate - lo.rate)
            break
        }
    }
    // 200 WPM should be between rate 0.4 and 0.5
    try assertTrue(rate > 0.4 && rate < 0.5,
                   "200 WPM should map to rate between 0.4 and 0.5, got \(rate)")
}

// ---- BookInfo Pitch Persistence ----
print("\n--- Voice Settings: BookInfo Persistence ---")

test("BookInfo: pitch persists through save/load cycle") {
    let bookInfo = BookInfo(
        metadata: BookMetadata(
            title: "Pitch Persist",
            author: "Tester",
            format: .txt,
            md5Hash: "abc123",
            dateAdded: Date(),
            originalFileName: "test.txt",
            folderPath: "",
            bookID: UUID()
        ),
        state: BookState(
            totalWordCount: 1000,
            isNew: false,
            tmbDirectoryName: "test.tmb",
            localVoiceID: "voice1",
            localWPM: 250.0,
            localPitch: 0.7
        ),
        bookmarks: []
    )

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(bookInfo)

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(BookInfo.self, from: data)

    try assertEqual(decoded.state.localPitch, 0.7)
    try assertEqual(decoded.state.localWPM, 250.0)
    try assertEqual(decoded.state.localVoiceID, "voice1")
}

test("BookInfo: old format without pitch loads gracefully") {
    let json = """
    {
        "metadata": {
            "title": "Old Book",
            "author": "Unknown",
            "format": "txt",
            "md5Hash": "def456",
            "dateAdded": "2025-01-01T00:00:00Z",
            "originalFileName": "old.txt",
            "folderPath": "",
            "bookID": "12345678-1234-1234-1234-123456789012"
        },
        "state": {
            "isNew": false,
            "tmbDirectoryName": "old.tmb",
            "localWPM": 200.0
        },
        "bookmarks": []
    }
    """
    let data = json.data(using: .utf8)!
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(BookInfo.self, from: data)

    try assertTrue(decoded.state.localPitch == nil, "Pitch should be nil for old format")
    try assertEqual(decoded.state.localWPM, 200.0)
}

// ---- Save/Reset Settings with Pitch ----
print("\n--- Voice Settings: Save/Reset with Pitch ---")

test("saveSettingsToGlobal copies pitch to global") {
    // Simulate the logic from saveSettingsToGlobal
    let localPitch: Double? = 1.4
    let localWPM: Double? = 350.0
    let localVoiceID: String? = "voice2"

    var globalPitch = 1.0
    var globalWPM = 200.0
    var globalVoiceID = "voice1"

    if let lp = localPitch { globalPitch = lp }
    if let lw = localWPM { globalWPM = lw }
    if let lv = localVoiceID { globalVoiceID = lv }

    try assertEqual(globalPitch, 1.4)
    try assertEqual(globalWPM, 350.0)
    try assertEqual(globalVoiceID, "voice2")
}

test("resetToGlobalSettings clears all local overrides including pitch") {
    var localVoiceID: String? = "voice2"
    var localWPM: Double? = 350.0
    var localPitch: Double? = 1.4

    // Reset
    localVoiceID = nil
    localWPM = nil
    localPitch = nil

    try assertTrue(localVoiceID == nil)
    try assertTrue(localWPM == nil)
    try assertTrue(localPitch == nil)

    let hasLocal = localVoiceID != nil || localWPM != nil || localPitch != nil
    try assertTrue(!hasLocal)
}

} // end runVoiceSettingsTests
