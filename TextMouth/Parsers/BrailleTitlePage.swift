import Foundation

/// The title and author a braille book's title page names (Life of Pi,
/// November 13, 2026). A BRF or BRL carries no metadata, but a transcribed
/// book opens with a title page whose first centered row is the title and
/// whose next names the author after "by": it reads as "Life of Pi" and
/// "by Yann Martel", or as one row, "Life of Pi by Yann Martel".
///
/// The page is read in braille first, because the word "by" is a different
/// cell in the two codes a transcription may use (⠃⠽, spelled, in UEB and
/// English Braille alike; ⠴, one sign, in English Braille, American
/// Edition), and what follows the word is the author whichever code was
/// used. The title and author are then translated with the table the book
/// is read with, as every block of the book is.
enum BrailleTitlePage {
    // MARK: Constants

    /// The blank cell (U+2800) that parts the words of a row.
    private static let blankCell: Character = "\u{2800}"
    /// "by" spelled, as a word of its own, in lowercase and with a capital sign.
    private static let spelledBy: Set<String> = ["⠃⠽", "⠠⠃⠽"]
    /// English Braille, American Edition's one-cell "by" (dots 3-5-6).
    private static let bySign = "⠴"
    /// The capital sign (dot 6), which that sign may be written against.
    private static let capitalSign = "⠠"
    /// The most rows of the title page looked at, and the most of them a title may take.
    private static let maxRowsLooked = 8
    private static let maxTitleRows = 3
    /// The fewest centered rows a page with no "by" has to be read as a title page.
    private static let minRowsOfTitlePage = 3
    /// The longest print a title or an author may have to be taken: longer is a paragraph.
    private static let maxPrintLength = 200

    // MARK: In braille

    /// The title and the author of a title page, as braille cells (words
    /// parted by blank cells), before they are translated.
    struct Names: Equatable {
        /// The title; nil when the page names none (it opens with "by").
        var title: String?
        /// The author after "by"; nil when the page has none.
        var author: String?
    }

    /// What the centered rows of a title page, `lines` (empty strings part
    /// stretches of rows, as `BraillePageAnalyzer.centeredRowsOfFirstPage(of:)`
    /// gives them), name.
    ///
    /// The first row with the word "by" in it is where the author begins:
    /// the rows before it, and the words before "by" in it, are the title
    /// (the rows of the first two stretches only, and at most three rows;
    /// a "by" farther down is not the page's), and the words after it, or
    /// the next row when it ends the row, are the author. A page with no "by"
    /// names its first row as the title and no author, when it has at least
    /// three rows (`minRowsOfTitlePage`). A page with no row names nothing.
    static func names(inRows lines: [String], hasRule: Bool = false) -> Names? {
        // Only the first two stretches of rows, which is where a title and
        // an author stand, and no more than a handful of rows.
        var rows: [String] = []
        var stretches = 0
        // How many of the rows are in the first stretch.
        var firstStretchRows = 0
        for line in lines {
            if line.isEmpty {
                stretches += 1
                if stretches == 1 { firstStretchRows = rows.count }
                if stretches == 2 { break }
            } else if rows.count < maxRowsLooked {
                rows.append(line)
            }
        }
        guard let first = rows.first else { return nil }
        if stretches == 0 { firstStretchRows = rows.count }

        // A row that begins with "by" is the author's, wherever it stands
        // (but the first row, which is the title's); failing that, the first
        // row with "by" inside it, in the first stretch, is a "Title by
        // Author" row. So "Stand by Me" above "by Stephen King" is a title of
        // its own, and the "Published by" of a later stretch is no author's.
        let startsWithBy = rows.indices.dropFirst().first { splitAtBy(rows[$0])?.before.isEmpty == true }
        guard let index = startsWithBy ?? rows.indices.prefix(firstStretchRows).first(where: { splitAtBy(rows[$0]) != nil }),
              let split = splitAtBy(rows[index]) else {
            // With no "by", the page is a title page only if it has the several
            // rows one has (a title, a publisher, an ISBN) and a rule that sets
            // the title off: a page of a part title, a chapter heading and an
            // epigraph is none, and a chapter exported alone names the file.
            let centeredRows = lines.filter { !$0.isEmpty }.count
            return centeredRows >= minRowsOfTitlePage && hasRule ? Names(title: first, author: nil) : nil
        }
        var titleRows = Array(rows[..<index])
        if !split.before.isEmpty { titleRows.append(split.before) }
        // The words after "by", or the row below when "by" ends its row.
        let author = split.after.isEmpty ? (index + 1 < rows.count ? rows[index + 1] : "") : split.after
        // A title of more rows than a title has is not read: the first row stands for it.
        let title = titleRows.count > maxTitleRows ? first : titleRows.joined(separator: String(blankCell))
        return Names(title: title.isEmpty ? nil : title, author: author.isEmpty ? nil : author)
    }

