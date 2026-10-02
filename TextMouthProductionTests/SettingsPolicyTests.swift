import XCTest
@testable import TextMouth

/// Coverage for the one validation table that every settings path shares:
/// config decoding, config application, the `@AppStorage` read path, direct
/// `UserDefaults` readers, and saved book state.
final class SettingsPolicyTests: XCTestCase {
    // MARK: - The table

    /// The ranges are the Settings controls' ranges, and every default is a
    /// supported value. A change here must be a deliberate UI change too.
    func testNumericRulesMatchTheSettingsControls() {
        let expected: [(NumericSettingRule, ClosedRange<Double>, Double)] = [
            (SettingsPolicy.wordsPerMinute, 50...650, 200),
            (SettingsPolicy.pitchMultiplier, 0.5...2.0, 1),
            (SettingsPolicy.rewindSmartThreshold, 5...600, 70),
            (SettingsPolicy.sleepFadeOutDuration, 0...10, 0),
            (SettingsPolicy.punctuationPauseLevel, 0...3, 0),
            (SettingsPolicy.bluetoothDisconnectDelay, 1...10, 2),
            (SettingsPolicy.restartTimerGestureWindow, 0.5...10, 2),
        ]
        for (rule, range, defaultValue) in expected {
            XCTAssertEqual(rule.range, range, rule.key)
            XCTAssertEqual(rule.defaultValue, defaultValue, rule.key)
            XCTAssertTrue(rule.range.contains(rule.defaultValue), rule.key)
        }
    }

    /// Only speed and pitch use 0 to mean "not chosen yet"; every other
    /// numeric field defaults to its real default in config.json.
    func testOnlySpeedAndPitchHaveAnUnsetValue() {
        XCTAssertEqual(SettingsPolicy.wordsPerMinute.configDefault, 0)
        XCTAssertEqual(SettingsPolicy.pitchMultiplier.configDefault, 0)
        XCTAssertEqual(SettingsPolicy.rewindSmartThreshold.configDefault, 70)
        XCTAssertEqual(SettingsPolicy.bluetoothDisconnectDelay.configDefault, 2)
        XCTAssertNil(SettingsPolicy.sleepFadeOutDuration.unsetValue)
    }

    /// The enum rules fall back to the same cases the Settings model always
    /// used, and accept exactly their enum's raw values.
    func testEnumRulesUseTheSettingsDefaultsAndTheirCases() {
        XCTAssertEqual(SettingsPolicy.skipForwardUnit.defaultValue, .seconds15)
        XCTAssertEqual(SettingsPolicy.skipBackwardUnit.defaultValue, .seconds15)
        XCTAssertEqual(SettingsPolicy.shiftSkipForwardUnit.defaultValue, .seconds30)
        XCTAssertEqual(SettingsPolicy.shiftSkipBackwardUnit.defaultValue, .seconds30)
        XCTAssertEqual(SettingsPolicy.rewindOnResumeUnit.defaultValue, RewindUnit.none)
        XCTAssertEqual(SettingsPolicy.endOfBookBehavior.defaultValue, .stop)
        XCTAssertEqual(
            SettingsPolicy.playbackNavigationUnitControlMode.defaultValue,
            PlaybackNavigationUnitControlMode.none
        )
        XCTAssertEqual(SettingsPolicy.importDeleteBehavior.defaultValue, .keepOriginal)
        XCTAssertEqual(
            SettingsPolicy.importDeleteBehavior.allowedRawValues,
            ["Keep Original", "Delete After Import", "Ask Each Time"]
        )
        XCTAssertEqual(SettingsPolicy.skipForwardUnit.allowedRawValues, SkipUnit.allCases.map(\.rawValue))
    }

    /// The sleep timer sheet's stepper allows 1 to 480 minutes.
    func testSleepTimerMinutesMatchTheSheetStepper() {
        XCTAssertEqual(SettingsPolicy.sleepTimerMinutes, 1...480)
    }

    // MARK: - Numeric clamping

