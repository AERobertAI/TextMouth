import Foundation

// MARK: - Sections and Page Numbers (PG07)

/// How a section's pages are numbered (`w:pgNumType w:fmt`): decimal,
/// lower- and upper-case Roman numerals, and lower- and upper-case letters.
/// Every other format Word offers is written as decimal.
enum DOCXPageNumberFormat: Equatable {
    case decimal
    case lowerRoman
    case upperRoman
    case lowerLetter
    case upperLetter

    /// The longest run of one letter Word counts to before this reader
    /// writes the number in decimal instead (a to z, aa to zz, aaa, …).
    static let longestLetterRun = 32

    /// The format a `w:fmt` attribute names; decimal for any other value, or none.
    init(_ value: String?) {
        switch value {
        case "lowerRoman": self = .lowerRoman
        case "upperRoman": self = .upperRoman
        case "lowerLetter": self = .lowerLetter
        case "upperLetter": self = .upperLetter
        default: self = .decimal
        }
    }

    /// The label of page number `number` in this format. Roman numerals run
    /// from 1 to 3999 and letters from 1 to 32 runs of 26 letters, and any
    /// number outside them (0 included) is written in decimal, since the
    /// format has no way to write it.
    func label(forNumber number: Int) -> String {
        switch self {
        case .decimal:
            return String(number)
        case .lowerRoman:
            return Self.roman(number)?.lowercased() ?? String(number)
        case .upperRoman:
            return Self.roman(number) ?? String(number)
        case .lowerLetter:
            return Self.letters(number) ?? String(number)
        case .upperLetter:
            return Self.letters(number)?.uppercased() ?? String(number)
        }
    }

