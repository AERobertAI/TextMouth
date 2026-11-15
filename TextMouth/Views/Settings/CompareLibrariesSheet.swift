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
                    .accessibilityLabel("Comparing")
            } else if !model.rows.isEmpty {
                // One row for each difference, read as a sentence.
                List(model.rows) { row in
                    Text(row.sentence)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(row.sentence)
                }
                .frame(minHeight: 220)
                .accessibilityLabel("Differences")
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LibraryComparisonWording.sheetLabel)
    }
}
