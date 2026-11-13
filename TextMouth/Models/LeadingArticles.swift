import Foundation

// MARK: - The Setting

/// What a title's leading article ("The", "A", "An", and the articles of a
/// book's own language) does in the Library's lists: the Library tab's
/// Leading Articles setting, which the user asked for on November 13, 2026
/// (TITLE-ARTICLES-RESEARCH-2026-11-13.md). config.json mirrors it as
/// `leadingArticles`.
///
/// It never changes a book's title. Book Information, a reader's window,
/// Now Playing, Export, and the files keep each title as it is written; the
/// setting changes only how the Library's lists sort titles, show them, and
/// find them by typing.
enum LeadingArticles: String, CaseIterable, Sendable {
    /// A leading article is part of the title, as everywhere before this
    /// setting: "The Hobbit" sorts among the T's, and the list's own letter
    /// navigation finds titles as they are written. The default, so nothing
    /// changes until the user chooses.
    case partOfTitle
    /// Typing a title's first letters passes over its leading article: H
    /// goes to "The Hobbit". The list keeps its order and shows each title
    /// as it is written.
    case ignoredWhenTyping
    /// Typing and sorting both pass over a title's leading article: "The
    /// Hobbit" sorts among the H's, its row shows "Hobbit, The", as an
    /// encyclopedia's index does, and H goes to it.
    case ignoredWhenTypingAndSorting

    /// Whether lists sort titles without their leading articles, and show
    /// each article after its title.
    var sortsWithoutArticles: Bool {
        self == .ignoredWhenTypingAndSorting
    }

    /// Whether typing a title passes over its leading article.
    var typesWithoutArticles: Bool {
        self != .partOfTitle
    }

    /// The choice in the preferences store, saved as its raw value and read
    /// through `SettingsPolicy.leadingArticles`, so a missing or unsupported
    /// value reads as the default. The Library windows read it there; the
    /// settings model mirrors it in config.json.
    static let preference = StoredPreference<LeadingArticles>(
        key: SettingsPolicy.leadingArticles.key,
        read: { store, key in SettingsPolicy.leadingArticles.value(fromRaw: store.object(forKey: key) as? String) },
        write: { choice, store, key in store.set(choice.rawValue, forKey: key) }
    )

    // MARK: What a List Does With a Title

    /// The text a list sorts `title` by: the title from where it files, its
    /// leading article left out, when sorting passes over articles
    /// ("Hobbit" for "The Hobbit"); otherwise the title as written.
    /// `language` is the book's metadata language, whose articles count
    /// beside English's.
    func sortKey(of title: String, language: String?) -> String {
        guard sortsWithoutArticles else { return title }
        return FilingTitle(title, language: language).key
    }

    /// The title a list's row shows and VoiceOver reads: "Hobbit, The" when
    /// sorting passes over articles, so the row shows the word it sorts by
    /// first; otherwise the title as written.
    func shownTitle(_ title: String, language: String?) -> String {
        guard sortsWithoutArticles else { return title }
        return FilingTitle(title, language: language).inverted
    }

    /// The title `book`'s row shows in place of the book's own, in the
    /// articles of English and of its metadata language: inverted while
    /// sorting passes over articles; nil while titles are shown as written,
    /// so the row shows the book's own title and makes no new text.
    func rowTitle(of book: Book) -> String? {
        sortsWithoutArticles ? shownTitle(book.title, language: book.epubLanguage) : nil
    }
}

// MARK: - A Title as a Library Files It

/// A title read as a library files it: its nonfiling part, which a sort
/// passes over, and the rest, where the sort begins (MARC 21 field 245's
/// second indicator counts the nonfiling characters: "The " is 4, "L'" in
/// "L'enfant" 2, and "[The " 5, a bracket before the article counting with
/// it).
///
/// The nonfiling part is a leading article of English or of the book's
/// language (`ArticleLanguage`), with any opening punctuation before it,
/// such as a quotation mark or a parenthesis, and the space after it:
///
/// - A word article ("The", "Le", "Die") must be followed by a space and
///   more title, holding a letter or a number: "The" alone is a title, and
///   so are "The." and "A.I.".
/// - An elided article ("L'", "Gl'", "Un'") joins the next word, which
///   begins with a letter: "L'Étranger".
/// - An article that begins with an apostrophe ("'t", "'n", "'s") is
///   followed by a space, as a word article is.
/// - English "A" is not an article where it is the letter A: before "is",
///   "was", "to", "for", "and", "or", "through", "versus", "vs", "&", or a
///   single letter, as in "A Is for Alibi" and "A to Z".
///
/// The article is matched in any letter case, and with any of the
/// apostrophes typists use (', ’, ʼ); accents count, so "À la recherche"
/// keeps its "À".
struct FilingTitle: Equatable, Sendable {
    /// The title as written.
    let title: String
    /// The punctuation that opens the title before its article: a quotation
    /// mark, a parenthesis, a bracket, or several; "" for none, and always
    /// "" for a title with no article.
    let opening: Substring
    /// The leading article as written: "The", "L’", "'t"; nil when the
    /// title has none.
    let article: Substring?
    /// The title from where it files: after the opening punctuation, the
    /// article, and the space after it; the whole title when it has no
    /// article.
    let rest: Substring

