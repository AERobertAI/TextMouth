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
@MainActor
final class TextSubstitutionService: ObservableObject {
    @Published var rules: [SubstitutionRule] = []
    @Published var isEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "substitutionsEnabled") }
    }

    /// Cached compiled regexes keyed by rule ID
    private var regexCache: [UUID: NSRegularExpression] = [:]

    /// Cached compiled regexes for whole-word rules. Kept separate from
    /// `regexCache` because the underlying pattern is different (the
    /// stored pattern wrapped with Unicode-aware lookarounds), and we
    /// don't want a regex-mode rule's compiled form to be reused if the
    /// user toggles it through plain+wholeWord and back.
    private var wholeWordRegexCache: [UUID: NSRegularExpression] = [:]

    static let shared = TextSubstitutionService()

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "substitutionsEnabled") as? Bool ?? true
        loadRules()
    }

    /// Dependency-injected initializer for deterministic production-target
    /// tests. It deliberately does not read or write the persisted rule file.
    init(rules: [SubstitutionRule], isEnabled: Bool = true) {
        self.rules = rules
        self.isEnabled = isEnabled
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

    func saveRules() {
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(rules)
            try data.write(to: TextMouthPaths.substitutionsFile, options: .atomic)
        } catch {
            print("Failed to save substitutions: \(error)")
        }
    }

    func loadRules() {
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
