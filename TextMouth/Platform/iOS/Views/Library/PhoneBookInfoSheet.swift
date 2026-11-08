import SwiftUI

/// Book Info, rebuilt for the phone with the Mac's words (the iPhone
/// interface spec, "The Book Info sheet"): a `Form` in a `NavigationStack`,
/// its title "Book Information" a heading, Cancel and Save in the toolbar,
/// the fields, then the read-only rows, each one element.
///
/// What it shows follows what `LibraryBookInfoReader` read of the book, as the
/// Mac's Library chooses its editor: an EPUB's fields and rows, an
/// audiobook's, or the title and author every book has. It saves through the
/// Mac's own paths, so only what was changed here is saved and recorded as
/// edited by hand. The Mac's "Also write to the library's copy of the EPUB
/// file" isn't here: on iOS the EPUB can't be written. The Mac's own sheets
/// can't be shown: their buttons are in their bodies and they don't scroll.
///
/// Nothing here has run on iOS.
struct PhoneBookInfoSheet: View {
    /// The book, as the library held it when the sheet opened.
    let book: Book
    /// The library that saves the change.
    let library: LibraryViewModel
    /// What was read of the book's file for the sheet.
    let info: LibraryBookInfo

    var body: some View {
        switch info {
        case .epub(let metadata, _):
            PhoneEPUBBookInfo(book: book, library: library, metadata: metadata)
        case .audio(let metadata, _):
            PhoneAudioBookInfo(book: book, library: library, metadata: metadata)
        case .simple:
            PhoneSimpleBookInfo(book: book, library: library)
        }
    }
}

// MARK: - The Three Kinds

/// The title and author every book has, saved as the Mac's simple Book
/// Information sheet saves them.
private struct PhoneSimpleBookInfo: View {
    let book: Book
    let library: LibraryViewModel
    /// The title typed.
    @State private var title: String
    /// The author typed.
    @State private var author: String
    /// The title and author the sheet opened with, as Save stores them.
    @State private var opened: Book.MetadataValues

    init(book: Book, library: LibraryViewModel) {
        self.book = book
        self.library = library
        _title = State(initialValue: book.title)
        _author = State(initialValue: book.author)
        _opened = State(initialValue: LibraryBookInfoSheet.values(title: book.title, author: book.author))
    }

    var body: some View {
        PhoneBookInfoForm(canSave: edit != nil, save: { save($0) }) {
            PhoneBookInfoField(PhoneLibraryVocabulary.titleField, label: PhoneLibraryVocabulary.titleFieldLabel, field: .title, of: book, text: $title)
            PhoneBookInfoField(PhoneLibraryVocabulary.authorField, label: PhoneLibraryVocabulary.authorFieldLabel, field: .author, of: book, text: $author)
            PhoneBookInfoFacts(book: book)
        }
    }

    /// What Save gives the library, or nil while the title is blank.
    private var edit: Book.MetadataEdit? {
        LibraryBookInfoSheet.edit(from: opened, title: title, author: author)
    }

    /// Closes the sheet, then saves, as the Mac's sheet does.
    private func save(_ close: @escaping @MainActor () -> Void) {
        guard let edit else { return }
        let library = library
        let bookID = book.id
        close()
        DispatchQueue.main.async {
            if library.updateBookMetadata(edit, of: bookID) != nil {
                PhoneBookInfoSave.sayUpdated()
            }
        }
    }
}

/// An EPUB's fields and rows, saved as the Mac's metadata editor saves them,
/// to the library only.
private struct PhoneEPUBBookInfo: View {
    let book: Book
    let library: LibraryViewModel
    /// The metadata as edited.
    @State private var edited: EPUBMetadata
    /// The metadata the sheet opened with, which Save compares with.
    @State private var opened: EPUBMetadata

    init(book: Book, library: LibraryViewModel, metadata: EPUBMetadata) {
        self.book = book
        self.library = library
        _edited = State(initialValue: metadata)
        _opened = State(initialValue: metadata)
    }

