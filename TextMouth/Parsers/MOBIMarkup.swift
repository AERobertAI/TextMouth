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
    static func html(of text: [UInt8], range: Range<Int>, anchors: ArraySlice<Anchor>) -> [UInt8] {
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

        forEachTag(in: text, within: range) { tag in
            guard isMobipocketTag(text, tag: tag) else { return }
            // The anchors up to this tag, then the text, then past the tag.
            copy(to: tag.lowerBound)
            cursor = tag.upperBound
        }
        copy(to: range.upperBound)
        return output
    }

    // MARK: Words

    /// Whether `markup` holds a word a listener could hear: a letter or
    /// digit in its text, or in the `alt` of a picture. The markup of a
    /// head, a style sheet, or a script is not looked through, but a book
    /// of only blank documents holds none either way, and that is all this is
    /// asked: a KF8 half with no words at all falls back to the MOBI 6 half.
    static func hasWords(_ markup: [UInt8]) -> Bool {
        var position = 0
        var inTag = false
        var quote: UInt8 = 0
        var inHead = false
        while position < markup.count {
            let byte = markup[position]
            if inTag {
                if quote != 0 {
                    if byte == quote { quote = 0 }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    inTag = false
                }
                // A picture's description counts.
                if !inHead, byte == UInt8(ascii: "a"), matches(altEquals, in: markup, at: position),
                   position > 0, isSpace(markup[position - 1]) {
                    let valueStart = position + altEquals.count + (position + altEquals.count < markup.count
                        && (markup[position + altEquals.count] == UInt8(ascii: "\"") || markup[position + altEquals.count] == UInt8(ascii: "'")) ? 1 : 0)
                    var cursor = valueStart
                    while cursor < markup.count, cursor < valueStart + 256, !isTagEnd(markup[cursor]) {
                        if isAlphanumeric(markup[cursor]) { return true }
                        cursor += 1
                    }
                }
            } else if byte == UInt8(ascii: "<"), position + 1 < markup.count, startsTag(markup[position + 1]) {
                inTag = true
                // The head holds the title, which is not the book's words.
                if matches(headName, in: markup, at: position + 1, endsName: true) { inHead = true }
                if matches(headEndName, in: markup, at: position + 1, endsName: true) { inHead = false }
            } else if !inHead, isAlphanumeric(byte) {
                return true
            }
            position += 1
        }
        return false
    }

    private static let altEquals = Array("alt=".utf8)
    private static let headName = Array("head".utf8)

    /// Whether `byte` ends an attribute value that is not quoted, or the tag.
    private static func isTagEnd(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") || byte == UInt8(ascii: ">")
    }

    /// Whether `byte` is a letter or digit of ASCII, or a byte of a multibyte
    /// character (which is a letter, a digit, or a symbol; a book of only symbols is not one anyone reads).
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isLetter(byte) || isDigit(byte) || byte >= 0x80
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
