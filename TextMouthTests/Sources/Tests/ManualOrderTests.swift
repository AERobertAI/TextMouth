import Foundation

/// Mirrors the app's moveBookInManualOrder logic for testing.
/// direction: -1 for up, +1 for down.
/// Returns the new index or nil if the move was not possible.
func simulateMoveBookInManualOrder(
    library: inout Library,
    bookID: UUID,
    direction: Int,
    folderPath: String
) -> Int? {
    var folderBooks = library.booksInFolder(folderPath)
        .sorted { a, b in
            let orderA = a.manualSortOrder ?? Int.max
            let orderB = b.manualSortOrder ?? Int.max
            if orderA != orderB { return orderA < orderB }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    guard let currentIndex = folderBooks.firstIndex(where: { $0.id == bookID }) else { return nil }
    let newIndex = currentIndex + direction
    guard newIndex >= 0, newIndex < folderBooks.count else { return nil }

    folderBooks.swapAt(currentIndex, newIndex)
    // Reassign sequential sort orders in the library
    for (i, book) in folderBooks.enumerated() {
        if let idx = library.books.firstIndex(where: { $0.id == book.id }) {
            library.books[idx].manualSortOrder = i
        }
    }
    return newIndex
}

func runManualOrderTests() {
    print("\n--- Manual Order Tests ---")

    test("Manual order: move book down swaps with next book") {
        let idA = UUID(), idB = UUID(), idC = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0, id: idA),
            Book(title: "Beta", folderPath: "F", manualSortOrder: 1, id: idB),
            Book(title: "Gamma", folderPath: "F", manualSortOrder: 2, id: idC),
        ])

        let result = simulateMoveBookInManualOrder(library: &library, bookID: idA, direction: 1, folderPath: "F")
        try assertEqual(result, 1, "Alpha should move to index 1")

        // Verify order: Beta(0), Alpha(1), Gamma(2)
        let sorted = library.booksInFolder("F").sorted { ($0.manualSortOrder ?? 0) < ($1.manualSortOrder ?? 0) }
        try assertEqual(sorted[0].id, idB, "Beta should be first")
        try assertEqual(sorted[1].id, idA, "Alpha should be second")
        try assertEqual(sorted[2].id, idC, "Gamma should be third")
    }

    test("Manual order: move book up swaps with previous book") {
        let idA = UUID(), idB = UUID(), idC = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0, id: idA),
            Book(title: "Beta", folderPath: "F", manualSortOrder: 1, id: idB),
            Book(title: "Gamma", folderPath: "F", manualSortOrder: 2, id: idC),
        ])

        let result = simulateMoveBookInManualOrder(library: &library, bookID: idC, direction: -1, folderPath: "F")
        try assertEqual(result, 1, "Gamma should move to index 1")

        let sorted = library.booksInFolder("F").sorted { ($0.manualSortOrder ?? 0) < ($1.manualSortOrder ?? 0) }
        try assertEqual(sorted[0].id, idA, "Alpha should be first")
        try assertEqual(sorted[1].id, idC, "Gamma should be second")
        try assertEqual(sorted[2].id, idB, "Beta should be third")
    }

    test("Manual order: move first book up returns nil") {
        let idA = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0, id: idA),
            Book(title: "Beta", folderPath: "F", manualSortOrder: 1),
        ])

        let result = simulateMoveBookInManualOrder(library: &library, bookID: idA, direction: -1, folderPath: "F")
        try assertTrue(result == nil, "Can't move first book up")
    }

    test("Manual order: move last book down returns nil") {
        let idB = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0),
            Book(title: "Beta", folderPath: "F", manualSortOrder: 1, id: idB),
        ])

        let result = simulateMoveBookInManualOrder(library: &library, bookID: idB, direction: 1, folderPath: "F")
        try assertTrue(result == nil, "Can't move last book down")
    }

    test("Manual order: move book not in folder returns nil") {
        let idA = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0, id: idA),
        ])

        let result = simulateMoveBookInManualOrder(library: &library, bookID: idA, direction: 1, folderPath: "Other")
        try assertTrue(result == nil, "Book not in target folder")
    }

    test("Manual order: books without manualSortOrder sort by title as fallback") {
        let idA = UUID(), idB = UUID(), idC = UUID()
        var library = Library(books: [
            Book(title: "Charlie", folderPath: "F", id: idA),  // no order
            Book(title: "Alpha", folderPath: "F", id: idB),    // no order
            Book(title: "Beta", folderPath: "F", id: idC),     // no order
        ])

        // Without manualSortOrder, title sort: Alpha(0), Beta(1), Charlie(2)
        // Move Alpha down → Beta(0), Alpha(1), Charlie(2)
        let result = simulateMoveBookInManualOrder(library: &library, bookID: idB, direction: 1, folderPath: "F")
        try assertEqual(result, 1, "Alpha should move from 0 to 1")

        let sorted = library.booksInFolder("F").sorted { ($0.manualSortOrder ?? 0) < ($1.manualSortOrder ?? 0) }
        try assertEqual(sorted[0].title, "Beta")
        try assertEqual(sorted[1].title, "Alpha")
        try assertEqual(sorted[2].title, "Charlie")
    }

    test("Manual order: only affects books in the same folder") {
        let idA = UUID(), idB = UUID(), idOther = UUID()
        var library = Library(books: [
            Book(title: "Alpha", folderPath: "F", manualSortOrder: 0, id: idA),
            Book(title: "Beta", folderPath: "F", manualSortOrder: 1, id: idB),
            Book(title: "Other", folderPath: "G", manualSortOrder: 0, id: idOther),
        ])

        simulateMoveBookInManualOrder(library: &library, bookID: idA, direction: 1, folderPath: "F")

        // Book in folder G should be unaffected
        let otherBook = library.books.first(where: { $0.id == idOther })!
        try assertEqual(otherBook.manualSortOrder, 0, "Book in other folder unchanged")
    }

    test("Manual order: sequential moves maintain consistent ordering") {
        let idA = UUID(), idB = UUID(), idC = UUID(), idD = UUID()
        var library = Library(books: [
            Book(title: "A", folderPath: "F", manualSortOrder: 0, id: idA),
            Book(title: "B", folderPath: "F", manualSortOrder: 1, id: idB),
            Book(title: "C", folderPath: "F", manualSortOrder: 2, id: idC),
            Book(title: "D", folderPath: "F", manualSortOrder: 3, id: idD),
        ])

        // Move D up three times to reach the top: D,A,B,C
        simulateMoveBookInManualOrder(library: &library, bookID: idD, direction: -1, folderPath: "F")
        simulateMoveBookInManualOrder(library: &library, bookID: idD, direction: -1, folderPath: "F")
        simulateMoveBookInManualOrder(library: &library, bookID: idD, direction: -1, folderPath: "F")

        let sorted = library.booksInFolder("F").sorted { ($0.manualSortOrder ?? 0) < ($1.manualSortOrder ?? 0) }
        try assertEqual(sorted[0].id, idD, "D should be first")
        try assertEqual(sorted[1].id, idA, "A should be second")
        try assertEqual(sorted[2].id, idB, "B should be third")
        try assertEqual(sorted[3].id, idC, "C should be fourth")

        // Verify orders are sequential 0,1,2,3
        for (i, book) in sorted.enumerated() {
            try assertEqual(book.manualSortOrder, i, "Order should be sequential")
        }
    }

    test("Manual order: manualSortOrder persists in Book model") {
        // Verify the field round-trips through Codable
        let book = Book(title: "Test", manualSortOrder: 42)
        let encoder = JSONEncoder()
        let data = try encoder.encode(book)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Book.self, from: data)
        try assertEqual(decoded.manualSortOrder, 42, "manualSortOrder should round-trip")
    }

    // Helper init extension to allow setting id in tests
}

private extension Book {
    init(title: String, folderPath: String = "", manualSortOrder: Int? = nil, id: UUID = UUID()) {
        self.init(
            id: id,
            title: title,
            folderPath: folderPath,
            manualSortOrder: manualSortOrder
        )
    }
}