    var body: some View {
        PhoneBookInfoForm(canSave: PhoneBookInfoSave.hasTitle(edited.title), save: { save($0) }) {
            PhoneBookInfoField(PhoneLibraryVocabulary.titleField, label: PhoneLibraryVocabulary.titleFieldLabel, field: .title, of: book, text: $edited.title)
            PhoneBookInfoField(PhoneLibraryVocabulary.authorField, label: PhoneLibraryVocabulary.authorField, field: .author, of: book, text: $edited.author)
            PhoneBookInfoField(PhoneLibraryVocabulary.publisherField, label: PhoneLibraryVocabulary.publisherField, field: .publisher, of: book, text: $edited.publisher)
            PhoneBookInfoField(
                PhoneLibraryVocabulary.publicationDateField,
                label: PhoneLibraryVocabulary.publicationDateFieldLabel,
                field: .publicationDate,
                of: book,
                text: $edited.publicationDate
            )
            PhoneBookInfoFacts(book: book)
            Section {
                PhoneBookInfoRow(PhoneLibraryVocabulary.isbnRow, value: edited.isbn)
                PhoneBookInfoRow(PhoneLibraryVocabulary.languageRow, value: edited.language)
                PhoneBookInfoRow(PhoneLibraryVocabulary.identifierRow, value: edited.identifier)
                PhoneBookInfoRow(PhoneLibraryVocabulary.epubVersionRow, value: edited.epubVersion)
            }
        }
    }

    /// Saves to the library only, through the Mac's EPUB path, while the
    /// sheet is open: once it succeeds the sheet closes; a refusal, such as
    /// a book no longer in the library, is said at once and the sheet stays.
    private func save(_ close: @escaping @MainActor () -> Void) {
        let saved = library.saveEPUBMetadata(edited, openedAs: opened, for: book, writingToFile: false)
        guard saved.outcome.succeeded else {
            PhoneAnnouncer.important(saved.message)
            return
        }
        close()
        PhoneBookInfoSave.sayUpdated()
    }
}

/// An audiobook's fields and rows, saved as the Mac's metadata editor saves
/// them, after the sheet has closed.
private struct PhoneAudioBookInfo: View {
    let book: Book
    let library: LibraryViewModel
    /// The metadata as edited.
    @State private var edited: AudioMetadata
    /// The metadata the sheet opened with, which Save compares with.
    @State private var opened: AudioMetadata

    init(book: Book, library: LibraryViewModel, metadata: AudioMetadata) {
        self.book = book
        self.library = library
        _edited = State(initialValue: metadata)
        _opened = State(initialValue: metadata)
    }

    var body: some View {
        PhoneBookInfoForm(canSave: PhoneBookInfoSave.hasTitle(edited.title), save: { save($0) }) {
            PhoneBookInfoField(PhoneLibraryVocabulary.titleField, label: PhoneLibraryVocabulary.titleFieldLabel, field: .title, of: book, text: $edited.title)
            PhoneBookInfoField(PhoneLibraryVocabulary.artistField, label: PhoneLibraryVocabulary.artistFieldLabel, field: .author, of: book, text: $edited.artist)
            PhoneBookInfoField(PhoneLibraryVocabulary.albumField, label: PhoneLibraryVocabulary.albumFieldLabel, field: .audioAlbum, of: book, text: $edited.album)
            PhoneBookInfoField(PhoneLibraryVocabulary.genreField, label: PhoneLibraryVocabulary.genreField, field: .audioGenre, of: book, text: $edited.genre)
            PhoneBookInfoField(PhoneLibraryVocabulary.yearField, label: PhoneLibraryVocabulary.yearField, field: .audioYear, of: book, text: $edited.year)
            PhoneBookInfoFacts(book: book)
            Section {
                PhoneBookInfoRow(PhoneLibraryVocabulary.durationRow, value: edited.duration)
            }
        }
    }

    /// Closes the sheet, then saves what was changed, as the Mac's editor
    /// does for audio, which writes no file.
    private func save(_ close: @escaping @MainActor () -> Void) {
        let edit = Book.MetadataEdit(opened: opened, saved: edited)
        let library = library
        let bookID = book.id
        close()
        DispatchQueue.main.async {
            if library.updateBookMetadata(edit, of: bookID) != nil {
                PhoneBookInfoSave.sayUpdated()
            }
        }
    }
}

// MARK: - The Parts They Share

