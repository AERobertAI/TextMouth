import SwiftUI

// MARK: - Wording

/// Every sentence the braille options of the Export dialog show or speak
/// (FMT22, Phase B), kept together so a test pins each one exactly. The
/// language, code, and contraction pop-ups keep the labels of the Braille
/// tab (`BrailleSettingsWording`), and its sentence for a refused Mac table,
/// and have hints of their own, which speak of the book rather than of
/// reading braille files.
enum BrailleExportWording {
    /// What the language pop-up does, spoken after its label and value
    /// (October 20, 2026).
    static let languageHint = "The language of the braille code the book is written in."
    /// What the braille code pop-up does, spoken after its label and value.
    static let codeHint = "The braille code the book is written in."
    /// What the contraction pop-up does, spoken after its label and value.
    static let contractionHint = "Whether that code's braille is contracted."

    /// The label of the stepper that sets the cells in a line.
    static let cellsLabel = "Cells per line"
    /// What the cells stepper does.
    static let cellsHint = "How many braille cells each line holds, from 18 to 80."
    /// The cells stepper's spoken value, such as "40 cells".
    static func cellsValue(_ count: Int) -> String {
        "\(count) cells"
    }

    /// The label of the stepper that sets the lines on a page.
    static let linesLabel = "Lines per page"
    /// What the lines stepper does.
    static let linesHint = "How many lines each braille page holds, from 4 to 50."
    /// The lines stepper's spoken value, such as "25 lines".
    static func linesValue(_ count: Int) -> String {
        "\(count) lines"
    }

    /// The label of the switch that numbers the pages.
    static let numbersLabel = "Braille page numbers"
    /// What the page numbers switch does.
    static let numbersHint = "Whether each page's last line carries its braille page number."

    /// The label of the pop-up that chooses the line end (BRF only).
    static let lineEndsLabel = "Line ends"
    /// What the line ends pop-up does.
    static let lineEndsHint = "CR LF suits most braille displays and embossers."
    /// The line end of carriage return and line feed, as the pop-up lists it.
    static let crlfName = "CR LF"
    /// The line end of line feed alone, as the pop-up lists it.
    static let lfName = "LF"

    /// The pop-up's name for `lineEnd`.
    static func name(of lineEnd: BrailleLineEnd) -> String {
        switch lineEnd {
        case .crlf: return crlfName
        case .lf: return lfName
        }
    }

    /// What the options say when the Braille setting's table, `table`, is one
    /// of this Mac's that this Mac cannot use, and the export starts from
    /// the default table instead (review R4).
    static func startsFromDefault(replacing table: String) -> String {
        "TextMouth can't use the braille table chosen in Settings, \u{201C}\(table)\u{201D}, so this export starts from "
            + "\(BrailleTableCatalog.description(ofTableID: BrailleTableCatalog.defaultTableID))."
    }
}

// MARK: - The Table Pop-ups

/// The three pop-ups that choose a braille table, as the Braille tab of
/// Settings has them (FMT21, FMT22; the language since October 20, 2026):
/// the language, the braille code, and how far that code contracts. They
/// edit one table, by its stored value; the first chooses the table's
/// language, the second its code among that language's, and the third its
/// contraction, so each offers only what the tables have
/// (`BrailleSettingsChoice`). The Braille tab and Export's braille options
/// both draw these pop-ups, so the two can never differ (decision 4).
///
/// The bundled tables are taken at once. One of this Mac's is taken only
/// once its check passes (`MacBrailleTableCheck`, decision 5), made off the
/// main thread; while it runs the pop-ups show the choice and nothing else
/// waits. A table that fails is not taken: the pop-ups return to the table
/// in use, and VoiceOver hears the table's name and why.
///
/// Their labels are the Braille tab's. The pop-up style and size are the
/// caller's (a form draws them its way, the Export dialog as menus), and so
/// are the hints, since each place speaks of a different use of the table.
struct BrailleTablePickers: View {
    /// The table in use, by its stored value.
    @Binding var table: String
    /// The codes the pop-ups offer: the bundled tables' and this Mac's,
    /// unless a test shows its own (an empty list is the broken bundle,
    /// which draws nothing).
    let codes: [BrailleCode]
    /// What the language pop-up does.
    let languageHint: String
    /// What the code pop-up does.
    let codeHint: String
    /// What the contraction pop-up does.
    let contractionHint: String
    /// The languages of `codes`, in the order the language pop-up lists them.
    private let languages: [BrailleLanguage]

