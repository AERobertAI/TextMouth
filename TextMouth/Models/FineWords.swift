import Foundation

/// The words TextMouth finds a saved place by when a book's text is read
/// anew (T06): fine words. Every way of finding a place again reads words
/// this one way, the saved-words search (`TextAnchorFinder`) and the diff
/// of an old text with a new one alike, so the rule lives here and nowhere
/// else.
///
/// A fine word is a run of letters or digits. It ends at anything that is
/// neither (a space, punctuation, a symbol, a combining mark), where
/// letters meet digits, and where a small letter meets a capital, and it
/// is compared in lower case. So text an older extraction ran together
/// reads as the same words as the text a newer one spaces out: "…of
/// TearsCHAPTER III.A Caucus-Race" and "…of Tears CHAPTER III. A
/// Caucus-Race" are both "of", "tears", "chapter", "iii", "a", "caucus",
/// "race". The addendum measured this rule (TEXT-ANCHORS-ADDENDUM-2026-10-10.md,
/// sections 2 and 9): with words split this way, the saved words alone put
/// 2 of 57,472 places of the real extraction changes on wrong words, against
/// 9 with words split only at spaces.
///
/// These words serve only to find places again. Speech, search, word
/// counts (`Chapter.wordCount`), and what the reader shows count words their
/// own way and are unchanged.
///
/// A word's key is a 64-bit FNV-1a hash of its letters and digits in lower
/// case, so comparing two words is comparing two integers and reading a
/// book's words makes no string per word. Two different words share a key
/// with a chance of about one in 2^64 for each pair; a book of 50,000
/// different words has about one chance in seven billion of holding any
/// such pair, and a shared key would only add a point to a score. The
/// measurement program interned each word's text instead, comparing words
/// as Swift strings do (by canonical equivalence), so the two differ only
/// for a word whose letters are spelled in two canonically equivalent ways,
/// such as a Hangul syllable written as its jamo.
enum FineWords {
    /// One fine word of a text: where it stands, in UTF-16 units, and its
    /// key.
    struct Word: Equatable, Sendable {
        /// Where the word begins in its text.
        let start: Int
        /// Where it ends: one past its last unit.
        let end: Int
        /// Its letters and digits in lower case, hashed (`FineWords`).
        let key: UInt64
    }

    /// What one Unicode scalar is to the fine-word rule.
    enum Kind: Equatable, Sendable {
        /// Neither a letter nor a digit: it ends a word and is part of none.
        case other
        /// A digit: any scalar with a numeric value, from "7" to "½" and
        /// the Roman numeral "Ⅻ", as the measured rule has it. That takes in
        /// the Chinese numerals too ("京", ten quadrillion), so a run of
        /// Chinese text splits around one; text without spaces between
        /// words was not measured.
        case digit
        /// A small letter, or a letter without case (as in Chinese or
        /// Arabic).
        case letter
        /// A capital letter or a title-case one ("ǅ").
        case capital
    }

    /// The FNV-1a offset basis: a word's key before its first letter.
    private static let keyBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    /// The FNV-1a prime, by which each letter folded in is multiplied.
    private static let keyPrime: UInt64 = 0x0000_0100_0000_01b3

    /// Calls `body` with each fine word of `text`, in order: where it
    /// starts and ends (UTF-16 units into `text`) and its key. Returns the
    /// text's length in UTF-16 units, which it measures on the way.
    ///
    /// The text is read once, a Unicode scalar at a time. ASCII is
    /// classified directly; any other scalar by its Unicode properties, as
    /// the measured rule does. Writing the key needs no allocation except
    /// for a capital beyond ASCII, whose lower case comes from
    /// `Unicode.Scalar.Properties.lowercaseMapping`.
    @discardableResult
    static func forEachWord(in text: String, _ body: (_ start: Int, _ end: Int, _ key: UInt64) -> Void) -> Int {
        var offset = 0
        // Where the word being read began, or nil between words.
        var start: Int?
        var key = keyBasis
        var previous = Kind.other
        for scalar in text.unicodeScalars {
            let kind = kind(of: scalar)
            if kind == .other {
                if let wordStart = start {
                    body(wordStart, offset, key)
                    start = nil
                }
            } else {
                if let wordStart = start, splits(after: previous, before: kind) {
                    body(wordStart, offset, key)
                    start = nil
                }
                if start == nil {
                    start = offset
                    key = keyBasis
                }
                fold(scalar, into: &key)
            }
            previous = kind
            // A scalar beyond the Basic Multilingual Plane takes two
            // UTF-16 units (a surrogate pair); every other takes one.
            offset += scalar.value > 0xFFFF ? 2 : 1
        }
        if let wordStart = start {
            body(wordStart, offset, key)
        }
        return offset
    }

