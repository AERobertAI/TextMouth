import Foundation

// MARK: - A Rule

/// One correction of the experimental transcript cleanup (FR05): wherever a
/// transcript's sentence holds `pattern`, in any case, `replacement` is
/// written instead, in the case the sentence wrote the pattern
/// (`TranscriptCleanup`).
///
/// TextMouth's own rules come from measuring the recognizer on speech whose
/// text was known (`TranscriptAccuracy`,
/// TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md); the user can add their own,
/// such as the names in a series the recognizer always spells wrong.
struct TranscriptCleanupRule: Equatable, Sendable {
    /// What the recognizer writes, matched in any case: one word or several,
    /// a single space between each two.
    var pattern: String
    /// What is written in its place.
    var replacement: String
    /// Whether the pattern matches whole words only, the punctuation around
    /// them aside, or wherever its letters stand, inside words too.
    var wholeWord: Bool
    /// How many times the correction was right in the measurements it came
    /// from: every time its pattern was heard. 0 for a rule not measured,
    /// such as one the user wrote.
    var evidence: Int
    /// Why the rule is there, in plain words, for whoever reads the file;
    /// nil for none.
    var note: String?
}

extension TranscriptCleanupRule: Codable {
    enum CodingKeys: String, CodingKey {
        case pattern, replacement, wholeWord, evidence, note
    }

