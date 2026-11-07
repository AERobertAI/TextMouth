import SwiftUI

/// Book Info, rebuilt for the phone with the Mac's words (the iPhone
/// interface spec, "The Book Info sheet"): a `Form` in a `NavigationStack`,
/// its title "Book Information" a heading, Cancel and Save in the toolbar,
/// the title and author fields, then the read-only rows, each one element.
///
/// It saves through the Mac's own path, `LibraryBookInfoSheet.edit(...)` and
/// `LibraryViewModel.updateBookMetadata(_:of:)`, so only what was changed
/// here is saved and recorded as edited by hand. The Mac's own sheet can't be
/// shown: its buttons are in its body and it doesn't scroll.
///
/// This first version has the fields and rows every book has. An EPUB's
/// publisher, date, ISBN, language, identifier, and version, and an
/// audiobook's artist, album, genre, year, and duration, which the spec also
/// lists, aren't here yet. Nothing here has run on iOS.
struct PhoneBookInfoSheet: View {
    /// The book, as the library held it when the sheet opened.
    let book: Book
    /// The library that saves the change.
    let library: LibraryViewModel

    /// The title typed.
    @State private var title: String
    /// The author typed.
    @State private var author: String
    /// The title and author the sheet opened with, as Save stores them, which
    /// Save compares with what is typed.
    @State private var opened: Book.MetadataValues
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The sheet for `book`.
    init(book: Book, library: LibraryViewModel) {
        self.book = book
        self.library = library
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _opened = State(initialValue: LibraryBookInfoSheet.values(title: book.title, author: book.author))
    }

    var body: some View {
        NavigationStack {
            Form {
                // Each spoken label says "edited by hand" when the listener
                // typed the value, as on the Mac.
                TextField(PhoneLibraryVocabulary.titleField, text: $title)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel(
                        PhoneLibraryVocabulary.titleFieldLabel, for: .title, in: book.handEdits
                    ))
                TextField(PhoneLibraryVocabulary.authorField, text: $author)
                    .accessibilityLabel(MetadataEditorWording.fieldLabel(
                        PhoneLibraryVocabulary.authorFieldLabel, for: .author, in: book.handEdits
                    ))
                Section {
                    LabeledContent(PhoneLibraryVocabulary.formatRow, value: book.format.displayName)
                        .accessibilityElement(children: .combine)
                    LabeledContent(PhoneLibraryVocabulary.addedRow) {
                        Text(book.dateAdded, style: .date)
                    }
                    .accessibilityElement(children: .combine)
                    if let lastOpened = book.lastOpened {
                        LabeledContent(PhoneLibraryVocabulary.lastOpenedRow) {
                            Text(lastOpened, style: .date)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let words = book.totalWordCount {
                        LabeledContent(PhoneLibraryVocabulary.wordCountRow, value: "\(words)")
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle(PhoneLibraryVocabulary.bookInformation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PhoneLibraryVocabulary.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PhoneLibraryVocabulary.save, action: save)
                        // Unavailable while the title is blank: a book keeps
                        // a title, as on the Mac.
                        .disabled(edit == nil)
                }
            }
        }
    }

    /// What Save gives the library, or nil while the title is blank.
    private var edit: Book.MetadataEdit? {
        LibraryBookInfoSheet.edit(from: opened, title: title, author: author)
    }

    /// Closes the sheet, then saves what was changed, as the Mac's sheet
    /// does, so the library's change can't pull focus from under the closing;
    /// and once saved, says the Mac's "Metadata updated" after VoiceOver has
    /// settled on the screen beneath.
    private func save() {
        guard let edit else { return }
        let library = library
        let bookID = book.id
        dismiss()
        DispatchQueue.main.async {
            guard library.updateBookMetadata(edit, of: bookID) != nil else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceOverAnnouncer.afterSheetDelay) {
                PhoneAnnouncer.say(PhoneLibraryVocabulary.metadataUpdated)
            }
        }
    }
}
