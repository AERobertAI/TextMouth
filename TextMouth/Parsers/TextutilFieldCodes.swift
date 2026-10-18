import Foundation
import SwiftSoup

/// Removes the field instructions that `/usr/bin/textutil` writes as text
/// into the HTML of a Word document.
///
/// A Word field (a table of contents, a hyperlink, a page reference) holds
/// an instruction and a visible result. textutil writes both as text, so
/// the sample `libreoffice-tdf81705_outlineLevel.doc` reads
/// `TOC \o "1-3" \h \z \u HYPERLINK \l "_Toc68096040" D PAGEREF _Toc68096040 \h 1`,
/// where `D` and `1` are the results. A listener must never hear the
/// instructions, and the results must stay.
///
/// The rule is narrow on purpose, because the text is also ordinary prose:
/// - a keyword counts only in capitals and at a word boundary;
/// - an unambiguous keyword (`HYPERLINK`, `PAGEREF`, and the like, which are
///   not words of English) is an instruction wherever it stands;
/// - an ambiguous keyword (`PAGE`, `INDEX`, `IF`, `TITLE`, `TOC`, and the
///   like, which are words or abbreviations) is an instruction only when a
///   switch (`\h`, `\* MERGEFORMAT`) or a bookmark name (`_Toc123`) follows
///   it: "Turn to PAGE 5" and "the INDEX finger" are prose and stay.
enum TextutilFieldCodes {

    // MARK: - Entry point

    /// Remove every field instruction from the text of `document`, in place.
    /// A paragraph that held an instruction and nothing else disappears;
    /// an empty paragraph that held no instruction is left as it was.
    static func removeInstructions(from document: Document) throws {
        // The blocks that lost an instruction, once each, in document order.
        var touched: [Element] = []
        var seen: Set<ObjectIdentifier> = []
        for node in TextutilHTMLStructure.textNodes(under: document.body() ?? document) {
            let text = node.getWholeText()
            let stripped = strip(text)
            guard stripped != text else { continue }
            if let block = block(containing: node), seen.insert(ObjectIdentifier(block)).inserted {
                touched.append(block)
            }
            if stripped.allSatisfy(\.isWhitespace) {
                try removeWithEmptiedSpans(node)
            } else {
                _ = node.text(stripped)
            }
        }
        // A block the removal left without text goes (a table cell stays:
        // the table keeps its shape); another has the white space that
        // stood beside the instruction trimmed from its ends.
        for block in touched {
            if canDisappear(block), !hasContent(block) {
                try block.remove()
            } else {
                trimEdges(of: block)
            }
        }
    }

    // MARK: - Keywords

    /// The keywords that are instructions wherever they stand: not words of
    /// English, so a capitalised one in prose is vanishingly rare.
    private static let unambiguousKeywords: Set<String> = [
        "HYPERLINK", "PAGEREF", "NUMPAGES", "INCLUDEPICTURE", "INCLUDETEXT", "MERGEFIELD",
        "NOTEREF", "STYLEREF", "FORMTEXT", "FORMCHECKBOX", "DOCPROPERTY", "NUMWORDS",
        "NUMCHARS", "LISTNUM", "FILENAME",
    ]

    /// The keywords that are also words or abbreviations of ordinary text:
    /// an instruction only when a switch or a bookmark name follows.
    private static let ambiguousKeywords: Set<String> = [
        "TOC", "REF", "PAGE", "SEQ", "TC", "XE", "INDEX", "DATE", "TIME", "SYMBOL", "EQ", "IF",
        "QUOTE", "AUTHOR", "TITLE", "SUBJECT", "KEYWORDS", "COMMENTS", "ADVANCE",
    ]

    /// The most bare words (a SEQ's identifier, a MERGEFIELD's name) that may
    /// stand between a keyword and its switches.
    private static let mostBareArguments = 3

    // MARK: - Scanning one text