    /// `title` read in the articles of English and of `language`, the
    /// book's metadata language (`ArticleLanguage(metadataLanguage:)`).
    init(_ title: String, language: String?) {
        self.init(title, articles: ArticleLanguage.articles(forMetadataLanguage: language))
    }

    /// `title` read with `articles`, lowercased, each written with the plain
    /// apostrophe, longest first.
    init(_ title: String, articles: [String]) {
        self.title = title
        if let found = Self.leadingArticle(in: title, articles: articles) {
            opening = found.opening
            article = found.article
            rest = found.rest
        } else {
            opening = ""
            article = nil
            rest = Substring(title)
        }
    }

    /// The text a sort reads: the title from where it files.
    var key: String {
        String(rest)
    }

    /// Whether the article joins the next word, as "L'" does.
    var isElided: Bool {
        article.map { Self.plainApostrophes($0).hasSuffix("'") } ?? false
    }

    /// The title as an index shows it, its article after the words it
    /// sorts by: "Hobbit, The", "Étranger, L'", "39 Steps, The". The
    /// article goes after the main title, so a subtitle keeps its place
    /// ("Hobbit, The: There and Back Again", "Fellowship of the Ring, The
    /// (The Lord of the Rings, Book 1)"), and inside the quotation marks or
    /// parentheses that opened the title ("\"Raven, The\" and Other Poems").
    /// A title with no article is shown as written.
    var inverted: String {
        guard let article else { return title }
        let insertion = articleInsertionIndex
        return String(opening) + String(rest[..<insertion]) + ", " + String(article) + String(rest[insertion...])
    }

    /// Where in `rest` the article goes back in the inverted title: at the
    /// end of the main title (`mainTitleEnd`), before any spaces that end
    /// it, so "Hobbit : There" shows "Hobbit, The : There".
    private var articleInsertionIndex: Substring.Index {
        var insertion = mainTitleEnd
        while insertion > rest.startIndex, rest[rest.index(before: insertion)].isWhitespace {
            insertion = rest.index(before: insertion)
        }
        return insertion
    }

    /// Where the main title ends in `rest`: at the mark that closes the
    /// opening punctuation, when `rest` holds one at the end of a word;
    /// otherwise at a colon, a semicolon, or a spaced dash or bracket, which
    /// begins a subtitle or a note; otherwise at the end.
    private var mainTitleEnd: Substring.Index {
        if let opener = opening.last {
            let closers = Self.closingMarks(of: opener)
            var index = rest.startIndex
            while index < rest.endIndex {
                if closers.contains(rest[index]) {
                    // A closing mark ends a word, so the apostrophe inside
                    // "Hobbit's" is not one.
                    let after = rest.index(after: index)
                    if after == rest.endIndex || !(rest[after].isLetter || rest[after].isNumber) {
                        return index
                    }
                }
                index = rest.index(after: index)
            }
        }
        var index = rest.startIndex
        while index < rest.endIndex {
            let character = rest[index]
            if character == ":" || character == ";" {
                return index
            }
            if character.isWhitespace {
                // A run of spaces, then a bracket, or a dash with a space
                // after it: the subtitle begins at the first space.
                let next = rest[index...].firstIndex { !$0.isWhitespace } ?? rest.endIndex
                if next < rest.endIndex {
                    let mark = rest[next]
                    if "([{".contains(mark) {
                        return index
                    }
                    let afterMark = rest.index(after: next)
                    if "-–—".contains(mark), afterMark < rest.endIndex, rest[afterMark].isWhitespace {
                        return index
                    }
                }
                index = next
                continue
            }
            index = rest.index(after: index)
        }
        return rest.endIndex
    }

    // MARK: Finding the Article

    /// The words after which English "A" is the letter A and no article:
    /// "A Is for Alibi", "A to Z", "A for Effort", "A and B", "A vs. B".
    static let wordsAfterTheLetterA: Set<String> = [
        "is", "was", "to", "for", "and", "or", "through", "thru", "versus", "vs", "&", "+",
    ]

