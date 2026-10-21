import Foundation

/// What the reader says about a book's pages (PG02, PG03, PG04): what Next
/// Page and Previous Page announce, Go to Page's field and what it refuses,
/// and the settings that show or say the page. Every sentence is shown and
/// spoken alike, and pinned by tests. The position's own words, "Page 12 of
/// 300" and "Before page 1", are `PagePosition.label`; callers use them and
/// never rebuild them.
enum ReaderPageWording {
    // MARK: - Next Page and Previous Page

    /// What Next Page and Previous Page say on reaching a page: "Page 13".
    /// `label` is the page's label as the book names it ("13", "xii").
    static func arrived(at label: String) -> String {
        "Page \(label)"
    }

    /// What a page command says in a book that has no pages, and moves
    /// nothing.
    static let noPages = "This book has no pages."
}
