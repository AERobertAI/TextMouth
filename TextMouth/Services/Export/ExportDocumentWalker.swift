import Foundation

// MARK: - The Walk of content.md (FMT18)

/// Turns a text book's content.md into the `ExportDocument` every text writer
/// reads.
///
/// Markdown is the base, and stays the base: every text book becomes
/// content.md, and every writer starts from it through this walk. HTML is the
/// first writer made from it, not a new base (the user's answer to Q21,
/// October 17, 2026).
///
/// The walk keeps and drops what the reader (`MarkdownDocParser`) keeps and
/// drops, so a writer's output holds the words a listener hears, hand edits
/// to content.md included, and none of TextMouth's own marker comments or
/// heading annotations, nor any other raw HTML. Nothing in the text is
/// rewritten.
enum ExportDocumentWalker {
    /// The document of the content.md whose bytes, read from `url`, are
    /// `bytes`, decoded as the reader decodes them
    /// (`MarkdownCacheService.cacheText(from:at:)`). Bytes that are not UTF-8
    /// throw the error reading the file as text throws; cancelling stops the
    /// walk with `CancellationError`
    /// (`document(fromMarkdown:book:options:deepChapters:cancellation:)`).
    static func document(
        fromContentBytes bytes: Data,
        at url: URL,
        book: ExportBookDetails,
        options: ExportWalkOptions = .plain,
        deepChapters: ExportDeepChapterDecider? = nil,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        let markdown = try MarkdownCacheService.cacheText(from: bytes, at: url)
        return try document(
            fromMarkdown: markdown, book: book, options: options, deepChapters: deepChapters, cancellation: cancellation
        )
    }

    /// The document of `markdown`, a content.md, for `book`. The text is split
    /// into chapters at TextMouth's chapter markers exactly as the reader
    /// splits it (text before the first marker is left out, as the reader
    /// leaves it out); text without a marker is one chapter with no title.
    /// `options` say what besides the words the document keeps. `cancellation`
    /// is checked before each chapter, and a cancelled export throws
    /// `CancellationError`.
    ///
    /// content.md is untrusted: Edit Text lets the user's own text in, and a
    /// walk calls itself once for each level of nesting, as the reader's does.
    /// So the walk is held to the reader's limit on nesting
    /// (`MarkdownTree.read(_:within:_:)`), whose refusal is this walk's
    /// `ExportWalkError.nestedTooDeeply`, naming the chapter by its number, and it runs on
    /// `MarkupGuard.onLargeStack`, whose stack holds a tree at that limit
    /// however small the stack of the thread that asks (an export's own is
    /// 512 KiB).
    ///
    /// A walk given `deepChapters` (FR24) does not refuse a chapter that
    /// nests past the limit: it asks the decider, which says to write the
    /// chapter as written (`Walk.blocksAsWritten(of:)`, plain paragraphs of
    /// its lines, which no writer reads as nesting) or to cancel the export
    /// (`CancellationError`). A chapter at the limit or under it is walked as
    /// ever and never asked about.
    /// - Parameter deepChapters: What to do with a chapter nested too deeply;
    ///   nil refuses it, as Edit Text's check does.
    /// - Throws: `ExportWalkError.nestedTooDeeply` for the first chapter that
    ///   nests past the limit when there is no decider, and
    ///   `CancellationError` when stopped or when the decider says to cancel.
    static func document(
        fromMarkdown markdown: String,
        book: ExportBookDetails,
        options: ExportWalkOptions = .plain,
        deepChapters: ExportDeepChapterDecider? = nil,
        cancellation: BookExportCancellation? = nil
    ) throws -> ExportDocument {
        var sections = MarkdownCacheService.splitChapters(markdown)
        // Whether the text has chapter markers: a refusal names a chapter only if it does.
        let hasChapters = !sections.isEmpty
        if sections.isEmpty {
            sections = [(title: "", content: markdown)]
        }
        // The limits in force are task-local, which a thread of its own does
        // not inherit, so they are read here and handed on.
        let limits = MarkupGuard.limits
        let chapters = sections
        return try MarkupGuard.onLargeStack {
            try walk(
                chapters,
                namingThem: hasChapters,
                book: book,
                options: options,
                limits: limits,
                deepChapters: deepChapters,
                cancellation: cancellation
            )
        }
    }

