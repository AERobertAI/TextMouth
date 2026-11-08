import Foundation
import SwiftSoup

// MARK: - The Guard

/// The one way markup reaches SwiftSoup. A book's markup is untrusted input, and
/// three things in it would otherwise take the whole app down, or the Mac's
/// memory with it:
///
/// - **A trap in SwiftSoup's XML parser.** Markup that opens with `<?xml` goes
///   to it, and it takes what follows `<?` apart by parsing it again, then asks
///   the result for its first element: a declaration that makes none, as `<?a>`
///   or a torn `<?xml version="1.0"` does, stops the process. One flipped byte
///   of a real book can make one. The guard rewrites any such declaration as an
///   empty comment before the parser sees it, which is what SwiftSoup 2.14 does
///   with one. Every other byte of the markup goes to the parser unchanged, so
///   no book that could be read before reads differently now.
/// - **Stack overflow from deep nesting.** SwiftSoup walks up an element's
///   parents by recursion, and the app's imports run on a 512 KiB stack.
/// - **Memory.** An element takes a kilobyte or two, however few bytes its tag
///   does, so the limit on the bytes of a document is no limit on its memory.
///
/// The nesting is held in two layers, so that one slip of the first cannot
/// crash the app. First, one pass over the bytes (`MarkupScanner`), as linear as
/// reading them, finds the same tags the parser will and follows the parser's
/// own rules (`XMLOpenElements`, `HTMLTreeModel`), counting a depth never less
/// than the tree will have; past a limit it refuses with a sentence, before
/// anything is built, which keeps SwiftSoup's own recursion safe. Then the
/// parsed tree's real depth is measured by a walk with a stack of its own, and
/// refused past the limit with the same sentence, before any reader that calls
/// itself for each level, the converter first among them, sees the tree.
///
/// Even a wrong count cannot overflow SwiftSoup's own recursion, because the
/// parse, that walk, and the release of a refused tree all run on a thread
/// whose stack holds the deepest tree the memory limit allows (`onLargeStack`).
enum MarkupGuard {

    // MARK: Limits

    /// What markup may hold and still be read.
    struct Limits: Equatable, Sendable {
        /// The deepest nesting read, by `Inspection.deepest`.
        var deepestNesting: Int
        /// The most memory one document may take, by `Inspection.memoryUnits`.
        var mostMemoryUnits: Int
        /// The most attributes read on one tag.
        var mostAttributesOnATag: Int
        /// The most work the parser may be set, by `Inspection.work`.
        var mostWork: Int
        /// The deepest tree the second layer lets pass, by `requireDepth(of:atMost:)`;
        /// `deepestNesting` when nil. Only a test sets it, to lift the first
        /// layer's count and still see the second refuse.
        var deepestTree: Int? = nil

        /// The depth the second layer holds a parsed tree to.
        var deepestParsedTree: Int { deepestTree ?? deepestNesting }

        /// The limits every reading has, set on November 7, 2026 from 3,236 documents
        /// of 327 real files (EPUB, HTML, Kindle, Word, OpenDocument, and rich text,
        /// Project Gutenberg's and Standard Ebooks' largest among them), and from how
        /// deep a tree each reading path survives on the 512 KiB stack of an import:
        ///
        /// - **Nesting, 128.** The deepest real book nests 12 levels, and 34 real web
        ///   pages of news, documentation, shops, and governments 10 to 36 (GitHub's
        ///   36, IKEA's 35, CNN's 33), which TextMouth imports as pages and web
        ///   archives. The converter calls itself for every level of the tree, and on
        ///   the 512 KiB stack of an import the app's Release build reads 552 levels
        ///   at the least (nested quotes, where the Markdown parser runs out), 862 of
        ///   lists, and about 1,190 of most other shapes. A tree can go twice as deep
        ///   as the count, and two more, as when a form's end tag leaves what it holds
        ///   open: at 128 the deepest tree, 258 levels, is under half of 552.
        ///   A debug build takes over 4 KB of stack a level and reads only 108 levels
        ///   of lists and 117 of divisions, so a hostile file nested between about 108
        ///   and 128 levels can overflow a developer's debug build, never the app. The
        ///   tests that convert in a debug test host keep to 40 levels at most.
        /// - **Memory, 1,000,000 units.** The most in a real document is 431,296,
        ///   Webster's Unabridged Dictionary as one 32 MB HTML file. A unit is about
        ///   800 bytes of SwiftSoup's tree, so the limit holds a parse near 800 MB.
        /// - **Attributes on a tag, 1,000.** No real tag has more than 7; SwiftSoup's
        ///   time grows with the square of them.
        /// - **Work, 30,000,000,000.** The most in a real document is 1,300; the limit
        ///   is about half a minute.
        static let standard = Limits(
            deepestNesting: 128, mostMemoryUnits: 1_000_000, mostAttributesOnATag: 1_000, mostWork: 30_000_000_000
        )
    }

