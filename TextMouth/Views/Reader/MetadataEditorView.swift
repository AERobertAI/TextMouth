import SwiftUI

/// Unified metadata editor for both EPUB and audio books.
/// Shows editable fields appropriate to the book format and read-only fields
/// extracted from the file. For EPUBs, optionally writes changes back to the
/// library's copy of the EPUB file, never to the file it was imported from;
/// a save that fails keeps the editor open with the edits and shows why
/// (TODO A09).
struct MetadataEditorView: View {
    @State private var editedEPUBMetadata: EPUBMetadata
    @State private var editedAudioMetadata: AudioMetadata
    @State private var writeToFile = false
    /// Why the last EPUB save failed, shown above the buttons until the user
    /// changes an edit or the choice to write the file.
    @State private var failureMessage: String?
    @Environment(\.dismiss) private var dismiss

    let isEPUB: Bool
    let isAudio: Bool
    /// Saves EPUB metadata, writing the library's copy of the EPUB file too
    /// when the Bool is true, and returns what happened, which the caller has
    /// announced. The editor closes after a success; after a failure it stays
    /// open with the edits and shows why.
    let onSaveEPUB: ((EPUBMetadata, Bool) -> OperationOutcome)?
    /// Called when saving audio metadata.
    let onSaveAudio: ((AudioMetadata) -> Void)?

    /// Initialize for an EPUB book
    init(metadata: EPUBMetadata, isEPUB: Bool, onSave: @escaping (EPUBMetadata, Bool) -> OperationOutcome) {
        self._editedEPUBMetadata = State(initialValue: metadata)
        self._editedAudioMetadata = State(initialValue: AudioMetadata())
        self.isEPUB = isEPUB
        self.isAudio = false
        self.onSaveEPUB = onSave
        self.onSaveAudio = nil
    }