    /// `document(fromMarkdown:book:options:deepChapters:cancellation:)`'s walk
    /// of the chapters `sections`, which its caller runs on the big stack. A
    /// refusal names the chapter by its number when `namingThem`, which is
    /// false for a text with no chapter markers, whose one section is the
    /// whole text.
    private static func walk(
        _ sections: [(title: String, content: String)],
        namingThem: Bool,
        book: ExportBookDetails,
        options: ExportWalkOptions,
        limits: MarkupGuard.Limits,
        deepChapters: ExportDeepChapterDecider?,
        cancellation: BookExportCancellation?
    ) throws -> ExportDocument {
        var state = Walk(options: options, limits: limits, deepChapters: deepChapters)
        var blocks: [ExportBlock] = []
        var chapterStarts: [ExportChapterStart] = []
        for (index, section) in sections.enumerated() {
            try cancellation?.checkCancelled()
            if options.keepsChapters {
                chapterStarts.append(ExportChapterStart(blockIndex: blocks.count, title: section.title))
            }
            blocks += try state.blocks(
                ofSectionTitled: section.title,
                number: namingThem ? index + 1 : nil,
                chaptersAfter: sections.count - index - 1,
                content: section.content
            )
        }

        // The book's title heads a document that has no level-1 heading of
        // its own, wherever in the text such a heading would be. It is
        // claimed last, so its id cannot take another heading's.
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var titleHeading: ExportHeading?
        if !title.isEmpty, !ExportBlock.headings(in: blocks).contains(where: { $0.level == 1 }) {
            titleHeading = state.plainHeading(level: 1, title: title)
        }
        return ExportDocument(book: book, titleHeading: titleHeading, blocks: blocks, chapterStarts: chapterStarts)
    }
}

// MARK: - Why a Walk Stops

/// Why a content.md is not walked into a document: a sentence of its own, the
/// same on screen, in VoiceOver, and in braille, which the export's failure
/// names after the file (`BookExportWording.failureSentence(_:)`). It never
/// quotes the text, not even a chapter's title, which is the book's text and
/// which the log of the failure may not hold: a chapter is named by its number.
enum ExportWalkError: LocalizedError, Equatable, Sendable {
    /// A chapter's Markdown nests quotes, lists, or emphasis past the limit
    /// the reader holds every text to (`MarkdownTree.read(_:within:_:)`):
    /// `chapter` is its number, from 1, among the text's chapter markers, nil
    /// for a text with no chapter markers, and `limit` the deepest nesting
    /// read (`MarkupGuard.Limits.deepestNesting`).
    case nestedTooDeeply(chapter: Int?, limit: Int)

    var errorDescription: String? {
        switch self {
        case let .nestedTooDeeply(chapter, limit):
            return BookExportWording.nestedTooDeeply(chapter: chapter, limit: limit)
        }
    }
}

// MARK: - What a Walk Keeps

/// What a walk of content.md keeps besides the words: a writer that has a
/// place for chapters and pages asks for them, and every other writer's
/// document is the one it always was.
struct ExportWalkOptions: Equatable, Sendable {
    /// Whether the document says where each chapter of the book begins
    /// (`ExportDocument.chapterStarts`).
    var keepsChapters = false
    /// Whether the document keeps content.md's page markers and heading
    /// annotations, as places between blocks (`ExportBlock.pageBreak`,
    /// `ExportBlock.navigationTarget`), inside text (`ExportRun.pageBreak`,
    /// `ExportRun.navigationTarget`), and in a table's cells
    /// (`ExportTable.cellPages`), read where the reader reads them.
    var keepsPageMarkers = false

    /// The words alone: what HTML, RTF, Word, and braille write.
    static let plain = ExportWalkOptions()
    /// The book's chapters and pages as well, for a writer of an e-book.
    static let bookStructure = ExportWalkOptions(keepsChapters: true, keepsPageMarkers: true)
}

// MARK: - Heading IDs

/// Makes the ids of a document's headings: each made from the heading's text
/// and unique among the ids claimed, so that a contents list and links within
/// the document can point to any heading. An id is a name XML accepts, of
/// ASCII letters, digits, and hyphens, beginning with a letter.
struct ExportHeadingIDs {
    /// The ids claimed so far.
    private var taken: Set<String> = []
    /// For each slug claimed more than once, the next number to try, so that
    /// claiming stays linear however many headings share a name.
    private var nextNumber: [String: Int] = [:]