    /// Reads a rule as transcript-cleanup.json writes it, forgiving what a
    /// hand edit leaves: white space around and between the words of the
    /// pattern and the replacement is made single spaces, a rule without
    /// `wholeWord` matches whole words, and one without `evidence` has none.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pattern = Self.singleSpaced(try container.decode(String.self, forKey: .pattern))
        replacement = Self.singleSpaced(try container.decode(String.self, forKey: .replacement))
        wholeWord = try container.decodeIfPresent(Bool.self, forKey: .wholeWord) ?? true
        evidence = try container.decodeIfPresent(Int.self, forKey: .evidence) ?? 0
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    /// `text` with each run of white space made one space, and none at
    /// either end.
    static func singleSpaced(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension TranscriptCleanupRule {
    /// Why the rule can't be used, naming its field as the file spells it,
    /// as in "replacement is empty"; nil when it can. A rule must have a
    /// pattern holding a letter or a figure, each of whose words does when
    /// it matches whole words; a replacement; and no pattern of its own in
    /// its replacement, so that cleaning up a transcript again changes
    /// nothing more.
    func validationFailure() -> String? {
        if pattern.isEmpty {
            return "pattern is empty"
        }
        if !pattern.contains(where: { $0.isLetter || $0.isNumber }) {
            return "pattern holds no letter or figure"
        }
        if wholeWord, pattern.split(separator: " ").contains(where: { word in !word.contains { $0.isLetter || $0.isNumber } }) {
            return "pattern holds a word with no letter or figure, which no whole word matches"
        }
        if replacement.isEmpty {
            return "replacement is empty"
        }
        if evidence < 0 {
            return "evidence is \(evidence), below 0"
        }
        if TranscriptCleanup(rules: [self]).cleaned(replacement).corrections.first ?? 0 > 0 {
            return "replacement holds the pattern itself, so every cleanup would change it again"
        }
        return nil
    }
}

// MARK: - A Rule File

/// The rules of the experimental transcript cleanup (FR05), as
/// transcript-cleanup.json holds them: TextMouth's own, in its bundle, or
/// the user's copy in the data directory (`TranscriptCleanupRuleFile`).
///
/// The rules have a version and a date of their own, which a transcript
/// cleaned up with them records (`TranscriptCleanupNote`). `about` says what
/// the file is, for whoever opens it; TextMouth reads nothing from it.
struct TranscriptCleanupRuleSet: Codable, Equatable, Sendable {
    /// The layout of transcript-cleanup.json this TextMouth reads.
    static let currentFormat = 1

    /// The file's layout (`currentFormat`).
    var format: Int
    /// The rules' version, which goes up whenever they change.
    var version: Int
    /// The day this version was made, as "2026-10-04".
    var date: String
    /// What the file is, for whoever reads it.
    var about: String?
    /// The rules, applied in order.
    var rules: [TranscriptCleanupRule]

    /// Rules of the current layout.
    init(version: Int, date: String, about: String? = nil, rules: [TranscriptCleanupRule]) {
        format = Self.currentFormat
        self.version = version
        self.date = date
        self.about = about
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey {
        case format, version, date, about, rules
    }

    /// Reads the rules as transcript-cleanup.json writes them; a file
    /// without `format` is of the first layout.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decodeIfPresent(Int.self, forKey: .format) ?? Self.currentFormat
        version = try container.decode(Int.self, forKey: .version)
        date = try container.decode(String.self, forKey: .date)
        about = try container.decodeIfPresent(String.self, forKey: .about)
        rules = try container.decode([TranscriptCleanupRule].self, forKey: .rules)
    }

    /// The rules `bytes` hold, as transcript-cleanup.json writes them,
    /// valid.
    /// - Throws: `TranscriptCleanupRuleSet.Unusable`, saying why not.
    static func decoded(_ bytes: Data) throws -> TranscriptCleanupRuleSet {
        let rules: TranscriptCleanupRuleSet
        do {
            rules = try JSONDecoder().decode(TranscriptCleanupRuleSet.self, from: bytes)
        } catch {
            throw Unusable(reason: TranscriptStore.describe(error))
        }
        if let reason = rules.validationFailure() {
            throw Unusable(reason: reason)
        }
        return rules
    }

    /// Why a rule file can't be used, in words naming the field at fault,
    /// never quoting the rules.
    struct Unusable: Error, Equatable {
        let reason: String
    }

    /// Why the rules can't be used, naming the first offending field as the
    /// file spells it, as in "rules[2].replacement is empty"; nil when they
    /// can. Never quotes a rule: a log line may carry the reason.
    func validationFailure() -> String? {
        if format != Self.currentFormat {
            return "format \(format) is not the supported \(Self.currentFormat)"
        }
        if version < 1 {
            return "version is \(version), below 1"
        }
        if Self.day(date) == nil {
            return "date is not a day written as 2026-10-04"
        }
        for (number, rule) in rules.enumerated() {
            if let failure = rule.validationFailure() {
                return "rules[\(number)].\(failure)"
            }
        }
        return nil
    }

    /// The day `text` names, written as "2026-10-04", at its start in UTC;
    /// nil for text that names none.
    static func day(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: text)
    }

    /// The rules' day, as the user's own words give a date: "October 4,
    /// 2026"; the file's own spelling when it names no day. The day is the
    /// same wherever the Mac is: it is read and written in UTC.
    var dayName: String {
        Self.dayName(date)
    }

    /// The day `text` names, written as "2026-10-04", in the user's own
    /// words: "October 4, 2026"; `text` itself when it names no day.
    static func dayName(_ text: String) -> String {
        guard let day = day(text) else { return text }
        return day.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .gmt))
    }
}

// MARK: - What a Cleaned Transcript Records

/// Where a cleanup's rules came from.
enum TranscriptCleanupRuleSource: String, Sendable {
    /// TextMouth's own rules, in its bundle.
    case builtIn = "built-in"
    /// The user's copy, transcript-cleanup.json in the data directory.
    case user
}

/// What a transcript records of its last cleanup (`Transcript.cleanedUp`):
/// when it was, with which rules, and how many corrections it made.
struct TranscriptCleanupNote: Codable, Equatable, Sendable {
    /// When the cleanup was applied, in whole seconds.
    var cleanedAt: Date
    /// The version of the rules it used (`TranscriptCleanupRuleSet.version`).
    var rulesVersion: Int
    /// The day of those rules, as their file wrote it.
    var rulesDate: String
    /// Whose rules they were: "built-in" or "user"
    /// (`TranscriptCleanupRuleSource`). Kept as words, so a source a later
    /// TextMouth adds never keeps this one from reading the transcript.
    var rules: String
    /// How many corrections it made.
    var corrections: Int

    /// Whose rules they were, when this TextMouth knows the source.
    var source: TranscriptCleanupRuleSource? {
        TranscriptCleanupRuleSource(rawValue: rules)
    }
}
