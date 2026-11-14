#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation

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
///
/// It holds no copy of the original text: nothing reads one, and a cached
/// speech would keep a source chapter alive by it (the audit's C17, M5).
struct TextTransformation {
    let modifiedText: String
    /// The offset map for this substitution stage (modified↔original).
    /// Exposed so it can be composed with other pipeline stages.
    let offsetMap: ComposedOffsetMap

    /// Each rule works in the previous rule's output coordinates. Retain the
    /// stages so subsequent edits cannot invalidate earlier breakpoints.
    init(modifiedText: String, offsetMaps: [OffsetMap]) {
        self.modifiedText = modifiedText
        self.offsetMap = ComposedOffsetMap(stages: offsetMaps)
    }

    /// Identity transformation (no changes).
    static func identity(_ text: String) -> TextTransformation {
        TextTransformation(modifiedText: text, offsetMaps: [])
    }

    /// Convert an offset in the modified text to the corresponding offset in the original text.
    func toOriginalOffset(_ modified: Int) -> Int {
        offsetMap.toOriginal(modified)
    }

    /// Convert an offset in the original text to the corresponding offset in the modified text.
    func toModifiedOffset(_ original: Int) -> Int {
        offsetMap.toModified(original)
    }
}

/// The substitution rules in force at one moment, each compiled and ready
/// to match: everything applying them reads, as values.
///
/// `TextSubstitutionService.substitutionPass` makes one from its rules, and
/// its `transform(_:)` applies one. Being `Sendable`, a pass carries the
/// rules off the main actor, where speech for a long chapter is prepared;
/// being `Equatable`, it tells a prepared chapter whether the rules it was
/// prepared with are still the ones in force (PERF02).
struct SubstitutionPass: Equatable, Sendable {
    /// How one rule finds its matches.
    enum Matcher: Equatable, Sendable {
        /// The pattern as literal text, found by `NSString`'s search.
        case literal
        /// A regular expression, with the template its matches are replaced
        /// by: a regex rule's own pattern and replacement, or a whole-word
        /// rule's literal pattern between word-boundary lookarounds and its
        /// replacement escaped to be taken literally.
        case expression(NSRegularExpression, template: String)
        /// A pattern that did not compile, which matches nothing.
        case nothing
    }

    /// One rule ready to match.
    struct CompiledRule: Equatable, Sendable {
        /// The rule as the user wrote it.
        let rule: SubstitutionRule
        /// How its matches are found.
        let matcher: Matcher
    }

    /// One match of a rule: the UTF-16 range it covers in the text it was
    /// found in, and the text to put there, with any group references of a
    /// regular expression already filled in.
    struct Replacement: Sendable {
        let range: NSRange
        let replacement: String
    }

    /// The rules, in the order they apply; empty while substitutions are off.
    let rules: [CompiledRule]

    /// No rules at all: what applies while substitutions are off.
    static let none = SubstitutionPass(rules: [])

    /// `text` with every rule applied in order, each to the text the rules
    /// before it made, and the map between offsets in `text` and in the
    /// result.
    func transform(_ text: String) -> TextTransformation {
        guard !rules.isEmpty else { return .identity(text) }

        // Apply rules sequentially and compose their coordinate maps. Sorting
        // all rules' breakpoints together mixes different intermediate texts.
        var current = text
        var stages: [OffsetMap] = []

        for rule in rules {
            guard let stage = Self.applying(replacements(of: rule, in: current), to: current) else { continue }
            current = stage.text
            stages.append(stage.offsetMap)
        }

        return TextTransformation(modifiedText: current, offsetMaps: stages)
    }

    /// Every match of `rule` in `text`, in text order.
    func replacements(of rule: CompiledRule, in text: String) -> [Replacement] {
        switch rule.matcher {
        case .literal:
            return Self.literalReplacements(of: rule.rule, in: text)
        case .expression(let regex, let template):
            let fullRange = NSRange(location: 0, length: (text as NSString).length)
            return regex.matches(in: text, range: fullRange).map { match in
                Replacement(
                    range: match.range,
                    replacement: regex.replacementString(for: match, in: text, offset: 0, template: template)
                )
            }
        case .nothing:
            return []
        }
    }