    /// The limits in force: `Limits.standard`, unless a test binds others with
    /// `MarkupGuard.$limits.withValue(_:operation:)`, which changes only the
    /// reading that operation does on its own thread.
    @TaskLocal static var limits = Limits.standard

    // MARK: Parsing

    /// `markup` parsed as `SwiftSoup.parse(_:_:)` parses it, by its XML parser
    /// when it opens with `<?xml` and its HTML parser otherwise, but that it can
    /// neither trap nor overflow the stack, with nesting read up to
    /// `deepestNesting`, or the limit in force. Only a reader that walks the
    /// tree without calling itself, and converts nothing, may ask for more.
    ///
    /// Two layers hold the nesting: the pass counts it before the parse, never
    /// less than the tree will be, which keeps SwiftSoup's own recursion safe;
    /// and the parsed tree's depth is measured before it is handed on, which
    /// keeps a reader's recursion safe even where the count were wrong.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parse(_ markup: String, baseURI: String = "", deepestNesting: Int? = nil) throws -> Document {
        if opensAsXML(markup) {
            return try parseXML(markup, baseURI: baseURI, deepestNesting: deepestNesting)
        }
        var limits = limits
        if let deepestNesting { limits.deepestNesting = deepestNesting }
        _ = try inspect(Array(markup.utf8), as: .html, limits: limits)
        let treeLimit = limits.deepestParsedTree
        return try onLargeStack { try requireDepth(of: SwiftSoup.parseHTML(markup, baseURI), atMost: treeLimit) }
    }

    /// `markup` parsed by SwiftSoup's XML parser, whatever it opens with, with
    /// nesting read up to `deepestNesting`, or the limit in force, in the same
    /// two layers as `parse(_:baseURI:deepestNesting:)`.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parseXML(_ markup: String, baseURI: String = "", deepestNesting: Int? = nil) throws -> Document {
        var limits = limits
        if let deepestNesting { limits.deepestNesting = deepestNesting }
        let neutral = try neutralized(markup, limits: limits)
        let treeLimit = limits.deepestParsedTree
        return try onLargeStack {
            try requireDepth(of: SwiftSoup.parse(neutral, baseURI, Parser.xmlParser()), atMost: treeLimit)
        }
    }

    /// The fragment `markup` in the body of an empty document, as
    /// `SwiftSoup.parseBodyFragment(_:)` makes one, by its HTML parser, in the
    /// same two layers as `parse(_:baseURI:deepestNesting:)`.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parseBodyFragment(_ markup: String) throws -> Document {
        _ = try inspect(Array(markup.utf8), as: .bodyFragment, limits: limits)
        let treeLimit = limits.deepestParsedTree
        return try onLargeStack { try requireDepth(of: SwiftSoup.parseBodyFragment(markup), atMost: treeLimit) }
    }

    /// `document`, once its deepest element is found no deeper than `limit`
    /// (an element of the document's own children, `html`, at 1), by a walk
    /// with a stack of its own: the second layer, after the parse and before
    /// any reader that calls itself for each level, such as the converter.
    /// - Throws: `MarkupRefusal.nestedTooDeeply` when an element is deeper.
    static func requireDepth(of document: Document, atMost limit: Int) throws -> Document {
        var pending: [(node: Node, depth: Int)] = [(document, 0)]
        while let (node, depth) = pending.popLast() {
            guard depth < limit else {
                // Its children are elements one level deeper than the limit.
                if node.getChildNodes().contains(where: { $0 is Element }) { throw MarkupRefusal.nestedTooDeeply(limit: limit) }
                continue
            }
            for child in node.getChildNodes() where child is Element {
                pending.append((child, depth + 1))
            }
        }
        return document
    }

    // MARK: The Big Stack

    /// The deepest tree the memory limit lets through. The pass counts every
    /// node as at least one unit, and refuses a document past
    /// `Limits.standard.mostMemoryUnits` (1,000,000), so no tree that is parsed
    /// is deeper.
    static let deepestTreeParsed = 1_000_000

    /// The stack SwiftSoup is given for each level of the tree, in bytes.
    ///
    /// Measured on November 7, 2026, on a thread with a 4 GiB stack of which
    /// the pages touched were counted: SwiftSoup's parse of a plain deep
    /// document touches 0 bytes a level in most shapes, and in the worst shapes
    /// found (an inline element or a list closed again, where an end tag walks
    /// up the whole chain of parents with `ownerDocument()`) about 200 bytes a
    /// level in a debug build (197 for spans, 195 for nested lists) and 160 to
    /// 190 in a Release build (161 and 160). The release of the tree touches
    /// none, since SwiftSoup 2.13.9's `Node.deinit` takes a deep tree apart
    /// with a loop. 512 is two and a half times the worst, and the old limit
    /// of an import thread's 512 KiB stack is 1,000 levels of it.
    static let stackBytesPerLevel = 512

    /// The stack for a tree `levels` deep: `stackBytesPerLevel` for each, and
    /// a megabyte for the parser's own frames and what is below them, which a
    /// whole number of megabytes keeps a multiple of the page size, as
    /// `pthread_attr_setstacksize` asks (16 KiB on Apple silicon).
    static func stackBytes(forTreeDepth levels: Int) -> Int {
        let megabyte = 1 << 20
        let needed = levels * stackBytesPerLevel + megabyte
        return (needed + megabyte - 1) / megabyte * megabyte
    }

    /// What a thread started by `onLargeStack` runs, held in a class so that
    /// its address can be handed through the C interface of `pthread_create`.
    private final class StackJob {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }

    /// The thread's start routine: runs the job it was handed.
    private static let startStackJob: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { context in
        Unmanaged<StackJob>.fromOpaque(context).takeUnretainedValue().run()
        return nil
    }

    /// Runs `body`, and returns what it returns or throws, on a thread whose
    /// stack holds the deepest tree that can be parsed (`deepestTreeParsed`
    /// levels), so that SwiftSoup's own recursion up a tree's parents cannot
    /// overflow it, whatever the first layer counted. The caller's stack, which
    /// is 512 KiB on every thread but the main thread, is never asked for it.
    ///
    /// The parse, the depth check after it, and the release of a tree the
    /// check refuses all run inside `body`, so a tree deeper than the limit
    /// never outlives this thread; one that passes is at most `deepestNesting`
    /// levels deep, and is safe to release anywhere.
    ///
    /// - Waiting. The caller blocks in `pthread_join` until the thread has
    ///   ended, as it was blocked by the parse when it ran on its own stack, so
    ///   no thread is blocked that was not already. The thread takes no lock
    ///   and waits for nothing the caller holds (SwiftSoup's parse is plain
    ///   code), so the join cannot deadlock, and it makes the thread's writes
    ///   to `outcome` visible to the caller. A bounded wait would have to give
    ///   up on a thread still running, which is worse.
    /// - Concurrency. The job and its result cross the C interface of `pthread`
    ///   as an address, which Swift 6's checking does not follow, so it holds
    ///   by construction: `outcome` is written by the thread alone, before it
    ///   ends, and read by the caller alone, after it has joined; the caller
    ///   does not touch the job meanwhile.
    /// - Priority. The thread has the caller's quality of service, so a caller
    ///   of high priority does not wait on a thread of low.
    /// - No thread. If the system refuses the stack asked for (no thread was
    ///   started), a stack a quarter the size is tried, and so on while it is
    ///   at least `smallestStack`, which holds a tree 16,000 levels deep; only
    ///   then does the body run on the caller's own thread, as it did before,
    ///   with the first layer's count as the only guard.
    static func onLargeStack<Value>(_ body: @escaping () throws -> Value) throws -> Value {
        var outcome: Result<Value, any Error>?
        let job = StackJob { outcome = Result { try body() } }
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        defer { pthread_attr_destroy(&attributes) }
        pthread_attr_set_qos_class_np(&attributes, qos_class_self(), 0)

        var bytes = stackBytes(forTreeDepth: deepestTreeParsed)
        while bytes >= smallestStack {
            var thread: pthread_t?
            if pthread_attr_setstacksize(&attributes, bytes) == 0,
               pthread_create(&thread, &attributes, startStackJob, Unmanaged.passUnretained(job).toOpaque()) == 0,
               let thread {
                pthread_join(thread, nil)
                break
            }
            bytes /= 4
            bytes -= bytes % (1 << 20)
        }
        // The thread was handed `job` as an address that holds no reference,
        // so the job is kept alive here, explicitly, until the join above.
        withExtendedLifetime(job) {}
        // A thread that ran has set `outcome`; if none could be made, the body runs here.
        return try (outcome ?? Result { try body() }).get()
    }

    /// The smallest stack `onLargeStack` tries before it runs the body on the
    /// caller's thread.
    private static let smallestStack = 8 << 20

    // MARK: Which Parser

    /// Which of SwiftSoup's parsers reads a document: its HTML parser for a
    /// document or for a fragment in a body (`parseBodyFragment`), or its XML parser.
    enum Dialect {
        case html, xml, bodyFragment
    }

    /// Whether SwiftSoup's automatic parse would choose its XML parser:
    /// `looksLikeXml`, which passes over its own idea of whitespace (not a
    /// no-break space, say) and compares characters, not bytes. The guard
    /// chooses now, and asks for that parser by name.
    static func opensAsXML(_ markup: String) -> Bool {
        markup.drop { openingWhitespace.contains($0) }.hasPrefix("<?xml")
    }

    /// What `Character.isWhitespace` means inside SwiftSoup, which has its own.
    private static let openingWhitespace: Set<Character> = [" ", "\t", "\n", "\u{0C}", "\r", "\r\n"]

    // MARK: The Pass

    /// What a pass found in markup it did not refuse.
    struct Inspection: Equatable {
        /// How deep the tree's deepest element will be, `html` at 1: never less
        /// than the parser's real tree, which the limit is on.
        var deepest = 0
        /// What takes a node in the tree: start tags, comments, and declarations
        /// read, and the elements the parser makes beyond them. An end tag takes none.
        var tags = 0
        /// How many of those nodes hold attributes.
        var tagsWithAttributes = 0
        /// The attributes they hold.
        var attributes = 0
        /// The most attributes on any one tag.
        var mostAttributesOnATag = 0
        /// What SwiftSoup spends where its time grows with the square of the
        /// markup, in about a nanosecond each; next to nothing in a real book.
        var work = 0
        /// Declarations that would trap SwiftSoup's XML parser, whole, in order.
        var brokenDeclarations: [Range<Int>] = []

        /// What the tree will take, in plain elements with their text, about 800
        /// bytes each: a tag's first attribute takes about twice that again, and
        /// each further one about a third of it.
        var memoryUnits: Int { tags + 2 * tagsWithAttributes + attributes / 3 }
    }

    /// One pass over `bytes`, as the parser for `dialect` will read them.
    /// - Throws: `MarkupRefusal` as soon as a limit is passed.
    static func inspect(_ bytes: [UInt8], as dialect: Dialect, limits: Limits) throws -> Inspection {
        var pass = Pass(bytes: bytes, limits: limits)
        switch dialect {
        case .xml: try pass.readXML()
        case .html: try pass.readHTML(fragment: false)
        case .bodyFragment: try pass.readHTML(fragment: true)
        }
        return pass.inspection
    }

    /// The state of one pass.
    private struct Pass {
        var scanner: MarkupScanner
        let limits: Limits
        var inspection = Inspection()

        init(bytes: [UInt8], limits: Limits) {
            scanner = MarkupScanner(bytes: bytes)
            self.limits = limits
        }

        /// Reads as `XmlTreeBuilder` does, which reads no text differently from any other.
        mutating func readXML() throws {
            var open = XMLOpenElements(bytes: scanner.bytes)
            while true {
                switch scanner.next() {
                case .text:
                    break
                case let .startTag(tag):
                    try countNode()
                    try noteAttributes(of: tag, holdsThem: true)
                    open.start(tag)
                    // A self-closed element stands a level below what is open.
                    try noteDepth(tag.isSelfClosing ? open.depth + 1 : open.depth)
                case let .endTag(tag):
                    try noteAttributes(of: tag, holdsThem: false)
                    open.end(tag)
                case .comment, .doctype:
                    try countNode()
                case let .declaration(data, whole):
                    try countNode()
                    if let tag = MarkupDeclaration.tagOfTakenApartDeclaration(scanner.bytes[data]) {
                        try noteAttributes(of: tag, holdsThem: true)
                    } else if MarkupDeclaration.isTakenApart(scanner.bytes[data]) {
                        inspection.brokenDeclarations.append(whole)
                    }
                case .finished:
                    return
                }
            }
        }

        /// Reads as `HtmlTreeBuilder` does, whose start tags can change how the text
        /// after them is read: a document, or a fragment in a body.
        mutating func readHTML(fragment: Bool) throws {
            var model = HTMLTreeModel(bytes: scanner.bytes, fragment: fragment)
            // Every document the parser makes has `html`, and `head` and `body` in it.
            try noteDepth(2)
            var counted = HTMLTreeModel.Costs()
            while true {
                switch scanner.next() {
                case let .text(range):
                    model.text(range)
                case let .startTag(tag):
                    try countNode()
                    try noteAttributes(of: tag, holdsThem: true)
                    let change = model.start(tag, name: scanner.lowercasedName(tag.name))
                    if model.tagsAreCertain {
                        switch change {
                        case .none:
                            break
                        case let .rawText(kind):
                            // A raw text element holds its text, and closes with it.
                            _ = scanner.skipRawText(kind, name: scanner.lowercasedName(tag.name))
                            try addWork(scanner.takeWork())
                        case .rest:
                            scanner.skipToEnd()
                        }
                    }
                case let .endTag(tag):
                    try noteAttributes(of: tag, holdsThem: false)
                    model.end(name: scanner.lowercasedName(tag.name))
                case .comment, .doctype, .declaration:
                    try countNode()
                case .finished:
                    try noteDepth(model.deepest)
                    return
                }
                try noteDepth(model.deepest)
                guard model.tagsAreCertain else {
                    try countEverythingAhead(from: model.openDepth)
                    return
                }
                // Elements made again, or made up by the parser, cost what any other does.
                let costs = model.costs
                try countMade(costs.elements - counted.elements)
                try countAttributes(costs.attributes - counted.attributes, onTags: costs.elementsWithAttributes - counted.elementsWithAttributes)
                try addWork(costs.work - counted.work)
                counted = costs
            }
        }

        /// The markup can no longer be read tag by tag: every tag that could
        /// lie ahead is counted as open and never closed.
        private mutating func countEverythingAhead(from depth: Int) throws {
            let ahead = scanner.tagsPossiblyAhead()
            try noteDepth(depth + ahead.starts)
            try countMade(ahead.tags)
            scanner.skipToEnd()
        }

        /// Records how many attributes a tag names, which it keeps unless it is an end tag.
        private mutating func noteAttributes(of tag: MarkupScanner.Tag, holdsThem: Bool) throws {
            inspection.mostAttributesOnATag = max(inspection.mostAttributesOnATag, tag.attributeCount)
            guard tag.attributeCount <= limits.mostAttributesOnATag else {
                throw MarkupRefusal.tooManyAttributes(limit: limits.mostAttributesOnATag)
            }
            if holdsThem, tag.attributeCount > 0 { try countAttributes(tag.attributeCount, onTags: 1) }
        }

        /// Counts `made` more attributes, held by that many more tags.
        private mutating func countAttributes(_ made: Int, onTags tags: Int) throws {
            inspection.attributes += made
            inspection.tagsWithAttributes += tags
            try checkMemory()
        }

        /// Refuses markup whose tree would take too much memory.
        private func checkMemory() throws {
            guard inspection.memoryUnits <= limits.mostMemoryUnits else { throw MarkupRefusal.tooMuchMarkup }
        }

        /// Counts `made` more of what SwiftSoup's time grows with the square of.
        private mutating func addWork(_ made: Int) throws {
            inspection.work += made
            guard inspection.work <= limits.mostWork else { throw MarkupRefusal.tooMuchWork }
        }

        /// Counts one more thing that takes memory.
        private mutating func countNode() throws {
            try countMade(1)
        }

        /// Counts `made` more things that take memory.
        private mutating func countMade(_ made: Int) throws {
            inspection.tags += made
            try checkMemory()
        }

        /// Records how many elements are open.
        private mutating func noteDepth(_ depth: Int) throws {
            inspection.deepest = max(inspection.deepest, depth)
            guard depth <= limits.deepestNesting else { throw MarkupRefusal.nestedTooDeeply(limit: limits.deepestNesting) }
        }
    }

    // MARK: Neutralizing

    /// `markup` with each declaration that would trap the XML parser written as
    /// an empty comment; `markup` itself when there are none, as in every real book.
    /// - Throws: `MarkupRefusal` when the markup passes a limit.
    private static func neutralized(_ markup: String, limits: Limits) throws -> String {
        let bytes = Array(markup.utf8)
        let declarations = try inspect(bytes, as: .xml, limits: limits).brokenDeclarations
        guard !declarations.isEmpty else { return markup }
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var cursor = 0
        for declaration in declarations {
            result.append(contentsOf: bytes[cursor..<declaration.lowerBound])
            result.append(contentsOf: emptyComment)
            cursor = declaration.upperBound
        }
        result.append(contentsOf: bytes[cursor...])
        return String(decoding: result, as: UTF8.self)
    }

    /// What a broken declaration is rewritten as: a node where it stood, as a
    /// comment, with nothing for a tree that reads comments to pass on.
    private static let emptyComment = Array("<!---->".utf8)
}

