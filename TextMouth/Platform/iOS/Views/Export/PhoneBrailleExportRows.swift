import SwiftUI

/// The braille rows of the iPhone's Export sheet (FR31), shown after the Convert to row while BRF or PEF is the choice, in
/// the Mac's order and its words (`BrailleExportOptionsView`): the braille code, the cells in a line, the lines on a page,
/// whether pages are numbered, and, for a BRF only, the line ends and the braille file characters. What each row says,
/// its label, its value, and its hint, is decided by `PhoneExportOffer.brailleRows`, which the Mac's test host reads.
///
/// The braille code is one choice row. It opens the Braille setting's list of every table, under a heading for each
/// language, with the tables that only write braille among them (`BrailleTableCatalog.exportCodes`), since an export only
/// ever writes braille. One list stands for the Mac's three pop-ups, language, braille code, and contraction, as in the
/// Braille setting since FR32: each row names all three, as "Unified English Braille, contracted (Grade 2), in English".
/// The iPhone has only the tables of its own pack, which need no check, so an export never waits for one.
///
/// The rows start from the Braille setting, as the Mac's options do (`BrailleExportOptions.standard()`), and stay until the
/// sheet closes. They read and set the writer's options through the typed accessor of its state
/// (`TextExportOptionsEditing.brailleOptions`) and are dimmed while an export runs.
///
/// The rows only ask for a choice sheet (`open`); the Export sheet presents it, and hears the options change
/// (`BookExportModel.optionsChanged`), from its list and not from any row. A List makes its rows as they scroll
/// into view, so a presenter on one row has gone when that row has scrolled away: a tap on another row would open
/// nothing, and a row made again could close a sheet that is open.
struct PhoneBrailleExportRows: View {
    /// The kind whose writer's options these are, which says where focus returns to.
    let kind: BookExportKind
    /// The options of the writer chosen, a BRF's or a PEF's.
    let state: any TextExportOptionsEditing
    /// Whether the line ends and the braille file characters are chosen here: a BRF's are, a PEF's are not.
    let choosesLineEnds: Bool
    /// Whether an export is running, which dims every row.
    let isExporting: Bool
    /// How many times the options have changed, which draws the rows again when it does.
    let revision: Int
    /// Where VoiceOver's focus is asked to go, which is the Export sheet's.
    let focus: AccessibilityFocusState<PhoneExportSheet.Focus?>.Binding
    /// Asks the Export sheet to show a choice sheet.
    let open: (PhoneExportOffer.BrailleChoice) -> Void

    /// The options as they stand now. `revision` is read so that a change draws the rows again.
    private var options: BrailleExportOptions {
        _ = revision
        return state.brailleOptions ?? BrailleExportOptions()
    }

    /// A binding to the options, written through the state.
    private var binding: Binding<BrailleExportOptions> {
        Binding(get: { options }, set: { state.brailleOptions = $0 })
    }

    var body: some View {
        Group {
            ForEach(PhoneExportOffer.brailleRows(options, choosesLineEnds: choosesLineEnds), id: \.label) { row in
                draw(row)
                // The Braille setting's table could not be used: say so, under the braille code, until another is chosen.
                if row.control == .choice(.code), let replaced = options.replacedTable {
                    Text(BrailleExportWording.startsFromDefault(replacing: replaced))
                }
            }
        }
    }

    // MARK: - The Rows

    /// The row `row` decides, drawn as its control.
    @ViewBuilder
    private func draw(_ row: PhoneExportOffer.BrailleRow) -> some View {
        switch row.control {
        case .choice(let which):
            choiceRow(which, row)
        case .cellsPerLine:
            stepperRow(row, number: binding.page.cellsPerLine, range: BraillePageFormat.cellsPerLineRange)
        case .linesPerPage:
            stepperRow(row, number: binding.page.linesPerPage, range: BraillePageFormat.linesPerPageRange)
        case .pageNumbers:
            Toggle(row.label, isOn: binding.page.numbersPages)
                .disabled(isExporting)
                .accessibilityHint(row.hint)
        }
    }