    /// The fine words of `text`, in order.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        forEachWord(in: text) { start, end, key in
            words.append(Word(start: start, end: end, key: key))
        }
        return words
    }

    /// The keys of the fine words of `text`, in order.
    static func keys(in text: String) -> [UInt64] {
        var keys: [UInt64] = []
        forEachWord(in: text) { _, _, key in keys.append(key) }
        return keys
    }

    /// What `scalar` is to the fine-word rule: a digit when it has a
    /// numeric value, else a capital or a letter when it is alphabetic (a
    /// capital when it is upper case or title case), else neither.
    static func kind(of scalar: Unicode.Scalar) -> Kind {
        let value = scalar.value
        if value < 0x80 {
            switch value {
            case 0x30...0x39: return .digit
            case 0x61...0x7A: return .letter
            case 0x41...0x5A: return .capital
            default: return .other
            }
        }
        let properties = scalar.properties
        if properties.numericType != nil { return .digit }
        guard properties.isAlphabetic else { return .other }
        return properties.isUppercase || properties.generalCategory == .titlecaseLetter ? .capital : .letter
    }

    /// Whether a word ends between a scalar of kind `previous` and one of
    /// kind `next`, both letters or digits: where letters meet digits, and
    /// where a small letter (or one without case) meets a capital. A
    /// capital followed by a small letter stays one word ("Chapter").
    static func splits(after previous: Kind, before next: Kind) -> Bool {
        (previous == .digit) != (next == .digit) || (previous == .letter && next == .capital)
    }

    /// Whether a UTF-16 unit is white space (Unicode's White_Space
    /// property; none of its characters lies outside the Basic Multilingual
    /// Plane): what separates the tokens a saved quote's cut can split
    /// (`TextAnchorFinder`), as the measured rule has it.
    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Folds `scalar`, a letter or digit, into `key` in lower case. A
    /// scalar that lower-casing changes contributes its lower case (which
    /// for "İ" is two scalars, "i" and a combining dot); every other
    /// contributes itself.
    private static func fold(_ scalar: Unicode.Scalar, into key: inout UInt64) {
        let value = scalar.value
        if value < 0x80 {
            // ASCII: a capital's small letter is 0x20 above it.
            let lower = (0x41...0x5A).contains(value) ? value + 0x20 : value
            key = (key ^ UInt64(lower)) &* keyPrime
        } else if scalar.properties.changesWhenLowercased {
            for lower in scalar.properties.lowercaseMapping.unicodeScalars {
                key = (key ^ UInt64(lower.value)) &* keyPrime
            }
        } else {
            key = (key ^ UInt64(value)) &* keyPrime
        }
    }
}

/// A place in a book's reading text: a chapter, and a UTF-16 offset into
/// that chapter's reading text, as a reading position or a bookmark counts
/// it (`ReadingPosition`, `Bookmark`).
struct TextPlace: Hashable, Sendable {
    /// The chapter's index.
    var chapter: Int
    /// The offset into the chapter's reading text, in UTF-16 units.
    var offset: Int
}

extension TextPlace {
    /// Whether a place `globalOffset` UTF-16 units into a book whose text is
    /// `bookLength` units long rests at the book's end, finished (TODO P07):
    /// at or past the end, where a book that played or was read to its end
    /// is saved. A place short of the end, however near, is not the end:
    /// speech or a player saved there stopped before the book did. False for
    /// a book without text. The one rule: `Book.restsAtEnd` reads a book's
    /// saved place by it, and the place relocator sends a place to the new
    /// text's end only by it.
    static func restsAtEnd(globalOffset: Int, bookLength: Int) -> Bool {
        bookLength > 0 && globalOffset >= bookLength
    }

