import SwiftUI

struct MetadataEditorView: View {
    @State private var editedMetadata: EPUBMetadata
    @State private var writeToFile = false
    @Environment(\.dismiss) private var dismiss

    let isEPUB: Bool
    let onSave: (EPUBMetadata, Bool) -> Void

    init(metadata: EPUBMetadata, isEPUB: Bool, onSave: @escaping (EPUBMetadata, Bool) -> Void) {
        self._editedMetadata = State(initialValue: metadata)
        self.isEPUB = isEPUB
        self.onSave = onSave
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
                Section {
                    TextField("Title", text: $editedMetadata.title)
                        .accessibilityLabel("Book title")

                    TextField("Author", text: $editedMetadata.author)
                        .accessibilityLabel("Author")

                    TextField("Publisher", text: $editedMetadata.publisher)
                        .accessibilityLabel("Publisher")

                    TextField("Publication Date", text: $editedMetadata.publicationDate)
                        .accessibilityLabel("Publication date")
                } header: {
                    Text("Editable")
                        .accessibilityAddTraits(.isHeader)
                }

                Section {
                    if !editedMetadata.isbn.isEmpty {
                        LabeledContent("ISBN") {
                            Text(editedMetadata.isbn)
                                .textSelection(.enabled)
                        }
                        .accessibilityLabel("ISBN: \(editedMetadata.isbn)")
                    }

                    if !editedMetadata.language.isEmpty {
                        LabeledContent("Language") {
                            Text(editedMetadata.language)
                        }
                        .accessibilityLabel("Language: \(editedMetadata.language)")
                    }

                    if !editedMetadata.identifier.isEmpty {
                        LabeledContent("Identifier") {
                            Text(editedMetadata.identifier)
                                .textSelection(.enabled)
                        }
                        .accessibilityLabel("Identifier: \(editedMetadata.identifier)")
                    }

                    if !editedMetadata.epubVersion.isEmpty {
                        LabeledContent("EPUB Version") {
                            Text(editedMetadata.epubVersion)
                        }
                        .accessibilityLabel("EPUB version: \(editedMetadata.epubVersion)")
                    }
                } header: {
                    Text("Read Only")
                        .accessibilityAddTraits(.isHeader)
                }

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

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Save") {
                    onSave(editedMetadata, writeToFile)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel("Save metadata changes")
            }
            .padding()
        }
        .frame(width: 450, height: 550)
    }
}
