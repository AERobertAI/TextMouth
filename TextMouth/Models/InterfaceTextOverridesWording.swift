import Foundation

/// What the Interface Language group of Settings says about the person's own interface lines (FR39), on the Mac (the top of
/// the Miscellaneous tab) and on the iPhone (its Language section), in one place so that the words on screen, VoiceOver, and
/// a braille display agree and tests can pin them.
///
/// The sentences are short, with the reason last, so that a list of them reads well one at a time.
enum InterfaceTextOverridesWording {
    // MARK: - Counts

    /// How many of the person's own lines are in use.
    static func inUse(_ count: Int) -> String {
        // Translators: A line in Settings under Interface Language. %lld is how many of the person's own lines, from the file interface_text.json in the data folder, are in use now.
        InterfaceText.line("interfaceTextFile.inUse", "Your own lines in use: \(number: count)")
    }

    /// How many of the person's own lines are ignored.
    static func ignored(_ count: Int) -> String {
        // Translators: A line in Settings under Interface Language. %lld is how many of the person's own lines, from the file interface_text.json in the data folder, are ignored because they break a rule; each is listed below with its reason.
        InterfaceText.line("interfaceTextFile.ignored", "Your own lines ignored: \(number: count)")
    }

    // MARK: - The lists

    /// One ignored line: its ID, its language, and the reason last.
    static func ignoredLine(id: String, language: String, reason: String) -> String {
        // Translators: One ignored line in the list under Interface Language. The first %@ is the line's ID (such as common.sleepTimer), the second the language's name, the third the reason, a whole sentence. Keep the reason last.
        InterfaceText.line("interfaceTextFile.ignoredLine", "Ignored line \(id) in \(language). \(reason)")
    }

    /// A line in use whose English has changed since the person wrote it.
    static func outdatedLine(id: String, language: String) -> String {
        // Translators: One line in the list under Interface Language. The first %@ is the ID of a line the person changed (such as common.sleepTimer), the second the language's name. The English the line was written against has changed since, and the person's line still applies.
        InterfaceText.line("interfaceTextFile.outdatedLine", "Check line \(id) in \(language). Its English has changed since you wrote it, and your line still applies.")
    }

    /// The whole file has a problem.
    static func fileProblemLine(reason: String) -> String {
        // Translators: A line in the list under Interface Language when the whole file of the person's own lines has a problem. %@ is the reason, a whole sentence.
        InterfaceText.line("interfaceTextFile.fileProblem", "Problem with your file of own lines. \(reason)")
    }

    /// The list stopped short: how many more ignored lines there are.
    static func moreIgnored(_ count: Int) -> String {
        // Translators: The last line of a long list of ignored lines under Interface Language. %lld is how many more lines are ignored than the list shows.
        InterfaceText.line("interfaceTextFile.moreIgnored", "And \(number: count) more ignored lines. The debug log lists each one.")
    }

    // MARK: - Reasons

