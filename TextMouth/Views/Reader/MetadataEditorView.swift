import SwiftUI

/// Unified metadata editor for both EPUB and audio books.
/// Shows editable fields appropriate to the book format and read-only fields
/// extracted from the file. For EPUBs, optionally writes changes back to the file.
struct MetadataEditorView: View {
    @State private var editedEPUBMetadata: EPUBMetadata
    @State private var editedAudioMetadata: AudioMetadata
    @State private var writeToFile = false
    @Environment(\.dismiss) private var dismiss

    let isEPUB: Bool
    let isAudio: Bool
    /// Called when saving EPUB metadata. The Bool indicates whether to write back to the EPUB file.
    let onSaveEPUB: ((EPUBMetadata, Bool) -> Void)?
    /// Called when saving audio metadata.
    let onSaveAudio: ((AudioMetadata) -> Void)?

    /// Initialize for an EPUB book
    init(metadata: EPUBMetadata, isEPUB: Bool, onSave: @escaping (EPUBMetadata, Bool) -> Void) {
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

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save") {
                    if isAudio {
                        onSaveAudio?(editedAudioMetadata)
                    } else {
                        onSaveEPUB?(editedEPUBMetadata, writeToFile)
                    }
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Save metadata changes")
            }
            .padding()
        }
        .frame(width: 450, height: 550)
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

    /// Optional toggle to write EPUB metadata changes back to the original file
    @ViewBuilder
    private var epubWriteBackSection: some View {
        if isEPUB {
            Section {
                Toggle("Also save changes to the EPUB file", isOn: $writeToFile)
                    .accessibilityLabel("Save changes to original EPUB file")
                    .accessibilityHint("When enabled, the original EPUB file on disk will be modified and its hash recalculated")

                if writeToFile {
                    Text("Warning: This will modify the original file and recalculate its MD5 hash.")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
        }
    }
}
