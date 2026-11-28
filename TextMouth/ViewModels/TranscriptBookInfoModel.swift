import Foundation

/// What a Book Information sheet's read-only Transcript detail holds: the
/// line saying where the book's transcript came from, once it has been read.
///
/// Both audiobook sheets (the library's and reader's editor, and an
/// episode's read-only sheet) own one, so the loading is written once and
/// can be tested without drawing either sheet. The sheet calls `load(for:)`
/// from its `.task(id:)` as it appears: the detail is absent until the read
/// answers, and then appears in the sheet's scrolling list without moving
/// the sheet or the focus.
@MainActor
final class TranscriptBookInfoModel: ObservableObject {
    /// Gives the line for a book (`TranscriptStore.bookInfoLine(for:)`, which
    /// reads off the main thread and downloads nothing); tests pass their own.
    typealias Reader = @Sendable (Book) async -> String?

    /// The line, or nil until the book's transcript has been read and for a
    /// book that has none.
    @Published private(set) var line: String?

    /// Reads the line for a book.
    private let reader: Reader

    /// A model that reads transcripts as the app does, or through `reader`.
    init(reader: @escaping Reader = { await TranscriptStore.bookInfoLine(for: $0) }) {
        self.reader = reader
    }

    /// Reads the transcript of `book`, if there is one, and holds its line.
    /// Any line held for another book goes first, so it is never shown beside
    /// this one. A read that finishes after the sheet moved on (the task was
    /// cancelled) is dropped.
    func load(for book: Book?) async {
        line = nil
        guard let book else { return }
        let answer = await reader(book)
        guard !Task.isCancelled else { return }
        line = answer
    }
}