    /// Where a place saved here opens in a text of `chapterCount` chapters,
    /// `bookLength` UTF-16 units long in all, whose chapter `index` is
    /// `chapterLength(index)` units long (T06's question 7, with P07's end
    /// of a book; `ReaderViewModel.openingPlace` says why): a place the text
    /// holds opens there, held within its chapter; a chapter before the
    /// first opens at the book's start; a chapter past the last opens at the
    /// book's end when `savedGlobalOffset`, the place's offset in the whole
    /// book, rests at the end (`restsAtEnd`), and otherwise at the last
    /// chapter's start. A text without chapters opens at its start. The one
    /// rule: the reader opens a saved place by it, and the place relocator
    /// holds a place saved without words within the old text by it.
    func opening(savedGlobalOffset: Int?, chapterCount: Int, bookLength: Int, chapterLength: (Int) -> Int) -> TextPlace {
        guard chapterCount > 0, chapter >= 0 else { return TextPlace(chapter: 0, offset: 0) }
        let last = chapterCount - 1
        guard chapter <= last else {
            let wasAtTheEnd = savedGlobalOffset.map { Self.restsAtEnd(globalOffset: $0, bookLength: bookLength) } ?? false
            return TextPlace(chapter: last, offset: wasAtTheEnd ? chapterLength(last) : 0)
        }
        return TextPlace(chapter: chapter, offset: min(max(offset, 0), chapterLength(chapter)))
    }
}

/// A book's reading text as fine words, in reading order through every
/// chapter, with where each word stands (T06). The saved-words search
/// (`TextAnchorFinder`) reads a book through it, and so does the diff of a
/// book's old text with its new one, which lines up two of these by their
/// `keys`.
///
/// A place is a chapter and a UTF-16 offset into that chapter's reading
/// text (`TextPlace`), as reading positions and bookmarks count it. Words
/// never cross a chapter's end, and an empty chapter holds none.
struct BookWords: Sendable {
    /// Each chapter's reading text.
    let texts: [String]
    /// Each word's key (`FineWords`), in reading order through the book.
    let keys: [UInt64]
    /// Where each word begins in its chapter's reading text.
    let starts: [Int]
    /// Where each word ends in its chapter's reading text.
    let ends: [Int]
    /// The index in `keys` of each chapter's first word, and one more
    /// entry, the number of words. An empty chapter's entry equals the
    /// next one's.
    let chapterFirstWords: [Int]
    /// Where each chapter begins in the whole book, in UTF-16 units, and
    /// one more entry, the book's length.
    let chapterStarts: [Int]

    /// Reads the fine words of a book whose chapters' reading texts are
    /// `texts`, in order.
    init(texts: [String]) {
        var keys: [UInt64] = []
        var starts: [Int] = []
        var ends: [Int] = []
        var chapterFirstWords: [Int] = []
        var chapterStarts: [Int] = []
        var bookLength = 0
        for text in texts {
            chapterFirstWords.append(keys.count)
            chapterStarts.append(bookLength)
            bookLength += FineWords.forEachWord(in: text) { start, end, key in
                keys.append(key)
                starts.append(start)
                ends.append(end)
            }
        }
        chapterFirstWords.append(keys.count)
        chapterStarts.append(bookLength)
        self.texts = texts
        self.keys = keys
        self.starts = starts
        self.ends = ends
        self.chapterFirstWords = chapterFirstWords
        self.chapterStarts = chapterStarts
    }

    /// How many words the book holds.
    var count: Int { keys.count }

    /// How many chapters the book holds.
    var chapterCount: Int { texts.count }

    /// The book's length: all its chapters' reading text, in UTF-16 units.
    var totalLength: Int { chapterStarts.last ?? 0 }

    /// The length of chapter `chapter`'s reading text in UTF-16 units; 0
    /// for a chapter the book doesn't have.
    func length(ofChapter chapter: Int) -> Int {
        guard chapter >= 0, chapter < chapterCount else { return 0 }
        return chapterStarts[chapter + 1] - chapterStarts[chapter]
    }

    /// The end of the book: its last chapter at its full length, where P07
    /// rests a finished book (END-AND-JUMP-RESEARCH-2026-10-10.md, section
    /// 5); the start of nothing for a book without chapters.
    var endPlace: TextPlace {
        guard chapterCount > 0 else { return TextPlace(chapter: 0, offset: 0) }
        let last = chapterCount - 1
        return TextPlace(chapter: last, offset: length(ofChapter: last))
    }

