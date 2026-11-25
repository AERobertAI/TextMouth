import Combine
import SwiftUI

/// The braille rows of the iPhone's Export sheet (FR31), shown after the Convert to row while BRF or PEF is the choice, in
/// the Mac's order and its words (`BrailleExportOptionsView`): the braille code, the cells in a line, the lines on a page,
/// whether pages are numbered, and, for a BRF only, the line ends and the braille file characters.
///
/// The braille code is one choice row. It opens the Braille setting's list of every table, under a heading for each
/// language, with the tables that only write braille among them (`BrailleTableCatalog.exportCodes`), since an export only
/// ever writes braille. One list stands for the Mac's three pop-ups, language, braille code, and contraction, as in the
/// Braille setting since FR32: each row names all three, as "Unified English Braille, contracted (Grade 2), in English".
/// The iPhone has only the tables of its own pack, which need no check, so an export never waits for one.
///
/// The rows start from the Braille setting, as the Mac's options do (`BrailleExportOptions.standard()`), and stay until the
/// sheet closes. They read and set the writer's options through the typed accessor of its state
/// (`TextExportOptionsEditing.brailleOptions`), are drawn again as those change, and are dimmed while an export runs.
struct PhoneBrailleExportRows: View {
    /// The options of the writer chosen, a BRF's or a PEF's.
    let state: any TextExportOptionsEditing
    /// Whether the line ends and the braille file characters are chosen here: a BRF's are, a PEF's are not.
    let choosesLineEnds: Bool
    /// Whether an export is running, which dims every row.
    let isExporting: Bool

    /// The choice sheet on show, if any.
    @State private var sheet: ChoiceSheet?
    /// The row whose sheet was opened last, which focus returns to.
    @State private var lastOpener: ChoiceSheet?
    /// Counts the changes the state announces, which is what makes the rows draw again.
    @State private var changes = 0
    /// Where VoiceOver's focus is asked to go once a choice sheet has closed.
    @AccessibilityFocusState private var focus: ChoiceSheet?

    /// The choices that open a sheet, each a row.
    private enum ChoiceSheet: String, Identifiable {
        case code
        case lineEnds
        case fileCode

        var id: String { rawValue }
    }

    /// The options as they stand now. `changes` is read so that a change draws the rows again.
    private var options: BrailleExportOptions {
        _ = changes
        return state.brailleOptions ?? BrailleExportOptions()
    }

    /// A binding to the options, written through the state.
    private var binding: Binding<BrailleExportOptions> {
        Binding(get: { options }, set: { state.brailleOptions = $0 })
    }

    var body: some View {
        Group {
            codeRow
            if let replaced = options.replacedTable {
                // The Braille setting's table could not be used: say so, until another is chosen.
                Text(BrailleExportWording.startsFromDefault(replacing: replaced))
            }
            stepperRow(
                label: BrailleExportWording.cellsLabel,
                hint: BrailleExportWording.cellsHint,
                value: BrailleExportWording.cellsValue(options.page.cellsPerLine),
                number: binding.page.cellsPerLine,
                range: BraillePageFormat.cellsPerLineRange
            )
            stepperRow(
                label: BrailleExportWording.linesLabel,
                hint: BrailleExportWording.linesHint,
                value: BrailleExportWording.linesValue(options.page.linesPerPage),
                number: binding.page.linesPerPage,
                range: BraillePageFormat.linesPerPageRange
            )
            Toggle(BrailleExportWording.numbersLabel, isOn: binding.page.numbersPages)
                .disabled(isExporting)
                .accessibilityHint(BrailleExportWording.numbersHint)
            // A BRF's own two choices come last, the file characters after the line ends, as on the Mac.
            if choosesLineEnds {
                lineEndsRow
                fileCodeRow
            }
        }
    }

    // MARK: - The Rows

    /// The braille code: a button valued with the table in words and its language, which opens the tables. The one
    /// view of the rows that presents the choice sheets and hears the options change: a modifier on the group would
    /// be applied to each of its six or seven rows, seven presenters of one sheet.
    private var codeRow: some View {
        choiceRow(.code, label: BrailleSettingsWording.codeLabel, value: PhoneSettingsModel.brailleTableValue(options.table), hint: BrailleExportWording.codeHint)
            .onReceive(state.changes) { _ in changes &+= 1 }
            .sheet(item: $sheet, onDismiss: sheetClosed) { shown in
                choices(for: shown)
            }
    }

    /// The line end, CR LF or LF.
    private var lineEndsRow: some View {
        choiceRow(.lineEnds, label: BrailleExportWording.lineEndsLabel, value: BrailleExportWording.name(of: options.lineEnd), hint: BrailleExportWording.lineEndsHint)
    }

    /// The braille file characters a BRF is written in.
    private var fileCodeRow: some View {
        choiceRow(.fileCode, label: BrailleSettingsWording.fileCodeLabel, value: options.fileCode.name, hint: BrailleExportWording.fileCodeHint)
    }

    /// A row that shows a choice and opens its sheet: its label, valued with the choice, hinted.
    private func choiceRow(_ which: ChoiceSheet, label: String, value: String, hint: String) -> some View {
        Button {
            lastOpener = which
            sheet = which
        } label: {
            PhoneValueRow(name: label, value: value)
        }
        .disabled(isExporting)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(hint)
        .accessibilityFocused($focus, equals: which)
    }

    /// A stepper that says its label, its value with its unit, and its hint, and shows both beside each other.
    private func stepperRow(label: String, hint: String, value: String, number: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Stepper(value: number, in: range) {
            PhoneValueRow(name: label, value: value)
        }
        .disabled(isExporting)
        .accessibilityLabel(label)
        .accessibilityValue(value)
        .accessibilityHint(hint)
    }

    // MARK: - The Choices

    /// The sheet of `shown`'s choices.
    @ViewBuilder
    private func choices(for shown: ChoiceSheet) -> some View {
        switch shown {
        case .code:
            PhoneChoiceSheet(
                title: BrailleSettingsWording.codeLabel,
                groups: PhoneSettingsModel.brailleTableGroups(codes: BrailleTableCatalog.exportCodes),
                selected: PhoneSettingsModel.brailleTableSelection(options.table)
            ) { id in
                var next = options
                next.table = id
                binding.wrappedValue = next
            }
        case .lineEnds:
            PhoneChoiceSheet(
                title: BrailleExportWording.lineEndsLabel,
                choices: [BrailleLineEnd.crlf, .lf].map { PhoneChoice(id: $0, label: BrailleExportWording.name(of: $0)) },
                selected: options.lineEnd
            ) { lineEnd in
                var next = options
                next.lineEnd = lineEnd
                binding.wrappedValue = next
            }
        case .fileCode:
            PhoneChoiceSheet(
                title: BrailleSettingsWording.fileCodeLabel,
                choices: BrailleFileCode.all.map { PhoneChoice(id: $0.id, label: $0.name) },
                selected: options.fileCode.id
            ) { id in
                guard let code = BrailleFileCode.all.first(where: { $0.id == id }) else { return }
                var next = options
                next.fileCode = code
                binding.wrappedValue = next
            }
        }
    }

    /// A choice sheet closed: focus returns to the row that opened it, 0.35 seconds later.
    private func sheetClosed() {
        // The sheet is nil by now; the row to return to is the last one opened.
        guard let opener = lastOpener else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = opener
        }
    }
}
