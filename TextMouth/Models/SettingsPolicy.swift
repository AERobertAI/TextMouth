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

    /// Reads this preference straight from `defaults`, as `@AppStorage`
    /// reads it, so a sheet that bypasses the Settings model reads the
    /// global choice (the Playback tab's "When book ends", say) exactly as
    /// Settings does: a missing key, or a stored value that names no case,
    /// yields the default.
    func storedValue(in defaults: UserDefaults) -> Value {
        value(fromRaw: defaults.string(forKey: key))
    }
}

// MARK: - Thresholds that can be switched off

/// Validation rule for a whole-number threshold with one value outside its
/// range that switches the threshold off. The repeated-symbol threshold is
/// one: -1 reads every symbol, and 2 to 99 is the shortest run that is
/// collapsed.
struct ThresholdSettingRule: Sendable {
    /// Key shared by the preferences store and `config.json`.
    let key: String
    /// The thresholds the Settings controls offer.
    let range: ClosedRange<Int>
    /// The value that switches the threshold off; below `range`.
    let offValue: Int
    /// The value used when nothing usable is stored; inside `range`.
    let defaultValue: Int

    /// Creates a rule; `offValue` must lie below `range`, and
    /// `defaultValue` inside it.
    init(key: String, range: ClosedRange<Int>, offValue: Int, defaultValue: Int) {
        assert(offValue < range.lowerBound, "The off value of \(key) must lie below its range")
        assert(range.contains(defaultValue), "The default of \(key) must be a supported value")
        self.key = key
        self.range = range
        self.offValue = offValue
        self.defaultValue = defaultValue
    }

    /// The supported values, for log lines.
    var supportedDescription: String {
        "\(offValue) (off), or \(range.lowerBound)...\(range.upperBound)"
    }

    /// Validates a threshold. Any value at or below `offValue` is the off
    /// value: with an off value of -1, any negative value, as the user who
    /// asked for the repeated-symbol threshold described it ("negative or -1
    /// means always repeat everything"), and with 0, as the feed refresh
    /// interval's, 0 or less. Any other value is clamped into `range`, so a
    /// value between the off value and the range (0 and 1 for the
    /// repeated-symbol threshold, which every run already reaches) acts as
    /// the lowest.
    func validated(_ value: Int) -> Int {
        value <= offValue ? offValue : min(max(value, range.lowerBound), range.upperBound)
    }

    /// Validates a number of any size, such as one `defaults write` stored:
    /// NaN and infinities become `defaultValue`, any number below the whole
    /// number after `offValue` is the off value, and any other number is
    /// rounded and validated like a whole one.
    func validated(_ value: Double) -> Int {
        guard value.isFinite else { return defaultValue }
        guard value >= Double(offValue + 1) else { return offValue }
        // Clamp first, so that no number is too large to become an Int.
        return validated(Int(min(value, Double(range.upperBound)).rounded()))
    }

    /// Reads this preference from `store`, validated: `defaultValue` when
    /// nothing is stored or the stored value is not a number; numeric text
    /// counts as its number, as `@AppStorage` reads it.
    func storedValue(in store: UserDefaults) -> Int {
        switch store.object(forKey: key) {
        case let number as NSNumber:
            return validated(number.doubleValue)
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces)).map { validated($0) } ?? defaultValue
        default:
            return defaultValue
        }
    }
}

// MARK: - Whole numbers without an off value

/// Validation rule for a whole number that is always a setting, with no
/// value that switches anything off: how many of each feed's newest items
/// the "List and download" choice lists or downloads is one (FR11), from 1
/// up. Any value outside `range` is moved to its nearest bound.
///
/// It reads and validates as a `ThresholdSettingRule` whose off value lies
/// just below the range would, with that off value read as the range's
/// lowest value, so both kinds of whole number read the preferences store
/// one way.
struct WholeNumberSettingRule: Sendable {
    /// Key shared by the preferences store and `config.json`.
    let key: String
    /// The values the setting takes.
    let range: ClosedRange<Int>
    /// The value used when nothing usable is stored; inside `range`.
    let defaultValue: Int
    /// The same number read as a threshold whose off value is the whole
    /// number just below `range`, which `validated` lifts to the bottom.
    private let threshold: ThresholdSettingRule