    /// Whether `place` is exactly the end of the book, where P07 rests a
    /// finished book: the end of its chapter, with nothing but empty
    /// chapters after it. A place past the end rests at the end for P07 too
    /// (`Book.restsAtEnd` reads a place at or past the book's length), but
    /// its numbers point past the text, and the reader opens such a place at
    /// its chapter's start; so it is not the end's place, and the finder
    /// puts it there. False for a book with no text.
    func isEnd(_ place: TextPlace) -> Bool {
        guard totalLength > 0, place.chapter >= 0, place.chapter < chapterCount else { return false }
        return place.offset == length(ofChapter: place.chapter)
            && chapterStarts[place.chapter] + place.offset == totalLength
    }

    /// The chapter word `word` stands in. A word past the book's last word
    /// counts as the last chapter's.
    func chapter(ofWord word: Int) -> Int {
        guard chapterCount > 1 else { return 0 }
        // The last chapter whose first word is at or before `word`: past
        // any empty chapters, which share their first word with the next.
        var low = 0
        var high = chapterCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chapterFirstWords[middle] <= word {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Where word `word` begins; the end of the book past its last word.
    func start(ofWord word: Int) -> TextPlace {
        guard word >= 0 else { return TextPlace(chapter: 0, offset: 0) }
        guard word < count else { return endPlace }
        return TextPlace(chapter: chapter(ofWord: word), offset: starts[word])
    }

    /// Where word `word` begins in the whole book, in UTF-16 units; the
    /// book's length past its last word.
    func globalStart(ofWord word: Int) -> Int {
        globalOffset(of: start(ofWord: word))
    }

    /// Where a found place lands when it stands before word `word`: one
    /// rule for every way of finding a place again, the saved-words search
    /// (`TextAnchorFinder`) and the diff of an old text with a new one
    /// (`PlaceRelocator`) alike.
    ///
    /// - The place lands at the word's start.
    /// - A place that stood inside a word (as a bookmark nudged clear of
    ///   another can) keeps how far into it it was when `word` is that same
    ///   word: `inside` gives that word's key and how many UTF-16 units into
    ///   it the place stood. It never lands past the word's end.
    /// - A place with no word after it in its chapter (`nothingAfter`: at
    ///   its chapter's end, or before nothing but punctuation there) stands
    ///   just after the word before `word`: so when `word` begins another
    ///   chapter, or the book has no more words, it is the end of that
    ///   word's chapter rather than the next chapter's start.
    func landing(beforeWord word: Int, inside: (key: UInt64, offset: Int)? = nil, nothingAfter: Bool = false) -> TextPlace {
        if let inside, word >= 0, word < count, keys[word] == inside.key {
            return TextPlace(chapter: chapter(ofWord: word), offset: min(starts[word] + inside.offset, ends[word]))
        }
        if nothingAfter, word > 0, word <= count {
            let chapter = chapter(ofWord: word - 1)
            if word == count || self.chapter(ofWord: word) != chapter {
                return TextPlace(chapter: chapter, offset: length(ofChapter: chapter))
            }
        }
        return start(ofWord: word)
    }

    /// The word `place` stands inside, or else the first word after it;
    /// `count` when no word follows it in the book.
    func word(at place: TextPlace) -> Int {
        guard place.chapter >= 0 else { return 0 }
        guard place.chapter < chapterCount else { return count }
        var low = chapterFirstWords[place.chapter]
        var high = chapterFirstWords[place.chapter + 1]
        while low < high {
            let middle = (low + high) / 2
            if ends[middle] <= place.offset {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }

    /// Where `place` stands in the whole book, in UTF-16 units: its
    /// chapter's start plus its offset, held within its chapter.
    func globalOffset(of place: TextPlace) -> Int {
        guard place.chapter >= 0 else { return 0 }
        guard place.chapter < chapterCount else { return totalLength }
        return chapterStarts[place.chapter] + min(max(place.offset, 0), length(ofChapter: place.chapter))
    }

    /// The place `offset` UTF-16 units into the whole book, held within the
    /// book. An offset where one chapter ends and the next begins is the
    /// next chapter's start (past any empty chapters); the book's length is
    /// its end.
    func place(atGlobalOffset offset: Int) -> TextPlace {
        guard chapterCount > 0 else { return TextPlace(chapter: 0, offset: 0) }
        let clamped = min(max(offset, 0), totalLength)
        var low = 0
        var high = chapterCount - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if chapterStarts[middle] <= clamped {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return TextPlace(chapter: low, offset: clamped - chapterStarts[low])
    }
}