    /// Every match of a plain rule's literal pattern in `text`, each searched
    /// for after the one before, ignoring letter case unless the rule is
    /// case sensitive.
    private static func literalReplacements(of rule: SubstitutionRule, in text: String) -> [Replacement] {
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

    /// `text` with one rule's `replacements` made, and the map between
    /// offsets in `text` and in the result; nil when none can be made.
    ///
    /// `replacements` are a rule's matches in `text`, in text order and not
    /// overlapping, as the matchers find them. Their ranges count UTF-16 code
    /// units, as `NSRegularExpression` and `NSString` report them. A range
    /// that does not convert to indices of `text` is left out, from the text
    /// and from the map alike, so an invalid Unicode range never shifts later
    /// offsets; a matcher that broke its promise of order is treated the same
    /// way rather than trapping.
    ///
    /// The result is built in one forward pass: the text between matches,
    /// then each replacement, appended in turn, with every range converted
    /// against `text`, which never changes, so finding where its UTF-16
    /// offsets fall is paid for once. Making the replacements in place, back
    /// to front, rescanned the changed text for every match on non-ASCII
    /// text, so time grew with the chapter's length times its matches
    /// (PERF01: 3.4 s for a chapter of a million UTF-16 units). Both make the
    /// same replacements: that pass changed only text after the range it
    /// converted next, and Foundation converts a range on Unicode scalar
    /// boundaries, so each range met the same characters there as it does
    /// here.
    static func applying(
        _ replacements: [Replacement],
        to text: String
    ) -> (text: String, offsetMap: OffsetMap)? {
        var result = ""
        // Most rules change little, so the result is about as long as `text`.
        result.reserveCapacity(text.utf8.count)
        var copiedUpTo = text.startIndex
        // The map has a breakpoint after each replacement, in the result:
        // there, a result offset plus the total change in length so far is
        // the offset in `text`. `shift` is how far the result's offsets have
        // moved from `text`'s by then.
        var shift = 0
        var totalDelta = 0
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []
        points.reserveCapacity(replacements.count)

        for replacement in replacements {
            guard let bounds = Range(replacement.range, in: text),
                  bounds.lowerBound >= copiedUpTo else { continue }
            result += text[copiedUpTo..<bounds.lowerBound]
            result += replacement.replacement
            copiedUpTo = bounds.upperBound

            let replacementLength = replacement.replacement.utf16Length
            let lengthChange = replacement.range.length - replacementLength
            totalDelta += lengthChange
            points.append((targetPos: replacement.range.location + shift + replacementLength, cumulativeDelta: totalDelta))
            shift -= lengthChange
        }

        guard !points.isEmpty else { return nil }
        result += text[copiedUpTo...]
        return (result, OffsetMap(points: points))
    }
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

    /// Whether the rules in use stand in for substitutions.json, found only
    /// in the cloud (FR02 polish: several Macs): it was not read, since
    /// reading it here, on the main thread, would have waited on the
    /// network, and the sync service was asked for it. The standard rules
    /// stand in meanwhile, and nothing is saved over the file, which holds
    /// the user's own rules: it is read again when the app becomes active
    /// and before each save, and once it is on this Mac its rules replace
    /// the stand-ins, as when the data directory comes back.
    private(set) var rulesAwaitFileInCloud = false
    /// Whether the rules in use are the standard rules, standing in for a
    /// substitutions.json that isn't there: at a first launch, or on a new
    /// Mac whose library is in the cloud before the sync service has brought
    /// the file down (FR02 polish: several Macs). They are kept in memory
    /// only, and written once a rule changes, so that a file the sync service
    /// brings down meanwhile is taken up as it came rather than met by one of
    /// this Mac's own, which the sync service would keep beside it as a
    /// conflict copy. The file is looked for again as the app becomes active
    /// and before each save (`readFileThatArrived()`).
    private(set) var rulesStandInForMissingFile = false
    /// Reads substitutions.json: with dataless files left in the cloud,
    /// unless a test reads it otherwise.
    var readFile: SavedFile.Reader = SavedFile.readWithoutDownloading
    /// Hears when the app becomes active, to read a file that waited in the
    /// cloud again.
    private var activationSubscription: AnyCancellable?

    static let shared = TextSubstitutionService()

    /// The app's service: `isEnabled` and the repeated-symbol settings from
    /// this process's preferences, which it then follows, and the rules from
    /// substitutions.json, read again when the data directory comes back
    /// after it was unavailable, and when the app becomes active while the
    /// file waits in the cloud or isn't there yet.
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
        activationSubscription = NotificationCenter.default
            .publisher(for: PlatformApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.readFileWaitingInTheCloud()
                self?.readFileThatArrived()
            }
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
        substitutionPass.transform(text)
    }

