import Foundation

/// How closely a transcript follows the text that was read aloud (FR05): the
/// recognizer's words aligned with the known text word by word, the
/// differences sorted into the kinds of mistake a recognizer makes, how the
/// recognizer's confidence bears on them, and which corrections would have
/// been right in every place they apply.
///
/// TextMouth's transcript cleanup rules (`TranscriptCleanupRuleSet`) were
/// derived this way from speech whose text was known
/// (TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md), and the opt-in measurement
/// test measures again. Words are compared as the edit alignment compares
/// them (`TranscriptEditAlignment.key(of:)`): in lower case, without the
/// punctuation at either end, and here with every apostrophe read as one,
/// so a book's "I’m" matches the recognizer's "I'm".
enum TranscriptAccuracy {
    // MARK: - Words

    /// One word of the known text, or of a transcript.
    struct Word: Equatable, Sendable {
        /// The word as written, with the punctuation attached to it.
        let text: String
        /// The word as compared (`key(of:)`).
        let key: String
        /// Whether the word begins a sentence: the first of its text or
        /// paragraph, or the first after a word ending one.
        let startsSentence: Bool
        /// How sure the recognizer was of a word it heard, from 0 to 1; nil
        /// for the known text's words, and for a word heard without one.
        var confidence: Double? = nil
    }

    /// What `word` is compared by: lower case, without the punctuation and
    /// symbols at either end (`TranscriptEditAlignment.key(of:)`), with every
    /// apostrophe read as a straight one.
    static func key(of word: String) -> String {
        TranscriptEditAlignment.key(of: foldingApostrophes(word))
    }

    /// `text` with each curly or modifier apostrophe written straight.
    static func foldingApostrophes(_ text: String) -> String {
        guard text.contains(where: { curlyApostrophes.contains($0) }) else { return text }
        return String(text.map { curlyApostrophes.contains($0) ? "'" : $0 })
    }

