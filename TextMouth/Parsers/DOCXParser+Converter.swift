import Foundation

// MARK: - DOCX to Markdown Converter

/// What the body of a document refers to in its notes parts: the notes a
/// person who reads the body sees a reference to, and the character styles
/// those references are written in.
struct DOCXNoteReferences {
    /// The `w:id` of each footnote the body refers to, in a run that was read.
    var footnotes: Set<String> = []
    /// The `w:id` of each endnote the body refers to.
    var endnotes: Set<String> = []
    /// The character styles (`w:rStyle`) of the runs that hold a reference: a
    /// note's own number is written in one, and is not a word.
    var runStyles: Set<String> = []
}

/// Markdown converted from a document's text part.
struct DOCXConversion {
    /// The notes the part refers to (empty for a notes part).
    let references: DOCXNoteReferences
    /// The document text: everything read from the part, up to any damage.
    let markdown: String
    /// Set when the part broke off or stopped being well-formed after some
    /// of its text had been read. That text is kept in `markdown`; this
    /// describes the damage so callers can report the document as
    /// incomplete. It never becomes part of the text.
    let diagnostic: DOCXParserError?
}

/// Converts the XML content of word/document.xml, or of a notes part
/// (word/footnotes.xml, word/endnotes.xml), into Markdown text.
/// Uses XMLParser (SAX-style) to walk through the document structure,
/// tracking paragraph styles, run formatting, and list context to emit
/// properly formatted Markdown.
class DOCXToMarkdownConverter: DOCXSAXParser {
    private let styles: DOCXStyles
    private let relationships: [String: String]

    // Output accumulation
    private var markdown = ""

    // Element stack for tracking nesting context
    private var elementStack: [String] = []

    /// How many records of tracked formatting changes (`w:pPrChange`,
    /// `w:rPrChange`, and the like) enclose the element being read. Inside
    /// one, properties are the formatting from before the change.
    private var trackedChangeDepth = 0

    /// One line of a paragraph (or of a link's label) as it is gathered. The
    /// words of the runs wait as raw text with the emphasis of each scalar, and
    /// are written as Markdown a whole stretch at a time (`commit()`), through
    /// `MarkdownEmphasis`, which never writes a delimiter that is read aloud: a
    /// run is not written apart from the runs that touch it, so bold "a" and
    /// bold "b" are one bold "ab", and white space or punctuation at a run's
    /// edge stays outside its delimiters. What cannot be part of a stretch (a
    /// page marker, a line break, a link) ends it: it is written to
    /// `committed` after the stretch before it.
    private struct StyledLine {
        /// The Markdown written so far.
        var committed = ""
        /// The words of the stretch in progress, as raw text.
        var raw = ""
        /// The emphasis of each Unicode scalar of `raw`.
        var styles: [MarkdownEmphasis.Style] = []

        /// Adds `text` in `style` to the stretch in progress.
        mutating func append(_ text: String, style: MarkdownEmphasis.Style) {
            raw += text
            styles.append(contentsOf: repeatElement(style, count: text.unicodeScalars.count))
        }

        /// Writes the stretch in progress as Markdown.
        mutating func commit() {
            guard !raw.isEmpty else { return }
            committed += MarkdownEmphasis.markdown(raw, styles: styles)
            raw = ""
            styles = []
        }

        /// Writes `markdown` after the stretch in progress, which it ends.
        mutating func appendFixed(_ markdown: String) {
            commit()
            committed += markdown
        }

        /// The whole line as Markdown.
        mutating func markdown() -> String {
            commit()
            return committed
        }

        /// Whether the line holds nothing but white space so far.
        var isBlank: Bool {
            raw.allSatisfy(\.isWhitespace) && committed.allSatisfy(\.isWhitespace)
        }

        /// The last character of the line so far.
        var last: Character? {
            raw.last ?? committed.last
        }
    }

    /// Everything the converter holds about the paragraph being read: the
    /// paragraph itself, the run and the link inside it, and the list the
    /// paragraph belongs to. One struct, so that a text box (whose paragraphs
    /// are paragraphs in the middle of another) sets the whole of it aside
    /// and takes it up again, and no field can be forgotten.
    private struct ParagraphState {
        // The paragraph (reset at each `w:p`)
        /// The paragraph's style ID (`w:pStyle`), empty for none.
        var style = ""
        /// The words gathered for the paragraph so far.
        var line = StyledLine()
        /// Whether any run has added content.
        var hasContent = false
        /// Whether a `w:p` is being read.
        var isOpen = false
        /// The list numbering the paragraph is in (`w:numId`), nil for none.
        var listNumId: String?
        /// The paragraph's level in its list (`w:ilvl`).
        var listLevel = 0
        /// The paragraph's own outline level (`w:outlineLvl` in its
        /// properties), which wins over its style's heading level.
        var outlineLevel: DOCXOutlineLevel?
        /// What the paragraph's own properties say about `w:pageBreakBefore`;
        /// nil when they say nothing, so its style decides.
        var pageBreakBefore: Bool?
        /// Whether the paragraph's properties hold a `w:sectPr`, which makes
        /// it the last paragraph of its section.
        var endsSection = false
        /// The markers of pages that begin at the paragraph, written as
        /// blocks before it when it ends, whatever the paragraph is.
        var leadingMarkers: [String] = []
        /// Whether the whitespace that begins the next words is dropped: set
        /// by a page `w:br`, cleared by the first words after it.
        var dropsLeadingWhitespace = false

        // The run (reset at each `w:r`)
        var isInRun = false
        var runIsBold = false
        var runIsItalic = false
        var runText = ""
        /// What the run's own properties say about hiding it (`w:vanish`);
        /// nil when they say nothing, so its styles decide.
        var runExplicitlyHidden: Bool?
        /// The run's character style (`w:rStyle`), empty for none.
        var runStyle = ""
        /// Whether the run being read is hidden: its text, line and page
        /// breaks, and tabs are not read, and begin no page. Follows the
        /// toggle rule of ECMA-376 17.7.3 (`updateRunHidden()`).
        var runIsHidden = false
        /// The pieces the run has been cut into at its page starts, in
        /// order. Empty for a run without one, which is formatted whole.
        var runPieces: [RunPiece] = []
        /// Whether the text of the run is a note's mark (a custom mark, or the
        /// number's run), which is not a word.
        var runSkipsText = false
        /// How many runs of the paragraph have begun.
        var runCount = 0
        /// Whether the paragraph is the first of its note.
        var isFirstOfNote = false
        /// Whether the paragraph begins a page that has not been started yet
        /// (`w:pageBreakBefore`). It is started with the first run that is
        /// read; a paragraph all of whose runs are unread begins none.
        var pageStartWaits = false
        /// Whether any run of the paragraph was read, and whether any was not.
        var hasReadRun = false
        var hasUnreadRun = false

        // The hyperlink
        var isInHyperlink = false
        var hyperlinkRelId = ""
        /// The label of the link being read.
        var linkLine = StyledLine()

        /// The text boxes anchored in this paragraph, finished, waiting for the
        /// paragraph to end (`writePendingBoxes`).
        var pendingBoxes: [FinishedBox] = []