    /// The rules in force now, each compiled and ready to apply: nothing
    /// while substitutions are off, and otherwise every enabled rule with a
    /// pattern, in order. A value, so speech can be prepared with it off the
    /// main actor, and so a prepared chapter can tell whether the rules it
    /// was prepared with are still the ones in force (PERF02).
    var substitutionPass: SubstitutionPass {
        guard isEnabled else { return .none }
        return SubstitutionPass(rules: rules.filter { $0.isEnabled && !$0.pattern.isEmpty }.map { compiled($0) })
    }

    /// `rule` ready to match: a regex rule with its own pattern, a whole-word
    /// rule with its literal pattern between word-boundary lookarounds, and
    /// any other rule as literal text. A pattern that does not compile
    /// matches nothing.
    private func compiled(_ rule: SubstitutionRule) -> SubstitutionPass.CompiledRule {
        if rule.isRegex {
            // Group references ($1, $2, and so on) in the replacement are
            // filled in from each match. A backslash in a template escapes
            // the next character, so "\1" is a plain "1", not a group.
            let matcher = compiledRegex(for: rule).map { SubstitutionPass.Matcher.expression($0, template: rule.replacement) }
            return SubstitutionPass.CompiledRule(rule: rule, matcher: matcher ?? .nothing)
        }
        if rule.isWholeWordEffective {
            // The replacement is taken literally, as for a plain rule: its
            // regular-expression metacharacters are escaped first, or a `$`
            // or `\` in a pronunciation would be read as a group reference
            // and silently disappear.
            let template = NSRegularExpression.escapedTemplate(for: rule.replacement)
            let matcher = wholeWordRegex(for: rule).map { SubstitutionPass.Matcher.expression($0, template: template) }
            return SubstitutionPass.CompiledRule(rule: rule, matcher: matcher ?? .nothing)
        }
        return SubstitutionPass.CompiledRule(rule: rule, matcher: .literal)
    }

    // MARK: - Pattern Compilation

    /// Compile (and cache) the lookaround-wrapped regex for a whole-word
    /// rule. Builds the pattern from the rule's literal text via
    /// `escapedPattern(for:)` so regex metacharacters in the user's input
    /// are taken literally.
    ///
    /// The lookarounds reject a match next to a letter, digit, combining
    /// mark, or underscore. `\p{L}` is any Unicode letter (covers accented
    /// characters, CJK, etc.), `\p{N}` is any Unicode number, `\p{M}` is any
    /// combining mark — included so a base letter followed by a
    /// separately-encoded diacritic is treated as one word, not as a letter
    /// followed by punctuation. Plain `\b` would NOT work here because
    /// patterns like "|" are non-word characters, so a regex word boundary
    /// doesn't apply to them. The lookarounds work for both word and
    /// non-word patterns.
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

    /// Compile (and cache) a regex rule's own pattern; nil when it does not
    /// compile.
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
    /// then, and the next save that succeeds settles it (TODO S09). While
    /// the file waits in the cloud, nothing is written over it
    /// (`saveWhileFileInCloud()`). While the standard rules stand in for a
    /// file that wasn't there, a file the sync service has brought down
    /// since is taken up instead, and nothing is written over its rules
    /// (`readFileThatArrived()`); otherwise this save is the first to write
    /// the file.
    func saveRules() {
        if readFileThatArrived() {
            return
        }
        guard !rulesAwaitFileInCloud else {
            saveWhileFileInCloud()
            return
        }
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)
            try data.write(to: TextMouthPaths.substitutionsFile, options: .atomic)
            rulesStandInForMissingFile = false
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