    /// `number` in upper-case Roman numerals; nil outside 1...3999.
    private static func roman(_ number: Int) -> String? {
        guard (1...3999).contains(number) else { return nil }
        let numerals: [(value: Int, symbol: String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remaining = number
        var written = ""
        for numeral in numerals {
            while remaining >= numeral.value {
                written += numeral.symbol
                remaining -= numeral.value
            }
        }
        return written
    }

    /// `number` counted as Word counts letters: a to z, then aa to zz, then
    /// aaa to zzz, and so on (27 is "aa", 28 is "bb"). Nil outside the 26
    /// letters times `longestLetterRun`, and for numbers below 1.
    private static func letters(_ number: Int) -> String? {
        guard number >= 1, number <= 26 * longestLetterRun else { return nil }
        let letterIndex = (number - 1) % 26
        let repeatCount = (number - 1) / 26 + 1
        let letter = Character(Unicode.Scalar(UInt8(ascii: "a") + UInt8(letterIndex)))
        return String(repeating: String(letter), count: repeatCount)
    }
}

/// One section of a document, as its `w:sectPr` states it (PG07).
struct DOCXSection: Equatable {
    /// The most a restart number can be (`w:pgNumType w:start`); a larger
    /// number, a negative one, and a word are ignored.
    static let largestStart = 999_999

    /// Whether the section begins on a new page: its `w:type` is
    /// `nextPage` (also when it names none), `oddPage`, or `evenPage`; not
    /// `continuous` or `nextColumn`.
    var startsPage = true
    /// The number the section's first page takes (`w:pgNumType w:start`),
    /// or nil to go on counting from the page before.
    var start: Int?
    /// How the section's pages are numbered.
    var format = DOCXPageNumberFormat.decimal

    /// Whether a `w:type` attribute value begins the section on a new page.
    static func typeStartsPage(_ value: String?) -> Bool {
        guard let value else { return true }
        return value != "continuous" && value != "nextColumn"
    }

    /// The restart number a `w:start` attribute value gives: only ASCII
    /// digits, from 0 to `largestStart`; nil for anything else.
    static func restartNumber(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.utf8.count <= 7,
              value.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              let number = Int(value), number <= largestStart else { return nil }
        return number
    }
}

/// The sections of a document in order (PG07). A `w:sectPr` comes at the end
/// of its section (in the last paragraph's properties, or last in the body),
/// so one light pass over the text part collects them all before the
/// converter, which needs a section's page number when the section begins.
struct DOCXSections: Equatable {
    /// Every section, in document order.
    let sections: [DOCXSection]

    init(sections: [DOCXSection] = []) {
        self.sections = sections
    }

    /// The section at `index`; a section with the defaults when the document
    /// states none there (a document with no `w:sectPr` at all).
    func section(at index: Int) -> DOCXSection {
        sections.indices.contains(index) ? sections[index] : DOCXSection()
    }

    /// The sections the text part `data` states. A part that is damaged yields
    /// the sections before the damage: the converter, which reads the same
    /// bytes, reports the damage itself.
    static func read(from data: Data, file: String = DOCXParser.Part.document) -> DOCXSections {
        let parser = DOCXSectionsParser(data: data, file: file)
        try? parser.parseDocument()
        return DOCXSections(sections: parser.sections)
    }
}

/// The light pass that collects a document's sections (PG07).
private final class DOCXSectionsParser: DOCXSAXParser {
    /// The sections read so far, in order.
    private(set) var sections: [DOCXSection] = []
    /// The section being read, between its `w:sectPr` start and end.
    private var current: DOCXSection?
    /// How many records of tracked changes enclose the element being read.
    /// `w:sectPrChange` holds the section as it was before the change, with a
    /// `w:sectPr` of its own that is no section of the document.
    private var trackedChangeDepth = 0

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        if localName.hasSuffix("Change") {
            trackedChangeDepth += 1
        }
        guard trackedChangeDepth == 0 else { return }
        switch localName {
        case "sectPr":
            current = DOCXSection()
        case "type" where current != nil:
            current?.startsPage = DOCXSection.typeStartsPage(attributes["w:val"])
        case "pgNumType" where current != nil:
            current?.start = DOCXSection.restartNumber(attributes["w:start"])
            current?.format = DOCXPageNumberFormat(attributes["w:fmt"])
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        if localName.hasSuffix("Change") {
            trackedChangeDepth = max(0, trackedChangeDepth - 1)
            return
        }
        guard trackedChangeDepth == 0, localName == "sectPr", let finished = current else { return }
        sections.append(finished)
        current = nil
    }
}

// MARK: - The Page Counter

/// Follows a document's pages as the converter walks it (PG07): which page
/// is pending, what number and format it takes, and which section the walk
/// is in. A page start sets a page pending; the converter writes its marker
/// before the next text that is not whitespace and then takes it.
struct DOCXPageTracker {
    private let sections: DOCXSections
    /// The index of the section being read.
    private var sectionIndex = 0
    /// Whether the section being read has not yet had its first block (a
    /// paragraph or table): its start may begin a page.
    private var sectionJustBegan = false
    /// A restart number the section being read stated and no page has taken.
    private var restartNumber: Int?
    /// The number of the latest page started; 0 before the first.
    private var number = 0
    /// The format of the latest page started.
    private var format = DOCXPageNumberFormat.decimal
    /// Whether a page has started and its marker is not yet written.
    private(set) var isPending = false
    /// Whether the pending page began at a `w:br` that joined the words
    /// around it, so the marker keeps them apart.
    private(set) var pendingJoinsWords = false
    /// The pages whose markers have been written; the next page's ordinal is one more.
    private var writtenCount = 0

    /// Begin at the document's start, where page 1 is pending: a break
    /// before the first words merges with it.
    init(sections: DOCXSections) {
        self.sections = sections
        enterSection()
        startPage()
    }

    /// The label of the pending page, or nil when none is pending.
    var pendingLabel: String? {
        isPending ? format.label(forNumber: number) : nil
    }

    /// A page begins here. With no page pending it is the next page; with one
    /// pending the two are one page that takes this start's numbering: its
    /// restart number and format, if the section it began in states any.
    /// - Parameter joinsWords: whether the start is a `w:br`, which stood
    ///   between two words.
    mutating func startPage(joinsWords: Bool = false) {
        let section = sections.section(at: sectionIndex)
        if let restart = restartNumber {
            number = restart
            restartNumber = nil
        } else if !isPending {
            number += 1
        }
        format = section.format
        isPending = true
        pendingJoinsWords = pendingJoinsWords || joinsWords
    }

    /// The pending page's marker, written now: its label, and the page's
    /// 1-based ordinal among those written. Nil when none is pending.
    mutating func takePendingMarker() -> (marker: MarkdownPageMarker, joinsWords: Bool)? {
        guard let label = pendingLabel else { return nil }
        writtenCount += 1
        let result = (MarkdownPageMarker(label: label, ordinal: writtenCount), pendingJoinsWords)
        isPending = false
        pendingJoinsWords = false
        return result
    }

    /// A paragraph or table begins. The first of a section begins a page when
    /// the section's break says so (nextPage, oddPage, evenPage).
    mutating func beginBlock() {
        guard sectionJustBegan else { return }
        sectionJustBegan = false
        if sections.section(at: sectionIndex).startsPage {
            startPage()
        }
    }

    /// The paragraph that ends the section being read has ended: the next
    /// block begins the next section.
    mutating func endSection() {
        sectionIndex += 1
        enterSection()
    }

    /// Note the start of the section at `sectionIndex`: its restart number
    /// waits for the first page that begins in it.
    private mutating func enterSection() {
        restartNumber = sections.section(at: sectionIndex).start
        sectionJustBegan = sectionIndex > 0
    }
}