    /// The reason a line is ignored, as a sentence.
    static func reason(_ reason: InterfaceTextIgnoredReason) -> String {
        switch reason {
        case .unknownLanguage:
            // Translators: The reason a line of the person's own lines is ignored: its language is not one TextMouth has.
            return InterfaceText.line("interfaceTextFile.reason.unknownLanguage", "TextMouth does not have that language.")
        case .unknownID:
            // Translators: The reason a line of the person's own lines is ignored: TextMouth has no line with that ID.
            return InterfaceText.line("interfaceTextFile.reason.unknownID", "TextMouth has no line with that ID.")
        case .noEnglish:
            // Translators: The reason a line of the person's own lines is ignored: TextMouth holds no English for it to compare with.
            return InterfaceText.line("interfaceTextFile.reason.noEnglish", "TextMouth has no English for it to be compared with.")
        case .notALine:
            // Translators: The reason a line of the person's own lines is ignored: it is not a text, or a set of plural forms, in the form the file has.
            return InterfaceText.line("interfaceTextFile.reason.notALine", "It is not a text or a set of plural forms.")
        case .noText:
            // Translators: The reason a line of the person's own lines is ignored: it has neither a text nor plural forms.
            return InterfaceText.line("interfaceTextFile.reason.noText", "It has no text.")
        case .bothTextAndPlural:
            // Translators: The reason a line of the person's own lines is ignored: it has both a text and plural forms.
            return InterfaceText.line("interfaceTextFile.reason.bothTextAndPlural", "It has both a text and plural forms.")
        case .textForPluralLine:
            // Translators: The reason a line of the person's own lines is ignored: the line has plural forms (one for each count), and the person gave one text.
            return InterfaceText.line("interfaceTextFile.reason.textForPluralLine", "That line needs plural forms, not one text.")
        case .pluralForPlainLine:
            // Translators: The reason a line of the person's own lines is ignored: the line has one text, and the person gave plural forms.
            return InterfaceText.line("interfaceTextFile.reason.pluralForPlainLine", "That line takes one text, not plural forms.")
        case .unsupportedSpecifier:
            // Translators: The reason a line of the person's own lines is ignored: it has a percent sign that is not one of the allowed placeholders (%@, %lld, or the numbered forms %1$@ and %1$lld, and %% for a percent sign).
            return InterfaceText.line("interfaceTextFile.reason.unsupportedSpecifier", "It has a percent sign that is not an allowed placeholder.")
        case .mixedPlaceholders:
            // Translators: The reason a line of the person's own lines is ignored: it mixes numbered placeholders (such as %1$@) with unnumbered ones (%@).
            return InterfaceText.line("interfaceTextFile.reason.mixedPlaceholders", "It mixes numbered and unnumbered placeholders.")
        case .placeholdersDiffer:
            // Translators: The reason a line of the person's own lines is ignored: its placeholders (the parts such as %@ and %lld that TextMouth fills in) differ from the English line's in number or kind.
            return InterfaceText.line("interfaceTextFile.reason.placeholdersDiffer", "Its placeholders differ from the English line's.")
        case .percentSignsDiffer:
            // Translators: The reason a line of the person's own lines is ignored: it has a different number of doubled percent signs (%%, which shows one percent sign) than the English line.
            return InterfaceText.line("interfaceTextFile.reason.percentSignsDiffer", "Its doubled percent signs differ in number from the English line's.")
        case .wrongPluralForms:
            // Translators: The reason a line of the person's own lines is ignored: its plural forms are not exactly the ones its language uses.
            return InterfaceText.line("interfaceTextFile.reason.wrongPluralForms", "Its plural forms are not the ones this language uses.")
        case .emptyForm:
            // Translators: The reason a line of the person's own lines is ignored: one of its texts is empty.
            return InterfaceText.line("interfaceTextFile.reason.emptyForm", "One of its texts is empty.")
        case .controlCharacter:
            // Translators: The reason a line of the person's own lines is ignored: one of its texts has an invisible control character other than a line break or a tab.
            return InterfaceText.line("interfaceTextFile.reason.controlCharacter", "One of its texts has a control character.")
        }
    }

    /// The reason a whole file is ignored, as a sentence.
    static func reason(_ problem: InterfaceTextFileProblem) -> String {
        switch problem {
        case .notJSON:
            // Translators: The reason the whole file of the person's own interface lines is ignored: it is not valid JSON.
            return InterfaceText.line("interfaceTextFile.problem.notJSON", "The file is not valid JSON.")
        case .notThisShape:
            // Translators: The reason the whole file of the person's own interface lines is ignored: it is not a set of languages, each holding lines.
            return InterfaceText.line("interfaceTextFile.problem.notThisShape", "The file is not a set of languages, each with its lines.")
        case .unknownVersion:
            // Translators: The reason the whole file of the person's own interface lines is ignored: its version is not one this TextMouth reads.
            return InterfaceText.line("interfaceTextFile.problem.unknownVersion", "The file's version is not one TextMouth reads.")
        case .tooLarge:
            // Translators: The reason the whole file of the person's own interface lines is ignored: it is far larger than any such file.
            return InterfaceText.line("interfaceTextFile.problem.tooLarge", "The file is too large.")
        case .unreadable:
            // Translators: The reason the whole file of the person's own interface lines could not be used: it could not be read, so the lines already in use stay.
            return InterfaceText.line("interfaceTextFile.problem.unreadable", "The file could not be read, so the lines in use stay.")
        }
    }

