import Foundation

/// The HTML dialect of a Kindle (MOBI 6) book, worked on as bytes.
///
/// A MOBI book's text is old HTML whose links and table of contents name
/// places by `filepos`: a count of bytes into the decompressed text. Those
/// counts only mean something before the text is decoded or parsed, so this
/// finds every place the book names, puts an anchor (`<a id="filepos-N"></a>`)
/// at each, and takes out the Mobipocket tags (`mbp:`) that are layout, never
/// words, all on the bytes. The result is HTML that `HTMLToMarkdownConverter`
/// reads like any other, with the book's links and contents landing on their
/// words.
///
/// Written from the format's specification (the MobileRead wiki's "MOBI"
/// page), with foliate-js's `mobi.js` (MIT) read as a map of the dialect:
/// its `fileposRegex` and `mbpPagebreakRegex` are the model of the scan here.
/// Nothing is copied; the scan is a hand-written tag walk with no regular
/// expression over the whole text, so a hostile file costs a single pass.
enum MOBIMarkup {

    /// Most places a book may name by `filepos` that get an anchor. A real
    /// book names a few hundred; a dictionary, some tens of thousands. A
    /// hostile one could name a place in every tag, so the places beyond this
    /// many (in file order) get none: a link to one has no destination, and
    /// its words are read all the same.
    static let maximumFileposTargets = 500_000

    /// Most levels of unclosed elements a section may hold. Every section is
    /// parsed into a tree and converted by code that visits it recursively,
    /// so a file that nests tens of thousands of elements would overflow the
    /// stack; real books nest a dozen.
    static let maximumNesting = 256

    /// What a first pass over the text found.
    struct Scan: Equatable {
        /// Every byte offset a `filepos` attribute names.
        var fileposTargets: Set<Int> = []
        /// The offset of each `<mbp:pagebreak>` tag, in order.
        var pageBreakOffsets: [Int] = []
        /// Where the first `<body>` tag starts, if the text has one.
        var bodyOffset: Int?
        /// Where the first `</head>` tag ends, if the text has one.
        var headEnd: Int?

        /// Where the words of the book start: at its `<body>` tag, else after
        /// its `</head>`, else at the start of the text. What comes before
        /// is the head (the title, an OEB `<metadata>` block with dc:Title and
        /// dc:Creator, a `<guide>`), which is about the book and is not read
        /// aloud: SwiftSoup moves a head element it does not know into the
        /// body, where its words would be heard.
        var bodyStart: Int { bodyOffset ?? headEnd ?? 0 }
    }

    /// How much of a text is looked at to tell whether it is HTML.
    static let htmlSniffLength = 4096

    /// Whether `text` is HTML: it holds an `<html` or a `<body` tag, in any
    /// letter case, in its first `htmlSniffLength` bytes. A plain PalmDOC
    /// book (`TEXtREAd`) with markup is an early Mobipocket book whose text
    /// is HTML, and is read as one; calibre's reader does the same.
    static func looksLikeHTML(_ text: [UInt8]) -> Bool {
        let end = min(text.count, htmlSniffLength)
        var position = 0
        while position < end {
            if text[position] == UInt8(ascii: "<"),
               matches(htmlName, in: text, at: position + 1, limit: end) || matches(bodyName, in: text, at: position + 1, limit: end) {
                return true
            }
            position += 1
        }
        return false
    }

    /// A place to put an anchor: the offset the book names, and the place
    /// the anchor goes, which is the start of the tag that offset lies in
    /// (an offset in the middle of a tag cannot take an anchor there).
    struct Anchor: Equatable {
        var offset: Int
        var position: Int

        /// The id the anchor takes, which a heading target names.
        var id: String { MOBIMarkup.anchorID(forOffset: offset) }
    }

    /// The id of the anchor at byte `offset` of the text.
    static func anchorID(forOffset offset: Int) -> String { "filepos-\(offset)" }

    // MARK: Tags

    /// Calls `body` with the range of each tag in `text[range]`, in order,
    /// from its `<` through its `>`. A tag begins at `<` followed by a
    /// letter, `/`, `!`, or `?`; any other `<` is text. A quoted attribute
    /// value (the quote right after `=`) may hold a `>`, and a comment ends
    /// at `-->`. A tag that never ends runs to the end of the range.
    static func forEachTag(in text: [UInt8], within range: Range<Int>, _ body: (Range<Int>) -> Void) {
        var position = range.lowerBound
        let end = range.upperBound
        while position < end {
            guard text[position] == UInt8(ascii: "<"), position + 1 < end, startsTag(text[position + 1]) else {
                position += 1
                continue
            }
            let start = position
            position = tagEnd(in: text, from: start, limit: end)
            body(start..<position)
        }
    }