    /// A save asked for while substitutions.json waits in the cloud: the
    /// file is read again first. Once it is on this Mac, its rules replace
    /// the stand-ins, dropping the change made to them, and nothing is
    /// written; while it is still in the cloud, nothing may be written over
    /// it, so the change is reported unsaved, with a retry that tries again.
    private func saveWhileFileInCloud() {
        readFileWaitingInTheCloud()
        guard rulesAwaitFileInCloud else { return }
        let url = TextMouthPaths.substitutionsFile
        PersistenceFailureCenter.shared.recordFailure(
            .substitutions,
            path: url.path,
            error: SavedFile.InCloudError(fileName: url.lastPathComponent)
        ) { [weak self] _ in
            self?.saveRules()
        }
    }

    /// Reads substitutions.json into `rules`, with dataless files left in
    /// the cloud, so the read never waits on the network
    /// (`takeUp(_:of:)`). With no file, as at a first launch, or on a new
    /// Mac before the sync service has brought the file down, the standard
    /// rules stand in, unsaved, until a rule changes or the file arrives
    /// (`rulesStandInForMissingFile`). A file that can't be read or decoded
    /// is preserved beside itself, and the standard rules stand in for it
    /// until a save replaces it. A file only in the cloud is asked of the
    /// sync service and logged once, and the standard rules stand in,
    /// unsaved, until a read finds it on this Mac (`rulesAwaitFileInCloud`);
    /// reading it again while it waits leaves the rules standing in as they
    /// are.
    func loadRules() {
        // Nothing is read from a data directory the library model found
        // unavailable, and a file missing there is no first launch (FR02):
        // the standard rules stand in, unsaved, until the library is back.
        guard !TextMouthPaths.isDataDirectoryUnavailable else {
            rules = Self.defaultRules
            rulesAwaitDataDirectory = true
            rulesStandInForMissingFile = false
            return
        }
        rulesAwaitDataDirectory = false
        let url = TextMouthPaths.substitutionsFile
        takeUp(SavedFile.read(url, using: readFile), of: url)
    }

    /// Takes up what a read of substitutions.json at `url` found, as
    /// `loadRules()` describes: the file's rules, or the standard rules
    /// standing in for a file that isn't there, can't be used, or is only in
    /// the cloud. Rules already standing in for a file that wasn't there
    /// stay as they are when the file is found only in the cloud, a change
    /// made to them included, as rules standing in for a file waiting there
    /// do.
    ///
    /// - Returns: Whether the file's own rules are in use now.
    @discardableResult
    private func takeUp(_ read: SavedFile.Read, of url: URL) -> Bool {
        let wasWaitingInTheCloud = rulesAwaitFileInCloud
        let wasStandingInForMissingFile = rulesStandInForMissingFile
        rulesAwaitFileInCloud = false
        rulesStandInForMissingFile = false
        switch read {
        case .missing:
            rules = Self.defaultRules
            rulesStandInForMissingFile = true
        case .contents(let data):
            do {
                rules = try JSONDecoder().decode([SubstitutionRule].self, from: data)
                return true
            } catch {
                standInForUnusableRulesFile(url, bytes: data, because: error.localizedDescription)
            }
        case .unreadable(let reason):
            standInForUnusableRulesFile(url, bytes: nil, because: reason)
        case .inCloud:
            rulesAwaitFileInCloud = true
            guard !wasWaitingInTheCloud else { return false }
            if !wasStandingInForMissingFile {
                rules = Self.defaultRules
            }
            SavedFile.requestDownload(of: url)
            DiagnosticLog.event(
                .storage,
                "SUBSTITUTIONS_FILE: \(url.lastPathComponent) is only in the cloud, so it was not read; "
                    + "asked the sync service for it, and the standard rules stand in until it is on this Mac"
            )
        }
        return false
    }

