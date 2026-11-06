import Foundation

// MARK: - What an Office Document Reader Holds While It Reads

/// The look of the text being read: the emphasis and the size (in half
/// points, as the rich-text blocks keep it) that `RTFSizeHeadings` and the
/// HTML writer use.
struct OfficeRun: Equatable {
    var bold = false
    var italic = false
    var size = 24
    /// Whether the text is hidden (a paragraph style hides its text, and a
    /// span can show it again): hidden text is not kept.
    var hidden = false

    /// This run with the properties given put over it; a nil one is
    /// inherited. `size` is in half points.
    func applying(bold: Bool?, italic: Bool?, size: Int?) -> OfficeRun {
        var run = self
        if let bold { run.bold = bold }
        if let italic { run.italic = italic }
        if let size { run.size = size }
        return run
    }

    /// `points` as half points, held to a sane range.
    static func halfPoints(_ points: Double) -> Int {
        min(max(Int((points * 2).rounded()), 1), 2_000)
    }
}

/// One piece of an open paragraph, kept until the paragraph is finished,
/// because a paragraph can turn out to be hidden after its words are read
/// (`text:hidden-paragraph` comes after the text it hides).
enum OfficePiece {
    /// Words, in the look they were read in.
    case text(String, OfficeRun)
    /// `text:line-break`.
    case lineBreak
    /// A page begins here (a hard break, or a break before the paragraph),
    /// and, if no letter or digit has been read, no page begins yet.
    case pageStart
    /// A page begins here by the layout's own record (`text:soft-page-break`):
    /// it begins one even before the first words.
    case softPageStart
}

/// A block that waits for the paragraph around it to be written: what is
/// anchored in a paragraph (a text box, a shape, a picture's description) is
/// read right after the paragraph, so that its sentence stays whole.
enum OfficeDeferred {
    /// A paragraph that ended inside the paragraph.
    case paragraph(OfficeOpenParagraph)
    /// A table begins, with whether its style begins a page before and after it.
    case beginTable(startsPage: Bool, startsPageAfter: Bool)
    /// A cell begins; one that a file repeats is read that many times.
    case beginCell(repeated: Int)
    /// A cell, a row, and a table end.
    case endCell
    case endRow
    case endTable
}

/// A paragraph or heading whose end has not been read yet. The readers of
/// OpenDocument text (FMT27) and Word 2003 XML (FMT53) both keep their
/// paragraphs here.
struct OfficeOpenParagraph {
    /// What the paragraph becomes when it ends.
    var kind: RTFBlockBuilder.Kind
    /// Whether the paragraph begins a page after it ends
    /// (`fo:break-after`).
    var startsPageAfter = false
    /// How many `text:hidden-paragraph` fields the paragraph holds that are
    /// hiding it and that are not: it is hidden when it holds some and all
    /// of them hide it.
    var hidingFields = 0
    var shownFields = 0
    /// Whether a style hides the paragraph's text: it is then dropped unless
    /// a span shows some of its words again.
    var isHiddenByStyle = false

    /// Whether the paragraph's fields hide it altogether.
    var isHidden: Bool { hidingFields > 0 && shownFields == 0 }

    /// Whether the paragraph held hidden text, which was left out: a paragraph
    /// that then holds no words begins no page.
    var hasHiddenText = false

    /// What has been read of the paragraph since it began, or since its
    /// pieces were last written out.
    var pieces: [OfficePiece] = []
    /// The notes whose references are in the paragraph, in order. They are
    /// read (after the main text) only if the paragraph is, so a note in
    /// hidden text is not read.
    var notes: [OfficeFlow] = []
    /// What is anchored in the paragraph (the paragraphs and tables of text
    /// boxes and shapes, and pictures' descriptions), finished and waiting:
    /// written right after the paragraph, so its sentence stays whole, and
    /// not at all if it is hidden.
    var deferred: [OfficeDeferred] = []

    /// Whether the pieces hold a character other than white space.
    var hasWords: Bool {
        pieces.contains { piece in
            if case .text(let words, _) = piece { return words.unicodeScalars.contains { !$0.properties.isWhitespace } }
            return false
        }
    }
    /// The look of the text now, and the looks of the spans around it.
    private(set) var run: OfficeRun
    private var enclosingRuns: [OfficeRun] = []
    /// Whether the text so far ends in white space (or is empty), so that
    /// the next white space of the markup collapses into it: OpenDocument
    /// reads a run of white space in the markup as one space, and none at
    /// the start of a paragraph or after a line break.
    private var followsSpace = true

    init(kind: RTFBlockBuilder.Kind, run: OfficeRun) {
        self.kind = kind
        self.run = run
    }

    // MARK: Looks

    /// Begins a span or link whose text has the look `run`.
    mutating func beginSpan(_ run: OfficeRun) {
        enclosingRuns.append(self.run)
        self.run = run
    }

    /// Ends the span or link begun last.
    mutating func endSpan() {
        if let enclosing = enclosingRuns.popLast() { run = enclosing }
    }

    // MARK: Words

