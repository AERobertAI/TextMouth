import SwiftUI

// MARK: - Wording

/// Every sentence the Braille tab of Settings shows or speaks (FMT21), the
/// braille file characters pop-up's among them (braillecodes), kept
/// together so a test pins each one exactly.
enum BrailleSettingsWording {
    /// The tab's name in the Settings window's toolbar.
    static var tabTitle: String {
        // Translators: The name of the Braille tab in the Settings window's toolbar.
        InterfaceText.line("common.braille", "Braille")
    }
    /// The heading of the tab's only group.
    static var sectionHeader: String {
        // Translators: The heading of the Braille tab's only group in Settings.
        InterfaceText.line("common.braille", "Braille")
    }
    /// The label of the pop-up that chooses the language, before the code
    /// (October 20, 2026, decision 4); Export's braille options share it.
    static var languageLabel: String {
        // Translators: The label of the pop-up that chooses the language of a braille code, in the Braille tab of Settings and in the Export dialog's braille options.
        InterfaceText.line("common.language", "Language")
    }
    /// What the language pop-up does, spoken after its label and value.
    static var languageHint: String {
        // Translators: The hint of the language pop-up in the Braille tab of Settings.
        InterfaceText.line("brailleSettings.languageHint", "The language of the braille code for reading and writing braille.")
    }
    /// The label of the pop-up that chooses the braille code.
    static var codeLabel: String {
        // Translators: The label of the pop-up that chooses the braille code, in the Braille tab of Settings and in the Export dialog's braille options.
        InterfaceText.line("brailleSettings.codeLabel", "Braille code")
    }
    /// What the code pop-up does, spoken after its label and value.
    static var codeHint: String {
        // Translators: The hint of the braille code pop-up in the Braille tab of Settings.
        InterfaceText.line("brailleSettings.codeHint", "The braille code for reading and writing braille.")
    }
    /// The label of the pop-up that chooses how far the code contracts.
    static var contractionLabel: String {
        // Translators: The label of the pop-up that chooses how far a braille code contracts words, in the Braille tab of Settings and in the Export dialog's braille options.
        InterfaceText.line("brailleSettings.contractionLabel", "Contraction")
    }
    /// What the contraction pop-up does, spoken after its label and value.
    static var contractionHint: String {
        // Translators: The hint of the contraction pop-up in the Braille tab of Settings.
        InterfaceText.line("brailleSettings.contractionHint", "Whether that code's braille is contracted, which writes common words and letter groups in fewer cells.")
    }
    /// The label of the pop-up that chooses how a BRF or BRL file writes
    /// each braille cell as a character, its braille file code
    /// (braillecodes); the Braille tab and Export's braille options share
    /// it, as they share the labels above.
    static var fileCodeLabel: String {
        // Translators: The label of the pop-up that chooses which characters a BRF or BRL braille file uses for the braille cells, in the Braille tab of Settings and in the Export dialog's braille options.
        InterfaceText.line("brailleSettings.fileCodeLabel", "Braille file characters")
    }
    /// What the Braille tab's braille file characters pop-up does, spoken
    /// after its label and value (BRAILLE-CODES-RESEARCH-2026-10-25.md,
    /// section 8.3).
    static var fileCodeHint: String {
        // Translators: The hint of the braille file characters pop-up in the Braille tab of Settings. BRF and BRL are braille file formats, and North American Braille ASCII is the name of a braille character code.
        InterfaceText.line("brailleSettings.fileCodeHint", "How a BRF or BRL file writes each braille cell. Most files use North American Braille ASCII.")
    }
    /// The caption under the code pop-ups: where the code is used, and what it
    /// leaves alone.
    static var caption: String {
        // Translators: The caption under the code pop-ups in the Braille tab of Settings. BRF, BRL, and PEF are braille file formats.
        InterfaceText.line("brailleSettings.caption", "TextMouth reads braille files (BRF, BRL, and PEF) with this code and exports with it unless the Export dialog chooses another. A book keeps the code it was imported with.")
    }
    /// The caption under the braille file characters pop-up, which follows
    /// the code's caption, so neither caption is heard as the other's (the
    /// review of October 30, finding 7): which files the characters apply
    /// to, that Unicode braille patterns are recognized rather than chosen,
    /// that a BRF export starts with them, and what a book keeps.
    static var fileCodeCaption: String {
        // Translators: The caption under the braille file characters pop-up in the Braille tab of Settings. BRF and BRL are braille file formats, and Book Information is a window.
        InterfaceText.line("brailleSettings.fileCodeCaption", "TextMouth reads BRF and BRL files you add from now on with these characters, and recognizes Unicode braille patterns by itself. The Export dialog starts a BRF with them. A book keeps its import characters, which Book Information can change.")
    }
    /// The label of the switch that turns the guess of a braille book's code
    /// at import on or off (brfguess).
    static var guessLabel: String {
        // Translators: The label of the switch in the Braille tab of Settings that turns on guessing the braille code of a book at import.
        InterfaceText.line("brailleSettings.guessLabel", "Guess the braille code of new books")
    }
    /// What the switch does, spoken after its label and value.
    static var guessHint: String {
        // Translators: The hint of the guess switch in the Braille tab of Settings. Unified English Braille and English Braille, American Edition are the names of braille codes.
        InterfaceText.line("brailleSettings.guessHint", "When on, a braille file read as contracted Unified English Braille that is clearly English Braille, American Edition is read as that instead.")
    }
    /// The caption under the switch: when the guess is made and where it shows.
    static var guessCaption: String {
        // Translators: The caption under the guess switch in the Braille tab of Settings. English Braille, American Edition is the name of a braille code, and Book Information is a window.
        InterfaceText.line("brailleSettings.guessCaption", "Only a book that clearly shows English Braille, American Edition changes, when added. Book Information says the code was guessed and can choose another.")
    }
    /// What the group says in place of the pop-ups when the app's bundle
    /// holds no braille tables.
    static var noTables: String {
        // Translators: Shown in the Braille tab of Settings in place of the pop-ups when the app holds no braille tables.
        InterfaceText.line("brailleSettings.noTables", "TextMouth found no braille tables in its bundle.")
    }