    /// Finite values move to the nearest bound; in-range values are untouched.
    func testClampMovesFiniteValuesToTheNearestBound() {
        let rule = SettingsPolicy.wordsPerMinute
        XCTAssertEqual(rule.validated(1e308), 650)
        XCTAssertEqual(rule.validated(Double.greatestFiniteMagnitude), 650)
        XCTAssertEqual(rule.validated(-5), 50)
        XCTAssertEqual(rule.validated(-Double.greatestFiniteMagnitude), 50)
        XCTAssertEqual(rule.validated(10), 50)
        XCTAssertEqual(rule.validated(337), 337)
        XCTAssertEqual(SettingsPolicy.punctuationPauseLevel.validated(-1), 0)
        XCTAssertEqual(SettingsPolicy.punctuationPauseLevel.validated(99), 3)
    }

    /// NaN and infinities have no usable magnitude, so they become the default.
    func testClampReplacesNonFiniteValuesWithTheDefault() {
        for value in [Double.nan, Double.infinity, -Double.infinity, Double.signalingNaN] {
            XCTAssertEqual(SettingsPolicy.wordsPerMinute.validated(value), 200, "\(value)")
            XCTAssertEqual(SettingsPolicy.sleepFadeOutDuration.validated(value), 0, "\(value)")
            XCTAssertEqual(SettingsPolicy.restartTimerGestureWindow.validated(value), 2, "\(value)")
        }
    }

    /// A stored speed or pitch of 0 means "not chosen yet", as the speech
    /// engine has always read it, so it becomes the default rather than the
    /// minimum. Zero is an ordinary value for the other settings.
    func testStoredZeroSpeedOrPitchMeansNotChosen() {
        XCTAssertEqual(SettingsPolicy.wordsPerMinute.validated(0), 200)
        XCTAssertEqual(SettingsPolicy.wordsPerMinute.validated(-0.0), 200)
        XCTAssertEqual(SettingsPolicy.wordsPerMinute.validated(0.5), 50)
        XCTAssertEqual(SettingsPolicy.pitchMultiplier.validated(0), 1)
        XCTAssertEqual(SettingsPolicy.sleepFadeOutDuration.validated(0), 0)
        XCTAssertEqual(SettingsPolicy.bluetoothDisconnectDelay.validated(0), 1)
    }

    /// In config.json, 0 still means "not chosen yet" for speed and pitch,
    /// while negative and huge numbers are clamped like any other value.
    func testConfigValuesKeepTheUnsetSentinelAndClampEverythingElse() {
        let speed = SettingsPolicy.wordsPerMinute
        XCTAssertEqual(speed.validatedConfigValue(0), 0)
        XCTAssertEqual(speed.validatedConfigValue(-0.0), 0)
        XCTAssertNil(speed.requestedValue(fromConfig: 0))
        XCTAssertEqual(speed.validatedConfigValue(-3), 50)
        XCTAssertEqual(speed.requestedValue(fromConfig: 1e308), 650)
        XCTAssertEqual(speed.requestedValue(fromConfig: 425), 425)
        // Non-finite numbers are treated as a missing field.
        XCTAssertEqual(speed.validatedConfigValue(.nan), 0)
        XCTAssertNil(speed.requestedValue(fromConfig: .infinity))
    }

    /// Settings without an unset sentinel clamp 0 like any other number, and
    /// treat a non-finite value as their (real) default.
    func testConfigValuesWithoutASentinelAlwaysRequestASupportedValue() {
        let threshold = SettingsPolicy.rewindSmartThreshold
        XCTAssertEqual(threshold.requestedValue(fromConfig: 0), 5)
        XCTAssertEqual(threshold.requestedValue(fromConfig: 1e9), 600)
        XCTAssertEqual(threshold.requestedValue(fromConfig: .nan), 70)
        XCTAssertEqual(SettingsPolicy.sleepFadeOutDuration.requestedValue(fromConfig: 0), 0)
    }

    /// Direct `UserDefaults` readers see exactly what the Settings model sees:
    /// a missing key is the default, and anything stored is validated. Text
    /// that is not a number reads as 0, which for speed means "not chosen".
    func testStoredValueReadsDefaultsLikeAppStorageAndValidates() throws {
        let defaults = makeSandboxedPreferences("settings-policy")
        let rule = SettingsPolicy.wordsPerMinute

        XCTAssertEqual(rule.storedValue(in: defaults), 200, "missing key")
        let cases: [(Any, Double)] = [
            (1e308, 650), (-40.0, 50), (Double.nan, 200), (Double.infinity, 200), (0.0, 200),
            (315, 315), ("450", 450), ("fast", 200), (true, 50),
        ]
        for (stored, expected) in cases {
            defaults.set(stored, forKey: rule.key)
            XCTAssertEqual(rule.storedValue(in: defaults), expected, "\(stored)")
        }
    }

