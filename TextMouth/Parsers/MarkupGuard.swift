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
/// One pass over the bytes (`MarkupScanner`), as linear as reading them, finds
/// the same tags the parser will, and follows the same stack it will keep
/// (`XMLOpenElements`, `HTMLOpenElements`). Past the limits it refuses with a
/// sentence, before anything is built.
enum MarkupGuard {

    // MARK: Limits

    /// What markup may hold and still be read.
    struct Limits: Equatable, Sendable {
        /// The deepest nesting read, by `Inspection.deepest`.
        var deepestNesting: Int
        /// The most tags read in one document, by `Inspection.tags`.
        var mostTags: Int
        /// The most attributes read on one tag.
        var mostAttributesOnATag: Int

        /// The limits every reading has.
        ///
        /// REAL_LIMITS
        static let standard = Limits(deepestNesting: 256, mostTags: 4_000_000, mostAttributesOnATag: 10_000)
    }

    /// The limits in force: `Limits.standard`, unless a test binds others with
    /// `MarkupGuard.$limits.withValue(_:operation:)`, which changes only the
    /// reading that operation does on its own thread.
    @TaskLocal static var limits = Limits.standard

    // MARK: Parsing

    /// `markup` parsed as `SwiftSoup.parse(_:_:)` parses it, by its XML parser
    /// when it opens with `<?xml` and its HTML parser otherwise, but that it can
    /// neither trap nor overflow the stack.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parse(_ markup: String, baseURI: String = "") throws -> Document {
        if opensAsXML(markup) {
            return try parseXML(markup, baseURI: baseURI)
        }
        _ = try inspect(Array(markup.utf8), as: .html, limits: limits)
        return try SwiftSoup.parseHTML(markup, baseURI)
    }

    /// `markup` parsed by SwiftSoup's XML parser, whatever it opens with, with
    /// nesting read up to `deepestNesting`, or the limit in force.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parseXML(_ markup: String, baseURI: String = "", deepestNesting: Int? = nil) throws -> Document {
        let bytes = Array(markup.utf8)
        var limits = limits
        if let deepestNesting { limits.deepestNesting = deepestNesting }
        let inspection = try inspect(bytes, as: .xml, limits: limits)
        return try SwiftSoup.parse(neutralizing(inspection.brokenDeclarations, in: bytes, of: markup), baseURI, Parser.xmlParser())
    }

    /// The fragment `markup` in the body of an empty document, as
    /// `SwiftSoup.parseBodyFragment(_:)` makes one, by its HTML parser.
    /// - Throws: `MarkupRefusal` when the markup passes a limit, or SwiftSoup's error.
    static func parseBodyFragment(_ markup: String) throws -> Document {
        _ = try inspect(Array(markup.utf8), as: .html, limits: limits)
        return try SwiftSoup.parseBodyFragment(markup)
    }

    // MARK: Which Parser

    /// Which of SwiftSoup's parsers reads a document.
    enum Dialect {
        case html, xml
    }

    /// Whether SwiftSoup's automatic parse would choose its XML parser:
    /// `looksLikeXml`, which skips what Swift calls whitespace, and compares
    /// characters, not bytes. The guard chooses now, and asks for that parser by name.
    static func opensAsXML(_ markup: String) -> Bool {
        markup.drop(while: \.isWhitespace).hasPrefix("<?xml")
    }

    // MARK: The Pass

    /// What a pass found in markup it did not refuse.
    struct Inspection: Equatable {
        /// The most elements open at once, by the count the limit is on.
        var deepest = 0
        /// The tags, comments, and declarations read, and the elements the parser makes beyond them.
        var tags = 0
        /// The most attributes on any one tag.
        var mostAttributes = 0
        /// Declarations that would trap SwiftSoup's XML parser, whole, in order.
        var brokenDeclarations: [Range<Int>] = []
    }

    /// One pass over `bytes`, as the parser for `dialect` will read them.
    /// - Throws: `MarkupRefusal` as soon as a limit is passed.
    static func inspect(_ bytes: [UInt8], as dialect: Dialect, limits: Limits) throws -> Inspection {
        var pass = Pass(bytes: bytes, limits: limits)
        switch dialect {
        case .xml: try pass.readXML()
        case .html: try pass.readHTML()
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
                    try count(tag)
                    open.start(tag)
                    try noteDepth(open.depth)
                case let .endTag(tag):
                    try count(tag)
                    open.end(tag)
                case .comment, .doctype:
                    try countNode()
                case let .declaration(data, whole):
                    try countNode()
                    if MarkupDeclaration.wouldTrap(scanner.bytes[data]) {
                        inspection.brokenDeclarations.append(whole)
                    }
                case .finished:
                    return
                }
            }
        }

        /// Reads as `HtmlTreeBuilder` does, whose start tags can change how the text after them is read.
        mutating func readHTML() throws {
            var open = HTMLOpenElements(bytes: scanner.bytes)
            // The elements the parser has that the count leaves out: `html` and `body`.
            let unseen = 2
            var madeCounted = 0
            while true {
                switch scanner.next() {
                case let .text(range):
                    open.text(range)
                case let .startTag(tag):
                    try count(tag)
                    let change = open.start(tag, name: scanner.lowercasedName(tag.name))
                    guard open.tagsAreCertain else {
                        try countEverythingAhead(from: open.depth + unseen)
                        return
                    }
                    switch change {
                    case .none:
                        break
                    case let .rawText(kind):
                        // A raw text element comes off the stack with its text.
                        _ = scanner.skipRawText(kind, name: scanner.lowercasedName(tag.name))
                    case .rest:
                        scanner.skipToEnd()
                    }
                case let .endTag(tag):
                    try count(tag)
                    open.end(tag, name: scanner.lowercasedName(tag.name))
                case .comment, .doctype, .declaration:
                    try countNode()
                case .finished:
                    return
                }
                try noteDepth(open.depth + unseen)
                // Elements made again, or made by a stray end tag, cost what any other does.
                try countMade(open.madeElements - madeCounted)
                madeCounted = open.madeElements
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

        /// Counts a tag and its attributes.
        private mutating func count(_ tag: MarkupScanner.Tag) throws {
            try countNode()
            inspection.mostAttributes = max(inspection.mostAttributes, tag.attributeCount)
            guard tag.attributeCount <= limits.mostAttributesOnATag else {
                throw MarkupRefusal.tooManyAttributes(limit: limits.mostAttributesOnATag)
            }
        }

        /// Counts one more thing that takes memory.
        private mutating func countNode() throws {
            try countMade(1)
        }

        /// Counts `made` more things that take memory.
        private mutating func countMade(_ made: Int) throws {
            inspection.tags += made
            guard inspection.tags <= limits.mostTags else { throw MarkupRefusal.tooManyTags(limit: limits.mostTags) }
        }

        /// Records how many elements are open.
        private mutating func noteDepth(_ depth: Int) throws {
            inspection.deepest = max(inspection.deepest, depth)
            guard depth <= limits.deepestNesting else { throw MarkupRefusal.nestedTooDeeply(limit: limits.deepestNesting) }
        }
    }

    // MARK: Neutralizing

    /// `markup`, whose bytes are `bytes`, with each of `declarations` written
    /// as an empty comment; `markup` itself when there are none, as in every real book.
    private static func neutralizing(_ declarations: [Range<Int>], in bytes: [UInt8], of markup: String) -> String {
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
    /// Whether the declaration whose text is `data` stops the process. The text
    /// is taken apart when it has two or more characters and begins `?` or `!`:
    /// `<` and everything but its first and last character and `>` is parsed
    /// again, and the result must hold an element.
    ///
    /// A tag whose name begins with a letter does, unless an open quotation
    /// mark runs through the `>` so that the tag never ends. Whatever begins
    /// another way is taken to trap, without looking further: a real declaration
    /// never does, and what such a one is rewritten as reads the same.
    static func wouldTrap(_ data: ArraySlice<UInt8>) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        guard text.count > 1, text.hasPrefix("?") || text.hasPrefix("!") else { return false }
        let inner = Array(text.dropFirst().dropLast().utf8)
        guard let first = inner.first, Ascii.isLetter(first) else { return true }
        var scanner = MarkupScanner(bytes: [Ascii.lessThan] + inner + [Ascii.greaterThan])
        guard case .startTag = scanner.next() else { return true }
        return false
    }
}

// MARK: - Refusals

/// Why markup is not read. Each sentence is one a listener can act on, and none
/// says the file is damaged, since it may not be.
enum MarkupRefusal: LocalizedError, Equatable {
    /// The markup holds elements nested more than `limit` levels deep.
    case nestedTooDeeply(limit: Int)
    /// One document holds more than `limit` tags.
    case tooManyTags(limit: Int)
    /// One tag has more than `limit` attributes.
    case tooManyAttributes(limit: Int)

    var errorDescription: String? {
        switch self {
        case let .nestedTooDeeply(limit):
            return "This file's markup nests more than \(limit.formatted()) levels deep, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        case let .tooManyTags(limit):
            return "One document in this file holds more than \(limit.formatted()) tags, too many for TextMouth to read without "
                + "running out of memory. Divide the document into smaller files, then import them."
        case let .tooManyAttributes(limit):
            return "One tag in this file has more than \(limit.formatted()) attributes, which TextMouth can't read safely. "
                + "Get another copy of the file, or save it in another format, then import it again."
        }
    }
}