    // MARK: - Commands

    /// The Mac's Edit Interface Text… button.
    static var editTitle: String {
        // Translators: A button in Settings under Interface Language, on the Mac. It opens the file of the person's own interface lines in their editor, after filling it with the current text if it has none for this language.
        InterfaceText.line("interfaceTextFile.editTitle", "Edit Interface Text…")
    }

    /// The Mac's Edit Interface Text… hint.
    static var editHint: String {
        // Translators: VoiceOver hint of the Edit Interface Text button on the Mac. The file is interface_text.json in the data folder.
        InterfaceText.line("interfaceTextFile.editHint", "Opens the file of your own lines in your editor. If it has none for this language, it first fills in every line as it reads now.")
    }

    /// The Export Interface Text… button, on both apps.
    static var exportTitle: String {
        // Translators: A button in Settings under Interface Language. It saves every line of the interface language, as it reads now, to a file the person chooses.
        InterfaceText.line("interfaceTextFile.exportTitle", "Export Interface Text…")
    }

    /// The Export Interface Text… hint.
    static var exportHint: String {
        // Translators: VoiceOver hint of the Export Interface Text button. Lines the person changed are marked in the file.
        InterfaceText.line("interfaceTextFile.exportHint", "Saves every line of the interface language as it reads now, with your own lines marked, to a file you choose.")
    }

    /// Why Edit could not make the file.
    static var editFailed: String {
        // Translators: VoiceOver announcement when Edit Interface Text could not fill in or open the file of the person's own lines.
        InterfaceText.line("interfaceTextFile.editFailed", "The file of your own lines could not be made.")
    }

    /// Why Export could not write the file.
    static var exportFailed: String {
        // Translators: VoiceOver announcement when Export Interface Text could not write its file.
        InterfaceText.line("interfaceTextFile.exportFailed", "The interface text could not be exported.")
    }

    /// Export wrote its file.
    static func exported(fileName: String) -> String {
        // Translators: VoiceOver announcement after Export Interface Text saved its file. %@ is the file's name.
        InterfaceText.line("interfaceTextFile.exported", "Exported the interface text to \(fileName).")
    }
}

/// What the group says now, from what reading the person's file came to: the two counts, then the sentences, one for each
/// problem, which the Mac and the iPhone each draw in their own rows.
struct InterfaceTextOverridesSummary: Equatable {
    /// The most ignored lines listed; the counts stay exact, and the debug log lists each one.
    static let largestList = 50

    /// "Your own lines in use: 3".
    let inUse: String
    /// "Your own lines ignored: 1".
    let ignored: String
    /// A sentence for the file's problem if it has one, each ignored line, a line saying how many more there are when the
    /// list is cut, and each line in use whose English has changed; empty when there is nothing to say.
    let details: [String]

    /// The summary of `outcome`, naming each language by `languageName` (its name in the interface language).
    init(_ outcome: InterfaceTextOverridesOutcome, languageName: (String) -> String = { code in
        InterfaceLanguagePicker.name(of: code, in: InterfaceLanguage.current.language)
    }) {
        inUse = InterfaceTextOverridesWording.inUse(outcome.inUse.count)
        ignored = InterfaceTextOverridesWording.ignored(outcome.ignored.count)
        var sentences: [String] = []
        if let problem = outcome.fileProblem {
            sentences.append(InterfaceTextOverridesWording.fileProblemLine(reason: InterfaceTextOverridesWording.reason(problem)))
        }
        for line in outcome.ignored.prefix(Self.largestList) {
            sentences.append(InterfaceTextOverridesWording.ignoredLine(
                id: line.key.id,
                language: languageName(line.key.language),
                reason: InterfaceTextOverridesWording.reason(line.reason)
            ))
        }
        if outcome.ignored.count > Self.largestList {
            sentences.append(InterfaceTextOverridesWording.moreIgnored(outcome.ignored.count - Self.largestList))
        }
        for key in outcome.outdatedEnglish.prefix(Self.largestList) {
            sentences.append(InterfaceTextOverridesWording.outdatedLine(id: key.id, language: languageName(key.language)))
        }
        details = sentences
    }
}