    /// A row that shows a choice and opens its sheet: its label, valued with the choice, hinted.
    private func choiceRow(_ which: PhoneExportOffer.BrailleChoice, _ row: PhoneExportOffer.BrailleRow) -> some View {
        let value = row.value ?? ""
        return Button {
            open(which)
        } label: {
            PhoneValueRow(name: row.label, value: value)
        }
        .disabled(isExporting)
        .accessibilityLabel(row.label)
        .accessibilityValue(value)
        .accessibilityHint(row.hint)
        .accessibilityFocused(focus, equals: .braille(kind, which))
    }

    /// A stepper that says its label, its value with its unit, and its hint, and shows the first two beside each other.
    ///
    /// Like the Settings steppers, it is one adjustable element (swipe up or down to change it), not the
    /// stepper's own text and two buttons: SwiftUI keeps its own words and drops a value set from outside.
    private func stepperRow(_ row: PhoneExportOffer.BrailleRow, number: Binding<Int>, range: ClosedRange<Int>) -> some View {
        let value = row.value ?? ""
        return Stepper(value: number, in: range) {
            PhoneValueRow(name: row.label, value: value)
        }
        .disabled(isExporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.label)
        .accessibilityValue(value)
        .accessibilityHint(row.hint)
        .accessibilityAdjustableAction { direction in
            // A dimmed row does nothing, even by this action.
            guard !isExporting else { return }
            switch direction {
            case .increment: number.wrappedValue = min(range.upperBound, number.wrappedValue + 1)
            case .decrement: number.wrappedValue = max(range.lowerBound, number.wrappedValue - 1)
            @unknown default: break
            }
        }
    }
}

// MARK: - The Choices

/// A request for one choice sheet of one kind's braille rows, which the Export sheet presents.
struct PhoneBrailleExportRequest: Identifiable {
    /// The kind whose writer's options the choice sets.
    let kind: BookExportKind
    /// The choice to make.
    let choice: PhoneExportOffer.BrailleChoice

    var id: String { "\(kind.rawValue).\(choice.rawValue)" }
}

/// The sheet of one braille choice, over the options of the writer `state` holds.
struct PhoneBrailleExportChoices: View {
    /// The options of the writer chosen.
    let state: any TextExportOptionsEditing
    /// The choice to make.
    let choice: PhoneExportOffer.BrailleChoice

    /// The options as they stand now.
    private var options: BrailleExportOptions { state.brailleOptions ?? BrailleExportOptions() }

    /// Sets the options through the state, from the ones that stand now.
    private func change(_ edit: (inout BrailleExportOptions) -> Void) {
        var next = options
        edit(&next)
        state.brailleOptions = next
    }

    var body: some View {
        switch choice {
        case .code:
            PhoneChoiceSheet(
                title: BrailleSettingsWording.codeLabel,
                groups: PhoneSettingsModel.brailleTableGroups(codes: BrailleTableCatalog.exportCodes),
                selected: PhoneSettingsModel.brailleTableSelection(options.table)
            ) { id in change { $0.table = id } }
        case .lineEnds:
            PhoneChoiceSheet(
                title: BrailleExportWording.lineEndsLabel,
                choices: [BrailleLineEnd.crlf, .lf].map { PhoneChoice(id: $0, label: BrailleExportWording.name(of: $0)) },
                selected: options.lineEnd
            ) { lineEnd in change { $0.lineEnd = lineEnd } }
        case .fileCode:
            PhoneChoiceSheet(
                title: BrailleSettingsWording.fileCodeLabel,
                choices: BrailleFileCode.all.map { PhoneChoice(id: $0.id, label: $0.name) },
                selected: options.fileCode.id
            ) { id in
                guard let code = BrailleFileCode.all.first(where: { $0.id == id }) else { return }
                change { $0.fileCode = code }
            }
        }
    }
}
