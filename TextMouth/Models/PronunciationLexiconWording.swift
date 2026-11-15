import Foundation

/// What a pronunciation lexicon import or export says (FMT08): the
/// buttons' labels and hints, the alerts' titles, and their sentences. One
/// type holds them so a test pins every word; VoiceOver speaks all of them,
/// so none uses a file extension or an abbreviation read letter by letter
/// (the format is "a pronunciation lexicon file").
enum PronunciationLexiconWording {
    // MARK: - The buttons

    /// The title of the Import button.
    static let importButton = "Import Rules…"
    /// What VoiceOver reads for the Import button.
    static let importLabel = "Import substitution rules from a pronunciation lexicon file"
    /// The Import button's hint: what it takes and what it leaves.
    static let importHint = "Adds the lexicon's spelling-to-words entries after your rules. Entries that only give phonetic spellings are set aside."
    /// The title of the Export button.
    static let exportButton = "Export Rules…"
    /// What VoiceOver reads for the Export button.
    static let exportLabel = "Export substitution rules as a pronunciation lexicon file"
    /// The Export button's hint.
    static let exportHint = "Saves your plain text rules that are on. Rules that use regular expressions, and rules that are off, are left out."
    /// The message of the Open panel Import chooses a file in.
    static let importPanelMessage = "Choose a pronunciation lexicon file to add its entries as substitution rules."
    /// The message of the Save panel Export names a file in.
    static let exportPanelMessage = "Save your substitution rules as a pronunciation lexicon file."

    // MARK: - Import

    /// The title of the alert after an import that added rules or found
    /// everything already there.
    static let importedTitle = "Rules Imported"
    /// The title of the alert after an import that could not read its file.
    static let importFailedTitle = "Import Failed"

    /// The sentence after an import: how many rules were added from the
    /// file, how many were already among the rules, and how many entries
    /// were set aside as phonetic only.
    ///
    /// "Added 3 rules from “names.pls”. 1 rule was already in your rules.
    /// 2 entries give only a phonetic spelling, which TextMouth cannot use,
    /// so they were set aside." A lexicon past the limit adds "7 entries were
    /// not read, because a lexicon adds at most 5000 rules at a time."
    static func imported(fileName: String, added: Int, alreadyPresent: Int, setAside: Int, unread: Int = 0) -> String {
        var sentences = [
            added == 0
                ? "No rules were added from “\(fileName)”."
                : "Added \(CountWording.phrase(added, singular: "rule", plural: "rules")) from “\(fileName)”."
        ]
        if alreadyPresent > 0 {
            sentences.append(
                alreadyPresent == 1
                    ? "1 rule was already in your rules."
                    : "\(alreadyPresent) rules were already in your rules."
            )
        }
        if setAside > 0 {
            sentences.append(
                setAside == 1
                    ? "1 entry gives only a phonetic spelling, which TextMouth cannot use, so it was set aside."
                    : "\(setAside) entries give only a phonetic spelling, which TextMouth cannot use, so they were set aside."
            )
        }
        if unread > 0 {
            sentences.append(
                (unread == 1 ? "1 entry was not read" : "\(unread) entries were not read")
                    + ", because a lexicon adds at most \(PronunciationLexicon.ruleLimit) rules at a time."
            )
        }
        return sentences.joined(separator: " ")
    }

    /// Why a file could not be read as a lexicon.
    static func importFailure(fileName: String, _ error: PronunciationLexicon.ReadError?) -> String {
        switch error {
        case .notXML?:
            return "“\(fileName)” is not a pronunciation lexicon: it is not a complete, valid XML file."
        case .notALexicon?:
            return "“\(fileName)” is an XML file, but not a pronunciation lexicon."
        case .tooLarge?:
            return "“\(fileName)” is too large to read as a pronunciation lexicon."
        case nil:
            return "TextMouth could not read “\(fileName)”."
        }
    }

    // MARK: - Export

    /// The title of the alert after rules were written.
    static let exportedTitle = "Rules Exported"
    /// The title of the alert when no rule can be written, or the file could not be.
    static let exportFailedTitle = "Export Failed"

    /// The sentence after an export: how many rules were written, and how
    /// many were left out and why.
    ///
    /// "Exported 5 rules to “rules.pls”. 2 rules were left out, because a
    /// regular expression or a rule that is off cannot be written in a lexicon."
    static func exported(fileName: String, written: Int, leftOut: Int) -> String {
        var sentences = ["Exported \(CountWording.phrase(written, singular: "rule", plural: "rules")) to “\(fileName)”."]
        if leftOut > 0 {
            sentences.append(
                (leftOut == 1 ? "1 rule was left out" : "\(leftOut) rules were left out")
                    + ", because a regular expression, or a rule that is off, cannot be written in a lexicon."
            )
        }
        return sentences.joined(separator: " ")
    }

    /// The sentence when no rule can be written at all.
    static let nothingToExport =
        "There are no rules to export. Only plain text rules that are on can be written in a lexicon."

    /// The sentence when the file could not be saved.
    static func exportWriteFailure(fileName: String) -> String {
        "TextMouth could not save “\(fileName)”."
    }
}
