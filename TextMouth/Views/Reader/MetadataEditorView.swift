import SwiftUI

/// Unified metadata editor for both EPUB and audio books.
/// Shows editable fields appropriate to the book format and read-only fields
/// extracted from the file. For EPUBs, optionally writes changes back to the
/// library's copy of the EPUB file, never to the file it was imported from;
/// a save that fails keeps the editor open with the edits and shows why
/// (TODO A09).
///
/// The editor keeps the metadata it opened with for as long as it is open
/// and hands it to its save beside the edits, so the save changes, and
/// records as edited by hand, only what the user changed here
/// (`Book.MetadataEdit`). Whoever shows the editor may make it again with
/// newer metadata while it is open, as the reader's Book Info does when the
/// library changes the book; the edits and what it opened with stay.
struct MetadataEditorView: View {
    @State private var editedEPUBMetadata: EPUBMetadata
    @State private var editedAudioMetadata: AudioMetadata
    /// The EPUB metadata the editor opened with, handed to `onSaveEPUB`.
    @State private var openedEPUBMetadata: EPUBMetadata
    /// The audio metadata the editor opened with, handed to `onSaveAudio`.
    @State private var openedAudioMetadata: AudioMetadata
    @State private var writeToFile = false
    /// Why the last save failed (an EPUB's write, or a title emptied), shown
    /// above the buttons until the user changes an edit or the choice to
    /// write the file.
    @State private var failureMessage: String?
    /// What the audiobook's transcript came from, for the read-only Transcript
    /// detail; nil until it is read, and for a book without a transcript.
    @State private var transcriptLine: String?
    @Environment(\.dismiss) private var dismiss

    let isEPUB: Bool
    let isAudio: Bool
    /// Which of the book's fields the user edited by hand, said after the
    /// label of each such field (`MetadataEditorWording.fieldLabel`); nil
    /// for a book with no record.
    let handEdits: Book.HandEdits?
    /// The audiobook being shown, whose transcript the read-only Transcript
    /// detail tells of; nil for an EPUB and where the book is not known.
    let transcriptBook: Book?
    /// Saves EPUB metadata: the edits, and the metadata the editor opened
    /// with, writing the library's copy of the EPUB file too when the Bool
    /// is true; returns what happened, which the caller has announced. The
    /// editor closes after a success; after a failure it stays open with the
    /// edits and shows why.
    let onSaveEPUB: ((_ edited: EPUBMetadata, _ opened: EPUBMetadata, _ writeToFile: Bool) -> OperationOutcome)?
    /// Saves audio metadata: the edits, and the metadata the editor opened
    /// with.
    let onSaveAudio: ((_ edited: AudioMetadata, _ opened: AudioMetadata) -> Void)?

    /// Initialize for an EPUB book. `handEdits` is the book's record of
    /// hand edits (`Book.handEdits`), which the labels say.
    init(
        metadata: EPUBMetadata,
        isEPUB: Bool,
        handEdits: Book.HandEdits? = nil,
        onSave: @escaping (_ edited: EPUBMetadata, _ opened: EPUBMetadata, _ writeToFile: Bool) -> OperationOutcome
    ) {
        self._editedEPUBMetadata = State(initialValue: metadata)
        self._openedEPUBMetadata = State(initialValue: metadata)
        self._editedAudioMetadata = State(initialValue: AudioMetadata())
        self._openedAudioMetadata = State(initialValue: AudioMetadata())
        self.isEPUB = isEPUB
        self.isAudio = false
        self.handEdits = handEdits
        self.transcriptBook = nil
        self.onSaveEPUB = onSave
        self.onSaveAudio = nil
    }

    /// Initialize for an audio book. `handEdits` is the book's record of
    /// hand edits (`Book.handEdits`), which the labels say. `book`, when
    /// given, is the audiobook itself, whose transcript the Transcript detail
    /// tells of.
    init(
        audioMetadata: AudioMetadata,
        handEdits: Book.HandEdits? = nil,
        book: Book? = nil,
        onSave: @escaping (_ edited: AudioMetadata, _ opened: AudioMetadata) -> Void
    ) {
        self._editedEPUBMetadata = State(initialValue: Self.noEPUBMetadata)
        self._openedEPUBMetadata = State(initialValue: Self.noEPUBMetadata)
        self._editedAudioMetadata = State(initialValue: audioMetadata)
        self._openedAudioMetadata = State(initialValue: audioMetadata)
        self.isEPUB = false
        self.isAudio = true
        self.handEdits = handEdits
        self.transcriptBook = book
        self.onSaveEPUB = nil
        self.onSaveAudio = onSave
    }

    /// The EPUB metadata an audio book's editor holds, which it never
    /// shows or saves.
    private static let noEPUBMetadata = EPUBMetadata(
        title: "", author: "", publisher: "", publicationDate: "",
        isbn: "", language: "", identifier: "", epubVersion: ""
    )

    /// The accessibility label of the field `field`, `label` with "edited
    /// by hand" after it when the book's record says so.
    private func fieldLabel(_ label: String, for field: Book.MetadataField) -> String {
        MetadataEditorWording.fieldLabel(label, for: field, in: handEdits)
    }