    /// The sentence under the pop-ups that says where the chosen table comes
    /// from (decision 4): built into TextMouth, or this Mac's VoiceOver
    /// tables, each with its liblouis version when known, or that this Mac
    /// no longer has the chosen Mac table (`isOffered` false), as after a
    /// macOS update that removed it.
    static func source(ofTable tableID: String, isOffered: Bool, macLiblouisVersion: String?, writesOnly: Bool = false) -> String {
        // (The value is the lists' spelling of the table: see `source(ofStored:codes:macLiblouisVersion:)`.)
        // A table the setting already names that only writes braille (FR40): it keeps working, and is not offered here.
        guard !writesOnly else {
            // Translators: Under the pop-ups in the Braille tab of Settings: the table chosen earlier only writes braille from print, so it is not among the choices for reading. Choosing another is the way to change it.
            return InterfaceText.line("brailleSettings.source.writesOnly", "The chosen table only writes braille, so it is not offered for reading braille files; choose another.")
        }
        // A table the lists do not offer is never said to be built in: a bare value the app's own pack lacks is no table of it.
        guard isOffered else {
            // Translators: Under the pop-ups in the Braille tab of Settings: the chosen braille table of this Mac is gone. %@ is the table's stored name, "mac:" and its file name.
            return InterfaceText.line("brailleSettings.source.another", "This Mac no longer has the chosen table, \u{201C}\(tableID)\u{201D}; choose another.")
        }
        guard BrailleTableSource.parse(tableID).source == .mac else {
            // Translators: Under the pop-ups in the Braille tab of Settings: the chosen braille table comes with TextMouth. %@ is the version of liblouis, the braille library, written as a version number.
            return InterfaceText.line("brailleSettings.source.built", "The chosen table is built into TextMouth (liblouis \(BrailleTableCatalog.bundledLiblouisVersion)).")
        }
        guard let version = macLiblouisVersion else {
            // Translators: Under the pop-ups in the Braille tab of Settings: the chosen braille table is one of this Mac's.
            return InterfaceText.line("brailleSettings.source.voiceoverTables", "The chosen table is one of this Mac's VoiceOver braille tables.")
        }
        // Translators: Under the pop-ups in the Braille tab of Settings: the chosen braille table is one of this Mac's. %@ is the version of liblouis, the braille library, written as a version number.
        return InterfaceText.line("brailleSettings.source.voiceoverLiblouis", "The chosen table is one of this Mac's VoiceOver braille tables (liblouis \(version)).")
    }