        // The list
        /// Whether the paragraph before this one was a list item. Numbering
        /// starts again when a non-list paragraph interrupts a list.
        var previousWasList = false
        /// The list items open in the Markdown list being written, outermost
        /// first. A heading, paragraph, or table ends the list and empties it.
        var openListItems: [OpenListItem] = []
    }

    /// The paragraph being read.
    private var paragraph = ParagraphState()

    /// The paragraphs set aside while a text box inside them is read,
    /// outermost first.
    private var asideParagraphs: [ParagraphState] = []

    /// The tables being read, outermost first. A table inside a cell is read
    /// above the table holding it and, once finished, becomes part of that cell.
    private var tables: [TableInProgress] = []

    /// Numbers the list paragraphs from the package's list definitions.
    /// Its counts start again when a non-list paragraph interrupts a list.
    private var listCounter: DOCXListCounter

    /// Whether any readable text has been read. Damage after this point
    /// leaves text worth keeping; damage before it leaves none.
    private var producedText = false

    // MARK: Page state (PG07)

    /// Follows the document's pages and sections. Nil when pages are not
    /// included, and then no page logic runs at all: the Markdown is exactly
    /// what it was before pages.
    private var pageTracker: DOCXPageTracker?

    /// The marker of the last page that began inside the table being read,
    /// written as a block after the outermost table. Pages that begin in a
    /// table cannot be told apart in its Markdown, so they merge into one.
    private var tableTrailingMarker: String?

    /// How many deletions (`w:del`, `w:moveFrom`) enclose the element being
    /// read. A page break inside deleted text starts no page.
    private var deletionDepth = 0

    // MARK: Structure that is skipped or nested

    /// How deep inside a subtree that is not read the converter is: 0
    /// outside one. A subtree is skipped whole: an `mc:Choice` after the
    /// first, an `mc:Fallback` that follows a `mc:Choice`, or a note of the
    /// kind that is only a separator.
    private var ignoredDepth = 0

    /// For each `mc:AlternateContent` being read, outermost first, whether
    /// one of its choices has been read. Markup compatibility has a consumer
    /// read the first choice it understands and nothing else of the
    /// element: a text box is written as a `mc:Choice` and again in the
    /// `mc:Fallback` for older readers, and a listener must hear it once.
    private var alternateContentChoiceTaken: [Bool] = []

    /// Whether this converter reads the notes part (`word/footnotes.xml` or
    /// `word/endnotes.xml`): its text is never a heading, the notes that only
    /// separate the others are skipped, and so are the notes `noteIDs` (when
    /// given) does not list.
    private let readsNotes: Bool

    /// For a notes part: the `w:id` of the notes to read, those the body
    /// refers to; nil to read every note.
    private let noteIDs: Set<String>?

    /// For a notes part: the character styles the body's references are written
    /// in. The first run of a note, in one of them, holds the note's own mark.
    private let referenceStyles: Set<String>

    /// What the body refers to in the notes parts (collected by the text part's
    /// converter).
    private var references = DOCXNoteReferences()

    /// How many paragraphs of the note being read have begun.
    private var paragraphsOfNote = 0

    /// How many elements have been read, to look at whether the import was
    /// cancelled every so many of them.
    private var elementsRead = 0

    /// Whether the parse was stopped because the import was cancelled.
    private var wasCancelled = false

    /// How many elements are read between two looks at whether the import was
    /// cancelled: a thousand, which costs nothing measurable. Elements of the
    /// most attributes the guard lets through (1,024 each, 22,865 of them in
    /// 62 MB) took 8.5 s to read, so 4,096 between looks left Cancel waiting
    /// 1.5 s; a thousand leaves it under half a second.
    private static let elementsBetweenCancellationChecks = 1_024

    /// The text of a run before a page start inside it.
    private struct RunPiece {
        /// The run's text before the page start.
        let text: String
        /// Whether the page start is a `w:br`, which stood between two words.
        let joinsWords: Bool
    }

    /// Prepare to convert the text part `data`, read from `file`, with the
    /// package's paragraph styles, list numbering, and hyperlink targets.
    ///
    /// With `includesPages` the converter also writes a page marker where each
    /// page begins (PG07); without it the Markdown is what it was before
    /// pages. The sections, which tell where pages begin and how they are
    /// numbered, are read from `data` in a first pass.
    ///
    /// With `readsNotes` the part is a notes part, read for its notes: no
    /// paragraph of it is a heading, and only the notes `noteIDs` lists are
    /// read. `referenceStyles` are the character styles the body's references
    /// are written in.
    init(
        data: Data,
        file: String = DOCXParser.Part.document,
        styles: DOCXStyles,
        numbering: DOCXNumbering,
        relationships: [String: String],
        includesPages: Bool = false,
        readsNotes: Bool = false,
        noteIDs: Set<String>? = nil,
        referenceStyles: Set<String> = []
    ) {
        self.readsNotes = readsNotes
        self.noteIDs = noteIDs
        self.referenceStyles = referenceStyles
        self.styles = styles
        self.listCounter = DOCXListCounter(numbering: numbering)
        self.relationships = relationships
        self.pageTracker = includesPages
            ? DOCXPageTracker(sections: DOCXSections.read(from: data, file: file))
            : nil
        super.init(data: data, file: file)
    }

