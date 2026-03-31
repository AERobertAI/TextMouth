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

    init(
        id: UUID = UUID(),
        name: String = "",
        pattern: String,
        replacement: String = "",
        isRegex: Bool = false,
        isEnabled: Bool = true,
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.replacement = replacement
        self.isRegex = isRegex
        self.isEnabled = isEnabled
        self.caseSensitive = caseSensitive
    }
}

/// Result of applying substitutions: modified text + bidirectional offset mapping.
/// Uses OffsetMap internally for offset conversion, and exposes it for pipeline composition.
struct TextTransformation {
    let originalText: String
    let modifiedText: String
    /// The offset map for this substitution stage (modified↔original).
    /// Exposed so it can be composed with other pipeline stages.
    let offsetMap: OffsetMap

    init(originalText: String, modifiedText: String, offsetPoints: [(modifiedPos: Int, cumulativeDelta: Int)]) {
        self.originalText = originalText
        self.modifiedText = modifiedText
        // Convert legacy offset points to OffsetMap format (conventions match exactly)
        self.offsetMap = OffsetMap(points: offsetPoints.map { (targetPos: $0.modifiedPos, cumulativeDelta: $0.cumulativeDelta) })
    }

    /// Identity transformation (no changes).
    static func identity(_ text: String) -> TextTransformation {
        TextTransformation(originalText: text, modifiedText: text, offsetPoints: [])
    }

    /// Convert an offset in the modified text to the corresponding offset in the original text.
    func toOriginalOffset(_ modified: Int) -> Int {
        offsetMap.toSource(modified)
    }

    /// Convert an offset in the original text to the corresponding offset in the modified text.
    func toModifiedOffset(_ original: Int) -> Int {
        offsetMap.toTarget(original)
    }

    var hasChanges: Bool { originalText != modifiedText }
}

/// Manages text substitution rules and applies them to text before TTS.
class TextSubstitutionService: ObservableObject {
    @Published var rules: [SubstitutionRule] = []
    @Published var isEnabled: Bool = true {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "substitutionsEnabled") }
    }

    /// Cached compiled regexes keyed by rule ID
    private var regexCache: [UUID: NSRegularExpression] = [:]

    static let shared = TextSubstitutionService()

    private init() {
        isEnabled = UserDefaults.standard.object(forKey: "substitutionsEnabled") as? Bool ?? true
        loadRules()
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

        // Apply rules sequentially, building offset map as we go.
        // Each rule operates on the result of the previous rule.
        // We track cumulative delta to map between modified and original coordinates.
        var current = text
        var totalDelta = 0
        var points: [(modifiedPos: Int, cumulativeDelta: Int)] = []

        for rule in enabledRules {
            let replacements = findReplacements(in: current, rule: rule)
            guard !replacements.isEmpty else { continue }

            // Track offset shifts from this rule's replacements (in forward order)
            var shift = 0
            for rep in replacements {
                let adjustedStart = rep.range.location + shift
                let lenDiff = rep.range.length - rep.replacement.count
                totalDelta += lenDiff
                let afterInModified = adjustedStart + rep.replacement.count
                points.append((modifiedPos: afterInModified, cumulativeDelta: totalDelta))
                shift -= lenDiff
            }

            // Apply replacements in reverse order so indices stay valid
            var newText = current
            for rep in replacements.reversed() {
                let startIdx = newText.index(newText.startIndex, offsetBy: rep.range.location)
                let endIdx = newText.index(startIdx, offsetBy: rep.range.length)
                newText.replaceSubrange(startIdx..<endIdx, with: rep.replacement)
            }
            current = newText
        }

        let sortedPoints = points.sorted { $0.modifiedPos < $1.modifiedPos }
        return TextTransformation(originalText: text, modifiedText: current, offsetPoints: sortedPoints)
    }

    // MARK: - Pattern Matching

    private struct Replacement {
        let range: NSRange
        let replacement: String
    }

    private func findReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        if rule.isRegex {
            return findRegexReplacements(in: text, rule: rule)
        } else {
            return findPlainReplacements(in: text, rule: rule)
        }
    }

    private func findPlainReplacements(in text: String, rule: SubstitutionRule) -> [Replacement] {
        var results: [Replacement] = []
        let searchText = rule.caseSensitive ? text : text.lowercased()
        let searchPattern = rule.caseSensitive ? rule.pattern : rule.pattern.lowercased()

        var searchStart = searchText.startIndex
        while let range = searchText.range(of: searchPattern, range: searchStart..<searchText.endIndex) {
            let nsRange = NSRange(range, in: text)
            results.append(Replacement(range: nsRange, replacement: rule.replacement))
            searchStart = range.upperBound
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
