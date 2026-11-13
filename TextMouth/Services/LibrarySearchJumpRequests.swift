import Foundation

// MARK: - A Request to Move to a Match

/// A request that a book's reader move to a match Search Library found
/// (LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 5): made just before the
/// Search Library window opens the book's reader, or brings its window
/// forward, as opening a book from the Library does.
///
/// A reader window is identified by its book's ID alone, so the match cannot
/// ride on the window's value; the reader claims this request instead,
/// exactly once, once its book has loaded: as its load ends, for a window the
/// open made, or at once, for a reader already open and loaded
/// (`ReaderRequestStore.requestsMade`). It waits in
/// `LibrarySearchJumpRequests`, a `ReaderRequestStore`.
///
/// It carries the match's place and what was searched for, so the reader
/// finds the very match again in the text it shows: at the place, when the
/// text there still matches, or, when the book's text changed since the
/// search (Edit Text, a rebuild), the match nearest the old place.
struct LibrarySearchJumpRequest: ReaderRequest {
    /// The book whose reader moves.
    let bookID: UUID
    /// When the request was made.
    let createdAt: Date
    /// The text searched for.
    let query: String
    /// The options it was searched with.
    let options: TextSearchOptions
    /// The chapter (content unit) holding the match.
    let chapterIndex: Int
    /// The match's UTF-16 offset in that chapter's text.
    let characterOffset: Int
    /// The match's UTF-16 offset from the start of the book.
    let globalOffset: Int
    /// The text that matched, as it was in the book.
    let matchedText: String
}

// MARK: - Request Store

/// The requests to move to a library search's match that wait for the
/// books' readers: a store of the one shape every reader request takes
/// (`ReaderRequestStore`), as the reading list's and the autoplay requests'
/// are.
typealias LibrarySearchJumpRequests = ReaderRequestStore<LibrarySearchJumpRequest>

/// The store readers and the Search Library window use unless a test gives
/// a reader its own, made on the main actor at its first use.
@MainActor private let sharedLibrarySearchJumpRequests = LibrarySearchJumpRequests()

extension ReaderRequestStore where Request == LibrarySearchJumpRequest {
    /// The store readers and the Search Library window use unless a test
    /// gives a reader its own.
    static var shared: LibrarySearchJumpRequests {
        sharedLibrarySearchJumpRequests
    }

    /// Ask that the reader of `match`'s book move to it, found by `query`
    /// searched with `options`, replacing any request already waiting for
    /// that book, and tell `requestsMade`.
    ///
    /// - Returns: The request made. A reader already open for the book may
    ///   have claimed it by the time this returns.
    @discardableResult
    func request(
        bookID: UUID,
        match: BookSearchResult,
        query: String,
        options: TextSearchOptions
    ) -> LibrarySearchJumpRequest {
        add(LibrarySearchJumpRequest(
            bookID: bookID,
            createdAt: currentDate,
            query: query,
            options: options,
            chapterIndex: match.chapterIndex,
            characterOffset: match.characterOffset,
            globalOffset: match.globalOffset,
            matchedText: match.matchedText
        ))
    }
}