    /// The apostrophes books and recognizers write in place of a straight one.
    private static let curlyApostrophes: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    /// The words of `text`, the known text read aloud, in order: each run of
    /// characters between white space or dashes (`runs(of:)`). A run of
    /// nothing but punctuation, which nobody reads aloud, is left out. A word
    /// begins a sentence when it is the first of the text or of a line, opens
    /// a quotation, or follows a word ending in ".", "!" or "?" that is not a
    /// title such as "Mr.".
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var startsSentence = true
        for line in text.split(whereSeparator: \.isNewline) {
            startsSentence = true
            for written in runs(of: line) {
                let key = key(of: written)
                guard key.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                // Dialogue opens with a capital wherever its quotation
                // begins: “How can you be so tiresome?”
                let opensQuotation = written.first.map { openingQuotes.contains($0) } ?? false
                words.append(Word(text: written, key: key, startsSentence: startsSentence || opensQuotation))
                startsSentence = endsSentence(written, key: key)
            }
        }
        return words
    }

    /// The marks that open a quotation.
    private static let openingQuotes: Set<Character> = ["\"", "\u{201C}", "\u{2018}"]

    /// The words heard in `sentences`, a transcript's, in order: each timed
    /// word, as the sentence's text spells it, with its confidence, or, in a
    /// sentence whose words were not timed, each run between its spaces.
    /// Each sentence's first word begins a sentence, as a word after one
    /// ending a sentence inside it does.
    static func words(heardIn sentences: [TranscriptSentence]) -> [Word] {
        var heard: [Word] = []
        for sentence in sentences {
            let text = sentence.text as NSString
            // The timed words, as the sentence's text spells them, or its
            // runs between spaces when none were timed.
            let pieces: [(text: String, confidence: Double?)]
            if sentence.words.isEmpty {
                pieces = sentence.text.split(separator: " ").map { (String($0), nil) }
            } else {
                pieces = sentence.words.compactMap { word in
                    guard word.characterOffset >= 0, word.characterOffset + word.characterCount <= text.length else {
                        return nil
                    }
                    let range = NSRange(location: word.characterOffset, length: word.characterCount)
                    return (text.substring(with: range), word.confidence)
                }
            }
            var startsSentence = true
            for piece in pieces {
                for written in runs(of: piece.text) {
                    let key = key(of: written)
                    guard key.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                    heard.append(Word(text: written, key: key, startsSentence: startsSentence, confidence: piece.confidence))
                    startsSentence = endsSentence(written, key: key)
                }
            }
        }
        return heard
    }

    /// The runs of `text` between white space and dashes, each a word as
    /// written: an em or en dash, or two hyphens standing for one, joins no
    /// words, as in "can;—but" or "bad,--belongs".
    private static func runs(of text: some StringProtocol) -> [String] {
        text.replacingOccurrences(of: "--", with: "\u{2014}")
            .split(whereSeparator: { $0.isWhitespace || wordBreakingDashes.contains($0) })
            .map(String.init)
    }

    /// The dashes that stand between words rather than inside one.
    private static let wordBreakingDashes: Set<Character> = ["\u{2014}", "\u{2013}"]

    /// Whether `written`, a word whose key is `key`, ends a sentence: it
    /// ends in ".", "!" or "?", before any closing quotes or brackets, and
    /// is not a title that a name follows.
    private static func endsSentence(_ written: String, key: String) -> Bool {
        let closing: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]"]
        guard let last = written.reversed().first(where: { !closing.contains($0) }), ".!?".contains(last) else {
            return false
        }
        return !(last == "." && titles.contains(key))
    }

    /// Titles written with a full stop before a name, which ends no
    /// sentence: "Mr. Bennet".
    private static let titles: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "prof", "rev", "sr", "jr", "messrs", "capt", "col", "gen", "lt", "sgt", "hon",
    ]

    // MARK: - Aligning

    /// A word heard matched with the word of the known text it stands for.
    struct Match: Equatable, Sendable {
        /// The heard word's index.
        let heard: Int
        /// The known text's word's index.
        let written: Int
    }

    /// A stretch where the transcript and the known text differ, between two
    /// matched words: words heard in place of words written (a
    /// substitution), words written but not heard (a deletion), or words
    /// heard but not written (an insertion).
    struct Difference: Equatable, Sendable {
        /// The heard words, by index.
        let heard: Range<Int>
        /// The written words, by index.
        let written: Range<Int>

        /// What kind of difference it is.
        enum Kind: String, Sendable {
            case substitution, deletion, insertion
        }

        /// Its kind: a substitution when both sides hold words.
        var kind: Kind {
            if heard.isEmpty { return .deletion }
            return written.isEmpty ? .insertion : .substitution
        }

        /// The word errors it counts for: each written word heard as another
        /// is a substitution, and each word over on either side a deletion
        /// or an insertion.
        var errorCount: Int {
            max(heard.count, written.count)
        }
    }

    /// The known text's words and a transcript's, aligned: the words that
    /// match, and the differences between them, in order.
    struct Alignment: Sendable {
        /// The words heard.
        let heard: [Word]
        /// The known text's words.
        let written: [Word]
        /// The heard words matched with written ones, in order in both.
        let matches: [Match]
        /// The stretches between matches, in order.
        let differences: [Difference]

        /// Written words heard as other words.
        var substitutions: Int {
            differences.reduce(0) { $0 + min($1.heard.count, $1.written.count) }
        }

        /// Written words not heard.
        var deletions: Int {
            differences.reduce(0) { $0 + max(0, $1.written.count - $1.heard.count) }
        }

        /// Words heard that were not written.
        var insertions: Int {
            differences.reduce(0) { $0 + max(0, $1.heard.count - $1.written.count) }
        }

        /// Every word error: substitutions, deletions, and insertions.
        var errorCount: Int {
            differences.reduce(0) { $0 + $1.errorCount }
        }

        /// The word error rate: word errors for each word of the known text,
        /// from 0 (none) upwards; 0 for a text of no words.
        var wordErrorRate: Double {
            written.isEmpty ? 0 : Double(errorCount) / Double(written.count)
        }

        /// The heard words' keys in `difference`, joined by spaces.
        func heardKeys(of difference: Difference) -> String {
            difference.heard.map { heard[$0].key }.joined(separator: " ")
        }

        /// The written words' keys in `difference`, joined by spaces.
        func writtenKeys(of difference: Difference) -> String {
            difference.written.map { written[$0].key }.joined(separator: " ")
        }
    }

    /// `heard`, a transcript's words, aligned with `written`, the known
    /// text's: the most words matched by key, in order, as the edit
    /// alignment matches them (`TranscriptEditAlignment.matches`), and the
    /// stretches between them as differences.
    static func align(heard: [Word], written: [Word]) -> Alignment {
        let pairs = TranscriptEditAlignment.matches(
            written.map(\.key), 0..<written.count,
            heard.map(\.key), 0..<heard.count
        )
        var matches: [Match] = []
        var differences: [Difference] = []
        var nextHeard = 0
        var nextWritten = 0
        for (writtenIndex, heardIndex) in pairs + [(written.count, heard.count)] {
            if nextHeard < heardIndex || nextWritten < writtenIndex {
                differences.append(Difference(heard: nextHeard..<heardIndex, written: nextWritten..<writtenIndex))
            }
            if writtenIndex < written.count {
                matches.append(Match(heard: heardIndex, written: writtenIndex))
            }
            nextHeard = heardIndex + 1
            nextWritten = writtenIndex + 1
        }
        return Alignment(heard: heard, written: written, matches: matches, differences: differences)
    }

    // MARK: - Kinds of Mistake

    /// The kind of mistake a difference is, as the measurement tabulates
    /// them; a difference that could be several is the first that fits, in
    /// the order listed.
    enum ErrorClass: String, CaseIterable, Sendable {
        /// More than `passageLength` words on a side: a passage the narration
        /// skipped or added, such as a credit or an image's description,
        /// rather than a word misheard.
        case passage
        /// A page or chapter the narrator announced and the text only
        /// numbered, or the other way round: "page" heard before a page's
        /// number.
        case announcement
        /// A number, in figures or in words, or a roman numeral.
        case number
        /// A name: a written word with a capital letter that begins no
        /// sentence.
        case name
        /// The same letters joined or split differently: "to-day" heard as
        /// "today", "rabbit-hole" as "rabbit hole".
        case hyphenation
        /// The same word in American and British spelling: "honor" heard for
        /// "honour", "practiced" for "practised".
        case spelling
        /// A word of older English: "shew", "thou", "whilst".
        case archaic
        /// A word heard as another that sounds the same: "there" for
        /// "their".
        case homophone
        /// Only short, common words: "were" for "are", "a" left out.
        case smallWords
        /// Any other word heard as another.
        case other

        /// The class's name in a table.
        var title: String {
            switch self {
            case .passage: return "Passages not in both"
            case .announcement: return "Pages and chapters announced"
            case .number: return "Numbers"
            case .name: return "Proper names"
            case .hyphenation: return "Hyphenation and compounds"
            case .spelling: return "American and British spelling"
            case .archaic: return "Archaic words"
            case .homophone: return "Homophones"
            case .smallWords: return "Small words"
            case .other: return "Other words"
            }
        }

        /// Whether a difference of this kind can be a convention of the book
        /// or the recognizer rather than a word misheard: how numbers,
        /// pages, compounds, and spellings are written. A correction of it is
        /// right only for books that follow the convention.
        var isConvention: Bool {
            [.announcement, .number, .hyphenation, .spelling, .archaic].contains(self)
        }
    }

    /// The most words a side of a difference holds before it counts as a
    /// passage rather than a mistake.
    static let passageLength = 6

    /// The kind of mistake `difference`, of `alignment`, is.
    static func errorClass(of difference: Difference, in alignment: Alignment) -> ErrorClass {
        let heard = difference.heard.map { alignment.heard[$0] }
        let written = difference.written.map { alignment.written[$0] }
        if max(heard.count, written.count) > passageLength {
            return .passage
        }
        let words = heard + written
        if words.contains(where: { announcementWords.contains($0.key) }),
           words.allSatisfy({ announcementWords.contains($0.key) || isNumber($0.key) }) {
            return .announcement
        }
        if words.contains(where: { isNumber($0.key) }) {
            return .number
        }
        if written.contains(where: isName) || heard.contains(where: isName) {
            return .name
        }
        // Hyphens and spaces set aside; apostrophes kept, so "its" for
        // "it's" stays a homophone.
        let joined = { (words: [Word]) in words.map(\.key).joined().filter { $0 != "-" } }
        if !heard.isEmpty, !written.isEmpty, joined(heard) == joined(written) {
            return .hyphenation
        }
        if !heard.isEmpty, !written.isEmpty, !words.allSatisfy({ smallWords.contains($0.key) }),
           areSpellingVariants(joined(heard), joined(written)) {
            return .spelling
        }
        if words.contains(where: { archaicWords.contains($0.key) }) {
            return .archaic
        }
        if heard.count == 1, written.count == 1, areHomophones(heard[0].key, written[0].key) {
            return .homophone
        }
        if (heard + written).allSatisfy({ smallWords.contains($0.key) }) {
            return .smallWords
        }
        return .other
    }

    /// Whether `key` is a number: written with a figure, a number word or
    /// an ordinal, or a roman numeral other than "i".
    static func isNumber(_ key: String) -> Bool {
        key.contains(where: \.isNumber) || numberWords.contains(key) || romanNumerals.contains(key)
    }

    /// Whether `word` reads as a name: a capital letter begins it, it
    /// begins no sentence, and it is not "I" or one of its contractions.
    static func isName(_ word: Word) -> Bool {
        guard !word.startsSentence, word.key != "i", !word.key.hasPrefix("i'") else { return false }
        let letters = word.text.drop(while: { !$0.isLetter })
        return letters.first?.isUppercase == true
    }

    /// Whether `first` and `second`, two keys, sound the same: both belong
    /// to one set of homophones.
    static func areHomophones(_ first: String, _ second: String) -> Bool {
        guard first != second else { return false }
        return homophoneSets.contains { $0.contains(first) && $0.contains(second) }
    }

    /// Whether `first` and `second`, two different keys of more than three
    /// letters, are one word in American and British spelling: the same once
    /// both are written the American way (`americanSpelling(of:)`).
    static func areSpellingVariants(_ first: String, _ second: String) -> Bool {
        guard first != second, first.count > 3, second.count > 3 else { return false }
        return americanSpelling(of: first) == americanSpelling(of: second)
    }

    /// `key` with the British spellings `britishSpellings` lists written the
    /// American way. Applied to both words of a pair, so a change that
    /// touches a word with no British spelling touches both alike.
    static func americanSpelling(of key: String) -> String {
        britishSpellings.reduce(key) { $0.replacingOccurrences(of: $1.british, with: $1.american) }
    }

    /// British spellings and their American ones, in the order they are
    /// replaced: whole stems first ("practised" is "practiced", not
    /// "practized"), then endings, the longer before the shorter ones
    /// within them.
    static let britishSpellings: [(british: String, american: String)] = [
        ("practis", "practic"), ("despatch", "dispatch"), ("mould", "mold"), ("grey", "gray"),
        ("programme", "program"), ("cheque", "check"), ("judgement", "judgment"), ("ageing", "aging"),
        ("learnt", "learned"), ("burnt", "burned"), ("spelt", "spelled"), ("dreamt", "dreamed"),
        ("spoilt", "spoiled"), ("kerb", "curb"), ("tyre", "tire"), ("pyjama", "pajama"), ("plough", "plow"),
        ("sceptic", "skeptic"), ("aluminium", "aluminum"), ("storey", "story"),
        ("isation", "ization"), ("ising", "izing"), ("ised", "ized"), ("ise", "ize"), ("yse", "yze"),
        ("our", "or"), ("tre", "ter"), ("ence", "ense"), ("ll", "l"), ("ogue", "og"), ("ae", "e"), ("oe", "e"),
    ]

    /// The words a narrator says to announce a page or a chapter.
    static let announcementWords: Set<String> = [
        "page", "pages", "p", "pp", "chapter", "chapters", "part", "section", "contents",
    ]

    /// Number words and ordinals.
    static let numberWords: Set<String> = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "eleventh",
        "twelfth", "thirteenth", "fourteenth", "fifteenth", "sixteenth", "seventeenth", "eighteenth",
        "nineteenth", "twentieth", "thirtieth", "fortieth", "fiftieth", "hundredth", "thousandth", "half",
        "dozen", "once", "twice",
    ]

    /// Roman numerals as chapters are numbered, without "i", which is a
    /// word too.
    static let romanNumerals: Set<String> = [
        "ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii", "xiii", "xiv", "xv", "xvi", "xvii", "xviii",
        "xix", "xx", "xxi", "xxii", "xxiii", "xxiv", "xxv",
    ]

    /// Words of older English that a modern recognizer writes otherwise, or
    /// not at all.
    static let archaicWords: Set<String> = [
        "thee", "thou", "thy", "thine", "ye", "hath", "doth", "dost", "hast", "art", "wert", "wast", "shalt",
        "wilt", "canst", "couldst", "wouldst", "shouldst", "mayst", "shew", "shewn", "shewed", "shewing",
        "chuse", "chusing", "connexion", "connexions", "ere", "whilst", "amongst", "amidst", "betwixt", "nay",
        "aye", "oft", "hither", "thither", "whither", "hence", "thence", "whence", "wherefore", "methinks",
        "perchance", "mayhap", "forsooth", "'tis", "'twas", "'twere", "o'er", "e'en", "ne'er", "e'er", "spake",
        "sate", "yon", "yonder", "verily", "unto", "anon", "albeit", "lest", "thereof", "whereof",
        "wherein", "whereupon", "hitherto", "to-day", "to-morrow", "to-night", "any-thing", "every-thing",
        "some-thing", "every-body", "any-body", "some-body", "no-body", "ancle", "skurried",
    ]

    /// Sets of words that sound alike.
    static let homophoneSets: [Set<String>] = [
        ["their", "there", "they're"], ["to", "too", "two"], ["its", "it's"], ["your", "you're"],
        ["whose", "who's"], ["know", "no"], ["knew", "new"], ["right", "write", "rite"], ["here", "hear"],
        ["where", "wear", "ware"], ["weather", "whether"], ["piece", "peace"], ["by", "buy", "bye"],
        ["for", "four", "fore"], ["one", "won"], ["red", "read"], ["sea", "see"], ["son", "sun"],
        ["tail", "tale"], ["wait", "weight"], ["week", "weak"], ["heard", "herd"], ["hole", "whole"],
        ["hour", "our"], ["made", "maid"], ["meet", "meat"], ["passed", "past"], ["plain", "plane"],
        ["principal", "principle"], ["rain", "reign", "rein"], ["road", "rode"], ["sail", "sale"],
        ["scene", "seen"], ["sole", "soul"], ["stair", "stare"], ["steal", "steel"], ["threw", "through"],
        ["waist", "waste"], ["wood", "would"], ["allowed", "aloud"], ["bare", "bear"], ["berry", "bury"],
        ["board", "bored"], ["break", "brake"], ["cell", "sell"], ["cent", "scent", "sent"], ["dear", "deer"],
        ["die", "dye"], ["fair", "fare"], ["flour", "flower"], ["groan", "grown"], ["hair", "hare"],
        ["heal", "heel"], ["him", "hymn"], ["idle", "idol"], ["knight", "night"], ["knot", "not"],
        ["lead", "led"], ["mail", "male"], ["morning", "mourning"], ["pair", "pear", "pare"], ["pause", "paws"],
        ["pray", "prey"], ["rap", "wrap"], ["ring", "wring"], ["role", "roll"], ["root", "route"],
        ["sew", "so", "sow"], ["some", "sum"], ["stationary", "stationery"], ["tide", "tied"],
        ["vain", "vein", "vane"], ["wail", "whale"], ["way", "weigh"], ["which", "witch"], ["wine", "whine"],
        ["ate", "eight"], ["ball", "bawl"], ["be", "bee"], ["blew", "blue"], ["vale", "veil"],
        ["cheap", "cheep"], ["council", "counsel"], ["dew", "due", "do"], ["ewe", "you"], ["flew", "flu"],
        ["guessed", "guest"], ["hall", "haul"], ["higher", "hire"], ["in", "inn"], ["isle", "aisle", "i'll"],
        ["kernel", "colonel"], ["lessen", "lesson"], ["loan", "lone"], ["mind", "mined"], ["miner", "minor"],
        ["missed", "mist"], ["oar", "or", "ore"], ["one's", "ones"], ["pail", "pale"], ["pane", "pain"],
        ["peak", "peek", "pique"], ["plum", "plumb"], ["poll", "pole"], ["profit", "prophet"], ["raise", "rays"],
        ["real", "reel"], ["seam", "seem"], ["sight", "site", "cite"], ["soar", "sore"], ["suite", "sweet"],
        ["tea", "tee"], ["than", "then"], ["throne", "thrown"], ["toe", "tow"], ["vary", "very"],
        ["wade", "weighed"], ["warn", "worn"], ["we'd", "weed"], ["we'll", "wheel"], ["yoke", "yolk"],
    ]

    /// Short, common words: the articles, pronouns, prepositions,
    /// conjunctions, and auxiliary verbs a recognizer drops, adds, or swaps
    /// most.
    static let smallWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "of", "to", "in", "on", "at", "by", "for", "with", "from",
        "as", "into", "upon", "up", "out", "off", "over", "is", "are", "was", "were", "be", "been", "being",
        "am", "it", "its", "it's", "he", "she", "they", "we", "you", "i", "me", "him", "her", "them", "us", "my",
        "his", "their", "our", "your", "this", "that", "these", "those", "there", "here", "so", "not", "no",
        "do", "did", "does", "had", "has", "have", "will", "would", "shall", "should", "can", "could", "may",
        "might", "must", "if", "then", "than", "when", "what", "who", "whom", "which", "all", "any", "some",
        "oh", "o", "ah", "well", "now", "just", "very", "too", "i'm", "i've", "i'll", "i'd", "don't", "didn't",
        "can't", "won't", "isn't", "wasn't", "that's", "there's", "he's", "she's", "you're", "we're", "they're",
    ]

    // MARK: - Words Matched, Written Differently

    /// How the matched words of `alignment` differ in what a key sets aside:
    /// in their letters' case alone, and in the punctuation that ends them
    /// (".", ",", ";", ":", "!", "?"), which is where the recognizer's
    /// sentences and the text's part.
    struct SurfaceDifferences: Equatable, Sendable {
        /// Matched words.
        var matched = 0
        /// Matched words whose letters differ in case alone.
        var casing = 0
        /// Matched words whose ending punctuation differs.
        var punctuation = 0
    }

    /// The surface differences of `alignment`'s matched words.
    static func surfaceDifferences(in alignment: Alignment) -> SurfaceDifferences {
        var found = SurfaceDifferences()
        for match in alignment.matches {
            let heard = alignment.heard[match.heard].text
            let written = alignment.written[match.written].text
            found.matched += 1
            if letters(of: heard) != letters(of: written) {
                found.casing += 1
            }
            if endingPunctuation(of: heard) != endingPunctuation(of: written) {
                found.punctuation += 1
            }
        }
        return found
    }

    /// The letters and figures of `text`, in order, as written.
    private static func letters(of text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber })
    }

    /// The marks that end `text`, among ".", ",", ";", ":", "!" and "?",
    /// with any quotes or brackets around them set aside.
    private static func endingPunctuation(of text: String) -> String {
        let marks: Set<Character> = [".", ",", ";", ":", "!", "?"]
        let ignored: Set<Character> = ["\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}", ")", "]", "("]
        var found = ""
        for character in text.reversed() {
            if marks.contains(character) {
                found.insert(character, at: found.startIndex)
            } else if !ignored.contains(character) {
                break
            }
        }
        return found
    }

    // MARK: - Confidence

    /// A range of the recognizer's confidence, with how many words heard
    /// fell in it and how many of those were wrong.
    struct ConfidenceBand: Equatable, Sendable {
        /// The band's least confidence.
        let from: Double
        /// The confidence the band runs up to, not included, but for the
        /// last band, which includes 1.
        let upTo: Double
        /// Words heard with a confidence in the band.
        var words = 0
        /// Of those, words in a difference: not the word written.
        var errors = 0

        /// The share of the band's words that were wrong, or 0 for none.
        var errorRate: Double {
            words == 0 ? 0 : Double(errors) / Double(words)
        }
    }

    /// The bounds of the confidence bands tabulated.
    static let confidenceBounds: [Double] = [0, 0.5, 0.7, 0.9, 0.95, 1]

    /// Bands of the recognizer's confidence, for `confidenceBounds`, each
    /// counting none.
    static func emptyConfidenceBands() -> [ConfidenceBand] {
        zip(confidenceBounds, confidenceBounds.dropFirst()).map { ConfidenceBand(from: $0, upTo: $1) }
    }

    /// `bands` with the heard words of `alignment` added: each word with a
    /// confidence, in the band it falls in, wrong when it lies in a
    /// difference.
    static func adding(_ alignment: Alignment, to bands: [ConfidenceBand]) -> [ConfidenceBand] {
        var bands = bands
        var wrong = Set<Int>()
        for difference in alignment.differences {
            wrong.formUnion(difference.heard)
        }
        for (index, word) in alignment.heard.enumerated() {
            guard let confidence = word.confidence,
                  let band = bands.lastIndex(where: { confidence >= $0.from }) else { continue }
            bands[band].words += 1
            if wrong.contains(index) {
                bands[band].errors += 1
            }
        }
        return bands
    }

    // MARK: - Tallies

    /// A difference as tallied: the keys heard and the keys written, each
    /// joined by spaces, "" for none.
    struct Pair: Hashable, Sendable {
        /// What was heard.
        let heard: String
        /// What was written.
        let written: String
    }

    /// The measurements of one or more transcripts, added up.
    struct Tally: Sendable {
        /// Words of the known texts.
        var writtenWords = 0
        /// Words heard.
        var heardWords = 0
        /// Written words heard as others.
        var substitutions = 0
        /// Written words not heard.
        var deletions = 0
        /// Words heard but not written.
        var insertions = 0
        /// Word errors, by the kind of mistake they belong to.
        var errorsByClass: [ErrorClass: Int] = [:]
        /// Differences, each counted once, by kind of mistake.
        var differencesByClass: [ErrorClass: Int] = [:]
        /// How often each difference shorter than a passage was found.
        var pairs: [Pair: Int] = [:]
        /// Each tallied pair's kind of mistake, as first found.
        var pairClasses: [Pair: ErrorClass] = [:]
        /// The matched words' surface differences.
        var surface = SurfaceDifferences()
        /// The heard words by the recognizer's confidence.
        var confidence = TranscriptAccuracy.emptyConfidenceBands()

        /// Every word error.
        var errors: Int {
            substitutions + deletions + insertions
        }

        /// The word error rate over every text added.
        var wordErrorRate: Double {
            writtenWords == 0 ? 0 : Double(errors) / Double(writtenWords)
        }

        /// The word error rate leaving out the passages not in both, which
        /// are not words misheard.
        var wordErrorRateWithoutPassages: Double {
            let passage = errorsByClass[.passage] ?? 0
            return writtenWords == 0 ? 0 : Double(errors - passage) / Double(writtenWords)
        }

        /// Adds `alignment`.
        mutating func add(_ alignment: Alignment) {
            writtenWords += alignment.written.count
            heardWords += alignment.heard.count
            substitutions += alignment.substitutions
            deletions += alignment.deletions
            insertions += alignment.insertions
            for difference in alignment.differences {
                let errorClass = TranscriptAccuracy.errorClass(of: difference, in: alignment)
                errorsByClass[errorClass, default: 0] += difference.errorCount
                differencesByClass[errorClass, default: 0] += 1
                guard errorClass != .passage else { continue }
                let pair = Pair(heard: alignment.heardKeys(of: difference), written: alignment.writtenKeys(of: difference))
                pairs[pair, default: 0] += 1
                if pairClasses[pair] == nil {
                    pairClasses[pair] = errorClass
                }
            }
            let found = TranscriptAccuracy.surfaceDifferences(in: alignment)
            surface.matched += found.matched
            surface.casing += found.casing
            surface.punctuation += found.punctuation
            confidence = TranscriptAccuracy.adding(alignment, to: confidence)
        }

        /// The `limit` pairs of `kind` found most often, the most frequent
        /// first, ties in order of what was heard, then what was written.
        func mostFrequent(_ kind: Difference.Kind, limit: Int) -> [(pair: Pair, count: Int)] {
            pairs.filter { pair, _ in
                switch kind {
                case .substitution: return !pair.heard.isEmpty && !pair.written.isEmpty
                case .deletion: return pair.heard.isEmpty
                case .insertion: return pair.written.isEmpty
                }
            }
            .map { (pair: $0.key, count: $0.value) }
            .sortedStably { ($1.count, $0.pair.heard, $0.pair.written) < ($0.count, $1.pair.heard, $1.pair.written) }
            .prefix(limit)
            .map { $0 }
        }
    }

    // MARK: - Corrections That Were Always Right

    /// One transcript measured against its known text, as the corrections
    /// it suggests are counted: its source's name, a recording or a voice
    /// reading a text, and the name of the known text, which two voices
    /// reading one text share.
    struct Measurement: Sendable {
        /// The recording's name.
        let source: String
        /// The known text's name.
        let text: String
        /// The transcript aligned with the text.
        let alignment: Alignment
    }

    /// A place in a known text: the text's name, and a word's index in it.
    struct Place: Hashable, Sendable {
        /// The text's name.
        let text: String
        /// The word's index.
        let word: Int
    }

    /// A correction the measurements suggest: writing `replacement` wherever
    /// `pattern` was heard, as whole words, and how that would have fared in
    /// every place the pattern was heard.
    struct RuleCandidate: Equatable, Sendable {
        /// The words heard, as keys joined by spaces.
        let pattern: String
        /// The words written in their place, as keys joined by spaces.
        let replacement: String
        /// The kind of mistake it corrects, as first found.
        let errorClass: ErrorClass
        /// Times the pattern was heard where the correction is exactly what
        /// was written, in every recording.
        var fixes = 0
        /// The places of the known texts those were, each once, however many
        /// voices read it.
        var places: Set<Place> = []
        /// Times the pattern was heard where the correction would not have
        /// been right: the words heard were right there, or something else
        /// was written.
        var conflicts = 0
        /// The recordings, by name, the correction was right in.
        var sources: Set<String> = []

        /// Whether the correction was right in every place it would apply.
        var wasAlwaysRight: Bool {
            conflicts == 0 && fixes > 0
        }

        /// How many places of the known texts the correction was right in:
        /// the evidence a rule records.
        var evidence: Int {
            places.count
        }
    }

    /// The corrections `measured` suggest: every substitution of at most
    /// `maximumWords` words a side that is not a passage, an announcement, a
    /// number, or a name, counted over the measurements (`tallied`). The
    /// candidates come with the most evidence first.
    static func ruleCandidates(_ measured: [Measurement], maximumWords: Int = 3) -> [RuleCandidate] {
        var found: [Pair: RuleCandidate] = [:]
        for measurement in measured {
            let alignment = measurement.alignment
            for difference in alignment.differences where difference.kind == .substitution
                && difference.heard.count <= maximumWords && difference.written.count <= maximumWords {
                let errorClass = errorClass(of: difference, in: alignment)
                guard ![.passage, .announcement, .number, .name].contains(errorClass) else { continue }
                let pair = Pair(heard: alignment.heardKeys(of: difference), written: alignment.writtenKeys(of: difference))
                if found[pair] == nil {
                    found[pair] = RuleCandidate(pattern: pair.heard, replacement: pair.written, errorClass: errorClass)
                }
            }
        }
        return tallied(Array(found.values), over: measured).sortedStably {
            ($1.evidence, $1.fixes, $0.conflicts, $0.pattern, $0.replacement)
                < ($0.evidence, $0.fixes, $1.conflicts, $1.pattern, $1.replacement)
        }
    }

    /// `candidates` counted afresh over `measured`, in their order: every
    /// time a candidate's pattern was heard there, as whole words within one
    /// sentence, is a fix when the pattern's words are exactly the words
    /// heard in one difference whose written words are the replacement and
    /// hold no name or number, and a conflict otherwise. Counting the
    /// corrections some texts suggest over another text shows how they would
    /// fare there.
    static func tallied(_ candidates: [RuleCandidate], over measured: [Measurement]) -> [RuleCandidate] {
        var counted = candidates.map { RuleCandidate(pattern: $0.pattern, replacement: $0.replacement, errorClass: $0.errorClass) }
        let patterns = counted.map { $0.pattern.split(separator: " ").map(String.init) }
        for measurement in measured {
            let alignment = measurement.alignment
            // The differences by where their heard words begin, and the
            // places each key was heard, so each candidate looks only where
            // its first word was.
            let differences = Dictionary(
                alignment.differences.filter { !$0.heard.isEmpty }.map { ($0.heard.lowerBound, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var heardAt: [String: [Int]] = [:]
            for (index, word) in alignment.heard.enumerated() {
                heardAt[word.key, default: []].append(index)
            }
            for (number, keys) in patterns.enumerated() {
                guard let first = keys.first, let starts = heardAt[first] else { continue }
                for start in starts {
                    let end = start + keys.count
                    guard end <= alignment.heard.count,
                          zip(keys, alignment.heard[start..<end]).allSatisfy({ $0 == $1.key }),
                          !alignment.heard[(start + 1)..<end].contains(where: \.startsSentence) else { continue }
                    if let difference = differences[start], difference.heard == start..<end,
                       alignment.writtenKeys(of: difference) == counted[number].replacement,
                       !isNameOrNumber(difference, in: alignment) {
                        counted[number].fixes += 1
                        counted[number].places.insert(Place(text: measurement.text, word: difference.written.lowerBound))
                        counted[number].sources.insert(measurement.source)
                    } else {
                        counted[number].conflicts += 1
                    }
                }
            }
        }
        return counted
    }

    /// The candidates fit to be TextMouth's own rules, conservatively: right
    /// every time their pattern was heard, in at least `minimumPlaces`
    /// places of the known texts; correcting words misheard rather than a
    /// passage, a name, or a convention only some books follow (numbers,
    /// announcements, compounds, spelling, older English); and with a
    /// pattern holding a word that is no English word, as `isWord` judges,
    /// since a pattern of English words is right wherever it was meant.
    static func conservativeRules(
        _ candidates: [RuleCandidate],
        minimumPlaces: Int = 2,
        isWord: (String) -> Bool
    ) -> [RuleCandidate] {
        candidates.filter { candidate in
            candidate.wasAlwaysRight
                && candidate.evidence >= minimumPlaces
                && ![.passage, .name].contains(candidate.errorClass)
                && !candidate.errorClass.isConvention
                && !candidate.pattern.split(separator: " ").allSatisfy { isWord(String($0)) }
        }
    }

    /// Whether `difference` holds a name or a number, heard or written.
    private static func isNameOrNumber(_ difference: Difference, in alignment: Alignment) -> Bool {
        let words = difference.heard.map { alignment.heard[$0] } + difference.written.map { alignment.written[$0] }
        return words.contains { isNumber($0.key) || isName($0) }
    }
}
