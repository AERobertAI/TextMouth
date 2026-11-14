import SwiftUI

// MARK: - Wording

/// Every sentence the Braille tab of Settings shows or speaks (FMT21), the
/// braille file characters pop-up's among them (braillecodes), kept
/// together so a test pins each one exactly.
enum BrailleSettingsWording {
    /// The tab's name in the Settings window's toolbar.
    static let tabTitle = "Braille"
    /// The heading of the tab's only group.
    static let sectionHeader = "Braille"
    /// The label of the pop-up that chooses the language, before the code
    /// (October 20, 2026, decision 4); Export's braille options share it.
    static let languageLabel = "Language"
    /// What the language pop-up does, spoken after its label and value.
    static let languageHint = "The language of the braille code TextMouth reads braille files with and writes braille in."
    /// The label of the pop-up that chooses the braille code.
    static let codeLabel = "Braille code"
    /// What the code pop-up does, spoken after its label and value.
    static let codeHint = "The braille code TextMouth reads braille files with and writes braille in."
    /// The label of the pop-up that chooses how far the code contracts.
    static let contractionLabel = "Contraction"
    /// What the contraction pop-up does, spoken after its label and value.
    static let contractionHint =
        "Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells."
    /// The label of the pop-up that chooses how a BRF or BRL file writes
    /// each braille cell as a character, its braille file code
    /// (braillecodes); the Braille tab and Export's braille options share
    /// it, as they share the labels above.
    static let fileCodeLabel = "Braille file characters"
    /// What the Braille tab's braille file characters pop-up does, spoken
    /// after its label and value (BRAILLE-CODES-RESEARCH-2026-10-25.md,
    /// section 8.3).
    static let fileCodeHint =
        "How a BRF or BRL file writes each braille cell as a character. Most files use North American Braille ASCII."
    /// The caption under the code pop-ups: where the code is used, and what it
    /// leaves alone.
    static let caption =
        "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with."
    /// The caption under the braille file characters pop-up, which follows
    /// the code's caption, so neither caption is heard as the other's (the
    /// review of October 30, finding 7): which files the characters apply
    /// to, that Unicode braille patterns are recognized rather than chosen,
    /// that a BRF export starts with them, and what a book keeps.
    static let fileCodeCaption =
        "TextMouth reads BRF and BRL files you add from now on with these characters; a file of Unicode braille patterns is recognized by itself. The Export dialog starts a BRF with them. A book keeps the characters it was imported with, which Book Information can change."
    /// The label of the switch that turns the guess of a braille book's code
    /// at import on or off (brfguess).
    static let guessLabel = "Guess the braille code of new books"
    /// What the switch does, spoken after its label and value.
    static let guessHint =
        "When on, a braille file read as Unified English Braille, contracted, that is clearly English Braille, American Edition, is read with that code instead."
    /// The caption under the switch: when the guess is made and where it shows.
    static let guessCaption =
        "Only a book that clearly shows English Braille, American Edition is changed, when it is added. Book Information says the code was guessed and can choose another."
    /// What the group says in place of the pop-ups when the app's bundle
    /// holds no braille tables.
    static let noTables = "TextMouth found no braille tables in its bundle."

    /// The sentence under the pop-ups that says where the chosen table comes
    /// from (decision 4): built into TextMouth, or this Mac's VoiceOver
    /// tables, each with its liblouis version when known, or that this Mac
    /// no longer has the chosen Mac table (`isOffered` false), as after a
    /// macOS update that removed it.
    static func source(ofTable tableID: String, isOffered: Bool, macLiblouisVersion: String?) -> String {
        guard BrailleTableSource.parse(tableID).source == .mac else {
            return "The chosen table is built into TextMouth (liblouis \(BrailleTableCatalog.bundledLiblouisVersion))."
        }
        guard isOffered else {
            return "This Mac no longer has the chosen table, \u{201C}\(tableID)\u{201D}; choose another."
        }
        guard let version = macLiblouisVersion else {
            return "The chosen table is one of this Mac's VoiceOver braille tables."
        }
        return "The chosen table is one of this Mac's VoiceOver braille tables (liblouis \(version))."
    }

    /// What VoiceOver hears when one of this Mac's tables, chosen in the
    /// Braille tab or in Export's braille options, is refused by its check
    /// (decision 5): the table's display name and why. The pop-ups have
    /// already returned to the table in use. A check that could not be made
    /// says so, and why, and that choosing the table again tries again
    /// (review R7).
    static func refusal(ofTableNamed name: String, because refusal: MacBrailleTableCheck.Refusal) -> String {
        if refusal.isUnchecked {
            return "TextMouth could not check this Mac's table \u{201C}\(name)\u{201D}: \(refusal.reason). Choose it again to try once more."
        }
        return "TextMouth can't use this Mac's table \u{201C}\(name)\u{201D}: \(refusal.reason)."
    }
}

// MARK: - Choices

/// The choices the Braille tab offers (FMT21), as pure functions of the
/// codes they are given, so a test can pass codes of its own.
enum BrailleSettingsChoice {
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
        let id = settingsViewModel.brailleTable
        return BrailleSettingsWording.source(
            ofTable: id,
            isOffered: codes.contains { code in code.tables.contains { $0.id == id } },
            macLiblouisVersion: BrailleTableCatalog.mac?.liblouisVersion
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
