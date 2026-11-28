import Foundation

// MARK: - The Code Page of Each Run

/// The code page of each stretch of text in a Word 6 or Word 95 document of one-byte characters. One
/// document holds text in several: Word marks a run of Macintosh text in a Windows document (and the
/// reverse) with `sprmCChse`, and a run in a Cyrillic or Greek font is in that code page whatever the
/// language of the document says. The rule, in order, for the text of a run:
/// 1. text in the font named Symbol (or a clone of it: `WordSymbolFontEncodings`) is in the Symbol encoding (its letters are Greek, its other characters
///    mathematical): `AdobeSymbolEncoding`. It is what Word shows (textutil does not decode it). A run that
///    holds a symbol of Insert Symbol is not: its "(" is a placeholder (`WordHTMLWriter`);
/// 2. the run's own mark (`sprmCChse`): 256 is the Macintosh's (Mac Roman), else the FIB's mark for
///    a Macintosh document;
/// 3. the character set of the run's font, if it names a code page. The font is the run's own
///    (`sprmCFtc`), else its character style's, else its paragraph style's, else the sheet's default,
///    each through the styles it is based on. A Far East font names none: whether the characters are
///    two bytes is the document's choice, and a run never switches into or out of double-byte;
/// 4. an explicit Windows mark (`sprmCChse` 0) in a document marked Macintosh is Windows-1252;
/// 5. the document's default: the non-Western code page whose fonts hold more than half the characters
///    above 0x7F that have a code page of their font, else the language's code page.
///
/// The language alone does not do: the FIB's language says English on three of four real Cyrillic
/// documents. A foreign font that lists a code page but is used for three characters must not make a
/// whole English report Greek, as the first reading of this format did.
///
/// The stretches are found in one sweep over the boundaries of the character and paragraph runs, and
/// each character asks a cursor that moves forward, so the cost grows with the runs and the text.
/// Damaged tables give the document's default.
struct WordLegacyCodePages {

    /// The name by which the decoding of the Symbol font stands among the tables (no code page has it).
    private static let symbolFontIdentifier = "adobe-symbol"

    /// The decoding tables in use (single byte to code unit); the first is the document's default.
    private let tables: [[UInt16]]
    /// The stretches, in order, with the index of the table of each.
    private let stretches: [(range: Range<Int>, table: Int)]

    /// A cursor that answers `table(at:)` for positions that never decrease.
    struct Cursor {
        fileprivate let pages: WordLegacyCodePages
        private var index = 0

        /// A cursor over `pages`, at its first stretch.
        fileprivate init(pages: WordLegacyCodePages) {
            self.pages = pages
        }

        /// The table that decodes the byte at `position`.
        mutating func table(at position: Int) -> [UInt16] {
            while index < pages.stretches.count, pages.stretches[index].range.upperBound <= position { index += 1 }
            if index < pages.stretches.count, pages.stretches[index].range.lowerBound <= position {
                return pages.tables[pages.stretches[index].table]
            }
            return pages.tables[0]
        }
    }

    /// A new cursor at the first stretch.
    func cursor() -> Cursor {
        Cursor(pages: self)
    }

    // MARK: Building