    /// One of this Mac's tables chosen and being checked, which the pop-ups
    /// show until its check ends; nil when none is.
    @State private var pending: String?

    /// Pop-ups for `table` among `codes`, with each pop-up's hint.
    init(
        table: Binding<String>,
        codes: [BrailleCode] = BrailleTableCatalog.offeredCodes,
        languageHint: String,
        codeHint: String,
        contractionHint: String
    ) {
        _table = table
        self.codes = codes
        self.languageHint = languageHint
        self.codeHint = codeHint
        self.contractionHint = contractionHint
        languages = BrailleTableCatalog.languages(of: codes)
    }

    /// The stored value the pop-ups show: the table being checked, else the
    /// table in use.
    private var shownID: String { pending ?? table }

    /// The table the pop-ups show, when one of the codes has it.
    private var currentTable: BrailleTable? {
        codes.lazy.flatMap(\.tables).first { $0.id == shownID }
    }

    /// The language the pop-up shows: the shown table's, else the first (so
    /// the pop-up never shows a selection it has no item for).
    private var currentLanguage: BrailleLanguage? {
        currentTable.flatMap { table in languages.first { $0.codes.contains { $0.tables.contains(table) } } }
            ?? languages.first
    }

    /// The code the pop-up shows: the shown table's, else the first of the
    /// language shown.
    private var currentCode: BrailleCode? {
        let codes = currentLanguage?.codes ?? []
        return currentTable.flatMap { table in codes.first { $0.tables.contains(table) } } ?? codes.first
    }

    /// The language pop-up's selection: the shown language's identifier.
    /// Choosing a language takes its default code's table, else its first
    /// code's, of the current contraction where it can.
    private var languageSelection: Binding<String> {
        Binding(
            get: { currentLanguage?.id ?? "" },
            set: { id in
                guard let language = languages.first(where: { $0.id == id }),
                      let chosen = BrailleSettingsChoice.table(in: language, matching: currentTable) else { return }
                choose(chosen)
            }
        )
    }

    /// The code pop-up's selection: the shown code's identifier. Choosing a
    /// code takes its table of the current contraction.
    private var codeSelection: Binding<String> {
        Binding(
            get: { currentCode?.id ?? "" },
            set: { id in
                guard let code = currentLanguage?.codes.first(where: { $0.id == id }),
                      let chosen = BrailleSettingsChoice.table(in: code, matching: currentTable) else { return }
                choose(chosen)
            }
        )
    }

    /// The contraction pop-up's selection: the identifier of the shown
    /// table, or of the code's first table when the shown table is another
    /// code's.
    private var tableSelection: Binding<String> {
        Binding(
            get: {
                guard let code = currentCode else { return "" }
                if let current = currentTable, code.tables.contains(current) { return current.id }
                return code.tables.first?.id ?? ""
            },
            set: { id in
                guard let chosen = currentCode?.tables.first(where: { $0.id == id }) else { return }
                choose(chosen)
            }
        )
    }

    var body: some View {
        if let language = currentLanguage, let code = currentCode {
            languagePicker
            codePicker(for: language)
            contractionPicker(for: code)
        }
    }

    /// The pop-up of languages, each by its name in the user's language.
    private var languagePicker: some View {
        Picker(BrailleSettingsWording.languageLabel, selection: languageSelection) {
            ForEach(languages) { language in
                Text(language.name).tag(language.id)
            }
        }
        .accessibilityLabel(BrailleSettingsWording.languageLabel)
        .accessibilityHint(languageHint)
    }

    /// The pop-up of `language`'s braille codes, each by its name.
    private func codePicker(for language: BrailleLanguage) -> some View {
        Picker(BrailleSettingsWording.codeLabel, selection: codeSelection) {
            ForEach(language.codes) { code in
                Text(code.name).tag(code.id)
            }
        }
        .accessibilityLabel(BrailleSettingsWording.codeLabel)
        .accessibilityHint(codeHint)
    }

    /// The pop-up of the contractions `code`'s tables have.
    private func contractionPicker(for code: BrailleCode) -> some View {
        Picker(BrailleSettingsWording.contractionLabel, selection: tableSelection) {
            ForEach(code.tables) { table in
                Text(table.contractionLabel).tag(table.id)
            }
        }
        .accessibilityLabel(BrailleSettingsWording.contractionLabel)
        .accessibilityHint(contractionHint)
    }