    /// `text` with every field instruction removed. Equal to `text` when it
    /// holds none.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var kept = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            // A keyword is a run of capitals that starts a word.
            if isCapital(scalars[index]), index == 0 || !isWordCharacter(scalars[index - 1]) {
                var wordEnd = index
                while wordEnd < scalars.count, isCapital(scalars[wordEnd]) { wordEnd += 1 }
                let endsWord = wordEnd == scalars.count || !isWordCharacter(scalars[wordEnd])
                let word = String(String.UnicodeScalarView(scalars[index..<wordEnd]))
                if endsWord, let end = instructionEnd(of: word, after: wordEnd, in: scalars) {
                    index = end
                    continue
                }
                // Not an instruction: keep the whole word and go on.
                kept.append(contentsOf: scalars[index..<wordEnd])
                index = wordEnd
                continue
            }
            kept.append(scalars[index])
            index += 1
        }
        return String(kept)
    }

    /// Where the instruction that begins with `keyword`, which ends at
    /// `start` in `scalars`, ends; or nil when the keyword is not an
    /// instruction. The instruction runs through its last switch, bookmark
    /// name, or quoted argument; a bare word after that is the field's
    /// visible result and stays.
    private static func instructionEnd(
        of keyword: String, after start: Int, in scalars: [Unicode.Scalar]
    ) -> Int? {
        let isUnambiguous = unambiguousKeywords.contains(keyword)
        guard isUnambiguous || ambiguousKeywords.contains(keyword) else { return nil }

        var cursor = start
        // The end of the last token that proves the instruction, and
        // whether a switch or a bookmark name has been seen.
        var confirmedEnd: Int?
        var sawSwitchOrBookmark = false
        var bareArguments = 0

        scanning: while true {
            while cursor < scalars.count, isSpace(scalars[cursor]) { cursor += 1 }
            guard cursor < scalars.count else { break }
            let first = scalars[cursor]

            if first == "\\" {
                // A switch: a backslash and a letter or one of * # @.
                guard let end = switchEnd(at: cursor, in: scalars) else { break scanning }
                cursor = end
                confirmedEnd = end
                sawSwitchOrBookmark = true
            } else if isOpeningQuote(first) {
                guard let end = quotedEnd(at: cursor, in: scalars) else { break scanning }
                cursor = end
                // A quoted word proves an instruction only for a keyword
                // that is no English word, or after a switch (its argument).
                if isUnambiguous || sawSwitchOrBookmark { confirmedEnd = end }
            } else if first == "_", cursor + 1 < scalars.count, isWordCharacter(scalars[cursor + 1]) {
                // A bookmark name such as _Toc68096040 or _Ref123.
                cursor = wordEnd(from: cursor, in: scalars)
                confirmedEnd = cursor
                sawSwitchOrBookmark = true
            } else if isBareWordCharacter(first), bareArguments < mostBareArguments {
                // A bare argument: counts only if a switch follows it.
                while cursor < scalars.count, isBareWordCharacter(scalars[cursor]) { cursor += 1 }
                bareArguments += 1
            } else {
                break scanning
            }
        }

        if let confirmedEnd { return confirmedEnd }
        return isUnambiguous ? start : nil
    }

    /// The end of the switch that begins at `start` (a backslash), or nil
    /// when what follows the backslash is no switch. `\* \# \@` take the
    /// next word or quoted text (`\* MERGEFORMAT`, `\@ "d MMMM"`); a letter
    /// switch (`\h`, `\o`) takes a quoted text only (`\o "1-3"`).
    private static func switchEnd(at start: Int, in scalars: [Unicode.Scalar]) -> Int? {
        guard start + 1 < scalars.count else { return nil }
        let kind = scalars[start + 1]
        var end = start + 2
        let takesBareArgument: Bool
        if kind == "*" || kind == "#" || kind == "@" {
            takesBareArgument = true
        } else if isASCIILetter(kind) {
            // A switch is one letter: "\hello" is not one.
            if end < scalars.count, isWordCharacter(scalars[end]) { return nil }
            takesBareArgument = false
        } else {
            return nil
        }

        // The argument, after optional white space.
        var argument = end
        while argument < scalars.count, isSpace(scalars[argument]) { argument += 1 }
        guard argument < scalars.count else { return end }
        if isOpeningQuote(scalars[argument]), let quoted = quotedEnd(at: argument, in: scalars) {
            end = quoted
        } else if takesBareArgument, !isOpeningQuote(scalars[argument]), scalars[argument] != "\\" {
            end = argument
            while end < scalars.count, !isSpace(scalars[end]) { end += 1 }
        }
        return end
    }

    /// The end of the quoted text that begins at `start`, or nil when the
    /// quote is never closed.
    private static func quotedEnd(at start: Int, in scalars: [Unicode.Scalar]) -> Int? {
        let closing: Unicode.Scalar = scalars[start] == "\u{201C}" ? "\u{201D}" : scalars[start]
        var cursor = start + 1
        while cursor < scalars.count {
            if scalars[cursor] == closing { return cursor + 1 }
            cursor += 1
        }
        return nil
    }

    /// The end of the run of word characters that begins at `start`.
    private static func wordEnd(from start: Int, in scalars: [Unicode.Scalar]) -> Int {
        var cursor = start
        while cursor < scalars.count, isWordCharacter(scalars[cursor]) { cursor += 1 }
        return cursor
    }

    // MARK: - Character classes

    /// Whether `scalar` is a capital letter A to Z.
    private static func isCapital(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x41 && scalar.value <= 0x5A
    }

    /// Whether `scalar` is a letter A to Z or a to z.
    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        isCapital(scalar) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    /// Whether `scalar` is a letter, digit, or underscore, so that a
    /// keyword next to it is part of a longer word.
    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    /// Whether `scalar` may stand in a bare argument: a word character or
    /// one of . : / -.
    private static func isBareWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        isWordCharacter(scalar) || scalar == "." || scalar == ":" || scalar == "/" || scalar == "-"
    }

    /// Whether `scalar` is white space, including the no-break space that
    /// textutil writes around a field.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace
    }

    /// Whether `scalar` opens a quoted argument: a straight or a curly quote.
    private static func isOpeningQuote(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\"" || scalar == "\u{201C}"
    }

    // MARK: - Tidying the tree

    /// The nearest block (paragraph, list item, heading, cell...) above `node`.
    private static func block(containing node: Node) -> Element? {
        var current = node.parent() as? Element
        while let element = current {
            if TextutilHTMLStructure.blockTags.contains(element.tagName().lowercased()) { return element }
            current = element.parent()
        }
        return nil
    }

    /// Whether an emptied `block` may be removed: a table cell may not.
    private static func canDisappear(_ block: Element) -> Bool {
        !["td", "th"].contains(block.tagName().lowercased())
    }

    /// Whether `block` still holds text (pictures are gone before this runs).
    private static func hasContent(_ block: Element) -> Bool {
        guard let text = try? block.text() else { return true }
        return !text.allSatisfy(\.isWhitespace)
    }

    /// Trim the white space from the start and the end of the text of
    /// `block`, so a field that stood at its edge leaves no gap. The text
    /// nodes are emptied or trimmed in place; no element is removed.
    private static func trimEdges(of block: Element) {
        let nodes = TextutilHTMLStructure.textNodes(under: block)
        for node in nodes {
            let text = node.getWholeText()
            let trimmed = String(text.drop(while: \.isWhitespace))
            if trimmed != text { _ = node.text(trimmed) }
            if !trimmed.isEmpty { break }
        }
        for node in nodes.reversed() {
            let text = node.getWholeText()
            let trimmed = String(text.reversed().drop(while: \.isWhitespace).reversed())
            if trimmed != text { _ = node.text(trimmed) }
            if !trimmed.isEmpty { break }
        }
    }

    /// Remove `node` and each ancestor span that it leaves empty, so no
    /// empty shell is left behind.
    private static func removeWithEmptiedSpans(_ node: Node) throws {
        var current: Node = node
        while let parent = current.parent() as? Element,
              parent.tagName().lowercased() == "span", parent.getChildNodes().count == 1 {
            current = parent
        }
        try current.remove()
    }
}