    /// The code pages of the document whose text is `pieces` (one-byte characters, in `document`), by its
    /// formatting. Without runs the document has its default alone.
    static func build(
        characters: WordLegacyCharacters, styles: WordStyleSheet, paragraphs: WordFormatRuns<WordParagraphFormat>,
        characterRuns: WordFormatRuns<WordCharacterFormat>, pieces: WordPieceTable, document: OLEBytes
    ) -> WordLegacyCodePages {
        let limit = pieces.characterCount
        // The boundaries of every run, which cut the text where any answer can change.
        var cuts = [0, limit]
        for run in characterRuns.runs { cuts.append(run.range.lowerBound); cuts.append(run.range.upperBound) }
        for run in paragraphs.runs { cuts.append(run.range.lowerBound); cuts.append(run.range.upperBound) }
        let boundaries = Array(Set(cuts.filter { (0...limit).contains($0) })).sortedStably()

        // What each stretch is: marked as the Macintosh's, or in the code page its font names, with the
        // characters above 0x7F it holds.
        struct Stretch {
            let range: Range<Int>
            let isMacintosh: Bool
            let isWindowsMarked: Bool
            let fontPage: String?
            let isSymbolFont: Bool
        }
        var stretches: [Stretch] = []
        var characterCursor = characterRuns.cursor()
        var paragraphCursor = paragraphs.cursor()
        let symbolFonts = characters.fonts.symbolFonts
        var usage: [String: Int] = [:]
        var otherHighCharacters = 0
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where start < end {
            let character = characterCursor.format(at: start) ?? WordCharacterFormat()
            let paragraph = paragraphCursor.format(at: start) ?? WordParagraphFormat()
            let isMacintosh = character.characterSet.map { $0 == 256 } ?? characters.isMacintosh
            // The run's font, by its set.
            var fontPage: String?
            var isSymbolFont = false
            let font = styles.fontIndex(paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.fontIndex)
            if let font, symbolFonts.contains(font), character.symbolFont == nil {
                isSymbolFont = true
            } else if let font,
               characters.fonts.characterSets.indices.contains(font),
               let page = WordLegacyCharacters.codePage(ofFontCharacterSet: characters.fonts.characterSets[font]),
               !WordLegacyCharacters.doubleByteCodePages.contains(page) {
                fontPage = page
            }
            let high = isSymbolFont ? 0 : pieces.countBytesAbove7F(in: start..<end, document: document)
            if high > 0 {
                if let fontPage { usage[fontPage, default: 0] += high } else { otherHighCharacters += high }
            }
            stretches.append(Stretch(
                range: start..<end, isMacintosh: isMacintosh, isWindowsMarked: character.characterSet == 0, fontPage: fontPage,
                isSymbolFont: isSymbolFont
            ))
        }

        // The document's default.
        var defaultPage = WordLegacyCharacters.codePage(ofLanguage: characters.languageIdentifier)
        let ranked = usage.sortedStably { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
        if let top = ranked.first, top.value > otherHighCharacters {
            defaultPage = top.key
        }

        // The tables, the default first, and the stretches that use them, joined when they run on.
        var identifiers: [String] = []
        var tables: [[UInt16]] = []
        /// The index in `tables` of the table that decodes the code page `identifier` (or the Symbol font's), made
        /// the first time it is asked for.
        func index(of identifier: String) -> Int {
            if let known = identifiers.firstIndex(of: identifier) { return known }
            identifiers.append(identifier)
            if identifier == Self.symbolFontIdentifier {
                tables.append(WordLegacyCharacters.symbolFontTable())
            } else {
                let encoding = WordLegacyCharacters.encoding(named: identifier)
                    ?? WordLegacyCharacters.encoding(named: TextEncodingCatalog.windows1252Identifier) ?? .windowsCP1252
                tables.append(WordLegacyCharacters.table(for: encoding))
            }
            return identifiers.count - 1
        }
        _ = index(of: defaultPage)
        var joined: [(range: Range<Int>, table: Int)] = []
        for stretch in stretches {
            let page: String
            if stretch.isSymbolFont {
                page = Self.symbolFontIdentifier
            } else if stretch.isMacintosh {
                page = "macintosh"
            } else if let fontPage = stretch.fontPage {
                page = fontPage
            } else if stretch.isWindowsMarked && characters.isMacintosh {
                page = TextEncodingCatalog.windows1252Identifier
            } else {
                page = defaultPage
            }
            let table = index(of: page)
            if let last = joined.last, last.table == table, last.range.upperBound == stretch.range.lowerBound {
                joined[joined.count - 1].range = last.range.lowerBound..<stretch.range.upperBound
            } else {
                joined.append((stretch.range, table))
            }
        }
        return WordLegacyCodePages(tables: tables, stretches: joined)
    }
}