    /// The longest slug, in characters.
    private static let maximumSlugLength = 64
    /// How many characters of a heading its slug is made from.
    private static let maximumSourceLength = 200

    /// The id for a heading of `text`: its slug when no heading has taken
    /// it, otherwise the first of "slug-2", "slug-3", and so on that no
    /// heading has taken. The id returned is taken from then on.
    mutating func claim(_ text: String) -> String {
        let slug = Self.slug(text)
        if taken.insert(slug).inserted {
            return slug
        }
        // Resume at the next number for this slug, passing any id a heading
        // of its own already has (such as "notes-2" from a heading "Notes 2").
        var number = nextNumber[slug, default: 2]
        var candidate = "\(slug)-\(number)"
        while taken.contains(candidate) {
            number += 1
            candidate = "\(slug)-\(number)"
        }
        nextNumber[slug] = number + 1
        taken.insert(candidate)
        return candidate
    }

    /// `text` as an id: the first 200 characters folded to ASCII (Latin
    /// letters without accents, other scripts transliterated), lowercased,
    /// each run of anything but ASCII letters and digits a single hyphen,
    /// hyphens at both ends dropped, and cut to 64 characters. Nothing left
    /// gives "heading", and a result that begins with a digit gets "heading-"
    /// before it so the id is a valid XML name.
    static func slug(_ text: String) -> String {
        let source = String(text.prefix(maximumSourceLength))
        let latin = source.applyingTransform(.toLatin, reverse: false) ?? source
        let folded = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()

        // Build the slug scalar by scalar, collapsing each run of other
        // characters into one hyphen (none at the start).
        var slug = ""
        var pendingHyphen = false
        for scalar in folded.unicodeScalars {
            let isLetter = ("a"..."z").contains(scalar)
            let isDigit = ("0"..."9").contains(scalar)
            if isLetter || isDigit {
                if pendingHyphen && !slug.isEmpty {
                    slug.append("-")
                }
                pendingHyphen = false
                slug.unicodeScalars.append(scalar)
            } else {
                pendingHyphen = true
            }
        }

        // Cutting may leave a hyphen at the end.
        slug = String(slug.prefix(maximumSlugLength))
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        if slug.isEmpty {
            return "heading"
        }
        return slug.first?.isNumber == true ? "heading-\(slug)" : slug
    }
}

// MARK: - The Walk's State

/// The state of one walk of a content.md: the ids its headings have taken,
/// and the functions that make blocks and runs from the tree cmark parses
/// (`MarkdownTree`). Until November 15, 2026 the walk read the tree
/// swift-markdown built from cmark's; it reads every node as it read that
/// tree's, and `MarkdownWalkCorpusTests` holds the records that prove it.
private struct Walk {
    /// What the walk keeps besides the words.
    let options: ExportWalkOptions
    /// The ids claimed so far, shared by every chapter of the document.
    var ids = ExportHeadingIDs()
    /// How many pages have been met, so each page's id is its number.
    var pageCount = 0
    /// How many contents targets have been met, so each one's id is its number.
    var targetCount = 0
    /// Whether the rest of a marker-led HTML block is being walked: another
    /// marker-led block inside it is not read again (as the reader does not,
    /// so a crafted line cannot be re-parsed once per level).
    var isReadingRestOfMarkerLine = false
    /// The limits on nesting every text read is held to.
    let limits: MarkupGuard.Limits
    /// What to do with a chapter nested past `limits` (FR24); nil refuses it.
    let deepChapters: ExportDeepChapterDecider?

    /// A walk that keeps what `options` ask for, held to `limits`, with no id
    /// claimed and no page or target met. A chapter nested past the limits is
    /// left to `deepChapters`, or refused when there is none.
    init(options: ExportWalkOptions, limits: MarkupGuard.Limits, deepChapters: ExportDeepChapterDecider? = nil) {
        self.options = options
        self.limits = limits
        self.deepChapters = deepChapters
    }

    // MARK: Chapters

