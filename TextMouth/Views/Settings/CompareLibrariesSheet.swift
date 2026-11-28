import SwiftUI

/// The Compare Libraries sheet (Phase 0 of the local-first design): the
/// count of differences first, which VoiceOver reads as the sheet opens, then
/// a list with one full sentence a row, and Copy Results and Done (Stop while
/// it works). Every control is reachable from the keyboard, and Escape stops
/// or closes. Nothing here changes either copy.
struct CompareLibrariesSheet: View {
    /// The comparison, started when the sheet appears.
    @StateObject var model: LibraryComparisonModel
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LibraryComparisonWording.title)
                .font(.title2)
                .fontWeight(.bold)
                .accessibilityAddTraits(.isHeader)

            // The count, or what is under way: first, and what VoiceOver
            // lands on.
            Text(model.heading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))

            if model.phase == .comparing {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel(CompareLibrariesSheetWording.comparingLabel)
            } else if !model.rows.isEmpty {
                // One row for each difference, read as a sentence.
                List(model.rows) { row in
                    Text(row.sentence)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(row.sentence)
                }
                .frame(minHeight: 220)
                .accessibilityLabel(CompareLibrariesSheetWording.differencesLabel)
            }
            // The files not read, a list of their own, so a list of the
            // differences holds only differences.
            if model.phase == .finished, !model.unreadRows.isEmpty {
                List(model.unreadRows) { row in
                    Text(row.sentence)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(row.sentence)
                }
                .frame(minHeight: 100)
                .accessibilityLabel(LibraryComparisonWording.unreadListLabel)
            }

            HStack {
                Button(LibraryComparisonWording.copyLabel) { model.copyResults() }
                .disabled(model.phase == .comparing)
                .accessibilityHint(LibraryComparisonWording.copyHint)
                Spacer()
                if model.phase == .comparing {
                    Button(LibraryComparisonWording.stopLabel) { model.stop() }
                        .keyboardShortcut(.cancelAction)
                        .accessibilityHint(LibraryComparisonWording.stopHint)
                } else {
                    Button(LibraryComparisonWording.doneLabel) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 620, minHeight: 320)
        .onAppear { model.start() }
        #if os(macOS)
        // Escape closes the finished sheet; while it works Stop has it.
        .onExitCommand { if model.phase == .finished { dismiss() } }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryComparisonWording.sheetLabel)
    }
}

/// The words of the Compare Libraries sheet's two VoiceOver labels that no
/// other wording holds (FR34).
enum CompareLibrariesSheetWording {
    /// The label of the progress bar shown while the comparison runs.
    static var comparingLabel: String {
        // Translators: VoiceOver label of the progress bar of the Compare Libraries sheet while the two copies of the library are being compared.
        InterfaceText.line("compareLibrariesSheet.comparingLabel", "Comparing")
    }

    /// The label of the list of differences found.
    static var differencesLabel: String {
        // Translators: VoiceOver label of the list of differences the Compare Libraries sheet found between the two copies of the library.
        InterfaceText.line("compareLibrariesSheet.differencesLabel", "Differences")
    }
}
