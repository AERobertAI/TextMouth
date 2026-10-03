import Foundation
import Combine

/// A single text substitution rule.
struct SubstitutionRule: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var pattern: String
    var replacement: String  // Empty string = skip/delete the match
    var isRegex: Bool
    var isEnabled: Bool
    var caseSensitive: Bool
    /// When true (and the rule is plain text, and the pattern contains no
    /// whitespace), the match must not be adjacent to a letter, digit, or
    /// underscore on either side. This is the "Match whole word only"
    /// behaviour from find/replace dialogs — useful for pronunciation
    /// rules where the pattern itself may be a non-word character (e.g.
    /// OCR'd "|" → "I"), so standard regex `\b` is not sufficient.
    /// The stored value is preserved across edits; whether it actually
    /// affects matching is gated by `isWholeWordEffective`.
    var wholeWord: Bool

    init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String,
        replacement: String = "",
        isRegex: Bool = false,
        isEnabled: Bool = true,
        caseSensitive: Bool = false,
        wholeWord: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.isEnabled = isEnabled
        self.caseSensitive = caseSensitive
        self.wholeWord = wholeWord
    }

    /// Decode with backward compatibility — older rule files (and the
    /// seeded defaults from previous app versions) don't carry the
    /// `wholeWord` key, so missing means false.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        pattern = try container.decode(String.self, forKey: .pattern)
        replacement = try container.decode(String.self, forKey: .replacement)
        isRegex = try container.decode(Bool.self, forKey: .isRegex)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        caseSensitive = try container.decode(Bool.self, forKey: .caseSensitive)
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? false
    }

    /// Whether the wholeWord setting actually influences matching for
    /// this rule's current configuration. The UI uses the same predicate
    /// to decide when to show the toggle and the badge, so the displayed
    /// state stays consistent with behaviour.
    /// - Regex rules use `\b` directly in the pattern; the toggle is N/A.
    /// - Patterns with internal whitespace are treated as phrases for
    ///   which a single "word" boundary doesn't make sense.
    /// - Empty patterns are skipped at the matcher level anyway.
    var isWholeWordEffective: Bool {
        wholeWord
            && !isRegex
            && !pattern.isEmpty
            && !pattern.contains(where: { $0.isWhitespace })
    }
}

/// One step up or down in the ordered rule list. Rules apply from the top
/// down, so moving a rule up makes it apply earlier.
enum SubstitutionRuleMoveDirection {
    case up
    case down

    /// The index one step from `index` in a list of `count` rules, or nil
    /// when there is no such step: the rule is already first (moving up) or
    /// last (moving down), or `index` is not a position in the list.
    func destination(from index: Int, count: Int) -> Int? {
        // Check `index` first so the step below can never overflow.
        guard index >= 0, index < count else { return nil }
        let destination = self == .up ? index - 1 : index + 1
        return destination >= 0 && destination < count ? destination : nil
    }
}

/// Result of applying substitutions: modified text + bidirectional offset mapping.
/// Uses OffsetMap internally for offset conversion, and exposes it for pipeline composition.
struct TextTransformation {
    let originalText: String
    let modifiedText: String
    /// The offset map for this substitution stage (modified↔original).
    /// Exposed so it can be composed with other pipeline stages.
    let offsetMap: ComposedOffsetMap

    /// Each rule works in the previous rule's output coordinates. Retain the
    /// stages so subsequent edits cannot invalidate earlier breakpoints.
    init(originalText: String, modifiedText: String, offsetMaps: [OffsetMap]) {
        self.originalText = originalText
        self.modifiedText = modifiedText
        self.offsetMap = ComposedOffsetMap(stages: offsetMaps)
    }

    /// Identity transformation (no changes).
    static func identity(_ text: String) -> TextTransformation {
        TextTransformation(originalText: text, modifiedText: text, offsetMaps: [])
    }

    /// Convert an offset in the modified text to the corresponding offset in the original text.
    func toOriginalOffset(_ modified: Int) -> Int {
        offsetMap.toOriginal(modified)
    }