    /// The blocks of one chapter: `content` parsed as Markdown. A chapter that
    /// has a title but no heading of any depth begins with its title as a
    /// level-1 heading, as the reader gives such a chapter its title. A walk
    /// that keeps the chapters adds none: it says where each chapter begins
    /// and what it is called (`ExportDocument.chapterStarts`), and the writer
    /// that asked names the chapter in its contents without adding words the
    /// book does not have.
    ///
    /// A chapter that nests past the limit, in its own Markdown or in the rest
    /// of a marker line, is refused, unless the walk has a decider
    /// (`deepChapters`, FR24): it says to write the chapter as written
    /// (`blocksAsWritten(of:)`) or to cancel the export.
    /// - Parameters:
    ///   - number: The chapter's number among the text's chapter markers, from
    ///     1, for a refusal or a question to name it; nil for a text with none.
    ///   - chaptersAfter: How many chapters follow this one, for the question
    ///     to say whether to offer the same for every such chapter.
    /// - Throws: `ExportWalkError.nestedTooDeeply` when the chapter nests past
    ///   the limit and there is no decider, and `CancellationError` when the
    ///   decider says to cancel.
    mutating func blocks(
        ofSectionTitled title: String,
        number: Int?,
        chaptersAfter: Int,
        content: String
    ) throws -> [ExportBlock] {
        let walked: [ExportBlock]
        // The count of pages and targets before the walk, which a walk
        // abandoned partway (a refusal in the rest of a marker line) must not
        // leave moved: the ids of the places after it follow the ones kept.
        let (pagesBefore, targetsBefore) = (pageCount, targetCount)
        do {
            walked = try MarkdownTree.read(content, within: limits) { document in
                try self.blocks(in: document, nesting: 0, listDepth: 0)
            }
        } catch let refusal as MarkupRefusal {
            // The only refusal a walk of Markdown makes, named for the chapter.
            guard case let .nestedTooDeeply(limit) = refusal else { throw refusal }
            guard let decide = deepChapters else {
                throw ExportWalkError.nestedTooDeeply(chapter: number, limit: limit)
            }
            // A heading id that an abandoned walk claimed stays claimed (only a
            // refusal in the rest of a marker line comes after a walk has
            // begun): ids stay unique, and a skipped number harms nothing.
            (pageCount, targetCount) = (pagesBefore, targetsBefore)
            switch decide(ExportDeepChapter(number: number, limit: limit, chaptersAfter: chaptersAfter)) {
            case .writeAsWritten:
                walked = blocksAsWritten(of: content)
            case .cancel:
                // The export stops as Stop stops it: nothing is written.
                throw CancellationError()
            }
        }
        var blocks = Self.droppingRedundantTargets(from: walked)
        // Claimed after the blocks are made: they hold no heading, so the
        // order of ids is still the order of reading.
        if !options.keepsChapters, !title.isEmpty, ExportBlock.headings(in: blocks).isEmpty {
            blocks.insert(.heading(plainHeading(level: 1, title: title)), at: 0)
        }
        return blocks
    }

    /// The blocks of a chapter exported as it is written (FR24): one plain
    /// paragraph for each block of lines between blank lines (`RawChapterLines`),
    /// its lines apart by a line feed, a hard break in every writer, so that
    /// a hard-wrapped book does not come out a paragraph to a line.
    /// Nothing is parsed, so no writer is handed any nesting: a chapter of a
    /// thousand `>` marks is a paragraph, never a thousand quotes. Each quote
    /// and list mark stays the character it is, for the writer to escape as it
    /// escapes any text.
    ///
    /// What is not the book's words is left out, as it is from any walk, and
    /// what content.md added to the words is undone: the spaces and tabs at
    /// the ends of a line (indentation is no part of the words, and a writer
    /// would take four spaces for code), blank lines, the backslash before each
    /// punctuation mark that the converters wrote, and TextMouth's own markers,
    /// found anywhere in a line. A marker that begins a block names a place
    /// between blocks, as the markers that lead an HTML block do
    /// (`blocks(ofHTML:atLevel:nesting:listDepth:)`); any other is a run of its
    /// own at its exact place in the words, as in any paragraph
    /// (`inlineRuns(of:style:)`); both only where the walk keeps places
    /// (`place(of:)`).
    private mutating func blocksAsWritten(of content: String) -> [ExportBlock] {
        var made: [ExportBlock] = []
        for paragraph in RawChapterLines.paragraphs(of: content) {
            made += paragraph.leadingMarkers.compactMap { place(of: $0) }.compactMap(Self.block(ofPlace:))
            var runs: [ExportRun] = []
            for piece in paragraph.pieces {
                switch piece {
                case let .words(text):
                    runs.append(ExportRun(text))
                case let .marker(marker):
                    if let found = place(of: marker) { runs.append(found) }
                }
            }
            runs = Self.joined(runs)
            if !runs.isEmpty {
                made.append(.paragraph(runs))
            }
        }
        return made
    }

