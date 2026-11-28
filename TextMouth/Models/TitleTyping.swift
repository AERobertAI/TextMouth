import Foundation
import os

// MARK: - Folding Text for Comparison

/// How text typed and titles are folded before they are compared: letter
/// case, accents, and character width never matter, and every apostrophe
/// typists use reads as the plain one, as in AppKit's own letter navigation.
///
/// A title is folded once, when its row is made (`TypedForms`), and the
/// letters typed once per key, so comparing them is a `hasPrefix` and no
/// per-row work: folding a title costs far more than comparing it, and a
/// Library of thousands of titles is scanned at every key.
enum TitleFolding {
    /// How many texts have been folded, which tests read to see that a key
    /// folds the letters typed and no title. A lock rather than an unchecked
    /// variable, since any thread may fold.
    private static let folds = OSAllocatedUnfairLock(initialState: 0)

    /// How many texts `fold(_:)` has folded so far.
    static var foldCount: Int {
        folds.withLock { $0 }
    }

    /// `text` folded for comparison.
    static func fold(_ text: String) -> String {
        folds.withLock { $0 += 1 }
        return FilingTitle.plainApostrophes(text).folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
    }
}

/// The letters typed into a list, folded once for a whole scan of its rows.
struct TypedQuery: Equatable, Sendable {
    /// The letters as typed.
    let typed: String
    /// The letters folded (`TitleFolding`).
    let folded: String

    /// The query for `typed`: folds it, once.
    init(_ typed: String) {
        self.typed = typed
        folded = TitleFolding.fold(typed)
    }

    /// Whether nothing was typed.
    var isEmpty: Bool {
        typed.isEmpty
    }
}

// MARK: - What Typing Reaches

/// The forms of one title that typing is compared with, each folded once
/// (`TitleFolding`): where a title is reached from, and where it goes on from.
struct TypedForms: Equatable, Sendable {
    /// The title from where it files, folded.
    let filing: String
    /// The title as written from its article (the article, its space unless
    /// it is elided, and the rest), folded; nil for a title with no article.
    let fromArticle: String?
    /// How many characters the article and its space take as typed, which
    /// letters must outnumber to go past the article; 0 with no article.
    let nonfilingCount: Int
    /// The title as an index shows it ("hobbit, the"), folded; nil for a
    /// title with no article, which shows as written.
    let inverted: String?

    /// The forms of `title`, folding each once.
    init(_ title: FilingTitle) {
        filing = TitleFolding.fold(String(title.filing))
        if let article = title.article {
            let nonfiling = String(article) + (title.isElided ? "" : " ")
            fromArticle = TitleFolding.fold(nonfiling + title.rest)
            nonfilingCount = nonfiling.count
            inverted = TitleFolding.fold(title.inverted)
        } else {
            fromArticle = nil
            nonfilingCount = 0
            inverted = nil
        }
    }

    /// Whether one of the title's forms begins with `query`: its filing
    /// text; the title as written from its article, where the letters go
    /// past the article and its space unless `articleAloneCounts`; or, when
    /// `showingInverted`, the inverted title.
    func begins(with query: TypedQuery, showingInverted: Bool, articleAloneCounts: Bool) -> Bool {
        guard !query.isEmpty else { return false }
        if filing.hasPrefix(query.folded) {
            return true
        }
        guard let fromArticle else { return false }
        if articleAloneCounts || query.typed.count > nonfilingCount, fromArticle.hasPrefix(query.folded) {
            return true
        }
        return showingInverted && inverted?.hasPrefix(query.folded) == true
    }
}

extension FilingTitle {
    /// Whether `typed`, the letters typed into a list whose letter
    /// navigation passes over leading articles, reaches this title: the
    /// title from where it files begins with them ("h" and "hob" reach "The
    /// Hobbit"); or, when the title has an article, they are that article
    /// typed as a word and then more of the title as written ("the h", the
    /// user's "if the letters are not for an article"; "l'é" for
    /// "L'Étranger"); or, where the list shows titles inverted
    /// (`showingInverted`), they begin the title as its row shows it
    /// ("hobbit, t").
    ///
    /// Letter case, accents, and the apostrophe a typist used never matter,
    /// as in AppKit's own letter navigation. The article typed alone ("the")
    /// reaches only titles that file under those letters, such as "Theory of
    /// Everything", since more letters may follow.
    ///
    /// Folds this title and the letters afresh: a list of many titles
    /// compares its rows' own forms (`TypedForms`) instead.
    func isReached(by typed: String, showingInverted: Bool) -> Bool {
        TypedForms(self).begins(with: TypedQuery(typed), showingInverted: showingInverted, articleAloneCounts: false)
    }

    /// Whether this title goes on with `typed`, whatever may be typed after
    /// it: the title from where it files, the title as written from its
    /// article, or, where the list shows titles inverted
    /// (`showingInverted`), the title as its row shows it, begins with it.
    /// Unlike `isReached(by:showingInverted:)`, the article and its space
    /// alone count ("the " goes on into "The Hobbit"), since a Space typed
    /// there is to be followed by more.
    func goesOn(with typed: String, showingInverted: Bool) -> Bool {
        TypedForms(self).begins(with: TypedQuery(typed), showingInverted: showingInverted, articleAloneCounts: true)
    }
}

// MARK: - One Row as Typing Reaches It

