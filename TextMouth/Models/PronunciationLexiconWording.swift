import Foundation

/// What a pronunciation lexicon import or export says (FMT08): the
/// buttons' labels and hints, the alerts' titles, and their sentences. One
/// type holds them so a test pins every word; VoiceOver speaks all of them,
/// so none uses a file extension or an abbreviation read letter by letter
/// (the format is "a pronunciation lexicon file").
enum PronunciationLexiconWording {
    // MARK: - The buttons

    /// The title of the Import button.
    static var importButton: String {
        // Translators: Title of the button in Settings, Text, Substitutions that adds rules from a pronunciation lexicon file.
        InterfaceText.line("pronunciationLexicon.importButton", "Import Rules…")
    }
    /// What VoiceOver reads for the Import button.
    static var importLabel: String {
        // Translators: VoiceOver label of the Import Rules button in Settings, Text, Substitutions.
        InterfaceText.line("pronunciationLexicon.importLabel", "Import rules from a pronunciation lexicon file")
    }
    /// The Import button's hint: what it takes and what it leaves.
    static var importHint: String {
        // Translators: VoiceOver hint of the Import Rules button in Settings, Text, Substitutions: what is added and what is left out.
        InterfaceText.line("pronunciationLexicon.importHint", "Adds the lexicon's entries after your rules; entries with only a phonetic spelling are set aside")
    }
    /// The title of the Export button.
    static var exportButton: String {
        // Translators: Title of the button in Settings, Text, Substitutions that saves the rules as a pronunciation lexicon file.
        InterfaceText.line("pronunciationLexicon.exportButton", "Export Rules…")
    }
    /// What VoiceOver reads for the Export button.
    static var exportLabel: String {
        // Translators: VoiceOver label of the Export Rules button in Settings, Text, Substitutions.
        InterfaceText.line("pronunciationLexicon.exportLabel", "Export rules as a pronunciation lexicon file")
    }
    /// The Export button's hint.
    static var exportHint: String {
        // Translators: VoiceOver hint of the Export Rules button in Settings, Text, Substitutions: which rules are saved and which are left out.
        InterfaceText.line("pronunciationLexicon.exportHint", "Saves your plain text rules that are on; regular expression rules are left out")
    }
    /// The message of the Open panel Import chooses a file in.
    static var importPanelMessage: String {
        // Translators: Message of the Open panel that Import Rules shows, asking for a pronunciation lexicon file.
        InterfaceText.line("pronunciationLexicon.importPanelMessage", "Choose a pronunciation lexicon file to add as rules.")
    }
    /// The message of the Save panel Export names a file in.
    static var exportPanelMessage: String {
        // Translators: Message of the Save panel that Export Rules shows.
        InterfaceText.line("pronunciationLexicon.exportPanelMessage", "Save your rules as a pronunciation lexicon file.")
    }
    /// The name the Save panel offers.
    static let exportFileName = "Substitution Rules.pls" // l10n: no (file name offered by the Save panel, kept English like every file name TextMouth writes)

    // MARK: - Import