    /// A heading of `level` whose one plain run is `title`.
    mutating func plainHeading(level: Int, title: String) -> ExportHeading {
        ExportHeading(level: level, runs: [ExportRun(title)], id: ids.claim(title))
    }

    // MARK: Blocks

    /// The blocks of `container`'s children, in order. `nesting` counts the
    /// lists and quotes opened around the container and `listDepth` the lists;
    /// the document's body is 0 and 0.
    mutating func blocks(in container: MarkdownNode, nesting: Int, listDepth: Int) throws -> [ExportBlock] {
        var made: [ExportBlock] = []
        for child in container.children {
            made += try blocks(of: child, nesting: nesting, listDepth: listDepth)
        }
        return made
    }

    /// The blocks `block` makes: usually one, none for a block that is
    /// dropped, several for a list or quote past the nesting cap.
    private mutating func blocks(of block: MarkdownNode, nesting: Int, listDepth: Int) throws -> [ExportBlock] {
        switch block.kind {
        case .heading:
            // A page that starts inside a heading starts where the heading
            // does (as the reader places it), so it is a break before it.
            // A contents target inside a heading is the heading's own place,
            // which the contents link already: the reader adds no row for it.
            let (places, runs) = Self.splittingPlaces(from: self.runs(of: block))
            let breaks = places.compactMap(\.pageBreak).map(ExportBlock.pageBreak)
            // A heading with nothing to read is dropped, as the reader's
            // heading list drops it.
            guard !runs.isEmpty else { return breaks }
            let level = min(max(block.headingLevel, 1), 6)
            return breaks + [.heading(ExportHeading(level: level, runs: runs, id: ids.claim(runs.plainText)))]

        case .paragraph:
            let runs = self.runs(of: block)
            // A paragraph that is only the start of a page, or a place the
            // contents point at, is that and no paragraph.
            if !runs.isEmpty, runs.allSatisfy(\.isPlace) {
                return runs.compactMap(Self.block(ofPlace:))
            }
            return runs.isEmpty ? [] : [.paragraph(runs)]

        case .list:
            // An unordered list starts at 1. CommonMark allows an ordered
            // list a start of at most nine digits (a longer number is no
            // list), and cmark never gives one below 0.
            let isOrdered = block.isOrderedList
            let start = isOrdered ? max(block.listStart, 0) : 1
            return try listBlocks(of: block, isOrdered: isOrdered, start: start, nesting: nesting, listDepth: listDepth)

        case .blockQuote:
            // Past the cap the quote is not opened: its blocks join the
            // container that holds it.
            if nesting >= ExportDocument.maximumNesting {
                return try blocks(in: block, nesting: nesting, listDepth: listDepth)
            }
            return [.blockQuote(try blocks(in: block, nesting: nesting + 1, listDepth: listDepth))]

        case .codeBlock:
            // The parser keeps the line feed that ends the code.
            var text = block.literal
            if text.hasSuffix("\n") {
                text.removeLast()
            }
            return text.isEmpty ? [] : [.codeBlock(text)]

        case .thematicBreak:
            return [.thematicBreak]

        case .table:
            // A target in a cell is a place before the table; a page that
            // starts in a cell stays in it (`ExportTable.cellPages`).
            let (hoisted, converted) = self.table(of: block)
            return hoisted + (converted.map { [.table($0)] } ?? [])

        case .htmlBlock:
            return try blocks(ofHTML: block.literal, atLevel: block.level, nesting: nesting, listDepth: listDepth)

        case .document, .listItem, .other:
            // Any other container of blocks is walked for its children
            // (cmark makes none of these here from a text).
            return try blocks(in: block, nesting: nesting, listDepth: listDepth)

        case .tableHeader, .tableRow, .tableCell, .text, .softBreak, .lineBreak, .inlineCode, .inlineHTML, .emphasis,
             .strong, .strikethrough, .link, .image, .inlineAttributes:
            // Anything else is no block, and is dropped.
            return []
        }
    }