/// One row of a list, as letter navigation reaches it: the row's identity,
/// which the list selects, and its title's forms, folded once when the row
/// is made. A folder's name is filed as written, with no article
/// (`FilingTitle(_:articles:)` with none), since the user types folder names
/// themselves.
struct TypedRow<ID: Hashable>: Equatable {
    /// The row's identity in the list's selection.
    let id: ID
    /// The row's title as typing compares it.
    let forms: TypedForms

    /// A row whose title, a book's or a feed's, is read in the articles of
    /// English and of `language`, the book's metadata language.
    init(id: ID, title: String, language: String?) {
        self.id = id
        forms = TypedForms(FilingTitle(title, language: language))
    }

    /// A row whose name has no article to pass over: a folder's.
    init(id: ID, name: String) {
        self.id = id
        forms = TypedForms(FilingTitle(name, articles: []))
    }
}

// MARK: - The Letters Typed

/// The letters typed into a list to go to a row, gathered as AppKit's type
/// select gathers them: a key typed within `interval` of the one before adds
/// to the search, and one typed later starts a new search.
///
/// A Space is a letter of the search only while a title in the list goes
/// on with it (`TitleTyping.spaceGoesOn(after:in:showingInverted:)`), so "the
/// h" and "lord of" can be typed, and a Space typed at any other time keeps
/// its own meaning, Play or Pause in a Library window.
struct TitleTypingSearch: Equatable, Sendable {
    /// The letters typed so far: "" before any.
    private(set) var typed = ""
    /// When the last of them was typed, in seconds of system uptime, the
    /// clock key events are stamped by; nil before any.
    private(set) var lastTypedAt: TimeInterval?

    /// Whether a search is under way at `time`: letters were typed, the last
    /// of them no more than `interval` seconds before.
    func isUnderWay(at time: TimeInterval, interval: TimeInterval) -> Bool {
        guard let lastTypedAt, !typed.isEmpty else { return false }
        return time - lastTypedAt <= interval
    }

    /// Adds `characters`, typed at `time`, to the search under way whatever
    /// the time: for a Space the list's claim accepted (`TitleTypingSpaceClaim`),
    /// which was decided after the last letter and so needs no second look
    /// at the clock.
    mutating func extend(with characters: String, at time: TimeInterval) {
        typed += characters
        lastTypedAt = time
    }

    /// Adds `characters`, typed at `time`: to the search under way, or, when
    /// none is, as the start of a new one. Returns whether a new one began.
    @discardableResult
    mutating func add(_ characters: String, at time: TimeInterval, interval: TimeInterval) -> Bool {
        let isNew = !isUnderWay(at: time, interval: interval)
        if isNew {
            typed = ""
        }
        typed += characters
        lastTypedAt = time
        return isNew
    }
}

// MARK: - The Row Typing Goes To

enum TitleTyping {
    /// The row typing `typed` goes to, found as AppKit's own type select
    /// finds it (measured by `LibraryTypeSelectProbeTests`): the first of
    /// `rows`, from where the search starts and wrapping round the end,
    /// that `typed` reaches (`FilingTitle.isReached(by:showingInverted:)`);
    /// nil when none does.
    ///
    /// - A new search starts at the row after the selected one (with
    ///   several rows selected, the last in the list's order), so a letter
    ///   typed again after a pause moves on to the next title with it, a
    ///   lone match stays where it is, and H, a pause, and H walks through
    ///   the H's and wraps.
    /// - A search that adds letters to one under way starts at the
    ///   selected row itself, so "ha" typed after "h" stays on Hamlet.
    /// - With nothing selected, either starts at the top.
    ///
    /// `showingInverted` is whether the list shows titles as an index does
    /// ("Hobbit, The"), as it does while sorting passes over articles.
    static func firstRow<ID: Hashable>(
        reachedBy typed: String,
        in rows: [TypedRow<ID>],
        selection: Set<ID> = [],
        isNewSearch: Bool = true,
        showingInverted: Bool
    ) -> ID? {
        guard !rows.isEmpty else { return nil }
        // The letters are folded once for the whole scan; each row's forms
        // were folded when the row was made.
        let query = TypedQuery(typed)
        let start = searchStart(in: rows, selection: selection, isNewSearch: isNewSearch)
        for offset in 0..<rows.count {
            let row = rows[(start + offset) % rows.count]
            if row.forms.begins(with: query, showingInverted: showingInverted, articleAloneCounts: false) {
                return row.id
            }
        }
        return nil
    }

    /// The index in `rows` a search starts at: the top when no row of
    /// `rows` is selected; otherwise the last selected row, in the list's
    /// order, or, for a new search, the row after it (the first row after
    /// the last).
    /// - Precondition: `rows` is not empty.
    static func searchStart<ID: Hashable>(in rows: [TypedRow<ID>], selection: Set<ID>, isNewSearch: Bool) -> Int {
        guard let selected = rows.lastIndex(where: { selection.contains($0.id) }) else { return 0 }
        return isNewSearch ? (selected + 1) % rows.count : selected
    }

    /// Whether a Space typed after `typed` joins the search: some row of
    /// `rows` goes on with the letters and a space
    /// (`FilingTitle.goesOn(with:showingInverted:)`), as "The Hobbit" goes
    /// on with "the " and "Lord of the Rings" with "lord ". At any other
    /// time a Space keeps its own meaning.
    static func spaceGoesOn<ID: Hashable>(after typed: String, in rows: [TypedRow<ID>], showingInverted: Bool) -> Bool {
        guard !typed.isEmpty else { return false }
        let query = TypedQuery(typed + " ")
        return rows.contains { $0.forms.begins(with: query, showingInverted: showingInverted, articleAloneCounts: true) }
    }
}