// MARK: - Declarations

/// What SwiftSoup's XML parser does with a declaration
/// (`XmlTreeBuilder.insert(_:)` for a comment token).
enum MarkupDeclaration {
    /// Whether SwiftSoup takes the declaration whose text is `data` apart: it
    /// has two or more characters and begins `?` or `!`. Any other is a comment to it.
    static func isTakenApart(_ data: ArraySlice<UInt8>) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.count > 1 && (text.hasPrefix("?") || text.hasPrefix("!"))
    }

    /// The start tag the declaration whose text is `data` makes when it is taken
    /// apart, or nil when it makes none: `<` and everything but its first and last
    /// character and `>` is parsed again.
    ///
    /// Text whose name begins with a letter makes a tag, unless an open quotation
    /// mark runs through the `>` so that the tag never ends. What begins another
    /// way is taken to make none, without looking further: a real declaration
    /// never does, and what such a one is rewritten as reads the same.
    static func tagOfTakenApartDeclaration(_ data: ArraySlice<UInt8>) -> MarkupScanner.Tag? {
        guard isTakenApart(data) else { return nil }
        let inner = Array(String(decoding: data, as: UTF8.self).dropFirst().dropLast().utf8)
        guard let first = inner.first, Ascii.isLetter(first) else { return nil }
        var scanner = MarkupScanner(bytes: [Ascii.lessThan] + inner + [Ascii.greaterThan])
        guard case let .startTag(tag) = scanner.next() else { return nil }
        return tag
    }

    /// Whether the declaration whose text is `data` stops the process: SwiftSoup
    /// takes it apart, and asks the result for an element it does not hold.
    static func wouldTrap(_ data: ArraySlice<UInt8>) -> Bool {
        isTakenApart(data) && tagOfTakenApartDeclaration(data) == nil
    }
}

// MARK: - Refusals

/// Why markup is not read. Each sentence is one a listener can act on, and none
/// says the file is damaged, since it may not be.
enum MarkupRefusal: LocalizedError, Equatable {
    /// The markup holds elements nested more than `limit` levels deep.
    case nestedTooDeeply(limit: Int)
    /// One document's tree would take too much memory.
    case tooMuchMarkup
    /// One tag has more than `limit` attributes.
    case tooManyAttributes(limit: Int)
    /// The markup would take the parser far longer than its size warrants.
    case tooMuchWork

    var errorDescription: String? {
        switch self {
        case let .nestedTooDeeply(limit):
            return "This file's markup nests more than \(limit.formatted()) levels deep, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        case .tooMuchMarkup:
            return "One document in this file holds too much markup for TextMouth to read without running out of memory. "
                + "Divide the document into smaller files, then import them."
        case let .tooManyAttributes(limit):
            return "One tag in this file has more than \(limit.formatted()) attributes, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        case .tooMuchWork:
            return "This file's markup is built in a way that would take TextMouth far too long to read. "
                + "Get another copy of the file, or save it in another format, then import it again."
        }
    }
}