    // MARK: - Enum validation

    /// Unknown or missing raw values fall back to the default case, and in
    /// config.json an unsupported raw value becomes "not chosen yet".
    func testEnumRulesRejectUnsupportedRawValues() {
        let rule = SettingsPolicy.skipForwardUnit
        XCTAssertEqual(rule.value(fromRaw: "Sentence"), .sentence)
        XCTAssertEqual(rule.value(fromRaw: "17 seconds"), .seconds15)
        XCTAssertEqual(rule.value(fromRaw: nil), .seconds15)
        XCTAssertEqual(rule.validatedConfigRawValue("Heading"), "Heading")
        XCTAssertEqual(rule.validatedConfigRawValue("17 seconds"), "")
        XCTAssertEqual(rule.validatedConfigRawValue(""), "")
        XCTAssertEqual(rule.requestedValue(fromConfig: "Paragraph"), .paragraph)
        XCTAssertNil(rule.requestedValue(fromConfig: ""))
        XCTAssertNil(rule.requestedValue(fromConfig: "heading"), "raw values are case-sensitive")
    }

    // MARK: - Saved book state

    /// A text book's saved speed is words per minute, clamped to the global
    /// range; values that cannot be a speed are dropped.
    func testTextBookSpeedUsesTheWordsPerMinuteRange() {
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(300, isAudio: false), 300)
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(10, isAudio: false), 50)
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(1e308, isAudio: false), 650)
        for unusable: Double in [0, -1, Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(SettingsPolicy.validatedLocalSpeed(unusable, isAudio: false), "\(unusable)")
        }
    }

    /// An audio book's saved speed is a multiplier, normalized exactly as the
    /// reader and player normalize it; unusable values are dropped.
    func testAudioBookSpeedUsesAudioSpeedNormalization() {
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(1.2345, isAudio: true), 1.25)
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(99, isAudio: true), 4)
        XCTAssertEqual(SettingsPolicy.validatedLocalSpeed(0.1, isAudio: true), 0.25)
        for speed in [0.26, 1.1000000000000001, 3.99, 275] {
            XCTAssertEqual(
                SettingsPolicy.validatedLocalSpeed(speed, isAudio: true),
                AudioSpeed.normalized(speed),
                "\(speed)"
            )
        }
        for unusable: Double in [0, -2, Double.nan, Double.infinity] {
            XCTAssertNil(SettingsPolicy.validatedLocalSpeed(unusable, isAudio: true), "\(unusable)")
        }
    }

    /// A saved pitch is clamped to the global pitch range or dropped.
    func testBookPitchIsClampedOrDropped() {
        XCTAssertEqual(SettingsPolicy.validatedLocalPitch(1.3), 1.3)
        XCTAssertEqual(SettingsPolicy.validatedLocalPitch(9), 2)
        XCTAssertEqual(SettingsPolicy.validatedLocalPitch(0.1), 0.5)
        for unusable: Double in [0, -1, Double.nan, -Double.infinity] {
            XCTAssertNil(SettingsPolicy.validatedLocalPitch(unusable), "\(unusable)")
        }
    }

    /// Indices and offsets never go below 0; negative counts become unknown.
    func testPositionsAndCountsNeverGoNegative() {
        XCTAssertEqual(SettingsPolicy.validatedPosition(-5), 0)
        XCTAssertEqual(SettingsPolicy.validatedPosition(Int.min), 0)
        XCTAssertEqual(SettingsPolicy.validatedPosition(7), 7)
        XCTAssertEqual(SettingsPolicy.validatedPosition(Int.max), Int.max, "the reader clamps to content")
        XCTAssertNil(SettingsPolicy.validatedCount(-1))
        XCTAssertEqual(SettingsPolicy.validatedCount(0), 0)
        XCTAssertEqual(SettingsPolicy.validatedCount(42), 42)
    }
}