    /// Convert the part to Markdown.
    ///
    /// When the part breaks off or becomes malformed after some of its text
    /// was read, that text is kept: a document missing its last pages is
    /// more use read than refused. Elements still open at the damage are
    /// closed as though the part ended there, so the paragraph, link, or
    /// table in progress is written out with its emphasis and link syntax
    /// complete, none of it read aloud as symbols, and the damage is
    /// returned as the diagnostic.
    /// - Throws: `DOCXParserError.malformedXML` naming the part when it is
    ///   damaged before any text, and `ImportCancelled` when the import
    ///   running the conversion was cancelled.
    func convert() throws -> DOCXConversion {
        do {
            try parseDocument()
            return DOCXConversion(references: references, markdown: normalizeWhitespace(markdown), diagnostic: nil)
        } catch where wasCancelled {
            // The import was cancelled and the parse stopped for it
            throw ImportCancelled()
        } catch let damage as DOCXParserError where producedText {
            closeOpenElements()
            return DOCXConversion(references: references, markdown: normalizeWhitespace(markdown), diagnostic: damage)
        }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let localName = ParserUtilities.stripNamespacePrefix(elementName)
        elementStack.append(localName)

        // Cancel is heard while a very large part is parsed
        elementsRead += 1
        if elementsRead % Self.elementsBetweenCancellationChecks == 0, ImportCancellation.current?.isCancelled == true {
            wasCancelled = true
            parser.abortParsing()
            return
        }

        // A subtree that is not read is passed over whole, and the structure
        // that nests paragraphs or chooses between copies is settled before
        // anything is read from the element.
        if ignoredDepth > 0 {
            ignoredDepth += 1
            return
        }
        if beginsStructure(localName, attributes: attributes) == .skip {
            ignoredDepth = 1
            return
        }

        // Formatting from before a tracked change says nothing about the
        // text as it now stands: read as current, it would undo the change.
        if Self.recordsTrackedChange(localName) {
            trackedChangeDepth += 1
        }
        guard trackedChangeDepth == 0 else { return }

        switch localName {
        case "p":
            // Start of a paragraph -- reset paragraph state
            startParagraph()
        case "pPr":
            // Paragraph properties container -- handled via child elements
            break
        case "pageBreakBefore" where paragraph.isOpen:
            // The paragraph begins a page (PG07), unless it says val "off"
            paragraph.pageBreakBefore = DOCXOnOff.isOn(attributes["w:val"])
        case "sectPr" where paragraph.isOpen:
            // A section's properties inside a paragraph's: the paragraph ends the section
            paragraph.endsSection = true
        case "del", "moveFrom":
            deletionDepth += 1
        case "pStyle":
            // Paragraph style reference (e.g. "Heading1", "ListParagraph")
            paragraph.style = attributes["w:val"] ?? ""
        case "numPr":
            // List numbering properties -- handled via child elements
            break
        case "ilvl":
            // Word lists support nine levels. Malformed values must not reach
            // a level lookup or a potentially enormous indentation allocation.
            if let val = attributes["w:val"], let level = Int(val) {
                paragraph.listLevel = DOCXNumbering.levelIndexes.contains(level) ? level : 0
            }
        case "numId":
            // List numbering definition ID
            let val = attributes["w:val"] ?? "0"
            if val != "0" {
                paragraph.listNumId = val
            }
        case "outlineLvl":
            // The paragraph's own outline level: a heading level, or body text
            if let outline = DOCXOutlineLevel(attributes["w:val"]) {
                paragraph.outlineLevel = outline
            }
        case "r":
            // Start of a text run -- reset run formatting state
            startRun()
        case "rPr":
            // Run properties container
            break
        case "rStyle" where paragraph.isInRun:
            // The run's character style, which may hide its text
            paragraph.runStyle = attributes["w:val"] ?? ""
            updateRunHidden()
            // The first run of a note, in the style the references are in, is
            // its mark
            if readsNotes && paragraph.isFirstOfNote && paragraph.runCount == 1 && referenceStyles.contains(paragraph.runStyle) {
                paragraph.runSkipsText = true
            }
        case "vanish" where paragraph.isInRun:
            // Hidden text: not read. Direct formatting wins over the styles.
            // (`w:webHidden`, hidden only on the web, stays read, and
            // `w:specVanish` and a paragraph mark's `w:vanish` hide no run.)
            paragraph.runExplicitlyHidden = DOCXOnOff.isOn(attributes["w:val"])
            updateRunHidden()
        case "b" where paragraph.isInRun:
            // Bold formatting. Check for w:val="0" which means explicitly NOT bold.
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" {
                paragraph.runIsBold = true
            }
        case "i" where paragraph.isInRun:
            // Italic formatting
            let val = attributes["w:val"] ?? "true"
            if val != "0" && val != "false" {
                paragraph.runIsItalic = true
            }
        // Strikethrough (`w:strike`) is written as plain text: a struck word is
        // read as it is, and a "~~" that is not paired would be read aloud.
        case "footnoteReference", "endnoteReference":
            // A reference a person who reads the body sees: its note is read,
            // and the note's mark, if it is custom, follows in this run and is
            // not a word
            if paragraph.isInRun && !runIsUnread, let id = attributes["w:id"] {
                if localName == "footnoteReference" {
                    references.footnotes.insert(id)
                } else {
                    references.endnotes.insert(id)
                }
                if !paragraph.runStyle.isEmpty { references.runStyles.insert(paragraph.runStyle) }
                if let custom = attributes["w:customMarkFollows"], DOCXOnOff.isOn(custom) {
                    paragraph.runSkipsText = true
                }
            }
        case "footnoteRef", "endnoteRef":
            // The note's own number: whatever else its run holds is its mark
            if paragraph.isInRun { paragraph.runSkipsText = true }
        case let name where (name == "br" || name == "cr") && paragraph.isInRun && !runIsUnread:
            // Keep breaks in their run; the paragraph has not received the
            // preceding run text yet, so appending there reverses their order.
            // (`w:cr` is a carriage return: a line break, as `w:br` is.)
            if pageTracker != nil && name == "br" && attributes["w:type"] == "page" {
                // A page break starts a page where it stands (PG07). The
                // words around it are kept apart by the marker, not a newline.
                cutRun(joinsWords: true)
            } else if name == "br" && attributes["w:type"] == "page" && lineEndsWithBreak {
                // Where there are no pages a page break is a line break, but not a
                // blank line after the line break that is already there (it would
                // split the paragraph; with pages the same two breaks are one)
            } else {
                paragraph.runText += "\n"
            }
        case "lastRenderedPageBreak" where paragraph.isInRun && !runIsUnread && pageTracker != nil:
            // Where Word's last layout put a page (PG07); no text of its own
            cutRun(joinsWords: false)
        case "tab" where paragraph.isInRun && !runIsUnread:
            paragraph.runText += "\t"
        case "noBreakHyphen" where paragraph.isInRun && !runIsUnread:
            // The same character RTF's `\_` gives
            paragraph.runText += "-"
        case "hyperlink":
            // A page that began before the link begins before its words, not
            // inside the label (PG07)
            startWaitingPage()
            placePendingPage()
            // Start of a hyperlink -- capture the relationship ID for the URL
            paragraph.isInHyperlink = true
            paragraph.hyperlinkRelId = attributes["r:id"] ?? ""
            paragraph.linkLine = StyledLine()
        case "tblStyle" where elementStack.suffix(3) == ["tbl", "tblPr", "tblStyle"] && !tables.isEmpty:
            // The innermost table's style, which may hide its text (not the
            // style of a record of a change, which is nested deeper)
            tables[tables.count - 1].style = attributes["w:val"] ?? ""
        case "tbl":
            // A table may begin a section, and a page pending when an
            // outermost one begins is written before it (PG07)
            pageTracker?.beginBlock()
            writePendingPageAsBlock()
            // Start of a table, at the top level or inside a cell
            tables.append(TableInProgress())
        case "tr":
            // Table row
            startTableRow()
        case "tc":
            // Table cell
            startTableCell()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        // Only capture text inside <w:t> elements (handled by element context),
        // and not in a subtree that is skipped, in a hidden run, or in text a
        // tracked change deleted or moved away (its words are read once, where
        // they were moved to)
        if ignoredDepth == 0, !runIsUnread, !paragraph.runSkipsText, let lastElement = elementStack.last, lastElement == "t" {
            paragraph.runText += string
            if !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                producedText = true
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        endElement(ParserUtilities.stripNamespacePrefix(elementName))
    }

    /// Close every element the damage left open, innermost first, exactly as
    /// their end tags would have: the run, any link, the paragraph, and any
    /// table around it are finished and written out.
    ///
    /// The run in progress first loses the whitespace at its cut end, which
    /// separated the last word read from one that never arrived.
    private func closeOpenElements() {
        if paragraph.isInRun {
            while paragraph.runText.last?.isWhitespace == true {
                paragraph.runText.removeLast()
            }
        }
        while let innermost = elementStack.last {
            endElement(innermost)
        }
    }

    /// Emit the Markdown that ends the element named `localName` (without
    /// its namespace prefix) and pop it from the element stack.
    private func endElement(_ localName: String) {
        defer {
            if !elementStack.isEmpty {
                elementStack.removeLast()
            }
        }

        // The end of a skipped subtree, or of structure that nested or chose
        // (`beginsStructure`), is settled before anything else.
        if ignoredDepth > 0 {
            ignoredDepth -= 1
            return
        }
        endsStructure(localName)

        // Inside a tracked change's record nothing started as content, so
        // nothing ends as content either; only the record itself closes.
        if trackedChangeDepth > 0 {
            if Self.recordsTrackedChange(localName) {
                trackedChangeDepth -= 1
            }
            return
        }

        switch localName {
        case "r":
            // End of a text run -- apply formatting and append to paragraph text
            endRun()
        case "pPr":
            // The paragraph's properties are complete: its style and its own
            // page break are known (PG07)
            startPageIfParagraphBreaksBefore()
        case "del", "moveFrom":
            deletionDepth = max(0, deletionDepth - 1)
        case "p":
            // End of a paragraph -- emit the accumulated text with proper formatting
            endParagraph()
            endSectionIfParagraphEndedIt()
        case "hyperlink":
            // End of hyperlink -- emit Markdown link
            endHyperlink()
        case "tbl":
            // End of table -- written out, or kept in the cell holding it
            endTable()
        case "tr":
            // End of table row
            endTableRow()
        case "tc":
            // End of table cell
            endTableCell()
        default:
            break
        }
    }

    /// Whether the element named `localName` records a tracked formatting
    /// change: `w:pPrChange`, `w:rPrChange`, `w:sectPrChange`, the table
    /// property changes, and `w:numberingChange`. Each holds the properties
    /// as they were before the change, and never any text.
    private static func recordsTrackedChange(_ localName: String) -> Bool {
        localName.hasSuffix("Change")
    }

    // MARK: - Skipped and Nested Structure

    /// What to do with an element that has begun.
    private enum StructureAction {
        /// Read it as usual.
        case read
        /// Pass over it and everything in it.
        case skip
    }

    /// The namespace prefixes of a `mc:Choice`'s `Requires` whose content the
    /// reader finds by element name: the text boxes of word processing shapes
    /// (`wps`), of their groups (`wpg`), and of their canvases (`wpc`); in the
    /// LibreOffice test documents these are the only ones whose choices hold
    /// words. It is not a list of what the reader cannot read: a prefix it has
    /// never heard of must send the reader to the fallback, which older readers
    /// get (a typed emoji is a `w16se:symEx` choice and the character itself in
    /// the fallback).
    private static let understoodPrefixes: Set<String> = ["wps", "wpg", "wpc"]

    /// Whether every prefix in `requires` (a `mc:Choice`'s attribute: prefixes
    /// separated by white space) is one the reader understands.
    private func understands(requires: String?) -> Bool {
        let prefixes = (requires ?? "").split(whereSeparator: \.isWhitespace)
        return prefixes.allSatisfy { Self.understoodPrefixes.contains(String($0)) }
    }

    /// The `w:type` values of a note that only separates the others, or
    /// notices a note continued on the next page: not notes of the document.
    private static let separatorNoteTypes: Set<String> = ["separator", "continuationSeparator", "continuationNotice"]

    /// Settles the structure the element `localName` begins, before its
    /// content is read:
    /// - `mc:AlternateContent` holds copies of the same content for readers
    ///   of different ages, and only the first `mc:Choice` is read: the later
    ///   choices and the `mc:Fallback` are skipped, so a text box written in
    ///   both is heard once;
    /// - a separator note of the notes part is skipped;
    /// - a text box (`w:txbxContent`) holds paragraphs in the middle of
    ///   another, so the paragraph and run around it are set aside.
    private func beginsStructure(_ localName: String, attributes: [String: String]) -> StructureAction {
        // The element's parent: the element before it on the stack.
        let parent = elementStack.dropLast().last
        switch localName {
        case "AlternateContent":
            alternateContentChoiceTaken.append(false)
        case "Choice" where parent == "AlternateContent":
            // The first choice whose every required prefix the reader
            // understands is read; any other choice is passed over, so the next
            // one, or at last the fallback, can be read instead.
            if alternateContentChoiceTaken.last == true || !understands(requires: attributes["Requires"]) { return .skip }
            if !alternateContentChoiceTaken.isEmpty { alternateContentChoiceTaken[alternateContentChoiceTaken.count - 1] = true }
        case "Fallback" where parent == "AlternateContent":
            if alternateContentChoiceTaken.last == true { return .skip }
        case "footnote", "endnote":
            guard readsNotes else { break }
            // A separator is not a note, and a note no read reference points
            // to is one nobody sees
            if Self.separatorNoteTypes.contains(attributes["w:type"] ?? "") { return .skip }
            if let noteIDs, !noteIDs.contains(attributes["w:id"] ?? "") { return .skip }
            paragraphsOfNote = 0
        case "txbxContent":
            // A text box anchored in text nobody reads is not read
            if runIsUnread { return .skip }
            startBox()
        default:
            break
        }
        return .read
    }

    /// Undoes what `beginsStructure` set up when the element ends.
    private func endsStructure(_ localName: String) {
        switch localName {
        case "AlternateContent":
            _ = alternateContentChoiceTaken.popLast()
        case "txbxContent":
            endBox()
        default:
            break
        }
    }

    /// A text box's text, finished: Markdown for a box read in the page's
    /// flow, or the text of its paragraphs for one inside a table cell.
    private struct FinishedBox {
        var markdown: String
        var texts: [String]?

        /// Whether the box holds a character other than white space, so that
        /// a page that waits begins at it.
        var hasWords: Bool {
            markdown.contains { !$0.isWhitespace } || (texts?.contains { $0.contains { !$0.isWhitespace } } ?? false)
        }
    }

    /// What the converter held outside a text box while the box is read.
    private struct OutsideBox {
        var markdown: String
        var tables: [TableInProgress]
        var pageTracker: DOCXPageTracker?
        var capture: [String]?
        var tableTrailingMarker: String?
    }
    private var outsideBoxes: [OutsideBox] = []

    /// While a text box is read inside a table cell (or inside another such
    /// box), the text of its paragraphs: a cell holds text, not blocks.
    /// Nil otherwise.
    private var capture: [String]?

    /// A text box begins. Its paragraphs are paragraphs in the middle of
    /// another, so the paragraph being read is set aside, whole, and the box
    /// is read as a document of its own: into a side buffer, in no table, and
    /// with no pages (a page that begins inside a floating box is not a page
    /// of the document, and the page pending before the box must wait for the
    /// words after it). When the box ends its text waits for the end of the
    /// paragraph that holds its anchor and is written right after it.
    private func startBox() {
        asideParagraphs.append(paragraph)
        paragraph = ParagraphState()
        outsideBoxes.append(OutsideBox(
            markdown: markdown, tables: tables, pageTracker: pageTracker,
            capture: capture, tableTrailingMarker: tableTrailingMarker
        ))
        let insideCell = !tables.isEmpty || capture != nil
        markdown = ""
        tables = []
        pageTracker = nil
        tableTrailingMarker = nil
        capture = insideCell ? [] : nil
    }

    /// The text box ends: what the converter held is taken up again, and the
    /// box's text is left with the paragraph that holds its anchor.
    private func endBox() {
        guard let outside = outsideBoxes.popLast(), let anchor = asideParagraphs.popLast() else { return }
        let finished = FinishedBox(markdown: markdown, texts: capture)
        markdown = outside.markdown
        tables = outside.tables
        pageTracker = outside.pageTracker
        capture = outside.capture
        tableTrailingMarker = outside.tableTrailingMarker
        paragraph = anchor
        paragraph.pendingBoxes.append(finished)
    }

    /// Writes the text boxes anchored in the paragraph that has just ended,
    /// after it: in the cell the paragraph is in, in the box it is in, or as
    /// blocks of the page's flow. A list the paragraph was in is ended by
    /// them. A page still pending (the paragraph held no words of its own)
    /// begins at the first box that has words, as it would at the paragraph's.
    private func writePendingBoxes() {
        let boxes = paragraph.pendingBoxes
        guard !boxes.isEmpty else { return }
        paragraph.pendingBoxes = []
        for box in boxes {
            if box.hasWords { placePendingPageBeforeBox() }
            if let texts = box.texts {
                for text in texts {
                    if !tables.isEmpty {
                        appendToTable(.text(text))
                    } else {
                        capture?.append(text)
                    }
                }
            } else {
                paragraph.openListItems.removeAll()
                markdown += box.markdown
            }
        }
    }

    // MARK: - Paragraph Processing

    /// Reset state for a new paragraph
    private func startParagraph() {
        paragraph.isOpen = true
        paragraph.style = ""
        paragraph.line = StyledLine()
        paragraph.hasContent = false
        paragraph.listNumId = nil
        paragraph.listLevel = 0
        paragraph.outlineLevel = nil
        paragraph.pageBreakBefore = nil
        paragraph.endsSection = false
        paragraph.leadingMarkers = []
        paragraph.dropsLeadingWhitespace = false
        paragraph.runCount = 0
        paragraph.pageStartWaits = false
        paragraph.hasReadRun = false
        paragraph.hasUnreadRun = false
        paragraph.isFirstOfNote = readsNotes && paragraphsOfNote == 0
        if readsNotes { paragraphsOfNote += 1 }
        // The first paragraph of a section may begin a page (PG07)
        pageTracker?.beginBlock()
    }

    /// The heading level of the paragraph being read: its own outline
    /// level when it declares one, which wins over its style's as direct
    /// formatting does in Word, so a paragraph marked as body text is no
    /// heading whatever its style; otherwise its style's heading level.
    private var paragraphHeadingLevel: Int? {
        // A note's text is never a heading, whatever its style says.
        if readsNotes { return nil }
        if let outline = paragraph.outlineLevel {
            return outline.headingLevel
        }
        return styles.headingLevels[paragraph.style]
    }

    /// The paragraph ends: its Markdown is written, and then the text boxes
    /// anchored in it.
    private func endParagraph() {
        // A paragraph that holds runs, none of them read, begins no page; one
        // with no run at all still begins its page
        if !(paragraph.hasUnreadRun && !paragraph.hasReadRun) { startWaitingPage() }
        writeParagraph()
        writePendingBoxes()
    }

    /// Emit the completed paragraph as Markdown
    private func writeParagraph() {
        let text = Self.removingLineIndentation(paragraph.line.markdown().trimmingCharacters(in: .whitespaces))

        // Inside a table, the paragraph's words belong to the cell being read
        if !tables.isEmpty {
            if !text.isEmpty {
                appendToTable(.text(text))
            }
            paragraph.isOpen = false
            return
        }

        // In a text box that sits in a cell the paragraphs are only text
        if capture != nil {
            if !text.isEmpty {
                capture?.append(text)
            }
            paragraph.isOpen = false
            return
        }

        // Pages that began at this paragraph are blocks before it (PG07)
        writeLeadingPageMarkers()

        // Handle empty paragraphs (just add a blank line)
        guard !text.isEmpty else {
            markdown += "\n"
            paragraph.isOpen = false
            return
        }

        // Determine if this paragraph is a list item
        let isListParagraph = paragraph.listNumId != nil
            || styles.bulletListStyles.contains(paragraph.style)
            || styles.numberedListStyles.contains(paragraph.style)

        // TextMouth's policy for a list interrupted by other text: every
        // list starts again from its start value afterwards. (Word would
        // continue the list's count; DOCXEdgeCaseTests pins this policy.)
        if !isListParagraph && paragraph.previousWasList {
            listCounter.restartAll()
        }
        paragraph.previousWasList = isListParagraph

        // Check if this paragraph is a heading
        if let headingLevel = paragraphHeadingLevel {
            let prefix = String(repeating: "#", count: headingLevel)
            paragraph.openListItems.removeAll()
            markdown += "\n\(prefix) \(text)\n\n"
        }
        // Check if this paragraph is a list item (via numPr or list style)
        else if let numId = paragraph.listNumId {
            writeListItem(text, level: paragraph.listLevel, marker: listCounter.marker(numId: numId, level: paragraph.listLevel))
        }
        // Style-based list detection (e.g. "ListBullet", "ListNumber" styles)
        else if styles.bulletListStyles.contains(paragraph.style) {
            writeListItem(text, level: 0, marker: .bullet)
        }
        else if styles.numberedListStyles.contains(paragraph.style) {
            writeListItem(text, level: 0, marker: listCounter.marker(numberedStyle: paragraph.style))
        }
        // Regular paragraph
        else {
            paragraph.openListItems.removeAll()
            markdown += "\n\(text)\n"
        }

        paragraph.isOpen = false
    }

    /// `text` without the spaces and tabs that begin its lines after the
    /// first. A line break in a paragraph (`w:br`) starts a new Markdown
    /// line, and after a blank line four spaces there begin a code block,
    /// which is read verbatim, the backslashes that keep its characters
    /// literal read aloud with them. Indentation is never heard, so leaving
    /// it out loses nothing. A page marker (PG07) that follows a line break
    /// is written at the end of the line before (`MarkdownMarkerWriter`), so
    /// no line begins with one.
    private static func removingLineIndentation(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var atLineStart = false
        var index = text.unicodeScalars.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if atLineStart && (scalar == " " || scalar == "\t") {
                // The whole indentation of this line is dropped.
                while index < scalars.endIndex, scalars[index] == " " || scalars[index] == "\t" {
                    index = scalars.index(after: index)
                }
                atLineStart = false
                continue
            }
            // CommonMark ends a line at a carriage return as well.
            atLineStart = scalar == "\n" || scalar == "\r"
            result.append(scalar)
            index = scalars.index(after: index)
        }
        return String(result)
    }

