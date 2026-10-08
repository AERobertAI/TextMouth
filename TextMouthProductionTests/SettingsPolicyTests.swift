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
            (SettingsPolicy.soundEffectsVolume, 0...1, 0.5),
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

    // MARK: - Keyed preferences

    /// Sound assignments keep only the playback events TextMouth knows, each
    /// with a sound the Sounds settings offer, named as they name it.
    func testSoundAssignmentRuleKeepsKnownEventsAndOfferedSounds() {
        let rule = SettingsPolicy.soundEffectAssignments

        XCTAssertEqual(
            rule.requestedValues(fromConfig: [
                "Play": "glass", "Pause": "none", "Fanfare": "Glass", "Skip Forward": "Pope",
            ]),
            [.play: "Glass", .pause: "None"]
        )
        XCTAssertEqual(rule.validatedConfigValue("PURR"), "Purr")
        XCTAssertNil(rule.validatedConfigValue("Pope"))
        XCTAssertNil(rule.validatedConfigValue(""))
        XCTAssertTrue(rule.names("Where Am I (Start)"))
        XCTAssertFalse(rule.names("where am i (start)"), "event names are case-sensitive")
        XCTAssertEqual(
            rule.fileEntries([.play: "Glass", .whereAmIEnd: "None"]),
            ["Play": "Glass", "Where Am I (End)": "None"]
        )
    }

    /// Shortcuts keep only the actions TextMouth knows, named in any letter
    /// case (FR12), each with a list whose every shortcut can be read,
    /// written the way TextMouth writes them, an empty list being a choice,
    /// an action with no shortcut; with text beginning with "default", kept
    /// as written; or with other text, one shortcut, written as a list.
    func testShortcutRuleKeepsKnownActionsWithReadableEntries() {
        let rule = SettingsPolicy.keyboardShortcuts

        XCTAssertEqual(
            rule.requestedValues(fromConfig: [
                "Where Am I?": ["Option+W"], "Go to Library": [], "Teleport": ["t"], "Play / Pause": ["space", "kk"],
                "go back": "Default: whatever", "Go Forward": "Cmd+]",
            ]),
            [.whereAmI: ["option+w"], .goToLibrary: [], .goBack: "Default: whatever", .goForward: ["command+]"]]
        )
        XCTAssertEqual(rule.validatedConfigValue(["cmd + shift + B", "space"]), ["shift+command+b", "space"])
        XCTAssertEqual(rule.validatedConfigValue("default: w"), "default: w")
        XCTAssertNil(rule.validatedConfigValue(["space", "comand+k"]))
        XCTAssertNil(rule.validatedConfigValue("none"))
        XCTAssertTrue(rule.names("where am i?"), "action names are read in any letter case")
        XCTAssertFalse(rule.names("Teleport"))
        XCTAssertEqual(
            rule.fileEntries([.togglePlayback: "default: space, k", .releaseMediaControls: ["shift+r"]]),
            ["Play / Pause": "default: space, k", "Release Media Controls": ["shift+r"]]
        )
    }

    /// Two entries naming one action, as names read in any letter case can:
    /// the one spelled as Settings names it wins, else the first in sorted
    /// order, whatever order the file holds them in.
    func testShortcutRulePicksOneOfTwoEntriesNamingOneAction() {
        let rule = SettingsPolicy.keyboardShortcuts

        XCTAssertEqual(
            rule.requestedValues(fromConfig: ["where am i?": ["k"], "Where Am I?": ["w"], "WHERE AM I?": ["j"]]),
            [.whereAmI: ["w"]]
        )
        XCTAssertEqual(rule.requestedValues(fromConfig: ["where am i?": ["k"], "WHERE AM I?": ["j"]]), [.whereAmI: ["j"]])
        // The sounds' events are still named exactly.
        XCTAssertFalse(SettingsPolicy.soundEffectAssignments.names("play"))
    }

    // MARK: - Repeated symbols

    /// The repeated-symbol rules match the Repeated Symbols controls: a
    /// picker of three styles, counting by default; a threshold from 2 to 99
    /// with -1 for Never collapse, 4 by default; and a default symbol set
    /// that is already valid.
    func testRepeatedSymbolRulesMatchTheSettingsControls() {
        XCTAssertEqual(SettingsPolicy.repeatedSymbolStyle.defaultValue, .sayCount)
        XCTAssertEqual(SettingsPolicy.repeatedSymbolStyle.allowedRawValues, ["repeat", "count", "omit"])
        let threshold = SettingsPolicy.repeatedSymbolThreshold
        XCTAssertEqual(threshold.range, 2...99)
        XCTAssertEqual(threshold.offValue, -1)
        XCTAssertEqual(threshold.defaultValue, 4)
        let symbols = SettingsPolicy.repeatedSymbolSet
        XCTAssertEqual(symbols.validated(symbols.defaultValue), symbols.defaultValue)
        XCTAssertEqual(Set(symbols.defaultValue), Set("*-=_~#+/\\|<>^&%$@`•◦‣⁃·‐‒–—―…─━═┄┅┈┉╌╍"))
    }

    /// Any negative threshold switches collapsing off, as -1; 0 and 1 act as
    /// 2, the shortest run; anything past 99 is 99.
    func testRepeatedSymbolThresholdSwitchesOffForAnyNegativeAndClampsTheRest() {
        let rule = SettingsPolicy.repeatedSymbolThreshold
        let cases: [(Int, Int)] = [
            (-1, -1), (-2, -1), (Int.min, -1), (0, 2), (1, 2), (2, 2), (4, 4), (57, 57), (99, 99), (100, 99), (Int.max, 99),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(rule.validated(value), expected, "\(value)")
        }
        let numbers: [(Double, Int)] = [
            (3.6, 4), (0.4, 2), (-0.5, -1), (1e308, 99), (-1e308, -1),
            (Double.nan, 4), (Double.infinity, 4), (-Double.infinity, 4),
        ]
        for (value, expected) in numbers {
            XCTAssertEqual(rule.validated(value), expected, "\(value)")
        }
        XCTAssertEqual(rule.supportedDescription, "-1 (off), or 2...99")
    }

    /// The stored threshold reads numbers and numeric text, validated, and
    /// the default for nothing or anything else.
    func testRepeatedSymbolThresholdReadsTheStoreLikeOtherNumbers() {
        let defaults = makeSandboxedPreferences("settings-policy-threshold")
        let rule = SettingsPolicy.repeatedSymbolThreshold

        XCTAssertEqual(rule.storedValue(in: defaults), 4, "missing key")
        let cases: [(Any, Int)] = [
            (7, 7), (-1, -1), (-30, -1), (7.4, 7), (150, 99), ("12", 12), (" 6 ", 6), ("many", 4), (Data([1]), 4),
        ]
        for (stored, expected) in cases {
            defaults.set(stored, forKey: rule.key)
            XCTAssertEqual(rule.storedValue(in: defaults), expected, "\(stored)")
        }
    }

    /// A symbol set keeps punctuation and symbols only, each once, in the
    /// order written: spaces, letters, digits, and repeats are dropped.
    func testRepeatedSymbolSetKeepsEachSymbolOnce() {
        let rule = SettingsPolicy.repeatedSymbolSet

        XCTAssertEqual(rule.validated("* * - * a1 ="), "*-=")
        XCTAssertEqual(rule.validated("~\n~\t#"), "~#")
        XCTAssertEqual(rule.validated(""), "")
        XCTAssertEqual(rule.validated("abc 123"), "")
        XCTAssertEqual(rule.validated("★☆★"), "★☆")
    }

    /// The stored symbol set is the default until one is saved; saved text,
    /// empty text included, is validated; a value that is not text reads as
    /// the default.
    func testRepeatedSymbolSetReadsTheStore() {
        let defaults = makeSandboxedPreferences("settings-policy-symbols")
        let rule = SettingsPolicy.repeatedSymbolSet

        XCTAssertEqual(rule.storedValue(in: defaults), rule.defaultValue, "missing key")
        let cases: [(Any, String)] = [("*=", "*="), ("* = *", "*="), ("", ""), ("xyz", ""), (5, rule.defaultValue)]
        for (stored, expected) in cases {
            defaults.set(stored, forKey: rule.key)
            XCTAssertEqual(rule.storedValue(in: defaults), expected, "\(stored)")
        }
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
