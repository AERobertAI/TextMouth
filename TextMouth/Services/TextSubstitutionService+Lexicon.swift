import Foundation

/// What an import of a pronunciation lexicon did to the rules (FMT08).
struct LexiconImportReport: Equatable {
    /// How many new rules were added.
    var added = 0
    /// How many of the lexicon's rules were already among the rules.
    var alreadyPresent = 0
    /// How many lexemes were set aside, having phonemes but no alias.
    var setAside = 0
    /// How many lexemes were not read, the lexicon being past the most
    /// rules one import adds (`PronunciationLexicon.ruleLimit`).
    var unread = 0
}

extension TextSubstitutionService {
    /// Adds the rules a lexicon's alias entries make after the existing
    /// rules, saving once. A rule is skipped as already present when a plain
    /// text rule with the same pattern (in any capitals) and the same
    /// replacement exists. Nothing changes, and nothing is saved, when no
    /// rule is added.
    @discardableResult
    func importLexicon(_ lexicon: PronunciationLexicon) -> LexiconImportReport {
        var report = LexiconImportReport(setAside: lexicon.setAsideCount, unread: lexicon.unreadCount)
        // Each existing plain rule as "pattern, replacement", so a lexicon
        // that repeats a rule adds nothing the second time it is imported.
        func key(_ rule: SubstitutionRule) -> String { rule.pattern.lowercased() + "\u{0}" + rule.replacement }
        var known = Set(rules.filter { !$0.isRegex }.map(key))
        var added: [SubstitutionRule] = []
        for rule in lexicon.substitutionRules {
            if known.insert(key(rule)).inserted {
                added.append(rule)
            } else {
                report.alreadyPresent += 1
            }
        }
        report.added = added.count
        guard !added.isEmpty else { return report }
        rules.append(contentsOf: added)
        saveRules()
        return report
    }

    /// The rules as a lexicon, with a count of those left out.
    func exportedLexicon() -> PronunciationLexicon.Export {
        PronunciationLexicon.export(rules)
    }
}

/// What a lexicon import or export tells the reader: an alert's title and
/// its sentence. VoiceOver reads the alert as it appears.
struct LexiconFileOutcome: Equatable {
    var title: String
    var message: String
}

/// The file side of lexicon import and export, apart from the panels that
/// choose the file, so a test can run it on a file of its own.
enum LexiconFileActions {
    /// Reads the lexicon at `url` and adds its rules to `service`.
    /// - Returns: What to tell the reader: the rules added, or why the file
    ///   could not be read (the rules are untouched then).
    @MainActor
    static func importLexicon(at url: URL, into service: TextSubstitutionService) -> LexiconFileOutcome {
        let name = url.lastPathComponent
        do {
            let lexicon = try PronunciationLexicon.read(from: url)
            let report = service.importLexicon(lexicon)
            return LexiconFileOutcome(
                title: PronunciationLexiconWording.importedTitle,
                message: PronunciationLexiconWording.imported(
                    fileName: name,
                    added: report.added,
                    alreadyPresent: report.alreadyPresent,
                    setAside: report.setAside,
                    unread: report.unread
                )
            )
        } catch {
            return LexiconFileOutcome(
                title: PronunciationLexiconWording.importFailedTitle,
                message: PronunciationLexiconWording.importFailure(
                    fileName: name,
                    error as? PronunciationLexicon.ReadError
                )
            )
        }
    }

    /// Writes `service`'s rules to `url` as a lexicon. Nothing is written
    /// when no rule can be.
    /// - Returns: What to tell the reader.
    @MainActor
    static func exportLexicon(from service: TextSubstitutionService, to url: URL) -> LexiconFileOutcome {
        let name = url.lastPathComponent
        let export = service.exportedLexicon()
        guard export.written > 0 else {
            return LexiconFileOutcome(
                title: PronunciationLexiconWording.exportFailedTitle,
                message: PronunciationLexiconWording.nothingToExport
            )
        }
        do {
            try export.lexicon.xmlData().write(to: url, options: .atomic)
        } catch {
            return LexiconFileOutcome(
                title: PronunciationLexiconWording.exportFailedTitle,
                message: PronunciationLexiconWording.exportWriteFailure(fileName: name)
            )
        }
        return LexiconFileOutcome(
            title: PronunciationLexiconWording.exportedTitle,
            message: PronunciationLexiconWording.exported(fileName: name, written: export.written, leftOut: export.leftOut)
        )
    }
}