    // MARK: - List Items

    /// A list item open in the Markdown being written: the items after it
    /// nest inside it or continue its list.
    private struct OpenListItem {
        /// The level (`w:ilvl`) of the paragraph it holds.
        let level: Int
        /// The spaces before its marker.
        let indent: Int
        /// The column where its text begins, which a nested item must reach.
        let contentColumn: Int
        /// Whether it is numbered: an item at its depth continues its
        /// Markdown list only when the two are both numbered or both bulleted.
        let isNumbered: Bool
    }

    /// Write a list item reading `text` at list level `level` after `marker`.
    ///
    /// The item nests one step inside the nearest open item of a shallower
    /// level, so a list that skips a level (an item at level 2 straight
    /// after one at level 0), or begins below level 0, still reads as a list
    /// rather than drifting far enough right to become a code block or a line
    /// of the paragraph above, whose words would then include its bullet or
    /// number. It is indented four spaces past its parent's marker, or to
    /// the parent's text when that marker is wider, which keeps it inside
    /// the parent's text (CommonMark §5.2).
    ///
    /// A numbered item that begins a new list at a number other than 1 is
    /// written after a blank line: CommonMark lets only a list starting at 1
    /// interrupt a paragraph, so otherwise its number would be read aloud as
    /// words of the paragraph before it.
    private func writeListItem(_ text: String, level: Int, marker: DOCXListMarker) {
        // Items at this level or deeper are finished. The last of them to
        // close stood at this item's depth, in the list this item continues
        // when both are numbered or both bulleted.
        var previousAtDepth: OpenListItem?
        while let innermost = paragraph.openListItems.last, innermost.level >= level {
            previousAtDepth = paragraph.openListItems.removeLast()
        }
        let parent = paragraph.openListItems.last
        let indent = parent.map { max($0.indent + 4, $0.contentColumn) } ?? 0

        let markerText: String
        switch marker {
        case .bullet:
            markerText = "- "
        case .number(let number):
            markerText = "\(number). "
            if number != 1 && previousAtDepth?.isNumbered != true {
                ensureBlankLine()
            }
        }
        markdown += String(repeating: " ", count: indent) + markerText + text + "\n"
        paragraph.openListItems.append(OpenListItem(
            level: level,
            indent: indent,
            contentColumn: indent + markerText.count,
            isNumbered: marker != .bullet
        ))
    }