    /// Whether `byte`, right after a `<`, makes it the start of a tag.
    private static func startsTag(_ byte: UInt8) -> Bool {
        isLetter(byte) || byte == UInt8(ascii: "/") || byte == UInt8(ascii: "!") || byte == UInt8(ascii: "?")
    }

    /// Where the tag that starts at `start` ends: just after its `>`, or
    /// `limit` when it has none.
    private static func tagEnd(in text: [UInt8], from start: Int, limit: Int) -> Int {
        // A comment ends at "-->", not at the first ">".
        if hasPrefix("<!--", in: text, at: start, limit: limit) {
            var position = start + 4
            while position + 2 < limit {
                if text[position] == UInt8(ascii: "-"), text[position + 1] == UInt8(ascii: "-"),
                   text[position + 2] == UInt8(ascii: ">") {
                    return position + 3
                }
                position += 1
            }
            return limit
        }
        var position = start + 1
        // The last byte that was not a space: a quote opens a value only
        // right after "=".
        var previous: UInt8 = 0
        var openQuote: UInt8?
        while position < limit {
            let byte = text[position]
            if let quote = openQuote {
                if byte == quote { openQuote = nil }
            } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'"), previous == UInt8(ascii: "=") {
                openQuote = byte
            } else if byte == UInt8(ascii: ">") {
                return position + 1
            }
            if !isSpace(byte) { previous = byte }
            position += 1
        }
        return limit
    }

    // MARK: Scan

    /// The names scanned for, as bytes made once: a hostile book may hold
    /// millions of tags, and each is looked at for these.
    private static let fileposName = Array("filepos".utf8)
    private static let pageBreakName = Array("pagebreak".utf8)
    private static let prefixedPageBreakName = Array("mbp:pagebreak".utf8)
    private static let mobipocketPrefix = Array("mbp:".utf8)
    private static let htmlName = Array("html".utf8)
    private static let bodyName = Array("body".utf8)
    private static let headEndName = Array("/head".utf8)

    /// Finds the offsets the book's `filepos` attributes name, and where
    /// its `<mbp:pagebreak>` tags are.
    static func scan(_ text: [UInt8]) -> Scan {
        var result = Scan()
        forEachTag(in: text, within: 0..<text.count) { tag in
            if result.fileposTargets.count < maximumFileposTargets, let target = fileposValue(in: text, tag: tag) {
                result.fileposTargets.insert(target)
            }
            if isPageBreak(text, tag: tag) { result.pageBreakOffsets.append(tag.lowerBound) }
            if result.bodyOffset == nil, matches(bodyName, in: text, at: tag.lowerBound + 1, limit: tag.upperBound, endsName: true) {
                result.bodyOffset = tag.lowerBound
            }
            if result.headEnd == nil, matches(headEndName, in: text, at: tag.lowerBound + 1, limit: tag.upperBound, endsName: true) {
                result.headEnd = tag.upperBound
            }
        }
        return result
    }

    /// The number a `filepos` attribute of the tag holds, or nil when it has
    /// none. The number may be quoted and is often padded with zeros
    /// (`filepos=0000012345`); one of more than ten digits is not a place.
    private static func fileposValue(in text: [UInt8], tag: Range<Int>) -> Int? {
        // A comment, a declaration, or an instruction holds no attributes, so
        // a filepos inside one (such as <!-- <a filepos=9> -->) names nothing.
        guard tag.lowerBound + 1 < tag.upperBound,
              text[tag.lowerBound + 1] != UInt8(ascii: "!"), text[tag.lowerBound + 1] != UInt8(ascii: "?") else { return nil }
        let name = fileposName
        var position = tag.lowerBound + 1
        while position + name.count < tag.upperBound {
            // The name starts an attribute: after a space. (One inside another
            // attribute's quoted value, such as title="filepos=7", is no attribute.)
            guard isSpace(text[position - 1]), matches(name, in: text, at: position) else {
                position += 1
                continue
            }
            var cursor = position + name.count
            while cursor < tag.upperBound, isSpace(text[cursor]) { cursor += 1 }
            guard cursor < tag.upperBound, text[cursor] == UInt8(ascii: "=") else { position += 1; continue }
            cursor += 1
            while cursor < tag.upperBound, isSpace(text[cursor]) { cursor += 1 }
            if cursor < tag.upperBound, text[cursor] == UInt8(ascii: "\"") || text[cursor] == UInt8(ascii: "'") { cursor += 1 }
            var value = 0
            var digits = 0
            while cursor < tag.upperBound, isDigit(text[cursor]), digits <= 10 {
                value = value * 10 + Int(text[cursor] - UInt8(ascii: "0"))
                digits += 1
                cursor += 1
            }
            return digits > 0 && digits <= 10 ? value : nil
        }
        return nil
    }

    /// Whether the tag is a page break: `<mbp:pagebreak>`, or `<pagebreak>`
    /// without its prefix, as some books write it.
    private static func isPageBreak(_ text: [UInt8], tag: Range<Int>) -> Bool {
        let start = tag.lowerBound + 1
        return matches(prefixedPageBreakName, in: text, at: start, limit: tag.upperBound, endsName: true)
            || matches(pageBreakName, in: text, at: start, limit: tag.upperBound, endsName: true)
    }

    /// Whether the tag is a Mobipocket tag (`<mbp:...>` or `</mbp:...>`, or a
    /// page break written without its prefix), which is layout and never words.
    private static func isMobipocketTag(_ text: [UInt8], tag: Range<Int>) -> Bool {
        var start = tag.lowerBound + 1
        if start < tag.upperBound, text[start] == UInt8(ascii: "/") { start += 1 }
        return matches(mobipocketPrefix, in: text, at: start, limit: tag.upperBound)
            || isPageBreak(text, tag: tag)
    }

    // MARK: Anchors

    /// The places the offsets in `offsets` (ascending, without repeats) take
    /// anchors: each offset itself, unless it lies inside a tag, when it is
    /// that tag's start. An offset at or past the end of the text names no
    /// place and is left out.
    static func anchors(for offsets: [Int], in text: [UInt8]) -> [Anchor] {
        let wanted = offsets.filter { $0 >= 0 && $0 < text.count }
        var anchors = wanted.map { Anchor(offset: $0, position: $0) }
        var next = 0
        forEachTag(in: text, within: 0..<text.count) { tag in
            // Offsets up to the tag's start are outside it, in the text.
            while next < anchors.count, anchors[next].position <= tag.lowerBound { next += 1 }
            // Offsets inside the tag take the tag's start.
            while next < anchors.count, anchors[next].position < tag.upperBound {
                anchors[next].position = tag.lowerBound
                next += 1
            }
        }
        return anchors
    }

    /// The bytes of `text[range]` with an anchor written at each of
    /// `anchors` that lies in the range (they are in ascending order of
    /// position), and the Mobipocket tags taken out. An anchor is an empty
    /// link, `<a id="filepos-N"></a>`, which the converter reads as a
    /// destination and no word.
    /// - Throws: `MOBIError.damaged` for a section that nests elements more
    ///   than `maximumNesting` levels deep.
    static func html(of text: [UInt8], range: Range<Int>, anchors: ArraySlice<Anchor>) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(range.count + anchors.count * 24)
        var cursor = range.lowerBound
        var next = anchors.startIndex

        /// Copies the text up to `position`, then writes every anchor placed there.
        func copy(to position: Int) {
            while next < anchors.endIndex, anchors[next].position <= position {
                let anchor = anchors[next]
                if anchor.position >= cursor {
                    output.append(contentsOf: text[cursor..<anchor.position])
                    cursor = anchor.position
                }
                output.append(contentsOf: "<a id=\"\(anchor.id)\"></a>".utf8)
                next += 1
            }
            if position > cursor {
                output.append(contentsOf: text[cursor..<position])
                cursor = position
            }
        }

        var depth = 0
        var deepest = 0
        forEachTag(in: text, within: range) { tag in
            depth = max(0, depth + nestingChange(of: tag, in: text))
            deepest = max(deepest, depth)
            guard isMobipocketTag(text, tag: tag) else { return }
            // The anchors up to this tag, then the text, then past the tag.
            copy(to: tag.lowerBound)
            cursor = tag.upperBound
        }
        guard deepest <= maximumNesting else {
            throw MOBIError.damaged("its markup is nested more than \(maximumNesting) levels deep")
        }
        copy(to: range.upperBound)
        return output
    }

    /// Throws unless `markup` nests its elements no more than
    /// `maximumNesting` levels deep (the same estimate `html(of:range:anchors:)`
    /// makes). A KF8 part is joined from pieces of the text and then checked
    /// whole, in one pass over its bytes.
    /// - Throws: `MOBIError.damaged` for markup nested deeper.
    static func requireShallowNesting(of markup: [UInt8]) throws {
        var depth = 0
        var deepest = 0
        forEachTag(in: markup, within: 0..<markup.count) { tag in
            depth = max(0, depth + nestingChange(of: tag, in: markup))
            deepest = max(deepest, depth)
        }
        guard deepest <= maximumNesting else {
            throw MOBIError.damaged("its markup is nested more than \(maximumNesting) levels deep")
        }
    }

    // MARK: Nesting

    /// Elements that have no end tag.
    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
        // Old books write these without an end tag as well.
        "basefont", "frame", "isindex",
    ]

    /// Elements the HTML parser closes by itself when the next one begins, so
    /// a book may leave their end tags out and they never nest deeply.
    private static let selfClosingByParser: Set<String> = [
        "p", "li", "dt", "dd", "tr", "td", "th", "option", "tbody", "thead", "tfoot", "colgroup", "caption",
    ]

    /// How much `tag` changes the number of open elements: 1 for the start
    /// of one that stays open, -1 for the end of one, 0 for a comment, a
    /// declaration, a void or self-closed element, and one the parser closes
    /// by itself. It is an estimate for a limit, not a parse: a book with
    /// more end tags than start tags cannot take the count below 0.
    private static func nestingChange(of tag: Range<Int>, in text: [UInt8]) -> Int {
        let first = tag.lowerBound + 1
        guard first < tag.upperBound, text[first] != UInt8(ascii: "!"), text[first] != UInt8(ascii: "?") else { return 0 }
        let closing = text[first] == UInt8(ascii: "/")
        var end = closing ? first + 1 : first
        let nameStart = end
        while end < tag.upperBound, !isSpace(text[end]), text[end] != UInt8(ascii: "/"), text[end] != UInt8(ascii: ">") {
            end += 1
        }
        guard end > nameStart else { return 0 }
        // The names in the two sets are at most eight letters, so a longer
        // name is looked up in neither (and no string is made of it).
        if end - nameStart <= 8 {
            let name = String(decoding: text[nameStart..<end], as: UTF8.self).lowercased()
            if voidElements.contains(name) || selfClosingByParser.contains(name) { return 0 }
        }
        if closing { return -1 }
        // "<x/>" closes itself.
        let selfClosed = tag.upperBound - tag.lowerBound >= 3 && text[tag.upperBound - 1] == UInt8(ascii: ">")
            && text[tag.upperBound - 2] == UInt8(ascii: "/")
        return selfClosed ? 0 : 1
    }

    // MARK: Bytes

    /// Whether the ASCII `word` is in `text` at `position`, in any letter
    /// case, inside `limit`; with `endsName`, only if a name ends there
    /// (a space, `/`, or `>` follows, or the limit is reached).
    private static func matches(_ word: [UInt8], in text: [UInt8], at position: Int, limit: Int? = nil, endsName: Bool = false) -> Bool {
        let end = limit ?? text.count
        guard position >= 0, position + word.count <= end else { return false }
        for (index, expected) in word.enumerated() where lowercase(text[position + index]) != expected {
            return false
        }
        guard endsName else { return true }
        let after = position + word.count
        return after >= end || isSpace(text[after]) || text[after] == UInt8(ascii: "/") || text[after] == UInt8(ascii: ">")
    }

    /// Whether the ASCII `prefix` is in `text` at `position`, case-sensitively.
    private static func hasPrefix(_ prefix: String, in text: [UInt8], at position: Int, limit: Int) -> Bool {
        let bytes = Array(prefix.utf8)
        guard position + bytes.count <= limit else { return false }
        return Array(text[position..<(position + bytes.count)]) == bytes
    }

    private static func lowercase(_ byte: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(lowercase(byte))
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }
}
