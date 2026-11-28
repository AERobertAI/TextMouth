import XCTest
@testable import TextMouth

/// A title's leading article as a library files it (`FilingTitle`), the
/// articles of each language (`ArticleLanguage`), and the setting's sort keys
/// and shown titles (`LeadingArticles`): TITLE-ARTICLES-RESEARCH-2026-11-13.md.
///
/// Each table is checked row by row, and every mismatch is reported in one
/// failure, so one run shows every row the rule gets wrong.
final class LeadingArticlesTests: XCTestCase {

    // MARK: - The Sort Key and the Inverted Title

    /// One title, its metadata language, the text it sorts by, and the
    /// title as a row shows it while sorting passes over articles.
    private struct Filed {
        let title: String
        let language: String?
        let key: String
        let inverted: String
        let line: UInt

        init(_ title: String, _ language: String? = nil, key: String? = nil, inverted: String? = nil, line: UInt = #line) {
            self.title = title
            self.language = language
            self.key = key ?? title
            self.inverted = inverted ?? title
            self.line = line
        }
    }

    /// Checks each row of `table`, failing once with every mismatch.
    private func check(_ table: [Filed], file: StaticString = #filePath, line: UInt = #line) {
        var mismatches: [String] = []
        for row in table {
            let filed = FilingTitle(row.title, language: row.language)
            let language = row.language.map { " (\($0))" } ?? ""
            if filed.key != row.key {
                mismatches.append("line \(row.line): \"\(row.title)\"\(language) sorts by \"\(filed.key)\", not \"\(row.key)\"")
            }
            if filed.inverted != row.inverted {
                mismatches.append("line \(row.line): \"\(row.title)\"\(language) shows \"\(filed.inverted)\", not \"\(row.inverted)\"")
            }
        }
        XCTAssertEqual(mismatches, [], file: file, line: line)
    }

    /// English's The, A, and An, in any case, and what is not one of them:
    /// the article alone, an article joined to more letters, "A.I.", and the
    /// letter A ("A Is for Alibi").
    func testEnglishArticlesAndWhatIsNotOne() {
        check([
            Filed("The Hobbit", key: "Hobbit", inverted: "Hobbit, The"),
            Filed("A Tale of Two Cities", key: "Tale of Two Cities", inverted: "Tale of Two Cities, A"),
            Filed("An Instance of the Fingerpost", key: "Instance of the Fingerpost", inverted: "Instance of the Fingerpost, An"),
            Filed("THE HOBBIT", key: "HOBBIT", inverted: "HOBBIT, THE"),
            Filed("the hobbit", key: "hobbit", inverted: "hobbit, the"),
            Filed("tHe Hobbit", key: "Hobbit", inverted: "Hobbit, tHe"),
            Filed("The  Hobbit", key: "Hobbit", inverted: "Hobbit, The"),
            Filed("The\u{00A0}Hobbit", key: "Hobbit", inverted: "Hobbit, The"),
            Filed("  The Hobbit", key: "Hobbit", inverted: "Hobbit, The"),
            // The article alone, or with nothing more than punctuation, is
            // the title.
            Filed("The"),
            Filed("The "),
            Filed("A"),
            Filed("An"),
            Filed("The !"),
            Filed("The ..."),
            // Joined to more letters, or followed by a period, it is a word.
            Filed("Thebes"),
            Filed("Theory of Everything"),
            Filed("Anne of Green Gables"),
            Filed("Atonement"),
            Filed("A.I. Superpowers"),
            Filed("The-Hobbit"),
            Filed("A: The Novel"),
            // The letter A.
            Filed("A Is for Alibi"),
            Filed("A is for Apple"),
            Filed("A to Z of Gardening"),
            Filed("A for Effort"),
            Filed("A and B Testing"),
            Filed("A or B"),
            Filed("A Through Z"),
            Filed("A vs. B"),
            Filed("A & P"),
            Filed("A B C Murders"),
            // One article only: the second "A" files as written.
            Filed("The A.B.C. Murders", key: "A.B.C. Murders", inverted: "A.B.C. Murders, The"),
            Filed("A Midsummer Night's Dream", key: "Midsummer Night's Dream", inverted: "Midsummer Night's Dream, A"),
            // An article followed by a number.
            Filed("The 39 Steps", key: "39 Steps", inverted: "39 Steps, The"),
            Filed("A 1000 Years of Joys", key: "1000 Years of Joys", inverted: "1000 Years of Joys, A"),
        ])
    }