    /// Creates a rule; `defaultValue` must lie inside `range`.
    init(key: String, range: ClosedRange<Int>, defaultValue: Int) {
        self.key = key
        self.range = range
        self.defaultValue = defaultValue
        threshold = ThresholdSettingRule(key: key, range: range, offValue: range.lowerBound - 1, defaultValue: defaultValue)
    }

    /// The supported values, for log lines.
    var supportedDescription: String {
        "\(range.lowerBound)...\(range.upperBound)"
    }

    /// Validates a whole number: clamped into `range`.
    func validated(_ value: Int) -> Int {
        max(threshold.validated(value), range.lowerBound)
    }

    /// Validates a number of any size, such as one `defaults write` stored:
    /// NaN and infinities become `defaultValue`, and any other number is
    /// rounded and clamped into `range`.
    func validated(_ value: Double) -> Int {
        max(threshold.validated(value), range.lowerBound)
    }

    /// Reads this preference from `store`, validated: `defaultValue` when
    /// nothing is stored or the stored value is not a number; numeric text
    /// counts as its number, as `@AppStorage` reads it.
    func storedValue(in store: UserDefaults) -> Int {
        max(threshold.storedValue(in: store), range.lowerBound)
    }
}

// MARK: - Sets of characters

/// Validation rule for a preference holding a set of characters written as
/// text, such as the symbols that form repeated-symbol runs. Only characters
/// `admits` accepts can belong, each once; the text keeps them in the order
/// they were written, so the Settings field shows them as they were typed,
/// less what does not count.
struct CharacterSetSettingRule: Sendable {
    /// Key shared by the preferences store and `config.json`.
    let key: String
    /// The set used until one is saved. Already valid.
    let defaultValue: String
    /// Whether a character may belong to the set.
    let admits: @Sendable (Character) -> Bool

    /// `text` with every character `admits` rejects removed, and every
    /// repeat of a character after its first: "* * - *" becomes "*-".
    func validated(_ text: String) -> String {
        var seen = Set<Character>()
        return String(text.filter { admits($0) && seen.insert($0).inserted })
    }

    /// Reads this preference from `store`, validated: `defaultValue` when
    /// nothing is stored or the stored value is not text. Empty text is a
    /// set like any other, with no characters.
    func storedValue(in store: UserDefaults) -> String {
        guard let text = store.object(forKey: key) as? String else { return defaultValue }
        return validated(text)
    }
}

// MARK: - Preferences keyed by enum cases