    /// Convert an offset in the original text to the corresponding offset in the modified text.
    func toModifiedOffset(_ original: Int) -> Int {
        offsetMap.toModified(original)
    }

    var hasChanges: Bool { originalText != modifiedText }
}

/// Manages text substitution rules and applies them to text before TTS.
///
/// It also keeps the repeated-symbol settings (Text settings, Repeated
/// Symbols), which speech preparation applies just before the punctuation
/// pauses and these rules; see `repeatedSymbolRule`.
@MainActor
final class TextSubstitutionService: ObservableObject {
    @Published var rules: [SubstitutionRule] = []
    /// Whether the rules apply at all. A change made here is saved to the
    /// preferences store; a change made there by anyone else, such as the
    /// settings model applying an edit of config.json, is taken up here at
    /// once, and published, so open readers prepare their speech again.
    @Published var isEnabled: Bool = true {
        didSet { save(isEnabled, as: Self.enabledPreference) }
    }

    /// How speech reads a run of a repeated symbol. Saved and followed in
    /// the preferences store exactly as `isEnabled` is, and independent of
    /// it: switching the substitution rules off leaves this setting alone.
    @Published var repeatedSymbolStyle: RepeatedSymbolStyle {
        didSet { save(repeatedSymbolStyle, as: Self.repeatedSymbolStylePreference) }
    }

    /// The fewest symbols a run must have to be read as a count or left
    /// out, from 2 to 99, or -1 to read every symbol. A value set here is
    /// validated first, as `SettingsPolicy.repeatedSymbolThreshold` reads a
    /// stored one, then saved and followed like `isEnabled`; setting the
    /// value already in force publishes and saves nothing.
    var repeatedSymbolThreshold: Int {
        get { storedRepeatedSymbolThreshold }
        set {
            let validated = SettingsPolicy.repeatedSymbolThreshold.validated(newValue)
            guard validated != storedRepeatedSymbolThreshold else { return }
            storedRepeatedSymbolThreshold = validated
        }
    }

    /// The symbols that can form runs, each once, in the order the user
    /// listed them. A value set here keeps only its punctuation and symbols,
    /// each once, then is saved and followed like `isEnabled`; setting the
    /// set already in force publishes and saves nothing.
    var repeatedSymbolSet: String {
        get { storedRepeatedSymbolSet }
        set {
            let validated = SettingsPolicy.repeatedSymbolSet.validated(newValue)
            guard validated != storedRepeatedSymbolSet else { return }
            storedRepeatedSymbolSet = validated
        }
    }

    /// The validated threshold; use `repeatedSymbolThreshold`. Validation
    /// happens in that setter because a published property's own observer
    /// runs again when it assigns the property, so clamping there would
    /// publish twice.
    @Published private var storedRepeatedSymbolThreshold: Int {
        didSet { save(storedRepeatedSymbolThreshold, as: Self.repeatedSymbolThresholdPreference) }
    }

    /// The validated symbol set; use `repeatedSymbolSet`.
    @Published private var storedRepeatedSymbolSet: String {
        didSet { save(storedRepeatedSymbolSet, as: Self.repeatedSymbolSetPreference) }
    }

    /// The repeated-symbol settings in force, as speech preparation applies
    /// them. Built afresh from the three settings each time, so a reader
    /// preparing its next chapter always uses the current ones.
    var repeatedSymbolRule: RepeatedSymbolRule {
        RepeatedSymbolRule(style: repeatedSymbolStyle, threshold: repeatedSymbolThreshold, symbols: repeatedSymbolSet)
    }

    /// The substitution switch in the preferences store: on until the user
    /// turns it off. Every release has used its key, so the choice keeps
    /// loading; the settings model mirrors it in config.json through this
    /// same definition.
    nonisolated static let enabledPreference = StoredPreference.flag("substitutionsEnabled", default: true)