    /// The blocks an HTML block makes. TextMouth's marker comments, its
    /// heading annotations, and any raw HTML make none, as the reader never
    /// reads them, but for what follows a line's markers (ST05, read as the
    /// reader reads it, `MarkdownMarker.leading(of:)`): that is Markdown, and
    /// its blocks are walked, preceded by the places of the markers.
    ///
    /// The rest is a text of its own, so it is held to the limit like one,
    /// on top of the level the HTML block is at in its tree (`level`), as the
    /// reader counts it, so that the two refuse the same texts.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` when the rest nests past it.
    private mutating func blocks(ofHTML rawHTML: String, atLevel level: Int, nesting: Int, listDepth: Int) throws -> [ExportBlock] {
        if !isReadingRestOfMarkerLine, let (markers, rest) = MarkdownMarker.leading(of: rawHTML) {
            var made = markers.compactMap { place(of: $0) }.compactMap(Self.block(ofPlace:))
            isReadingRestOfMarkerLine = true
            defer { isReadingRestOfMarkerLine = false }
            made += try MarkdownTree.read(String(rest), within: limits, insideLevel: level) { document in
                try blocks(in: document, nesting: nesting, listDepth: listDepth)
            }
            return made
        }
        if let marker = MarkdownMarker.decode(rawHTML), let found = place(of: marker) {
            return [Self.block(ofPlace: found)].compactMap { $0 }
        }
        return []
    }

    // MARK: Places

    /// The place `marker` marks when the walk keeps them: a page start (with
    /// the next id, and for a label with no word left once the characters XML
    /// forbids are gone, the page's number among the book's pages) or a place
    /// the contents point at (B3); nil for a walk of the words alone.
    private mutating func place(of marker: MarkdownMarker) -> ExportRun? {
        guard options.keepsPageMarkers else { return nil }
        var run = ExportRun("")
        switch marker {
        case .page(let page):
            pageCount += 1
            let hasWords = XMLEscaping.hasVisibleText(page.label)
            run.pageBreak = ExportPageBreak(label: hasWords ? page.label : String(pageCount), id: "page_\(pageCount)")
        case .heading(let annotation):
            targetCount += 1
            let level = min(max(annotation.level, 1), 6)
            run.navigationTarget = ExportNavigationTarget(level: level, text: annotation.text, id: "target_\(targetCount)")
        }
        return run
    }

    /// The block that marks the place `run` marks.
    private static func block(ofPlace run: ExportRun) -> ExportBlock? {
        if let page = run.pageBreak { return .pageBreak(page) }
        if let target = run.navigationTarget { return .navigationTarget(target) }
        return nil
    }

    /// `runs` as the runs that mark places they hold, in order, and the runs
    /// that are text, neighbours of one style joined again where a place was
    /// between them.
    private static func splittingPlaces(from runs: [ExportRun]) -> (places: [ExportRun], text: [ExportRun]) {
        (runs.filter(\.isPlace), joined(runs.filter { !$0.isPlace }))
    }

    /// `blocks` without the contents targets that stand where another entry
    /// of the contents already does, as the reader (`MarkdownDocParser`) keeps
    /// one navigation row for a place: a target with no words between it and
    /// a heading is that heading's place, and of several targets with none
    /// between them only the first is kept. Only the chapter's own blocks, not
    /// those inside a list or quote, are looked at; a target kept by mistake
    /// there costs one more entry, never one fewer.
    private static func droppingRedundantTargets(from blocks: [ExportBlock]) -> [ExportBlock] {
        // Whether the next block that has words is a heading, for each block,
        // found in one pass from the end.
        var headingFollows = [Bool](repeating: false, count: blocks.count)
        var nextWordsAreHeading = false
        for index in blocks.indices.reversed() {
            headingFollows[index] = nextWordsAreHeading
            switch blocks[index] {
            case .pageBreak, .navigationTarget: break
            case .heading: nextWordsAreHeading = true
            default: nextWordsAreHeading = false
            }
        }

        var kept: [ExportBlock] = []
        // Whether a target was kept with nothing but places since.
        var targetIsHere = false
        for (index, block) in blocks.enumerated() {
            switch block {
            case .navigationTarget:
                if headingFollows[index] || targetIsHere { continue }
                targetIsHere = true
            case .pageBreak:
                break
            default:
                targetIsHere = false
            }
            kept.append(block)
        }
        return kept
    }

