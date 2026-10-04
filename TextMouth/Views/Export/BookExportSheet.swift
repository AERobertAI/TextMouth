import SwiftUI

/// The Export dialog (FR05): a checkbox for each kind of item the chosen
/// books hold, with its size, the folder they go to with a button choosing
/// another, and Export.
///
/// VoiceOver's focus moves to the first checkbox once the books are listed
/// (`InitialVoiceOverFocusModifier`). Return presses Export and Escape
/// presses Cancel, or Stop while an export runs. Every checkbox, line, and
/// button has its own words, from `BookExportWording`, the same on screen
/// and in speech; a kind only in the cloud is shown unavailable, which
/// VoiceOver speaks, with the reason in the line below the checkboxes.
struct BookExportSheet: View {
    /// The dialog's state, and the export.
    @ObservedObject var model: BookExportModel
    /// Closes the dialog.
    let close: () -> Void
    /// The sheet's own window, where the folder chooser opens and the
    /// export's announcement is posted from.
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title)
                .font(.title2)
                .accessibilityAddTraits(.isHeader)

            choices

            if let notice = model.cloudNotice {
                Text(notice)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            destination

            if let progress = model.progressText {
                progressBar(progress)
            }

            if let summary = model.summary {
                Text(summary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            buttons
        }
        .padding(20)
        .frame(minWidth: 460, alignment: .leading)
        .background(WindowAccessor(onWindowFound: { window = $0 }))
        .task {
            await model.load()
        }
    }

    // MARK: Parts

    /// The checkboxes, or what the dialog says while it lists the books or
    /// when they hold nothing.
    @ViewBuilder
    private var choices: some View {
        if model.phase == .listing {
            ProgressView(BookExportWording.listing)
                .progressViewStyle(.linear)
        } else if model.choices.isEmpty {
            Text(BookExportWording.nothingToExport)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.choices) { choice in
                    Toggle(choice.label, isOn: checkedBinding(for: choice.kind))
                        .toggleStyle(.checkbox)
                        .disabled(!choice.isAvailable || model.isExporting)
                        .accessibilityHint(BookExportWording.hint(for: choice.kind))
                        .modifier(InitialVoiceOverFocusModifier(isTarget: choice.kind == model.choices.first?.kind))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(BookExportWording.choicesLabel)
        }
    }

    /// The folder the items go to, and the button choosing another.
    private var destination: some View {
        HStack {
            Text(BookExportWording.destination(folderName: BookExportWording.folderName(of: model.destination)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(BookExportWording.chooseFolderTitle) {
                model.chooseDestination(from: window)
            }
            .disabled(model.isExporting)
            .accessibilityHint(BookExportWording.chooseFolderHint)
        }
    }

    /// The export's progress bar, labelled and valued with `text`, as in
    /// "Exporting 3 of 40 items…".
    private func progressBar(_ text: String) -> some View {
        Group {
            if case .exporting(let done, let total) = model.phase, total > 0 {
                ProgressView(value: Double(done), total: Double(total)) {
                    Text(text)
                }
            } else {
                ProgressView {
                    Text(text)
                }
            }
        }
        .progressViewStyle(.linear)
        .accessibilityLabel(text)
    }

    /// Cancel (or Stop while an export runs, or Close once one has said
    /// what it could not do), and Export.
    private var buttons: some View {
        HStack {
            Spacer()
            if model.isExporting {
                Button(BookExportWording.stopTitle) {
                    model.stop()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint(BookExportWording.stopHint)
            } else {
                Button(model.summary == nil ? BookExportWording.cancelTitle : BookExportWording.closeTitle) {
                    close()
                }
                .keyboardShortcut(.cancelAction)
            }
            Button(BookExportWording.exportTitle) {
                Task { await export() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExport)
            .accessibilityHint(BookExportWording.exportHint)
        }
    }

    // MARK: Actions

    /// A checkbox's state, read from and written to the model.
    private func checkedBinding(for kind: BookExportKind) -> Binding<Bool> {
        Binding(
            get: { model.isChecked(kind) },
            set: { model.setChecked($0, for: kind) }
        )
    }

    /// Exports, announcing how it ended from the window the dialog sits on,
    /// and closes the dialog when everything asked was done; otherwise the
    /// dialog stays, with what could not be done.
    private func export() async {
        let announcingWindow = window?.sheetParent ?? window
        guard let outcome = await model.export(announcingFrom: announcingWindow) else { return }
        if BookExportModel.didEverything(outcome) {
            close()
        }
    }
}