    /// The sentence for the table the stored value `stored` names, worked out in the lists' spelling of it: whether `codes`
    /// offer it, whether it only writes braille, and where it comes from. The one place the Braille tab asks, so an iPhone's
    /// bare value the Mac reads with VoiceOver's file is told as VoiceOver's, not as built in.
    static func source(ofStored stored: String, codes: [BrailleCode], macLiblouisVersion: String?) -> String {
        let id = BrailleTableCatalog.listedID(forStored: stored)
        return source(
            ofTable: id,
            isOffered: BrailleSettingsChoice.table(ofStored: stored, in: codes) != nil,
            macLiblouisVersion: macLiblouisVersion,
            writesOnly: BrailleTableCatalog.table(withID: id)?.isPrintOnly == true
        )
    }

    /// What VoiceOver hears when one of this Mac's tables, chosen in the
    /// Braille tab or in Export's braille options, is refused by its check
    /// (decision 5): the table's display name and why. The pop-ups have
    /// already returned to the table in use. A check that could not be made
    /// says so, and why, and that choosing the table again tries again
    /// (review R7).
    static func refusal(ofTableNamed name: String, because refusal: MacBrailleTableCheck.Refusal) -> String {
        if refusal.isUnchecked {
            // Translators: Announced when one of this Mac's braille tables, just chosen, could not be checked. %1$@ is the table's name as macOS gives it and %2$@ the reason, a clause.
            return InterfaceText.line("brailleSettings.refusal.choose", "TextMouth could not check this Mac's table \u{201C}\(name)\u{201D}: \(refusal.reason). Choose it again to retry.")
        }
        // Translators: Announced when one of this Mac's braille tables, just chosen, was refused by its check. %1$@ is the table's name as macOS gives it and %2$@ the reason, a clause.
        return InterfaceText.line("brailleSettings.refusal.cant", "TextMouth can't use this Mac's table \u{201C}\(name)\u{201D}: \(refusal.reason).")
    }
}

// MARK: - Choices

/// The choices the Braille tab offers (FMT21), as pure functions of the
/// codes they are given, so a test can pass codes of its own.
enum BrailleSettingsChoice {
    /// Whether `chosen` is the table the stored value `stored` already names, whichever way the value is spelled: a choice of
    /// the table shown is no choice, and changes nothing (the pickers' guard).
    static func isShown(_ chosen: BrailleTable, stored: String) -> Bool {
        chosen.id == BrailleTableCatalog.listedID(forStored: stored)
    }

    /// The table of `codes` that the stored value `stored` names, matched in the lists' own spelling
    /// (`BrailleTableCatalog.listedID(forStored:)`), so a value stored as another platform spells it, an iPhone's bare
    /// `fr-bfu-g2.ctb` on the Mac, still finds its table. Nil when no code has it.
    static func table(ofStored stored: String, in codes: [BrailleCode]) -> BrailleTable? {
        let id = BrailleTableCatalog.listedID(forStored: stored)
        return codes.lazy.flatMap(\.tables).first { $0.id == id }
    }