    /// The blocks of a list whose items are `list`'s children. Past the
    /// nesting cap the list is not opened: each item's blocks, in turn, join
    /// the container that holds it.
    private mutating func listBlocks(
        of list: MarkdownNode,
        isOrdered: Bool,
        start: Int,
        nesting: Int,
        listDepth: Int
    ) throws -> [ExportBlock] {
        let items = list.children.filter { $0.kind == .listItem }
        if nesting >= ExportDocument.maximumNesting {
            var joined: [ExportBlock] = []
            for item in items {
                joined += try blocks(in: item, nesting: nesting, listDepth: listDepth)
            }
            return joined
        }
        // A task-list checkbox is ignored: the item's words are all it keeps.
        var exportItems: [ExportListItem] = []
        for item in items {
            exportItems.append(ExportListItem(blocks: try blocks(in: item, nesting: nesting + 1, listDepth: listDepth + 1)))
        }
        return [.list(ExportList(isOrdered: isOrdered, start: start, depth: listDepth, items: exportItems))]
    }

    // MARK: Tables

    /// `table` as an `ExportTable`, its cells as plain text, or nil when it
    /// has no row left. A head row whose cells are all empty is left out, and
    /// the table has no header row. Also the blocks to put before the table:
    /// the contents targets in its cells, and the pages in a head row that is
    /// left out. The pages that start in the other cells stay in them
    /// (`ExportTable.cellPages`).
    private mutating func table(of table: MarkdownNode) -> (before: [ExportBlock], table: ExportTable?) {
        var before: [ExportBlock] = []
        var rows: [[String]] = []
        var found: [ExportCellPage] = []
        // cmark's table holds its rows, the header row first. A table
        // without one (cmark makes none) has a head row of no cells.
        var allRows = Array(table.children)
        let head = allRows.first?.kind == .tableHeader ? allRows.removeFirst() : nil
        let cellsOfRows = [head.map { Array($0.children) } ?? []] + allRows.map { Array($0.children) }
        for (rowIndex, cells) in cellsOfRows.enumerated() {
            var texts: [String] = []
            for (column, cell) in cells.enumerated() {
                let cellText = self.cellText(cell, hoisting: &before)
                texts.append(cellText.text)
                found += cellText.pages.map { ExportCellPage(row: rowIndex, column: column, offset: $0.offset, page: $0.page) }
            }
            rows.append(texts)
        }
        // A head row of empty cells is left out, and the rows after it move up.
        let hasHeaderRow = rows[0].contains { !$0.isEmpty }
        if !hasHeaderRow { rows.removeFirst() }
        var cellPages: [ExportCellPage] = []
        for var cellPage in found {
            if hasHeaderRow {
                cellPages.append(cellPage)
            } else if cellPage.row == 0 {
                before.append(.pageBreak(cellPage.page))
            } else {
                cellPage.row -= 1
                cellPages.append(cellPage)
            }
        }
        return (before, rows.isEmpty ? nil : ExportTable(rows: rows, hasHeaderRow: hasHeaderRow, cellPages: cellPages))
    }

    /// A cell's words as one line: its runs' plain text with every line feed
    /// a space, trimmed. Also the pages that start in it, each with how many
    /// Characters of the words come before it; the targets that start in it
    /// join `hoisted`.
    private mutating func cellText(
        _ cell: MarkdownNode,
        hoisting hoisted: inout [ExportBlock]
    ) -> (text: String, pages: [(offset: Int, page: ExportPageBreak)]) {
        var text = ""
        var pages: [(offset: Int, page: ExportPageBreak)] = []
        for run in runs(of: cell) {
            if let page = run.pageBreak {
                pages.append((text.count, page))
            } else if let target = run.navigationTarget {
                hoisted.append(.navigationTarget(target))
            } else {
                text += run.text
            }
        }
        // Line feeds are spaces, one Character each; trimming moves the pages.
        let spaced = text.replacingOccurrences(of: "\n", with: " ")
        let trimmed = spaced.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = spaced.prefix(while: { $0.isWhitespace }).count
        return (trimmed, pages.map { (min(max($0.offset - leading, 0), trimmed.count), $0.page) })
    }

