import Foundation

// MARK: - What Typing Reaches

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
    func isReached(by typed: String, showingInverted: Bool) -> Bool {
        begins(with: typed, showingInverted: showingInverted, articleAloneCounts: false)
    }

    /// Whether this title goes on with `typed`, whatever may be typed after
    /// it: the title from where it files, the title as written from its
    /// article, or, where the list shows titles inverted
    /// (`showingInverted`), the title as its row shows it, begins with it.
    /// Unlike `isReached(by:showingInverted:)`, the article and its space
    /// alone count ("the " goes on into "The Hobbit"), since a Space typed
    /// there is to be followed by more.
    func goesOn(with typed: String, showingInverted: Bool) -> Bool {
        begins(with: typed, showingInverted: showingInverted, articleAloneCounts: true)
    }

    /// Whether one of this title's forms begins with `typed`: its filing
    /// text; the title as written from its article, where the letters go
    /// past the article and its space unless `articleAloneCounts`; or, when
    /// `showingInverted`, the inverted title.
    private func begins(with typed: String, showingInverted: Bool, articleAloneCounts: Bool) -> Bool {
        guard !typed.isEmpty else { return false }
        if Self.text(filing, beginsWith: typed) {
            return true
        }
        guard let article else { return false }
        let nonfiling = String(article) + (isElided ? "" : " ")
        if articleAloneCounts || typed.count > nonfiling.count, Self.text(nonfiling + rest, beginsWith: typed) {
            return true
        }
        return showingInverted && Self.text(inverted, beginsWith: typed)
    }

    /// Whether `text` begins with `typed`, ignoring letter case, accents,
    /// character widths, and which apostrophe each was written with.
    static func text<Text: StringProtocol>(_ text: Text, beginsWith typed: String) -> Bool {
        plainApostrophes(text).range(
            of: plainApostrophes(typed),
            options: [.anchored, .caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) != nil
    }
}

// MARK: - One Row as Typing Reaches It

/// One row of a list, as letter navigation reaches it: the row's identity,
/// which the list selects, and its title as a library files it. A folder's
/// name is filed as written, with no article (`FilingTitle(_:articles:)`
/// with none), since the user types folder names themselves.
struct TypedRow<ID: Hashable>: Equatable {
    /// The row's identity in the list's selection.
    let id: ID
    /// The row's title, read for its leading article.
    let title: FilingTitle

    /// A row whose title, a book's or a feed's, is read in the articles of
    /// English and of `language`, the book's metadata language.
    init(id: ID, title: String, language: String?) {
        self.id = id
        self.title = FilingTitle(title, language: language)
    }

    /// A row whose name has no article to pass over: a folder's.
    init(id: ID, name: String) {
        self.id = id
        title = FilingTitle(name, articles: [])
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
        let start = searchStart(in: rows, selection: selection, isNewSearch: isNewSearch)
        for offset in 0..<rows.count {
            let row = rows[(start + offset) % rows.count]
            if row.title.isReached(by: typed, showingInverted: showingInverted) {
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
        let withSpace = typed + " "
        return rows.contains { $0.title.goesOn(with: withSpace, showingInverted: showingInverted) }
    }
}