    /// The repeated-symbol style in the preferences store, saved as its raw
    /// value ("repeat", "count", or "omit"); `SettingsPolicy` supplies the
    /// key and the default, which an unsupported value also reads as.
    nonisolated static let repeatedSymbolStylePreference = StoredPreference<RepeatedSymbolStyle>(
        key: SettingsPolicy.repeatedSymbolStyle.key,
        read: { store, key in SettingsPolicy.repeatedSymbolStyle.value(fromRaw: store.object(forKey: key) as? String) },
        write: { style, store, key in store.set(style.rawValue, forKey: key) }
    )

    /// The repeated-symbol threshold in the preferences store, saved as a
    /// whole number and read through `SettingsPolicy.repeatedSymbolThreshold`.
    nonisolated static let repeatedSymbolThresholdPreference = StoredPreference<Int>(
        key: SettingsPolicy.repeatedSymbolThreshold.key,
        read: { store, _ in SettingsPolicy.repeatedSymbolThreshold.storedValue(in: store) },
        write: { threshold, store, key in
            store.set(SettingsPolicy.repeatedSymbolThreshold.validated(threshold), forKey: key)
        }
    )

    /// The repeated-symbol set in the preferences store, saved as text and
    /// read through `SettingsPolicy.repeatedSymbolSet`.
    nonisolated static let repeatedSymbolSetPreference = StoredPreference<String>(
        key: SettingsPolicy.repeatedSymbolSet.key,
        read: { store, _ in SettingsPolicy.repeatedSymbolSet.storedValue(in: store) },
        write: { symbols, store, key in store.set(SettingsPolicy.repeatedSymbolSet.validated(symbols), forKey: key) }
    )

    /// The keys of every preference this service keeps: the substitution
    /// switch and the three repeated-symbol settings. The settings model
    /// mirrors them all in config.json.
    nonisolated static var preferenceKeys: [String] {
        [
            enabledPreference.key,
            repeatedSymbolStylePreference.key,
            repeatedSymbolThresholdPreference.key,
            repeatedSymbolSetPreference.key,
        ]
    }

    /// The store this service's preferences are saved to and followed in:
    /// this process's preferences for the app's shared service, and for a
    /// test's own service only a store the test passes. Nil saves and
    /// follows nothing.
    private let preferences: UserDefaults?
    /// Reports changes to this service's preferences in `preferences`.
    private var storeObserver: PreferenceObserver?
    /// True while the service takes values from the store, which already
    /// holds them, so nothing is written back.
    private var isFollowingStore = false

    /// Cached compiled regexes keyed by rule ID
    private var regexCache: [UUID: NSRegularExpression] = [:]

    /// Cached compiled regexes for whole-word rules. Kept separate from
    /// `regexCache` because the underlying pattern is different (the
    /// stored pattern wrapped with Unicode-aware lookarounds), and we
    /// don't want a regex-mode rule's compiled form to be reused if the
    /// user toggles it through plain+wholeWord and back.
    private var wholeWordRegexCache: [UUID: NSRegularExpression] = [:]

    /// Whether the rules in use only stand in for substitutions.json, left
    /// unread because the library model found the data directory unavailable
    /// (FR02); they are replaced by the file's once the library is back.
    private(set) var rulesAwaitDataDirectory = false
    /// Hears when the data directory is available again.
    private var availabilitySubscription: AnyCancellable?

    static let shared = TextSubstitutionService()

    /// The app's service: `isEnabled` and the repeated-symbol settings from
    /// this process's preferences, which it then follows, and the rules from
    /// substitutions.json, read again when the data directory comes back
    /// after it was unavailable.
    private init() {
        let preferences = TextMouthRuntime.current.preferences
        self.preferences = preferences
        isEnabled = Self.storedIsEnabled(in: preferences)
        repeatedSymbolStyle = Self.repeatedSymbolStylePreference.read(from: preferences)
        storedRepeatedSymbolThreshold = Self.repeatedSymbolThresholdPreference.read(from: preferences)
        storedRepeatedSymbolSet = Self.repeatedSymbolSetPreference.read(from: preferences)
        loadRules()
        followStore(in: preferences)
        availabilitySubscription = NotificationCenter.default
            .publisher(for: .dataDirectoryDidBecomeAvailable)
            .sink { [weak self] _ in self?.dataDirectoryBecameAvailable() }
    }