/// Validation rule for a preference that gives each case of an enum a value
/// of its own: a sound for each playback event, or the shortcuts of each
/// action.
///
/// `config.json` holds such a preference as an object keyed by the cases'
/// raw values, each value in a readable form (`FileValue`) that the rule
/// reads into the value the app uses (`Value`) and writes back. The file may
/// name any of the cases: each entry replaces its case's value, and a case it
/// leaves out keeps the current one. So does an entry that names no case or
/// holds a value the rule cannot read.
struct KeyedSettingRule<Case, FileValue, Value>: Sendable
where Case: RawRepresentable & Hashable & Sendable, Case.RawValue == String,
      FileValue: Sendable, Value: Sendable {
    /// The `config.json` field.
    let key: String
    /// What the entries may hold, for log lines.
    let supportedDescription: String
    /// The case an entry's name names, or nil when it names none.
    private let caseNamed: @Sendable (String) -> Case?
    /// Reads one entry's value, or returns nil when it is unsupported.
    private let parse: @Sendable (FileValue) -> Value?
    /// Writes one value the way TextMouth saves it.
    private let format: @Sendable (Value) -> FileValue

    /// A rule for the field `key`, reading each entry's value with `parse`
    /// and writing it with `format`. An entry names its case by the case's
    /// raw value exactly, unless `caseNamed` reads names otherwise, as the
    /// shortcuts' rule reads them in any letter case.
    init(
        key: String,
        supportedDescription: String,
        caseNamed: @escaping @Sendable (String) -> Case? = { Case(rawValue: $0) },
        parse: @escaping @Sendable (FileValue) -> Value?,
        format: @escaping @Sendable (Value) -> FileValue
    ) {
        self.key = key
        self.supportedDescription = supportedDescription
        self.caseNamed = caseNamed
        self.parse = parse
        self.format = format
    }

    /// Whether `name` names a case, and so can key an entry.
    func names(_ name: String) -> Bool {
        caseNamed(name) != nil
    }

    /// Validates one entry's value from `config.json`: the value as
    /// TextMouth writes it, or nil when the rule cannot read it.
    func validatedConfigValue(_ value: FileValue) -> FileValue? {
        parse(value).map(format)
    }

    /// The values `config.json`'s entries ask the app to adopt: those of the
    /// entries that name a case and hold a value the rule can read. Should
    /// two entries name one case, as names read in any letter case can, the
    /// one spelled as the case's raw value wins, else the first in sorted
    /// order, so one file always asks for the same values.
    func requestedValues(fromConfig entries: [String: FileValue]) -> [Case: Value] {
        var requested: [Case: Value] = [:]
        for (name, fileValue) in entries.sortedStably(by: { $0.key < $1.key }) {
            guard let named = caseNamed(name), let value = parse(fileValue) else { continue }
            if requested[named] == nil || name == named.rawValue {
                requested[named] = value
            }
        }
        return requested
    }

    /// `values` as `config.json` holds them.
    func fileEntries(_ values: [Case: Value]) -> [String: FileValue] {
        values.mapValues(format).keyedByRawValue
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
    /// How loud sound effects play, from silent (0) to full volume (1)
    /// (Sounds settings slider).
    static let soundEffectsVolume = NumericSettingRule(
        key: "soundEffectsVolume", range: 0...1, defaultValue: 0.5
    )
    /// How soon a second press of a key must follow the first to make a
    /// double press, in seconds (Shortcuts settings stepper, FR12): one time
    /// for every shortcut, from 0.2 to 2 seconds in tenths, and half a
    /// second until the user picks another. The shortcut manager keeps it
    /// (`KeyboardShortcutManager.doublePressTimePreference`), in tenths
    /// (`validatedDoublePressSeconds(_:)`).
    static let shortcutDoublePressSeconds = NumericSettingRule(
        key: "shortcutDoublePressSeconds", range: 0.2...2, defaultValue: 0.5
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
    /// Where the next book opens when listening goes on from one book to
    /// another: in the window the listener is in, or in a new one (Playback
    /// settings pop-up button, 0.2.5).
    static let nextBookWindow = EnumSettingRule(key: "nextBookWindow", defaultValue: NextBookWindow.thisWindow)
    /// Which per-book navigation menus the playback bar shows.
    static let playbackNavigationUnitControlMode = EnumSettingRule(
        key: "playbackNavigationUnitControlMode", defaultValue: PlaybackNavigationUnitControlMode.none
    )
    /// What happens to an original file after import. Stored only in
    /// `config.json`, not in `UserDefaults`.
    static let importDeleteBehavior = EnumSettingRule(
        key: "importDeleteBehavior", defaultValue: ImportDeleteBehavior.keepOriginal
    )

    // MARK: Repeated symbols

    /// How speech reads a run of a repeated symbol (Text settings, Repeated
    /// Symbols picker): as a count until the user picks another style.
    static let repeatedSymbolStyle = EnumSettingRule(
        key: "repeatedSymbolStyle", defaultValue: RepeatedSymbolStyle.sayCount
    )
    /// The fewest symbols a run must have to be read as a count or left out
    /// (Repeated Symbols field and stepper, 2 to 99), or -1 to read every
    /// symbol (the Never collapse checkbox). 4 until the user picks another.
    static let repeatedSymbolThreshold = ThresholdSettingRule(
        key: "repeatedSymbolThreshold", range: 2...99, offValue: -1, defaultValue: 4
    )
    /// The symbols that can form runs (Repeated Symbols field): punctuation
    /// and symbols only, each once.
    ///
    /// The default holds the ASCII symbols that voices read aloud and that
    /// separator lines are made of, and the Unicode bullets, dashes,
    /// ellipsis, and box-drawing lines. It leaves out the sentence
    /// punctuation voices treat as pauses and intonation (. , ! ? ; :),
    /// quotation marks, and brackets: every installed voice reads
    /// "Wait.... What now?" as a pause, so collapsing the run would only add
    /// the words "4 periods". A user who wants them can type them in.
    static let repeatedSymbolSet = CharacterSetSettingRule(
        key: "repeatedSymbolSet",
        defaultValue: "*-=_~#+/\\|<>^&%$@`"
            + "\u{2022}\u{25E6}\u{2023}\u{2043}\u{00B7}"  // • ◦ ‣ ⁃ ·
            + "\u{2010}\u{2012}\u{2013}\u{2014}\u{2015}\u{2026}"  // ‐ ‒ – — ― …
            + "\u{2500}\u{2501}\u{2550}\u{2504}\u{2505}\u{2508}\u{2509}\u{254C}\u{254D}",  // ─ ━ ═ ┄ ┅ ┈ ┉ ╌ ╍
        admits: { RepeatedSymbolRule.canFormRuns($0) }
    )

    // MARK: Feeds (FR03)

    /// Hours between the refreshes of every feed made while TextMouth runs,
    /// from 1 to a week, or 0 to refresh only at launch and when asked. Once
    /// an hour until the listener picks another (the listener's decision of
    /// October 4).
    static let feedRefreshIntervalHours = ThresholdSettingRule(
        key: "feedRefreshIntervalHours", range: 1...168, offValue: 0, defaultValue: 1
    )
    /// How many of each feed's newest entries were kept beside its
    /// downloads, which were always kept: 0 to 2,000, the most a feed's
    /// document is read for (`FeedParser.maximumItems`), or -1 to keep every
    /// entry; 10 until the listener picked another. Retired by the "List and
    /// download" choice (FR11, `feedItems` and `feedNewestCount`), which the
    /// move to the choice reads it for, once
    /// (`FeedSettings.moveToItemPolicyIfNeeded(in:)`).
    static let feedKeepEntries = ThresholdSettingRule(
        key: "feedKeepEntries", range: 0...2_000, offValue: -1, defaultValue: 10
    )
    /// How many days after an episode plays to the end its download is
    /// deleted: 0, at once, to a year, or -1 never. A day until the listener
    /// picks another.
    static let feedDeleteDownloadsDaysAfterPlayed = ThresholdSettingRule(
        key: "feedDeleteDownloadsDaysAfterPlayed", range: 0...365, offValue: -1, defaultValue: 1
    )
    /// The "List and download" choice (FR11): what every feed lists, and
    /// what downloads by itself, unless a feed has a choice of its own
    /// (`Feed.itemPolicyOverride`). Every item listed with the newest
    /// downloaded until the listener picks another (the listener's answer
    /// of October 7).
    static let feedItems = EnumSettingRule(key: "feedItems", defaultValue: FeedItemPolicy.Choice.everyListedNewestDownloaded)
    /// How many of each feed's newest items the "List and download" choice
    /// keeps downloaded, or lists under "Only the newest 5 listed" (FR11):
    /// 1 to 2,000, the most a feed's document is read for
    /// (`FeedParser.maximumItems`). 5 until the listener picks another.
    static let feedNewestCount = WholeNumberSettingRule(key: "feedNewestCount", range: 1...2_000, defaultValue: 5)

    // MARK: Logs

    /// Where the diagnostic logs are written (Storage settings, Logs
    /// picker): inside the data directory until the user picks this Mac's
    /// Logs folder.
    static let logLocation = EnumSettingRule(key: "logLocation", defaultValue: LogLocation.dataDirectory)

    // MARK: Library

    /// What a title's leading article does in the Library's lists (Library
    /// settings, Leading Articles pop-up): part of the title until the user
    /// picks another, so nothing changes until then (November 13, 2026).
    static let leadingArticles = EnumSettingRule(key: "leadingArticles", defaultValue: LeadingArticles.partOfTitle)

    // MARK: Keyed by enum cases

    /// The sound each playback event plays (Sounds settings pickers): one of
    /// the system sounds those pickers offer, named in any letter case and
    /// written as the pickers name it, or None for no sound.
    static let soundEffectAssignments = KeyedSettingRule<SoundEvent, String, String>(
        key: "soundEffectAssignments",
        supportedDescription: "playback events as Settings names them, each with a system sound's name or \"None\"",
        parse: { name in
            SoundEffectService.availableSounds().first { $0.caseInsensitiveCompare(name) == .orderedSame }
        },
        format: { $0 }
    )

    /// The shortcuts of each action (Shortcuts settings, FR12), named as
    /// Settings names the action, in any letter case: a list of shortcuts
    /// written as `KeyBinding.configText` writes them, such as
    /// ["option+shift+command+b"], read whole or not at all, makes the
    /// action the user's; an object holding such a list and the kind of
    /// window it works in, such as {"keys": ["shift+command+t"], "worksIn":
    /// "Every window"}, makes it the user's working there (FR12's branch E);
    /// text beginning with "default" gives it TextMouth's defaults
    /// (`ShortcutListing`). A usable entry is kept as TextMouth writes it;
    /// the record of the user's edits takes it in
    /// (`ShortcutEdits.adopting(_:)`).
    static let keyboardShortcuts = KeyedSettingRule<ShortcutAction, ShortcutListing, ShortcutListing>(
        key: "keyboardShortcuts",
        supportedDescription: "actions as Settings names them, in any letter case, each with a list of shortcuts "
            + "such as [\"shift+command+b\"], an object such as {\"keys\": [\"shift+command+t\"], "
            + "\"worksIn\": \"Every window\"} naming where they work (every window, Library windows, "
            + "or reader windows), or text beginning with \"default\"",
        caseNamed: { ShortcutAction.named($0) },
        parse: { $0.validated },
        format: { $0 }
    )

    // MARK: Integer

    /// Minutes a sleep timer can run: the range of the custom-duration
    /// stepper in the sleep timer sheet.
    static let sleepTimerMinutes: ClosedRange<Int> = 1...480
}

// MARK: - The double-press time

extension SettingsPolicy {
    /// The double-press time's step, as tenths in a second: the Shortcuts
    /// tab's stepper moves it a tenth of a second at a time.
    static let shortcutDoublePressTenthsPerSecond = 10.0

    /// `seconds` as a double-press time (FR12): validated by
    /// `shortcutDoublePressSeconds`, so a value out of range moves to the
    /// nearest bound, then moved to the nearest tenth of a second, so the
    /// store and config.json hold 0.3, never 0.30000000000000004 or 0.75.
    static func validatedDoublePressSeconds(_ seconds: Double) -> Double {
        let tenths = (shortcutDoublePressSeconds.validated(seconds) * shortcutDoublePressTenthsPerSecond).rounded()
        return tenths / shortcutDoublePressTenthsPerSecond
    }
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