    var body: some View {
        VStack(spacing: 0) {
            // The heading alone: the Cancel button below, with Escape, is the
            // one way to close without saving. A Close button here did the
            // same, so VoiceOver met two controls for it.
            HStack {
                Text("Book Information")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
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
        // The transcript is read off the main thread, without downloading
        // it; the Transcript row shows once it has answered.
        .task(id: transcriptBook?.id) {
            // Another book's line is never kept while this one is read.
            transcriptLine = nil
            guard let transcriptBook else { return }
            transcriptLine = await TranscriptStore.bookInfoLine(for: transcriptBook)
        }
        // A reason that no longer applies is never read beside new input.
        .clearingFailure($failureMessage, whenChanged: editedEPUBFields)
        .clearingFailure($failureMessage, whenChanged: editedAudioMetadata.title)
        .clearingFailure($failureMessage, whenChanged: writesToFile)
    }

    // MARK: - Saving

    /// Saves the edits the way the book's format needs.
    private func save() {
        // A title the user emptied is refused here, in the editor, which stays
        // open with their edits and says why, so a book is never left with no
        // name to hear in the library, the windows, or Now Playing.
        let openedTitle = isAudio ? openedAudioMetadata.title : openedEPUBMetadata.title
        let editedTitle = isAudio ? editedAudioMetadata.title : editedEPUBMetadata.title
        if Book.MetadataEdit.clearsTitle(opened: openedTitle, edited: editedTitle) {
            failureMessage = MetadataEditorWording.titleCleared
            VoiceOverAnnouncer.announce(MetadataEditorWording.titleCleared)
            return
        }
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
        let outcome = onSaveEPUB(editedEPUBMetadata, openedEPUBMetadata, writesToFile)
        if outcome.succeeded {
            dismiss()
        } else {
            failureMessage = outcome.failureMessage
        }
    }

    /// Saves audio edits, which write no file, after closing the editor, so
    /// the sheet closes before the shared update can move window focus.
    private func saveAudioAfterClosing() {
        // Capture the edits, and what the editor opened with, before
        // dismissing.
        let audioMeta = editedAudioMetadata
        let opened = openedAudioMetadata
        let saveAudio = onSaveAudio
        dismiss()
        DispatchQueue.main.async {
            saveAudio?(audioMeta, opened)
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

    /// Editable fields for audio books: title, artist, album, genre, year,
    /// each labeled "edited by hand" when the user typed it.
    private var audioEditableSection: some View {
        Section {
            TextField("Title", text: $editedAudioMetadata.title)
                .accessibilityLabel(fieldLabel("Book title", for: .title))

            TextField("Artist", text: $editedAudioMetadata.artist)
                .accessibilityLabel(fieldLabel("Artist or narrator", for: .author))

            TextField("Album", text: $editedAudioMetadata.album)
                .accessibilityLabel(fieldLabel("Album name", for: .audioAlbum))

            TextField("Genre", text: $editedAudioMetadata.genre)
                .accessibilityLabel(fieldLabel("Genre", for: .audioGenre))

            TextField("Year", text: $editedAudioMetadata.year)
                .accessibilityLabel(fieldLabel("Year", for: .audioYear))
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

            // Where the transcript came from; the row appears once the
            // package has been read, and only for a book that has one.
            if let transcriptLine {
                LabeledContent(TranscriptionWording.bookInfoLabel) {
                    Text(transcriptLine)
                }
                .accessibilityLabel("\(TranscriptionWording.bookInfoLabel): \(transcriptLine)")
            }
        } header: {
            Text("Read Only")
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - EPUB Sections

    /// Editable fields for EPUBs: title, author, publisher, publication
    /// date, each labeled "edited by hand" when the user typed it.
    private var epubEditableSection: some View {
        Section {
            TextField("Title", text: $editedEPUBMetadata.title)
                .accessibilityLabel(fieldLabel("Book title", for: .title))

            TextField("Author", text: $editedEPUBMetadata.author)
                .accessibilityLabel(fieldLabel("Author", for: .author))

            TextField("Publisher", text: $editedEPUBMetadata.publisher)
                .accessibilityLabel(fieldLabel("Publisher", for: .publisher))

            TextField("Publication Date", text: $editedEPUBMetadata.publicationDate)
                .accessibilityLabel(fieldLabel("Publication date", for: .publicationDate))
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

// MARK: - Wording

/// The words the metadata editors and the library's Book Info sheet share.
enum MetadataEditorWording {
    /// What VoiceOver reads after the label of a field the user edited by
    /// hand (`Book.handEdits`), so the user knows which values are their
    /// own: "Book title, edited by hand".
    static let editedByHand = "edited by hand"

    /// The accessibility label of the control for `field`: `label`, with
    /// `editedByHand` after it when `handEdits` records the field.
    static func fieldLabel(_ label: String, for field: Book.MetadataField, in handEdits: Book.HandEdits?) -> String {
        guard handEdits?.contains(field) == true else { return label }
        return "\(label), \(editedByHand)"
    }

    /// What the editor says when Save is pressed after the title was
    /// emptied.
    static let titleCleared = "Could not save: the book's title is empty. Type a title, then save again."

    /// When the book titled `title` has left the library, so its edit has
    /// nowhere to go: "Could not save metadata: “Notes” is no longer in the
    /// library. Nothing was changed."
    static func notInLibrary(title: String) -> String {
        "Could not save metadata: “\(title)” is no longer in the library. Nothing was changed."
    }
}
