import SwiftUI

// MARK: - Wording

/// Every sentence the Braille tab of Settings shows or speaks (FMT21),
/// kept together so a test pins each one exactly.
enum BrailleSettingsWording {
    /// The tab's name in the Settings window's toolbar.
    static let tabTitle = "Braille"
    /// The heading of the tab's only group.
    static let sectionHeader = "Braille"
    /// The label of the pop-up that chooses the braille code.
    static let codeLabel = "Braille code"
    /// What the code pop-up does, spoken after its label and value.
    static let codeHint = "The braille code TextMouth reads braille files with and writes braille in."
    /// The label of the pop-up that chooses how far the code contracts.
    static let contractionLabel = "Contraction"
    /// What the contraction pop-up does, spoken after its label and value.
    static let contractionHint =
        "Whether that code's braille is contracted. Contracted braille writes common words and letter groups in fewer cells."
    /// The caption under the pop-ups: where the setting is used, and what it
    /// leaves alone.
    static let caption =
        "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog. A book keeps the code it was imported with."
    /// What the group says in place of the pop-ups when the app's bundle
    /// holds no braille tables.
    static let noTables = "TextMouth found no braille tables in its bundle."
}

// MARK: - Choices

/// The choices the Braille tab offers (FMT21), as pure functions of the
/// codes they are given, so a test can pass codes of its own.
enum BrailleSettingsChoice {
    /// The codes of one language, as the code pop-up groups them.
    struct LanguageGroup: Identifiable {
        /// The language, such as "en".
        let language: String
        /// The language's codes, in the order the catalog gives them.
        var codes: [BrailleCode]

        var id: String { language }
    }

    /// The codes grouped by language, in the order each language first
    /// appears, each group keeping the codes' order.
    static func languageGroups(of codes: [BrailleCode]) -> [LanguageGroup] {
        var groups: [LanguageGroup] = []
        for code in codes {
            if let index = groups.firstIndex(where: { $0.language == code.language }) {
                groups[index].codes.append(code)
            } else {
                groups.append(LanguageGroup(language: code.language, codes: [code]))
            }
        }
        return groups
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

/// The Braille tab of Settings (FMT21): the braille code TextMouth reads
/// braille files with and writes braille in, and how far that code
/// contracts. Both pop-ups edit one setting, the table
/// (`SettingsViewModel.brailleTable`, mirrored in config.json); the first
/// chooses the table's code and the second its contraction, so each offers
/// only what the bundled tables have. If the bundle holds no tables, the tab
/// says so instead of showing pop-ups with nothing to choose.
struct BrailleSettingsView: View {
    @EnvironmentObject var settingsViewModel: SettingsViewModel

    /// The codes the pop-up offers: the bundled ones, unless a test shows
    /// its own (an empty list is the broken bundle).
    var codes: [BrailleCode] = BrailleTableCatalog.bundledCodes

    /// The table in use, as the setting stores it (`SettingsViewModel.brailleTable`).
    private var tableBinding: Binding<String> {
        Binding(
            get: { settingsViewModel.brailleTable },
            set: { settingsViewModel.brailleTable = $0 }
        )
    }

    /// What the group shows above its caption: the two pop-ups, or the
    /// sentence that says the bundle holds no tables. A pure choice of the
    /// codes, so a test can pin it without drawing the view (hosted SwiftUI
    /// text is not exposed to the tests).
    enum Content: Equatable {
        /// The code and contraction pop-ups.
        case choices
        /// The sentence shown instead of the pop-ups.
        case noTables(String)

        /// The content for `codes`: the pop-ups when there is a code to
        /// choose, else the no-tables sentence.
        static func of(codes: [BrailleCode]) -> Content {
            codes.isEmpty ? .noTables(BrailleSettingsWording.noTables) : .choices
        }
    }

    var body: some View {
        Form {
            Section {
                switch Content.of(codes: codes) {
                case .choices:
                    BrailleTablePickers(
                        table: tableBinding,
                        codes: codes,
                        codeHint: BrailleSettingsWording.codeHint,
                        contractionHint: BrailleSettingsWording.contractionHint
                    )
                case .noTables(let sentence):
                    Text(sentence)
                }
                Text(BrailleSettingsWording.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text(BrailleSettingsWording.sectionHeader)
            }
        }
    }
}