    /// End the Markdown with a blank line, so the next block cannot be read
    /// as part of the block before it. Nothing is written at the start, or
    /// when the Markdown already ends with a blank line. Unicode scalars
    /// decide, because a carriage return before a line feed forms a single
    /// Character that a Character comparison with "\n" would not match.
    private func ensureBlankLine() {
        guard !markdown.isEmpty else { return }
        let ending = markdown.unicodeScalars.suffix(2)
        guard !ending.elementsEqual(["\n", "\n"]) else { return }
        markdown += ending.last == "\n" ? "\n" : "\n\n"
    }

    // MARK: - Run Processing

    /// Reset state for a new text run
    private func startRun() {
        paragraph.isInRun = true
        paragraph.runIsBold = false
        paragraph.runIsItalic = false
        paragraph.runText = ""
        paragraph.runExplicitlyHidden = nil
        paragraph.runStyle = ""
        paragraph.runSkipsText = false
        paragraph.runCount += 1
        updateRunHidden()
    }

    /// Whether the line being gathered (the paragraph, or the label of the link
    /// being read) ends with a line break, the run in progress included.
    private var lineEndsWithBreak: Bool {
        if let last = paragraph.runText.last { return last == "\n" }
        let line = paragraph.isInHyperlink ? paragraph.linkLine : paragraph.line
        return line.last == "\n"
    }

