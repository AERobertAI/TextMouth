import SwiftUI

/// Book Info over the reader (the spec, "The Book Info sheet"): the Library's
/// own sheet (`PhoneBookInfoSheet`), for the reader's book.
///
/// What the sheet shows depends on what is read of the book's file: an EPUB's
/// metadata, an audiobook's, or nothing more. That read takes a moment and
/// happens off the main thread (`LibraryBookInfoReader`), as the Library's
/// does, so until it ends the sheet shows its title, a progress indicator
/// read as "Loading", and Cancel. Saving closes the sheet, and the reader's
/// screen returns focus to the Book Info button, as it does for every sheet.
struct PhoneReaderBookInfo: View {
    /// The reader whose book the sheet shows.
    let reader: ReaderViewModel
    /// The library the change is saved to, and that holds the book as the
    /// listener last saw it.
    let library: LibraryViewModel

    /// The book and what was read of it, once the read has ended.
    @State private var loaded: Loaded?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The book as the sheet opened, with what was read of its file.
    private struct Loaded {
        let book: Book
        let info: LibraryBookInfo
    }

    var body: some View {
        if let loaded {
            PhoneBookInfoSheet(book: loaded.book, library: library, info: loaded.info)
        } else {
            reading
        }
    }

    /// The sheet while the file is read: its title and Cancel, and a
    /// progress indicator that VoiceOver reads as "Loading".
    private var reading: some View {
        NavigationStack {
            ProgressView()
                .accessibilityLabel(PhoneAppWording.loading)
                .navigationTitle(PhoneLibraryVocabulary.bookInformation)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    PhoneSheetButton(title: PhoneAppWording.cancel) { dismiss() }
                }
        }
        .task {
            // The library's row, which a rename or an edit has kept current;
            // the reader's own copy only when the row is gone.
            let book = library.bookByID(reader.book.id) ?? reader.book
            let info = await LibraryBookInfoReader.system.info(for: book)
            loaded = Loaded(book: book, info: info)
        }
    }
}