    /// The opening punctuation, the article, and the rest of `title`, or
    /// nil when it begins with no article of `articles`.
    private static func leadingArticle(
        in title: String,
        articles: [String]
    ) -> (opening: Substring, article: Substring, rest: Substring)? {
        // Spaces before the title are never part of it.
        var start = title.startIndex
        while start < title.endIndex, title[start].isWhitespace {
            start = title.index(after: start)
        }
        // An article that begins with an apostrophe ('t, 'n, 's) comes
        // first, before the apostrophe can be read as an opening quotation
        // mark.
        if let found = article(in: title, at: start, articles: articles.filter { $0.hasPrefix("'") }) {
            return (title[start..<start], found.article, found.rest)
        }
        var afterOpening = start
        while afterOpening < title.endIndex, isOpeningPunctuation(title[afterOpening]) {
            afterOpening = title.index(after: afterOpening)
        }
        guard let found = article(in: title, at: afterOpening, articles: articles.filter { !$0.hasPrefix("'") }) else {
            return nil
        }
        return (title[start..<afterOpening], found.article, found.rest)
    }

    /// The first of `articles` that `title` holds at `index`, as an article
    /// (see the type), and the title after it and its space.
    private static func article(
        in title: String,
        at index: String.Index,
        articles: [String]
    ) -> (article: Substring, rest: Substring)? {
        for candidate in articles {
            guard let end = title.index(index, offsetBy: candidate.count, limitedBy: title.endIndex) else { continue }
            let written = title[index..<end]
            guard plainApostrophes(written).lowercased() == candidate else { continue }
            var restStart = end
            if candidate.hasSuffix("'") {
                // An elided article joins the word after it, which begins
                // with a letter; a space typed between them is passed over.
                while restStart < title.endIndex, title[restStart].isWhitespace {
                    restStart = title.index(after: restStart)
                }
                guard restStart < title.endIndex, title[restStart].isLetter else { continue }
            } else {
                // A word article ends at a space, and more title follows.
                guard restStart < title.endIndex, title[restStart].isWhitespace else { continue }
                while restStart < title.endIndex, title[restStart].isWhitespace {
                    restStart = title.index(after: restStart)
                }
                let rest = title[restStart...]
                guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                if candidate == "a", isTheLetterA(before: rest) { continue }
            }
            return (written, title[restStart...])
        }
        return nil
    }

    /// Whether "A" before `rest` is the letter A: the next word is one of
    /// `wordsAfterTheLetterA`, or a single letter ("A B C").
    private static func isTheLetterA(before rest: Substring) -> Bool {
        let word = rest.prefix { !$0.isWhitespace }
        let bare = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        if wordsAfterTheLetterA.contains(bare) {
            return true
        }
        return bare.count == 1 && bare.first?.isLetter == true
    }

    /// Whether `character` opens a title before its article: an opening
    /// bracket or an initial quotation mark (Unicode's Ps and Pi), a
    /// straight quotation mark or apostrophe, or Spanish ¡ and ¿.
    static func isOpeningPunctuation(_ character: Character) -> Bool {
        if "\"'¡¿".contains(character) {
            return true
        }
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .openPunctuation, .initialPunctuation: return true
        default: return false
        }
    }

    /// The marks that close `opener`: ")" for "(", "”" for "“", the same
    /// mark for a straight one, and both closing quotes for German „ and ‚.
    private static func closingMarks(of opener: Character) -> Set<Character> {
        switch opener {
        case "(": return [")"]
        case "[": return ["]"]
        case "{": return ["}"]
        case "“": return ["”"]
        case "‘": return ["’"]
        case "«": return ["»"]
        case "‹": return ["›"]
        case "„": return ["“", "”"]
        case "‚": return ["‘", "’"]
        case "¡": return ["!"]
        case "¿": return ["?"]
        default: return [opener]
        }
    }

    /// `text` with every apostrophe typists use written as the plain one,
    /// so "L’" and "L'" are one article.
    static func plainApostrophes<Text: StringProtocol>(_ text: Text) -> String {
        String(text.map { "’ʼ‘".contains($0) ? "'" : $0 })
    }
}

// MARK: - The Articles of Each Language

/// The languages whose leading articles TextMouth knows beside English's,
/// with the articles the Library of Congress lists for each (MARC 21
/// Bibliographic, Appendix F, "Initial Definite and Indefinite Articles").
/// A book uses English's always, and its own language's when its metadata
/// names one of these (`Book.epubLanguage`), so "Die Hard" in an English
/// book keeps its "Die" and "Die Verwandlung" in a German one files under V.
enum ArticleLanguage: String, CaseIterable, Sendable {
    case english, french, german, spanish, italian, portuguese, dutch, catalan, swedish, danish, norwegian