    /// Punctuation that opens a title before its article (a quotation mark
    /// or a parenthesis) is passed over with it, as MARC counts "[The " as
    /// five nonfiling characters, and the inverted title puts the article
    /// back inside the marks; punctuation before no article stays.
    func testOpeningPunctuationBeforeTheArticle() {
        check([
            Filed("\"The Raven\"", key: "Raven\"", inverted: "\"Raven, The\""),
            Filed("“The Raven” and Other Poems", key: "Raven” and Other Poems", inverted: "“Raven, The” and Other Poems"),
            Filed("(The Hobbit)", key: "Hobbit)", inverted: "(Hobbit, The)"),
            Filed("[The Part of Pennsylvania]", key: "Part of Pennsylvania]", inverted: "[Part of Pennsylvania, The]"),
            Filed("(“The Raven”)", key: "Raven”)", inverted: "(“Raven, The”)"),
            Filed("«The Raven»", key: "Raven»", inverted: "«Raven, The»"),
            // German and Danish open a quotation with ».
            Filed("»Der Prozess«", "de", key: "Prozess«", inverted: "»Prozess, Der«"),
            // A subtitle inside the marks: the article goes before it.
            Filed("\"The Raven: A Poem\"", key: "Raven: A Poem\"", inverted: "\"Raven, The: A Poem\""),
            Filed("(The Hobbit) [Illustrated]", key: "Hobbit) [Illustrated]", inverted: "(Hobbit, The) [Illustrated]"),
            // Opening punctuation after the article files with it, as MARC
            // counts it; the row keeps the marks where they are.
            Filed("The \"Best\" Of", key: "Best\" Of", inverted: "\"Best\" Of, The"),
            Filed("A 'Little' Life", key: "Little' Life", inverted: "'Little' Life, A"),
            // An apostrophe inside a word closes nothing.
            Filed("'The Hobbit's Journey'", key: "Hobbit's Journey'", inverted: "'Hobbit's Journey, The'"),
            // Never closed: the article goes after the main title.
            Filed("\"The Raven", key: "Raven", inverted: "\"Raven, The"),
            // No article after the punctuation: the title as written.
            Filed("\"Heart of Darkness\""),
            Filed("(The) Hobbit"),
            Filed("( The Hobbit )"),
        ])
    }

    /// The article goes after the main title, so a subtitle or a note keeps
    /// its place: after a colon, a semicolon, a spaced dash, or a spaced
    /// bracket. A comma inside the title is the title's own.
    func testTheArticleGoesAfterTheMainTitle() {
        check([
            Filed("The Hobbit: There and Back Again", key: "Hobbit: There and Back Again", inverted: "Hobbit, The: There and Back Again"),
            Filed("The Hobbit : There and Back Again", key: "Hobbit : There and Back Again", inverted: "Hobbit, The : There and Back Again"),
            Filed("The Hobbit; or, There and Back Again", key: "Hobbit; or, There and Back Again", inverted: "Hobbit, The; or, There and Back Again"),
            Filed(
                "The Fellowship of the Ring (The Lord of the Rings, Book 1)",
                key: "Fellowship of the Ring (The Lord of the Rings, Book 1)",
                inverted: "Fellowship of the Ring, The (The Lord of the Rings, Book 1)"
            ),
            Filed("The Hobbit [Illustrated]", key: "Hobbit [Illustrated]", inverted: "Hobbit, The [Illustrated]"),
            Filed("The Hobbit - A Graphic Novel", key: "Hobbit - A Graphic Novel", inverted: "Hobbit, The - A Graphic Novel"),
            Filed("The Hobbit — A Graphic Novel", key: "Hobbit — A Graphic Novel", inverted: "Hobbit, The — A Graphic Novel"),
            // A hyphen inside a word starts no subtitle.
            Filed("The Self-Made Man", key: "Self-Made Man", inverted: "Self-Made Man, The"),
            Filed("The Lion, the Witch and the Wardrobe", key: "Lion, the Witch and the Wardrobe", inverted: "Lion, the Witch and the Wardrobe, The"),
        ])
    }