    /// Adds the characters of the markup, with white space read as
    /// OpenDocument reads it.
    /// - Returns: the number of bytes of text added.
    @discardableResult
    mutating func addCharacters(_ characters: String) -> Int {
        // Hidden text is not kept, and does not change the spacing around it.
        guard !run.hidden else { return 0 }
        var text = ""
        for scalar in characters.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\r":
                guard !followsSpace else { continue }
                text.unicodeScalars.append(" ")
                followsSpace = true
            case Self.softHyphen:
                // Invisible unless the line breaks there: not a word's end.
                continue
            case Self.noBreakSpace, Self.narrowNoBreakSpace:
                // A space that does not collapse and that keeps a line whole.
                text.unicodeScalars.append(" ")
                followsSpace = false
            default:
                text.unicodeScalars.append(scalar)
                followsSpace = false
            }
        }
        add(text)
        return text.utf8.count
    }

    /// Adds words that stand as they are (`text:s`, `text:tab`): they do
    /// not collapse, and white space after them is not dropped.
    mutating func addExplicit(_ text: String) {
        add(Self.spoken(text))
        followsSpace = false
    }

    /// The soft hyphen and the no-break spaces.
    private static let softHyphen: Unicode.Scalar = "\u{AD}"
    private static let noBreakSpace: Unicode.Scalar = "\u{A0}"
    private static let narrowNoBreakSpace: Unicode.Scalar = "\u{202F}"

    /// `text` as it is heard: no soft hyphens, which show only where a line
    /// breaks and would join or split a word, and no-break spaces as spaces.
    static func spoken(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0 == softHyphen || $0 == noBreakSpace || $0 == narrowNoBreakSpace }) else {
            return text
        }
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != softHyphen {
            result.append(scalar == noBreakSpace || scalar == narrowNoBreakSpace ? " " : scalar)
        }
        return String(result)
    }

    /// `text:line-break`.
    mutating func addLineBreak() {
        guard !run.hidden else { return }
        pieces.append(.lineBreak)
        followsSpace = true
    }

    /// Marks that a page begins here. A hard break between words that touch
    /// (Word writes `and`, a page break, `continues` in one run) keeps them
    /// apart with a space, so that the marker, which is no white space,
    /// joins nothing. The layout's own break (`soft`) adds no space: it
    /// falls between words, and not inside one.
    mutating func addPageStart(soft: Bool = false) {
        if !soft, case .text(let before, _)? = pieces.last, let last = before.unicodeScalars.last,
           !last.properties.isWhitespace {
            add(" ")
            followsSpace = true
        }
        pieces.append(soft ? .softPageStart : .pageStart)
    }

    /// If the paragraph begins with a bullet character and a tab (how a
    /// writer without lists marks a list item: a tab, a bullet, a tab, and the
    /// item's words), takes them out and returns true; otherwise leaves the
    /// paragraph as it is and returns false. A dash or an asterisk and a
    /// space are words, not a bullet: the tab is what shows a mark.
    /// - Parameter bullets: the characters that are bullets.
    mutating func removeLeadingBullet(from bullets: Set<Character>) -> Bool {
        guard case .text(let first, let look)? = pieces.first else { return false }
        var rest = Substring(first).drop(while: { $0.isWhitespace })
        guard let bullet = rest.first, bullets.contains(bullet) else { return false }
        rest = rest.dropFirst()
        guard rest.first == "\t" else { return false }
        rest = rest.drop(while: { $0.isWhitespace })
        if rest.isEmpty {
            pieces.removeFirst()
        } else {
            pieces[0] = .text(String(rest), look)
        }
        return true
    }

    /// Adds `text` in the current look, joining the text before it when the
    /// look is the same.
    private mutating func add(_ text: String) {
        guard !text.isEmpty, !run.hidden else { return }
        if case .text(var before, let look)? = pieces.last, look == run {
            // The piece is taken out of the array first, so that its string
            // is the only holder and the append does not copy it: a paragraph
            // of a million pieces of text must not cost a million copies.
            pieces.removeLast()
            before.append(text)
            pieces.append(.text(before, look))
        } else {
            pieces.append(.text(text, run))
        }
    }
}

/// One open list of an OpenDocument document (`text:list`): the list style
/// its items are marked by, and whether the next paragraph is the first of
/// an item.
struct OfficeOpenList {
    /// The list style by name, from the list or the one around it.
    var styleName: String?
    /// For the lists of OpenDocument 1.1 (`text:ordered-list` and
    /// `text:unordered-list`), which say what they are: true for a numbered
    /// list. Nil for a list whose style says.
    var isNumbered: Bool?
    /// Whether a list item has begun and its first paragraph has not. Only
    /// that paragraph is the item's; the item's others are paragraphs of
    /// the text.
    var awaitsFirstParagraph = false
}

/// Where paragraphs are being collected: the main text, or the notes that
/// follow it. Each has its own builder, so a note in the middle of a
/// paragraph does not break the paragraph.
final class OfficeFlow {
    /// Builds the blocks: it gathers the words, places the pages, groups
    /// the cells of a table, and keeps the budget (`RTFBlockBuilder`).
    var builder: RTFBlockBuilder
    /// How many tables are open: a table inside a cell is read into the
    /// cell around it.
    var tableDepth = 0
    /// Whether each open table's style ends its page (`fo:break-after`).
    var tablesStartPageAfter: [Bool] = []
    /// The paragraphs of the cell open, if a file repeats the cell, to be
    /// read again for each repeat.
    var repeatedCell: (times: Int, paragraphs: [OfficeOpenParagraph])?
    /// The notes of the paragraphs written in this flow, in file order: the
    /// notes of a note follow it.
    var committedNotes: [OfficeFlow] = []
    /// The lists open, outermost first, and the lists open outside each
    /// text box that is open (a text box starts lists of its own).
    var lists: [OfficeOpenList] = []
    var listsOutsideTextBoxes: [[OfficeOpenList]] = []
    /// The paragraphs open, outermost first: a text box in a paragraph
    /// holds paragraphs of its own.
    var paragraphs: [OfficeOpenParagraph] = []

    init(includesPages: Bool, limit: Int64) {
        builder = RTFBlockBuilder(includesPages: includesPages, limit: limit)
    }
}