    // MARK: Runs

    /// The runs of `container`'s inline children, for a heading, a paragraph,
    /// or a table cell: neighbouring runs of one style joined, runs with no
    /// text dropped (but for the start of a page), and white space and line
    /// feeds trimmed from both ends of the text.
    mutating func runs(of container: MarkdownNode) -> [ExportRun] {
        var runs = Self.joined(inlineRuns(of: container, style: ExportRun("")))
        // Trim the first run that has text at its start and the last at its
        // end, dropping any run that trimming empties, until each end has
        // text. A page that starts there stays where it is.
        var index = 0
        while index < runs.count {
            if runs[index].isPlace {
                index += 1
                continue
            }
            let trimmed = runs[index].text.drop { $0.isWhitespace || $0.isNewline }
            if trimmed.isEmpty {
                runs.remove(at: index)
            } else {
                runs[index].text = String(trimmed)
                break
            }
        }
        index = runs.count - 1
        while index >= 0 {
            if runs[index].isPlace {
                index -= 1
                continue
            }
            var text = runs[index].text
            while let end = text.last, end.isWhitespace || end.isNewline {
                text.removeLast()
            }
            if text.isEmpty {
                runs.remove(at: index)
                index -= 1
            } else {
                runs[index].text = text
                break
            }
        }
        return runs
    }

    /// The runs of `markup`'s children in `style` (an `ExportRun` with empty
    /// text, carrying the emphasis, strength, code, and link of the markup
    /// around them), before neighbours are joined.
    private mutating func inlineRuns(of markup: MarkdownNode, style: ExportRun) -> [ExportRun] {
        var made: [ExportRun] = []
        for child in markup.children {
            var inner = style
            switch child.kind {
            case .text:
                made.append(Self.styled(child.literal, like: style))
                continue
            case .emphasis:
                inner.isEmphasis = true
            case .strong:
                inner.isStrong = true
            case .strikethrough:
                break // keeps the style it is in
            case .inlineCode:
                inner.isCode = true
                made.append(Self.styled(child.literal, like: inner))
                continue
            case .link:
                // Only a web or mail address becomes a link; any other
                // link's words are plain text in the style they had.
                if let destination = child.destination, ExportRun.isAllowedLinkAddress(destination) {
                    inner.link = destination.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case .image:
                break // its alternative text, in the style it is in; never its source
            case .softBreak:
                made.append(Self.styled(" ", like: style))
                continue
            case .lineBreak:
                made.append(Self.styled("\n", like: style))
                continue
            case .inlineHTML:
                // Dropped, but for a page start or a contents target where
                // the walk keeps them: a run of its own at its exact place in
                // the text, in the style it is in. No string is made of it
                // for a walk that keeps none.
                if options.keepsPageMarkers, let marker = MarkdownMarker.decode(child.literal),
                   var found = place(of: marker) {
                    found.isEmphasis = style.isEmphasis
                    found.isStrong = style.isStrong
                    found.isCode = style.isCode
                    found.link = style.link
                    made.append(found)
                }
                continue
            case .inlineAttributes, .paragraph, .heading, .tableCell:
                break // any other container of inlines: its children
            case .document, .blockQuote, .list, .listItem, .codeBlock, .htmlBlock, .thematicBreak, .table,
                 .tableHeader, .tableRow, .other:
                continue // anything else: nothing
            }
            made += inlineRuns(of: child, style: inner)
        }
        return made
    }

    /// A run of `text` in the style of `style`.
    private static func styled(_ text: String, like style: ExportRun) -> ExportRun {
        var run = style
        run.text = text
        return run
    }

    /// `runs` with neighbours of one style (`hasSameStyle(as:)`) joined into
    /// one run, and runs with no text dropped, but for the start of a page.
    private static func joined(_ runs: [ExportRun]) -> [ExportRun] {
        var result: [ExportRun] = []
        for run in runs where !run.text.isEmpty || run.isPlace {
            if let last = result.last, last.hasSameStyle(as: run) {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }
}