    /// Whether the run being read is read by nobody: hidden, or inside text a
    /// tracked change deleted or moved away (`w:del`, `w:moveFrom`). Its text,
    /// tabs, breaks, hyphens, page breaks, and any text box anchored in it are
    /// left out.
    private var runIsUnread: Bool {
        paragraph.runIsHidden || deletionDepth > 0
    }

    /// Settle whether the run being read is hidden, by its own toggle alone:
    /// a run's levels (its table style, paragraph style, and character style),
    /// the document defaults, and its own `w:vanish`, by the rule of
    /// `DOCXHiding`. A row marked hidden (`w:trPr/w:hidden`) hides nothing of
    /// its own: ECMA-376 section 17.4.20 hides the glyph of the row's end
    /// marker, "to ensure that the entire table row is hidden and not
    /// displayed in the document, as if any part of the row is visible, the
    /// row is displayed". The clause's example says the row is not displayed,
    /// so it is not clean, and nothing here has been checked in Word itself.
    /// Called at the start of the run and again as its style and `w:vanish`
    /// are read, which come before any of its text.
    private func updateRunHidden() {
        // A paragraph that names no style takes the default paragraph style,
        // and a table that names none the default table style.
        let paragraphStyle = paragraph.style.isEmpty ? (styles.defaultParagraphStyle ?? "") : paragraph.style
        let tableStyle = tables.last.map { $0.style.isEmpty ? (styles.defaultTableStyle ?? "") : $0.style } ?? ""
        paragraph.runIsHidden = DOCXHiding.isHidden(
            documentDefaults: styles.documentDefaultsHiding,
            table: styles.tableHiding[tableStyle],
            paragraph: styles.paragraphHiding[paragraphStyle],
            character: styles.characterHiding[paragraph.runStyle],
            direct: paragraph.runExplicitlyHidden
        )
    }

    /// Apply formatting to the run text and append to paragraph
    private func endRun() {
        guard paragraph.isInRun else { return }
        paragraph.isInRun = false
        if runIsUnread {
            paragraph.hasUnreadRun = true
        } else {
            paragraph.hasReadRun = true
            startWaitingPage()
        }
        paragraph.runIsHidden = false

        // A run with a page start inside it is written piece by piece, a
        // page beginning after each piece (PG07). Any other run is one piece.
        let pieces = paragraph.runPieces
        paragraph.runPieces = []
        for piece in pieces {
            appendRunText(piece.text)
            pageTracker?.startPage(joinsWords: piece.joinsWords)
            if piece.joinsWords {
                paragraph.dropsLeadingWhitespace = true
                separateWordsAroundPageBreak()
            }
        }
        appendRunText(paragraph.runText)
    }

    /// Adds `piece`, a run or a piece of one, to the paragraph (or to the
    /// hyperlink label being read) in the run's emphasis. A page that has begun
    /// is written first when `piece` holds a word.
    private func appendRunText(_ piece: String) {
        // After a page `w:br` the whitespace that begins the next words is
        // dropped: one space separates the words on either side of the break,
        // written with the marker (or in the link label), as the newline the
        // break used to be read as a single space.
        var text = piece
        if paragraph.dropsLeadingWhitespace {
            text = String(text.drop(while: \.isWhitespace))
            if !text.isEmpty {
                paragraph.dropsLeadingWhitespace = false
            }
        }
        guard !text.isEmpty else { return }

        // A page that has begun is marked before the first word that follows
        // it (PG07). Inside a hyperlink's label no marker is written: the
        // page waits for the text after the link. A marker that joins words
        // (a page `w:br`) brings the space between them, so the whitespace
        // that begins this text is dropped.
        if !paragraph.isInHyperlink && pageTracker?.isPending == true && text.contains(where: { !$0.isWhitespace }),
           placePendingPage() {
            text = String(text.drop(while: \.isWhitespace))
        }

        // The run's characters are written as Markdown literals, so each is
        // read exactly as written, as plain text and HTML are (TODO T02,
        // T03): an asterisk, underscore, number sign, or bracket is never
        // taken for emphasis, a heading, a list, or a link, and quotes,
        // dashes, and ellipses are not turned typographic (`MarkdownEmphasis`
        // writes every stretch through `MarkdownLiteral`). A line break ends
        // the stretch; tabs are not punctuation, so they pass through.
        var style = MarkdownEmphasis.Style()
        if paragraph.runIsBold { style.insert(.strong) }
        if paragraph.runIsItalic { style.insert(.emphasis) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, words) in lines.enumerated() {
            if index > 0 { appendFixed("\n") }
            if !words.isEmpty { appendStyled(String(words), style) }
        }
        paragraph.hasContent = true
    }