    /// What the first page of `pages` names (`names(inRows:hasRule:)`).
    static func names(of pages: BrailleFilePages) -> Names? {
        let first = BraillePageAnalyzer.centeredRowsOfFirstPage(of: pages)
        return names(inRows: first.lines, hasRule: first.hasRule)
    }

    /// `row` parted at its first word "by": the words before it and the
    /// words after it, each as braille with blank cells between words. The
    /// sign ⠴ counts as "by" when it is a word alone or begins the row
    /// against a capital sign (⠴⠠⠽⠁⠝⠝, "by Yann"), which no print begins a
    /// row with; spelled "by" counts anywhere, as a word of its own.
    private static func splitAtBy(_ row: String) -> (before: String, after: String)? {
        let words = row.split(separator: blankCell, omittingEmptySubsequences: true).map(String.init)
        for (index, word) in words.enumerated() {
            if spelledBy.contains(word) || word == bySign {
                return (join(words[..<index]), join(words[(index + 1)...]))
            }
            if index == 0, word.hasPrefix(bySign + capitalSign) {
                // The sign and the word it is written against: the word stays
                // after "by", less the sign.
                return ("", join([String(word.dropFirst())] + words[1...]))
            }
        }
        return nil
    }

    /// `words` as one braille text, a blank cell between words.
    private static func join<Words: Sequence>(_ words: Words) -> String where Words.Element == String {
        words.joined(separator: String(blankCell))
    }

    // MARK: In print

    /// The title and author the title page of the braille book at `url`
    /// names, in print, read with `table` and `code` (the book's table and
    /// braille file characters, as `BrailleBookReader.markdown` takes them);
    /// nil for a name the page lacks, or when nothing can be read or
    /// translated: reading a title page never fails an import, which lists
    /// the book under its file's name and an unknown author instead.
    static func names(ofFileAt url: URL, table: String, fileCode: String?) -> (title: String?, author: String?) {
        let kind = BrailleBookReader.kind(of: url)
        guard kind == .brf,
              let code = BrailleFileCode.code(forStored: fileCode),
              let pages = try? BrailleFileReader.read(url, as: kind, code: code),
              let named = Self.names(of: pages) else {
            return (nil, nil)
        }
        // Translate what the page names, together, in one run of the helper.
        let braille = [named.title, named.author].compactMap { $0 }
        let printed = (try? TextutilDocumentReader.withWorkingFolder(for: url) { folder in
            try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: folder)
        }).map { $0.map(cleaned) } ?? []
        guard printed.count == braille.count else { return (nil, nil) }
        var remaining = printed[...]
        let title = named.title == nil ? nil : remaining.popFirst().flatMap { $0 }
        let author = named.author == nil ? nil : remaining.popFirst().flatMap { $0 }
        return (title, author)
    }

    /// `text` as a title or an author: its white space made single spaces
    /// and trimmed; nil when it is empty, has no letter or digit, or is too
    /// long to be one.
    private static func cleaned(_ text: String) -> String? {
        let trimmed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !trimmed.isEmpty, trimmed.count <= maxPrintLength,
              trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return trimmed
    }
}