    /// A service of the caller's own: for deterministic production-target
    /// tests, and for the rule editor's Test button, which shows what one
    /// rule does. It deliberately does not read or write the persisted rule
    /// file. Given a store, it saves and follows its preferences only there,
    /// reading the repeated-symbol settings from it; without one, it saves
    /// nothing and starts from the standard repeated-symbol settings, so
    /// changing a setting leaves nothing behind.
    init(
        rules: [SubstitutionRule],
        isEnabled: Bool = true,
        preferences: UserDefaults? = nil
    ) {
        self.preferences = preferences
        self.rules = rules
        self.isEnabled = isEnabled
        let standard = RepeatedSymbolRule.standard
        repeatedSymbolStyle = preferences.map { Self.repeatedSymbolStylePreference.read(from: $0) } ?? standard.style
        storedRepeatedSymbolThreshold = preferences.map { Self.repeatedSymbolThresholdPreference.read(from: $0) }
            ?? standard.threshold
        storedRepeatedSymbolSet = preferences.map { Self.repeatedSymbolSetPreference.read(from: $0) } ?? standard.symbols
        if let preferences {
            followStore(in: preferences)
        }
    }

    /// Whether substitutions are on as `preferences` records it: on unless
    /// the user turned them off.
    static func storedIsEnabled(in preferences: UserDefaults) -> Bool {
        enabledPreference.read(from: preferences)
    }

    /// Takes up each change to this service's preferences in `preferences`
    /// from then on.
    private func followStore(in preferences: UserDefaults) {
        storeObserver = PreferenceObserver(keys: Self.preferenceKeys, in: preferences) { [weak self] _ in
            self?.takePreferencesFromStore()
        }
    }

    /// Sets each preference to the store's value where someone else changed
    /// it there, writing nothing back. A preference that did not change is
    /// not set, so it publishes nothing.
    private func takePreferencesFromStore() {
        guard let preferences else { return }
        isFollowingStore = true
        defer { isFollowingStore = false }
        adopt(Self.enabledPreference, into: \.isEnabled, from: preferences)
        adopt(Self.repeatedSymbolStylePreference, into: \.repeatedSymbolStyle, from: preferences)
        adopt(Self.repeatedSymbolThresholdPreference, into: \.repeatedSymbolThreshold, from: preferences)
        adopt(Self.repeatedSymbolSetPreference, into: \.repeatedSymbolSet, from: preferences)
    }

    /// Sets the property at `keyPath` to `preference`'s value in `store`
    /// when the two differ.
    private func adopt<Value>(
        _ preference: StoredPreference<Value>,
        into keyPath: ReferenceWritableKeyPath<TextSubstitutionService, Value>,
        from store: UserDefaults
    ) {
        let stored = preference.read(from: store)
        if self[keyPath: keyPath] != stored {
            self[keyPath: keyPath] = stored
        }
    }

    /// Saves a preference changed through this service to the store, unless
    /// the change came from the store or the service keeps no store.
    private func save<Value>(_ value: Value, as preference: StoredPreference<Value>) {
        guard !isFollowingStore, let preferences else { return }
        preference.write(value, to: preferences)
    }

    // MARK: - Rule Management

    func addRule(_ rule: SubstitutionRule) {
        rules.append(rule)
        invalidateCache(for: rule.id)
        saveRules()
    }