    /// Adds `text` in `style` to the line being gathered: the label of the link
    /// being read, or the paragraph.
    private func appendStyled(_ text: String, _ style: MarkdownEmphasis.Style) {
        if paragraph.isInHyperlink {
            paragraph.linkLine.append(text, style: style)
        } else {
            paragraph.line.append(text, style: style)
        }
    }

    /// Adds `markdown` to the line being gathered, ending the stretch of runs
    /// before it.
    private func appendFixed(_ markdown: String) {
        if paragraph.isInHyperlink {
            paragraph.linkLine.appendFixed(markdown)
        } else {
            paragraph.line.appendFixed(markdown)
        }
    }

    // MARK: - Hyperlink Processing

    /// Emit a completed hyperlink as Markdown
    private func endHyperlink() {
        guard paragraph.isInHyperlink else { return }
        paragraph.isInHyperlink = false

        var label = paragraph.linkLine
        paragraph.linkLine = StyledLine()
        let text = label.markdown().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let target = relationships[paragraph.hyperlinkRelId], !target.isEmpty {
            // Escape parentheses in URLs to avoid breaking markdown link syntax
            let escapedTarget = target
                .replacingOccurrences(of: "(", with: "%28")
                .replacingOccurrences(of: ")", with: "%29")
            paragraph.line.appendFixed("[\(text)](\(escapedTarget))")
        } else {
            // No URL found -- just emit the text
            paragraph.line.appendFixed(text)
        }
        paragraph.hasContent = true
    }

    // MARK: - Table Processing

    /// What a table cell holds, in reading order: the text of its paragraphs,
    /// and any tables nested in it.
    private enum CellContent {
        case text(String)
        case table(ReadTable)
    }

    /// A table read from the document.
    private struct ReadTable {
        /// One cell: the text and nested tables it holds, in reading order.
        typealias Cell = [CellContent]
        /// One row: its cells, in reading order.
        typealias Row = [Cell]

        var rows: [Row] = []
        /// Whether a cell holds a table, which a Markdown table cannot hold.
        var nestsTables = false
    }

    /// A table being read: the table so far, and its row and cell in progress.
    private struct TableInProgress {
        var table = ReadTable()
        var row: ReadTable.Row?
        var cell: ReadTable.Cell?
        /// The table's style (`w:tblStyle`), empty when it names none.
        var style = ""
    }

    /// Start a row in the innermost table, finishing any row left open.
    private func startTableRow() {
        guard !tables.isEmpty else { return }
        endTableRow()
        tables[tables.count - 1].row = []
    }

    /// Start a cell in the innermost table's row in progress, finishing any
    /// cell left open. A cell outside any row is not started; its text is
    /// still kept in reading order (see `appendToTable(_:)`).
    private func startTableCell() {
        guard let innermost = tables.indices.last, tables[innermost].row != nil else { return }
        endTableCell()
        tables[innermost].cell = []
    }

    /// Finish the innermost table's cell in progress, adding it to its row.
    private func endTableCell() {
        guard let innermost = tables.indices.last, let cell = tables[innermost].cell else { return }
        tables[innermost].row?.append(cell)
        tables[innermost].cell = nil
    }

    /// Finish the innermost table's row in progress, and any cell left open
    /// in it, adding the row to its table.
    private func endTableRow() {
        guard let innermost = tables.indices.last else { return }
        endTableCell()
        if let row = tables[innermost].row {
            tables[innermost].table.rows.append(row)
            tables[innermost].row = nil
        }
    }

    /// Finish the innermost table, and any row left open in it. A table
    /// inside a cell becomes part of that cell; an outermost table is
    /// written out.
    private func endTable() {
        guard !tables.isEmpty else { return }
        endTableRow()
        let finished = tables.removeLast().table
        if tables.isEmpty {
            if capture != nil {
                capture?.append(contentsOf: Self.rowParagraphs(of: finished))
            } else {
                writeTable(finished)
                writeTrailingTableMarker()
            }
        } else {
            appendToTable(.table(finished))
        }
    }

    /// Add `content` to the innermost table where reading has reached: to
    /// its cell in progress, or else as a cell of its own in the row in
    /// progress, or else as a row of its own. Content a malformed table
    /// holds outside its cells thus keeps its place in reading order.
    private func appendToTable(_ content: CellContent) {
        guard let innermost = tables.indices.last else { return }
        if case .table = content {
            tables[innermost].table.nestsTables = true
        }
        if tables[innermost].cell != nil {
            tables[innermost].cell?.append(content)
        } else if tables[innermost].row != nil {
            tables[innermost].row?.append([content])
        } else {
            tables[innermost].table.rows.append([[content]])
        }
    }

    /// Write a finished outermost table, which ends any list before it. A
    /// table of text cells is written as a Markdown table, as it always has
    /// been. A Markdown table cannot hold a table in a cell, so a table that
    /// nests one is written as paragraphs instead.
    private func writeTable(_ table: ReadTable) {
        let written = table.nestsTables ? Self.paragraphMarkdown(of: table) : Self.markdownTable(of: table)
        guard let written else { return }
        paragraph.openListItems.removeAll()
        markdown += written
    }

    /// A table of text cells as a Markdown table, its first row the header
    /// and every row padded to the widest; nil when it has no cells.
    private static func markdownTable(of table: ReadTable) -> String? {
        let rows = table.rows.map { row in row.map(cellText) }

        // A table in which no cell holds a word (every word hidden, say) is not
        // written
        guard rows.contains(where: { $0.contains { !$0.isEmpty } }) else { return nil }

        // Determine column count from the widest row
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else { return nil }

        var written = "\n"
        for (rowIndex, row) in rows.enumerated() {
            // Pad rows to consistent column count
            let cells = row + Array(repeating: "", count: columnCount - row.count)
            written += "| " + cells.joined(separator: " | ") + " |\n"

            // Add header separator after first row
            if rowIndex == 0 {
                written += "| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |\n"
            }
        }
        return written + "\n"
    }

    /// The text of a cell of a Markdown table: the text of its paragraphs,
    /// joined by spaces and trimmed. A table row is one line of Markdown, so
    /// a line break inside a paragraph (`w:br`) is a space here: a newline
    /// would end the row, and the rest of the cell would be read as a row of
    /// its own, after a pipe the listener would hear.
    private static func cellText(_ cell: ReadTable.Cell) -> String {
        cell.compactMap { content -> String? in
            if case .text(let text) = content {
                return text
            }
            return nil
        }
        .flatMap { $0.split(whereSeparator: \.isNewline) }
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A table that holds tables, as paragraphs (see `rowParagraphs(of:)`)
    /// separated by blank lines; nil when it holds no words.
    private static func paragraphMarkdown(of table: ReadTable) -> String? {
        let paragraphs = rowParagraphs(of: table)
        guard !paragraphs.isEmpty else { return nil }
        return "\n" + paragraphs.map { $0 + "\n" }.joined(separator: "\n") + "\n"
    }

    /// The paragraphs `table` reads as, by the rule HTML tables are read by
    /// (TODO T03), applied at every depth: each row is one paragraph of its
    /// cells' words joined by spaces, so no two cells' words run together. A
    /// table nested in a cell puts its own rows, each a paragraph, between
    /// the words of its row that come before it and those after it, so all
    /// of it reads in source order and its rows stay apart from the row
    /// holding it.
    private static func rowParagraphs(of table: ReadTable) -> [String] {
        var paragraphs: [String] = []
        for row in table.rows {
            var words: [String] = []
            for content in row.joined() {
                switch content {
                case .text(let text):
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        words.append(trimmed)
                    }
                case .table(let nested):
                    if !words.isEmpty {
                        paragraphs.append(words.joined(separator: " "))
                        words = []
                    }
                    paragraphs += rowParagraphs(of: nested)
                }
            }
            if !words.isEmpty {
                paragraphs.append(words.joined(separator: " "))
            }
        }
        return paragraphs
    }