    /// A book's own language adds its articles to English's; a language
    /// TextMouth knows no articles of, or none, adds none, so "Die Hard" in
    /// an English book keeps its "Die".
    func testABooksLanguageAddsItsArticles() {
        check([
            // German.
            Filed("Die Hard"),
            Filed("Die Hard", "en"),
            Filed("Die Hard", "en-US"),
            Filed("Die Verwandlung", "de", key: "Verwandlung", inverted: "Verwandlung, Die"),
            Filed("Der Prozess", "de-DE", key: "Prozess", inverted: "Prozess, Der"),
            Filed("Das Boot", "ger", key: "Boot", inverted: "Boot, Das"),
            Filed("Eine kleine Nachtmusik", "deu", key: "kleine Nachtmusik", inverted: "kleine Nachtmusik, Eine"),
            Filed("Ein Mann will nach oben", "German", key: "Mann will nach oben", inverted: "Mann will nach oben, Ein"),
            Filed("Das Boot", "en"),
            // French, with the elided L' joined to the next word.
            Filed("Le Petit Prince", "fr", key: "Petit Prince", inverted: "Petit Prince, Le"),
            Filed("Les Misérables", "fr-FR", key: "Misérables", inverted: "Misérables, Les"),
            Filed("La Peste", "fre", key: "Peste", inverted: "Peste, La"),
            Filed("L'Étranger", "fra", key: "Étranger", inverted: "Étranger, L'"),
            Filed("L’Étranger", "fr", key: "Étranger", inverted: "Étranger, L’"),
            Filed("l'enfant", "fr", key: "enfant", inverted: "enfant, l'"),
            Filed("L' Étranger", "fr", key: "Étranger", inverted: "Étranger, L'"),
            Filed("Un amour de Swann", "French", key: "amour de Swann", inverted: "amour de Swann, Un"),
            Filed("Une saison en enfer", "fr", key: "saison en enfer", inverted: "saison en enfer, Une"),
            Filed("Le Morte d'Arthur"),
            Filed("Le Morte d'Arthur", "en"),
            // An accent counts: À is not A.
            Filed("À la recherche du temps perdu", "fr"),
            // Spanish.
            Filed("El Aleph", "es", key: "Aleph", inverted: "Aleph, El"),
            Filed("La casa de los espíritus", "es-MX", key: "casa de los espíritus", inverted: "casa de los espíritus, La"),
            Filed("Los de abajo", "spa", key: "de abajo", inverted: "de abajo, Los"),
            Filed("La La Land"),
            // Italian.
            Filed("Il nome della rosa", "it", key: "nome della rosa", inverted: "nome della rosa, Il"),
            Filed("Gli indifferenti", "ita", key: "indifferenti", inverted: "indifferenti, Gli"),
            Filed("L'amica geniale", "it-IT", key: "amica geniale", inverted: "amica geniale, L'"),
            Filed("Un'altra vita", "it", key: "altra vita", inverted: "altra vita, Un'"),
            Filed("I promessi sposi", "it", key: "promessi sposi", inverted: "promessi sposi, I"),
            Filed("I promessi sposi"),
            // Portuguese.
            Filed("O Alquimista", "pt-BR", key: "Alquimista", inverted: "Alquimista, O"),
            Filed("Os Lusíadas", "pt", key: "Lusíadas", inverted: "Lusíadas, Os"),
            Filed("Uma Aprendizagem", "por", key: "Aprendizagem", inverted: "Aprendizagem, Uma"),
            Filed("O Alquimista"),
            // Dutch, with an article that begins with an apostrophe.
            Filed("Het Achterhuis", "nl", key: "Achterhuis", inverted: "Achterhuis, Het"),
            Filed("De ontdekking van de hemel", "nl-BE", key: "ontdekking van de hemel", inverted: "ontdekking van de hemel, De"),
            Filed("Een vlucht regenwulpen", "dut", key: "vlucht regenwulpen", inverted: "vlucht regenwulpen, Een"),
            Filed("'t Hooft", "nl", key: "Hooft", inverted: "Hooft, 't"),
            Filed("’t Hooft", "nl", key: "Hooft", inverted: "Hooft, ’t"),
            Filed("'t Hooft"),
            // Catalan, Swedish, Danish, and Norwegian.
            Filed("El quadern gris", "ca", key: "quadern gris", inverted: "quadern gris, El"),
            Filed("L'ombra del vent", "cat", key: "ombra del vent", inverted: "ombra del vent, L'"),
            Filed("Den allvarsamma leken", "sv", key: "allvarsamma leken", inverted: "allvarsamma leken, Den"),
            Filed("Ett drömspel", "swe", key: "drömspel", inverted: "drömspel, Ett"),
            Filed("Et dukkehjem", "da", key: "dukkehjem", inverted: "dukkehjem, Et"),
            Filed("Det forsømte forår", "dan", key: "forsømte forår", inverted: "forsømte forår, Det"),
            Filed("Ei natt", "nn", key: "natt", inverted: "natt, Ei"),
            Filed("Den unge Werthers lidelser", "nb-NO", key: "unge Werthers lidelser", inverted: "unge Werthers lidelser, Den"),
            // Norwegian's dialect "e" is left out.
            Filed("E for Eventyr", "no"),
            // A language TextMouth knows no articles of.
            Filed("Die Antwoord", "af"),
            Filed("The Hobbit", "zh-Hans", key: "Hobbit", inverted: "Hobbit, The"),
        ])
    }