    /// The language's leading articles, lowercased, with the plain
    /// apostrophe: Appendix F's for the language, but for English, whose
    /// archaic "ye" and "d'" and "de" (as in the names of books written in
    /// French or Latin) are left out, and Norwegian, whose dialect "e" is
    /// left out as a letter more often than an article.
    var articles: [String] {
        switch self {
        case .english: return ["the", "a", "an"]
        case .french: return ["le", "la", "les", "un", "une", "l'"]
        case .german: return ["der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "eines", "'s"]
        case .spanish: return ["el", "la", "los", "las", "lo", "un", "una"]
        case .italian: return ["il", "lo", "la", "i", "gli", "le", "un", "uno", "una", "l'", "gl'", "un'"]
        case .portuguese: return ["o", "a", "os", "as", "um", "uma"]
        case .dutch: return ["de", "het", "een", "eene", "'t", "'n"]
        case .catalan: return ["el", "els", "la", "les", "en", "un", "una", "l'"]
        case .swedish: return ["den", "det", "de", "en", "ett"]
        case .danish: return ["den", "det", "de", "en", "et"]
        case .norwegian: return ["den", "det", "de", "dei", "en", "ei", "ein", "et", "eit"]
        }
    }

    /// The names a book's metadata may give the language, lowercased: its
    /// ISO 639-1 code, its ISO 639-2 codes (bibliographic and terminology),
    /// its English name, and its own name.
    private var names: [String] {
        switch self {
        case .english: return ["en", "eng", "english"]
        case .french: return ["fr", "fre", "fra", "french", "français", "francais"]
        case .german: return ["de", "ger", "deu", "german", "deutsch"]
        case .spanish: return ["es", "spa", "spanish", "español", "espanol", "castellano"]
        case .italian: return ["it", "ita", "italian", "italiano"]
        case .portuguese: return ["pt", "por", "portuguese", "português", "portugues"]
        case .dutch: return ["nl", "dut", "nld", "dutch", "nederlands"]
        case .catalan: return ["ca", "cat", "catalan", "català"]
        case .swedish: return ["sv", "swe", "swedish", "svenska"]
        case .danish: return ["da", "dan", "danish", "dansk"]
        case .norwegian: return ["no", "nb", "nn", "nor", "nob", "nno", "norwegian", "norsk", "bokmål", "bokmal", "nynorsk"]
        }
    }

    /// Every language, by each of its names.
    private static let byName: [String: ArticleLanguage] = {
        var byName: [String: ArticleLanguage] = [:]
        for language in allCases {
            for name in language.names {
                byName[name] = language
            }
        }
        return byName
    }()

    /// The language a book's metadata names, or nil for one TextMouth knows
    /// no articles of, or none: a language tag ("fr", "fr-CA", "pt_BR"), an
    /// ISO 639-2 code ("fre", "deu"), or a name ("French", "Deutsch"), in
    /// any letter case. A tag's region and script are passed over, and of a
    /// list ("en, fr") the first is read.
    init?(metadataLanguage: String?) {
        guard let metadataLanguage else { return nil }
        let first = metadataLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .prefix { !"-_,; ".contains($0) }
        guard let language = Self.byName[String(first)] else { return nil }
        self = language
    }

    /// English's articles and those of the language `metadataLanguage`
    /// names, without repeats, longest first, so "les" is tried before
    /// "le" and "eine" before "ein".
    static func articles(forMetadataLanguage metadataLanguage: String?) -> [String] {
        let language = ArticleLanguage(metadataLanguage: metadataLanguage) ?? .english
        return articleLists[language] ?? englishArticles
    }

    /// English's articles alone, longest first.
    private static let englishArticles = ArticleLanguage.english.articles.sorted { $0.count > $1.count }

    /// Each language's articles with English's, longest first, made once.
    private static let articleLists: [ArticleLanguage: [String]] = {
        var lists: [ArticleLanguage: [String]] = [:]
        for language in allCases {
            var seen = Set<String>()
            let merged = (ArticleLanguage.english.articles + language.articles).filter { seen.insert($0).inserted }
            // Longest first; among articles of one length, the list's own
            // order, so the result never depends on a hash.
            lists[language] = merged.enumerated()
                .sorted { $0.element.count != $1.element.count ? $0.element.count > $1.element.count : $0.offset < $1.offset }
                .map(\.element)
        }
        return lists
    }()
}
