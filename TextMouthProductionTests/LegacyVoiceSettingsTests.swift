import XCTest
@testable import TextMouth

/// Production-backed ports of all legacy voice, speed, and pitch settings scenarios.
@MainActor
final class LegacyVoiceSettingsTests: XCTestCase {
    func testBookStateRoundTripsAllVoiceSettings() throws {
        let state = BookState(
            totalWordCount: 5_000,
            totalCharacterCount: 25_000,
            isNew: false,
            tmbDirectoryName: "book.tmb",
            localVoiceID: "com.apple.voice.premium.en-GB.Malcolm",
            localWPM: 425,
            localPitch: 0.8
        )

        let decoded = try JSONDecoder().decode(BookState.self, from: JSONEncoder().encode(state))

        XCTAssertEqual(decoded.localVoiceID, state.localVoiceID)
        XCTAssertEqual(decoded.localWPM, state.localWPM)
        XCTAssertEqual(decoded.localPitch, state.localPitch)
    }

    func testBookRoundTripsSpeedAndPitch() throws {
        let book = makeBook(localWPM: 200, localPitch: 1.5)

        let decoded = try JSONDecoder().decode(Book.self, from: JSONEncoder().encode(book))

        XCTAssertEqual(decoded.localWPM, 200)
        XCTAssertEqual(decoded.localPitch, 1.5)
    }

    func testBookPitchDefaultsToNil() {
        XCTAssertNil(makeBook().localPitch)
    }

    func testPitchClampAcceptsExactBoundaries() {
        XCTAssertEqual(SpeechService.clampedPitch(0.5), 0.5)
        XCTAssertEqual(SpeechService.clampedPitch(2.0), 2.0)
    }

    func testPitchClampPreservesEverySliderStep() {
        let steps = (0...15).map { 0.5 + Double($0) / 10 }

        XCTAssertEqual(steps.map(SpeechService.clampedPitch), steps)
        XCTAssertEqual(steps.count, 16)
    }

    func testPitchCentsConversionRoundTrips() {
        let original = 1.4
        let cents = AudioEngineService.pitchCents(for: original)
        let recovered = pow(2, Double(cents) / 1_200)

        XCTAssertEqual(recovered, original, accuracy: 0.0001)
    }

    func testNormalPitchLabel() {
        XCTAssertEqual(SpeechService.pitchLabel(1.0), "Normal (1.0x)")
    }

    func testNearNormalPitchLabelUsesTolerance() {
        XCTAssertEqual(SpeechService.pitchLabel(0.99), "Normal (1.0x)")
    }

    func testLowPitchLabelUsesMultiplier() {
        XCTAssertEqual(SpeechService.pitchLabel(0.7), "0.7x")
    }

    func testHighPitchLabelUsesMultiplier() {
        XCTAssertEqual(SpeechService.pitchLabel(1.8), "1.8x")
    }

    func testAppConfigRoundTripsPitch() throws {
        var config = ConfigService.AppConfig()
        config.selectedVoiceID = "com.apple.voice.compact.en-US.Samantha"
        config.wordsPerMinute = 300
        config.pitchMultiplier = 1.3
        config.selectedLanguage = "en"

        let decoded = try JSONDecoder().decode(
            ConfigService.AppConfig.self,
            from: JSONEncoder().encode(config)
        )

        XCTAssertEqual(decoded, config)
    }

    func testAppConfigDefaultsMissingPitchToZero() throws {
        let data = Data(#"{"selectedVoiceID":"voice1","wordsPerMinute":200,"selectedLanguage":"en"}"#.utf8)

        let decoded = try JSONDecoder().decode(ConfigService.AppConfig.self, from: data)

        XCTAssertEqual(decoded.pitchMultiplier, 0)
        XCTAssertFalse(decoded.pitchMultiplier > 0)
    }

    func testEveryLocalVoiceSettingCombinationReportsCorrectly() {
        let combinations: [(String?, Double?, Double?, Bool)] = [
            (nil, nil, nil, false),
            ("voice", nil, nil, true),
            (nil, 200, nil, true),
            (nil, nil, 1.5, true),
            ("voice", 200, nil, true),
            ("voice", nil, 1.5, true),
            (nil, 200, 1.5, true),
            ("voice", 200, 1.5, true),
        ]

        for (voice, speed, pitch, expected) in combinations {
            XCTAssertEqual(makeBook(localVoiceID: voice, localWPM: speed, localPitch: pitch).hasLocalVoiceSettings, expected)
        }
    }

    func testSpeedAndPitchOverridesRemainIndependent() {
        var book = makeBook(localWPM: 200, localPitch: 1.0)
        book.localWPM = 225
        XCTAssertEqual(book.localPitch, 1.0)

        book.localPitch = 1.1
        XCTAssertEqual(book.localWPM, 225)
    }

    func testWPMRateCalculationIsIndependentOfPitch() {
        let rate = SpeechService.rateForWPM(200)

        XCTAssertGreaterThan(rate, 0.4)
        XCTAssertLessThan(rate, 0.5)
    }

    func testBookInfoRoundTripsPitch() throws {
        let info = BookInfo(
            metadata: BookMetadata(title: "Pitch Persist", author: "Tester", format: .txt),
            state: BookState(
                totalWordCount: 1_000,
                isNew: false,
                tmbDirectoryName: "test.tmb",
                localVoiceID: "voice1",
                localWPM: 250,
                localPitch: 0.7
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookInfo.self, from: encoder.encode(info))

        XCTAssertEqual(decoded.state.localPitch, 0.7)
        XCTAssertEqual(decoded.state.localWPM, 250)
        XCTAssertEqual(decoded.state.localVoiceID, "voice1")
    }

    func testOldBookInfoWithoutPitchLoadsGracefully() throws {
        let json = """
        {
          "metadata": {
            "title": "Old Book", "author": "Unknown", "format": "txt",
            "md5Hash": "def456", "dateAdded": "2025-01-01T00:00:00Z",
            "originalFileName": "old.txt", "folderPath": "",
            "bookID": "12345678-1234-1234-1234-123456789012"
          },
          "state": {"isNew": false, "tmbDirectoryName": "old.tmb", "localWPM": 200},
          "bookmarks": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(BookInfo.self, from: Data(json.utf8))

        XCTAssertNil(decoded.state.localPitch)
        XCTAssertEqual(decoded.state.localWPM, 200)
    }

    func testLocalVoiceSnapshotProvidesValuesForGlobalSave() {
        let settings = makeBook(localVoiceID: "voice2", localWPM: 350, localPitch: 1.4).localVoiceSettings

        XCTAssertEqual(settings.voiceID, "voice2")
        XCTAssertEqual(settings.wordsPerMinute, 350)
        XCTAssertEqual(settings.pitch, 1.4)
    }

    func testClearingLocalVoiceSettingsRemovesEveryOverride() {
        var book = makeBook(localVoiceID: "voice2", localWPM: 350, localPitch: 1.4)

        book.clearLocalVoiceSettings()

        XCTAssertEqual(book.localVoiceSettings, Book.LocalVoiceSettings())
        XCTAssertFalse(book.hasLocalVoiceSettings)
    }

    private func makeBook(
        localVoiceID: String? = nil,
        localWPM: Double? = nil,
        localPitch: Double? = nil
    ) -> Book {
        Book(
            title: "Voice Test",
            format: .txt,
            filePath: "/tmp/voice-test.txt",
            md5Hash: "hash",
            localVoiceID: localVoiceID,
            localWPM: localWPM,
            localPitch: localPitch
        )
    }
}