    /// The names a book's metadata gives its language: a tag with a region
    /// or a script, an ISO 639-2 code, a name, in any case, and the first of
    /// a list; anything else is no language TextMouth knows articles of.
    func testTheLanguagesAMetadataNames() {
        let named: [(String?, ArticleLanguage?)] = [
            ("en", .english), ("EN", .english), ("en-GB", .english), ("eng", .english), ("English", .english),
            ("fr", .french), ("fr-CA", .french), ("fre", .french), ("fra", .french), ("Français", .french),
            ("de", .german), ("de_AT", .german), ("ger", .german), ("deu", .german), ("Deutsch", .german),
            ("es", .spanish), ("es-419", .spanish), ("spa", .spanish), ("Español", .spanish),
            ("it", .italian), ("ita", .italian), ("pt", .portuguese), ("pt-BR", .portuguese), ("por", .portuguese),
            ("nl", .dutch), ("dut", .dutch), ("nld", .dutch), ("ca", .catalan), ("cat", .catalan),
            ("sv", .swedish), ("swe", .swedish), ("da", .danish), ("dan", .danish),
            ("no", .norwegian), ("nb", .norwegian), ("nn-NO", .norwegian), ("nob", .norwegian),
            (" fr ", .french), ("en, fr", .english), ("fr;en", .french),
            (nil, nil), ("", nil), ("und", nil), ("zh-Hans", nil), ("ja", nil), ("xx", nil), ("-", nil),
        ]
        var mismatches: [String] = []
        for (name, expected) in named where ArticleLanguage(metadataLanguage: name) != expected {
            let found = ArticleLanguage(metadataLanguage: name).map { "\($0)" } ?? "none"
            mismatches.append("\(String(describing: name)) named \(found), not \(expected.map { "\($0)" } ?? "none")")
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Every language's articles are tried longest first, with its own and
    /// English's "the" among them, and none twice; English's "a" and "an"
    /// only where the book is in English (or a language not known, or none)
    /// or the language has them itself.
    func testEachLanguageTriesItsOwnArticlesAndTheLongestFirst() {
        for language in ArticleLanguage.allCases {
            let articles = ArticleLanguage.articles(forMetadataLanguage: Self.code(of: language))
            XCTAssertEqual(articles.map(\.count), articles.map(\.count).sorted(by: >), "\(language): \(articles)")
            XCTAssertEqual(Set(articles).count, articles.count, "\(language) repeats an article: \(articles)")
            XCTAssertTrue(articles.contains("the"), "\(language) lacks English's the: \(articles)")
            XCTAssertTrue(Set(language.articles).isSubset(of: Set(articles)), "\(language) lacks its own: \(articles)")
            // Nothing but its own and "the": "a" and "an" are English's alone.
            XCTAssertEqual(Set(articles), Set(language.articles + ["the"]), "\(language): \(articles)")
        }
        XCTAssertEqual(ArticleLanguage.articles(forMetadataLanguage: nil), ["the", "an", "a"])
        XCTAssertEqual(ArticleLanguage.articles(forMetadataLanguage: "ja"), ["the", "an", "a"])
        XCTAssertEqual(ArticleLanguage.articles(forMetadataLanguage: "en-GB"), ["the", "an", "a"])
    }

    /// English's "a" and "an" are articles in English books, in books of no
    /// known language, and where a language has them itself, and are plain
    /// words in a book of another listed language: "An die Freude" and "A
    /// ciascuno il suo" keep their first word, as do the Spanish "A sangre
    /// fría" and the French "A la recherche du temps perdu" written without
    /// its accent; "The" counts in every language's books.
    func testEnglishAAndAnAreNoArticlesInOtherLanguagesBooks() {
        check([
            Filed("An die Freude", "de"),
            Filed("A ciascuno il suo", "it"),
            Filed("A sangre fría", "es"),
            Filed("A la recherche du temps perdu", "fr"),
            Filed("An die Freude", "ger"),
            Filed("A ciascuno il suo", "Italiano"),
            // English books, and books of no language the app knows articles of.
            Filed("An die Freude", "en", key: "die Freude", inverted: "die Freude, An"),
            Filed("A Tale of Two Cities", "en", key: "Tale of Two Cities", inverted: "Tale of Two Cities, A"),
            Filed("A Tale of Two Cities", nil, key: "Tale of Two Cities", inverted: "Tale of Two Cities, A"),
            Filed("A Tale of Two Cities", "ja", key: "Tale of Two Cities", inverted: "Tale of Two Cities, A"),
            // "The" is English's in every language's books.
            Filed("The Hobbit", "fr", key: "Hobbit", inverted: "Hobbit, The"),
            Filed("The Hobbit", "de", key: "Hobbit", inverted: "Hobbit, The"),
            Filed("The Hobbit", "pt", key: "Hobbit", inverted: "Hobbit, The"),
            // Portuguese has "a" itself.
            Filed("A casa dos espíritos", "pt", key: "casa dos espíritos", inverted: "casa dos espíritos, A"),
            // The language's own articles still count.
            Filed("Die Verwandlung", "de", key: "Verwandlung", inverted: "Verwandlung, Die"),
            Filed("Le Petit Prince", "fr", key: "Petit Prince", inverted: "Petit Prince, Le"),
        ])
    }

    /// A two-letter code for each language, to name it in metadata.
    private static func code(of language: ArticleLanguage) -> String {
        switch language {
        case .english: return "en"
        case .french: return "fr"
        case .german: return "de"
        case .spanish: return "es"
        case .italian: return "it"
        case .portuguese: return "pt"
        case .dutch: return "nl"
        case .catalan: return "ca"
        case .swedish: return "sv"
        case .danish: return "da"
        case .norwegian: return "no"
        }
    }

    // MARK: - The Setting

    /// Only the third choice sorts and shows titles without their articles;
    /// the other two keep every title as written. Typing passes over
    /// articles in the second and third.
    func testWhatEachChoiceDoesWithATitle() {
        let title = "The Hobbit"
        XCTAssertEqual(LeadingArticles.partOfTitle.sortKey(of: title, language: nil), title)
        XCTAssertEqual(LeadingArticles.ignoredWhenTyping.sortKey(of: title, language: nil), title)
        XCTAssertEqual(LeadingArticles.ignoredWhenTypingAndSorting.sortKey(of: title, language: nil), "Hobbit")
        XCTAssertEqual(LeadingArticles.partOfTitle.shownTitle(title, language: nil), title)
        XCTAssertEqual(LeadingArticles.ignoredWhenTyping.shownTitle(title, language: nil), title)
        XCTAssertEqual(LeadingArticles.ignoredWhenTypingAndSorting.shownTitle(title, language: nil), "Hobbit, The")
        XCTAssertEqual(LeadingArticles.allCases.map(\.typesWithoutArticles), [false, true, true])
        XCTAssertEqual(LeadingArticles.allCases.map(\.sortsWithoutArticles), [false, false, true])
        // The default, so nothing changes until the user chooses.
        XCTAssertEqual(SettingsPolicy.leadingArticles.defaultValue, .partOfTitle)
        XCTAssertEqual(SettingsPolicy.leadingArticles.key, "leadingArticles")
        XCTAssertEqual(
            LeadingArticles.allCases.map(\.rawValue),
            ["partOfTitle", "ignoredWhenTyping", "ignoredWhenTypingAndSorting"],
            "config.json names the choices so"
        )
    }

    /// The setting's words: three short choices, each with what it does.
    func testTheSettingsWords() {
        XCTAssertEqual(LeadingArticleWording.pickerLabel, "Leading articles")
        XCTAssertEqual(
            LeadingArticles.allCases.map(LeadingArticleWording.name),
            ["Part of the Title", "Ignored When Typing", "Ignored When Typing and Sorting"]
        )
        let descriptions = LeadingArticles.allCases.map(LeadingArticleWording.description)
        XCTAssertEqual(Set(descriptions).count, 3, "two choices are described alike")
        XCTAssertTrue(descriptions[2].contains("Hobbit, The"), descriptions[2])
    }

    /// The words under the pop-up say only what is true of the choice in
    /// force. Under the first, where nothing passes over an article, they
    /// do not speak of languages whose articles are passed over; under the
    /// other two they do, and begin so ("When articles are ignored"). No
    /// choice promises that a letter goes to a title that only the first
    /// of its letter's titles would be.
    func testTheCaptionSaysOnlyWhatIsTrueOfTheChoiceInForce() {
        let first = LeadingArticleWording.caption(for: .partOfTitle)
        XCTAssertEqual(first, LeadingArticleWording.description(.partOfTitle))
        XCTAssertFalse(first.contains("passes over"), first)
        XCTAssertFalse(first.contains("French"), first)
        for choice in [LeadingArticles.ignoredWhenTyping, .ignoredWhenTypingAndSorting] {
            let caption = LeadingArticleWording.caption(for: choice)
            XCTAssertTrue(caption.hasPrefix(LeadingArticleWording.description(choice)), caption)
            XCTAssertTrue(caption.hasSuffix(LeadingArticleWording.languagesNote), caption)
        }
        XCTAssertTrue(LeadingArticleWording.languagesNote.hasPrefix("When articles are ignored"))
        // Typing H goes to the first H, which may not be The Hobbit: the
        // sentences say it is found among the H's, or counts as an H.
        for choice in LeadingArticles.allCases {
            XCTAssertFalse(LeadingArticleWording.description(choice).contains("Typing H goes to"), "\(choice)")
        }
        XCTAssertTrue(LeadingArticleWording.description(.ignoredWhenTypingAndSorting).contains("among the H's"))
    }

    /// The choice is stored by its name, and anything the store holds that
    /// names no choice reads as the default.
    func testTheChoiceIsStoredByItsName() throws {
        let store = makeSandboxedPreferences("leading-articles")
        XCTAssertEqual(LeadingArticles.preference.read(from: store), .partOfTitle)
        LeadingArticles.preference.write(.ignoredWhenTypingAndSorting, to: store)
        XCTAssertEqual(store.string(forKey: "leadingArticles"), "ignoredWhenTypingAndSorting")
        XCTAssertEqual(LeadingArticles.preference.read(from: store), .ignoredWhenTypingAndSorting)
        store.set("IgnoredWhenTyping", forKey: "leadingArticles")
        XCTAssertEqual(LeadingArticles.preference.read(from: store), .partOfTitle)
        store.set(7, forKey: "leadingArticles")
        XCTAssertEqual(LeadingArticles.preference.read(from: store), .partOfTitle)
    }
}
