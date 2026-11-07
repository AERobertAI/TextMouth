import Foundation

/// One section of the iPhone's Library list: its heading, which carries the
/// header trait so the Headings rotor reaches it, and its rows.
struct PhoneLibrarySection: Identifiable, Equatable, Sendable {
    /// The section's identity, stable while the list keeps its shape.
    let id: String
    /// The heading, or nil for a section with none.
    let header: String?
    /// The letter iOS 26's section index shows for touch, or nil.
    let indexLabel: String?
    /// The section's rows, in the list's order.
    let rows: [PhoneRowValue]
}

/// How the iPhone's Library divides its books into letter sections (the
/// iPhone interface spec, "The Library's top", item 6): in a Title or Author
/// sort with more than about 30 books, "A", "B", and so on, as headings.
///
/// The sections follow the order the list already has and never reorder it:
/// each is a run of neighbors filed under the same letter. So a letter the
/// order brings back later, as a title in another script can, starts a
/// section of its own rather than moving a book.
enum PhoneLibrarySections {
    /// More books than this, in a Title or Author sort, have letter sections.
    static let letterThreshold = 30

    /// What files a title or an author under a letter: anything that isn't a
    /// letter files under this.
    static let otherLetter = "#"

    /// Whether `count` books sorted by `field` have letter sections.
    static func usesLetters(sortedBy field: LibrarySortField, count: Int) -> Bool {
        (field == .title || field == .author) && count > letterThreshold
    }

    /// The letter `key` files under: its first character, without accents
    /// and in capitals, as the library's sort compares it, so "Émile" files
    /// under "E" beside "Emma"; `otherLetter` when it starts with no letter.
    static func letter(of key: String) -> String {
        guard let first = key.first, first.isLetter else { return otherLetter }
        return String(first)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .uppercased()
    }

    /// `books` divided into runs of neighbors filed under the same letter of
    /// their title or author, as `field` sorts them, in their order.
    static func letterRuns(of books: [Book], sortedBy field: LibrarySortField) -> [(letter: String, books: [Book])] {
        var runs: [(letter: String, books: [Book])] = []
        for book in books {
            let filed = Self.letter(of: field == .author ? book.author : book.title)
            if let last = runs.indices.last, runs[last].letter == filed {
                runs[last].books.append(book)
            } else {
                runs.append((letter: filed, books: [book]))
            }
        }
        return runs
    }
}