    /// The table to use once `language` is chosen while `current` is the
    /// table in use (decision 4): in the language's code that holds the
    /// default table (Unified English Braille, for English), else in its
    /// first code, the table `table(in:matching:)` picks. Nil only for a
    /// language with no tables.
    static func table(in language: BrailleLanguage, matching current: BrailleTable?) -> BrailleTable? {
        let code = language.codes.first { code in code.tables.contains { $0.id == BrailleTableCatalog.defaultTableID } }
            ?? language.codes.first
        return code.flatMap { table(in: $0, matching: current) }
    }

    /// The table to use once `code` is chosen while `current` is the table
    /// in use: the code's table of the same contraction when it has one,
    /// else its `full` table, else its first. Nil only for a code with no
    /// tables.
    static func table(in code: BrailleCode, matching current: BrailleTable?) -> BrailleTable? {
        if let current, let same = code.tables.first(where: { $0.contraction == current.contraction }) {
            return same
        }
        return code.tables.first(where: { $0.contraction == .full }) ?? code.tables.first
    }
}

// MARK: - The Tab

/// The Braille tab of Settings (FMT21): the language, the braille code
/// TextMouth reads braille files with and writes braille in, and how far
/// that code contracts. The three pop-ups (`BrailleTablePickers`) edit one
/// setting, the table (`SettingsViewModel.brailleTable`, mirrored in
/// config.json), and offer the bundled tables and this Mac's (October 20,
/// 2026). Under them, one sentence says where the chosen table comes from,
/// and the code's caption follows. After it, a fourth pop-up chooses the
/// braille file characters an import reads a BRF or BRL file with, one of
/// the two seven-bit codes (braillecodes; `SettingsViewModel.brailleFileCode`,
/// mirrored in config.json too), which Export's braille options start from,
/// with a caption of its own (`trailingRows(for:)`).
/// If the bundle holds no tables, the tab says so instead of showing pop-ups
/// with nothing to choose; with no table, no braille can be read, so the
/// braille file characters pop-up is left out too.
struct BrailleSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// The codes the pop-ups offer: the bundled tables' and this Mac's,
    /// unless a test shows its own (an empty list is the broken bundle).
    var codes: [BrailleCode] = BrailleTableCatalog.offeredCodes

    /// The table in use, as the setting stores it (`SettingsViewModel.brailleTable`).
    private var tableBinding: Binding<String> {
        Binding(
            get: { settingsViewModel.brailleTable },
            set: { settingsViewModel.brailleTable = $0 }
        )
    }

    /// The braille file characters imports read a BRF or BRL file with, by
    /// the code's id, as the setting stores it
    /// (`SettingsViewModel.brailleFileCode`).
    private var fileCodeBinding: Binding<String> {
        Binding(
            get: { settingsViewModel.brailleFileCode },
            set: { settingsViewModel.brailleFileCode = $0 }
        )
    }

    /// What the group shows above its caption: the pop-ups, or the sentence
    /// that says the bundle holds no tables. A pure choice of the codes, so
    /// a test can pin it without drawing the view (hosted SwiftUI text is not
    /// exposed to the tests).
    enum Content: Equatable {
        /// The table pop-ups, the sentence that says where the table comes
        /// from, and the braille file characters pop-up.
        case choices
        /// The sentence shown instead of the pop-ups.
        case noTables(String)

        /// The content for `codes`: the pop-ups when there is a code to
        /// choose, else the no-tables sentence.
        static func of(codes: [BrailleCode]) -> Content {
            codes.isEmpty ? .noTables(BrailleSettingsWording.noTables) : .choices
        }
    }

    /// One row the group shows after the table pop-ups and their source
    /// sentence (or after the no-tables sentence).
    enum TrailingRow: Hashable {
        /// The code's caption (`BrailleSettingsWording.caption`).
        case caption
        /// The braille file characters pop-up.
        case fileCodePopUp
        /// The braille file characters' own caption
        /// (`BrailleSettingsWording.fileCodeCaption`).
        case fileCodeCaption
        /// The switch that turns the guess of a new book's code on or off
        /// (`BrailleSettingsWording.guessLabel`).
        case guessSwitch
        /// The switch's own caption (`BrailleSettingsWording.guessCaption`).
        case guessCaption
    }

    /// The rows after the table pop-ups, in reading order, which the body
    /// draws as listed (the review of October 30, finding 7): the code's
    /// caption first, then the braille file characters pop-up and its own
    /// caption, so neither caption is heard as the other's. With no tables,
    /// no braille can be read, so the caption is alone. A pure list, so a
    /// test pins the order without drawing the view, whose captions hosted
    /// tests cannot read.
    static func trailingRows(for content: Content) -> [TrailingRow] {
        content == .choices
            ? [.caption, .fileCodePopUp, .fileCodeCaption, .guessSwitch, .guessCaption]
            : [.caption]
    }

    /// The sentence that says where the table in use comes from
    /// (`BrailleSettingsWording.source(ofTable:isOffered:macLiblouisVersion:)`).
    private var sourceSentence: String {
        BrailleSettingsWording.source(
            ofStored: settingsViewModel.brailleTable, codes: codes, macLiblouisVersion: BrailleTableCatalog.mac?.liblouisVersion
        )
    }

    var body: some View {
        let content = Content.of(codes: codes)
        Form {
            Section {
                switch content {
                case .choices:
                    BrailleTablePickers(
                        table: tableBinding,
                        codes: codes,
                        languageHint: BrailleSettingsWording.languageHint,
                        codeHint: BrailleSettingsWording.codeHint,
                        contractionHint: BrailleSettingsWording.contractionHint
                    )
                    captionText(sourceSentence)
                case .noTables(let sentence):
                    Text(sentence)
                }
                // The code's caption, then the braille file characters with
                // a caption of their own, in the order `trailingRows(for:)`
                // pins, so the code's "this code" is never heard as theirs.
                ForEach(Self.trailingRows(for: content), id: \.self) { row in
                    switch row {
                    case .caption:
                        captionText(BrailleSettingsWording.caption)
                    case .fileCodePopUp:
                        fileCodePicker
                    case .fileCodeCaption:
                        captionText(BrailleSettingsWording.fileCodeCaption)
                    case .guessSwitch:
                        // An explicit binding, so the settings model announces the change.
                        Toggle(BrailleSettingsWording.guessLabel, isOn: Binding(
                            get: { settingsViewModel.guessesBrailleTable },
                            set: { settingsViewModel.guessesBrailleTable = $0 }
                        ))
                        .accessibilityLabel(BrailleSettingsWording.guessLabel)
                        .accessibilityHint(BrailleSettingsWording.guessHint)
                    case .guessCaption:
                        captionText(BrailleSettingsWording.guessCaption)
                    }
                }
            } header: {
                Text(BrailleSettingsWording.sectionHeader)
            }
        }
    }

    /// `text` drawn as the tab's captions are: small, secondary, and wrapped.
    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The pop-up of braille file characters: the codes an import may be
    /// set to (`BrailleFileCode.importChoices`, the two seven-bit codes; a
    /// file of Unicode braille patterns is recognized by its bytes, never
    /// chosen, review finding 4), each listed by its name and tagged by its
    /// id, drawn by the form as it draws the table pop-ups. The selected
    /// code's name is its value, so VoiceOver says "North American Braille
    /// ASCII, Braille file characters, pop-up button".
    private var fileCodePicker: some View {
        Picker(BrailleSettingsWording.fileCodeLabel, selection: fileCodeBinding) {
            ForEach(BrailleFileCode.importChoices) { code in
                Text(code.name).tag(code.id)
            }
        }
        .accessibilityLabel(BrailleSettingsWording.fileCodeLabel)
        .accessibilityHint(BrailleSettingsWording.fileCodeHint)
    }
}