    /// The title of the alert after an import that added rules or found
    /// everything already there.
    static var importedTitle: String {
        // Translators: Title of the alert after a pronunciation lexicon was imported as substitution rules.
        InterfaceText.line("pronunciationLexicon.importedTitle", "Rules Imported")
    }
    /// The title of the alert after an import that could not read its file.
    static var importFailedTitle: String {
        // Translators: Title of the alert when a pronunciation lexicon file could not be imported.
        InterfaceText.line("pronunciationLexicon.importFailedTitle", "Import Failed")
    }

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
                // Translators: A sentence of the alert after a pronunciation lexicon import: nothing was added. %@ is the file's name.
                ? InterfaceText.line("pronunciationLexicon.imported.noAdded", "No rules were added from “\(fileName)”.")
                // Translators: A sentence of the alert after a pronunciation lexicon import. %1$lld is the number of rules added; %2$@ is the file's name.
                : InterfaceText.line("pronunciationLexicon.imported.added", "Added \(number: added) rules from “\(fileName)”.")
        ]
        if alreadyPresent > 0 {
            sentences.append(
                // Translators: A sentence of the alert after a pronunciation lexicon import. %lld is the number of the lexicon's rules that the user's rules already held.
                InterfaceText.line("pronunciationLexicon.imported.already", "\(number: alreadyPresent) rules were already in your rules.")
            )
        }
        if setAside > 0 {
            sentences.append(
                // Translators: A sentence of the alert after a pronunciation lexicon import. %lld is the number of entries that give only a phonetic spelling.
                InterfaceText.line("pronunciationLexicon.imported.phonetic", "\(number: setAside) entries give only a phonetic spelling, so they were set aside.")
            )
        }
        if unread > 0 {
            // The limit is written grouped for the region ("5,000"), like every count of rules; it is
            // a fixed cap, always a plural count of rules, so the sentence's plural varies on `unread` only.
            let limit = PronunciationLexicon.ruleLimit.interfaceFormatted()
            sentences.append(
                // Translators: A sentence of the alert after a pronunciation lexicon import. %1$lld is the number of entries left unread; %2$@ is the most rules one import adds, written as a grouped number (a fixed cap, always a plural count).
                InterfaceText.line("pronunciationLexicon.imported.because", "\(number: unread) entries were not read, because a lexicon adds at most \(limit) rules at a time.")
            )
        }
        return SentenceWording.joined(sentences)
    }

    /// Why a file could not be read as a lexicon.
    static func importFailure(fileName: String, _ error: PronunciationLexicon.ReadError?) -> String {
        switch error {
        case .notXML?:
            // Translators: Message of the alert when a file chosen as a pronunciation lexicon is not valid XML. %@ is the file's name.
            return InterfaceText.line("pronunciationLexicon.importFailure.notXML", "“\(fileName)” is not a complete, valid XML file.")
        case .notALexicon?:
            // Translators: Message of the alert when a file chosen as a pronunciation lexicon is XML of another kind. %@ is the file's name.
            return InterfaceText.line("pronunciationLexicon.importFailure.notALexicon", "“\(fileName)” is an XML file, but not a pronunciation lexicon.")
        case .declaresEntities?:
            // Translators: Message of the alert when a pronunciation lexicon declares XML entities, which are refused for safety. %@ is the file's name.
            return InterfaceText.line("pronunciationLexicon.declaresEntities", "“\(fileName)” uses XML entities of its own, which TextMouth does not read.")
        case .tooLarge?:
            // Translators: Message of the alert when a pronunciation lexicon file is too large. %@ is the file's name.
            return InterfaceText.line("pronunciationLexicon.importFailure.tooLarge", "“\(fileName)” is too large to read.")
        case nil:
            // Translators: Message of the alert when a pronunciation lexicon file could not be read at all. %@ is the file's name.
            return InterfaceText.line("pronunciationLexicon.importFailure.nil", "TextMouth could not read “\(fileName)”.")
        }
    }

    // MARK: - Export

    /// The title of the alert after rules were written.
    static var exportedTitle: String {
        // Translators: Title of the alert after substitution rules were saved as a pronunciation lexicon.
        InterfaceText.line("pronunciationLexicon.exportedTitle", "Rules Exported")
    }
    /// The title of the alert when no rule can be written, or the file could not be.
    static var exportFailedTitle: String {
        // Translators: Title of the alert when substitution rules could not be saved as a pronunciation lexicon.
        InterfaceText.line("pronunciationLexicon.exportFailedTitle", "Export Failed")
    }

    /// The sentence after an export: how many rules were written, and how
    /// many were left out and why.
    ///
    /// "Exported 5 rules to “rules.pls”. 2 rules were left out, because a
    /// regular expression or a rule that is off cannot be written in a lexicon."
    static func exported(fileName: String, written: Int, leftOut: Int) -> String {
        var sentences = [
            // Translators: A sentence of the alert after substitution rules were saved as a pronunciation lexicon. %1$lld is the number of rules written; %2$@ is the file's name.
            InterfaceText.line("pronunciationLexicon.exported.rules", "Exported \(number: written) rules to “\(fileName)”.")
        ]
        if leftOut > 0 {
            sentences.append(
                // Translators: A sentence of the alert after substitution rules were saved as a pronunciation lexicon. %lld is the number of rules left out.
                InterfaceText.line("pronunciationLexicon.exported.expressions", "\(number: leftOut) rules were left out: regular expressions and rules that are off cannot be written in a lexicon.")
            )
        }
        return SentenceWording.joined(sentences)
    }

    /// The sentence when no rule can be written at all.
    static var nothingToExport: String {
        // Translators: Message of the alert when Export Rules finds no rule it can write as a pronunciation lexicon.
        InterfaceText.line("pronunciationLexicon.nothingToExport", "No rules to export: only plain text rules that are on can be written in a lexicon.")
    }

    /// The sentence when the file could not be saved.
    static func exportWriteFailure(fileName: String) -> String {
        // Translators: Message of the alert when a pronunciation lexicon file could not be saved. %@ is the file's name.
        InterfaceText.line("pronunciationLexicon.exportWriteFailure", "TextMouth could not save “\(fileName)”.")
    }
}
