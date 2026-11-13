import SwiftUI

// MARK: - Cloud Notes in the Library List (FR02)

/// How the library list presents a book's cloud state. The words are the
/// contract's own (`visibleNote`, `spokenNote`); these helpers only decide
/// where the note appears and how it reads beside the row's other parts.
extension BookCloudState {
    /// Whether the book is being downloaded.
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }

    /// Whether the spoken note carries a download percentage, as only a
    /// download's does. The row then speaks its reading progress as
    /// "<n> percent read", so its label never holds two bare percentages.
    var speaksPercentage: Bool {
        isDownloading
    }

    /// Whether some of the book's files are not on this Mac: only in the
    /// cloud, still downloading, left there by a failed download, or not
    /// synced here yet. The list's summary counts these books as in the
    /// cloud.
    var isInTheCloud: Bool {
        switch self {
        case .inCloud, .downloading, .downloadFailed, .waitingForSync:
            return true
        case .local, .downloaded:
            return false
        }
    }

    /// The SF Symbol drawn before the note, or nil when there is no note.
    /// The picture repeats the note's words for sighted readers; it never
    /// stands in for them, and VoiceOver never reads it.
    var noteSymbolName: String? {
        switch self {
        case .local: return nil
        case .downloaded: return "checkmark.circle"
        case .inCloud: return "cloud"
        case .downloading: return "arrow.down.circle"
        case .downloadFailed: return "exclamationmark.triangle"
        case .waitingForSync: return "clock"
        }
    }
}

extension BookCloudStates {
    /// The state the library row shows for the book `bookID`: nil outside a
    /// cloud location, where the list looks exactly as it does for a local
    /// library, and nil for a book no refresh has checked yet.
    func listedState(of bookID: UUID) -> BookCloudState? {
        showsCloudNotes ? state(of: bookID) : nil
    }

    /// How many of `books` the list's summary counts as in the cloud: in a
    /// cloud location, the books whose known state leaves some of their
    /// files off this Mac; always 0 elsewhere.
    func countInTheCloud(_ books: [Book]) -> Int {
        books.filter { listedState(of: $0.id)?.isInTheCloud == true }.count
    }

    /// Whether the library row of the book `bookID` says it is kept on this
    /// Mac: only in a cloud location, where the rows have cloud notes, and
    /// only for a book `kept` keeps, whether the listener kept it or it is on
    /// the reading list being kept (`KeptBooks.isKept(_:)`).
    func listsAsKept(_ bookID: UUID, in kept: KeptBooks) -> Bool {
        showsCloudNotes && kept.isKept(bookID)
    }

    /// Whether Book Information adds "for the reading list" to the book
    /// `bookID`'s kept note: in a cloud location, only when the reading list
    /// alone keeps it (`KeptBooks.isKeptOnlyForReadingList(_:)`).
    func listsAsKeptOnlyForReadingList(_ bookID: UUID, in kept: KeptBooks) -> Bool {
        showsCloudNotes && kept.isKeptOnlyForReadingList(bookID)
    }

    /// How many of `books` the list's summary counts as kept on this Mac: in
    /// a cloud location, the books `kept` keeps for either reason; always 0
    /// elsewhere.
    func countKept(_ books: [Book], in kept: KeptBooks) -> Int {
        showsCloudNotes ? kept.count(of: books) : 0
    }
}

/// The note that follows a kept book's cloud note in its row (Keep on This
/// Mac): words of its own, which the row's label speaks after the cloud
/// note, and a picture that only repeats them.
enum KeptOnThisMacNote {
    /// The note's words, shown and spoken.
    static let text = "Kept on this Mac"
    /// The words Book Information says when the reading list alone keeps the
    /// book, not the listener's own choice.
    static let forReadingListText = "Kept on this Mac for the reading list"
    /// The SF Symbol drawn before the words.
    static let symbolName = "pin.fill"
}

/// A book's cloud note in its library row: a small picture and the note's
/// words, such as "In Cloud" or "Downloading 40%". It shows nothing for a
/// state without a note. The row speaks the note itself, in its own label,
/// so this view adds nothing to what VoiceOver reads.
struct BookCloudNote: View {
    /// The book's cloud state.
    let state: BookCloudState

    var body: some View {
        if let note = state.visibleNote {
            RowNoteBadge(symbolName: state.noteSymbolName, text: note)
        }
    }
}

/// "Kept on this Mac" in a kept book's library row, after its cloud note
/// (Keep on This Mac). The row speaks the words itself, in its own label, so
/// this view adds nothing to what VoiceOver reads.
struct BookKeptNote: View {
    var body: some View {
        RowNoteBadge(symbolName: KeptOnThisMacNote.symbolName, text: KeptOnThisMacNote.text)
    }
}

/// The outlined badge a library row's notes are drawn in, its cloud notes
/// and its transcription note (FR05): a small picture, hidden from
/// VoiceOver since it only repeats the words, and the words themselves.
struct RowNoteBadge: View {
    /// The SF Symbol drawn before the words, if any.
    let symbolName: String?
    /// The note's words.
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            if let symbolName {
                Image(systemName: symbolName)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundColor(.secondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        // An outline rather than a fill keeps the note apart from the
        // New and Now Reading badges without leaning on their colors.
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1)
        )
    }
}
