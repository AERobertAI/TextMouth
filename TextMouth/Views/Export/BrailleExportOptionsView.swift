import SwiftUI

// MARK: - Wording

/// Every sentence the braille options of the Export dialog show or speak
/// (FMT22, Phase B), kept together so a test pins each one exactly. The
/// code and contraction pop-ups keep the labels of the Braille tab
/// (`BrailleSettingsWording`) and have hints of their own, which speak of
/// the book rather than of reading braille files.
enum BrailleExportWording {
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
}

// MARK: - The Table Pop-ups

/// The two pop-ups that choose a braille table, as the Braille tab of
/// Settings has them (FMT21, FMT22): the braille code, and how far that code
/// contracts. They edit one table, by its file name; the first chooses the
/// table's code and the second its contraction, so each offers only what the
/// bundled tables have (`BrailleSettingsChoice`). Their labels are the
/// Braille tab's. The pop-up style and size are the caller's (a form draws
/// them its way, the Export dialog as menus), and so are the hints, since
/// each place speaks of a different use of the table.
struct BrailleTablePickers: View {
    /// The table in use, by its file name.
    @Binding var table: String
    /// The codes the pop-ups offer: the bundled ones, unless a test shows
    /// its own (an empty list is the broken bundle, which draws nothing).
    var codes: [BrailleCode] = BrailleTableCatalog.bundledCodes
    /// What the code pop-up does.
    let codeHint: String
    /// What the contraction pop-up does.
    let contractionHint: String

    /// The table in use, when one of the codes has it.
    private var currentTable: BrailleTable? {
        codes.flatMap(\.tables).first { $0.id == table }
    }

    /// The code the pop-up shows: the table in use's, else the first (so the
    /// pop-up never shows a selection it has no item for).
    private var currentCode: BrailleCode? {
        codes.first { code in currentTable.map { code.tables.contains($0) } ?? false } ?? codes.first
    }

    /// The code pop-up's selection: the chosen code's identifier. Choosing a
    /// code takes its table of the current contraction.
    private var codeSelection: Binding<String> {
        Binding(
            get: { currentCode?.id ?? "" },
            set: { id in
                guard let code = codes.first(where: { $0.id == id }),
                      let chosen = BrailleSettingsChoice.table(in: code, matching: currentTable) else { return }
                table = chosen.id
            }
        )
    }

    /// The contraction pop-up's selection: the identifier of the table in
    /// use, or of the code's first table when the table in use is another
    /// code's.
    private var tableSelection: Binding<String> {
        Binding(
            get: {
                guard let code = currentCode else { return "" }
                if let current = currentTable, code.tables.contains(current) { return current.id }
                return code.tables.first?.id ?? ""
            },
            set: { table = $0 }
        )
    }

    var body: some View {
        if let code = currentCode {
            codePicker
            contractionPicker(for: code)
        }
    }

    /// The pop-up of braille codes, each by its name; grouped under each
    /// language's name when the codes have more than one language.
    private var codePicker: some View {
        let groups = BrailleSettingsChoice.languageGroups(of: codes)
        return Picker(BrailleSettingsWording.codeLabel, selection: codeSelection) {
            if groups.count > 1 {
                ForEach(groups) { group in
                    Section(BrailleTableCatalog.languageName(group.language)) {
                        ForEach(group.codes) { code in
                            Text(code.name).tag(code.id)
                        }
                    }
                }
            } else {
                ForEach(codes) { code in
                    Text(code.name).tag(code.id)
                }
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
}

// MARK: - The Options View

/// The braille options of the Export dialog (FMT22, Phase B), shown under the
/// Convert to picker while BRF or PEF is chosen: the braille code and its
/// contraction, the cells in a line, the lines on a page, whether pages are
/// numbered, and (BRF only, since a PEF always ends a row with a line feed)
/// the line end. Every control has a label, a hint, and a spoken value, and
/// is reached by the keyboard.
struct BrailleExportOptionsView: View {
    /// The options the view sets.
    @Binding var options: BrailleExportOptions
    /// Whether the line end is chosen here: a BRF's is, a PEF's is not.
    let choosesLineEnds: Bool
    /// The codes the table pop-ups offer (see `BrailleTablePickers`).
    var codes: [BrailleCode] = BrailleTableCatalog.bundledCodes

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The dialog draws the pop-ups as menus at their own size, as it
            // draws its Convert to picker; the Braille tab leaves them to its
            // form.
            VStack(alignment: .leading, spacing: 6) {
                BrailleTablePickers(
                    table: $options.table,
                    codes: codes,
                    codeHint: BrailleExportWording.codeHint,
                    contractionHint: BrailleExportWording.contractionHint
                )
            }
            .pickerStyle(.menu)
            .fixedSize()
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
