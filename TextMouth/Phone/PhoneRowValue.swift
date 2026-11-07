import Foundation

/// What identifies a row of the iPhone's Library list. It never changes when
/// the list refreshes, so VoiceOver's cursor stays put, and it is what focus
/// is asked for on returning to the list (`PhoneListFocus`).
enum PhoneRowID: Hashable, Sendable {
    /// A book's row.
    case book(UUID)
    /// A folder's row, by the folder's full path.
    case folder(String)
    /// The one sentence a list shows where it has nothing.
    case note(PhoneRowNote)
}

/// The sentence a Library list shows where it has nothing to list.
enum PhoneRowNote: Hashable, Sendable {
    /// A library with no books and no folders.
    case emptyLibrary
    /// A folder holding no book and no folder.
    case emptyFolder
    /// A search that matches nothing.
    case noMatches
    /// An empty Reading List.
    case emptyReadingList
    /// A view that lists nothing now.
    case emptyView
}

/// One row of the iPhone's Library list, as it was when the list was last
/// built: what VoiceOver says, what is shown, and what the row offers.
///
/// A value, built once per list rather than at each redraw (the engineering
/// review's F11), so a row's words never change under a listener while the
/// book plays: `PhoneLibraryRows` builds new values only when the list itself
/// changes. The row views take nothing else, and compare equal while their
/// value does.
struct PhoneRowValue: Identifiable, Equatable, Sendable {
    /// What kind of row it is.
    enum Kind: Equatable, Sendable {
        /// A book, which opens its reader.
        case book
        /// A folder, which opens the folder.
        case folder
        /// A sentence, which does nothing.
        case note
    }

    /// The row's identity.
    let id: PhoneRowID
    /// What VoiceOver says for the row: for a book, exactly the Mac's
    /// `BookRow.rowAccessibilityLabel`; for a folder, the Mac's
    /// `FolderRow.accessibilityLabel`.
    let label: String
    /// The first visible line: the book's title, the folder's name, or the
    /// sentence.
    let title: String
    /// The second visible line, or nil: a book's author and progress, a
    /// folder's count.
    let detail: String?
    /// The row's commands, in the order offered.
    let commands: [PhoneLibraryOffer.Command]

    /// What kind of row it is, by its identity.
    var kind: Kind {
        switch id {
        case .book: .book
        case .folder: .folder
        case .note: .note
        }
    }

    /// The row of a sentence, which offers nothing and is said as it reads.
    static func note(_ note: PhoneRowNote) -> PhoneRowValue {
        let sentence = PhoneRowWording.sentence(for: note)
        return PhoneRowValue(id: .note(note), label: sentence, title: sentence, detail: nil, commands: [])
    }
}
