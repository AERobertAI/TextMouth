import SwiftUI

/// The list of the editor's markers and the pauses found in the audio
/// (FR04): a place to find without a waveform. Each marker can be gone to,
/// named, or deleted; each pause gone to, or selected, as for cutting it.
///
/// Every row is one element VoiceOver reads whole, "Marker 3, Intro, at 1
/// minute, 4 seconds", holding its buttons, which are also its VoiceOver
/// actions; each button names its row ("Delete Marker 3"), so a braille
/// display shows which. VoiceOver starts on the first row, or on Close
/// when the list is empty. Escape closes the sheet.
struct AudioEditorMarkersSheet: View {
    /// The window's model.
    @ObservedObject var model: AudioEditorModel

    /// The marker whose name is being typed, if any.
    @State private var renaming: UUID?
    /// The chapter marker whose title is being typed, by its place, if any.
    @State private var renamingChapter: TimeInterval?
    /// The name or title typed.
    @State private var newName = ""
    /// Puts the keyboard in the name field as it opens.
    @FocusState private var nameFocused: Bool

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
    private func markerRow(_ marker: AudioEditorMarker, number: Int) -> some View {
        let label = AudioEditorWording.marker(number, named: marker.name, at: marker.time)
        let subject = AudioEditorWording.markerName(number, named: "")
        if renaming == marker.id {
            HStack {
                TextField(AudioEditorWording.nameFieldLabel, text: $newName)
                    .focused($nameFocused)
                    .onSubmit { saveName(of: marker) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.nameFieldLabel, subject))
                Button(AudioEditorWording.saveNameButton) { saveName(of: marker) }
                    .keyboardShortcut(.defaultAction)
                Button(AudioEditorWording.cancelButton) { renaming = nil }
            }
            .onAppear { nameFocused = true }
        } else {
            HStack {
                Text(label)
                Spacer()
                Button(AudioEditorWording.goToButton) { model.goToMarker(marker.id) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.goToButton, subject))
                Button(AudioEditorWording.renameButton) { startRenaming(marker) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.renameButton, subject))
                Button(AudioEditorWording.deleteButton, role: .destructive) { model.deleteMarker(marker.id) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.deleteButton, subject))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityActions {
                Button(AudioEditorWording.goToButton) { model.goToMarker(marker.id) }
                Button(AudioEditorWording.renameButton) { startRenaming(marker) }
                Button(AudioEditorWording.deleteButton) { model.deleteMarker(marker.id) }
            }
        }
    }

    /// Opens `marker`'s name field, holding its name.
    private func startRenaming(_ marker: AudioEditorMarker) {
        renamingChapter = nil
        newName = marker.name
        renaming = marker.id
    }

    /// Keeps the name typed for `marker` and closes the field.
    private func saveName(of marker: AudioEditorMarker) {
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
        let subject = "Chapter \(index + 1)"
        if renamingChapter == start {
            HStack {
                TextField(AudioEditorWording.titleFieldLabel, text: $newName)
                    .focused($nameFocused)
                    .onSubmit { saveTitle(at: start) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.titleFieldLabel, subject))
                Button(AudioEditorWording.saveNameButton) { saveTitle(at: start) }
                    .keyboardShortcut(.defaultAction)
                Button(AudioEditorWording.cancelButton) { renamingChapter = nil }
            }
            .onAppear { nameFocused = true }
        } else {
            HStack {
                Text(label)
                Spacer()
                Button(AudioEditorWording.goToButton) { model.goToChapter(index) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.goToButton, subject))
                Button(AudioEditorWording.renameButton) { startRenamingChapter(at: start, title: title) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.renameButton, subject))
                Button(AudioEditorWording.removeButton, role: .destructive) { removeChapter(at: start, title: title) }
                    .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.removeButton, subject))
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
            .accessibilityActions {
                Button(AudioEditorWording.goToButton) { model.goToChapter(index) }
                Button(AudioEditorWording.renameButton) { startRenamingChapter(at: start, title: title) }
                Button(AudioEditorWording.removeButton) { removeChapter(at: start, title: title) }
            }
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
        let label = AudioEditorWording.pauseRow(number, pause)
        let subject = "Pause \(number)"
        return HStack {
            Text(label)
            Spacer()
            Button(AudioEditorWording.goToButton) { model.goToPause(pause) }
                .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.goToButton, subject))
            Button(AudioEditorWording.selectButton) { model.selectPause(pause) }
                .accessibilityLabel(AudioEditorWording.rowButton(AudioEditorWording.selectButton, subject))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
        .accessibilityActions {
            Button(AudioEditorWording.goToButton) { model.goToPause(pause) }
            Button(AudioEditorWording.selectButton) { model.selectPause(pause) }
        }
    }
}