    /// Takes `chosen`: a bundled table at once, and one of this Mac's once
    /// its check passes (decision 5). The check of a table already checked
    /// this session answers at once; any other runs off the main thread
    /// while the pop-ups show the choice. A later choice replaces a pending
    /// one, whose verdict is then only kept. A refused table is not taken:
    /// the pop-ups return to the table in use, and VoiceOver hears why once
    /// the pop-up's menu has closed and VoiceOver has spoken the value
    /// (`VoiceOverAnnouncer.afterSheetCloses(_:)`).
    private func choose(_ chosen: BrailleTable) {
        guard chosen.id != shownID else { return }
        guard chosen.source == .mac else {
            pending = nil
            table = chosen.id
            return
        }
        pending = chosen.id
        Task { @MainActor in
            let verdict = await MacBrailleTableCheck.verdictOffTheMainThread(for: chosen.id)
            guard pending == chosen.id else { return }
            pending = nil
            switch verdict {
            case .usable:
                table = chosen.id
            case let .refused(refusal):
                let sentence = BrailleSettingsWording.refusal(ofTableNamed: chosen.displayName, because: refusal)
                VoiceOverAnnouncer.afterSheetCloses { VoiceOverAnnouncer.announce(sentence) }
            }
        }
    }
}

// MARK: - The Options View

/// The braille options of the Export dialog (FMT22, Phase B), shown under the
/// Convert to picker while BRF or PEF is chosen: the language, the braille
/// code and its contraction (the Braille tab's own pop-ups, so one of this
/// Mac's tables can be chosen here too), the cells in a line, the lines on a
/// page, whether pages are numbered, and (BRF only, since a PEF always ends a
/// row with a line feed) the line end. Every control has a label, a hint,
/// and a spoken value, and is reached by the keyboard.
struct BrailleExportOptionsView: View {
    /// The options the view sets.
    @Binding var options: BrailleExportOptions
    /// Whether the line end is chosen here: a BRF's is, a PEF's is not.
    let choosesLineEnds: Bool
    /// The codes the table pop-ups offer (see `BrailleTablePickers`).
    var codes: [BrailleCode] = BrailleTableCatalog.offeredCodes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The dialog draws the pop-ups as menus at their own size, as it
            // draws its Convert to picker; the Braille tab leaves them to its
            // form.
            VStack(alignment: .leading, spacing: 6) {
                BrailleTablePickers(
                    table: $options.table,
                    codes: codes,
                    languageHint: BrailleExportWording.languageHint,
                    codeHint: BrailleExportWording.codeHint,
                    contractionHint: BrailleExportWording.contractionHint
                )
            }
            .pickerStyle(.menu)
            .fixedSize()
            // The setting's table could not be used: say so, until another
            // table is chosen here (review R4).
            if let replaced = options.replacedTable {
                Text(BrailleExportWording.startsFromDefault(replacing: replaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            stepperRow(
                label: BrailleExportWording.cellsLabel,
                hint: BrailleExportWording.cellsHint,
                value: BrailleExportWording.cellsValue(options.page.cellsPerLine),
                number: $options.page.cellsPerLine,
                range: BraillePageFormat.cellsPerLineRange
            )
            stepperRow(
                label: BrailleExportWording.linesLabel,
                hint: BrailleExportWording.linesHint,
                value: BrailleExportWording.linesValue(options.page.linesPerPage),
                number: $options.page.linesPerPage,
                range: BraillePageFormat.linesPerPageRange
            )
            Toggle(BrailleExportWording.numbersLabel, isOn: $options.page.numbersPages)
                .toggleStyle(.checkbox)
                .accessibilityHint(BrailleExportWording.numbersHint)
            if choosesLineEnds {
                lineEndPicker
            }
        }
    }

    /// A row of a visible label, a stepper, and its visible value. The
    /// stepper carries the label, value, and hint VoiceOver speaks; the two
    /// texts beside it are hidden from VoiceOver, which would otherwise read
    /// each twice.
    private func stepperRow(
        label: String,
        hint: String,
        value: String,
        number: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .accessibilityHidden(true)
            Stepper(value: number, in: range) {
                EmptyView()
            }
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint)
            Text(value)
                .accessibilityHidden(true)
        }
    }

    /// The pop-up of line ends, CR LF and LF.
    private var lineEndPicker: some View {
        Picker(BrailleExportWording.lineEndsLabel, selection: $options.lineEnd) {
            ForEach([BrailleLineEnd.crlf, .lf], id: \.self) { lineEnd in
                Text(BrailleExportWording.name(of: lineEnd)).tag(lineEnd)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .accessibilityLabel(BrailleExportWording.lineEndsLabel)
        .accessibilityHint(BrailleExportWording.lineEndsHint)
    }
}