    /// Initialize for an audio book
    init(audioMetadata: AudioMetadata, onSave: @escaping (AudioMetadata) -> Void) {
        self._editedEPUBMetadata = State(initialValue: EPUBMetadata(
            title: "", author: "", publisher: "", publicationDate: "",
            isbn: "", language: "", identifier: "", epubVersion: ""
        ))
        self._editedAudioMetadata = State(initialValue: audioMetadata)
        self.isEPUB = false
        self.isAudio = true
        self.onSaveEPUB = nil
        self.onSaveAudio = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Book Information")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()

            Divider()

            Form {
                if isAudio {
                    audioEditableSection
                    audioReadOnlySection
                } else {
                    epubEditableSection
                    epubReadOnlySection
                    epubWriteBackSection
                }
            }

            Divider()

            // Why the last save failed, beside the buttons that can try again.
            if let failureMessage {
                OperationFailureNotice(message: failureMessage)
                    .padding([.horizontal, .top])
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(saveButtonAccessibilityLabel)
            }
            .padding()
        }
        .frame(width: 450, height: 550)
        .navigationTitle("Info: \(isAudio ? editedAudioMetadata.title : editedEPUBMetadata.title)")
        // A reason that no longer applies is never read beside new input.
        .clearingFailure($failureMessage, whenChanged: editedEPUBFields)
        .clearingFailure($failureMessage, whenChanged: writesToFile)
    }

    // MARK: - Saving

    /// Saves the edits the way the book's format needs.
    private func save() {
        if isAudio {
            saveAudioAfterClosing()
        } else {
            saveEPUB()
        }
    }

    /// Saves EPUB edits while the editor is still open, because writing the
    /// library's copy of the file can fail (TODO A09). The editor closes only
    /// after a success. After a failure it stays open with the user's edits
    /// and shows why, so the user can turn off writing to the file or try
    /// again; the caller has already announced the failure.
    private func saveEPUB() {
        guard let onSaveEPUB else { return }
        let outcome = onSaveEPUB(editedEPUBMetadata, writesToFile)
        if outcome.succeeded {
            dismiss()
        } else {
            failureMessage = outcome.failureMessage
        }
    }

    /// Saves audio edits, which write no file, after closing the editor, so
    /// the sheet closes before the shared update can move window focus.
    private func saveAudioAfterClosing() {
        // Capture the edits before dismissing.
        let audioMeta = editedAudioMetadata
        let saveAudio = onSaveAudio
        dismiss()
        DispatchQueue.main.async {
            saveAudio?(audioMeta)
        }
    }

    /// Whether Save writes the library's copy of the EPUB file too: only an
    /// EPUB's can be written, and only when the user asks.
    private var writesToFile: Bool {
        isEPUB && writeToFile
    }

    /// What VoiceOver says for Save. For an EPUB it says where the metadata
    /// goes, following the choice to write the file; audio metadata only
    /// ever goes to the library.
    private var saveButtonAccessibilityLabel: String {
        isAudio ? "Save metadata changes" : EPUBMetadataSaveWording.saveButtonLabel(writesToFile: writesToFile)
    }

    /// The EPUB edits a failure is about, so its message clears as soon as
    /// one of them changes.
    private var editedEPUBFields: [String] {
        [
            editedEPUBMetadata.title,
            editedEPUBMetadata.author,
            editedEPUBMetadata.publisher,
            editedEPUBMetadata.publicationDate
        ]
    }

    // MARK: - Audio Sections

    /// Editable fields for audio books: title, artist, album, genre, year
    private var audioEditableSection: some View {
        Section {
            TextField("Title", text: $editedAudioMetadata.title)
                .accessibilityLabel("Book title")

            TextField("Artist", text: $editedAudioMetadata.artist)
                .accessibilityLabel("Artist or narrator")

            TextField("Album", text: $editedAudioMetadata.album)
                .accessibilityLabel("Album name")

            TextField("Genre", text: $editedAudioMetadata.genre)
                .accessibilityLabel("Genre")

            TextField("Year", text: $editedAudioMetadata.year)
                .accessibilityLabel("Year")
        } header: {
            Text("Editable")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Read-only fields for audio books: duration, file format
    private var audioReadOnlySection: some View {
        Section {
            if !editedAudioMetadata.duration.isEmpty {
                LabeledContent("Duration") {
                    Text(editedAudioMetadata.duration)
                }
                .accessibilityLabel("Duration: \(editedAudioMetadata.duration)")
            }

            if !editedAudioMetadata.fileFormat.isEmpty {
                LabeledContent("Format") {
                    Text(editedAudioMetadata.fileFormat)
                }
                .accessibilityLabel("File format: \(editedAudioMetadata.fileFormat)")
            }
        } header: {
            Text("Read Only")
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - EPUB Sections

    /// Editable fields for EPUBs: title, author, publisher, publication date
    private var epubEditableSection: some View {
        Section {
            TextField("Title", text: $editedEPUBMetadata.title)
                .accessibilityLabel("Book title")

            TextField("Author", text: $editedEPUBMetadata.author)
                .accessibilityLabel("Author")

            TextField("Publisher", text: $editedEPUBMetadata.publisher)
                .accessibilityLabel("Publisher")

            TextField("Publication Date", text: $editedEPUBMetadata.publicationDate)
                .accessibilityLabel("Publication date")
        } header: {
            Text("Editable")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Read-only fields for EPUBs: ISBN, language, identifier, EPUB version
    private var epubReadOnlySection: some View {
        Section {
            if !editedEPUBMetadata.isbn.isEmpty {
                LabeledContent("ISBN") {
                    Text(editedEPUBMetadata.isbn)
                        .textSelection(.enabled)
                }
                .accessibilityLabel("ISBN: \(editedEPUBMetadata.isbn)")
            }

            if !editedEPUBMetadata.language.isEmpty {
                LabeledContent("Language") {
                    Text(editedEPUBMetadata.language)
                }
                .accessibilityLabel("Language: \(editedEPUBMetadata.language)")
            }

            if !editedEPUBMetadata.identifier.isEmpty {
                LabeledContent("Identifier") {
                    Text(editedEPUBMetadata.identifier)
                        .textSelection(.enabled)
                }
                .accessibilityLabel("Identifier: \(editedEPUBMetadata.identifier)")
            }

            if !editedEPUBMetadata.epubVersion.isEmpty {
                LabeledContent("EPUB Version") {
                    Text(editedEPUBMetadata.epubVersion)
                }
                .accessibilityLabel("EPUB version: \(editedEPUBMetadata.epubVersion)")
            }
        } header: {
            Text("Read Only")
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The choice to write the edits into the library's copy of the EPUB
    /// file as well. Its title, which VoiceOver reads as its label, its
    /// hint, and its note all say which file that is: the copy TextMouth
    /// keeps in its library, never the file the book was imported from
    /// (TODO A09).
    @ViewBuilder
    private var epubWriteBackSection: some View {
        if isEPUB {
            Section {
                Toggle(EPUBMetadataSaveWording.writeBackToggleTitle, isOn: $writeToFile)
                    .accessibilityHint(EPUBMetadataSaveWording.writeBackToggleHint)

                if writeToFile {
                    Text(EPUBMetadataSaveWording.writeBackNote)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
}