    // MARK: - Whitespace Normalization

    /// Clean up the generated Markdown: collapse excessive blank lines,
    /// trim trailing whitespace from lines
    private func normalizeWhitespace(_ text: String) -> String {
        ParserUtilities.normalizeMarkdownWhitespace(text)
    }
}

// MARK: - Pages (PG07)

/// Where each page begins, and the marker written there (`<!-- page: 12 -->`).
/// A page start only sets a page pending (`DOCXPageTracker`); the marker is
/// written before the next text that is not whitespace, so a page break with
/// nothing after it, or merged with another, writes one marker or none. A
/// marker adds no reading text and never begins a line (`MarkdownMarkerWriter`).
extension DOCXToMarkdownConverter {

    /// Cut the run being read at a page start inside it: the text read so far
    /// becomes a piece of the run, and the rest begins a new one. The pieces
    /// are written in order when the run ends (`endRun`), the page beginning
    /// between them.
    /// - Parameter joinsWords: whether the page start is a `w:br`, which stood
    ///   between two words that must stay apart.
    fileprivate func cutRun(joinsWords: Bool) {
        paragraph.runPieces.append(RunPiece(text: paragraph.runText, joinsWords: joinsWords))
        paragraph.runText = ""
    }

    /// Separate the words around a page `w:br` just read, where no marker will
    /// stand between them:
    /// - in a heading, the break stays the line break it always was, which ends
    ///   the heading line, so the reading text is unchanged (the marker for a
    ///   page that begins in a heading is a block before the heading, and a
    ///   heading line never holds a marker);
    /// - inside a hyperlink's label, a space, since no marker is written there.
    ///
    /// Anywhere else the marker keeps the words apart (`placePendingPage`).
    fileprivate func separateWordsAroundPageBreak() {
        if paragraphHeadingLevel != nil {
            appendFixed("\n")
        } else if paragraph.isInHyperlink, let last = paragraph.linkLine.last, !last.isWhitespace {
            appendStyled(" ", [])
        }
    }

    /// The paragraph's properties are complete: it begins a page when its own
    /// properties say `w:pageBreakBefore` (a `w:val` of "0", "false", or "off"
    /// says not), or else when its style or one it is based on does.
    fileprivate func startPageIfParagraphBreaksBefore() {
        guard pageTracker != nil, paragraph.isOpen else { return }
        let breaksBefore = paragraph.pageBreakBefore ?? styles.pageBreakBeforeStyles.contains(paragraph.style)
        // The page starts with the first run that is read, so that a paragraph
        // whose words are all hidden begins none (`startWaitingPage()`)
        if breaksBefore {
            paragraph.pageStartWaits = true
        }
    }

    /// Starts the page a paragraph's `w:pageBreakBefore` waits to begin, if one
    /// does.
    fileprivate func startWaitingPage() {
        guard paragraph.pageStartWaits else { return }
        paragraph.pageStartWaits = false
        pageTracker?.startPage()
    }

    /// The paragraph that was just written ended its section when its
    /// properties held the section's `w:sectPr`: the next block begins the
    /// next section.
    fileprivate func endSectionIfParagraphEndedIt() {
        guard paragraph.endsSection else { return }
        paragraph.endsSection = false
        pageTracker?.endSection()
    }

    /// Write the marker of the page that has begun, if one has, in the place
    /// the words about to be added belong to:
    /// - in a table: kept for after the outermost table, whose Markdown cannot
    ///   hold a comment between its rows;
    /// - at the start of a paragraph, or anywhere in a heading: a block before
    ///   the paragraph, written when it ends, since a heading line must hold
    ///   only its words;
    /// - in the middle of a paragraph: inline, right before the words.
    ///
    /// A page that began at a `w:br` also keeps its two neighbouring words apart.
    /// - Returns: whether the page began at a `w:br`, so that the one space
    ///   between its two words has been written (false when no page was pending).
    @discardableResult
    fileprivate func placePendingPage() -> Bool {
        guard let page = pageTracker?.takePendingMarker() else { return false }
        let marker = page.marker.markdown
        if !tables.isEmpty {
            tableTrailingMarker = marker
        } else if paragraphHeadingLevel != nil || paragraph.line.isBlank {
            paragraph.leadingMarkers.append(marker)
        } else {
            // The stretch of runs before the marker ends where it stands
            paragraph.line.commit()
            MarkdownMarkerWriter.write(
                marker, inline: true, keepingWordsApart: page.joinsWords, into: &paragraph.line.committed
            )
            return page.joinsWords
        }
        // The marker is not between the words, so the space that keeps them
        // apart is written here. (A paragraph with no words yet needs none.)
        if page.joinsWords, let last = paragraph.line.last, !last.isWhitespace {
            appendStyled(" ", [])
        }
        return page.joinsWords
    }

    /// A page pending when an outermost table begins, or when a text box with
    /// words is written outside any table, is a block before it. The block
    /// ends any list, so the list is closed first.
    fileprivate func writePendingPageAsBlock() {
        guard tables.isEmpty, let page = pageTracker?.takePendingMarker() else { return }
        paragraph.openListItems.removeAll()
        MarkdownMarkerWriter.write(page.marker.markdown, inline: false, into: &markdown)
    }

    /// A page pending when a text box with words is written begins at the
    /// box (the paragraph that held its anchor had none): a block before it,
    /// or, in a table, kept for after the table, whose Markdown cannot hold a
    /// comment between its rows (`placePendingPage`).
    private func placePendingPageBeforeBox() {
        if tables.isEmpty {
            writePendingPageAsBlock()
        } else if let page = pageTracker?.takePendingMarker() {
            tableTrailingMarker = page.marker.markdown
        }
    }

    /// Write, as a block after the outermost table that has just been written,
    /// the marker of the pages that began inside it.
    fileprivate func writeTrailingTableMarker() {
        guard let marker = tableTrailingMarker else { return }
        tableTrailingMarker = nil
        MarkdownMarkerWriter.write(marker, inline: false, into: &markdown)
    }

    /// Write, as blocks before the paragraph that has just ended, the markers
    /// of the pages that began at it. A block cannot stand between the items
    /// of a Markdown list, so any open list is closed first; that changes no
    /// reading text.
    fileprivate func writeLeadingPageMarkers() {
        guard !paragraph.leadingMarkers.isEmpty else { return }
        paragraph.openListItems.removeAll()
        for marker in paragraph.leadingMarkers {
            MarkdownMarkerWriter.write(marker, inline: false, into: &markdown)
        }
        paragraph.leadingMarkers = []
    }
}
