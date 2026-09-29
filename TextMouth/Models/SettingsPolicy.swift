import Foundation

// MARK: - Numeric preferences

/// Validation rule for one numeric preference that can change outside the
/// Settings window: by editing `config.json`, with `defaults write`, or by
/// another version of TextMouth.
///
/// The Settings controls only produce values inside `range`, but every other
/// path hands stored values over as they are. Each path that reads one of
/// these preferences (decoding `config.json`, applying it, the `@AppStorage`
/// read path, and services that read `UserDefaults` directly) passes the value
/// through its rule, so an unsupported value never reaches playback code or a
/// label that converts it to an integer.
struct NumericSettingRule: Sendable {
    /// Key shared by `UserDefaults` (`@AppStorage`) and `config.json`.
    let key: String
    /// Values the Settings controls can produce.
    let range: ClosedRange<Double>
    /// Value used when nothing usable is stored. Always inside `range`.
    let defaultValue: Double
    /// The value meaning "not chosen yet" rather than a setting. Only speed
    /// and pitch have one (0): early config files were written before the
    /// user chose either, and the speech engine has always read a stored 0
    /// as unset. In `config.json` it keeps the app's current preference;
    /// read from the preferences store it yields `defaultValue`.
    let unsetValue: Double?

    /// Creates a rule. `unsetValue` is nil for preferences whose stored
    /// value is always a real setting.
    init(key: String, range: ClosedRange<Double>, defaultValue: Double, unsetValue: Double? = nil) {
        assert(range.contains(defaultValue), "The default of \(key) must be a supported value")
        self.key = key
        self.range = range
        self.defaultValue = defaultValue
        self.unsetValue = unsetValue
    }

    /// What `config.json` holds when this field is missing or unreadable.
    var configDefault: Double { unsetValue ?? defaultValue }

    /// The supported values, for log lines.
    var supportedDescription: String { "\(range.lowerBound)...\(range.upperBound)" }

    /// Validates a value from the preferences store, or one about to be
    /// stored. The unset value and non-finite values (NaN and infinities
    /// carry no usable magnitude, the reasoning `AudioSpeed.normalized(_:)`
    /// also follows) become `defaultValue`; any other value is clamped to
    /// the nearest bound of `range`.
    func validated(_ value: Double) -> Double {
        guard value.isFinite, value != unsetValue else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Validates a number from `config.json`. The unset value passes through
    /// unchanged, a non-finite value becomes `configDefault` as if the field
    /// were missing, and any other value is clamped.
    func validatedConfigValue(_ value: Double) -> Double {
        guard value.isFinite else { return configDefault }
        if let unsetValue, value == unsetValue { return unsetValue }
        return validated(value)
    }

    /// The validated preference a `config.json` value asks the app to adopt,
    /// or nil when the value means "not chosen yet".
    func requestedValue(fromConfig value: Double) -> Double? {
        let validated = validatedConfigValue(value)
        return validated == unsetValue ? nil : validated
    }

    /// Reads this preference straight from `defaults`, validated. Services
    /// that bypass `@AppStorage` use this so they interpret a stored value
    /// exactly as the Settings model does: a missing key yields the default,
    /// and anything present is read the way `@AppStorage` reads it (numeric
    /// text parses, any other non-number reads as 0) and then validated.
    func storedValue(in defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return validated(defaults.double(forKey: key))
    }
}

// MARK: - Enum-backed preferences

/// Validation rule for a preference stored as the raw value of an enum. The
/// enum's cases are the complete list of allowed raw values, so a new case
/// extends the rule automatically.
struct EnumSettingRule<Value>: Sendable
where Value: RawRepresentable & CaseIterable & Sendable, Value.RawValue == String {
    /// Key shared by `UserDefaults` (`@AppStorage`) and `config.json`.
    let key: String
    /// Case used when the stored raw value is missing or unsupported.
    let defaultValue: Value

    /// Every raw value the preference accepts, in declaration order.
    var allowedRawValues: [String] { Value.allCases.map(\.rawValue) }

    /// The supported values, for log lines.
    var supportedDescription: String {
        allowedRawValues.map { String(reflecting: $0) }.joined(separator: ", ")
    }

    /// The case stored as `rawValue`, or `defaultValue` when the raw value is
    /// missing or names no case.
    func value(fromRaw rawValue: String?) -> Value {
        rawValue.flatMap(Value.init(rawValue:)) ?? defaultValue
    }

    /// Validates a raw value from `config.json`, where an empty string means
    /// "not chosen yet". An unsupported value is treated the same way, so
    /// applying the file keeps the app's current choice.
    func validatedConfigRawValue(_ rawValue: String) -> String {
        Value(rawValue: rawValue) == nil ? "" : rawValue
    }

    /// The case a `config.json` raw value asks the app to adopt, or nil when
    /// the value is empty or unsupported.
    func requestedValue(fromConfig rawValue: String) -> Value? {
        Value(rawValue: rawValue)
    }
}

// MARK: - The table

/// The single table of validated preferences. Each rule states a key, the
/// supported values, and the default; the numeric ranges are exactly those of
/// the controls in the Settings window.
enum SettingsPolicy {
    // MARK: Numeric

