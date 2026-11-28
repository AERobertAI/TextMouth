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
    /// The read-only Transcript detail: what the audiobook's transcript came
    /// from, empty until it is read and for a book without a transcript.
    @StateObject private var transcript = TranscriptBookInfoModel()
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
                Text(MetadataEditorWording.sheetTitle)
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
                Button(MetadataEditorWording.cancelTitle) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button(MetadataEditorWording.saveTitle, action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(saveButtonAccessibilityLabel)
            }
            .padding()
        }
        .frame(width: 450, height: 550)
        .navigationTitle(MetadataEditorWording.navigationTitle(bookTitle: isAudio ? editedAudioMetadata.title : editedEPUBMetadata.title))
        // The transcript is read off the main thread, without downloading
        // it; the Transcript row shows once it has answered.
        .task(id: transcriptBook?.id) {
            await transcript.load(for: transcriptBook)
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
        isAudio ? MetadataEditorWording.saveAudioLabel : EPUBMetadataSaveWording.saveButtonLabel(writesToFile: writesToFile)
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
            TextField(MetadataEditorWording.titleField, text: $editedAudioMetadata.title)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.bookTitleLabel, for: .title))

            TextField(MetadataEditorWording.artistField, text: $editedAudioMetadata.artist)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.artistLabel, for: .author))

            TextField(MetadataEditorWording.albumField, text: $editedAudioMetadata.album)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.albumLabel, for: .audioAlbum))

            TextField(MetadataEditorWording.genreField, text: $editedAudioMetadata.genre)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.genreField, for: .audioGenre))

            TextField(MetadataEditorWording.yearField, text: $editedAudioMetadata.year)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.yearField, for: .audioYear))
        } header: {
            Text(MetadataEditorWording.editableHeading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Read-only fields for audio books: duration, file format
    private var audioReadOnlySection: some View {
        Section {
            if !editedAudioMetadata.duration.isEmpty {
                LabeledContent(MetadataEditorWording.durationRow) {
                    Text(editedAudioMetadata.duration)
                }
                .accessibilityLabel(MetadataEditorWording.durationSpoken(editedAudioMetadata.duration))
            }

            if !editedAudioMetadata.fileFormat.isEmpty {
                LabeledContent(MetadataEditorWording.formatRow) {
                    Text(editedAudioMetadata.fileFormat)
                }
                .accessibilityLabel(MetadataEditorWording.formatSpoken(editedAudioMetadata.fileFormat))
            }

            // Where the transcript came from; the row appears once the
            // package has been read, and only for a book that has one.
            if let line = transcript.line {
                LabeledContent(TranscriptionWording.bookInfoLabel) {
                    Text(line)
                }
                .accessibilityLabel(TranscriptionWording.bookInfoSpokenDetail(line))
            }
        } header: {
            Text(MetadataEditorWording.readOnlyHeading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // MARK: - EPUB Sections

    /// Editable fields for EPUBs: title, author, publisher, publication
    /// date, each labeled "edited by hand" when the user typed it.
    private var epubEditableSection: some View {
        Section {
            TextField(MetadataEditorWording.titleField, text: $editedEPUBMetadata.title)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.bookTitleLabel, for: .title))

            TextField(MetadataEditorWording.authorField, text: $editedEPUBMetadata.author)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.authorField, for: .author))

            TextField(MetadataEditorWording.publisherField, text: $editedEPUBMetadata.publisher)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.publisherField, for: .publisher))

            TextField(MetadataEditorWording.publicationDateField, text: $editedEPUBMetadata.publicationDate)
                .accessibilityLabel(fieldLabel(MetadataEditorWording.publicationDateLabel, for: .publicationDate))
        } header: {
            Text(MetadataEditorWording.editableHeading)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// Read-only fields for EPUBs: ISBN, language, identifier, EPUB version
    private var epubReadOnlySection: some View {
        Section {
            if !editedEPUBMetadata.isbn.isEmpty {
                LabeledContent(MetadataEditorWording.isbnRow) {
                    Text(editedEPUBMetadata.isbn)
                        .textSelection(.enabled)
                }
                .accessibilityLabel(MetadataEditorWording.isbnSpoken(editedEPUBMetadata.isbn))
            }

            if !editedEPUBMetadata.language.isEmpty {
                LabeledContent(MetadataEditorWording.languageRow) {
                    Text(editedEPUBMetadata.language)
                }
                .accessibilityLabel(MetadataEditorWording.languageSpoken(editedEPUBMetadata.language))
            }

            if !editedEPUBMetadata.identifier.isEmpty {
                LabeledContent(MetadataEditorWording.identifierRow) {
                    Text(editedEPUBMetadata.identifier)
                        .textSelection(.enabled)
                }
                .accessibilityLabel(MetadataEditorWording.identifierSpoken(editedEPUBMetadata.identifier))
            }

            if !editedEPUBMetadata.epubVersion.isEmpty {
                LabeledContent(MetadataEditorWording.epubVersionRow) {
                    Text(editedEPUBMetadata.epubVersion)
                }
                .accessibilityLabel(MetadataEditorWording.epubVersionSpoken(editedEPUBMetadata.epubVersion))
            }
        } header: {
            Text(MetadataEditorWording.readOnlyHeading)
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
    // MARK: The sheet

    /// The sheet's heading.
    static var sheetTitle: String {
        // Translators: Heading of the sheet in which the user edits a book's information (title, author and so on).
        InterfaceText.line("common.bookInformation", "Book Information")
    }
    /// The sheet's navigation title.
    static func navigationTitle(bookTitle: String) -> String {
        // Translators: Navigation title of the book information sheet. %@ is the book's title.
        InterfaceText.line("common.infoValue", "Info: \(bookTitle)")
    }
    /// The button that closes the sheet without saving.
    static var cancelTitle: String {
        // Translators: Button of the book information sheet that closes it without saving.
        InterfaceText.line("common.cancel", "Cancel")
    }
    /// The button that saves the edits.
    static var saveTitle: String {
        // Translators: Button of the book information sheet that saves the edits.
        InterfaceText.line("common.save", "Save")
    }
    /// What VoiceOver says for Save in an audiobook's sheet.
    static var saveAudioLabel: String {
        // Translators: What VoiceOver says for the Save button of an audiobook's book information sheet.
        InterfaceText.line("metadataEditor.saveAudioLabel", "Save metadata changes")
    }
    /// The heading of the group of fields the user can change.
    static var editableHeading: String {
        // Translators: Heading of the group of fields of the book information sheet that the user can change.
        InterfaceText.line("metadataEditor.editableHeading", "Editable")
    }
    /// The heading of the group of fields the user cannot change.
    static var readOnlyHeading: String {
        // Translators: Heading of the group of fields of the book information sheet that the user cannot change.
        InterfaceText.line("metadataEditor.readOnlyHeading", "Read Only")
    }

    // MARK: Editable fields: what the screen shows

    /// The title field's name.
    static var titleField: String {
        // Translators: Name of the book information sheet's field for the book's title.
        InterfaceText.line("common.title", "Title")
    }
    /// The audiobook artist field's name.
    static var artistField: String {
        // Translators: Name of the book information sheet's field for an audiobook's artist.
        InterfaceText.line("metadataEditor.artistField", "Artist")
    }
    /// The audiobook album field's name.
    static var albumField: String {
        // Translators: Name of the book information sheet's field for an audiobook's album.
        InterfaceText.line("metadataEditor.albumField", "Album")
    }
    /// The audiobook genre field's name, which VoiceOver also reads.
    static var genreField: String {
        // Translators: Name of the book information sheet's field for an audiobook's genre; VoiceOver reads it as the field's label.
        InterfaceText.line("metadataEditor.genreField", "Genre")
    }
    /// The audiobook year field's name, which VoiceOver also reads.
    static var yearField: String {
        // Translators: Name of the book information sheet's field for an audiobook's year; VoiceOver reads it as the field's label.
        InterfaceText.line("metadataEditor.yearField", "Year")
    }
    /// The EPUB author field's name, which VoiceOver also reads.
    static var authorField: String {
        // Translators: Name of the book information sheet's field for a book's author; VoiceOver reads it as the field's label.
        InterfaceText.line("common.author", "Author")
    }
    /// The EPUB publisher field's name, which VoiceOver also reads.
    static var publisherField: String {
        // Translators: Name of the book information sheet's field for a book's publisher; VoiceOver reads it as the field's label.
        InterfaceText.line("metadataEditor.publisherField", "Publisher")
    }
    /// The EPUB publication date field's name.
    static var publicationDateField: String {
        // Translators: Name of the book information sheet's field for a book's publication date.
        InterfaceText.line("metadataEditor.publicationDateField", "Publication Date")
    }

    // MARK: Editable fields: what VoiceOver says

    /// What VoiceOver says for the title field.
    static var bookTitleLabel: String {
        // Translators: What VoiceOver says for the book information sheet's field for the book's title.
        InterfaceText.line("metadataEditor.bookTitleLabel", "Book title")
    }
    /// What VoiceOver says for an audiobook's artist field.
    static var artistLabel: String {
        // Translators: What VoiceOver says for the book information sheet's field for an audiobook's artist, who may be its narrator.
        InterfaceText.line("metadataEditor.artistLabel", "Artist or narrator")
    }
    /// What VoiceOver says for an audiobook's album field.
    static var albumLabel: String {
        // Translators: What VoiceOver says for the book information sheet's field for an audiobook's album.
        InterfaceText.line("metadataEditor.albumLabel", "Album name")
    }
    /// What VoiceOver says for an EPUB's publication date field.
    static var publicationDateLabel: String {
        // Translators: What VoiceOver says for the book information sheet's field for a book's publication date.
        InterfaceText.line("metadataEditor.publicationDateLabel", "Publication date")
    }

    // MARK: Read-only rows

    /// The audiobook's duration row.
    static var durationRow: String {
        // Translators: Name of the book information sheet's row that shows an audiobook's length.
        InterfaceText.line("common.duration", "Duration")
    }
    /// The audiobook's file format row.
    static var formatRow: String {
        // Translators: Name of the book information sheet's row that shows an audiobook's file format.
        InterfaceText.line("common.format", "Format")
    }
    /// The ISBN row.
    static var isbnRow: String {
        // Translators: Name of the book information sheet's row that shows a book's ISBN, its international book number.
        InterfaceText.line("metadataEditor.isbnRow", "ISBN")
    }
    /// The language row.
    static var languageRow: String {
        // Translators: Name of the book information sheet's row that shows the language a book is written in.
        InterfaceText.line("common.language", "Language")
    }
    /// The identifier row.
    static var identifierRow: String {
        // Translators: Name of the book information sheet's row that shows a book's identifier, a code that names it.
        InterfaceText.line("metadataEditor.identifierRow", "Identifier")
    }
    /// The EPUB version row.
    static var epubVersionRow: String {
        // Translators: Name of the book information sheet's row that shows which version of the EPUB format the file uses.
        InterfaceText.line("metadataEditor.epubVersionRow", "EPUB Version")
    }

    /// What VoiceOver says for the duration row.
    static func durationSpoken(_ duration: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's duration row. %@ is the length, such as 9:41:07.
        InterfaceText.line("metadataEditor.durationSpoken", "Duration: \(duration)")
    }
    /// What VoiceOver says for the file format row.
    static func formatSpoken(_ format: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's file format row. %@ is the format, such as MP3.
        InterfaceText.line("metadataEditor.formatSpoken", "File format: \(format)")
    }
    /// What VoiceOver says for the ISBN row.
    static func isbnSpoken(_ isbn: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's ISBN row. %@ is the book's ISBN.
        InterfaceText.line("common.isbnValue", "ISBN: \(isbn)")
    }
    /// What VoiceOver says for the language row.
    static func languageSpoken(_ language: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's language row. %@ is the language code the book gives, such as en.
        InterfaceText.line("metadataEditor.languageSpoken", "Language: \(language)")
    }
    /// What VoiceOver says for the identifier row.
    static func identifierSpoken(_ identifier: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's identifier row. %@ is the book's identifier code.
        InterfaceText.line("metadataEditor.identifierSpoken", "Identifier: \(identifier)")
    }
    /// What VoiceOver says for the EPUB version row.
    static func epubVersionSpoken(_ version: String) -> String {
        // Translators: What VoiceOver says for the book information sheet's EPUB version row. %@ is the version, such as 3.0.
        InterfaceText.line("metadataEditor.epubVersionSpoken", "EPUB version: \(version)")
    }

    // MARK: Hand edits and refusals

    /// What VoiceOver reads after the label of a field the user edited by
    /// hand (`Book.handEdits`), so the user knows which values are their
    /// own: "Book title, edited by hand".
    static var editedByHand: String {
        // Translators: Words that follow a field's name in what VoiceOver says, when the user typed that field's value themselves. Begins in lower case, as it follows a comma.
        InterfaceText.line("metadataEditor.editedByHand", "edited by hand")
    }

    /// The accessibility label of the control for `field`: `label`, with
    /// `editedByHand` after it when `handEdits` records the field.
    static func fieldLabel(_ label: String, for field: Book.MetadataField, in handEdits: Book.HandEdits?) -> String {
        guard handEdits?.contains(field) == true else { return label }
        // Translators: What VoiceOver says for a field of the book information sheet that the user edited by hand. %@ is the field's name, such as "Book title".
        return InterfaceText.line("metadataEditor.fieldLabel", "\(label), edited by hand")
    }

    /// What the editor says when Save is pressed after the title was
    /// emptied.
    static var titleCleared: String {
        SentenceWording.joined([
            // Translators: First sentence of the message when Save is pressed after the book's title was emptied.
            InterfaceText.line("metadataEditor.titleCleared.empty", "Could not save: the book's title is empty."),
            // Translators: Second sentence of that message: what to do.
            InterfaceText.line("metadataEditor.titleCleared.again", "Type a title, then save again."),
        ])
    }

    /// When the book titled `title` has left the library, so its edit has
    /// nowhere to go: "Could not save metadata: “Notes” is no longer in the
    /// library. Nothing was changed."
    static func notInLibrary(title: String) -> String {
        SentenceWording.joined([
            // Translators: First sentence of the message when the book being edited left the library. %@ is the book's title.
            InterfaceText.line("metadataEditor.notInLibrary", "Could not save metadata: “\(title)” is no longer in the library."),
            // Translators: Last sentence of a message that says saving failed: nothing the user edited was saved anywhere.
            InterfaceText.line("common.nothingWasChanged", "Nothing was changed."),
        ])
    }
}
