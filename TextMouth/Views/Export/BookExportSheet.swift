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
///
/// Beside the "Text as Markdown" checkbox, while it is checked, a Convert to
/// picker (FMT18) chooses Markdown, today's export, or a text writer (HTML,
/// RTF, Word); the checkbox's label and hint then name the writer, and the
/// writer's own options view, when it has one, shows under the row.
///
/// For one text book, a "Text as spoken audio" checkbox (FMT43) shows its
/// options under it while it is checked: the format, the range of headings,
/// the rate, and the pitch (`SpeechExportOptionsView`). While that export runs,
/// the progress bar says which chapter is being spoken, and then that the file
/// is being encoded, and Stop's hint says that the chapters already spoken are
/// kept.
struct BookExportSheet: View {
    /// The dialog's state, and the export.
    @ObservedObject var model: BookExportModel
    /// The checks of braille tables just chosen in the options, which an
    /// export waits for and the Export button's hint tells of (review R5).
    @ObservedObject private var choiceChecks = BrailleTableChoiceChecks.shared
    /// Closes the dialog.
    let close: () -> Void
    /// The sheet's own window, where the folder chooser opens and the
    /// export's announcement is posted from.
    @State private var window: PlatformWindow?

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
        // However the dialog closes, an export still under way, or still
        // waiting for a braille table's check, stops (review F3).
        .onDisappear { model.stop() }
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
                    choiceRow(choice)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(BookExportWording.choicesLabel)
        }
    }

    /// One kind's checkbox, with its Convert to picker beside it while it is
    /// checked, and the chosen writer's options view under it.
    private func choiceRow(_ choice: BookExportChoice) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(model.label(for: choice), isOn: checkedBinding(for: choice.kind))
                    .checkboxToggleStyle()
                    .disabled(!choice.isAvailable || model.isExporting)
                    .accessibilityHint(model.hint(for: choice.kind))
                    .modifier(InitialVoiceOverFocusModifier(isTarget: choice.kind == model.choices.first?.kind))
                if model.isChecked(choice.kind), !model.conversionChoices(for: choice.kind).isEmpty {
                    conversionPicker(for: choice.kind)
                }
            }
            if let options = model.optionsView(for: choice.kind) {
                options
                    .padding(.leading, 24)
                    .disabled(model.isExporting)
            }
        }
    }

    /// The Convert to picker of `kind`: a pop-up menu of Markdown and the
    /// writers, spoken as "Convert to", with the choice made as its value and
    /// what that choice exports as its hint.
    private func conversionPicker(for kind: BookExportKind) -> some View {
        Picker(BookExportWording.convertToLabel, selection: conversionBinding(for: kind)) {
            ForEach(model.conversionChoices(for: kind)) { option in
                Text(option.name).tag(option.id)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(model.isExporting)
        .accessibilityLabel(BookExportWording.convertToLabel)
        .accessibilityValue(model.conversionChoice(for: kind)?.name ?? "")
        .accessibilityHint(model.conversionChoice(for: kind)?.hint ?? "")
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
    /// "Exporting 3 of 40 items…" or "Speaking chapter 3 of 12…".
    private func progressBar(_ text: String) -> some View {
        Group {
            if let fraction = model.progressFraction {
                ProgressView(value: fraction, total: 1) {
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
                .accessibilityHint(model.isExportingSpeech ? SpeechExportWording.stopHint : BookExportWording.stopHint)
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
            .accessibilityHint(choiceChecks.isChecking ? BookExportWording.exportWaitsHint : BookExportWording.exportHint)
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

    /// The Convert to picker's choice for `kind`, read from and written to the
    /// model.
    private func conversionBinding(for kind: BookExportKind) -> Binding<String> {
        Binding(
            get: { model.conversionID(for: kind) },
            set: { model.setConversionID($0, for: kind) }
        )
    }

    /// Exports, announcing how it ended from the window the dialog sits on,
    /// and closes the dialog when everything asked was done; otherwise the
    /// dialog stays, with what could not be done.
    private func export() async {
        #if os(macOS)
        let announcingWindow = window?.sheetParent ?? window
        #else
        // Phase 0 iOS: a UIKit window has no sheet parent.
        let announcingWindow = window
        #endif
        guard let outcome = await model.export(announcingFrom: announcingWindow) else { return }
        if BookExportModel.didEverything(outcome) {
            close()
        }
    }
}