    /// Looks for substitutions.json again while the standard rules stand in
    /// for it, unsaved, because it wasn't there (`rulesStandInForMissingFile`):
    /// as the app becomes active, and before a save. A file the sync service
    /// has brought down since is taken up as at launch: its rules replace the
    /// stand-ins, a change made to them dropped and no longer reported
    /// unsaved, as when the data directory comes back, since the file holds
    /// the user's own rules, which they never saw here. A file only in the
    /// cloud waits there, as one found so at launch does, and one that can't
    /// be used is preserved beside itself. While no file is there, nothing
    /// changes.
    ///
    /// - Returns: Whether the file's own rules are in use now, so that
    ///   nothing is to be written over them.
    @discardableResult
    func readFileThatArrived() -> Bool {
        guard rulesStandInForMissingFile, !rulesAwaitDataDirectory else { return false }
        let url = TextMouthPaths.substitutionsFile
        let read = SavedFile.read(url, using: readFile)
        guard read != .missing else { return false }
        let tookUpTheFile = takeUp(read, of: url)
        clearCompiledRules()
        guard tookUpTheFile else { return false }
        PersistenceFailureCenter.shared.withdraw(.substitutions)
        DiagnosticLog.event(
            .storage,
            "SUBSTITUTIONS_FILE: read \(rules.count) rules from the file the sync service brought here; "
                + "the standard rules stood in until now, unsaved"
        )
        return true
    }

    /// Puts the standard rules in place of substitutions.json at `url`,
    /// which can't be read or decoded for `reason`, such as one a write
    /// interrupted on another Mac cut short. The file is preserved beside
    /// itself first, holding `bytes` when they could be read, so the save
    /// that later replaces it loses none of the user's own rules, and one
    /// line says so.
    private func standInForUnusableRulesFile(_ url: URL, bytes: Data?, because reason: String) {
        SavedFile.preserveUnusable(
            url,
            bytes: bytes,
            because: reason,
            logging: "SUBSTITUTIONS_FILE",
            in: .storage,
            standIn: "the standard rules stand in"
        )
        rules = Self.defaultRules
    }

    /// Reads substitutions.json again while its rules wait in the cloud, as
    /// the app becomes active and before a save. Once the file is on this
    /// Mac, its rules replace the stand-ins, and a change made to them is no
    /// longer reported unsaved, as when the data directory comes back: the
    /// file holds the user's own rules, which they never saw. While it is
    /// still in the cloud, nothing changes.
    func readFileWaitingInTheCloud() {
        guard rulesAwaitFileInCloud else { return }
        // A change made to the stand-ins is reported unsaved (never the
        // rules themselves): the file's rules replace them, so say so.
        let hadChanges = PersistenceFailureCenter.shared.outstandingFailures().contains { $0.subject == .substitutions }
        loadRules()
        guard !rulesAwaitFileInCloud else { return }
        if hadChanges {
            DiagnosticLog.event(
                .storage,
                "SUBSTITUTIONS_FILE: changes made to the standard rules while the file was in the cloud "
                    + "were dropped for the file's own rules"
            )
        }
        clearCompiledRules()
        PersistenceFailureCenter.shared.withdraw(.substitutions)
        DiagnosticLog.event(
            .storage,
            "SUBSTITUTIONS_FILE: read \(rules.count) rules now that the file is on this Mac"
        )
    }

    /// Reads substitutions.json once the data directory is back, when the
    /// rules in use only stood in for it (FR02). Changes made to the
    /// stand-ins meanwhile are dropped, with their unsaved-change notice:
    /// the file holds the user's own rules, which they never saw.
    func dataDirectoryBecameAvailable() {
        guard rulesAwaitDataDirectory, !TextMouthPaths.isDataDirectoryUnavailable else { return }
        loadRules()
        clearCompiledRules()
        PersistenceFailureCenter.shared.withdraw(.substitutions)
        // A file found only in the cloud said so as it was read.
        guard !rulesAwaitFileInCloud else { return }
        DiagnosticLog.event(
            .storage,
            "SUBSTITUTIONS_FILE: read \(rules.count) rules now that the library is available"
        )
    }

    /// Forgets every compiled rule, for rules replaced all at once.
    private func clearCompiledRules() {
        regexCache.removeAll()
        wholeWordRegexCache.removeAll()
    }

    func resetToDefaults() {
        rules = Self.defaultRules
        clearCompiledRules()
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
