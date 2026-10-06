import SwiftUI

/// The list of the editor's markers and the pauses found in the audio
/// (FR04): a place to find without a waveform. Each marker can be gone to,
/// named, or deleted; each pause gone to, or selected, as for cutting it.
///
/// Every row is one element VoiceOver reads whole, "Marker 3, Intro, at 1
/// minute, 4 seconds", holding its buttons, which are also its VoiceOver
/// actions; each button names its row ("Delete Marker 3"), so a braille
/// display shows which. The words drawn are hidden from VoiceOver, which
/// has them in the row's label, so it reads them once, then the buttons.
/// VoiceOver starts on the first row, or on Close when the list is empty.
/// Escape closes the sheet.
struct AudioEditorMarkersSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel

    /// The marker whose name is being typed, if any.
    @State private var renaming: UUID?
    /// The chapter marker whose title is being typed, by its place, if any.
    @State private var renamingChapter: TimeInterval?
    /// The name or title typed.
    @State private var newName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AudioEditorWording.markersTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            List {
                Section(AudioEditorWording.markersHeading) {
                    if model.markers.isEmpty {
                        Text(AudioEditorWording.noMarkers)
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(model.orderedMarkers.enumerated()), id: \.element.id) { index, marker in
                        markerRow(marker, number: index + 1)
                            .modifier(InitialVoiceOverFocusModifier(isTarget: index == 0))
                    }
                }
                Section(AudioEditorWording.chaptersHeading) {
                    if model.chapters.isEmpty {
                        Text(AudioEditorWording.noChapters)
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(model.chapters.enumerated()), id: \.offset) { index, chapter in
                        chapterRow(start: chapter.start, title: chapter.title, index: index)
                            .modifier(InitialVoiceOverFocusModifier(isTarget: index == 0 && model.markers.isEmpty))
                    }
                }
                Section(AudioEditorWording.pausesHeading) {
                    pauseRows
                }
            }
            .frame(minHeight: 300)
            HStack {
                Spacer()
                Button(AudioEditorWording.closeButton) { model.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                    .modifier(InitialVoiceOverFocusModifier(
                        isTarget: model.markers.isEmpty && model.chapters.isEmpty && model.pauses.isEmpty
                    ))
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 440)
    }

    // MARK: - Markers

    /// A marker's row: its name and place, then Go To, Rename, and Delete;
    /// while it is being renamed, the name field, Save Name, and Cancel.
    @ViewBuilder
    private func markerRow(_ marker: AudioEditMarker, number: Int) -> some View {
        let label = AudioEditorWording.marker(number, named: marker.name, at: marker.time)
        let subject = AudioEditorWording.markerSubject(number)
        if renaming == marker.id {
            AudioEditorRenameRow(
                label: AudioEditorWording.nameFieldLabel,
                subject: subject,
                name: $newName,
                save: { saveName(of: marker) },
                cancel: { renaming = nil }
            )
        } else {
            row(label, subject: subject, commands: [
                RowCommand(AudioEditorWording.goToButton) { model.goToMarker(marker.id) },
                RowCommand(AudioEditorWording.renameButton) { startRenaming(marker) },
                RowCommand(AudioEditorWording.deleteButton, isDestructive: true) { model.deleteMarker(marker.id) },
            ])
        }
    }

    /// Opens `marker`'s name field, holding its name.
    private func startRenaming(_ marker: AudioEditMarker) {
        renamingChapter = nil
        newName = marker.name
        renaming = marker.id
    }

    /// Keeps the name typed for `marker` and closes the field.
    private func saveName(of marker: AudioEditMarker) {
        model.renameMarker(marker.id, to: newName)
        renaming = nil
    }

    // MARK: - Chapter Markers

    /// A chapter marker's row: its number, title, and place, then Go To,
    /// Rename, and Remove, which are edits, undone as any edit is; while it
    /// is being renamed, the title field, Save Name, and Cancel.
    @ViewBuilder
    private func chapterRow(start: TimeInterval, title: String, index: Int) -> some View {
        let label = AudioEditorWording.chapterRow(index + 1, title: title, at: start)
        let subject = AudioEditorWording.chapterSubject(index + 1)
        if renamingChapter == start {
            AudioEditorRenameRow(
                label: AudioEditorWording.titleFieldLabel,
                subject: subject,
                name: $newName,
                save: { saveTitle(at: start) },
                cancel: { renamingChapter = nil }
            )
        } else {
            row(label, subject: subject, commands: [
                RowCommand(AudioEditorWording.goToButton) { model.goToChapter(index) },
                RowCommand(AudioEditorWording.renameButton) { startRenamingChapter(at: start, title: title) },
                RowCommand(AudioEditorWording.removeButton, isDestructive: true) { removeChapter(at: start, title: title) },
            ])
        }
    }

    /// Opens the title field of the chapter marker at `start`, holding its
    /// title.
    private func startRenamingChapter(at start: TimeInterval, title: String) {
        renaming = nil
        newName = title
        renamingChapter = start
    }

    /// Renames the chapter marker at `start` as typed, and closes the field;
    /// a blank title is refused, saying why.
    private func saveTitle(at start: TimeInterval) {
        let title = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return model.announce(AudioEditorWording.chapterNeedsTitle) }
        renamingChapter = nil
        Task { await model.renameChapter(at: start, to: title) }
    }

    /// Removes the chapter marker at `start`.
    private func removeChapter(at start: TimeInterval, title: String) {
        Task { await model.removeChapter(at: start, titled: title) }
    }

    // MARK: - Pauses

    /// The pauses' rows, or a line saying they are still being found,
    /// couldn't be, or there are none.
    @ViewBuilder
    private var pauseRows: some View {
        switch model.pauseSearch {
        case .finding:
            Text(AudioEditorWording.findingPauses)
                .foregroundColor(.secondary)
        case .failed(let reason):
            Text(AudioEditorWording.pausesFailed(reason))
                .foregroundColor(.secondary)
        case .found:
            if model.pauses.isEmpty {
                Text(AudioEditorWording.noPauses)
                    .foregroundColor(.secondary)
            }
            ForEach(Array(model.pauses.enumerated()), id: \.element.id) { index, pause in
                pauseRow(pause, number: index + 1)
                    .modifier(InitialVoiceOverFocusModifier(isTarget: index == 0 && model.markers.isEmpty && model.chapters.isEmpty))
            }
        }
    }

    /// A pause's row: its length and place, then Go To and Select.
    private func pauseRow(_ pause: AudioEditorPause, number: Int) -> some View {
        row(AudioEditorWording.pauseRow(number, pause), subject: AudioEditorWording.pauseSubject(number), commands: [
            RowCommand(AudioEditorWording.goToButton) { model.goToPause(pause) },
            RowCommand(AudioEditorWording.selectButton) { model.selectPause(pause) },
        ])
    }

    // MARK: - A Row

    /// A row of the list, as VoiceOver reads it: one element labelled
    /// `label`, holding a button for each of `commands`, named with the
    /// row's `subject` ("Delete Marker 3") so a braille display tells one
    /// row's from the next, and offering the commands as its actions, by
    /// their titles. The words drawn are hidden from VoiceOver, which has
    /// them in the label, so it reads a row's words once, then its buttons.
    private func row(_ label: String, subject: String, commands: [RowCommand]) -> some View {
        HStack {
            Text(label)
                .accessibilityHidden(true)
            Spacer()
            ForEach(commands) { command in
                Button(command.title, role: command.isDestructive ? .destructive : nil, action: command.perform)
                    .accessibilityLabel(AudioEditorWording.rowButton(command.title, subject))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityActions {
            ForEach(commands) { command in
                Button(command.title, action: command.perform)
            }
        }
    }
}

/// One command of a row of the list: its button's title, which names the
/// row's VoiceOver action too, and what it does.
private struct RowCommand: Identifiable {
    /// The button's title.
    let title: String
    /// Whether the command deletes something, as its button shows.
    let isDestructive: Bool
    /// Runs it.
    let perform: () -> Void

    /// The command titled `title`, destructive as `isDestructive` says.
    init(_ title: String, isDestructive: Bool = false, perform: @escaping () -> Void) {
        self.title = title
        self.isDestructive = isDestructive
        self.perform = perform
    }

    /// A row's commands are told apart by their titles.
    var id: String { title }
}

// MARK: - Renaming

/// A row of the list while its marker or chapter marker is renamed: the
/// field, where the keyboard goes as the row opens, labelled for VoiceOver
/// with the row's subject ("Name Marker 3"); Save Name, which Return
/// presses too; and Cancel. The field's submit and Save Name run the one
/// `save`, which one press of Return runs once.
struct AudioEditorRenameRow: View {
    /// The field's label: Name for a marker, Title for a chapter marker.
    let label: String
    /// The row's subject, which names the field: "Marker 3".
    let subject: String
    /// The name as typed.
    @Binding var name: String
    /// Keeps the name typed, and closes the row.
    let save: () -> Void
    /// Closes the row with the name as it was.
    let cancel: () -> Void

    /// Puts the keyboard in the field as the row opens.
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack {
            TextField(label, text: $name)
                .focused($fieldFocused)
                .onSubmit(save)
                .accessibilityLabel(AudioEditorWording.rowButton(label, subject))
            Button(AudioEditorWording.saveNameButton, action: save)
                .keyboardShortcut(.defaultAction)
            Button(AudioEditorWording.cancelButton, action: cancel)
        }
        .onAppear { fieldFocused = true }
    }
}