    func updateRule(_ rule: SubstitutionRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            invalidateCache(for: rule.id)
            saveRules()
        }
    }

    func removeRule(id: UUID) {
        rules.removeAll { $0.id == id }
        regexCache.removeValue(forKey: id)
        wholeWordRegexCache.removeValue(forKey: id)
        saveRules()
    }

    func toggleRule(id: UUID) {
        if let index = rules.firstIndex(where: { $0.id == id }) {
            rules[index].isEnabled.toggle()
            saveRules()
        }
    }

    func moveRule(from source: IndexSet, to destination: Int) {
        rules.move(fromOffsets: source, toOffset: destination)
        saveRules()
    }

    /// Move the rule with `id` one step up or down and save the new order.
    ///
    /// One step swaps the rule with its neighbour, so every other rule keeps
    /// its place. Nothing changes, and nothing is saved, when the rule is
    /// unknown or already at that end of the list.
    ///
    /// - Returns: The rule's new index, or nil when it did not move.
    @discardableResult
    func moveRule(id: UUID, direction: SubstitutionRuleMoveDirection) -> Int? {
        guard let index = rules.firstIndex(where: { $0.id == id }),
              let destination = direction.destination(from: index, count: rules.count) else {
            return nil
        }
        rules.swapAt(index, destination)
        saveRules()
        return destination
    }

    // MARK: - Text Transformation

    /// Apply all enabled rules to the text, returning the modified text and an offset mapping.
    func transform(_ text: String) -> TextTransformation {
        guard isEnabled else { return .identity(text) }

        let enabledRules = rules.filter { $0.isEnabled && !$0.pattern.isEmpty }
        guard !enabledRules.isEmpty else { return .identity(text) }

        // Apply rules sequentially and compose their coordinate maps. Sorting
        // all rules' breakpoints together mixes different intermediate texts.
        var current = text
        var stages: [OffsetMap] = []

        for rule in enabledRules {
            // Only map replacements that can actually be applied to this
            // string; an invalid Unicode range must not shift later offsets.
            let replacements = findReplacements(in: current, rule: rule).filter {
                Range($0.range, in: current) != nil
            }
            guard !replacements.isEmpty else { continue }

            // Track offset shifts from this rule's replacements (in forward order)
            var shift = 0
            var totalDelta = 0
            var points: [(targetPos: Int, cumulativeDelta: Int)] = []
            for rep in replacements {
                let adjustedStart = rep.range.location + shift
                let replacementLength = rep.replacement.utf16Length
                let lenDiff = rep.range.length - replacementLength
                totalDelta += lenDiff
                let afterInModified = adjustedStart + replacementLength
                points.append((targetPos: afterInModified, cumulativeDelta: totalDelta))
                shift -= lenDiff
            }

            // Apply replacements in reverse order so indices stay valid.
            // NSRegularExpression returns ranges in UTF-16 code units, while
            // `String.index(_:offsetBy:)` walks `Character` (grapheme
            // clusters). Using offsetBy on an NSRange would crash on any
            // text containing emoji or other surrogate-pair characters
            // (e.g. "🙂 cat"). Range(_:in:) handles the unit conversion.
            // If the conversion fails (would be a regex bug), skip the
            // replacement rather than crash.
            var newText = current
            for rep in replacements.reversed() {
                guard let stringRange = Range(rep.range, in: newText) else { continue }
                newText.replaceSubrange(stringRange, with: rep.replacement)
            }
            current = newText
            stages.append(OffsetMap(points: points))
        }

        return TextTransformation(originalText: text, modifiedText: current, offsetMaps: stages)
    }

    // MARK: - Pattern Matching

    private struct Replacement {
        let range: NSRange
        let replacement: String
    }

    private func findReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        if rule.isRegex {
            return findRegexReplacements(in: text, rule: rule)
        }
        if rule.isWholeWordEffective {
            return findWholeWordReplacements(in: text, rule: rule)
        }
        return findPlainReplacements(in: text, rule: rule)
    }

    private func findPlainReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        var results: [Replacement] = []
        let nsText = text as NSString
        let fullLength = nsText.length
        let options: NSString.CompareOptions = rule.caseSensitive ? [] : [.caseInsensitive]
        var remaining = NSRange(location: 0, length: fullLength)

        while remaining.length > 0 {
            let match = nsText.range(of: rule.pattern, options: options, range: remaining)
            guard match.location != NSNotFound else { break }
            results.append(Replacement(range: match, replacement: rule.replacement))
            let nextLocation = NSMaxRange(match)
            remaining = NSRange(location: nextLocation, length: fullLength - nextLocation)
        }
        return results
    }

    private func findRegexReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        guard let regex = compiledRegex(for: rule) else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        return matches.map { match in
            // Expand group references (\1, \2, etc.) in the replacement template
            let expanded = regex.replacementString(for: match, in: text, offset: 0, template: rule.replacement)
            return Replacement(range: match.range, replacement: expanded)
        }
    }

    /// Whole-word matching for plain (non-regex) rules. The user-supplied
    /// pattern is treated as literal text and wrapped with Unicode-aware
    /// lookarounds so the match is rejected when adjacent to a letter,
    /// digit, combining mark, or underscore.
    ///
    /// `\p{L}` is any Unicode letter (covers accented characters, CJK,
    /// etc.), `\p{N}` is any Unicode number, `\p{M}` is any combining
    /// mark — included so a base letter followed by a separately-encoded
    /// diacritic is treated as one word, not as a letter followed by
    /// punctuation. Plain `\b` would NOT work here because patterns like
    /// "|" are non-word characters, so a regex word boundary doesn't
    /// apply to them. The lookarounds work for both word and non-word
    /// patterns.
    ///
    /// Replacement is taken literally — no `$1`/`\1` group expansion,
    /// matching the behaviour of the existing plain-text path.
    private func findWholeWordReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        guard let regex = wholeWordRegex(for: rule) else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, range: fullRange)

        // Use the literal replacement string. Escape any regex metacharacters
        // in the user's replacement before handing it to NSRegularExpression's
        // template-expansion engine, otherwise a `$` or `\` in a pronunciation
        // replacement would be interpreted as a back-reference and either
        // silently disappear or throw at runtime.
        let escapedReplacement = NSRegularExpression.escapedTemplate(for: rule.replacement)
        return matches.map { match in
            let expanded = regex.replacementString(
                for: match,
                in: text,
                offset: 0,
                template: escapedReplacement
            )
            return Replacement(range: match.range, replacement: expanded)
        }
    }

    /// Compile (and cache) the lookaround-wrapped regex for a whole-word
    /// rule. Builds the pattern from the rule's literal text via
    /// `escapedPattern(for:)` so regex metacharacters in the user's input
    /// are taken literally.
    private func wholeWordRegex(for rule: SubstitutionRule) -> NSRegularExpression? {
        if let cached = wholeWordRegexCache[rule.id] { return cached }
        let escaped = NSRegularExpression.escapedPattern(for: rule.pattern)
        let wrapped = "(?<![\\p{L}\\p{N}\\p{M}_])\(escaped)(?![\\p{L}\\p{N}\\p{M}_])"
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: wrapped, options: options) else { return nil }
        wholeWordRegexCache[rule.id] = regex
        return regex
    }

    private func compiledRegex(for rule: SubstitutionRule) -> NSRegularExpression? {
        if let cached = regexCache[rule.id] { return cached }
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: options) else { return nil }
        regexCache[rule.id] = regex
        return regex
    }

    private func invalidateCache(for id: UUID) {
        regexCache.removeValue(forKey: id)
        wholeWordRegexCache.removeValue(forKey: id)
    }

    // MARK: - Persistence

    /// Writes the rules to the substitutions file. A failure is reported to
    /// the failure center with a retry that saves the rules as they are
    /// then, and the next save that succeeds settles it (TODO S09).
    func saveRules() {
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)
            try data.write(to: TextMouthPaths.substitutionsFile, options: .atomic)
            PersistenceFailureCenter.shared.recordSuccess(.substitutions)
        } catch {
            print("Failed to save substitutions: \(error)")
            PersistenceFailureCenter.shared.recordFailure(
                .substitutions,
                path: TextMouthPaths.substitutionsFile.path,
                error: error
            ) { [weak self] _ in
                self?.saveRules()
            }
        }
    }

    func loadRules() {
        // Nothing is read from a data directory the library model found
        // unavailable, and a file missing there is no first launch (FR02):
        // the standard rules stand in, unsaved, until the library is back.
        guard !TextMouthPaths.isDataDirectoryUnavailable else {
            rules = Self.defaultRules
            rulesAwaitDataDirectory = true
            return
        }
        rulesAwaitDataDirectory = false
        let url = TextMouthPaths.substitutionsFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            // First launch: install default rules
            rules = Self.defaultRules
            saveRules()
            return
        }
        do {
            let data = try Data(contentsOf: url)
            rules = try JSONDecoder().decode([SubstitutionRule].self, from: data)
        } catch {
            print("Failed to load substitutions: \(error)")
            rules = Self.defaultRules
        }
    }

    /// Reads substitutions.json once the data directory is back, when the
    /// rules in use only stood in for it (FR02). Changes made to the
    /// stand-ins meanwhile are dropped, with their unsaved-change notice:
    /// the file holds the user's own rules, which they never saw.
    func dataDirectoryBecameAvailable() {
        guard rulesAwaitDataDirectory, !TextMouthPaths.isDataDirectoryUnavailable else { return }
        loadRules()
        regexCache.removeAll()
        wholeWordRegexCache.removeAll()
        PersistenceFailureCenter.shared.withdraw(.substitutions)
        DiagnosticLog.event(
            .storage,
            "SUBSTITUTIONS_FILE: read \(rules.count) rules now that the library is available"
        )
    }

    func resetToDefaults() {
        rules = Self.defaultRules
        regexCache.removeAll()
        wholeWordRegexCache.removeAll()
        saveRules()
    }

    // MARK: - Default Rules

    static let defaultRules: [SubstitutionRule] = [
        // Common abbreviations
        SubstitutionRule(name: "Mr.", pattern: "\\bMr\\.", replacement: "Mister", isRegex: true),
        SubstitutionRule(name: "Mrs.", pattern: "\\bMrs\\.", replacement: "Missus", isRegex: true),
        SubstitutionRule(name: "Dr.", pattern: "\\bDr\\.", replacement: "Doctor", isRegex: true),
        SubstitutionRule(name: "Prof.", pattern: "\\bProf\\.", replacement: "Professor", isRegex: true),
        SubstitutionRule(name: "St.", pattern: "\\bSt\\.", replacement: "Saint", isRegex: true),
        SubstitutionRule(name: "vs.", pattern: "\\bvs\\.", replacement: "versus", isRegex: true),
        SubstitutionRule(name: "etc.", pattern: "\\betc\\.", replacement: "etcetera", isRegex: true),
        SubstitutionRule(name: "e.g.", pattern: "\\be\\.g\\.", replacement: "for example", isRegex: true),
        SubstitutionRule(name: "i.e.", pattern: "\\bi\\.e\\.", replacement: "that is", isRegex: true),

        // Skip URLs
        SubstitutionRule(name: "Skip URLs", pattern: "https?://\\S+", replacement: "link", isRegex: true),

        // Skip email addresses
        SubstitutionRule(name: "Skip emails", pattern: "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Z|a-z]{2,}\\b", replacement: "email address", isRegex: true),

        // Footnote markers
        SubstitutionRule(name: "Skip footnote brackets", pattern: "\\[\\d+\\]", replacement: "", isRegex: true),
        SubstitutionRule(name: "Skip footnote parens", pattern: "\\(see note \\d+\\)", replacement: "", isRegex: true, caseSensitive: false),

        // Normalize dashes to pauses
        SubstitutionRule(name: "Em dash to pause", pattern: "—", replacement: " — ", isRegex: false),

        // Collapse repeated whitespace
        SubstitutionRule(name: "Collapse whitespace", pattern: "[ \\t]{3,}", replacement: "  ", isRegex: true),
    ]
}