    /// Global speech speed in words per minute (Voice settings slider).
    static let wordsPerMinute = NumericSettingRule(
        key: "wordsPerMinute", range: 50...650, defaultValue: 200, unsetValue: 0
    )
    /// Global pitch multiplier; 1 is normal (Voice settings slider).
    static let pitchMultiplier = NumericSettingRule(
        key: "pitchMultiplier", range: 0.5...2.0, defaultValue: 1.0, unsetValue: 0
    )
    /// Seconds a pause must last before smart rewind-on-resume rewinds
    /// (Playback settings stepper).
    static let rewindSmartThreshold = NumericSettingRule(
        key: "rewindSmartThreshold", range: 5...600, defaultValue: 70
    )
    /// Seconds the sleep timer fades out; 0 pauses instantly (Playback
    /// settings stepper).
    static let sleepFadeOutDuration = NumericSettingRule(
        key: "sleepFadeOutDuration", range: 0...10, defaultValue: 0
    )
    /// Punctuation pause level: 0 off, 1 subtle, 2 moderate, 3 heavy
    /// (Playback settings slider).
    static let punctuationPauseLevel = NumericSettingRule(
        key: "punctuationPauseLevel", range: 0...3, defaultValue: 0
    )
    /// Seconds to ignore media commands after a Bluetooth device disconnects
    /// (Miscellaneous settings slider).
    static let bluetoothDisconnectDelay = NumericSettingRule(
        key: "bluetoothDisconnectDelay", range: 1...10, defaultValue: 2
    )
    /// Seconds allowed for the whole restart-timer media gesture
    /// (Miscellaneous settings slider).
    static let restartTimerGestureWindow = NumericSettingRule(
        key: "restartTimerGestureWindow", range: 0.5...10, defaultValue: 2
    )

    // MARK: Enum-backed

    /// Skip forward unit (Playback settings picker).
    static let skipForwardUnit = EnumSettingRule(key: "skipForwardUnit", defaultValue: SkipUnit.seconds15)
    /// Skip backward unit (Playback settings picker).
    static let skipBackwardUnit = EnumSettingRule(key: "skipBackwardUnit", defaultValue: SkipUnit.seconds15)
    /// Shift+skip forward unit (Playback settings picker).
    static let shiftSkipForwardUnit = EnumSettingRule(key: "shiftSkipForwardUnit", defaultValue: SkipUnit.seconds30)
    /// Shift+skip backward unit (Playback settings picker).
    static let shiftSkipBackwardUnit = EnumSettingRule(key: "shiftSkipBackwardUnit", defaultValue: SkipUnit.seconds30)
    /// Unit to rewind to when playback resumes (Playback settings picker).
    static let rewindOnResumeUnit = EnumSettingRule(key: "rewindOnResumeUnit", defaultValue: RewindUnit.none)
    /// What happens when a book ends (Playback settings picker).
    static let endOfBookBehavior = EnumSettingRule(key: "endOfBookBehavior", defaultValue: EndOfBookBehavior.stop)
    /// Which per-book navigation menus the playback bar shows.
    static let playbackNavigationUnitControlMode = EnumSettingRule(
        key: "playbackNavigationUnitControlMode", defaultValue: PlaybackNavigationUnitControlMode.none
    )
    /// What happens to an original file after import. Stored only in
    /// `config.json`, not in `UserDefaults`.
    static let importDeleteBehavior = EnumSettingRule(
        key: "importDeleteBehavior", defaultValue: ImportDeleteBehavior.keepOriginal
    )

    // MARK: Integer

    /// Minutes a sleep timer can run: the range of the custom-duration
    /// stepper in the sleep timer sheet.
    static let sleepTimerMinutes: ClosedRange<Int> = 1...480
}

// MARK: - Saved book state

extension SettingsPolicy {
    /// Names saved book data (`library.json` and `bookInfo.json`) in log lines.
    static let bookStateSource = "saved book state"

    /// Validates a per-book speed saved in `localWPM`, or returns nil when the
    /// value cannot be a speed, so the book follows the global setting (normal
    /// speed for an audio book). Text books store words per minute, clamped
    /// like the global speed; audio books store a playback multiplier, which
    /// `AudioSpeed.normalized(_:)` clamps and snaps exactly as the reader and
    /// player do.
    static func validatedLocalSpeed(_ value: Double, isAudio: Bool) -> Double? {
        guard let speed = usableLocalSpeed(value) else { return nil }
        return isAudio ? AudioSpeed.normalized(speed) : wordsPerMinute.validated(speed)
    }

    /// The format-independent part of `validatedLocalSpeed(_:isAudio:)`: NaN,
    /// infinities, zero, and negative values cannot be a speed of either kind.
    /// Used where the book's format is not known yet.
    static func usableLocalSpeed(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    /// Validates a per-book pitch: clamped to the global pitch range, or nil
    /// (follow the global pitch) when the value cannot be a pitch.
    static func validatedLocalPitch(_ value: Double) -> Double? {
        guard value.isFinite, value > 0 else { return nil }
        return pitchMultiplier.validated(value)
    }

    /// Chapter and heading indices and character offsets count from 0, so a
    /// negative one becomes 0. A value past the end of the content is left for
    /// the reader, which clamps it against the loaded text.
    static func validatedPosition(_ value: Int) -> Int {
        max(0, value)
    }

    /// Word and character counts cannot be negative. A negative count is
    /// dropped, leaving the book in the same state as one not yet measured.
    static func validatedCount(_ value: Int) -> Int? {
        value >= 0 ? value : nil
    }
}