/// The sheet around a kind's fields: its title, a heading; Cancel and Save
/// in the toolbar; the fields in a `Form`.
private struct PhoneBookInfoForm<Fields: View>: View {
    /// Whether Save can be chosen: not while the title is blank, as on the Mac.
    let canSave: Bool
    /// Saves, handed what closes the sheet, to call when the save says so.
    let save: @MainActor (@escaping @MainActor () -> Void) -> Void
    /// The kind's fields and rows.
    @ViewBuilder let fields: () -> Fields
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                fields()
            }
            .navigationTitle(PhoneLibraryVocabulary.bookInformation)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In this order, so VoiceOver reads the title, then Cancel,
                // then Save (the spec).
                PhoneSheetButton(title: PhoneAppWording.cancel) { dismiss() }
                PhoneSheetButton(title: PhoneAppWording.save, isEnabled: canSave) {
                    save { dismiss() }
                }
            }
        }
    }

}

/// What every kind of Book Info shares about saving.
private enum PhoneBookInfoSave {
    /// Whether `title` is one a book can keep: not blank.
    static func hasTitle(_ title: String) -> Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Says the Mac's "Metadata updated" once VoiceOver has settled on the
    /// screen beneath the closed sheet.
    @MainActor
    static func sayUpdated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceOverAnnouncer.afterSheetDelay) {
            PhoneAnnouncer.say(PhoneLibraryVocabulary.metadataUpdated)
        }
    }
}

/// One field: its visible name, and its spoken label with the Mac's "edited
/// by hand" when the listener typed the value.
private struct PhoneBookInfoField: View {
    /// The visible name.
    let title: String
    /// The spoken label, before "edited by hand".
    let label: String
    /// Which of the book's fields it is, for "edited by hand".
    let field: Book.MetadataField
    /// The book, whose hand edits say which fields were typed.
    let book: Book
    /// The text typed.
    @Binding var text: String

    init(_ title: String, label: String, field: Book.MetadataField, of book: Book, text: Binding<String>) {
        self.title = title
        self.label = label
        self.field = field
        self.book = book
        _text = text
    }

    var body: some View {
        // A field that grows to as many lines as its text needs, up to six,
        // so that a long title or date is never cut at a large text size (the
        // audit found a one-line field clipped). Its value is still one line:
        // Return, which would start another, is dropped, and so is a newline
        // in pasted text.
        TextField(title, text: $text, axis: .vertical)
            .lineLimit(1...6)
            .onChange(of: text) { _, newText in
                guard newText.contains(where: \.isNewline) else { return }
                text = newText.filter { !$0.isNewline }
            }
            .accessibilityLabel(MetadataEditorWording.fieldLabel(label, for: field, in: book.handEdits))
    }
}

/// The read-only rows every book has: Format, Added, Last Opened, and Word
/// Count, each one element.
private struct PhoneBookInfoFacts: View {
    let book: Book

    var body: some View {
        Section {
            PhoneBookInfoRow(PhoneLibraryVocabulary.formatRow, value: book.format.displayName)
            LabeledContent {
                Text(book.dateAdded, style: .date).phoneSecondaryText()
            } label: {
                Text(PhoneLibraryVocabulary.addedRow).phonePrimaryText()
            }
            .accessibilityElement(children: .combine)
            if let lastOpened = book.lastOpened {
                LabeledContent {
                    Text(lastOpened, style: .date).phoneSecondaryText()
                } label: {
                    Text(PhoneLibraryVocabulary.lastOpenedRow).phonePrimaryText()
                }
                .accessibilityElement(children: .combine)
            }
            if let words = book.totalWordCount {
                PhoneBookInfoRow(PhoneLibraryVocabulary.wordCountRow, value: "\(words)")
            }
        }
    }
}

/// One read-only row, its name and its value read as one element; nothing
/// when the value is empty, as on the Mac.
private struct PhoneBookInfoRow: View {
    let name: String
    let value: String

    init(_ name: String, value: String) {
        self.name = name
        self.value = value
    }

    var body: some View {
        if !value.isEmpty {
            PhoneValueRow(name: name, value: value)
                .accessibilityElement(children: .combine)
        }
    }
}
